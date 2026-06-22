// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {YieldBearingOutcomeTokens} from "src/YieldBearingOutcomeTokens.sol";
import {IConditionalTokens} from "src/interface/IConditionalTokens.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";
import {ERC4626VaultAdapter} from "test/mocks/ERC4626VaultAdapter.sol";

/// @dev The subset of the real Gnosis ConditionalTokens surface the tests drive directly. The vault only depends on
/// `IConditionalTokens`; this extends it with the condition-setup and id-derivation helpers used to build fixtures.
interface IConditionalTokensExt is IConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;
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
/// @notice Shared fixture for the YieldBearingOutcomeTokens suite. Deploys the real ConditionalTokens via
/// `vm.deployCode` (CTHelpers is out of scope and assumed correct), a mock ERC20 collateral, a mock ERC4626 vault and
/// the example ERC4626 adapter, then wires a single default binary market. Modeled on morpho-blue's BaseTest.
contract BaseTest is Test {
    bytes32 internal constant PARENT_COLLECTION_ID = bytes32(0);
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    // Bounds for fuzzed amounts, kept well clear of uint256 overflow in the share math.
    uint256 internal constant MIN_TEST_AMOUNT = 1;
    uint256 internal constant MAX_TEST_AMOUNT = 1e30;

    // Tighter bounds for stateful invariant runs, where amounts compound across many operations. Kept well below the
    // point where `assets * (totalShares + VIRTUAL_SHARES)` could approach 2^256 even after share-price growth.
    uint256 internal constant MIN_INVARIANT_AMOUNT = 1e6;
    uint256 internal constant MAX_INVARIANT_AMOUNT = 1e24;

    address internal ALICE;
    address internal BOB;
    address internal CAROL;
    address internal RECEIVER;
    address internal ORACLE; // the condition's reporter (unrelated to the vault adapter)

    IConditionalTokensExt internal ct;
    MockERC20 internal collateral;
    MockERC4626 internal erc4626;
    ERC4626VaultAdapter internal adapter;
    YieldBearingOutcomeTokens internal vault;

    bytes32 internal questionId;
    bytes32 internal conditionId;
    IYieldBearingOutcomeTokens.MarketParams internal marketParams;
    bytes32 internal id;

    uint256 internal yesPositionId;
    uint256 internal noPositionId;

    function setUp() public virtual {
        ALICE = makeAddr("Alice");
        BOB = makeAddr("Bob");
        CAROL = makeAddr("Carol");
        RECEIVER = makeAddr("Receiver");
        ORACLE = makeAddr("Oracle");

        ct = IConditionalTokensExt(deployCode("ConditionalTokens.sol"));
        vm.label(address(ct), "ConditionalTokens");

        collateral = new MockERC20("Collateral", "COL");
        vm.label(address(collateral), "Collateral");

        erc4626 = new MockERC4626(IERC20(address(collateral)));
        vm.label(address(erc4626), "ERC4626");

        vault = new YieldBearingOutcomeTokens(ct);
        vm.label(address(vault), "Vault");

        adapter = new ERC4626VaultAdapter(IERC4626(address(erc4626)), address(vault));
        vm.label(address(adapter), "Adapter");

        questionId = keccak256("question");
        ct.prepareCondition(ORACLE, questionId, 2);
        conditionId = ct.getConditionId(ORACLE, questionId, 2);

        marketParams = IYieldBearingOutcomeTokens.MarketParams({
            collateralToken: IERC20(address(collateral)),
            conditionId: conditionId,
            vaultAdapter: IVaultAdapter(address(adapter))
        });
        id = _id(marketParams);

        yesPositionId = _positionId(true);
        noPositionId = _positionId(false);
    }

    /* ID HELPERS */

    function _id(IYieldBearingOutcomeTokens.MarketParams memory p) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(address(p.collateralToken), p.conditionId, address(p.vaultAdapter)));
    }

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
    /// approves the vault to pull the user's outcome tokens. Returns with the user holding `amount` of each side.
    function _mintOutcomeTokens(address user, IERC20 collateralToken, bytes32 condition, uint256 amount) internal {
        MockERC20(address(collateralToken)).mint(user, amount);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        vm.startPrank(user);
        collateralToken.approve(address(ct), amount);
        ct.splitPosition(collateralToken, PARENT_COLLECTION_ID, condition, partition, amount);
        ct.setApprovalForAll(address(vault), true);
        vm.stopPrank();
    }

    function _mintOutcomeTokens(address user, uint256 amount) internal {
        _mintOutcomeTokens(user, IERC20(address(collateral)), conditionId, amount);
    }

    /// @dev Deposits `amount` of `isYes` outcome tokens of the default market from `user` to `user`.
    function _deposit(address user, bool isYes, uint256 amount) internal returns (uint256 shares) {
        _mintOutcomeTokens(user, amount);
        vm.prank(user);
        shares = vault.deposit(marketParams, isYes, amount, user);
    }

    function _redeem(address user, bool isYes, uint256 shares) internal returns (uint256 assets) {
        vm.prank(user);
        assets = vault.redeem(marketParams, isYes, shares, user, user);
    }

    /// @dev Simulates yield by minting `amount` collateral straight into the ERC4626 vault, lifting its share price so
    /// `adapter.investedBalance` grows for every market invested through it.
    function _accrueYield(uint256 amount) internal {
        collateral.mint(address(erc4626), amount);
    }

    /// @dev The vault's actual ConditionalTokens balance of a side's position id.
    function _vaultPositionBalance(uint256 positionId) internal view returns (uint256) {
        return ct.balanceOf(address(vault), positionId);
    }
}
