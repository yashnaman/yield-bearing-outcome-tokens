// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/Base.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";
import {ConfigurableERC20} from "test/mocks/ConfigurableERC20.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";
import {IOutcomeYieldPool} from "src/interface/IOutcomeYieldPool.sol";

/// @notice Covers the pool's raw-bool collateral failure path, which only triggers when a non-conforming token's
/// `approve` returns false. A `ConfigurableERC20` is used as collateral and made to fail only for the pool's own call,
/// so ConditionalTokens' split/merge and the user's approvals still work.
/// @dev Both collateral approvals now live in the pool's constructor rather than on the merge and redeem hot paths, so
/// a token that cannot be approved is rejected once at deployment instead of silently deferring merges forever. These
/// tests pin that relocation.
contract RevertPathsTest is BaseTest {
    ConfigurableERC20 internal badCollateral;
    IERC4626 internal badVault;

    function setUp() public override {
        super.setUp();

        badCollateral = new ConfigurableERC20("Bad", "BAD");
        badVault = IERC4626(address(new MockERC4626(IERC20(address(badCollateral)))));
    }

    /// @dev Splits `amount` of the bad collateral into a YES/NO pair for `user` and approves `operator`.
    function _giveBadOutcomeTokens(address user, uint256 amount, address operator) internal {
        badCollateral.mint(user, amount);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        vm.startPrank(user);
        badCollateral.approve(address(ct), amount);
        ct.splitPosition(IERC20(address(badCollateral)), PARENT_COLLECTION_ID, conditionId, partition, amount);
        ct.setApprovalForAll(operator, true);
        vm.stopPrank();
    }

    /// @dev A collateral whose `approve` returns false cannot back a pool at all: the constructor's approval to
    /// ConditionalTokens fails and the deployment reverts, so no market is ever created against it.
    function testDeployRevertsWhenCollateralApproveFails() public {
        // The failing caller is the pool address the factory is about to deploy to, which is deterministic.
        address predicted = factory.getPoolAddress(badVault, conditionId);
        badCollateral.setApproveRevertsFor(predicted);

        vm.expectRevert(IOutcomeYieldPool.ApproveFailed.selector);
        factory.deployPool(badVault, conditionId);

        assertEq(predicted.code.length, 0, "no pool exists at the predicted address");
    }

    /// @dev Once the pool has been deployed with working approvals, they are permanent: the token can start refusing
    /// `approve` afterwards and every merge and redemption keeps working, because neither path approves again.
    function testHotPathsSurviveLaterApproveFailure() public {
        OutcomeYieldPool badPool = factory.deployPool(badVault, conditionId);

        _giveBadOutcomeTokens(ALICE, 100, address(badPool));
        vm.prank(ALICE);
        badPool.deposit(true, 100, ALICE);

        // From here on the collateral refuses every approve from the pool.
        badCollateral.setApproveRevertsFor(address(badPool));

        _giveBadOutcomeTokens(BOB, 100, address(badPool));
        uint256 bobShares = _depositAs(badPool, BOB, false, 100, BOB);

        assertEq(_invested(badPool), 100, "the merge still invests with no fresh approve");
        assertEq(_dangling(badPool, true), 0, "YES fully matched");
        assertEq(_dangling(badPool, false), 0, "NO fully matched");

        // And the withdraw-and-split path, which used to approve ConditionalTokens per call, also still works.
        vm.prank(BOB);
        uint256 assets = badPool.redeem(false, bobShares, BOB, BOB);
        assertEq(assets, 100, "Bob still exits in full");
    }

    /// @dev Directly exercises the `danglingBalance` getter: after an unmatched deposit it equals the deposited amount.
    function testDanglingBalanceGetter() public {
        _deposit(ALICE, true, 100); // default market, unmatched YES
        assertEq(_dangling(pool, true), 100, "dangling reflects the unmatched deposit");
        assertEq(_dangling(pool, false), 0, "opposite side has no dangling");
    }
}
