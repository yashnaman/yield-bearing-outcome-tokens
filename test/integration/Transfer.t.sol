// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {ERC6909} from "@openzeppelin/contracts/token/ERC6909/ERC6909.sol";
import {IERC6909} from "@openzeppelin/contracts/interfaces/IERC6909.sol";

import {BaseTest} from "test/Base.t.sol";

/// @notice Tests for share transfers, which are plain ERC-6909 moves on the factory rather than a bespoke `transfer`
/// entry point on the pool. Every market's shares live in that one ledger, under ids derived from the pool address and
/// the side, so a YES share and a NO share of one market are two ids among all markets' ids on one contract.
contract TransferTest is BaseTest {
    /// @dev The owner transferring its own shares needs no authorization; balances move, total supply doesn't.
    function testOwnerTransfers(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);
        uint256 totalBefore = factory.totalSupply(yesShareId);

        vm.prank(ALICE);
        factory.transfer(BOB, yesShareId, shares);

        assertEq(factory.balanceOf(ALICE, yesShareId), 0, "sender's shares moved out");
        assertEq(factory.balanceOf(BOB, yesShareId), shares, "recipient received the shares");
        assertEq(factory.totalSupply(yesShareId), totalBefore, "total supply unchanged");
    }

    /// @dev A partial transfer leaves the remainder with the sender.
    function testPartialTransfer(uint256 amount) public {
        amount = bound(amount, 2, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);
        uint256 sent = shares / 2;

        vm.prank(ALICE);
        factory.transfer(BOB, yesShareId, sent);

        assertEq(factory.balanceOf(ALICE, yesShareId), shares - sent, "remainder stays with sender");
        assertEq(factory.balanceOf(BOB, yesShareId), sent, "recipient received the sent amount");
    }

    /// @dev An unauthorized third party cannot move another holder's shares.
    function testUnauthorizedTransferFromReverts() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(ERC6909.ERC6909InsufficientAllowance.selector, BOB, 0, shares, yesShareId)
        );
        factory.transferFrom(ALICE, BOB, yesShareId, shares);

        assertEq(factory.balanceOf(ALICE, yesShareId), shares, "Alice's shares untouched");
    }

    /// @dev Once Alice makes Bob an operator, Bob can move Alice's shares to any recipient he likes.
    function testOperatorTransfersFrom(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);

        vm.prank(ALICE);
        factory.setOperator(BOB, true);

        vm.prank(BOB);
        factory.transferFrom(ALICE, RECEIVER, yesShareId, shares);

        assertEq(factory.balanceOf(ALICE, yesShareId), 0, "Alice's shares moved");
        assertEq(factory.balanceOf(RECEIVER, yesShareId), shares, "routed to the chosen receiver");
    }

    /// @dev Revoking the operator grant blocks a previously approved spender again.
    function testRevokedOperatorTransferReverts() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(ALICE);
        factory.setOperator(BOB, true);
        vm.prank(ALICE);
        factory.setOperator(BOB, false);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(ERC6909.ERC6909InsufficientAllowance.selector, BOB, 0, shares, yesShareId)
        );
        factory.transferFrom(ALICE, BOB, yesShareId, shares);
    }

    /// @dev A per-id allowance also authorizes a move, and is decremented by it.
    function testAllowanceAuthorizesTransferFrom() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(ALICE);
        factory.approve(BOB, yesShareId, shares);

        vm.prank(BOB);
        factory.transferFrom(ALICE, RECEIVER, yesShareId, shares / 2);

        assertEq(factory.allowance(ALICE, BOB, yesShareId), shares - shares / 2, "allowance spent down");
        assertEq(factory.balanceOf(RECEIVER, yesShareId), shares / 2, "recipient credited");
    }

    /// @dev Transferring more shares than held reverts with ERC-6909's balance error.
    function testTransferMoreThanBalanceReverts() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(ERC6909.ERC6909InsufficientBalance.selector, ALICE, shares, shares + 1, yesShareId)
        );
        factory.transfer(BOB, yesShareId, shares + 1);
    }

    /// @dev Shares live per-side: a YES transfer never touches the sender's NO balance.
    function testTransferIsPerSide() public {
        uint256 yesShares = _deposit(ALICE, true, 100);
        uint256 noShares = _deposit(ALICE, false, 100);

        vm.prank(ALICE);
        factory.transfer(BOB, yesShareId, yesShares);

        assertEq(factory.balanceOf(ALICE, noShareId), noShares, "NO shares untouched");
        assertEq(factory.balanceOf(BOB, noShareId), 0, "no NO shares received");
    }

    /// @dev Transfers emit ERC-6909's own event, from the factory that owns the ledger.
    function testTransferEmits() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.expectEmit(true, true, true, true, address(factory));
        emit IERC6909.Transfer(ALICE, ALICE, BOB, yesShareId, shares);

        vm.prank(ALICE);
        factory.transfer(BOB, yesShareId, shares);
    }

    /// @dev A transfer is the exact form of "redeem from the sender and re-deposit to the recipient in the same tx".
    /// With a full position at par (no yield accrued) no rounding occurs, so the two paths are bit-for-bit identical:
    /// same shares held by the recipient and same assets on final exit.
    function testTransferMatchesRedeemThenDeposit(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);
        _deposit(CAROL, false, amount); // matches ALICE's side into complete sets so the position is fully invested

        uint256 snap = vm.snapshotState();

        // Path A: plain transfer, then the recipient exits.
        vm.prank(ALICE);
        factory.transfer(BOB, yesShareId, shares);
        uint256 assetsTransfer = _redeem(BOB, true, shares);

        vm.revertToState(snap);

        // Path B: redeem ALICE's shares straight to BOB, BOB re-deposits the outcome tokens, then exits.
        vm.prank(ALICE);
        uint256 redeemed = pool.redeem(true, shares, ALICE, BOB);
        vm.prank(BOB);
        ct.setApprovalForAll(address(pool), true);
        uint256 roundTripShares = _depositAs(pool, BOB, true, redeemed, BOB);
        uint256 assetsRoundTrip = _redeem(BOB, true, roundTripShares);

        assertEq(roundTripShares, shares, "round trip mints exactly the transferred share count");
        assertEq(assetsRoundTrip, assetsTransfer, "both paths exit to identical assets");
    }

    /// @dev End-to-end: the recipient of a transfer can redeem the shares for the full deposit.
    function testRecipientCanRedeem(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);

        vm.prank(ALICE);
        factory.transfer(BOB, yesShareId, shares);

        uint256 assets = _redeem(BOB, true, shares);

        assertEq(assets, amount, "recipient redeems the transferred shares");
        assertEq(ct.balanceOf(BOB, yesPositionId), amount, "recipient holds the outcome tokens");
    }
}
