// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {ERC6909} from "@openzeppelin/contracts/token/ERC6909/ERC6909.sol";
import {IERC6909} from "@openzeppelin/contracts/interfaces/IERC6909.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {BaseTest} from "test/Base.t.sol";

/// @notice Tests for redeeming on behalf of a share owner. The bespoke `setAuthorization` ledger is gone: shares are
/// ERC-6909 tokens on the *factory*, so `redeem` gates `onBehalf` exactly the way ERC-6909's own `transferFrom` does —
/// the owner acts freely, an operator acts freely, and anyone else spends a per-id allowance.
/// @dev Because the ledger is shared, an operator grant is made once and covers every market. A per-id `approve` is
/// still the narrow tool: it names one side of one market.
contract AuthorizationTest is BaseTest {
    /// @dev The owner redeeming its own shares needs no authorization.
    function testOwnerRedeemsWithoutAuthorization(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);

        vm.prank(ALICE);
        uint256 assets = pool.redeem(true, shares, ALICE, ALICE);

        assertEq(assets, amount, "owner redeems own shares");
        assertEq(factory.balanceOf(ALICE, yesShareId), 0, "shares burned");
    }

    /// @dev An unauthorized third party cannot redeem another holder's shares: with no allowance and no operator
    /// grant, `_spendAllowance` reverts.
    function testUnauthorizedRedeemReverts() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(ERC6909.ERC6909InsufficientAllowance.selector, BOB, 0, shares, yesShareId)
        );
        pool.redeem(true, shares, ALICE, BOB);

        assertEq(factory.balanceOf(ALICE, yesShareId), shares, "Alice's shares untouched");
    }

    /// @dev Once Alice makes Bob an operator, Bob can burn Alice's shares and route the tokens wherever he likes.
    function testOperatorRedeems(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        uint256 shares = _deposit(ALICE, true, amount);

        vm.prank(ALICE);
        factory.setOperator(BOB, true);
        assertTrue(factory.isOperator(ALICE, BOB), "operator recorded");

        // Bob redeems Alice's shares; tokens are delivered to RECEIVER.
        vm.prank(BOB);
        uint256 assets = pool.redeem(true, shares, ALICE, RECEIVER);

        assertEq(assets, amount, "operator redeems on behalf");
        assertEq(factory.balanceOf(ALICE, yesShareId), 0, "Alice's shares burned, not Bob's");
        assertEq(ct.balanceOf(RECEIVER, yesPositionId), amount, "tokens routed to the chosen receiver");
    }

    /// @dev An operator's reach is unlimited but revocable: revoking blocks a previously approved spender again.
    function testRevokedOperatorReverts() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(ALICE);
        factory.setOperator(BOB, true);
        vm.prank(ALICE);
        factory.setOperator(BOB, false);
        assertFalse(factory.isOperator(ALICE, BOB), "operator revoked");

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(ERC6909.ERC6909InsufficientAllowance.selector, BOB, 0, shares, yesShareId)
        );
        pool.redeem(true, shares, ALICE, BOB);
    }

    /// @dev A per-id allowance is a narrower grant than an operator: it covers exactly one side and is spent down as
    /// it is used. This is coverage the bespoke boolean `isAuthorized` could not express at all.
    function testAllowanceIsSpentDownOnPartialRedeem() public {
        uint256 shares = _deposit(ALICE, true, 1000);

        vm.prank(ALICE);
        factory.approve(BOB, yesShareId, shares);

        vm.prank(BOB);
        pool.redeem(true, shares / 4, ALICE, BOB);

        assertEq(factory.allowance(ALICE, BOB, yesShareId), shares - shares / 4, "allowance decremented by the spend");
        assertEq(factory.balanceOf(ALICE, yesShareId), shares - shares / 4, "only the spent quarter was burned");
    }

    /// @dev An infinite allowance is not decremented, matching ERC-6909's own `_spendAllowance`.
    function testInfiniteAllowanceIsNotDecremented() public {
        uint256 shares = _deposit(ALICE, true, 1000);

        vm.prank(ALICE);
        factory.approve(BOB, yesShareId, type(uint256).max);

        vm.prank(BOB);
        pool.redeem(true, shares / 2, ALICE, BOB);

        assertEq(factory.allowance(ALICE, BOB, yesShareId), type(uint256).max, "infinite allowance untouched");
    }

    /// @dev An allowance is per token id, so a YES grant buys nothing on the NO side.
    function testAllowanceIsPerSide() public {
        _deposit(ALICE, true, 100);
        uint256 noShares = _deposit(ALICE, false, 100);

        vm.prank(ALICE);
        factory.approve(BOB, yesShareId, type(uint256).max);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(ERC6909.ERC6909InsufficientAllowance.selector, BOB, 0, noShares, noShareId)
        );
        pool.redeem(false, noShares, ALICE, BOB);
    }

    /// @dev Authorization is directional and per-owner: Bob's grant from Carol gives him nothing over Alice's shares.
    function testAuthorizationIsPerOwner() public {
        uint256 aliceShares = _deposit(ALICE, true, 100);

        vm.prank(CAROL);
        factory.setOperator(BOB, true);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(ERC6909.ERC6909InsufficientAllowance.selector, BOB, 0, aliceShares, yesShareId)
        );
        pool.redeem(true, aliceShares, ALICE, BOB);
    }

    /// @dev The ledger is shared, so one `setOperator` covers every market. This is the point of holding shares on the
    /// factory: a user active in ten markets signs one grant, not ten.
    function testOperatorGrantCoversEveryMarket() public {
        bytes32 question2 = keccak256("authorization-question-2");
        Market memory m = _createMarket(defaultVault, question2);

        uint256 defaultShares = _deposit(ALICE, true, 100);

        _mintOutcomeTokens(ALICE, IERC20(address(collateral)), m.conditionId, 100, address(m.pool));
        uint256 otherShares = _depositAs(m.pool, ALICE, true, 100, ALICE);

        // One grant, made once, on the factory.
        vm.prank(ALICE);
        factory.setOperator(BOB, true);

        // Bob can act on both markets without a second signature from Alice.
        vm.prank(BOB);
        pool.redeem(true, defaultShares, ALICE, BOB);
        vm.prank(BOB);
        m.pool.redeem(true, otherShares, ALICE, BOB);

        assertEq(factory.balanceOf(ALICE, yesShareId), 0, "default market drained under the shared grant");
        assertEq(factory.balanceOf(ALICE, _shareId(m.pool, true)), 0, "and so is the second market");
    }

    /// @dev A per-id allowance stays narrow even though the ledger is shared: it names one side of one market, so it
    /// buys nothing on a different pool.
    function testAllowanceDoesNotCrossPools() public {
        bytes32 question2 = keccak256("authorization-allowance-question");
        Market memory m = _createMarket(defaultVault, question2);

        _mintOutcomeTokens(ALICE, IERC20(address(collateral)), m.conditionId, 100, address(m.pool));
        uint256 otherShares = _depositAs(m.pool, ALICE, true, 100, ALICE);

        // Alice approves Bob generously, but only on the default market's YES id.
        vm.prank(ALICE);
        factory.approve(BOB, yesShareId, type(uint256).max);

        uint256 otherId = _shareId(m.pool, true);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(ERC6909.ERC6909InsufficientAllowance.selector, BOB, 0, otherShares, otherId)
        );
        m.pool.redeem(true, otherShares, ALICE, BOB);
    }

    /// @dev `setOperator` emits ERC-6909's own event, from the factory that owns the ledger.
    function testSetOperatorEmits() public {
        vm.expectEmit(true, true, true, true, address(factory));
        emit IERC6909.OperatorSet(ALICE, BOB, true);

        vm.prank(ALICE);
        factory.setOperator(BOB, true);
    }
}
