// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";
import {MaliciousVaultAdapter} from "test/mocks/MaliciousVaultAdapter.sol";

/// @notice Proves the "don't trust the adapter" property: a market wired to a hostile adapter can never steal from, or
/// DoS, a market on the honest adapter — even though both markets share the same collateral+condition and therefore
/// the same ConditionalTokens position-id pool inside the singleton vault. The only isolation is the vault's internal
/// per-market `danglingBalance` accounting.
contract MaliciousAdapterTest is BaseTest {
    MaliciousVaultAdapter internal evil;

    // Market A == the default `marketParams` (honest ERC4626 adapter).
    // Market B shares A's collateral and condition but is wired to the malicious adapter.
    IYieldBearingOutcomeTokens.MarketParams internal marketB;

    address internal ATTACKER;

    // Amount of honest, unmatched YES that market A parks in the shared pool. It must remain untouchable.
    uint256 internal constant HONEST_DEPOSIT = 100;

    function setUp() public virtual override {
        super.setUp();
        ATTACKER = makeAddr("Attacker");

        evil = new MaliciousVaultAdapter(IERC20(address(collateral)));
        vm.label(address(evil), "EvilAdapter");

        marketB = IYieldBearingOutcomeTokens.MarketParams({
            collateralToken: IERC20(address(collateral)),
            conditionId: conditionId,
            vaultAdapter: IVaultAdapter(address(evil))
        });

        // Market A parks HONEST_DEPOSIT YES in the shared pool, unmatched, so it stays as dangling tokens the vault
        // custodies. This is the value the attacker will try to reach through market B.
        _deposit(ALICE, true, HONEST_DEPOSIT);
        assertEq(_vaultPositionBalance(yesPositionId), HONEST_DEPOSIT, "honest tokens parked in shared pool");
    }

    /// @dev Helper: attacker deposits `amount` YES into the malicious market B.
    function _depositToB(address user, uint256 amount) internal returns (uint256 shares) {
        _mintOutcomeTokens(user, amount);
        vm.prank(user);
        shares = vault.deposit(marketB, true, amount, user);
    }

    /// @dev Whatever the malicious adapter reports as its balance, the honest market's parked tokens stay put and Alice
    /// can always redeem them in full.
    function testFakeInvestedBalanceCannotStealHonestTokens(uint256 fake) public {
        uint256 attackerShares = _depositToB(ATTACKER, 100);

        evil.setFakeBalance(true, fake); // lie about the balance to inflate the attacker's redeemable assets

        // The attacker tries to redeem an inflated amount. With no real collateral behind the malicious adapter, the
        // divest+split path can't deliver, so the attempt reverts; it can never reach Alice's tokens.
        vm.prank(ATTACKER);
        try vault.redeem(marketB, true, attackerShares, ATTACKER) returns (uint256 got) {
            // If it somehow succeeded, it could only have paid out the attacker's own dangling (<= 100).
            assertLe(got, 100, "attacker can only ever get its own tokens back");
        } catch {}

        // Invariant: the shared pool never drops below the honest market's dangling balance.
        assertGe(_vaultPositionBalance(yesPositionId), HONEST_DEPOSIT, "honest tokens preserved");

        // And Alice redeems her full honest position.
        uint256 aliceShares = vault.sharesOf(id, true, ALICE);
        uint256 assets = _redeem(ALICE, true, aliceShares);
        assertEq(assets, HONEST_DEPOSIT, "Alice fully redeems despite the hostile sibling market");
    }

    /// @dev Even if the attacker pre-funds the malicious adapter so divest can pay, the split only mints tokens backed
    /// by the attacker's OWN collateral; the honest market's tokens are still untouched.
    function testFundedMaliciousAdapterStillCannotSteal() public {
        uint256 attackerShares = _depositToB(ATTACKER, 100);

        // Attacker donates collateral to the malicious adapter and inflates the reported balance.
        collateral.mint(address(evil), 1000);
        evil.setFakeBalance(true, 1000);

        vm.prank(ATTACKER);
        try vault.redeem(marketB, true, attackerShares, ATTACKER) returns (uint256 got) {
            // Attacker receives YES tokens, but only ones freshly split from its own collateral plus its own dangling.
            assertEq(ct.balanceOf(ATTACKER, yesPositionId), got, "attacker only receives what it paid for");
        } catch {}

        assertGe(_vaultPositionBalance(yesPositionId), HONEST_DEPOSIT, "honest tokens preserved");

        uint256 aliceShares = vault.sharesOf(id, true, ALICE);
        assertEq(_redeem(ALICE, true, aliceShares), HONEST_DEPOSIT, "Alice still whole");
    }

    /// @dev A divest that short-pays or withholds collateral makes the split revert, so the malicious market's own
    /// redeem reverts. This is pure self-DoS; the honest market is unaffected.
    function testShortDivestOnlyDosesItself(uint256 bips) public {
        bips = bound(bips, 0, 9999); // anything less than full payout
        uint256 attackerShares = _depositToB(ATTACKER, 100);

        // Match the attacker's side so the malicious adapter actually custodies collateral and a divest is attempted.
        _mintOutcomeTokens(ATTACKER, 100);
        vm.prank(ATTACKER);
        vault.deposit(marketB, false, 100, ATTACKER); // merges 100 sets into the malicious adapter

        evil.setDivestPayoutBips(bips);

        // Redeeming now needs a divest; the short-paid divest makes splitPosition revert.
        vm.prank(ATTACKER);
        vm.expectRevert();
        vault.redeem(marketB, true, attackerShares, ATTACKER);

        // Honest market entirely unaffected.
        uint256 aliceShares = vault.sharesOf(id, true, ALICE);
        assertEq(_redeem(ALICE, true, aliceShares), HONEST_DEPOSIT, "Alice unaffected by B's self-DoS");
    }

    /// @dev The malicious adapter reenters the vault during `divest`, attempting a second redeem of its own market. The
    /// redeem path zeroes this side's dangling balance *before* the external divest call, so the reentrant redeem sees
    /// no stale balance to double-spend. The honest pool stays whole.
    function testReentrantDivestCannotDoubleSpend() public {
        uint256 attackerShares = _depositToB(ATTACKER, 100);
        // Match the side so the adapter holds collateral and divest is reachable.
        _mintOutcomeTokens(ATTACKER, 100);
        vm.prank(ATTACKER);
        vault.deposit(marketB, false, 100, ATTACKER);
        collateral.mint(address(evil), 1000); // ensure divest can pay during the outer call

        // On divest, reenter and try to redeem the same shares again.
        bytes memory reentryData = abi.encodeCall(vault.redeem, (marketB, true, attackerShares, ATTACKER));
        evil.setReentrancy(MaliciousVaultAdapter.ReenterOn.DIVEST, address(vault), reentryData);

        vm.prank(ATTACKER);
        try vault.redeem(marketB, true, attackerShares, ATTACKER) {} catch {}

        // No matter the outcome, the honest market's parked tokens are intact and Alice redeems in full.
        assertGe(_vaultPositionBalance(yesPositionId), HONEST_DEPOSIT, "honest tokens preserved through reentrancy");
        uint256 aliceShares = vault.sharesOf(id, true, ALICE);
        assertEq(_redeem(ALICE, true, aliceShares), HONEST_DEPOSIT, "Alice unaffected by reentrancy");
    }
}
