// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";
import {OutcomeYieldPoolFactory} from "src/OutcomeYieldPoolFactory.sol";
import {IConditionalTokens} from "src/interface/IConditionalTokens.sol";
import {SharesMathLib} from "src/libraries/SharesMathLib.sol";
import {ShareIdLib} from "src/libraries/ShareIdLib.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";

/// @dev The subset of the real Gnosis ConditionalTokens surface the tests drive directly. The pool only depends on
/// `IConditionalTokens`; this extends it with the condition-setup and id-derivation helpers used to build fixtures.
interface IConditionalTokensExt is IConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external;
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external;
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);
    function getPositionId(IERC20 collateralToken, bytes32 collectionId) external pure returns (uint256);
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);
}

/// @title BaseTest
/// @notice Shared fixture for the OutcomeYieldPool suite. Deploys the real ConditionalTokens via
/// `vm.deployCode` (CTHelpers is out of scope and assumed correct), a mock ERC20 collateral and a mock ERC4626 vault,
/// then deploys a pool for a single default binary market over that vault. Modeled on morpho-blue's BaseTest.
contract BaseTest is Test {
    /// @dev Test-only bundle of the two values that identify a market plus the pool serving it, for suites that
    /// juggle several markets. The production pool takes neither as an argument — both are immutables on it.
    struct Market {
        IERC4626 vault;
        bytes32 conditionId;
        OutcomeYieldPool pool;
    }

    bytes32 internal constant PARENT_COLLECTION_ID = bytes32(0);

    // Re-exported from the library the pool itself uses, so a change there cannot silently diverge from the
    // expectations encoded in these tests.
    uint256 internal constant VIRTUAL_SHARES = SharesMathLib.VIRTUAL_SHARES;
    uint256 internal constant VIRTUAL_ASSETS = SharesMathLib.VIRTUAL_ASSETS;

    // Bounds for fuzzed amounts, kept well clear of uint256 overflow in the share math.
    uint256 internal constant MIN_TEST_AMOUNT = 1;
    uint256 internal constant MAX_TEST_AMOUNT = 1e30;

    // Tighter bounds for stateful invariant runs, where amounts compound across many operations. Kept well below the
    // point where `assets * (totalSupply + VIRTUAL_SHARES)` could approach 2^256 even after share-price growth.
    uint256 internal constant MIN_INVARIANT_AMOUNT = 1e6;
    uint256 internal constant MAX_INVARIANT_AMOUNT = 1e24;

    address internal ALICE;
    address internal BOB;
    address internal CAROL;
    address internal RECEIVER;
    address internal ORACLE; // the condition's reporter (unrelated to the pool)

    IConditionalTokensExt internal ct;
    MockERC20 internal collateral;
    MockERC4626 internal erc4626;
    OutcomeYieldPoolFactory internal factory;
    OutcomeYieldPool internal pool;

    bytes32 internal questionId;
    bytes32 internal conditionId;
    IERC4626 internal defaultVault; // the default market's ERC-4626 vault (== erc4626, typed as IERC4626)

    uint256 internal yesPositionId;
    uint256 internal noPositionId;

    // The factory's ERC-6909 share ids for the default market. Distinct from the position ids above: those identify
    // the outcome tokens the pool custodies, these identify the shares holders own on the factory.
    uint256 internal yesShareId;
    uint256 internal noShareId;

    function setUp() public virtual {
        ALICE = makeAddr("Alice");
        BOB = makeAddr("Bob");
        CAROL = makeAddr("Carol");
        RECEIVER = makeAddr("Receiver");
        ORACLE = makeAddr("Oracle");

        ct = IConditionalTokensExt(deployCode("out/ConditionalTokens.sol/ConditionalTokens.json"));
        vm.label(address(ct), "ConditionalTokens");

        collateral = new MockERC20("Collateral", "COL");
        vm.label(address(collateral), "Collateral");

        erc4626 = new MockERC4626(IERC20(address(collateral)));
        vm.label(address(erc4626), "ERC4626");

        factory = new OutcomeYieldPoolFactory(ct);
        vm.label(address(factory), "Factory");

        defaultVault = IERC4626(address(erc4626));

        questionId = keccak256("question");
        ct.prepareCondition(ORACLE, questionId, 2);
        conditionId = ct.getConditionId(ORACLE, questionId, 2);

        pool = factory.deployPool(defaultVault, conditionId);
        vm.label(address(pool), "Pool");

        yesPositionId = _positionId(true);
        noPositionId = _positionId(false);

        yesShareId = ShareIdLib.idFor(address(pool), true);
        noShareId = ShareIdLib.idFor(address(pool), false);
    }

    /// @dev The factory share id of a side of `market`. The core exposes no id arithmetic, so this derives the id the
    /// same way any off-chain consumer would — from the pool address and the side.
    function _shareId(OutcomeYieldPool market, bool isYes) internal pure returns (uint256) {
        return ShareIdLib.idFor(address(market), isYes);
    }

    /* DERIVED ACCOUNTING
     *
     * The pool deliberately exposes no accounting views: everything below is a composition of calls a caller can make
     * for itself, which is exactly why they were removed from the core. Each helper needs nothing but the pool, since
     * `YIELD_VAULT()` and `CONDITION_ID()` make a pool self-describing.
     */

    /// @dev The ConditionalTokens position id of a side of `market`, derived from the market's own identity. Uses the
    /// pool's pinned `COLLATERAL()` rather than `YIELD_VAULT().asset()`: for a vault that changes its asset after
    /// deployment the two differ, and only the pinned one names the positions the pool actually holds.
    function _poolPositionId(OutcomeYieldPool market, bool isYes) internal view returns (uint256) {
        return _positionId(market.COLLATERAL(), market.CONDITION_ID(), isYes);
    }

    /// @dev What `danglingBalance(isYes)` used to return: the outcome tokens the pool holds but has not merged.
    function _dangling(OutcomeYieldPool market, bool isYes) internal view returns (uint256) {
        return ct.balanceOf(address(market), _poolPositionId(market, isYes));
    }

    /// @dev What `investedBalance()` used to return, including the short-circuit that keeps a pool holding no vault
    /// position from ever calling a vault whose `previewRedeem` has stopped working.
    function _invested(OutcomeYieldPool market) internal view returns (uint256) {
        IERC4626 vault_ = market.YIELD_VAULT();
        uint256 vaultShares = vault_.balanceOf(address(market));
        return vaultShares == 0 ? 0 : vault_.previewRedeem(vaultShares);
    }

    /// @dev What `totalAssets(isYes)` used to return: a side's dangling tokens plus the whole invested balance.
    function _totalAssets(OutcomeYieldPool market, bool isYes) internal view returns (uint256) {
        return _dangling(market, isYes) + _invested(market);
    }

    /// @dev Share balance of `user` on a side of the default market, held on the factory.
    function _sharesOf(address user, bool isYes) internal view returns (uint256) {
        return factory.balanceOf(user, isYes ? yesShareId : noShareId);
    }

    /* MARKET HELPERS */

    /// @dev Prepares a fresh binary condition and deploys the pool that serves it over `vault_`.
    function _createMarket(IERC4626 vault_, bytes32 question) internal returns (Market memory m) {
        ct.prepareCondition(ORACLE, question, 2);
        bytes32 condition = ct.getConditionId(ORACLE, question, 2);
        m = Market({vault: vault_, conditionId: condition, pool: factory.deployPool(vault_, condition)});
    }

    /// @dev Deploys a pool for an already-prepared condition over `vault_`.
    function _createPool(IERC4626 vault_, bytes32 condition) internal returns (Market memory m) {
        m = Market({vault: vault_, conditionId: condition, pool: factory.deployPool(vault_, condition)});
    }

    /* ID HELPERS */

    /// @dev Position id of a side of the default market, derived through the deployed ConditionalTokens itself.
    function _positionId(bool isYes) internal view returns (uint256) {
        return _positionId(IERC20(address(collateral)), conditionId, isYes);
    }

    function _positionId(IERC20 collateralToken, bytes32 condition, bool isYes) internal view returns (uint256) {
        bytes32 collectionId = ct.getCollectionId(PARENT_COLLECTION_ID, condition, isYes ? 1 : 2);
        return ct.getPositionId(collateralToken, collectionId);
    }

    /* FIXTURE HELPERS */

    /// @dev Mints `amount` of both YES and NO outcome tokens to `user` by splitting fresh collateral at the CT, and
    /// approves `operator` to pull the user's outcome tokens. Returns with the user holding `amount` of each side.
    function _mintOutcomeTokens(
        address user,
        IERC20 collateralToken,
        bytes32 condition,
        uint256 amount,
        address operator
    ) internal {
        MockERC20(address(collateralToken)).mint(user, amount);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.startPrank(user);
        collateralToken.approve(address(ct), amount);
        ct.splitPosition(collateralToken, PARENT_COLLECTION_ID, condition, partition, amount);
        ct.setApprovalForAll(operator, true);
        vm.stopPrank();
    }

    function _mintOutcomeTokens(address user, IERC20 collateralToken, bytes32 condition, uint256 amount) internal {
        _mintOutcomeTokens(user, collateralToken, condition, amount, address(pool));
    }

    function _mintOutcomeTokens(address user, uint256 amount) internal {
        _mintOutcomeTokens(user, IERC20(address(collateral)), conditionId, amount, address(pool));
    }

    /// @dev Deposits `amount` of `isYes` outcome tokens of the default market from `user` to `user`.
    function _deposit(address user, bool isYes, uint256 amount) internal returns (uint256 shares) {
        _mintOutcomeTokens(user, amount);
        shares = _depositAs(pool, user, isYes, amount, user);
    }

    /// @dev Calls `deposit` on `p` as `caller` and reports the shares it minted to `to`. `deposit` returns nothing —
    /// the share count is decided inside the ERC-1155 callback that credits it — so tests read it as the change in
    /// `to`'s balance on the factory. Assumes the outcome tokens are already minted and approved.
    function _depositAs(OutcomeYieldPool p, address caller, bool isYes, uint256 amount, address to)
        internal
        returns (uint256 shares)
    {
        uint256 id = ShareIdLib.idFor(address(p), isYes);
        uint256 balanceBefore = factory.balanceOf(to, id);

        vm.prank(caller);
        p.deposit(isYes, amount, to);

        shares = factory.balanceOf(to, id) - balanceBefore;
    }

    function _redeem(address user, bool isYes, uint256 shares) internal returns (uint256 assets) {
        vm.prank(user);
        assets = pool.redeem(isYes, shares, user, user);
    }

    /// @dev Simulates yield by minting `amount` collateral straight into the ERC4626 vault, lifting its share price so
    /// the invested balance grows for every pool invested into it.
    function _accrueYield(uint256 amount) internal {
        collateral.mint(address(erc4626), amount);
    }

    /// @dev The pool's actual ConditionalTokens balance of a side's position id.
    function _poolPositionBalance(uint256 positionId) internal view returns (uint256) {
        return ct.balanceOf(address(pool), positionId);
    }
}
