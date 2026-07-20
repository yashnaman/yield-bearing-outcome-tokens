// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {stdError} from "forge-std/StdError.sol";

import {BaseTest} from "test/BaseTest.sol";
import {YieldBearingOutcomeTokens} from "src/YieldBearingOutcomeTokens.sol";

/// @notice Tests for `transfer`, the pure share-bookkeeping move between users. Gated by the same morpho-blue-style
/// authorization as `redeem`: the owner itself, or an address it approved via `setAuthorization`.
contract TransferTest is BaseTest {
    event Transfer(
        bytes32 indexed id, bool isYes, address indexed caller, address onBehalf, address indexed to, uint256 shares
    );

    /// @dev The owner transferring its own shares needs no authorization; balances move, total shares don't.
    function testOwnerTransfers(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);
        uint256 totalBefore = vault.totalShares(defaultVault, conditionId, true);

        vm.prank(ALICE);
        vault.transfer(defaultVault, conditionId, true, shares, ALICE, BOB);

        assertEq(vault.sharesOf(defaultVault, conditionId, true, ALICE), 0, "sender's shares moved out");
        assertEq(vault.sharesOf(defaultVault, conditionId, true, BOB), shares, "recipient received the shares");
        assertEq(vault.totalShares(defaultVault, conditionId, true), totalBefore, "total shares unchanged");
    }

    /// @dev A partial transfer leaves the remainder with the sender.
    function testPartialTransfer(uint256 amount) public {
        amount = bound(amount, 2, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);
        uint256 sent = shares / 2;

        vm.prank(ALICE);
        vault.transfer(defaultVault, conditionId, true, sent, ALICE, BOB);

        assertEq(vault.sharesOf(defaultVault, conditionId, true, ALICE), shares - sent, "remainder stays with sender");
        assertEq(vault.sharesOf(defaultVault, conditionId, true, BOB), sent, "recipient received the sent amount");
    }

    /// @dev An unauthorized third party cannot move another holder's shares.
    function testUnauthorizedTransferReverts() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(BOB);
        vm.expectRevert(YieldBearingOutcomeTokens.Unauthorized.selector);
        vault.transfer(defaultVault, conditionId, true, shares, ALICE, BOB);

        assertEq(vault.sharesOf(defaultVault, conditionId, true, ALICE), shares, "Alice's shares untouched");
    }

    /// @dev Once Alice authorizes Bob, Bob can move Alice's shares to any recipient he likes.
    function testAuthorizedThirdPartyTransfers(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);

        vm.prank(ALICE);
        vault.setAuthorization(BOB, true);

        vm.prank(BOB);
        vault.transfer(defaultVault, conditionId, true, shares, ALICE, RECEIVER);

        assertEq(vault.sharesOf(defaultVault, conditionId, true, ALICE), 0, "Alice's shares moved");
        assertEq(vault.sharesOf(defaultVault, conditionId, true, RECEIVER), shares, "routed to the chosen receiver");
    }

    /// @dev Revoking authorization blocks a previously approved spender again.
    function testRevokedAuthorizationTransferReverts() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(ALICE);
        vault.setAuthorization(BOB, true);
        vm.prank(ALICE);
        vault.setAuthorization(BOB, false);

        vm.prank(BOB);
        vm.expectRevert(YieldBearingOutcomeTokens.Unauthorized.selector);
        vault.transfer(defaultVault, conditionId, true, shares, ALICE, BOB);
    }

    /// @dev Authorization gates `onBehalf`, not the recipient: Bob's grant from Carol gives him nothing over Alice.
    function testAuthorizationIsPerAuthorizer() public {
        uint256 aliceShares = _deposit(ALICE, true, 100);

        vm.prank(CAROL);
        vault.setAuthorization(BOB, true);

        vm.prank(BOB);
        vm.expectRevert(YieldBearingOutcomeTokens.Unauthorized.selector);
        vault.transfer(defaultVault, conditionId, true, aliceShares, ALICE, BOB);
    }

    /// @dev Transferring more shares than held reverts on the checked subtraction.
    function testTransferMoreThanBalanceReverts() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(ALICE);
        vm.expectRevert(stdError.arithmeticError);
        vault.transfer(defaultVault, conditionId, true, shares + 1, ALICE, BOB);
    }

    /// @dev Shares live per-side: a YES transfer never touches the sender's NO balance.
    function testTransferIsPerSide() public {
        uint256 yesShares = _deposit(ALICE, true, 100);
        uint256 noShares = _deposit(ALICE, false, 100);

        vm.prank(ALICE);
        vault.transfer(defaultVault, conditionId, true, yesShares, ALICE, BOB);

        assertEq(vault.sharesOf(defaultVault, conditionId, false, ALICE), noShares, "NO shares untouched");
        assertEq(vault.sharesOf(defaultVault, conditionId, false, BOB), 0, "no NO shares received");
    }

    /// @dev `transfer` emits with the market id, side, caller, share owner, recipient and amount.
    function testTransferEmits() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Transfer(id, true, ALICE, ALICE, BOB, shares);

        vm.prank(ALICE);
        vault.transfer(defaultVault, conditionId, true, shares, ALICE, BOB);
    }

    /// @dev `transfer` is the exact form of "redeem from `onBehalf` and re-deposit to `to` in the same tx". With a
    /// full position at par (no yield accrued) no rounding occurs, so the two paths are bit-for-bit identical: same
    /// shares minted to the recipient and same assets on final exit.
    function testTransferMatchesRedeemThenDeposit(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);
        _deposit(CAROL, false, amount); // matches ALICE's side into complete sets so the position is fully invested

        uint256 snap = vm.snapshotState();

        // Path A: plain transfer, then the recipient exits.
        vm.prank(ALICE);
        vault.transfer(defaultVault, conditionId, true, shares, ALICE, BOB);
        uint256 assetsTransfer = _redeem(BOB, true, shares);

        vm.revertToState(snap);

        // Path B: redeem ALICE's shares straight to BOB, BOB re-deposits the outcome tokens, then exits.
        vm.prank(ALICE);
        uint256 redeemed = vault.redeem(defaultVault, conditionId, true, shares, ALICE, BOB);
        vm.prank(BOB);
        ct.setApprovalForAll(address(vault), true);
        vm.prank(BOB);
        uint256 roundTripShares = vault.deposit(defaultVault, conditionId, true, redeemed, BOB);
        uint256 assetsRoundTrip = _redeem(BOB, true, roundTripShares);

        assertEq(roundTripShares, shares, "round trip mints exactly the transferred share count");
        assertEq(assetsRoundTrip, assetsTransfer, "both paths exit to identical assets");
    }

    /// @dev End-to-end: the recipient of a transfer can redeem the shares for the full deposit.
    function testRecipientCanRedeem(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);

        vm.prank(ALICE);
        vault.transfer(defaultVault, conditionId, true, shares, ALICE, BOB);

        uint256 assets = _redeem(BOB, true, shares);

        assertEq(assets, amount, "recipient redeems the transferred shares");
        assertEq(ct.balanceOf(BOB, yesPositionId), amount, "recipient holds the outcome tokens");
    }
}
