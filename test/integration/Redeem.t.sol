// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/Base.t.sol";
import {IOutcomeYieldPool} from "src/interface/IOutcomeYieldPool.sol";
import {BreakableVault} from "test/mocks/EipRoundingERC4626.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Behavioural tests for `redeem`: the pay-from-dangling path, the divest-and-split path, round-trip safety,
/// events and reverts.
contract RedeemTest is BaseTest {
    /// @dev When the side still holds enough dangling tokens, redemption pays straight out without touching the vault.
    function testRedeemFromDangling(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        uint256 shares = _deposit(ALICE, true, amount); // no opposite side, so everything stays dangling

        uint256 assets = _redeem(ALICE, true, shares);

        assertEq(assets, amount, "redeems exactly what was deposited");
        assertEq(_invested(pool), 0, "vault untouched");
        assertEq(ct.balanceOf(ALICE, yesPositionId), amount, "outcome tokens returned to user");
        assertEq(factory.balanceOf(ALICE, yesShareId), 0, "shares burned");
    }

    /// @dev When the side's tokens were merged away, redemption must divest collateral and split it back into a fresh
    /// pair: the redeemer's side is paid and the opposite side is credited the freshly split dangling tokens.
    function testRedeemViaDivestAndSplit(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        _deposit(ALICE, true, amount);
        uint256 bobShares = _deposit(BOB, false, amount); // fully matched -> all invested, no dangling

        assertEq(_poolPositionBalance(noPositionId), 0, "NO fully merged");

        uint256 assets = _redeem(BOB, false, bobShares);

        assertEq(assets, amount, "Bob reconstitutes his NO tokens");
        assertEq(ct.balanceOf(BOB, noPositionId), amount, "NO tokens delivered");
        // Splitting produced `amount` YES too, credited to the YES side as dangling.
        assertEq(_poolPositionBalance(yesPositionId), amount, "opposite side credited the split YES tokens");
        assertEq(_invested(pool), 0, "collateral fully divested");
    }

    function testRedeemEmitsEvent() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.expectEmit(true, true, true, true, address(pool));
        emit IOutcomeYieldPool.Redeem(true, ALICE, ALICE, RECEIVER, shares, 100);

        vm.prank(ALICE);
        uint256 assets = pool.redeem(true, shares, ALICE, RECEIVER);

        assertEq(assets, 100, "assets returned");
        assertEq(ct.balanceOf(RECEIVER, yesPositionId), 100, "tokens sent to `to`, not caller");
    }

    /// @dev The redeemed outcome tokens go to `to`, not the caller, for any receiver that can hold ERC1155.
    function testRedeemToFuzzedReceiver(address to, uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        // `to` must be able to receive ERC1155: an EOA (no code) and not the zero address.
        vm.assume(to != address(0) && to.code.length == 0);

        uint256 shares = _deposit(ALICE, true, amount); // unmatched, paid from dangling

        uint256 balBefore = ct.balanceOf(to, yesPositionId);
        vm.prank(ALICE);
        uint256 assets = pool.redeem(true, shares, ALICE, to);

        assertEq(assets, amount, "redeems the deposited amount");
        assertEq(ct.balanceOf(to, yesPositionId) - balBefore, amount, "outcome tokens delivered to receiver");
    }

    /// @dev Redeeming more shares than held underflows and reverts; no payout happens.
    function testRedeemMoreThanOwnedReverts() public {
        uint256 shares = _deposit(ALICE, true, 100);

        vm.prank(ALICE);
        vm.expectRevert();
        pool.redeem(true, shares + 1, ALICE, ALICE);
    }

    /// @dev A deposit immediately followed by a full redeem never returns more than was deposited (rounding favors the
    /// vault), across the full fuzz range.
    function testRoundTripNeverProfits(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        uint256 shares = _deposit(ALICE, true, amount);
        uint256 assets = _redeem(ALICE, true, shares);

        assertLe(assets, amount, "no value extracted on a round trip");
    }

    /* ---- A dead vault must not block a redemption that needs no vault ---- */

    /// @dev `_investedBalance` short-circuits on an empty position, so a pool holding outcome tokens and no vault
    /// shares never calls `previewRedeem` at all. The pure-dangling exit does not depend on the vault being alive, so
    /// there is no need for a rescue path.
    function testDanglingOnlyRedeemSurvivesDeadVault() public {
        BreakableVault v = new BreakableVault(IERC20(address(collateral)));
        OutcomeYieldPool p = factory.deployPool(IERC4626(address(v)), conditionId);
        uint256 n = 1_000e6;
        _mintOutcomeTokens(ALICE, IERC20(address(collateral)), conditionId, n, address(p));

        vm.prank(ALICE);
        p.deposit(true, n, ALICE); // YES only -> pure dangling, nothing invested
        uint256 shYes = factory.balanceOf(ALICE, _shareId(p, true));

        assertEq(v.balanceOf(address(p)), 0, "nothing invested");
        assertEq(ct.balanceOf(address(p), yesPositionId), n, "tokens physically held");

        v.breakIt();

        vm.prank(ALICE);
        uint256 out = p.redeem(true, shYes, ALICE, ALICE);

        assertEq(out, n, "the pure-dangling redeem pays out despite the dead vault");
        assertEq(ct.balanceOf(ALICE, yesPositionId), n, "Alice holds her tokens again");
    }

    /// @dev A dead vault does still block a redemption that genuinely needs to divest — the pool cannot value or
    /// liquidate a position through a vault that will not answer. That is the vault's failure, contained to the market
    /// that chose it, and is the residual the short-circuit deliberately does not cover.
    function testInvestedRedeemStillNeedsALiveVault() public {
        BreakableVault v = new BreakableVault(IERC20(address(collateral)));
        OutcomeYieldPool p = factory.deployPool(IERC4626(address(v)), conditionId);
        uint256 n = 1_000e6;
        _mintOutcomeTokens(ALICE, IERC20(address(collateral)), conditionId, n, address(p));

        vm.startPrank(ALICE);
        p.deposit(true, n, ALICE);
        p.deposit(false, n, ALICE); // matched -> invested
        vm.stopPrank();
        uint256 shYes = factory.balanceOf(ALICE, _shareId(p, true));

        v.breakIt();

        vm.prank(ALICE);
        vm.expectRevert();
        p.redeem(true, shYes, ALICE, ALICE);
    }
}
