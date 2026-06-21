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
    /// binary markets.
    bytes32 public constant PARENT_COLLECTION_ID = bytes32(0);

    /// @dev Virtual shares and assets, added to the totals in every share conversion to mitigate share price
    /// manipulation when a side is empty. See OpenZeppelin's ERC-4626 inflation-attack note.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    error NoOtherERC1155Accepted();
    error TransferFailed();
    error ApproveFailed();

    /// @dev Holds the share accounting for one side (YES or NO) of one market.
    struct Side {
        uint256 totalShares;
        mapping(address user => uint256 shares) shares;
    }

    /// @notice The share accounting of each market side, keyed by market `id` then by `isYes`.
    mapping(bytes32 id => mapping(bool isYes => Side)) internal side;

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

    /// @dev Returns the market `id`, the hash of the pair (`conditionId`, `vaultAdapter`) that uniquely identifies it.
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

        uint256 indexSet = isYes ? 1 : 2;
        uint256 positionId = CTHelpers.getPositionId(
            address(marketParams.collateralToken),
            CTHelpers.getCollectionId(PARENT_COLLECTION_ID, marketParams.conditionId, indexSet)
        );

        // shares = assets * (totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS), rounded down.
        uint256 totalAssets = CONDITIONAL_TOKENS.balanceOf(address(this), positionId)
            + marketParams.vaultAdapter.investedBalance(marketParams);
        shares = assets * (side[id][isYes].totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS);

        side[id][isYes].totalShares += shares;
        side[id][isYes].shares[to] += shares;

        CONDITIONAL_TOKENS.safeTransferFrom(msg.sender, address(this), positionId, assets, "");

        _mergeAndInvest(marketParams);

        emit Deposit(id, isYes, msg.sender, to, assets, shares);
    }

    /// @dev Merges as many complete sets as the current YES and NO balances allow into collateral, then sends that
    /// collateral to the market's adapter to be invested.
    function _mergeAndInvest(MarketParams calldata marketParams) internal {
        uint256 yesPositionId = CTHelpers.getPositionId(
            address(marketParams.collateralToken),
            CTHelpers.getCollectionId(PARENT_COLLECTION_ID, marketParams.conditionId, 1)
        );
        uint256 noPositionId = CTHelpers.getPositionId(
            address(marketParams.collateralToken),
            CTHelpers.getCollectionId(PARENT_COLLECTION_ID, marketParams.conditionId, 2)
        );

        uint256 yesOutcomeTokenBalance = CONDITIONAL_TOKENS.balanceOf(address(this), yesPositionId);
        uint256 noOutcomeTokenBalance = CONDITIONAL_TOKENS.balanceOf(address(this), noPositionId);

        // The number of complete sets is bounded by the scarcer side.
        uint256 completeSets =
            yesOutcomeTokenBalance > noOutcomeTokenBalance ? noOutcomeTokenBalance : yesOutcomeTokenBalance;

        if (completeSets > 0) {
            uint256[] memory partition = new uint256[](2);
            partition[0] = 1;
            partition[1] = 2;

            CONDITIONAL_TOKENS.mergePositions(
                marketParams.collateralToken, PARENT_COLLECTION_ID, marketParams.conditionId, partition, completeSets
            );

            require(
                marketParams.collateralToken.transfer(address(marketParams.vaultAdapter), completeSets),
                TransferFailed()
            );

            marketParams.vaultAdapter.invest(marketParams, completeSets);
        }
    }

    /// @inheritdoc IYieldBearingOutcomeTokens
    function redeem(MarketParams calldata marketParams, bool isYes, uint256 shares, address to)
        external
        returns (uint256 assets)
    {
        bytes32 id = _id(marketParams);

        uint256 indexSet = isYes ? 1 : 2;
        uint256 positionId = CTHelpers.getPositionId(
            address(marketParams.collateralToken),
            CTHelpers.getCollectionId(PARENT_COLLECTION_ID, marketParams.conditionId, indexSet)
        );

        uint256 danglingBalance = CONDITIONAL_TOKENS.balanceOf(address(this), positionId);

        // Total assets backing this side are the dangling outcome tokens plus the collateral in the vault, since each
        // unit of collateral splits back into one outcome token of this side.
        // assets = shares * (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES), rounded down.
        uint256 totalAssets = danglingBalance + marketParams.vaultAdapter.investedBalance(marketParams);
        assets = shares * (totalAssets + VIRTUAL_ASSETS) / (side[id][isYes].totalShares + VIRTUAL_SHARES);

        side[id][isYes].totalShares -= shares;
        side[id][isYes].shares[msg.sender] -= shares;

        if (danglingBalance < assets) {
            _divestAndSplit(marketParams, assets - danglingBalance);
        }

        CONDITIONAL_TOKENS.safeTransferFrom(address(this), to, positionId, assets, "");

        emit Redeem(id, isYes, msg.sender, to, shares, assets);
    }

    /// @dev Divests `amount` of collateral from the vault and splits it into an `amount`-sized YES/NO pair held by
    /// this contract. Internal because splitting only ever happens during a redemption that runs short of dangling
    /// tokens.
    function _divestAndSplit(MarketParams calldata marketParams, uint256 amount) internal {
        marketParams.vaultAdapter.divest(marketParams, amount);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;

        // `splitPosition` pulls the collateral from this contract, so approve it first.
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
    /// @dev Only accepts outcome tokens transferred by `CONDITIONAL_TOKENS`.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == address(CONDITIONAL_TOKENS), NoOtherERC1155Accepted());
        return this.onERC1155Received.selector;
    }

    /// @inheritdoc IERC1155TokenReceiver
    /// @dev Only accepts outcome tokens transferred by `CONDITIONAL_TOKENS`.
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        require(msg.sender == address(CONDITIONAL_TOKENS), NoOtherERC1155Accepted());
        return this.onERC1155BatchReceived.selector;
    }
}
