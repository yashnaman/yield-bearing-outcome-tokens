// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";
import {ERC4626VaultAdapter} from "test/mocks/ERC4626VaultAdapter.sol";

/// @title InvariantBaseTest
/// @notice Shared harness for the invariant suites, in the style of morpho-blue's BaseInvariantTest: handler methods
/// that bound their inputs and guard preconditions so that, under honest adapters, no call ever reverts (the suites
/// run with `fail_on_revert = true`, so a guarded valid op reverting is itself a finding).
///
/// The market topology is chosen to stress cross-market isolation: markets A and B share one collateral+condition (so
/// they share a ConditionalTokens position-id pool) but use two distinct honest adapters; market C is on a second
/// condition. Isolation is enforced only by the vault's internal per-market `danglingBalance`.
abstract contract InvariantBaseTest is BaseTest {
    ERC4626VaultAdapter internal adapterB;

    bytes32 internal conditionId2;
    bytes32 internal questionId2;

    IYieldBearingOutcomeTokens.MarketParams internal marketA; // == default marketParams (adapter A, condition 1)
    IYieldBearingOutcomeTokens.MarketParams internal marketB; // adapter B, condition 1 (shares A's pool)
    IYieldBearingOutcomeTokens.MarketParams internal marketC; // adapter A, condition 2 (separate pool)

    IYieldBearingOutcomeTokens.MarketParams[] internal markets;

    address[] internal actors;

    function setUp() public virtual override {
        super.setUp();

        // A second honest adapter over the SAME ERC4626 vault, so markets A and B share collateral+condition but not
        // their adapter.
        adapterB = new ERC4626VaultAdapter(IERC4626(address(erc4626)), address(vault));
        vm.label(address(adapterB), "AdapterB");

        // A second binary condition for a market on a separate position-id pool.
        questionId2 = keccak256("question2");
        ct.prepareCondition(ORACLE, questionId2, 2);
        conditionId2 = ct.getConditionId(ORACLE, questionId2, 2);

        marketA = marketParams;
        marketB = IYieldBearingOutcomeTokens.MarketParams({
            collateralToken: IERC20(address(collateral)),
            conditionId: conditionId,
            vaultAdapter: IVaultAdapter(address(adapterB))
        });
        marketC = IYieldBearingOutcomeTokens.MarketParams({
            collateralToken: IERC20(address(collateral)),
            conditionId: conditionId2,
            vaultAdapter: IVaultAdapter(address(adapter))
        });

        markets.push(marketA);
        markets.push(marketB);
        markets.push(marketC);

        actors.push(ALICE);
        actors.push(BOB);
        actors.push(CAROL);

        for (uint256 i; i < actors.length; ++i) {
            targetSender(actors[i]);
        }
    }

    /* HELPERS */

    function _market(uint256 seed) internal view returns (IYieldBearingOutcomeTokens.MarketParams memory) {
        return markets[seed % markets.length];
    }

    /// @dev Mints `amount` of the `isYes` side of `m` to `user` (by splitting fresh collateral at the CT) and approves
    /// the vault as ERC1155 operator. Pure setup; never reverts for honest collateral.
    function _giveOutcomeTokens(address user, IYieldBearingOutcomeTokens.MarketParams memory m, uint256 amount)
        internal
    {
        collateral.mint(user, amount);
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        vm.startPrank(user);
        collateral.approve(address(ct), amount);
        ct.splitPosition(IERC20(address(collateral)), PARENT_COLLECTION_ID, m.conditionId, partition, amount);
        ct.setApprovalForAll(address(vault), true);
        vm.stopPrank();
    }

    /* HONEST HANDLERS (must never revert under honest adapters) */

    function depositHandler(uint256 marketSeed, bool isYes, uint256 amount) external {
        IYieldBearingOutcomeTokens.MarketParams memory m = _market(marketSeed);
        amount = bound(amount, MIN_INVARIANT_AMOUNT, MAX_INVARIANT_AMOUNT);

        _giveOutcomeTokens(msg.sender, m, amount);
        vm.prank(msg.sender);
        vault.deposit(m, isYes, amount, msg.sender);
    }

    function redeemHandler(uint256 marketSeed, bool isYes, uint256 sharesSeed) external {
        IYieldBearingOutcomeTokens.MarketParams memory m = _market(marketSeed);
        bytes32 mid = _id(m);

        uint256 held = vault.sharesOf(mid, isYes, msg.sender);
        if (held == 0) return;
        uint256 shares = bound(sharesSeed, 1, held);

        vm.prank(msg.sender);
        vault.redeem(m, isYes, shares, msg.sender);
    }

    /// @dev Accrues yield into the shared ERC4626 vault, lifting every honest adapter's invested balance. Models
    /// realistic yield: it only accrues once there is principal to earn on, and at most ~10% of the current balance
    /// per step, so the underlying share price grows gradually rather than being dumped into an empty vault (which
    /// would let honest `invest` calls round to zero underlying shares and is not how a real yield vault behaves).
    function accrueYieldHandler(uint256 amount) external {
        uint256 totalAssets = erc4626.totalAssets();
        if (totalAssets == 0) return; // no principal yet: nothing to earn yield on
        amount = bound(amount, 0, totalAssets / 10);
        if (amount == 0) return;
        collateral.mint(address(erc4626), amount);
    }

    /* INVARIANT BUILDING BLOCKS */

    /// @dev Sum of all tracked actors' shares for a (market, side).
    function _sumActorShares(bytes32 mid, bool isYes) internal view returns (uint256 sum) {
        for (uint256 i; i < actors.length; ++i) {
            sum += vault.sharesOf(mid, isYes, actors[i]);
        }
    }

    /// @dev Asserts, for every market and side, that the tracked actors hold exactly the side's total shares (nothing
    /// is minted to or stranded on an untracked account).
    function assertShareConservation() internal view {
        for (uint256 i; i < markets.length; ++i) {
            bytes32 mid = _id(markets[i]);
            assertEq(_sumActorShares(mid, true), vault.totalShares(mid, true), "YES share conservation");
            assertEq(_sumActorShares(mid, false), vault.totalShares(mid, false), "NO share conservation");
        }
    }

    /// @dev Asserts the vault's real ConditionalTokens balance of each position equals the sum of the internal
    /// `danglingBalance` of every market that shares that position. This is the cross-market isolation invariant: the
    /// pooled ERC1155 balance is always fully and exactly attributed to the markets that own it.
    function assertPoolConservation() internal view {
        // Condition 1 pool is shared by markets A and B.
        _assertPool(conditionId, true, _two(marketA, marketB));
        _assertPool(conditionId, false, _two(marketA, marketB));
        // Condition 2 pool belongs to market C alone.
        _assertPool(conditionId2, true, _one(marketC));
        _assertPool(conditionId2, false, _one(marketC));
    }

    function _assertPool(bytes32 cond, bool isYes, IYieldBearingOutcomeTokens.MarketParams[] memory sharing)
        internal
        view
    {
        uint256 positionId = _positionId(IERC20(address(collateral)), cond, isYes);
        uint256 sumDangling;
        for (uint256 i; i < sharing.length; ++i) {
            sumDangling += vault.danglingBalance(_id(sharing[i]), isYes);
        }
        assertEq(_vaultPositionBalance(positionId), sumDangling, "pool == sum of dangling balances");
    }

    /// @dev Asserts the honest adapters never collectively claim more invested collateral than the underlying ERC4626
    /// actually holds.
    function assertAdapterSolvency() internal view {
        uint256 claimed =
            adapter.investedBalance(marketA) + adapterB.investedBalance(marketB) + adapter.investedBalance(marketC);
        assertLe(claimed, erc4626.totalAssets(), "adapters cannot claim more than the vault holds");
    }

    function _one(IYieldBearingOutcomeTokens.MarketParams memory a)
        internal
        pure
        returns (IYieldBearingOutcomeTokens.MarketParams[] memory arr)
    {
        arr = new IYieldBearingOutcomeTokens.MarketParams[](1);
        arr[0] = a;
    }

    function _two(IYieldBearingOutcomeTokens.MarketParams memory a, IYieldBearingOutcomeTokens.MarketParams memory b)
        internal
        pure
        returns (IYieldBearingOutcomeTokens.MarketParams[] memory arr)
    {
        arr = new IYieldBearingOutcomeTokens.MarketParams[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
