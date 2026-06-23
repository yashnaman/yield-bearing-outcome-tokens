// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";

/// @notice Tests the yield-distribution mechanic: yield accrued in the underlying ERC4626 lifts each side's share
/// price, and the fully-matched (scarce) side captures the full rate while the surplus side is diluted by its
/// utilization, exactly as the README describes.
contract YieldDistributionIntegrationTest is BaseTest {
    /// @dev Yield raises the redeemable assets of a fully-matched side proportionally.
    function testYieldLiftsSharePrice() public {
        _deposit(ALICE, true, 100);
        uint256 bobShares = _deposit(BOB, false, 100); // fully matched: investedBalance = 100, no dangling

        _accrueYield(100); // double the vault's assets -> investedBalance = 200

        assertEq(vault.investedBalance(defaultVault, conditionId), 200, "yield reflected in invested balance");

        // Bob's NO shares should now redeem for ~200 (his 100 doubled), minus virtual-offset rounding.
        uint256 assets = _redeem(BOB, false, bobShares);
        assertApproxEqAbs(assets, 200, 2, "fully-matched side earns the full yield");
    }

    /// @dev With an unbalanced book, the scarce side (all tokens merged, 100% utilized) earns the full rate while the
    /// surplus side (partially utilized) is diluted. YES is oversupplied (100 vs 50), so NO is the scarce side.
    function testScarceSideEarnsMoreThanSurplusSide() public {
        uint256 yesShares = _deposit(ALICE, true, 100);
        uint256 noShares = _deposit(BOB, false, 50); // matched = 50; YES has 50 dangling, NO has 0

        assertEq(vault.investedBalance(defaultVault, conditionId), 50, "50 complete sets invested");

        _accrueYield(50); // investedBalance 50 -> 100

        // Redeem the scarce (NO) side first, then the surplus (YES) side; both must stay solvent.
        uint256 noAssets = _redeem(BOB, false, noShares);
        uint256 yesAssets = _redeem(ALICE, true, yesShares);

        // NO deposited 50 and should roughly double (full rate); YES deposited 100 and gains only ~half the rate.
        assertGt(noAssets, 90, "scarce side ~doubles");
        assertLe(noAssets, 100, "scarce side bounded by its backing");
        assertGt(yesAssets, 100, "surplus side still gains some yield");
        assertLt(yesAssets, 160, "surplus side diluted relative to scarce side");

        // Yield-per-unit-deposited is strictly higher for the scarce side.
        // noAssets/50 (~2.0) must exceed yesAssets/100 (~1.5).
        assertGt(noAssets * 100, yesAssets * 50, "scarce side captures a higher yield rate");
    }
}
