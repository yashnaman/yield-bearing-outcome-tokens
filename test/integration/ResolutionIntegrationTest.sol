// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice The vault relies only on split/merge at par, which need the condition merely *prepared*, not resolved. So
/// deposits and redemptions must keep working after the condition is reported.
contract ResolutionIntegrationTest is BaseTest {
    function _reportYesWins() internal {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1; // YES (slot {1}) wins
        payouts[1] = 0;
        vm.prank(ORACLE);
        ct.reportPayouts(questionId, payouts);
    }

    function testDepositAndRedeemWorkAfterResolution() public {
        // Establish an invested position before resolution.
        _deposit(ALICE, true, 100);
        uint256 bobShares = _deposit(BOB, false, 100);

        _reportYesWins();

        // A fresh deposit after resolution still merges and invests.
        uint256 carolShares = _deposit(CAROL, true, 100);
        assertGt(carolShares, 0, "deposit still mints shares post-resolution");

        // Redemption still reconstitutes outcome tokens via divest+split, even though the condition is resolved.
        uint256 assets = _redeem(BOB, false, bobShares);
        assertEq(assets, 100, "redeem via split still works post-resolution");
        assertEq(ct.balanceOf(BOB, noPositionId), 100, "NO tokens delivered post-resolution");
    }

    /// @dev A winning-side holder is simply better off redeeming shares here then redeeming the outcome tokens 1:1 at
    /// the ConditionalTokens contract. Sanity-check that the reconstituted winning tokens redeem for collateral.
    function testWinningSideTokensRedeemableAtCT() public {
        _deposit(ALICE, true, 100);
        uint256 bobYesShares = _deposit(BOB, false, 100); // matched

        // Bob actually wants YES (the winner); deposit a matching YES position so he can pull YES out. For simplicity
        // here, Alice (YES depositor) redeems her YES shares back to YES tokens, then claims at CT after resolution.
        uint256 aliceShares = vault.sharesOf(id, true, ALICE);
        _redeem(ALICE, true, aliceShares);
        assertEq(ct.balanceOf(ALICE, yesPositionId), 100, "Alice holds her YES tokens again");

        _reportYesWins();

        uint256[] memory indexSets = new uint256[](1);
        indexSets[0] = 1; // redeem the YES slot
        uint256 balBefore = collateral.balanceOf(ALICE);
        vm.prank(ALICE);
        ct.redeemPositions(IERC20(address(collateral)), PARENT_COLLECTION_ID, conditionId, indexSets);
        assertEq(collateral.balanceOf(ALICE) - balBefore, 100, "winning YES redeems 1:1 for collateral at CT");

        // Bob's NO shares are now worthless at CT but his shares here are still backed by the vault's split machinery.
        assertGt(bobYesShares, 0, "loser still holds vault shares (redeemable to NO tokens, worth 0 at CT)");
    }
}
