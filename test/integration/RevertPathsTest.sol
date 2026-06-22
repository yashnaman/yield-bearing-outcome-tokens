// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";
import {ConfigurableERC20} from "test/mocks/ConfigurableERC20.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";
import {ERC4626VaultAdapter} from "test/mocks/ERC4626VaultAdapter.sol";

/// @notice Covers the vault's raw-bool collateral failure paths, which only trigger when a non-conforming token's
/// `transfer`/`approve` returns false. A `ConfigurableERC20` is used as collateral and made to fail only for the
/// vault's own call, so ConditionalTokens' split/merge and the user's approvals still work.
contract RevertPathsTest is BaseTest {
    ConfigurableERC20 internal badCollateral;
    MockERC4626 internal badVault;
    ERC4626VaultAdapter internal badAdapter;
    IYieldBearingOutcomeTokens.MarketParams internal badMarket;

    error TransferFailed();
    error ApproveFailed();

    function setUp() public override {
        super.setUp();

        badCollateral = new ConfigurableERC20("Bad", "BAD");
        badVault = new MockERC4626(IERC20(address(badCollateral)));
        badAdapter = new ERC4626VaultAdapter(IERC4626(address(badVault)), address(vault));
        badMarket = IYieldBearingOutcomeTokens.MarketParams({
            collateralToken: IERC20(address(badCollateral)),
            conditionId: conditionId,
            vaultAdapter: IVaultAdapter(address(badAdapter))
        });
    }

    /// @dev Splits `amount` of the bad collateral into a YES/NO pair for `user` and approves the vault as operator.
    function _giveBadOutcomeTokens(address user, uint256 amount) internal {
        badCollateral.mint(user, amount);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        vm.startPrank(user);
        badCollateral.approve(address(ct), amount);
        ct.splitPosition(IERC20(address(badCollateral)), PARENT_COLLECTION_ID, conditionId, partition, amount);
        ct.setApprovalForAll(address(vault), true);
        vm.stopPrank();
    }

    function _depositBad(address user, bool isYes, uint256 amount) internal {
        _giveBadOutcomeTokens(user, amount);
        vm.prank(user);
        vault.deposit(badMarket, isYes, amount, user);
    }

    /// @dev When merging complete sets, the vault transfers collateral to the adapter; if that transfer returns false
    /// the deposit reverts with TransferFailed.
    function testMergeRevertsOnFailedTransfer() public {
        _depositBad(ALICE, true, 100); // YES dangling, no merge yet

        // Make the vault's own collateral.transfer (to the adapter) return false during the merging deposit.
        badCollateral.setTransferRevertsFor(address(vault));

        _giveBadOutcomeTokens(BOB, 100);
        vm.prank(BOB);
        vm.expectRevert(TransferFailed.selector);
        vault.deposit(badMarket, false, 100, BOB); // matches -> triggers _mergeAndInvest -> failing transfer
    }

    /// @dev When a redemption must divest and split, the vault approves ConditionalTokens to pull the collateral; if
    /// that approve returns false the redemption reverts with ApproveFailed.
    function testRedeemRevertsOnFailedApprove() public {
        // Establish an invested position so the redeem path needs divest+split.
        _depositBad(ALICE, true, 100);
        _depositBad(BOB, false, 100); // fully matched -> 100 invested, NO side has no dangling

        uint256 bobShares = vault.sharesOf(_id(badMarket), false, BOB);

        // Make the vault's approve to ConditionalTokens return false during _divestAndSplit.
        badCollateral.setApproveRevertsFor(address(vault));

        vm.prank(BOB);
        vm.expectRevert(ApproveFailed.selector);
        vault.redeem(badMarket, false, bobShares, BOB, BOB);
    }

    /// @dev Directly exercises the `danglingBalance` getter: after an unmatched deposit it equals the deposited amount.
    function testDanglingBalanceGetter() public {
        _deposit(ALICE, true, 100); // default market, unmatched YES
        assertEq(vault.danglingBalance(id, true), 100, "dangling reflects the unmatched deposit");
        assertEq(vault.danglingBalance(id, false), 0, "opposite side has no dangling");
    }
}
