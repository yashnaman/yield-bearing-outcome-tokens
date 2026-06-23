// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";

/// @title InvariantBaseTest
/// @notice Shared harness for the invariant suites, in the style of morpho-blue's BaseInvariantTest: handler methods
/// that bound their inputs and guard preconditions so that, under honest vaults, no call ever reverts (the suites run
/// with `fail_on_revert = true`, so a guarded valid op reverting is itself a finding).
///
/// The market topology is chosen to stress cross-market isolation: markets A and B share one collateral+condition (so
/// they share a ConditionalTokens position-id pool) but invest into two distinct honest vaults; market C is on a second
/// condition. Isolation is enforced only by the core's internal per-market `danglingBalance`.
abstract contract InvariantBaseTest is BaseTest {
    MockERC4626 internal erc4626B;

    bytes32 internal conditionId2;
    bytes32 internal questionId2;

    Market internal marketA; // default vault, condition 1
    Market internal marketB; // vault B, condition 1 (shares A's pool)
    Market internal marketC; // default vault, condition 2 (separate pool)

    Market[] internal markets;

    address[] internal actors;

    /// @dev Ghost: outcome tokens donated straight to the vault (never deposited), keyed by position id. The core
    /// prices off internal accounting, not its raw balance, so donations must inflate the pool by exactly this much
    /// and nothing more.
    mapping(uint256 positionId => uint256 amount) internal donated;

    function setUp() public virtual override {
        super.setUp();

        // A second honest ERC-4626 vault over the SAME collateral, so markets A and B share collateral+condition (and
        // thus a position-id pool) but invest into different vaults, mapping to distinct market ids.
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

        // A second binary condition for a market on a separate position-id pool.
        questionId2 = keccak256("question2");
        ct.prepareCondition(ORACLE, questionId2, 2);
        conditionId2 = ct.getConditionId(ORACLE, questionId2, 2);

        marketA = Market({vault: defaultVault, conditionId: conditionId});
        marketB = Market({vault: IERC4626(address(erc4626B)), conditionId: conditionId});
        marketC = Market({vault: defaultVault, conditionId: conditionId2});

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

    function _market(uint256 seed) internal view returns (Market memory) {
        return markets[seed % markets.length];
    }

    /// @dev Mints `amount` of the `isYes` side of `m` to `user` (by splitting fresh collateral at the CT) and approves
    /// the vault as ERC1155 operator. Pure setup; never reverts for honest collateral.
    function _giveOutcomeTokens(address user, Market memory m, uint256 amount) internal {
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

    /* HONEST HANDLERS (must never revert under honest vaults) */

    function depositHandler(uint256 marketSeed, bool isYes, uint256 amount) external {
        Market memory m = _market(marketSeed);
        amount = bound(amount, MIN_INVARIANT_AMOUNT, MAX_INVARIANT_AMOUNT);

        _giveOutcomeTokens(msg.sender, m, amount);
        vm.prank(msg.sender);
        vault.deposit(m.vault, m.conditionId, isYes, amount, msg.sender);
    }

    function redeemHandler(uint256 marketSeed, bool isYes, uint256 sharesSeed) external {
        Market memory m = _market(marketSeed);
        bytes32 mid = _id(m);

        uint256 held = vault.sharesOf(mid, isYes, msg.sender);
        if (held == 0) return;
        uint256 shares = bound(sharesSeed, 1, held);

        vm.prank(msg.sender);
        vault.redeem(m.vault, m.conditionId, isYes, shares, msg.sender, msg.sender);
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

    /// @dev Pushes outcome tokens straight onto the vault without going through `deposit`. The core ignores raw
    /// balances, so this must never move a share price or let anyone redeem the donated tokens; it should only show up
    /// as the `donated` ghost in pool conservation.
    function donateHandler(uint256 marketSeed, bool isYes, uint256 amount) external {
        Market memory m = _market(marketSeed);
        amount = bound(amount, MIN_INVARIANT_AMOUNT, MAX_INVARIANT_AMOUNT);

        _giveOutcomeTokens(msg.sender, m, amount); // mints `amount` of both sides to the sender
        uint256 positionId = _positionId(IERC20(address(collateral)), m.conditionId, isYes);
        vm.prank(msg.sender);
        ct.safeTransferFrom(msg.sender, address(vault), positionId, amount, "");
        donated[positionId] += amount;
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

    function _assertPool(bytes32 cond, bool isYes, Market[] memory sharing) internal view {
        uint256 positionId = _positionId(IERC20(address(collateral)), cond, isYes);
        uint256 sumDangling;
        for (uint256 i; i < sharing.length; ++i) {
            sumDangling += vault.danglingBalance(_id(sharing[i]), isYes);
        }
        assertEq(
            _vaultPositionBalance(positionId), sumDangling + donated[positionId], "pool == sum of dangling + donated"
        );
    }

    /// @dev Solvency / exit-liveness: every tracked actor can redeem their entire share balance on every honest
    /// market and side, all at once. Performed against a snapshot that is rolled back, so it does not disturb the
    /// run. A revert here means a holder is stuck — i.e. bad debt — and fails the invariant.
    function assertAllHoldersCanRedeem() internal {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < markets.length; ++i) {
            Market memory m = markets[i];
            bytes32 mid = _id(m);
            for (uint256 s; s < 2; ++s) {
                bool isYes = s == 0;
                for (uint256 a; a < actors.length; ++a) {
                    uint256 held = vault.sharesOf(mid, isYes, actors[a]);
                    if (held == 0) continue;
                    vm.prank(actors[a]);
                    vault.redeem(m.vault, m.conditionId, isYes, held, actors[a], actors[a]);
                }
            }
        }
        vm.revertToState(snap);
    }

    /// @dev Asserts the honest markets never collectively claim more invested collateral than the underlying vault
    /// actually holds. Markets A and C share the default vault; market B uses vault B.
    function assertVaultSolvency() internal view {
        uint256 claimedDefault = vault.investedBalance(marketA.vault, marketA.conditionId)
            + vault.investedBalance(marketC.vault, marketC.conditionId);
        assertLe(claimedDefault, erc4626.totalAssets(), "default vault: markets cannot claim more than it holds");

        uint256 claimedB = vault.investedBalance(marketB.vault, marketB.conditionId);
        assertLe(claimedB, erc4626B.totalAssets(), "vault B: market cannot claim more than it holds");
    }

    function _one(Market memory a) internal pure returns (Market[] memory arr) {
        arr = new Market[](1);
        arr[0] = a;
    }

    function _two(Market memory a, Market memory b) internal pure returns (Market[] memory arr) {
        arr = new Market[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
