// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {YieldBearingOutcomeTokens} from "src/YieldBearingOutcomeTokens.sol";

/// @notice Tests for the morpho-blue-style authorization that lets an approved address redeem on behalf of a share
/// owner. `redeem` burns the `onBehalf` owner's shares and is gated by `_isSenderAuthorized(onBehalf)`.
contract AuthorizationTest is BaseTest {
    event SetAuthorization(address indexed authorizer, address indexed authorized, bool newIsAuthorized);

    /// @dev The owner redeeming its own shares needs no authorization.
    function testOwnerRedeemsWithoutAuthorization(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);

        vm.prank(ALICE);
        uint256 assets = vault.redeem(defaultVault, conditionId, true, shares, ALICE, ALICE);

        assertEq(assets, amount, "owner redeems own shares");
        assertEq(vault.sharesOf(id, true, ALICE), 0, "shares burned");
    }

    /// @dev An unauthorized third party cannot redeem another holder's shares.
    function testUnauthorizedRedeemReverts() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(BOB);
        vm.expectRevert(YieldBearingOutcomeTokens.Unauthorized.selector);
        vault.redeem(defaultVault, conditionId, true, shares, ALICE, BOB);

        assertEq(vault.sharesOf(id, true, ALICE), shares, "Alice's shares untouched");
    }

    /// @dev Once Alice authorizes Bob, Bob can burn Alice's shares and route the tokens wherever he likes.
    function testAuthorizedThirdPartyRedeems(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);

        vm.prank(ALICE);
        vault.setAuthorization(BOB, true);
        assertTrue(vault.isAuthorized(ALICE, BOB), "authorization recorded");

        // Bob redeems Alice's shares; tokens are delivered to RECEIVER.
        vm.prank(BOB);
        uint256 assets = vault.redeem(defaultVault, conditionId, true, shares, ALICE, RECEIVER);

        assertEq(assets, amount, "authorized party redeems on behalf");
        assertEq(vault.sharesOf(id, true, ALICE), 0, "Alice's shares burned, not Bob's");
        assertEq(ct.balanceOf(RECEIVER, yesPositionId), amount, "tokens routed to the chosen receiver");
    }

    /// @dev Revoking authorization blocks a previously approved spender again.
    function testRevokedAuthorizationReverts() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(ALICE);
        vault.setAuthorization(BOB, true);
        vm.prank(ALICE);
        vault.setAuthorization(BOB, false);
        assertFalse(vault.isAuthorized(ALICE, BOB), "authorization revoked");

        vm.prank(BOB);
        vm.expectRevert(YieldBearingOutcomeTokens.Unauthorized.selector);
        vault.redeem(defaultVault, conditionId, true, shares, ALICE, BOB);
    }

    /// @dev Authorization is directional and per-authorizer: Bob authorizing Carol does not let Carol spend Alice's
    /// shares, and Alice authorizing Bob does not let Alice spend Bob's shares.
    function testAuthorizationIsPerAuthorizer() public {
        uint256 aliceShares = _deposit(ALICE, true, 100);
        _deposit(BOB, true, 100);

        // Carol is authorized by Bob, but tries to spend Alice's shares.
        vm.prank(BOB);
        vault.setAuthorization(CAROL, true);
        vm.prank(CAROL);
        vm.expectRevert(YieldBearingOutcomeTokens.Unauthorized.selector);
        vault.redeem(defaultVault, conditionId, true, aliceShares, ALICE, CAROL);

        // Alice authorizing Bob grants Bob nothing over his own grant direction: Alice still can't spend Bob's shares.
        vm.prank(ALICE);
        vault.setAuthorization(BOB, true);
        vm.prank(ALICE);
        vm.expectRevert(YieldBearingOutcomeTokens.Unauthorized.selector);
        vault.redeem(defaultVault, conditionId, true, 100, BOB, ALICE);
    }

    /// @dev `setAuthorization` emits with the authorizer (msg.sender), the authorized address and the new status.
    function testSetAuthorizationEmits() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit SetAuthorization(ALICE, BOB, true);

        vm.prank(ALICE);
        vault.setAuthorization(BOB, true);
    }

    /// @dev Setting the value already in storage reverts, mirroring morpho-blue's `ALREADY_SET` guard.
    function testSetAuthorizationToSameValueReverts() public {
        // Default is false; setting false again reverts.
        vm.prank(ALICE);
        vm.expectRevert(YieldBearingOutcomeTokens.AlreadySet.selector);
        vault.setAuthorization(BOB, false);

        vm.prank(ALICE);
        vault.setAuthorization(BOB, true);
        vm.prank(ALICE);
        vm.expectRevert(YieldBearingOutcomeTokens.AlreadySet.selector);
        vault.setAuthorization(BOB, true);
    }
}
