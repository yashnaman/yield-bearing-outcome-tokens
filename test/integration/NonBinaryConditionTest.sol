// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {YieldBearingOutcomeTokens} from "src/YieldBearingOutcomeTokens.sol";

/// @notice The vault hardcodes the binary `{1},{2}` partition, which only merges back into collateral on a condition
/// with exactly two outcome slots. Anything else is rejected outright at the `deposit` entry point, so a non-binary
/// market can never hold state: no shares, no dangling balances, nothing to redeem or transfer.
contract NonBinaryConditionTest is BaseTest {
    bytes32 internal conditionId3;

    function setUp() public override {
        super.setUp();

        ct.prepareCondition(ORACLE, keccak256("question-3-slots"), 3);
        conditionId3 = ct.getConditionId(ORACLE, keccak256("question-3-slots"), 3);
    }

    /// @dev Mints `amount` of each of the three singleton outcome slots ({1},{2},{4}) to `user` and approves the vault.
    function _giveThreeSlotTokens(address user, uint256 amount) internal {
        collateral.mint(user, amount);
        uint256[] memory partition = new uint256[](3);
        partition[0] = 1;
        partition[1] = 2;
        partition[2] = 4;
        vm.startPrank(user);
        collateral.approve(address(ct), amount);
        ct.splitPosition(IERC20(address(collateral)), PARENT_COLLECTION_ID, conditionId3, partition, amount);
        ct.setApprovalForAll(address(vault), true);
        vm.stopPrank();
    }

    function testDepositRejectsThreeSlotCondition() public {
        _giveThreeSlotTokens(ALICE, 100);

        vm.prank(ALICE);
        vm.expectRevert(YieldBearingOutcomeTokens.NotBinaryCondition.selector);
        vault.deposit(defaultVault, conditionId3, true, 100, ALICE);

        vm.prank(ALICE);
        vm.expectRevert(YieldBearingOutcomeTokens.NotBinaryCondition.selector);
        vault.deposit(defaultVault, conditionId3, false, 100, ALICE);
    }

    function testDepositRejectsUnpreparedCondition() public {
        vm.prank(ALICE);
        vm.expectRevert(YieldBearingOutcomeTokens.NotBinaryCondition.selector);
        vault.deposit(defaultVault, keccak256("never-prepared"), true, 100, ALICE);
    }

    /// @dev The rejection happens before any state change: the caller keeps their outcome tokens and the market
    /// stays completely empty.
    function testRejectedDepositLeavesNoState() public {
        _giveThreeSlotTokens(ALICE, 100);
        uint256 posId = _positionId(IERC20(address(collateral)), conditionId3, true);

        vm.prank(ALICE);
        vm.expectRevert(YieldBearingOutcomeTokens.NotBinaryCondition.selector);
        vault.deposit(defaultVault, conditionId3, true, 100, ALICE);

        assertEq(ct.balanceOf(ALICE, posId), 100, "Alice keeps her outcome tokens");
        assertEq(ct.balanceOf(address(vault), posId), 0, "vault pulled nothing");
        assertEq(vault.totalShares(defaultVault, conditionId3, true), 0, "no shares minted");
        assertEq(vault.danglingBalance(defaultVault, conditionId3, true), 0, "no dangling balance");
        assertEq(vault.investedBalance(defaultVault, conditionId3), 0, "nothing invested");
    }

    /// @dev The binary market on the same vault is unaffected.
    function testBinaryMarketStillWorks() public {
        _deposit(ALICE, true, 100);
        _deposit(BOB, false, 100);
        assertEq(vault.investedBalance(defaultVault, conditionId), 100, "binary market invests normally");
    }
}
