// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {InvariantBaseTest} from "test/invariant/InvariantBaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";
import {MaliciousVaultAdapter} from "test/mocks/MaliciousVaultAdapter.sol";

/// @notice Adversarial invariants: a market wired to a fully hostile adapter (market D) shares the same
/// collateral+condition — hence the same ConditionalTokens position-id pool — as the two honest markets A and B. The
/// hostile adapter may lie about its balance, short-pay or skip divest, and reenter the vault.
///
/// Because the malicious adapter can legitimately make the *vault's* deposit/redeem revert (e.g. a short-paid divest
/// makes the split revert), the market-D handlers wrap their vault calls in try/catch so the handler itself never
/// reverts (the suite still runs with `fail_on_revert = true`). Swallowed reverts simply mean "the attack only
/// DoS'd its own market." The invariants assert that, no matter what market D does, the pooled ERC1155 balance stays
/// exactly attributed to the markets' internal dangling balances — so honest markets' tokens are never reachable.
contract AdversarialInvariantTest is InvariantBaseTest {
    MaliciousVaultAdapter internal evil;
    IYieldBearingOutcomeTokens.MarketParams internal marketD; // hostile adapter, condition 1 (shares A & B's pool)

    function setUp() public override {
        super.setUp();

        evil = new MaliciousVaultAdapter(IERC20(address(collateral)));
        vm.label(address(evil), "EvilAdapter");

        marketD = IYieldBearingOutcomeTokens.MarketParams({
            collateralToken: IERC20(address(collateral)),
            conditionId: conditionId,
            vaultAdapter: IVaultAdapter(address(evil))
        });

        bytes4[] memory selectors = new bytes4[](7);
        // Honest handlers (operate only on honest markets A/B/C; must never revert).
        selectors[0] = this.depositHandler.selector;
        selectors[1] = this.redeemHandler.selector;
        selectors[2] = this.accrueYieldHandler.selector;
        selectors[3] = this.donateHandler.selector;
        // Hostile handlers (operate on market D; wrapped in try/catch).
        selectors[4] = this.evilDepositHandler.selector;
        selectors[5] = this.evilRedeemHandler.selector;
        selectors[6] = this.evilConfigHandler.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    /* HOSTILE-MARKET HANDLERS (must not revert: vault calls are wrapped) */

    function evilDepositHandler(bool isYes, uint256 amount) external {
        amount = bound(amount, MIN_INVARIANT_AMOUNT, MAX_INVARIANT_AMOUNT);
        _giveOutcomeTokens(msg.sender, marketD, amount);
        vm.prank(msg.sender);
        try vault.deposit(marketD, isYes, amount, msg.sender) {} catch {}
    }

    function evilRedeemHandler(bool isYes, uint256 sharesSeed) external {
        uint256 held = vault.sharesOf(_id(marketD), isYes, msg.sender);
        if (held == 0) return;
        uint256 shares = bound(sharesSeed, 1, held);
        vm.prank(msg.sender);
        try vault.redeem(marketD, isYes, shares, msg.sender, msg.sender) {} catch {}
    }

    /// @dev Reconfigures the hostile adapter mid-run: lie about the balance, short-pay divest, or arm a reentrant
    /// redeem during divest. All branches are pure config and never revert.
    function evilConfigHandler(uint256 mode, uint256 value, bool isYes) external {
        mode %= 4;
        if (mode == 0) {
            evil.setFakeBalance(true, bound(value, 0, type(uint128).max));
        } else if (mode == 1) {
            evil.setFakeBalance(false, 0);
        } else if (mode == 2) {
            evil.setDivestPayoutBips(bound(value, 0, 10_000));
        } else {
            // Arm a reentrant redeem of market D during the next divest.
            uint256 held = vault.sharesOf(_id(marketD), isYes, msg.sender);
            bytes memory data = abi.encodeCall(vault.redeem, (marketD, isYes, held, msg.sender, msg.sender));
            evil.setReentrancy(MaliciousVaultAdapter.ReenterOn.DIVEST, address(vault), data);
        }
    }

    /* INVARIANTS */

    /// @dev Share accounting holds for the honest markets regardless of what the hostile market does.
    function invariant_honestShareConservation() public view {
        assertShareConservation();
    }

    /// @dev The pooled ERC1155 balance always equals the sum of *all* markets' internal dangling balances — including
    /// the hostile market's. The hostile adapter can never make the pool diverge from the internal accounting, so it
    /// can never reach the honest markets' parked tokens.
    function invariant_poolConservationWithHostileMarket() public view {
        IYieldBearingOutcomeTokens.MarketParams[] memory sharing = new IYieldBearingOutcomeTokens.MarketParams[](3);
        sharing[0] = marketA;
        sharing[1] = marketB;
        sharing[2] = marketD;
        _assertPool(conditionId, true, sharing);
        _assertPool(conditionId, false, sharing);
        // Condition 2 is untouched by the hostile market.
        _assertPool(conditionId2, true, _one(marketC));
        _assertPool(conditionId2, false, _one(marketC));
    }

    /// @dev Holders of the honest markets can always exit in full, no matter what the hostile market does.
    function invariant_honestHoldersCanRedeem() public {
        assertAllHoldersCanRedeem();
    }
}
