// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/Base.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";
import {MaliciousERC4626} from "test/mocks/MaliciousERC4626.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {ZeroShareVault} from "test/mocks/EipRoundingERC4626.sol";

/// @notice Proves the "a market's vault can't harm a sibling" property: a market wired to a hostile ERC-4626 vault can
/// never steal from, or DoS, a market on an honest vault — even though both markets share the same collateral and
/// condition and therefore the same ConditionalTokens position ids.
/// @dev Under the singleton this property rested entirely on the core's internal per-market `danglingBalance` ledger,
/// and the audit found several ways through it. It is now physical: the honest market and the hostile market are two
/// different contracts holding two different ConditionalTokens balances, so the hostile vault has no allowance over,
/// and no accounting shared with, the honest pool. These tests assert that separation directly.
contract MaliciousVaultTest is BaseTest {
    MaliciousERC4626 internal evil;
    IERC4626 internal evilVault;
    OutcomeYieldPool internal evilPool;

    address internal ATTACKER;

    // Amount of honest, unmatched YES that the honest market parks in its pool. It must remain untouchable.
    uint256 internal constant HONEST_DEPOSIT = 100;

    function setUp() public virtual override {
        super.setUp();
        ATTACKER = makeAddr("Attacker");

        evil = new MaliciousERC4626(IERC20(address(collateral)));
        evilVault = IERC4626(address(evil));
        vm.label(address(evil), "EvilVault");

        evilPool = factory.deployPool(evilVault, conditionId);
        vm.label(address(evilPool), "EvilPool");

        // The honest market parks HONEST_DEPOSIT YES in its own pool, unmatched, so it stays as dangling tokens the
        // pool custodies. This is the value the attacker will try to reach through the hostile market.
        _deposit(ALICE, true, HONEST_DEPOSIT);
        assertEq(_poolPositionBalance(yesPositionId), HONEST_DEPOSIT, "honest tokens parked in the honest pool");
    }

    /// @dev Attacker deposits `amount` of a side into the hostile market.
    function _depositEvil(address user, bool isYes, uint256 amount) internal returns (uint256 shares) {
        _mintOutcomeTokens(user, IERC20(address(collateral)), conditionId, amount, address(evilPool));
        shares = _depositAs(evilPool, user, isYes, amount, user);
    }

    /// @dev The core separation assertion, reused by every test here: the honest pool holds exactly the honest
    /// deposit, and Alice can still exit in full.
    function _assertHonestMarketWhole() internal {
        assertEq(_poolPositionBalance(yesPositionId), HONEST_DEPOSIT, "honest pool holds exactly its own tokens");
        assertEq(erc4626.balanceOf(address(evilPool)), 0, "the hostile pool never holds honest vault shares");

        uint256 aliceShares = factory.balanceOf(ALICE, yesShareId);
        assertEq(_redeem(ALICE, true, aliceShares), HONEST_DEPOSIT, "Alice fully redeems despite the hostile market");
    }

    /// @dev Whatever the hostile vault reports as its balance, the honest market's parked tokens stay put and Alice can
    /// always redeem them in full.
    function testFakeInvestedBalanceCannotStealHonestTokens(uint256 fake) public {
        uint256 attackerShares = _depositEvil(ATTACKER, true, 100);

        evil.setFakeAssets(true, fake); // lie about the balance to inflate the attacker's redeemable assets

        // The attacker tries to redeem an inflated amount. With no real collateral behind the hostile vault, the
        // withdraw+split path can't deliver, so the attempt reverts; it can never reach Alice's tokens.
        vm.prank(ATTACKER);
        try evilPool.redeem(true, attackerShares, ATTACKER, ATTACKER) returns (uint256 got) {
            // If it somehow succeeded, it could only have paid out the attacker's own dangling (<= 100).
            assertLe(got, 100, "attacker can only ever get its own tokens back");
        } catch {}

        _assertHonestMarketWhole();
    }

    /// @dev Even if the attacker funds the hostile vault and inflates its reported balance, any split only mints tokens
    /// backed by the attacker's OWN collateral; the honest market's tokens are still untouched.
    function testFundedMaliciousVaultStillCannotSteal() public {
        // Attacker fully matches its own position so the hostile vault legitimately custodies the attacker's collateral.
        _depositEvil(ATTACKER, true, 100);
        uint256 attackerNoShares = _depositEvil(ATTACKER, false, 100); // matches -> 100 invested in the hostile vault

        // Attacker donates extra collateral to the hostile vault and inflates the reported balance.
        collateral.mint(address(evil), 1000);
        evil.setFakeAssets(true, 5000);

        vm.prank(ATTACKER);
        try evilPool.redeem(false, attackerNoShares, ATTACKER, ATTACKER) returns (uint256 got) {
            // Attacker receives NO tokens, but only ones freshly split from its own collateral plus its own dangling.
            assertEq(ct.balanceOf(ATTACKER, noPositionId), got, "attacker only receives what it paid for");
            assertLe(got, 100 + 1000, "attacker cannot extract more than it put in");
        } catch {}

        _assertHonestMarketWhole();
    }

    /// @dev Regression for the "unbound collateral / mutable `asset()`" finding, which the singleton defended against
    /// by folding the collateral into a hashed market id. The pool caches `asset()` once in its constructor, so a
    /// vault that flips it afterwards changes nothing: the pool keeps operating on the position ids of the collateral
    /// it was born with, and can never address the honest market's positions at all.
    function testMutableAssetIsPinnedAtDeployment() public {
        // A worthless collateral the attacker fully controls.
        MockERC20 cheap = new MockERC20("Cheap", "CHP");
        vm.label(address(cheap), "CheapCollateral");

        // 1. The hostile vault reports the worthless collateral when its pool is deployed.
        evil.setAsset(IERC20(address(cheap)));
        ct.prepareCondition(ORACLE, keccak256("cheap-question"), 2);
        bytes32 cheapCondition = ct.getConditionId(ORACLE, keccak256("cheap-question"), 2);
        OutcomeYieldPool cheapPool = factory.deployPool(evilVault, cheapCondition);
        // (the condition differs, so this is a distinct pool from `evilPool`)
        assertEq(address(cheapPool.COLLATERAL()), address(cheap), "collateral cached at construction");

        // 2. Attacker flips the vault to report the valuable collateral the honest market uses.
        evil.setAsset(IERC20(address(collateral)));

        // 3. The pool is unmoved: it still reports the cheap collateral, and its position ids are the cheap market's,
        //    not the honest market's — so nothing it can do addresses Alice's tokens.
        assertEq(address(cheapPool.COLLATERAL()), address(cheap), "collateral unchanged by the flip");
        assertTrue(_poolPositionId(cheapPool, true) != yesPositionId, "cheap pool cannot address honest YES");
        assertTrue(_poolPositionId(cheapPool, false) != noPositionId, "cheap pool cannot address honest NO");

        _assertHonestMarketWhole();
    }

    /// @dev A withdraw that short-pays or withholds collateral makes the split under-deliver, so the hostile market's
    /// own redeem reverts. This is pure self-DoS; the honest market is unaffected.
    function testShortWithdrawOnlyDosesItself(uint256 bips) public {
        bips = bound(bips, 0, 9999); // anything less than full payout
        uint256 attackerShares = _depositEvil(ATTACKER, true, 100);

        // Match the attacker's side so the hostile vault actually custodies collateral and a withdraw is attempted.
        _depositEvil(ATTACKER, false, 100); // merges 100 sets into the hostile vault

        evil.setWithdrawPayoutBips(bips);

        // Redeeming now needs a withdraw; the short-paid withdraw leaves too few tokens to deliver.
        vm.prank(ATTACKER);
        vm.expectRevert();
        evilPool.redeem(true, attackerShares, ATTACKER, ATTACKER);

        _assertHonestMarketWhole();
    }

    /// @dev The hostile vault reenters during the merge's `deposit`. There is no reentrancy guard: the reentrant call
    /// is simply confined to the hostile pool, whose participants chose that vault. It cannot observe or touch the
    /// honest pool's balances, because they live in a different contract.
    function testReentrantDepositInsideMergeFrameCannotReachHonestPool() public {
        uint256 attackerYesShares = _depositEvil(ATTACKER, true, 100);

        // The vault reenters as itself, so the attacker grants it operator rights over their own shares.
        vm.prank(ATTACKER);
        factory.setOperator(address(evil), true);

        // On the merge's vault deposit, reenter and try to redeem the attacker's YES shares mid-flight.
        bytes memory reentryData =
            abi.encodeCall(OutcomeYieldPool.redeem, (true, attackerYesShares, ATTACKER, ATTACKER));
        evil.setReentrancy(MaliciousERC4626.ReenterOn.DEPOSIT, address(evilPool), reentryData);

        _depositEvil(ATTACKER, false, 100); // matches -> merge -> evil deposit -> reentrant redeem

        // Whatever happened inside the hostile pool, the honest pool's ConditionalTokens balance is untouched: the two
        // are separate accounts holding the same position id.
        _assertHonestMarketWhole();
    }

    /// @dev The hostile vault reenters during `withdraw`, attempting a second redeem of its own market. Again the
    /// blast radius is the hostile pool alone.
    function testReentrantWithdrawCannotReachHonestPool() public {
        uint256 attackerShares = _depositEvil(ATTACKER, true, 100);
        // Match the side so the vault holds collateral and withdraw is reachable.
        _depositEvil(ATTACKER, false, 100);
        collateral.mint(address(evil), 1000); // ensure withdraw can pay during the outer call

        vm.prank(ATTACKER);
        factory.setOperator(address(evil), true);

        // On withdraw, reenter and try to redeem the same shares again.
        bytes memory reentryData = abi.encodeCall(OutcomeYieldPool.redeem, (true, attackerShares, ATTACKER, ATTACKER));
        evil.setReentrancy(MaliciousERC4626.ReenterOn.WITHDRAW, address(evilPool), reentryData);

        vm.prank(ATTACKER);
        try evilPool.redeem(true, attackerShares, ATTACKER, ATTACKER) {} catch {}

        _assertHonestMarketWhole();
    }

    /// @dev The hostile vault holds an unbounded allowance over its own pool's collateral, granted in that pool's
    /// constructor. It has none over the honest pool's, so it cannot pull a single unit of the honest market's funds.
    function testHostileVaultHasNoAllowanceOverTheHonestPool() public view {
        assertEq(collateral.allowance(address(pool), address(evil)), 0, "no allowance from the honest pool");
        assertEq(
            collateral.allowance(address(evilPool), address(evil)),
            type(uint256).max,
            "the hostile pool grants only its own collateral"
        );
    }

    /// @dev ACCEPTED RISK, at its limit. `_mergeAndDeposit` ignores the share count the vault returns, so a vault that
    /// takes the collateral and books nothing destroys the whole merge. This is the same `floor` the pool accepts on
    /// every merge taken to `assetsPerShare = infinity`: there is no cliff between "minted zero" and "minted one share
    /// worth less than was paid", which is why no `!= 0` check guards it.
    ///
    /// Kept as a test because it marks where the accepted-risk argument stops holding. That argument bounds the loss by
    /// the vault's `assetsPerShare` and assumes a standard ERC-4626 where that is ~1. A vault outside that shape is not
    /// bounded by anything, and `deployPool` is permissionless — so the vault a market picks is load-bearing.
    function testZeroShareDepositLosesPrincipalAcceptedRisk() public {
        ZeroShareVault v = new ZeroShareVault(IERC20(address(collateral)));
        OutcomeYieldPool p = factory.deployPool(IERC4626(address(v)), conditionId);
        uint256 n = 1_000e6;
        _mintOutcomeTokens(ALICE, IERC20(address(collateral)), conditionId, n, address(p));

        vm.startPrank(ALICE);
        p.deposit(true, n, ALICE);
        p.deposit(false, n, ALICE);
        vm.stopPrank();
        uint256 shYes = factory.balanceOf(ALICE, _shareId(p, true));

        // The merge went through: the collateral left the pool and the vault booked the pool nothing for it.
        assertEq(collateral.balanceOf(address(v)), n, "the collateral reached the vault");
        assertEq(v.balanceOf(address(p)), 0, "and bought the pool no shares at all");
        assertEq(_dangling(p, true), 0, "nothing stayed dangling on YES");
        assertEq(_dangling(p, false), 0, "nothing stayed dangling on NO");
        assertEq(_totalAssets(p, true), 0, "the side is backed by nothing");

        // The pool is still internally consistent — it pays out what it says it has, which is zero.
        vm.prank(ALICE);
        uint256 out = p.redeem(true, shYes, ALICE, ALICE);
        assertEq(out, 0, "the depositor's principal is gone: this vault is outside the accepted-risk bound");
    }
}
