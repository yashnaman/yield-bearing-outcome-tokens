// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {MaliciousERC4626} from "test/mocks/MaliciousERC4626.sol";

/// @notice Proves the "a market's vault can't harm a sibling" property: a market wired to a hostile ERC-4626 vault can
/// never steal from, or DoS, a market on an honest vault — even though both markets share the same collateral and
/// condition and therefore the same ConditionalTokens position-id pool inside the singleton vault. The only isolation
/// is the core's internal per-market `danglingBalance` accounting.
contract MaliciousVaultTest is BaseTest {
    MaliciousERC4626 internal evil;
    IERC4626 internal evilVault;

    address internal ATTACKER;

    // Amount of honest, unmatched YES that the honest market parks in the shared pool. It must remain untouchable.
    uint256 internal constant HONEST_DEPOSIT = 100;

    function setUp() public virtual override {
        super.setUp();
        ATTACKER = makeAddr("Attacker");

        evil = new MaliciousERC4626(IERC20(address(collateral)));
        evilVault = IERC4626(address(evil));
        vm.label(address(evil), "EvilVault");

        // The honest market parks HONEST_DEPOSIT YES in the shared pool, unmatched, so it stays as dangling tokens the
        // core custodies. This is the value the attacker will try to reach through the hostile market.
        _deposit(ALICE, true, HONEST_DEPOSIT);
        assertEq(_vaultPositionBalance(yesPositionId), HONEST_DEPOSIT, "honest tokens parked in shared pool");
    }

    /// @dev Attacker deposits `amount` YES into the hostile market.
    function _depositEvil(address user, bool isYes, uint256 amount) internal returns (uint256 shares) {
        _mintOutcomeTokens(user, amount);
        vm.prank(user);
        shares = vault.deposit(evilVault, conditionId, isYes, amount, user);
    }

    /// @dev Whatever the hostile vault reports as its balance, the honest market's parked tokens stay put and Alice can
    /// always redeem them in full.
    function testFakeInvestedBalanceCannotStealHonestTokens(uint256 fake) public {
        uint256 attackerShares = _depositEvil(ATTACKER, true, 100);

        evil.setFakeAssets(true, fake); // lie about the balance to inflate the attacker's redeemable assets

        // The attacker tries to redeem an inflated amount. With no real collateral behind the hostile vault, the
        // withdraw+split path can't deliver, so the attempt reverts; it can never reach Alice's tokens.
        vm.prank(ATTACKER);
        try vault.redeem(evilVault, conditionId, true, attackerShares, ATTACKER, ATTACKER) returns (uint256 got) {
            // If it somehow succeeded, it could only have paid out the attacker's own dangling (<= 100).
            assertLe(got, 100, "attacker can only ever get its own tokens back");
        } catch {}

        // Invariant: the shared pool never drops below the honest market's dangling balance.
        assertGe(_vaultPositionBalance(yesPositionId), HONEST_DEPOSIT, "honest tokens preserved");

        // And Alice redeems her full honest position.
        uint256 aliceShares = vault.sharesOf(defaultVault, conditionId, true, ALICE);
        uint256 assets = _redeem(ALICE, true, aliceShares);
        assertEq(assets, HONEST_DEPOSIT, "Alice fully redeems despite the hostile sibling market");
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
        try vault.redeem(evilVault, conditionId, false, attackerNoShares, ATTACKER, ATTACKER) returns (uint256 got) {
            // Attacker receives NO tokens, but only ones freshly split from its own collateral plus its own dangling.
            assertEq(ct.balanceOf(ATTACKER, noPositionId), got, "attacker only receives what it paid for");
            assertLe(got, 100 + 1000, "attacker cannot extract more than it put in");
        } catch {}

        assertGe(_vaultPositionBalance(yesPositionId), HONEST_DEPOSIT, "honest tokens preserved");

        uint256 aliceShares = vault.sharesOf(defaultVault, conditionId, true, ALICE);
        assertEq(_redeem(ALICE, true, aliceShares), HONEST_DEPOSIT, "Alice still whole");
    }

    /// @dev A withdraw that short-pays or withholds collateral makes the split revert, so the hostile market's own
    /// redeem reverts. This is pure self-DoS; the honest market is unaffected.
    function testShortWithdrawOnlyDosesItself(uint256 bips) public {
        bips = bound(bips, 0, 9999); // anything less than full payout
        uint256 attackerShares = _depositEvil(ATTACKER, true, 100);

        // Match the attacker's side so the hostile vault actually custodies collateral and a withdraw is attempted.
        _depositEvil(ATTACKER, false, 100); // merges 100 sets into the hostile vault

        evil.setWithdrawPayoutBips(bips);

        // Redeeming now needs a withdraw; the short-paid withdraw makes splitPosition revert.
        vm.prank(ATTACKER);
        vm.expectRevert();
        vault.redeem(evilVault, conditionId, true, attackerShares, ATTACKER, ATTACKER);

        // Honest market entirely unaffected.
        uint256 aliceShares = vault.sharesOf(defaultVault, conditionId, true, ALICE);
        assertEq(_redeem(ALICE, true, aliceShares), HONEST_DEPOSIT, "Alice unaffected by the hostile market's self-DoS");
    }

    /// @dev The hostile vault reenters the core during the merge's `deposit` (inside the try frame of the best-effort
    /// merge). Both sides' dangling balances are settled before that external call, so the reentrant redeem sees no
    /// stale balance to double-spend; it can only burn the attacker's own shares. The honest pool stays whole and the
    /// pooled balance still matches the sum of the markets' dangling balances.
    function testReentrantDepositInsideMergeFrameCannotCorruptAccounting() public {
        uint256 attackerYesShares = _depositEvil(ATTACKER, true, 100);

        // On the merge's vault deposit, reenter and try to redeem the attacker's YES shares mid-flight.
        bytes memory reentryData =
            abi.encodeCall(vault.redeem, (evilVault, conditionId, true, attackerYesShares, ATTACKER, ATTACKER));
        evil.setReentrancy(MaliciousERC4626.ReenterOn.DEPOSIT, address(vault), reentryData);

        _depositEvil(ATTACKER, false, 100); // matches -> merge -> evil deposit -> reentrant redeem

        // The reentrant redeem observed settled danglings (both zero) and a not-yet-booked invested balance, so it
        // could not extract anything; the honest market's parked tokens are intact and Alice redeems in full.
        assertGe(_vaultPositionBalance(yesPositionId), HONEST_DEPOSIT, "honest tokens preserved through reentrancy");
        assertEq(
            _vaultPositionBalance(yesPositionId),
            vault.danglingBalance(defaultVault, conditionId, true)
                + vault.danglingBalance(evilVault, conditionId, true),
            "YES pool == sum of danglings"
        );
        assertEq(
            _vaultPositionBalance(noPositionId),
            vault.danglingBalance(defaultVault, conditionId, false)
                + vault.danglingBalance(evilVault, conditionId, false),
            "NO pool == sum of danglings"
        );
        uint256 aliceShares = vault.sharesOf(defaultVault, conditionId, true, ALICE);
        assertEq(_redeem(ALICE, true, aliceShares), HONEST_DEPOSIT, "Alice unaffected by reentrancy");
    }

    /// @dev The hostile vault reenters the core during `withdraw`, attempting a second redeem of its own market. The
    /// redeem path zeroes this side's dangling balance *before* the external withdraw call, so the reentrant redeem
    /// sees no stale balance to double-spend. The honest pool stays whole.
    function testReentrantWithdrawCannotDoubleSpend() public {
        uint256 attackerShares = _depositEvil(ATTACKER, true, 100);
        // Match the side so the vault holds collateral and withdraw is reachable.
        _depositEvil(ATTACKER, false, 100);
        collateral.mint(address(evil), 1000); // ensure withdraw can pay during the outer call

        // On withdraw, reenter and try to redeem the same shares again.
        bytes memory reentryData =
            abi.encodeCall(vault.redeem, (evilVault, conditionId, true, attackerShares, ATTACKER, ATTACKER));
        evil.setReentrancy(MaliciousERC4626.ReenterOn.WITHDRAW, address(vault), reentryData);

        vm.prank(ATTACKER);
        try vault.redeem(evilVault, conditionId, true, attackerShares, ATTACKER, ATTACKER) {} catch {}

        // No matter the outcome, the honest market's parked tokens are intact and Alice redeems in full.
        assertGe(_vaultPositionBalance(yesPositionId), HONEST_DEPOSIT, "honest tokens preserved through reentrancy");
        uint256 aliceShares = vault.sharesOf(defaultVault, conditionId, true, ALICE);
        assertEq(_redeem(ALICE, true, aliceShares), HONEST_DEPOSIT, "Alice unaffected by reentrancy");
    }
}
