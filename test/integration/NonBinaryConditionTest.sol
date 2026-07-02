// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice The vault hardcodes the binary `{1},{2}` partition. On a condition with more than two outcome slots,
/// merging `{1},{2}` mints a *combined* position instead of returning collateral, so the merge-and-invest step has no
/// collateral to deposit into the vault; that failure is caught and the merge deferred. This test pins down the
/// documented guarantee that such a market causes no self-harm: it never invests, but every deposit stays dangling and
/// fully redeemable on both sides.
contract NonBinaryConditionTest is BaseTest {
    bytes32 internal questionId3;
    bytes32 internal conditionId3;

    function setUp() public override {
        super.setUp();

        questionId3 = keccak256("question-3-slots");
        ct.prepareCondition(ORACLE, questionId3, 3);
        conditionId3 = ct.getConditionId(ORACLE, questionId3, 3);
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

    function testMatchingDepositDefersAndBothSidesStayRedeemable() public {
        // Alice deposits the {1} side. No opposite side yet, so nothing merges and the deposit succeeds.
        _giveThreeSlotTokens(ALICE, 100);
        vm.prank(ALICE);
        uint256 aliceShares = vault.deposit(defaultVault, conditionId3, true, 100, ALICE);
        assertGt(aliceShares, 0, "first deposit mints shares");

        // Bob deposits the {2} side. This matches a complete set and triggers the merge, which on a 3-slot condition
        // mints the combined {1,2} position rather than collateral; the vault then has no collateral to forward, the
        // merge attempt reverts internally and is deferred, and Bob's deposit succeeds with both sides dangling.
        _giveThreeSlotTokens(BOB, 100);
        vm.prank(BOB);
        uint256 bobShares = vault.deposit(defaultVault, conditionId3, false, 100, BOB);
        assertGt(bobShares, 0, "matching deposit succeeds despite the impossible merge");

        assertEq(vault.danglingBalance(defaultVault, conditionId3, true), 100, "{1} side fully dangling");
        assertEq(vault.danglingBalance(defaultVault, conditionId3, false), 100, "{2} side fully dangling");
        assertEq(vault.investedBalance(defaultVault, conditionId3), 0, "a non-binary market never invests");

        // Both sides stay fully redeemable from their dangling balances.
        vm.prank(ALICE);
        uint256 aliceGot = vault.redeem(defaultVault, conditionId3, true, aliceShares, ALICE, ALICE);
        assertEq(aliceGot, 100, "{1} side fully redeemable");
        assertEq(
            ct.balanceOf(ALICE, _positionId(IERC20(address(collateral)), conditionId3, true)),
            100,
            "Alice recovered her {1} outcome tokens"
        );

        vm.prank(BOB);
        uint256 bobGot = vault.redeem(defaultVault, conditionId3, false, bobShares, BOB, BOB);
        assertEq(bobGot, 100, "{2} side fully redeemable");
        assertEq(
            ct.balanceOf(BOB, _positionId(IERC20(address(collateral)), conditionId3, false)),
            100,
            "Bob recovered his {2} outcome tokens"
        );
    }
}
