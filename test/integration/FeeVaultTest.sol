// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {FeeChargingERC4626} from "test/mocks/FeeChargingERC4626.sol";

/// @notice A market's vault is allowed to charge fees; the core must not depend on the vault returning everything it
/// received. With a fee-charging (but honest) vault, redemptions still succeed — depositors simply absorb the fee.
contract FeeVaultTest is BaseTest {
    IERC4626 internal feeVault;

    uint256 internal constant FEE_BIPS = 100; // 1%

    function setUp() public override {
        super.setUp();

        feeVault = IERC4626(address(new FeeChargingERC4626(IERC20(address(collateral)), FEE_BIPS)));
    }

    function _depositFee(address user, bool isYes, uint256 amount) internal returns (uint256 shares) {
        _mintOutcomeTokens(user, amount);
        vm.prank(user);
        shares = vault.deposit(feeVault, conditionId, isYes, amount, user);
    }

    /// @dev A fully-matched market whose vault skims 1% on deposit still lets both sides redeem; the payout is just
    /// reduced by the fee. The core never reverts and stays solvent to the (reduced) backing.
    function testRedemptionsSucceedWithFeeCharged() public {
        uint256 yesShares = _depositFee(ALICE, true, 1000);
        uint256 noShares = _depositFee(BOB, false, 1000); // matches 1000 -> vault keeps 990 after a 1% fee

        assertEq(vault.investedBalance(feeVault, conditionId), 990, "invested balance is net of the fee");

        // Both holders can still exit; each gets back less than deposited because they share the haircut backing.
        vm.prank(ALICE);
        uint256 aliceAssets = vault.redeem(feeVault, conditionId, true, yesShares, ALICE, ALICE);
        vm.prank(BOB);
        uint256 bobAssets = vault.redeem(feeVault, conditionId, false, noShares, BOB, BOB);

        assertLt(aliceAssets, 1000, "YES depositor absorbs part of the fee");
        assertLt(bobAssets, 1000, "NO depositor absorbs part of the fee");
        assertGt(aliceAssets, 900, "but still recovers most of the deposit");
        assertGt(bobAssets, 900, "but still recovers most of the deposit");

        // The two sides together cannot redeem more than the fee-reduced backing.
        assertLe(aliceAssets + bobAssets, 1990, "total payout bounded by the haircut backing");
    }
}
