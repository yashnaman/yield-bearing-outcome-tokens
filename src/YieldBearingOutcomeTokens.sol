// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {IConditionalTokens} from "src/interface/IConditionalTokens.sol";
import {CTHelpers} from "src/libraries/CTHelpers.sol";
import {IERC1155TokenReceiver} from "src/interface/IERC1155TokenReceiver.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";

/// @title YieldBearingOutcomeTokens
/// @author yashnaman
/// @notice A singleton vault that puts idle binary-market outcome tokens to work without ever trading on price.
/// @dev Deposited YES and NO tokens of a market are matched into complete sets and merged into collateral, which is
/// deposited into the market's ERC-4626 yield vault. Yield is distributed back to each side by splitting it into fresh
/// YES/NO pairs, so the scarce (fully matched) side earns the full rate and the surplus side is diluted by its
/// utilization. Each `(id, isYes)` side runs its own share index, in the spirit of a lending pool's liquidity index.
/// @dev A market is the pair (`yieldVault`, `conditionId`); its collateral is the yield vault's underlying `asset()`.
/// The yield-vault shares minted by investing merged collateral are tracked per market in `vaultSharesOf`, so two
/// markets that share a ConditionalTokens position-id pool (same collateral and condition over different yield vaults)
/// never reach each other's funds.
/// @dev The vault relies solely on the par identity `1 YES + 1 NO <-> 1 collateral`, never on market prices. It needs
/// no special handling at resolution: `splitPosition` and `mergePositions` only require the condition to be prepared,
/// not resolved, so deposits and redemptions keep working afterwards. Because the same collateral backs both sides at
/// once and splitting always succeeds, every redemption can reconstitute the outcome tokens it owes and the contract
/// stays solvent to the token. A holder of the winning side is simply better off redeeming their shares here and then
/// redeeming the outcome tokens 1:1 at the ConditionalTokens contract.
contract YieldBearingOutcomeTokens is IYieldBearingOutcomeTokens, IERC1155TokenReceiver {
    /* ERRORS */

    error ApproveFailed();
    /// @notice Thrown when `msg.sender` is neither `onBehalf` nor authorized to act on its behalf.
    error Unauthorized();
    /// @notice Thrown when `setAuthorization` is called with the value already set.
    error AlreadySet();

    /* IMMUTABLES & CONSTANTS */

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

    /* STORAGE */

    /// @notice The per-side state (shares and dangling balance) of each market, keyed by market `id` then by `isYes`.
    mapping(bytes32 id => mapping(bool isYes => Side)) internal side;

    /// @notice Yield-vault shares held on behalf of each market id, so each market's invested balance is tracked in
    /// isolation. The id matches `keccak256(yieldVault, conditionId)`.
    mapping(bytes32 id => uint256 shares) public vaultSharesOf;

    /// @inheritdoc IYieldBearingOutcomeTokens
    mapping(address authorizer => mapping(address authorized => bool)) public isAuthorized;

    /* CONSTRUCTOR */

    /// @param conditionalTokens The ConditionalTokens contract backing every market this vault serves.
    constructor(IConditionalTokens conditionalTokens) {
        CONDITIONAL_TOKENS = conditionalTokens;
    }

    /* DEPOSIT */

    /// @inheritdoc IYieldBearingOutcomeTokens
    function deposit(IERC4626 yieldVault, bytes32 conditionId, bool isYes, uint256 assets, address to)
        external
        returns (uint256 shares)
    {
        bytes32 id = _id(yieldVault, conditionId);
        IERC20 collateralToken = IERC20(yieldVault.asset());

        // Pull the deposited outcome tokens
        {
            uint256 positionId = _outcomePositionId(collateralToken, conditionId, isYes);
            CONDITIONAL_TOKENS.safeTransferFrom(msg.sender, address(this), positionId, assets, "");
        }

        Side storage depositSide = side[id][isYes];
        Side storage otherSide = side[id][!isYes];

        // shares = assets * (totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS), rounded down.
        uint256 depositSideTotalShares = depositSide.totalShares;
        uint256 dangling = depositSide.danglingBalance;
        shares = assets * (depositSideTotalShares + VIRTUAL_SHARES)
            / (dangling + _investedBalance(yieldVault, id) + VIRTUAL_ASSETS);

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
            _mergeAndDeposit(yieldVault, conditionId, collateralToken, id, completeSets);
        }

        emit Deposit(id, isYes, msg.sender, to, assets, shares);
    }

    /// @dev Merges `completeSets` complete sets into collateral, then deposits that collateral into the market's yield
    /// vault and books the minted shares to the market.
    function _mergeAndDeposit(
        IERC4626 yieldVault,
        bytes32 conditionId,
        IERC20 collateralToken,
        bytes32 id,
        uint256 completeSets
    ) internal {
        // Assumes a binary market: merging the {1},{2} pair returns collateral. If outcomeSlotCount > 2 this instead
        // mints a combined ERC1155 position rather than returning collateral, so the deposit below reverts and the
        // deposit fails. The outcome token already deposited on the other side stays redeemable, so there is no
        // self-harm or stuck funds.
        CONDITIONAL_TOKENS.mergePositions(collateralToken, PARENT_COLLECTION_ID, conditionId, partition(), completeSets);

        // `deposit` pulls the collateral from this contract, so approve it first. Raw approve with a bool check, the
        // same way ConditionalTokens handles collateral; a token that does not conform cannot back outcome tokens in
        // ConditionalTokens either, so we inherit that limitation here.
        require(collateralToken.approve(address(yieldVault), completeSets), ApproveFailed());

        // ACCEPTED RISK: a 1-wei opposite deposit forces a 1-wei merge, and if the vault rounds `deposit(1)` to 0
        // shares the collateral reaches the vault but `vaultSharesOf[id]` does not grow, leaking 1 wei of backing to the
        // vault's other depositors. Bounded to ~1 wei per attack and self-harming (the attacker holds losing market shares too
        // and pays gas), so it is uneconomical. If underlying vault has virtual shares calculation with high decimals offset, 
        // the attack impact reduces even further.
        vaultSharesOf[id] += yieldVault.deposit(completeSets, address(this));
    }

    /* REDEEM */

    /// @inheritdoc IYieldBearingOutcomeTokens
    function redeem(IERC4626 yieldVault, bytes32 conditionId, bool isYes, uint256 shares, address onBehalf, address to)
        external
        returns (uint256 assets)
    {
        require(msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender], Unauthorized());

        bytes32 id = _id(yieldVault, conditionId);
        IERC20 collateralToken = IERC20(yieldVault.asset());

        Side storage redeemSide = side[id][isYes];
        uint256 redeemSideTotalShares = redeemSide.totalShares;
        uint256 dangling = redeemSide.danglingBalance;

        // Total assets backing this side are the dangling outcome tokens plus the collateral invested in the vault,
        // since each unit of collateral splits back into one outcome token of this side.
        // assets = shares * (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES), rounded down.
        assets = shares * (dangling + _investedBalance(yieldVault, id) + VIRTUAL_ASSETS)
            / (redeemSideTotalShares + VIRTUAL_SHARES);

        redeemSide.totalShares = redeemSideTotalShares - shares;
        redeemSide.shares[onBehalf] -= shares;

        if (dangling < assets) {
            uint256 amount = assets - dangling;
            // Settle both sides' dangling balances before the external withdraw call: a reentrant redeem must observe
            // this side already zeroed, otherwise it could reuse the stale balance to spend another market's tokens.
            side[id][!isYes].danglingBalance += amount;
            redeemSide.danglingBalance = 0;
            _withdrawAndSplit(yieldVault, conditionId, collateralToken, id, amount);
        } else {
            redeemSide.danglingBalance = dangling - assets;
        }

        // Send the redeemed outcome tokens out
        uint256 positionId = _outcomePositionId(collateralToken, conditionId, isYes);
        CONDITIONAL_TOKENS.safeTransferFrom(address(this), to, positionId, assets, "");

        emit Redeem(id, isYes, msg.sender, onBehalf, to, shares, assets);
    }

    /// @dev Withdraws `amount` of collateral from the yield vault and splits it into an `amount`-sized YES/NO pair held
    /// by this contract. Internal because splitting only ever happens during a redemption that runs short of dangling
    /// tokens. The share subtraction reverts if the market tries to withdraw more than it invested.
    function _withdrawAndSplit(
        IERC4626 yieldVault,
        bytes32 conditionId,
        IERC20 collateralToken,
        bytes32 id,
        uint256 amount
    ) internal {
        vaultSharesOf[id] -= yieldVault.withdraw(amount, address(this), address(this));

        // `splitPosition` pulls the collateral from this contract, so approve it first. Raw approve with a bool check,
        // the same way ConditionalTokens handles collateral; a token that does not conform cannot back outcome tokens
        // in ConditionalTokens either, so we inherit that limitation here.
        require(collateralToken.approve(address(CONDITIONAL_TOKENS), amount), ApproveFailed());

        CONDITIONAL_TOKENS.splitPosition(collateralToken, PARENT_COLLECTION_ID, conditionId, partition(), amount);
    }

    /* AUTHORIZATION */

    /// @inheritdoc IYieldBearingOutcomeTokens
    function setAuthorization(address authorized, bool newIsAuthorized) external {
        require(newIsAuthorized != isAuthorized[msg.sender][authorized], AlreadySet());

        isAuthorized[msg.sender][authorized] = newIsAuthorized;

        emit SetAuthorization(msg.sender, authorized, newIsAuthorized);
    }

    /* STORAGE VIEW */

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

    /// @inheritdoc IYieldBearingOutcomeTokens
    function investedBalance(IERC4626 yieldVault, bytes32 conditionId) public view returns (uint256) {
        return _investedBalance(yieldVault, _id(yieldVault, conditionId));
    }

    /* INTERNAL HELPERS */

    /// @dev The collateral recoverable for market `id` if its position in `yieldVault` were withdrawn now. Takes the
    /// pre-computed `id` so callers that already have it skip recomputing the hash. Only the shares booked to this
    /// market are converted, so other markets' funds are never reported here.
    function _investedBalance(IERC4626 yieldVault, bytes32 id) internal view returns (uint256) {
        return yieldVault.previewRedeem(vaultSharesOf[id]);
    }

    /// @dev Returns the market `id`, the hash of (`yieldVault`, `conditionId`) that uniquely identifies it.
    function _id(IERC4626 yieldVault, bytes32 conditionId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(address(yieldVault), conditionId));
    }

    /// @dev The ERC-1155 position id of the `isYes` side of the (`collateralToken`, `conditionId`) market.
    function _outcomePositionId(IERC20 collateralToken, bytes32 conditionId, bool isYes)
        internal
        view
        returns (uint256)
    {
        return CTHelpers.getPositionId(
            address(collateralToken), CTHelpers.getCollectionId(PARENT_COLLECTION_ID, conditionId, isYes ? 1 : 2)
        );
    }

    /// @dev returns the partition for a binary conditional token the partition [1,2] = [0b01, 0b10]
    function partition() internal pure returns (uint256[] memory partition_) {
        assembly ("memory-safe") {
            partition_ := mload(0x40)
            mstore(partition_, 2)
            mstore(add(partition_, 0x20), 1)
            mstore(add(partition_, 0x40), 2)
            mstore(0x40, add(partition_, 0x60))
        }
    }

    /* ERC-1155 RECEIVER */

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
