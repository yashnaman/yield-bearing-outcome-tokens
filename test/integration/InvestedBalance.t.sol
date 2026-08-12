// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/Base.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";

/// @notice Tests per-market invested-balance accounting. Merged collateral deposited into a market's vault is now held
/// by that market's own pool contract, so `investedBalance` is simply that pool's vault-share position converted back
/// to assets — one market can never withdraw another's, even when several markets share the same ERC-4626 vault.
contract InvestedBalanceTest is BaseTest {
    // A second market that shares the default vault but uses a different condition, so it gets its own pool and must
    // be accounted independently.
    bytes32 internal conditionId2;
    OutcomeYieldPool internal pool2;

    function setUp() public override {
        super.setUp();

        bytes32 questionId2 = keccak256("invested-balance-question-2");
        ct.prepareCondition(ORACLE, questionId2, 2);
        conditionId2 = ct.getConditionId(ORACLE, questionId2, 2);

        pool2 = factory.deployPool(defaultVault, conditionId2);
        vm.label(address(pool2), "Pool2");
    }

    /// @dev Deposits a matched `amount` of YES and NO into `market` so `amount` complete sets are merged and invested.
    function _investMatched(OutcomeYieldPool market, bytes32 condition, uint256 amount) internal {
        _mintOutcomeTokens(ALICE, IERC20(address(collateral)), condition, amount, address(market));
        vm.prank(ALICE);
        market.deposit(true, amount, ALICE);

        _mintOutcomeTokens(BOB, IERC20(address(collateral)), condition, amount, address(market));
        vm.prank(BOB);
        market.deposit(false, amount, BOB);
    }

    /// @dev A matched deposit invests the complete sets; a full redeem of both sides withdraws them again.
    function testInvestedBalanceReflectsMatchedDeposits() public {
        _investMatched(pool, conditionId, 1000);
        assertEq(_invested(pool), 1000, "matched sets invested");

        // Redeem both sides; the invested collateral is withdrawn back out and the balance drains to zero.
        uint256 aliceShares = factory.balanceOf(ALICE, yesShareId);
        _redeem(ALICE, true, aliceShares);
        uint256 bobShares = factory.balanceOf(BOB, noShareId);
        _redeem(BOB, false, bobShares);

        assertEq(_invested(pool), 0, "invested balance drained");
    }

    /// @dev Two markets sharing the default vault but on different conditions are accounted independently: querying or
    /// draining one leaves the other untouched, even though their collateral sits in the same ERC-4626 vault. With one
    /// pool per market this is now physical — each pool holds its own vault shares — rather than bookkept.
    function testPerMarketAccountingIsIsolated() public {
        _investMatched(pool, conditionId, 1000);
        _investMatched(pool2, conditionId2, 4000);

        assertEq(_invested(pool), 1000, "market 1 unaffected by market 2");
        assertEq(_invested(pool2), 4000, "market 2 tracked independently");
        assertEq(erc4626.balanceOf(address(pool)), 1000, "market 1 holds only its own vault shares");
        assertEq(erc4626.balanceOf(address(pool2)), 4000, "market 2 holds only its own vault shares");

        // Fully draining market 1 leaves market 2 intact.
        _redeem(ALICE, true, factory.balanceOf(ALICE, yesShareId));
        _redeem(BOB, false, factory.balanceOf(BOB, noShareId));

        assertEq(_invested(pool), 0, "market 1 drained");
        assertEq(_invested(pool2), 4000, "market 2 still fully funded");
        assertEq(erc4626.balanceOf(address(pool2)), 4000, "market 2's shares never moved");
    }
}
