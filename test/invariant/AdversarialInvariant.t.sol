// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {InvariantBaseTest} from "test/invariant/InvariantBase.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";
import {MaliciousERC4626} from "test/mocks/MaliciousERC4626.sol";

/// @notice Adversarial invariants: a market wired to a fully hostile vault (market D) shares the same collateral and
/// condition — hence the same ConditionalTokens position ids — as the two honest markets A and B. The hostile vault may
/// lie about its balance, short-pay or withhold on withdraw, and reenter its own pool.
///
/// Because the hostile vault can legitimately make its own pool's deposit/redeem revert (e.g. a short-paid withdraw
/// leaves too few tokens to deliver), the market-D handlers wrap their calls in try/catch so the handler itself never
/// reverts (the suite still runs with `fail_on_revert = true`). Swallowed reverts simply mean "the attack only DoS'd
/// its own market."
///
/// The invariants assert the separation that the refactor makes structural: market D's pool is a different contract
/// from A's and B's, so no matter what it does, the honest pools' ConditionalTokens balances, ERC-4626 share balances
/// and share ledgers are untouched. There is deliberately no reentrancy guard — the hostile vault is free to reenter,
/// and these runs assert that doing so reaches nothing outside its own pool.
contract AdversarialInvariantTest is InvariantBaseTest {
    MaliciousERC4626 internal evil;
    Market internal marketD; // hostile vault, condition 1 (same position ids as A & B, separate pool)

    /// @dev Snapshot of the honest pools' token balances, taken before the hostile market ever acts.
    mapping(address pool => mapping(bool isYes => uint256)) internal honestFloor;

    function setUp() public override {
        super.setUp();

        evil = new MaliciousERC4626(IERC20(address(collateral)));
        vm.label(address(evil), "EvilVault");

        marketD = _createPool(IERC4626(address(evil)), conditionId);
        vm.label(address(marketD.pool), "EvilPool");

        bytes4[] memory selectors = new bytes4[](8);
        // Honest handlers (operate only on honest markets A/B/C/S; must never revert).
        selectors[0] = this.depositHandler.selector;
        selectors[1] = this.redeemHandler.selector;
        selectors[2] = this.accrueYieldHandler.selector;
        selectors[3] = this.donateHandler.selector;
        selectors[4] = this.mergeHandler.selector;
        // Hostile handlers (operate on market D; wrapped in try/catch).
        selectors[5] = this.evilDepositHandler.selector;
        selectors[6] = this.evilRedeemHandler.selector;
        selectors[7] = this.evilConfigHandler.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    /* HOSTILE-MARKET HANDLERS (must not revert: pool calls are wrapped) */

    function evilDepositHandler(bool isYes, uint256 amount) external {
        amount = bound(amount, MIN_INVARIANT_AMOUNT, MAX_INVARIANT_AMOUNT);
        _giveOutcomeTokens(msg.sender, marketD, amount);
        vm.prank(msg.sender);
        try marketD.pool.deposit(isYes, amount, msg.sender) {} catch {}
    }

    function evilRedeemHandler(bool isYes, uint256 sharesSeed) external {
        uint256 held = factory.balanceOf(msg.sender, _marketShareId(marketD, isYes));
        if (held == 0) return;
        uint256 shares = bound(sharesSeed, 1, held);
        vm.prank(msg.sender);
        try marketD.pool.redeem(isYes, shares, msg.sender, msg.sender) {} catch {}
    }

    /// @dev Reconfigures the hostile vault mid-run: lie about the balance, short-pay withdraw, or arm a reentrant call
    /// during withdraw. All branches are pure config and never revert.
    function evilConfigHandler(uint256 mode, uint256 value, bool isYes) external {
        mode %= 5;
        if (mode == 0) {
            evil.setFakeAssets(true, bound(value, 0, type(uint128).max));
        } else if (mode == 1) {
            evil.setFakeAssets(false, 0);
        } else if (mode == 2) {
            evil.setWithdrawPayoutBips(bound(value, 0, 10_000));
        } else if (mode == 3) {
            // Arm a reentrant redeem of market D during the next withdraw. The vault reenters as itself, so it needs
            // operator rights over the sender's shares. The grant is on the shared ledger and therefore covers the
            // sender's honest-market shares too — deliberately, since that is the widest reach the hostile vault can
            // be handed, and the invariants below must still hold under it.
            vm.prank(msg.sender);
            factory.setOperator(address(evil), true);
            uint256 held = factory.balanceOf(msg.sender, _marketShareId(marketD, isYes));
            bytes memory data = abi.encodeCall(OutcomeYieldPool.redeem, (isYes, held, msg.sender, msg.sender));
            evil.setReentrancy(MaliciousERC4626.ReenterOn.WITHDRAW, address(marketD.pool), data);
        } else {
            // Arm a reentrant permissionless merge on an *honest* pool during the hostile withdraw. It takes no
            // arguments and no authorization, so this is the strongest cross-pool reach the hostile vault has.
            bytes memory data = abi.encodeCall(OutcomeYieldPool.mergeAndDeposit, ());
            evil.setReentrancy(MaliciousERC4626.ReenterOn.WITHDRAW, address(marketA.pool), data);
        }
    }

    /* INVARIANTS */

    /// @dev Share accounting holds for the honest markets regardless of what the hostile market does.
    function invariant_honestShareConservation() public view {
        assertShareConservation();
    }

    /// @dev The hostile pool never holds a share of an honest market's vault, and the honest pools never hold a share
    /// of the hostile one. This is the audit's finding E1 — a vault whose `asset()` is another vault's share token —
    /// made unreachable: the balances live in different accounts.
    function invariant_vaultShareIsolationWithHostileMarket() public view {
        assertVaultShareIsolation();

        assertEq(erc4626.balanceOf(address(marketD.pool)), 0, "hostile pool holds no default-vault shares");
        assertEq(erc4626B.balanceOf(address(marketD.pool)), 0, "hostile pool holds no vault-B shares");
        assertEq(evil.balanceOf(address(marketA.pool)), 0, "honest pool A holds no hostile-vault shares");
        assertEq(evil.balanceOf(address(marketB.pool)), 0, "honest pool B holds no hostile-vault shares");
    }

    /// @dev Every honest pool's backing still covers everything that was ever deposited into or donated to it, minus
    /// what it paid out. Anything the hostile market managed to siphon out of an honest pool would appear here as a
    /// shortfall — including through the reentrant `mergeAndDeposit` that mode 4 arms.
    function invariant_honestBackingNeverLeaks() public view {
        assertSideBackingCoversFlows();
    }

    /// @dev Exact, rounding-free token conservation across every pool — including the hostile one. This is the
    /// sharpest statement of the property the singleton could not hold: two pools share a position id, and not one
    /// token crosses between them.
    function invariant_yesNoDifferenceConservation() public view {
        assertYesNoDifferenceConservation();
    }

    /// @dev Holders of the honest markets can always exit in full, no matter what the hostile market does.
    function invariant_honestHoldersCanRedeem() public {
        assertAllHoldersCanRedeem();
    }
}
