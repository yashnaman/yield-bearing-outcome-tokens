// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";
import {FeeChargingVaultAdapter} from "test/mocks/FeeChargingVaultAdapter.sol";

/// @notice An adapter is allowed to charge fees; the vault must not depend on it returning everything it received.
/// With a fee-charging (but honest) adapter, redemptions still succeed — depositors simply absorb the fee.
contract FeeAdapterTest is BaseTest {
    FeeChargingVaultAdapter internal feeAdapter;
    MockERC4626 internal feeVault;
    IYieldBearingOutcomeTokens.MarketParams internal feeMarket;

    uint256 internal constant FEE_BIPS = 100; // 1%

    function setUp() public override {
        super.setUp();

        feeVault = new MockERC4626(IERC20(address(collateral)));
        feeAdapter = new FeeChargingVaultAdapter(IERC4626(address(feeVault)), address(vault), FEE_BIPS);
        feeMarket = IYieldBearingOutcomeTokens.MarketParams({
            collateralToken: IERC20(address(collateral)),
            conditionId: conditionId,
            vaultAdapter: IVaultAdapter(address(feeAdapter))
        });
    }

    function _depositFee(address user, bool isYes, uint256 amount) internal returns (uint256 shares) {
        _mintOutcomeTokens(user, amount);
        vm.prank(user);
        shares = vault.deposit(feeMarket, isYes, amount, user);
    }

    /// @dev A fully-matched market whose adapter skims 1% on invest still lets both sides redeem; the payout is just
    /// reduced by the fee. The vault never reverts and stays solvent to the (reduced) backing.
    function testRedemptionsSucceedWithFeeCharged() public {
        uint256 yesShares = _depositFee(ALICE, true, 1000);
        uint256 noShares = _depositFee(BOB, false, 1000); // matches 1000 -> adapter invests 990 after a 1% fee

        assertEq(feeAdapter.investedBalance(feeMarket), 990, "invested balance is net of the fee");

        // Both holders can still exit; each gets back less than deposited because they share the haircut backing.
        vm.prank(ALICE);
        uint256 aliceAssets = vault.redeem(feeMarket, true, yesShares, ALICE, ALICE);
        vm.prank(BOB);
        uint256 bobAssets = vault.redeem(feeMarket, false, noShares, BOB, BOB);

        assertLt(aliceAssets, 1000, "YES depositor absorbs part of the fee");
        assertLt(bobAssets, 1000, "NO depositor absorbs part of the fee");
        assertGt(aliceAssets, 900, "but still recovers most of the deposit");
        assertGt(bobAssets, 900, "but still recovers most of the deposit");

        // The two sides together cannot redeem more than the fee-reduced backing.
        assertLe(aliceAssets + bobAssets, 1990, "total payout bounded by the haircut backing");
    }
}
