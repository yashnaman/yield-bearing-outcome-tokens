// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Tests the per-market invested-balance accounting: merged collateral deposited into a market's vault is
/// tracked against that market's id alone, so `investedBalance` reports only the querying market's funds and one market
/// can never withdraw another's — even when several markets share the same vault.
contract InvestedBalanceTest is BaseTest {
    // A second market that shares the default vault but uses a different condition, so it maps to a distinct id and
    // must be accounted independently.
    bytes32 internal conditionId2;

    function setUp() public override {
        super.setUp();

        bytes32 questionId2 = keccak256("invested-balance-question-2");
        ct.prepareCondition(ORACLE, questionId2, 2);
        conditionId2 = ct.getConditionId(ORACLE, questionId2, 2);
    }

    /// @dev Deposits a matched `amount` of YES and NO into the (`defaultVault`, `condition`) market so `amount`
    /// complete sets are merged and invested.
    function _investMatched(bytes32 condition, uint256 amount) internal {
        _mintOutcomeTokens(ALICE, IERC20(address(collateral)), condition, amount);
        vm.prank(ALICE);
        vault.deposit(defaultVault, condition, true, amount, ALICE);

        _mintOutcomeTokens(BOB, IERC20(address(collateral)), condition, amount);
        vm.prank(BOB);
        vault.deposit(defaultVault, condition, false, amount, BOB);
    }

    /// @dev A matched deposit invests the complete sets; a full redeem of both sides withdraws them again.
    function testInvestedBalanceReflectsMatchedDeposits() public {
        _investMatched(conditionId, 1000);
        assertEq(vault.investedBalance(defaultVault, conditionId), 1000, "matched sets invested");

        // Redeem both sides; the invested collateral is withdrawn back out and the balance drains to zero.
        uint256 aliceShares = vault.sharesOf(defaultVault, conditionId, true, ALICE);
        _redeem(ALICE, true, aliceShares);
        uint256 bobShares = vault.sharesOf(defaultVault, conditionId, false, BOB);
        _redeem(BOB, false, bobShares);

        assertEq(vault.investedBalance(defaultVault, conditionId), 0, "invested balance drained");
    }

    /// @dev Two markets sharing the default vault but on different conditions are accounted independently: querying or
    /// draining one leaves the other untouched, even though their collateral sits in the same vault.
    function testPerMarketAccountingIsIsolated() public {
        _investMatched(conditionId, 1000);
        _investMatched(conditionId2, 4000);

        assertEq(vault.investedBalance(defaultVault, conditionId), 1000, "market 1 unaffected by market 2");
        assertEq(vault.investedBalance(defaultVault, conditionId2), 4000, "market 2 tracked independently");

        // Fully draining market 1 leaves market 2 intact.
        _redeem(ALICE, true, vault.sharesOf(defaultVault, conditionId, true, ALICE));
        _redeem(BOB, false, vault.sharesOf(defaultVault, conditionId, false, BOB));

        assertEq(vault.investedBalance(defaultVault, conditionId), 0, "market 1 drained");
        assertEq(vault.investedBalance(defaultVault, conditionId2), 4000, "market 2 still fully funded");
    }
}
