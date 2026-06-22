// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IConditionalTokens} from "src/interface/IConditionalTokens.sol";
import {CTHelpers} from "src/libraries/CTHelpers.sol";
import {IERC1155TokenReceiver} from "src/interface/IERC1155TokenReceiver.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";

/// @title YieldBearingOutcomeTokens
/// @author yashnaman
/// @notice A singleton vault that puts idle binary-market outcome tokens to work without ever trading on price.
/// @dev Deposited YES and NO tokens of a market are matched into complete sets and merged into collateral, which is
/// invested in a vault through the market's adapter. Yield is distributed back to each side by splitting it into fresh
/// YES/NO pairs, so the scarce (fully matched) side earns the full rate and the surplus side is diluted by its
/// utilization. Each `(id, isYes)` side runs its own share index, in the spirit of a lending pool's liquidity index.
/// @dev The vault relies solely on the par identity `1 YES + 1 NO <-> 1 collateral`, never on market prices. It needs
/// no special handling at resolution: `splitPosition` and `mergePositions` only require the condition to be prepared,
/// not resolved, so deposits and redemptions keep working afterwards. Because the same collateral backs both sides at
/// once and splitting always succeeds, every redemption can reconstitute the outcome tokens it owes and the contract
/// stays solvent to the token. A holder of the winning side is simply better off redeeming their shares here and then
/// redeeming the outcome tokens 1:1 at the ConditionalTokens contract.
contract YieldBearingOutcomeTokens is IYieldBearingOutcomeTokens, IERC1155TokenReceiver {
    /// @notice The ConditionalTokens contract that mints, splits and merges the outcome tokens.
    IConditionalTokens public immutable CONDITIONAL_TOKENS;

    /// @notice The parent collection id used for every position. Fixed to zero to restrict the vault to top-level
    /// markets, i.e. positions not nested under another collection. (Binary-market support is a separate assumption,
    /// enforced by the hardcoded `{1},{2}` partition.)
    bytes32 public constant PARENT_COLLECTION_ID = bytes32(0);

    /// @dev Virtual shares and assets, added to the totals in every share conversion to mitigate share price
    /// manipulation when a side is empty. See OpenZeppelin's ERC-4626 inflation-attack note.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    error TransferFailed();
    error ApproveFailed();
    /// @notice Thrown when `msg.sender` is neither `onBehalf` nor authorized to act on its behalf.
    error Unauthorized();
    /// @notice Thrown when `setAuthorization` is called with the value already set.
    error AlreadySet();

    /// @notice The per-side state (shares and dangling balance) of each market, keyed by market `id` then by `isYes`.
    mapping(bytes32 id => mapping(bool isYes => Side)) internal side;

    /// @inheritdoc IYieldBearingOutcomeTokens
    mapping(address authorizer => mapping(address authorized => bool)) public isAuthorized;

    /// @param conditionalTokens The ConditionalTokens contract backing every market this vault serves.
    constructor(IConditionalTokens conditionalTokens) {
        CONDITIONAL_TOKENS = conditionalTokens;
    }

    /// @inheritdoc IYieldBearingOutcomeTokens
    /// @dev Exposed explicitly because `Side` holds a mapping and therefore has no auto-generated getter.
    function totalShares(bytes32 marketId, bool outcome) external view returns (uint256) {
        return side[marketId][outcome].totalShares;
    }

    /// @inheritdoc IYieldBearingOutcomeTokens
    function sharesOf(bytes32 marketId, bool outcome, address user) external view returns (uint256) {
        return side[marketId][outcome].shares[user];
    }

    /// @inheritdoc IYieldBearingOutcomeTokens
    /// @dev Exposed explicitly because `Side` holds a mapping and therefore has no auto-generated getter.
    function danglingBalance(bytes32 marketId, bool outcome) external view returns (uint256) {
        return side[marketId][outcome].danglingBalance;
    }

    /// @dev Returns the market `id`, the hash of (`collateralToken`, `conditionId`, `vaultAdapter`) that uniquely
    /// identifies it.
    function _id(MarketParams calldata marketParams) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                address(marketParams.collateralToken), marketParams.conditionId, address(marketParams.vaultAdapter)
            )
        );
    }

    /// @inheritdoc IYieldBearingOutcomeTokens
    function deposit(MarketParams calldata marketParams, bool isYes, uint256 assets, address to)
        external
        returns (uint256 shares)
    {
        bytes32 id = _id(marketParams);

        uint256 positionId = CTHelpers.getPositionId(
            address(marketParams.collateralToken),
            CTHelpers.getCollectionId(PARENT_COLLECTION_ID, marketParams.conditionId, isYes ? 1 : 2)
        );

        CONDITIONAL_TOKENS.safeTransferFrom(msg.sender, address(this), positionId, assets, "");

        Side storage depositSide = side[id][isYes];
        Side storage otherSide = side[id][!isYes];

        // shares = assets * (totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS), rounded down.
        uint256 depositSideTotalShares = depositSide.totalShares;
        uint256 dangling = depositSide.danglingBalance;
        shares = assets * (depositSideTotalShares + VIRTUAL_SHARES)
            / (dangling + marketParams.vaultAdapter.investedBalance(marketParams) + VIRTUAL_ASSETS);

        depositSide.totalShares = depositSideTotalShares + shares;
        depositSide.shares[to] += shares;

        dangling += assets;

        // Compute how many complete sets can now be merged. depositSide's dangling balance is always written back;
        // otherSide is only touched when a merge actually happens.
        uint256 otherDanglingBalance = otherSide.danglingBalance;
        uint256 completeSets = dangling < otherDanglingBalance ? dangling : otherDanglingBalance;

        depositSide.danglingBalance = dangling - completeSets;
        if (completeSets > 0) {
            otherSide.danglingBalance = otherDanglingBalance - completeSets;
            _mergeAndInvest(marketParams, completeSets);
        }

        emit Deposit(id, isYes, msg.sender, to, assets, shares);
    }

    /// @dev Merges `completeSets` complete sets into collateral, then sends that collateral to the market's adapter to
    /// be invested.
    function _mergeAndInvest(MarketParams calldata marketParams, uint256 completeSets) internal {
        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        // Assumes a binary market: merging the {1},{2} pair returns collateral. If outcomeSlotCount > 2 this instead
        // mints a combined ERC1155 position rather than returning collateral, so the transfer below reverts and the deposit
        // fails. The outcome token already deposited on the other side stays redeemable, so there is no self-harm or
        // stuck funds.
        CONDITIONAL_TOKENS.mergePositions(
            marketParams.collateralToken, PARENT_COLLECTION_ID, marketParams.conditionId, partition, completeSets
        );

        // Raw transfer with a bool check, the same way ConditionalTokens handles collateral. A token that does not
        // conform to this cannot back outcome tokens in ConditionalTokens either, so we inherit that limitation here.
        require(
            marketParams.collateralToken.transfer(address(marketParams.vaultAdapter), completeSets), TransferFailed()
        );

        marketParams.vaultAdapter.invest(marketParams, completeSets);
    }

    /// @inheritdoc IYieldBearingOutcomeTokens
    function redeem(MarketParams calldata marketParams, bool isYes, uint256 shares, address onBehalf, address to)
        external
        returns (uint256 assets)
    {
        require(msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender], Unauthorized());

        bytes32 id = _id(marketParams);

        uint256 positionId = CTHelpers.getPositionId(
            address(marketParams.collateralToken),
            CTHelpers.getCollectionId(PARENT_COLLECTION_ID, marketParams.conditionId, isYes ? 1 : 2)
        );

        Side storage redeemSide = side[id][isYes];
        uint256 redeemSideTotalShares = redeemSide.totalShares;
        uint256 dangling = redeemSide.danglingBalance;

        // Total assets backing this side are the dangling outcome tokens plus the collateral invested through the
        // adapter, since each unit of collateral splits back into one outcome token of this side.
        // assets = shares * (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES), rounded down.
        assets = shares * (dangling + marketParams.vaultAdapter.investedBalance(marketParams) + VIRTUAL_ASSETS)
            / (redeemSideTotalShares + VIRTUAL_SHARES);

        redeemSide.totalShares = redeemSideTotalShares - shares;
        redeemSide.shares[onBehalf] -= shares;

        if (dangling < assets) {
            uint256 amount = assets - dangling;
            // Settle both sides' dangling balances before the external divest call: a reentrant redeem must observe
            // this side already zeroed, otherwise it could reuse the stale balance to spend another market's tokens.
            side[id][!isYes].danglingBalance += amount;
            redeemSide.danglingBalance = 0;
            _divestAndSplit(marketParams, amount);
        } else {
            redeemSide.danglingBalance = dangling - assets;
        }

        CONDITIONAL_TOKENS.safeTransferFrom(address(this), to, positionId, assets, "");

        emit Redeem(id, isYes, msg.sender, onBehalf, to, shares, assets);
    }

    /// @inheritdoc IYieldBearingOutcomeTokens
    function setAuthorization(address authorized, bool newIsAuthorized) external {
        require(newIsAuthorized != isAuthorized[msg.sender][authorized], AlreadySet());

        isAuthorized[msg.sender][authorized] = newIsAuthorized;

        emit SetAuthorization(msg.sender, authorized, newIsAuthorized);
    }

    /// @dev Divests `amount` of collateral from the vault and splits it into an `amount`-sized YES/NO pair held by
    /// this contract. Internal because splitting only ever happens during a redemption that runs short of dangling
    /// tokens.
    function _divestAndSplit(MarketParams calldata marketParams, uint256 amount) internal {
        marketParams.vaultAdapter.divest(marketParams, amount);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        // `splitPosition` pulls the collateral from this contract, so approve it first. Raw approve with a bool check,
        // the same way ConditionalTokens handles collateral; a token that does not conform cannot back outcome tokens
        // in ConditionalTokens either, so we inherit that limitation here.
        require(marketParams.collateralToken.approve(address(CONDITIONAL_TOKENS), amount), ApproveFailed());

        CONDITIONAL_TOKENS.splitPosition(
            marketParams.collateralToken, PARENT_COLLECTION_ID, marketParams.conditionId, partition, amount
        );
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155TokenReceiver).interfaceId;
    }

    /// @inheritdoc IERC1155TokenReceiver
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /// @inheritdoc IERC1155TokenReceiver
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
