// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Behavioural tests for `deposit`: share minting math, the merge-and-invest rebalance, events and reverts.
contract DepositIntegrationTest is BaseTest {
    event Deposit(
        bytes32 indexed id, bool isYes, address indexed caller, address indexed to, uint256 amount, uint256 shares
    );

    /// @dev First deposit on an empty side: shares = assets * VIRTUAL_SHARES / VIRTUAL_ASSETS (totals start at zero).
    function testFirstDepositSharePrice(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        uint256 shares = _deposit(ALICE, true, amount);

        assertEq(shares, amount * VIRTUAL_SHARES / VIRTUAL_ASSETS, "first deposit share price");
        assertEq(vault.totalShares(id, true), shares, "totalShares updated");
        assertEq(vault.sharesOf(id, true, ALICE), shares, "user shares credited");
        // No opposite side yet, so nothing merges; the deposit stays dangling and the vault holds the tokens.
        assertEq(adapter.investedBalance(marketParams), 0, "nothing invested without a match");
        assertEq(_vaultPositionBalance(yesPositionId), amount, "vault holds the dangling YES tokens");
    }

    /// @dev Depositing the opposite side matches complete sets, which are merged into collateral and invested.
    function testDepositMatchesAndInvests(uint256 yesAmount, uint256 noAmount) public {
        yesAmount = bound(yesAmount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        noAmount = bound(noAmount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        _deposit(ALICE, true, yesAmount);
        _deposit(BOB, false, noAmount);

        uint256 matched = yesAmount < noAmount ? yesAmount : noAmount;

        assertEq(adapter.investedBalance(marketParams), matched, "complete sets invested");
        // Each side keeps only its surplus over the match as dangling tokens.
        assertEq(_vaultPositionBalance(yesPositionId), yesAmount - matched, "YES surplus dangling");
        assertEq(_vaultPositionBalance(noPositionId), noAmount - matched, "NO surplus dangling");
    }

    /// @dev A deposit into a side whose assets have all been merged still mints shares 1:1 against invested balance.
    function testDepositAfterFullMatchKeepsSharePrice() public {
        _deposit(ALICE, true, 100);
        _deposit(BOB, false, 100); // fully matched: YES totalAssets are now entirely invested (100)

        // YES side: totalShares = 100 * VS, totalAssets = investedBalance = 100. A second 100 deposit should mint
        // ~the same shares as the first (price ~1 asset : VS shares), modulo virtual offsets.
        uint256 shares = _deposit(CAROL, true, 100);
        uint256 expected = 100 * (100 * VIRTUAL_SHARES + VIRTUAL_SHARES) / (100 + VIRTUAL_ASSETS);
        assertEq(shares, expected, "share price tracks invested balance");
    }

    /// @dev Shares are credited to `to`, never to the caller, for any receiver address.
    function testDepositToFuzzedReceiver(address to, uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        _mintOutcomeTokens(ALICE, amount);
        vm.prank(ALICE);
        uint256 shares = vault.deposit(marketParams, true, amount, to);

        assertEq(vault.sharesOf(id, true, to), shares, "shares credited to receiver");
        if (to != ALICE) {
            assertEq(vault.sharesOf(id, true, ALICE), 0, "caller receives nothing when to != caller");
        }
    }

    function testDepositEmitsEvent() public {
        _mintOutcomeTokens(ALICE, 100);

        uint256 expectedShares = 100 * VIRTUAL_SHARES / VIRTUAL_ASSETS;
        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(id, true, ALICE, BOB, 100, expectedShares);

        vm.prank(ALICE);
        vault.deposit(marketParams, true, 100, BOB);

        assertEq(vault.sharesOf(id, true, BOB), expectedShares, "shares minted to `to`, not caller");
    }

    /// @dev The vault only accepts outcome tokens forwarded by ConditionalTokens; depositing without approval reverts.
    function testDepositRevertsWithoutApproval() public {
        // Mint tokens but do NOT approve the vault as ERC1155 operator.
        collateral.mint(ALICE, 100);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        vm.startPrank(ALICE);
        collateral.approve(address(ct), 100);
        ct.splitPosition(IERC20(address(collateral)), PARENT_COLLECTION_ID, conditionId, partition, 100);
        vm.expectRevert();
        vault.deposit(marketParams, true, 100, ALICE);
        vm.stopPrank();
    }

    /// @dev Inflation-attack resistance: an attacker front-running the first depositor with a 1-wei deposit plus a
    /// large direct token donation cannot make the victim's shares round to zero, thanks to the virtual offsets.
    function testInflationAttackBoundedByVirtualShares() public {
        // Attacker seeds the side with 1 wei.
        _deposit(ALICE, true, 1);
        // Attacker donates a large amount of YES tokens straight to the vault, inflating its raw balance. The vault
        // ignores raw balances and prices off internal dangling + invested, so this does not move the share price.
        _mintOutcomeTokens(CAROL, 1e18);
        vm.prank(CAROL);
        ct.safeTransferFrom(CAROL, address(vault), yesPositionId, 1e18, "");

        // Victim deposits and must still receive a fair (non-zero, ~proportional) share allocation.
        uint256 victimShares = _deposit(BOB, true, 1e18);
        assertGt(victimShares, 0, "victim not griefed to zero shares");
    }
}
