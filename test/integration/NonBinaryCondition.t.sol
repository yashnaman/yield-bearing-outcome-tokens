// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/Base.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";
import {IOutcomeYieldPool} from "src/interface/IOutcomeYieldPool.sol";

/// @notice The pool hardcodes the binary `{1},{2}` partition, which only merges back into collateral on a condition
/// with exactly two outcome slots. Anything else is rejected in the pool's constructor, so a non-binary market cannot
/// be deployed at all: there is no contract to deposit into, no shares, no dangling balances, nothing to redeem.
/// @dev This is stricter than the singleton it replaces, which rejected non-binary conditions per `deposit` call and
/// therefore had to be trusted to check on every entry point. The check now runs once and the market simply never
/// exists.
contract NonBinaryConditionTest is BaseTest {
    bytes32 internal conditionId3;

    function setUp() public override {
        super.setUp();

        ct.prepareCondition(ORACLE, keccak256("question-3-slots"), 3);
        conditionId3 = ct.getConditionId(ORACLE, keccak256("question-3-slots"), 3);
    }

    function testDeployRejectsThreeSlotCondition() public {
        vm.expectRevert(IOutcomeYieldPool.NotBinaryCondition.selector);
        factory.deployPool(defaultVault, conditionId3);
    }

    function testDeployRejectsUnpreparedCondition() public {
        vm.expectRevert(IOutcomeYieldPool.NotBinaryCondition.selector);
        factory.deployPool(defaultVault, keccak256("never-prepared"));
    }

    /// @dev The rejection leaves nothing behind: no code at the deterministic address, so there is no contract for a
    /// three-slot market's outcome tokens to be deposited into.
    function testRejectedDeploymentLeavesNoContract() public {
        address predicted = factory.getPoolAddress(defaultVault, conditionId3);

        vm.expectRevert(IOutcomeYieldPool.NotBinaryCondition.selector);
        factory.deployPool(defaultVault, conditionId3);

        assertEq(predicted.code.length, 0, "no pool deployed for the non-binary market");
    }

    /// @dev A three-slot market's outcome tokens cannot reach the binary market's pool either: they carry a different
    /// position id, so the pool would never mint shares against them even if they were sent to it directly.
    function testThreeSlotTokensAreNotTheBinaryPoolsPositionIds() public view {
        uint256 threeSlotYes = _positionId(IERC20(address(collateral)), conditionId3, true);

        assertTrue(threeSlotYes != _poolPositionId(pool, true), "distinct from the binary pool's YES id");
        assertTrue(threeSlotYes != _poolPositionId(pool, false), "distinct from the binary pool's NO id");
    }

    /// @dev The binary market on the same vault is unaffected.
    function testBinaryMarketStillWorks() public {
        _deposit(ALICE, true, 100);
        _deposit(BOB, false, 100);
        assertEq(_invested(pool), 100, "binary market invests normally");
    }
}
