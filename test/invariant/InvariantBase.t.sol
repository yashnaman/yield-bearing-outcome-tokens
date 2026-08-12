// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/Base.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";
import {ZeroShareRevertingERC4626} from "test/mocks/ZeroShareRevertingERC4626.sol";
import {ShareIdLib} from "src/libraries/ShareIdLib.sol";

/// @title InvariantBaseTest
/// @notice Shared harness for the invariant suites, in the style of morpho-blue's BaseInvariantTest: handler methods
/// that bound their inputs and guard preconditions so that, under honest vaults, no call ever reverts (the suites run
/// with `fail_on_revert = true`, so a guarded valid op reverting is itself a finding).
///
/// The market topology is chosen to stress cross-market isolation: markets A and B share one collateral+condition (so
/// their pools hold the *same* ConditionalTokens position ids) but invest into two distinct honest vaults; markets C
/// and S are on a second condition. Under the singleton, isolation between them rested on an internal
/// `danglingBalance` ledger; each market now has its own pool contract, so the same topology tests that two accounts
/// holding one position id never reach each other. Market S invests into a vault that reverts on zero-share mints at a
/// high share price, so runs organically hit both deferred and successful merges — with `fail_on_revert = true` this
/// proves deposits stay live while merges defer.
abstract contract InvariantBaseTest is BaseTest {
    MockERC4626 internal erc4626B;
    ZeroShareRevertingERC4626 internal strictErc4626;

    /// @dev Share price the strict vault is seeded to: merges below this amount mint zero shares and are deferred.
    /// Sits between MIN_INVARIANT_AMOUNT and MAX_INVARIANT_AMOUNT so a run exercises both outcomes.
    uint256 internal constant STRICT_RATE = 1e9;

    bytes32 internal conditionId2;
    bytes32 internal questionId2;

    Market internal marketA; // default vault, condition 1
    Market internal marketB; // vault B, condition 1 (same position ids as A, different pool)
    Market internal marketC; // default vault, condition 2
    Market internal marketS; // strict vault (reverts on zero-share mints), condition 2 (same position ids as C)

    Market[] internal markets;

    address[] internal actors;

    /// @dev Ghost: outcome tokens that have entered a pool on a given side, whether by `deposit` or by a raw donation.
    mapping(address pool => mapping(bool isYes => uint256)) internal inflow;

    /// @dev Ghost: outcome tokens a pool has paid back out on a given side via `redeem`.
    mapping(address pool => mapping(bool isYes => uint256)) internal outflow;

    /// @dev Ghost: an upper bound on how many times a pool has round-tripped value through its ERC-4626 vault. Every
    /// such hop floors once (`deposit` mints floor(shares), `previewRedeem` floors on the way back), so the pool's
    /// booked backing may sit up to one wei below the flows per hop. This bounds that drift so the backing invariant
    /// stays meaningful instead of being loosened to nothing.
    mapping(address pool => uint256) internal vaultHops;

    function setUp() public virtual override {
        super.setUp();

        // A second honest ERC-4626 vault over the SAME collateral, so markets A and B share collateral+condition (and
        // thus the same position ids) but invest into different vaults, giving them distinct pools.
        erc4626B = new MockERC4626(IERC20(address(collateral)));
        vm.label(address(erc4626B), "ERC4626_B");

        // Seed each vault with a large 1:1 position held by this harness and never withdrawn. This keeps each vault's
        // share price ~1 across a long run, so honest deposits never round to zero shares (no stranding) and the
        // gradually-accruing yield can't compound the price to an overflow. A real yield vault is similarly deep
        // relative to a single market's deposits.
        uint256 seed = 1e30;
        collateral.mint(address(this), 2 * seed);
        collateral.approve(address(erc4626), seed);
        erc4626.deposit(seed, address(this));
        collateral.approve(address(erc4626B), seed);
        erc4626B.deposit(seed, address(this));

        // A strict vault that reverts on zero-share mints, deliberately seeded to a share price of STRICT_RATE so that
        // small merges round to zero shares and are deferred rather than blocking deposits.
        strictErc4626 = new ZeroShareRevertingERC4626(IERC20(address(collateral)));
        vm.label(address(strictErc4626), "ERC4626_Strict");
        collateral.mint(address(this), STRICT_RATE);
        collateral.approve(address(strictErc4626), 1);
        strictErc4626.deposit(1, address(this));
        collateral.transfer(address(strictErc4626), STRICT_RATE - 1);

        // A second binary condition, giving markets C and S a separate pair of position ids.
        questionId2 = keccak256("question2");
        ct.prepareCondition(ORACLE, questionId2, 2);
        conditionId2 = ct.getConditionId(ORACLE, questionId2, 2);

        // Market A's pool is the default one BaseTest already deployed.
        marketA = Market({vault: defaultVault, conditionId: conditionId, pool: pool});
        marketB = _createPool(IERC4626(address(erc4626B)), conditionId);
        marketC = _createPool(defaultVault, conditionId2);
        marketS = _createPool(IERC4626(address(strictErc4626)), conditionId2);

        markets.push(marketA);
        markets.push(marketB);
        markets.push(marketC);
        markets.push(marketS);

        actors.push(ALICE);
        actors.push(BOB);
        actors.push(CAROL);

        for (uint256 i; i < actors.length; ++i) {
            targetSender(actors[i]);
        }
    }

    /* HELPERS */

    function _market(uint256 seed) internal view returns (Market memory) {
        return markets[seed % markets.length];
    }

    /// @dev The ConditionalTokens position id of a side of `m` — the outcome token the pool custodies.
    function _marketPositionId(Market memory m, bool isYes) internal view returns (uint256) {
        return _positionId(IERC20(address(collateral)), m.conditionId, isYes);
    }

    /// @dev The factory's ERC-6909 share id of a side of `m` — what holders own. Markets A and B share a position id
    /// but never a share id, since the share id is derived from the pool address.
    function _marketShareId(Market memory m, bool isYes) internal view returns (uint256) {
        return ShareIdLib.idFor(address(m.pool), isYes);
    }

    /// @dev Mints `amount` of both sides of `m` to `user` (by splitting fresh collateral at the CT) and approves that
    /// market's pool as ERC1155 operator. Pure setup; never reverts for honest collateral.
    function _giveOutcomeTokens(address user, Market memory m, uint256 amount) internal {
        collateral.mint(user, amount);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        vm.startPrank(user);
        collateral.approve(address(ct), amount);
        ct.splitPosition(IERC20(address(collateral)), PARENT_COLLECTION_ID, m.conditionId, partition, amount);
        ct.setApprovalForAll(address(m.pool), true);
        vm.stopPrank();
    }

    /* HONEST HANDLERS (must never revert under honest vaults) */

    function depositHandler(uint256 marketSeed, bool isYes, uint256 amount) external {
        Market memory m = _market(marketSeed);
        amount = bound(amount, MIN_INVARIANT_AMOUNT, MAX_INVARIANT_AMOUNT);

        _giveOutcomeTokens(msg.sender, m, amount);
        vm.prank(msg.sender);
        m.pool.deposit(isYes, amount, msg.sender);
        inflow[address(m.pool)][isYes] += amount;
        vaultHops[address(m.pool)] += 1;
    }

    function redeemHandler(uint256 marketSeed, bool isYes, uint256 sharesSeed) external {
        Market memory m = _market(marketSeed);

        uint256 held = factory.balanceOf(msg.sender, _marketShareId(m, isYes));
        if (held == 0) return;
        uint256 shares = bound(sharesSeed, 1, held);

        vm.prank(msg.sender);
        uint256 assets = m.pool.redeem(isYes, shares, msg.sender, msg.sender);
        outflow[address(m.pool)][isYes] += assets;
        vaultHops[address(m.pool)] += 1;
    }

    /// @dev Transfers part of the sender's shares to another tracked actor. Pure bookkeeping: no assets move, so no
    /// invariant may drift. The recipient is picked from `actors` so share conservation stays checkable.
    function transferHandler(uint256 marketSeed, bool isYes, uint256 sharesSeed, uint256 toSeed) external {
        Market memory m = _market(marketSeed);

        uint256 shareId = _marketShareId(m, isYes);
        uint256 held = factory.balanceOf(msg.sender, shareId);
        if (held == 0) return;
        uint256 shares = bound(sharesSeed, 1, held);
        address to = actors[toSeed % actors.length];

        vm.prank(msg.sender);
        factory.transfer(to, shareId, shares);
    }

    /// @dev Anyone may retry a deferred merge with no arguments. On a pool with nothing matchable, or one whose vault
    /// refuses the merged amount, this is expected to be a no-op or to revert — neither may disturb any invariant, so
    /// the revert is swallowed here rather than counted against `fail_on_revert`.
    function mergeHandler(uint256 marketSeed) external {
        Market memory m = _market(marketSeed);
        try m.pool.mergeAndDeposit() {
            vaultHops[address(m.pool)] += 1;
        } catch {}
    }

    /// @dev Accrues yield into one of the shared ERC-4626 vaults, lifting that vault's invested balances. Capped in
    /// absolute terms per step: combined with the large 1:1 seed in `setUp`, this keeps each vault's share price near 1
    /// over a long run, so it grows gradually without compounding toward an overflow.
    function accrueYieldHandler(uint256 amount) external {
        amount = bound(amount, 0, MAX_INVARIANT_AMOUNT);
        if (amount == 0) return;
        // Alternate which vault receives the yield so both A/C and B accrue over a run.
        if (amount % 2 == 0) collateral.mint(address(erc4626), amount);
        else collateral.mint(address(erc4626B), amount);
    }

    /// @dev The push half of the deposit surface: outcome tokens sent straight to the pool, credited by
    /// {onERC1155Received} without a prior approval or a `deposit` call. Deliberately kept in the same shape as
    /// `depositHandler` — same inflow, same vault hop — because the two entry points must be indistinguishable in
    /// every invariant. A pool that priced a pushed deposit differently from a pulled one would show up here.
    ///
    /// This was a *donation* handler before pushes were credited. There is no longer any way to donate outcome
    /// tokens to a pool: every single transfer in is a deposit, and batch transfers are rejected outright.
    function donateHandler(uint256 marketSeed, bool isYes, uint256 amount) external {
        Market memory m = _market(marketSeed);
        amount = bound(amount, MIN_INVARIANT_AMOUNT, MAX_INVARIANT_AMOUNT);

        _giveOutcomeTokens(msg.sender, m, amount); // mints `amount` of both sides to the sender
        uint256 positionId = _marketPositionId(m, isYes);
        vm.prank(msg.sender);
        ct.safeTransferFrom(msg.sender, address(m.pool), positionId, amount, "");
        inflow[address(m.pool)][isYes] += amount;
        vaultHops[address(m.pool)] += 1;
    }

    /* INVARIANT BUILDING BLOCKS */

    /// @dev Sum of all tracked actors' shares for a (market, side).
    function _sumActorShares(Market memory m, bool isYes) internal view returns (uint256 sum) {
        uint256 shareId = _marketShareId(m, isYes);
        for (uint256 i; i < actors.length; ++i) {
            sum += factory.balanceOf(actors[i], shareId);
        }
    }

    /// @dev Asserts, for every market and side, that the tracked actors hold exactly the side's total share supply
    /// (nothing is minted to or stranded on an untracked account).
    function assertShareConservation() internal view {
        for (uint256 i; i < markets.length; ++i) {
            Market memory m = markets[i];
            assertEq(_sumActorShares(m, true), factory.totalSupply(_marketShareId(m, true)), "YES share conservation");
            assertEq(_sumActorShares(m, false), factory.totalSupply(_marketShareId(m, false)), "NO share conservation");
        }
    }

    /// @dev Isolation, stated physically: a pool holds ERC-4626 shares of exactly one vault — its own. Under the
    /// singleton every market's shares sat in one balance and this had to be simulated by the `vaultSharesOf` ledger,
    /// which the audit's finding E1 broke. There is now nothing to simulate.
    function assertVaultShareIsolation() internal view {
        IERC4626[3] memory allVaults = [defaultVault, IERC4626(address(erc4626B)), IERC4626(address(strictErc4626))];

        for (uint256 i; i < markets.length; ++i) {
            Market memory m = markets[i];
            for (uint256 v; v < allVaults.length; ++v) {
                if (address(allVaults[v]) == address(m.vault)) continue;
                assertEq(allVaults[v].balanceOf(address(m.pool)), 0, "pool holds no foreign vault's shares");
            }
        }
    }

    /// @dev Backing conservation, per pool and per side. Merging burns one token from each side and credits the
    /// invested balance; splitting does the reverse. Both leave `dangling + invested` unchanged on each side, so a
    /// side's total assets can only be moved by tokens flowing in (deposits, donations) or out (redemptions) — plus
    /// yield, which only ever adds. Anything a pool leaked to another pool would show up as a shortfall here.
    ///
    /// The one honest exception is ERC-4626 rounding: each hop through the vault floors once, so the booked backing
    /// may trail the flows by up to one *share's worth* per hop — a wei on a share price of 1, but up to 1e9 on
    /// market S, whose vault is deliberately seeded to that price. The slack is therefore bounded by
    /// `hops x assets-per-share` rather than waived, which still fails any leak larger than the vault's own dust.
    function assertSideBackingCoversFlows() internal view {
        for (uint256 i; i < markets.length; ++i) {
            Market memory m = markets[i];
            uint256 slack = vaultHops[address(m.pool)] * (m.vault.previewRedeem(1) + 1);
            for (uint256 s; s < 2; ++s) {
                bool isYes = s == 0;
                uint256 in_ = inflow[address(m.pool)][isYes];
                uint256 out_ = outflow[address(m.pool)][isYes];
                // Yield means a side can legitimately pay out more than was ever deposited into it, so the net can go
                // negative. There is nothing left to cover in that case.
                if (out_ >= in_) continue;
                assertGe(
                    _totalAssets(m.pool, isYes) + slack, in_ - out_, "side backing covers everything that flowed in"
                );
            }
        }
    }

    /// @dev Exact token conservation, with no rounding tolerance at all. Merging burns exactly one YES and one NO;
    /// splitting mints exactly one of each. Neither changes `danglingYes - danglingNo`, so that difference is moved
    /// only by tokens entering or leaving the pool — and the vault never touches it. Any outcome token that leaked
    /// between two pools sharing a position id breaks this identity by exactly the amount leaked.
    ///
    /// Stated without subtraction to keep every term non-negative:
    ///     danglingYes + inflowNo  + outflowYes  ==  danglingNo + inflowYes + outflowNo
    function assertYesNoDifferenceConservation() internal view {
        for (uint256 i; i < markets.length; ++i) {
            Market memory m = markets[i];
            address p = address(m.pool);
            assertEq(
                _dangling(m.pool, true) + inflow[p][false] + outflow[p][true],
                _dangling(m.pool, false) + inflow[p][true] + outflow[p][false],
                "YES/NO token conservation"
            );
        }
    }

    /// @dev Solvency / exit-liveness: every tracked actor can redeem their entire share balance on every honest
    /// market and side, all at once. Performed against a snapshot that is rolled back, so it does not disturb the
    /// run. A revert here means a holder is stuck — i.e. bad debt — and fails the invariant.
    function assertAllHoldersCanRedeem() internal {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < markets.length; ++i) {
            Market memory m = markets[i];
            for (uint256 s; s < 2; ++s) {
                bool isYes = s == 0;
                uint256 shareId = _marketShareId(m, isYes);
                for (uint256 a; a < actors.length; ++a) {
                    uint256 held = factory.balanceOf(actors[a], shareId);
                    if (held == 0) continue;
                    vm.prank(actors[a]);
                    m.pool.redeem(isYes, held, actors[a], actors[a]);
                }
            }
        }
        vm.revertToState(snap);
    }

    /// @dev Asserts the honest markets never collectively claim more invested collateral than the underlying vault
    /// actually holds. Markets A and C share the default vault; market B uses vault B.
    function assertVaultSolvency() internal view {
        uint256 claimedDefault = _invested(marketA.pool) + _invested(marketC.pool);
        assertLe(claimedDefault, erc4626.totalAssets(), "default vault: markets cannot claim more than it holds");

        assertLe(_invested(marketB.pool), erc4626B.totalAssets(), "vault B: market cannot claim more than it holds");

        assertLe(
            _invested(marketS.pool), strictErc4626.totalAssets(), "strict vault: market cannot claim more than it holds"
        );
    }
}
