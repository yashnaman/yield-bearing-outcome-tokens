// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {ConfigurableERC20} from "test/mocks/ConfigurableERC20.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";

/// @notice Covers the vault's raw-bool collateral failure paths, which only trigger when a non-conforming token's
/// `approve` returns false. A `ConfigurableERC20` is used as collateral and made to fail only for the vault's own call,
/// so ConditionalTokens' split/merge and the user's approvals still work.
contract RevertPathsTest is BaseTest {
    ConfigurableERC20 internal badCollateral;
    IERC4626 internal badVault;

    error ApproveFailed();

    function setUp() public override {
        super.setUp();

        badCollateral = new ConfigurableERC20("Bad", "BAD");
        badVault = IERC4626(address(new MockERC4626(IERC20(address(badCollateral)))));
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
        vault.deposit(badVault, conditionId, isYes, amount, user);
    }

    /// @dev When merging complete sets, the vault approves the ERC-4626 vault to pull the collateral; if that approve
    /// returns false the merge is rolled back and deferred — the deposit still succeeds with both sides left dangling,
    /// and a later deposit retries the merge once the approve works again.
    function testApproveFailureDefersMerge() public {
        _depositBad(ALICE, true, 100); // YES dangling, no merge yet

        // Make the vault's own collateral.approve (to the ERC-4626 vault) return false during the merging deposit.
        badCollateral.setApproveRevertsFor(address(vault));

        _depositBad(BOB, false, 100); // matches -> merge attempted -> failing approve -> deferred, not reverted

        assertEq(
            vault.danglingBalance(badVault, conditionId, true), 100, "YES keeps its dangling after the deferred merge"
        );
        assertEq(
            vault.danglingBalance(badVault, conditionId, false), 100, "NO keeps its dangling after the deferred merge"
        );
        assertEq(vault.investedBalance(badVault, conditionId), 0, "nothing invested while approve fails");

        // Once the approve works again, the next deposit retries the accumulated merge and invests it.
        badCollateral.setApproveRevertsFor(address(0));
        _depositBad(BOB, false, 1);

        assertEq(vault.investedBalance(badVault, conditionId), 100, "retried merge invests the matched sets");
        assertEq(vault.danglingBalance(badVault, conditionId, true), 0, "YES fully matched");
        assertEq(vault.danglingBalance(badVault, conditionId, false), 1, "NO keeps only its surplus");
    }

    /// @dev When a redemption must withdraw and split, the vault approves ConditionalTokens to pull the collateral; if
    /// that approve returns false the redemption reverts with ApproveFailed.
    function testRedeemRevertsOnFailedApprove() public {
        // Establish an invested position so the redeem path needs withdraw+split.
        _depositBad(ALICE, true, 100);
        _depositBad(BOB, false, 100); // fully matched -> 100 invested, NO side has no dangling

        uint256 bobShares = vault.sharesOf(badVault, conditionId, false, BOB);

        // Make the vault's approve to ConditionalTokens return false during the withdraw-and-split.
        badCollateral.setApproveRevertsFor(address(vault));

        vm.prank(BOB);
        vm.expectRevert(ApproveFailed.selector);
        vault.redeem(badVault, conditionId, false, bobShares, BOB, BOB);
    }

    /// @dev Directly exercises the `danglingBalance` getter: after an unmatched deposit it equals the deposited amount.
    function testDanglingBalanceGetter() public {
        _deposit(ALICE, true, 100); // default market, unmatched YES
        assertEq(vault.danglingBalance(defaultVault, conditionId, true), 100, "dangling reflects the unmatched deposit");
        assertEq(vault.danglingBalance(defaultVault, conditionId, false), 0, "opposite side has no dangling");
    }
}
