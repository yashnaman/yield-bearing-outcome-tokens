// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/Base.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";
import {IOutcomeYieldPool} from "src/interface/IOutcomeYieldPool.sol";
import {ZeroShareRevertingERC4626} from "test/mocks/ZeroShareRevertingERC4626.sol";

/// @notice Behavioural tests for the best-effort merge: a yield vault that reverts on zero-share mints (solmate-style)
/// must not block opposite-side deposits. A refused merge leaves both sides dangling, and a later deposit retries the
/// merge with the accumulated amount. The strict vault is seeded to a share price of `RATE`, so any merge below `RATE`
/// collateral rounds to zero shares and reverts.
contract DeferredMergeTest is BaseTest {
    ZeroShareRevertingERC4626 internal strict;
    IERC4626 internal strictVault;
    OutcomeYieldPool internal strictPool;

    // Share price of the strict vault: deposits below RATE mint zero shares and revert.
    uint256 internal constant RATE = 1000;

    function setUp() public virtual override {
        super.setUp();

        strict = new ZeroShareRevertingERC4626(IERC20(address(collateral)));
        strictVault = IERC4626(address(strict));
        vm.label(address(strict), "StrictVault");

        // Seed the exchange rate to RATE: 1 share backed by RATE assets, so `deposit(x)` mints `x / RATE` floored.
        collateral.mint(address(this), 1);
        collateral.approve(address(strict), 1);
        strict.deposit(1, address(this));
        collateral.mint(address(strict), RATE - 1);

        strictPool = factory.deployPool(strictVault, conditionId);
        vm.label(address(strictPool), "StrictPool");
    }

    /// @dev Deposits `amount` of `isYes` outcome tokens of the strict market from `user` to `user`.
    function _depositStrict(address user, bool isYes, uint256 amount) internal returns (uint256 shares) {
        _mintOutcomeTokens(user, IERC20(address(collateral)), conditionId, amount, address(strictPool));
        shares = _depositAs(strictPool, user, isYes, amount, user);
    }

    /// @dev The strict pool's booked yield-vault position, which is now simply its share balance.
    function _strictVaultShares() internal view returns (uint256) {
        return strict.balanceOf(address(strictPool));
    }

    /// @dev The reported bug scenario: 1 wei of dangling YES used to make every NO deposit revert on the strict
    /// vault's zero-share `deposit(1)`. Now the merge is deferred and the deposit succeeds with both sides dangling.
    function testTinyDanglingDoesNotBlockOppositeDeposit() public {
        _depositStrict(ALICE, true, 1);

        _mintOutcomeTokens(BOB, IERC20(address(collateral)), conditionId, 5000, address(strictPool));
        vm.expectEmit(true, true, true, true, address(strictPool));
        emit IOutcomeYieldPool.Deposit(false, BOB, BOB, 5000, 5000 * VIRTUAL_SHARES);
        uint256 bobShares = _depositAs(strictPool, BOB, false, 5000, BOB);

        assertEq(bobShares, 5000 * VIRTUAL_SHARES, "Bob's shares priced as if nothing merged");
        assertEq(_dangling(strictPool, true), 1, "YES side keeps its 1 wei dangling");
        assertEq(_dangling(strictPool, false), 5000, "NO side keeps everything dangling");
        assertEq(_invested(strictPool), 0, "nothing invested");
        assertEq(_strictVaultShares(), 0, "no strict-vault shares booked");

        // The merge rolled back, so the pool still holds every deposited token.
        assertEq(ct.balanceOf(address(strictPool), yesPositionId), 1, "pool holds the dangling YES");
        assertEq(ct.balanceOf(address(strictPool), noPositionId), 5000, "pool holds the dangling NO");
    }

    /// @dev As long as the matchable amount stays below the vault's minimum, every deposit defers again and the
    /// dangling balances simply accumulate on both sides.
    function testRepeatedDeferralAccumulates() public {
        _depositStrict(ALICE, true, 1);
        _depositStrict(BOB, false, 5000);

        _depositStrict(ALICE, true, 100); // completeSets = 101 < RATE, still refused

        assertEq(_dangling(strictPool, true), 101, "YES dangling accumulates");
        assertEq(_dangling(strictPool, false), 5000, "NO dangling untouched");
        assertEq(_invested(strictPool), 0, "still nothing invested");
    }

    /// @dev Once a later deposit lifts the matchable amount past the vault's minimum, the merge retries with the
    /// accumulated total and succeeds, settling both sides' danglings and booking the vault shares.
    function testLaterDepositRetriesAndSucceeds() public {
        _depositStrict(ALICE, true, 1);
        _depositStrict(BOB, false, 5000);

        _depositStrict(CAROL, true, 2000); // completeSets = 2001 >= RATE -> mints 2001 / RATE = 2 shares

        assertEq(_strictVaultShares(), 2, "strict-vault shares booked from the retried merge");
        assertEq(_dangling(strictPool, true), 0, "YES fully matched");
        assertEq(_dangling(strictPool, false), 2999, "NO keeps only its surplus");
        assertEq(_invested(strictPool), strict.previewRedeem(2), "invested = shares' worth");
        assertEq(_invested(strictPool), 2000, "floored to 2000 at the seeded rate");
    }

    /// @dev A deferred merge is no longer hostage to the next deposit: anyone can retry it directly, with no
    /// arguments, once the matchable amount clears the vault's minimum.
    function testPermissionlessMergeRetriesTheDeferral() public {
        _depositStrict(ALICE, true, 2001);
        _depositStrict(BOB, false, 5000);
        assertEq(_invested(strictPool), 2001 - 1, "the deposit's own merge already invested 2001");

        // Drain nothing, add nothing: a second call is a no-op because one side is now fully matched.
        vm.prank(makeAddr("Keeper"));
        strictPool.mergeAndDeposit();
        assertEq(_dangling(strictPool, true), 0, "YES still fully matched");
    }

    /// @dev A merge the vault refuses reverts loudly when called directly, rather than silently deferring — only
    /// `deposit` swallows it, and only so the deposit itself still lands.
    function testDirectMergeRevertsWhenVaultRefuses() public {
        _depositStrict(ALICE, true, 1);
        _depositStrict(BOB, false, 5000); // completeSets = 1 < RATE, deferred

        // This vault reverts on the zero-share mint itself (solmate-style), before the pool's own guard is reached.
        // Either way the failure surfaces loudly instead of deferring silently.
        vm.expectRevert(bytes("ZERO_SHARES"));
        strictPool.mergeAndDeposit();
    }

    /// @dev With both sides dangling after a deferral, a redeem that fits inside this side's dangling balance pays
    /// straight out without touching the vault and leaves the other side's dangling intact.
    function testRedeemFromDanglingWhenBothSidesDangle() public {
        _depositStrict(ALICE, true, 1);
        uint256 bobShares = _depositStrict(BOB, false, 5000);

        vm.prank(BOB);
        uint256 assets = strictPool.redeem(false, bobShares, BOB, BOB);

        assertEq(assets, 5000, "Bob redeems his full deposit from dangling");
        assertEq(ct.balanceOf(BOB, noPositionId), 5000, "Bob holds the NO tokens");
        assertEq(_dangling(strictPool, false), 0, "NO dangling drained");
        assertEq(_dangling(strictPool, true), 1, "YES dangling untouched");
        assertEq(_strictVaultShares(), 0, "vault never touched");
    }

    /// @dev After a successful retry has invested, a redeem larger than this side's dangling takes the
    /// withdraw-and-split path: collateral is pulled from the strict vault, split into a fresh pair, and the opposite
    /// side is credited the other half.
    function testRedeemViaWithdrawAndSplitAfterRetry() public {
        _depositStrict(ALICE, true, 1);
        uint256 bobShares = _depositStrict(BOB, false, 5000);
        _depositStrict(CAROL, true, 2000); // retried merge invests 2001 collateral for 2 shares

        // assets = 5000e6 * (2999 dangling + 2000 invested + 1 virtual) / (5000e6 + 1e6) = 4999.
        // The 2000 shortfall over the dangling 2999 is withdrawn from the strict vault and split.
        uint256 sharesBefore = _strictVaultShares();
        vm.prank(BOB);
        uint256 assets = strictPool.redeem(false, bobShares, BOB, BOB);

        assertEq(assets, 4999, "Bob's redeem spans dangling and invested backing");
        assertEq(ct.balanceOf(BOB, noPositionId), 4999, "Bob holds the NO tokens");
        assertEq(_dangling(strictPool, false), 0, "NO dangling drained");
        // The exit asks the vault for exactly the shortfall, so exactly that is split and the YES side is credited
        // its other half — no more. The ceil-rounded over-burn stays in the vault, which is the accepted risk.
        assertEq(_dangling(strictPool, true), 2000, "YES credited exactly the split's other half");
        assertLt(_strictVaultShares(), sharesBefore, "vault shares reduced by the withdraw");
    }
}
