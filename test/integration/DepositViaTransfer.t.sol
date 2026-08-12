// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/Base.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IOutcomeYieldPool} from "src/interface/IOutcomeYieldPool.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";

/// @notice Depositing by sending outcome tokens straight to the pool, rather than approving it and calling
/// {deposit}. `safeTransferFrom` on ConditionalTokens lands in {onERC1155Received}, which prices and credits the
/// deposit in the same transfer.
contract DepositViaTransferTest is BaseTest {
    /// @dev Mints `amount` of both sides to `user` without approving the pool — the whole point of this path is that
    /// no prior `setApprovalForAll` is needed.
    function _mintSetsNoApproval(address user, uint256 amount) internal {
        _mintOutcomeTokens(user, IERC20(address(collateral)), conditionId, amount, address(0xdead));
    }

    function _push(address user, uint256 positionId, uint256 amount, bytes memory data) internal {
        vm.prank(user);
        ct.safeTransferFrom(user, address(pool), positionId, amount, data);
    }

    /* CREDITING */

    /// @dev Empty `data` credits the account the tokens came from. Routed through `_poolPositionId(pool, true)` — the
    /// off-chain derivation — rather than the fixture's cached id, since finding where to send tokens is exactly what a
    /// depositor must now do for itself.
    function testTransferWithNoDataCreditsSender(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        _mintSetsNoApproval(ALICE, amount);

        _push(ALICE, _poolPositionId(pool, true), amount, "");

        assertEq(_sharesOf(ALICE, true), amount * VIRTUAL_SHARES, "Alice credited the shares");
        assertEq(_dangling(pool, true), amount, "the pool holds the tokens");
    }

    /// @dev Non-empty `data` is the account to credit, which is how a router deposits for a user.
    function testTransferWithDataCreditsEncodedRecipient(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        _mintSetsNoApproval(ALICE, amount);

        _push(ALICE, noPositionId, amount, abi.encode(BOB));

        assertEq(_sharesOf(BOB, false), amount * VIRTUAL_SHARES, "Bob credited the shares");
        assertEq(_sharesOf(ALICE, false), 0, "Alice credited nothing");
    }

    /// @dev The event names the token sender as the caller, not ConditionalTokens.
    function testTransferEmitsDepositWithSenderAsCaller() public {
        _mintSetsNoApproval(ALICE, 1000);

        vm.expectEmit(true, true, true, true, address(pool));
        emit IOutcomeYieldPool.Deposit(true, ALICE, BOB, 1000, 1000 * VIRTUAL_SHARES);
        _push(ALICE, yesPositionId, 1000, abi.encode(BOB));
    }

    /// @dev The two entry points are the same deposit. Pricing must not differ just because the tokens arrived by a
    /// push rather than a pull — this is what the `- assets` netting in `_deposit` is for.
    function testPushAndPullPriceIdentically(uint256 seed, uint256 amount) public {
        seed = bound(seed, MIN_TEST_AMOUNT, 1e24);
        amount = bound(amount, MIN_TEST_AMOUNT, 1e24);

        // Seed the side so the share price is not 1:1, then deposit the same amount both ways.
        _deposit(CAROL, true, seed);
        _accrueYield(seed);

        _mintSetsNoApproval(ALICE, amount);
        _push(ALICE, yesPositionId, amount, "");
        uint256 pushed = _sharesOf(ALICE, true);

        uint256 pulled = _deposit(BOB, true, amount);

        assertApproxEqAbs(pushed, pulled, 1, "push and pull price the same deposit alike");
    }

    /* REBALANCING */

    /// @dev A pushed deposit rebalances exactly like a pulled one: matching the other side merges and invests.
    function testPushedDepositTriggersTheMerge() public {
        _mintSetsNoApproval(ALICE, 1000);
        _mintSetsNoApproval(BOB, 1000);

        _push(ALICE, yesPositionId, 1000, "");
        assertEq(_invested(pool), 0, "nothing to match yet");

        _push(BOB, noPositionId, 1000, "");
        assertEq(_invested(pool), 1000, "the matched pair was merged and invested");
        assertEq(_dangling(pool, true), 0, "YES fully merged");
        assertEq(_dangling(pool, false), 0, "NO fully merged");
    }

    /// @dev And the position is still redeemable afterwards, which exercises the `splitPosition` batch mint back
    /// into the pool — the one batch receive the pool must keep accepting.
    function testPushedDepositIsRedeemable() public {
        _mintSetsNoApproval(ALICE, 1000);
        _mintSetsNoApproval(BOB, 1000);
        _push(ALICE, yesPositionId, 1000, "");
        _push(BOB, noPositionId, 1000, "");

        uint256 shares = _sharesOf(ALICE, true);
        vm.prank(ALICE);
        uint256 assets = pool.redeem(true, shares, ALICE, ALICE);

        assertEq(assets, 1000, "Alice redeems the full deposit through the withdraw-and-split path");
        assertEq(ct.balanceOf(ALICE, yesPositionId), 1000, "and holds the outcome tokens");
    }

    /* REJECTIONS */

    /// @dev An id this pool does not serve is rejected outright. It is never assumed to be "the other side": the
    /// tokens would be credited against a supply they do not back.
    function testForeignPositionIdIsRejected() public {
        Market memory other = _createMarket(defaultVault, keccak256("some-other-market"));
        uint256 foreignId = _positionId(IERC20(address(collateral)), other.conditionId, true);

        _mintOutcomeTokens(ALICE, IERC20(address(collateral)), other.conditionId, 1000, address(0xdead));

        vm.prank(ALICE);
        vm.expectRevert(IOutcomeYieldPool.UnknownPositionId.selector);
        ct.safeTransferFrom(ALICE, address(pool), foreignId, 1000, "");
    }

    /// @dev Batch transfers from anyone but the pool itself are rejected: a batch carries both sides at once, and
    /// each side is priced against its own supply, so there is no single deposit to credit it as.
    function testBatchTransferFromThirdPartyIsRejected() public {
        _mintSetsNoApproval(ALICE, 1000);

        uint256[] memory ids = new uint256[](2);
        ids[0] = yesPositionId;
        ids[1] = noPositionId;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1000;
        amounts[1] = 1000;

        vm.prank(ALICE);
        vm.expectRevert(IOutcomeYieldPool.BatchDepositNotSupported.selector);
        ct.safeBatchTransferFrom(ALICE, address(pool), ids, amounts, "");
    }

    /// @dev Redeeming with the pool itself as `to` collapses to a self-transfer, which moves nothing. It must not be
    /// re-credited as a deposit: there is no new backing, so pricing shares against it would mint them out of thin
    /// air and dilute everyone. The tokens just stay dangling, which is what naming the pool asked for.
    function testRedeemingToThePoolCreditsNoDeposit() public {
        _mintSetsNoApproval(ALICE, 1000);
        _mintSetsNoApproval(BOB, 1000);
        _push(ALICE, yesPositionId, 1000, "");
        _push(BOB, noPositionId, 1000, "");

        uint256 bobShares = _sharesOf(BOB, false);
        uint256 aliceShares = _sharesOf(ALICE, true);
        uint256 supplyBefore = factory.totalSupply(noShareId);

        vm.prank(BOB);
        pool.redeem(false, bobShares, BOB, address(pool));

        assertEq(factory.totalSupply(noShareId), supplyBefore - bobShares, "only Bob's burn moved the supply");
        assertEq(_sharesOf(address(pool), false), 0, "the pool was credited nothing");
        assertEq(_sharesOf(address(pool), true), 0, "and nothing on the other side either");

        // Bob gave his position away; Alice's claim is unharmed and still redeemable.
        vm.prank(ALICE);
        uint256 aliceAssets = pool.redeem(true, aliceShares, ALICE, ALICE);
        assertEq(aliceAssets, 1000, "Alice is not diluted by Bob's mistake");
    }

    /// @dev Malformed `data` reverts rather than silently falling back to the sender.
    function testMalformedDataReverts() public {
        _mintSetsNoApproval(ALICE, 1000);

        vm.prank(ALICE);
        vm.expectRevert();
        ct.safeTransferFrom(ALICE, address(pool), yesPositionId, 1000, hex"1234");
    }
}
