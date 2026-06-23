// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";

/// @notice The vault hardcodes the binary `{1},{2}` partition. On a condition with more than two outcome slots,
/// merging `{1},{2}` mints a *combined* position instead of returning collateral, so the merge-and-invest step has no
/// collateral to forward and the matching deposit reverts. This test pins down the documented guarantee that such a
/// failed deposit causes no self-harm: the outcome tokens already deposited on the other side stay fully redeemable.
contract NonBinaryConditionTest is BaseTest {
    bytes32 internal questionId3;
    bytes32 internal conditionId3;
    IYieldBearingOutcomeTokens.MarketParams internal market3;

    function setUp() public override {
        super.setUp();

        questionId3 = keccak256("question-3-slots");
        ct.prepareCondition(ORACLE, questionId3, 3);
        conditionId3 = ct.getConditionId(ORACLE, questionId3, 3);

        market3 = IYieldBearingOutcomeTokens.MarketParams({
            collateralToken: IERC20(address(collateral)),
            conditionId: conditionId3,
            vaultAdapter: IVaultAdapter(address(adapter))
        });
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

    function testMatchingDepositRevertsAndOtherSideStaysRedeemable() public {
        // Alice deposits the {1} side. No opposite side yet, so nothing merges and the deposit succeeds.
        _giveThreeSlotTokens(ALICE, 100);
        vm.prank(ALICE);
        uint256 aliceShares = vault.deposit(market3, true, 100, ALICE);
        assertGt(aliceShares, 0, "first deposit mints shares");

        // Bob deposits the {2} side. This matches a complete set and triggers the merge, which on a 3-slot condition
        // mints the combined {1,2} position rather than collateral; the vault then has no collateral to forward and
        // the deposit reverts.
        _giveThreeSlotTokens(BOB, 100);
        vm.prank(BOB);
        vm.expectRevert();
        vault.deposit(market3, false, 100, BOB);

        // The revert rolled Bob's deposit back entirely (including the token pull), and Alice's {1} position is intact
        // and fully redeemable.
        vm.prank(ALICE);
        uint256 got = vault.redeem(market3, true, aliceShares, ALICE, ALICE);
        assertEq(got, 100, "first side fully redeemable after the failed match");
        assertEq(
            ct.balanceOf(ALICE, _positionId(IERC20(address(collateral)), conditionId3, true)),
            100,
            "Alice recovered her {1} outcome tokens"
        );
    }
}
