// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseTest} from "test/BaseTest.sol";

/// @notice Behavioural tests for `redeem`: the pay-from-dangling path, the divest-and-split path, round-trip safety,
/// events and reverts.
contract RedeemIntegrationTest is BaseTest {
    event Redeem(
        bytes32 indexed id, bool isYes, address indexed caller, address indexed to, uint256 shares, uint256 amount
    );

    /// @dev When the side still holds enough dangling tokens, redemption pays straight out without touching the adapter.
    function testRedeemFromDangling(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        uint256 shares = _deposit(ALICE, true, amount); // no opposite side, so everything stays dangling

        uint256 assets = _redeem(ALICE, true, shares);

        assertEq(assets, amount, "redeems exactly what was deposited");
        assertEq(adapter.investedBalance(marketParams), 0, "adapter untouched");
        assertEq(ct.balanceOf(ALICE, yesPositionId), amount, "outcome tokens returned to user");
        assertEq(vault.sharesOf(id, true, ALICE), 0, "shares burned");
    }

    /// @dev When the side's tokens were merged away, redemption must divest collateral and split it back into a fresh
    /// pair: the redeemer's side is paid and the opposite side is credited the freshly split dangling tokens.
    function testRedeemViaDivestAndSplit(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        _deposit(ALICE, true, amount);
        uint256 bobShares = _deposit(BOB, false, amount); // fully matched -> all invested, no dangling

        assertEq(_vaultPositionBalance(noPositionId), 0, "NO fully merged");

        uint256 assets = _redeem(BOB, false, bobShares);

        assertEq(assets, amount, "Bob reconstitutes his NO tokens");
        assertEq(ct.balanceOf(BOB, noPositionId), amount, "NO tokens delivered");
        // Splitting produced `amount` YES too, credited to the YES side as dangling.
        assertEq(_vaultPositionBalance(yesPositionId), amount, "opposite side credited the split YES tokens");
        assertEq(adapter.investedBalance(marketParams), 0, "collateral fully divested");
    }

    function testRedeemEmitsEvent() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Redeem(id, true, ALICE, RECEIVER, shares, 100);

        vm.prank(ALICE);
        uint256 assets = vault.redeem(marketParams, true, shares, RECEIVER);

        assertEq(assets, 100, "assets returned");
        assertEq(ct.balanceOf(RECEIVER, yesPositionId), 100, "tokens sent to `to`, not caller");
    }

    /// @dev The redeemed outcome tokens go to `to`, not the caller, for any receiver that can hold ERC1155.
    function testRedeemToFuzzedReceiver(address to, uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        // `to` must be able to receive ERC1155: an EOA (no code) and not the zero address.
        vm.assume(to != address(0) && to.code.length == 0);

        uint256 shares = _deposit(ALICE, true, amount); // unmatched, paid from dangling

        uint256 balBefore = ct.balanceOf(to, yesPositionId);
        vm.prank(ALICE);
        uint256 assets = vault.redeem(marketParams, true, shares, to);

        assertEq(assets, amount, "redeems the deposited amount");
        assertEq(ct.balanceOf(to, yesPositionId) - balBefore, amount, "outcome tokens delivered to receiver");
    }

    /// @dev Redeeming more shares than held underflows and reverts; no payout happens.
    function testRedeemMoreThanOwnedReverts() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(ALICE);
        vm.expectRevert();
        vault.redeem(marketParams, true, shares + 1, ALICE);
    }

    /// @dev A deposit immediately followed by a full redeem never returns more than was deposited (rounding favors the
    /// vault), across the full fuzz range.
    function testRoundTripNeverProfits(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        uint256 shares = _deposit(ALICE, true, amount);
        uint256 assets = _redeem(ALICE, true, shares);

        assertLe(assets, amount, "no value extracted on a round trip");
    }
}
