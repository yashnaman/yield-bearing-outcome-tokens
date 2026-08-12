// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/Base.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";
import {FeeChargingERC4626} from "test/mocks/FeeChargingERC4626.sol";
import {CeilWithdrawVault, ExitFeeVault} from "test/mocks/EipRoundingERC4626.sol";

/// @notice A market's vault is allowed to charge fees; the core must not depend on the vault returning everything it
/// received. With a fee-charging (but honest) vault, redemptions still succeed — depositors simply absorb the fee.
contract FeeVaultTest is BaseTest {
    IERC4626 internal feeVault;
    OutcomeYieldPool internal feePool;

    uint256 internal constant FEE_BIPS = 100; // 1%

    function setUp() public override {
        super.setUp();

        feeVault = IERC4626(address(new FeeChargingERC4626(IERC20(address(collateral)), FEE_BIPS)));
        feePool = factory.deployPool(feeVault, conditionId);
        vm.label(address(feePool), "FeePool");
    }

    function _depositFee(address user, bool isYes, uint256 amount) internal returns (uint256 shares) {
        _mintOutcomeTokens(user, IERC20(address(collateral)), conditionId, amount, address(feePool));
        shares = _depositAs(feePool, user, isYes, amount, user);
    }

    /// @dev A fully-matched market whose vault skims 1% on deposit still lets both sides redeem; the payout is just
    /// reduced by the fee. The core never reverts and stays solvent to the (reduced) backing.
    function testRedemptionsSucceedWithFeeCharged() public {
        uint256 yesShares = _depositFee(ALICE, true, 1000);
        uint256 noShares = _depositFee(BOB, false, 1000); // matches 1000 -> vault keeps 990 after a 1% fee

        assertEq(_invested(feePool), 990, "invested balance is net of the fee");

        // Both holders can still exit; each gets back less than deposited because they share the haircut backing.
        vm.prank(ALICE);
        uint256 aliceAssets = feePool.redeem(true, yesShares, ALICE, ALICE);
        vm.prank(BOB);
        uint256 bobAssets = feePool.redeem(false, noShares, BOB, BOB);

        assertLt(aliceAssets, 1000, "YES depositor absorbs part of the fee");
        assertLt(bobAssets, 1000, "NO depositor absorbs part of the fee");
        assertGt(aliceAssets, 900, "but still recovers most of the deposit");
        assertGt(bobAssets, 900, "but still recovers most of the deposit");

        // The two sides together cannot redeem more than the fee-reduced backing.
        assertLe(aliceAssets + bobAssets, 1990, "total payout bounded by the haircut backing");
    }

    /// @dev Audit finding 4b, accepted rather than fixed. `previewWithdraw` rounds the share burn *up*, and the pool
    /// asks the vault for an exact asset amount, so anything the burn over-covered stays in the vault. The pool takes
    /// exactly what it asked for and splits exactly that — there is no surplus to credit back. What this pins is the
    /// bound: the untouched side is never charged more than one share's worth per exit. See the ACCEPTED RISK note on
    /// the pool for why that is tolerated at a normal share price.
    function testCeilRoundedExitStrandsAtMostOneShare() public {
        // Lift the fee vault's share price well above 1 so a ceil-rounded burn is worth much more than the request.
        uint256 yesShares = _depositFee(ALICE, true, 1_000_000);
        _depositFee(BOB, false, 1_000_000); // fully matched: everything invested, no dangling on either side
        collateral.mint(address(feeVault), 9_000_000); // share price ~10x

        assertEq(_dangling(feePool, true), 0, "YES starts fully invested");
        assertEq(_dangling(feePool, false), 0, "NO starts fully invested");

        uint256 beforeNo = _totalAssets(feePool, false);
        uint256 assetsPerShare = feeVault.convertToAssets(1);

        // Redeem a sliver, which forces the withdraw-and-split path for a tiny `amount`.
        vm.prank(ALICE);
        uint256 assets = feePool.redeem(true, yesShares / 1000, ALICE, ALICE);

        assertGt(assets, 0, "the sliver still pays out");

        // Exactly the withdrawn amount was split; the ceil-rounded over-burn stayed in the vault.
        assertEq(_dangling(feePool, false), assets, "only what was withdrawn got split, no surplus recovered");
        assertEq(_dangling(feePool, true), 0, "the redeemer took its whole side of the split");

        // The untouched side absorbs whatever the over-burn cost, bounded by one share.
        assertLe(beforeNo - _totalAssets(feePool, false), assetsPerShare + 1, "charge to the passive side is bounded");
    }

    /* ---- EIP-correct exit rounding: previewRedeem DOWN, previewWithdraw UP ---- */

    /// @dev An exit-fee vault must not brick redemption. Both sides exit cleanly and the depositor absorbs the fee,
    /// which is the documented design.
    function testExitFeeVaultStillExitsCleanly() public {
        ExitFeeVault v = new ExitFeeVault(IERC20(address(collateral)));
        OutcomeYieldPool p = factory.deployPool(IERC4626(address(v)), conditionId);
        uint256 n = 1_000e6;
        _mintOutcomeTokens(ALICE, IERC20(address(collateral)), conditionId, n, address(p));

        vm.startPrank(ALICE);
        p.deposit(true, n, ALICE);
        p.deposit(false, n, ALICE);

        p.redeem(true, factory.balanceOf(ALICE, _shareId(p, true)), ALICE, ALICE);
        p.redeem(false, factory.totalSupply(_shareId(p, false)), ALICE, ALICE);
        vm.stopPrank();

        assertEq(ct.balanceOf(ALICE, yesPositionId), 900e6, "depositor absorbs the fee, as the design intends");
    }

    /// @dev ACCEPTED RISK, measured. `_withdrawAndSplit` asks the vault for an exact asset amount, so the vault burns a
    /// `ceil`-rounded share count and keeps the difference. The pool forfeits up to one share's worth per redemption,
    /// and because a single invested balance backs both sides, the untouched side is charged too. This pins the
    /// direction and the bound rather than asserting a fix.
    ///
    /// Note the fixture's `assetsPerShare` of 1e9 — the pathological end of the range, chosen to make the effect
    /// visible. README.md § Accepted risks states the bound against a standard vault whose `assetsPerShare` is ~1 in
    /// asset units, where this same bound is ~1 wei. It scales with the vault, which is why the note says to re-check
    /// it per vault.
    function testCeilRoundedExitStrandsAtMostOneShareEipCorrect() public {
        CeilWithdrawVault v = new CeilWithdrawVault(IERC20(address(collateral)));
        OutcomeYieldPool p = factory.deployPool(IERC4626(address(v)), conditionId);

        // Seed an assets-per-share of 1e9: 1 share outstanding backed by 1e9 assets.
        collateral.mint(address(this), 1e9);
        collateral.approve(address(v), 1);
        v.deposit(1, address(this));
        collateral.mint(address(v), 1e9 - 1); // donation lifts the price

        uint256 n = 3e9;
        _mintOutcomeTokens(ALICE, IERC20(address(collateral)), conditionId, n, address(p));
        vm.startPrank(ALICE);
        p.deposit(true, n, ALICE);
        p.deposit(false, n, ALICE);
        vm.stopPrank();
        uint256 shYes = factory.balanceOf(ALICE, _shareId(p, true));

        uint256 beforeYes = _totalAssets(p, true);
        uint256 beforeNo = _totalAssets(p, false);
        assertEq(beforeNo, n, "both sides start backed by the full deposit");

        // Redeem a dust amount: a whole share (worth 1e9) must be burned to deliver ~3 units.
        vm.prank(ALICE);
        uint256 got = p.redeem(true, shYes / 1e9, ALICE, ALICE);
        assertGt(got, 0, "the dust redemption still pays out");

        // Only what the redemption asked for came back and was split; the rest of the burned share stayed behind.
        assertEq(_dangling(p, false), got, "exactly the withdrawn amount was split, no surplus recovered");
        assertEq(_dangling(p, true), 0, "the redeemer took its whole side of the split");

        // Both sides are charged, because one invested balance backs both.
        uint256 lostYes = beforeYes - got - _totalAssets(p, true);
        uint256 lostNo = beforeNo - _totalAssets(p, false);
        assertGt(lostNo, 0, "the untouched side IS charged for the rounding: this is the accepted risk");
        assertEq(lostYes, lostNo, "both sides are charged the same, since one invested balance backs both");

        // The bound README.md claims: never more than one share's worth per redemption.
        assertLt(lostNo, 1e9, "the stranded value stays under assetsPerShare");
    }
}
