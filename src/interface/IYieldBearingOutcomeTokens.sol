// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";

/// @title IYieldBearingOutcomeTokens
/// @author yashnaman
/// @notice Interface for the YieldBearingOutcomeTokens vault, exposing its market type and events.
interface IYieldBearingOutcomeTokens {
    /// @notice Emitted on a deposit into the `isYes` side of market `id`.
    /// @param id The market the deposit was made to.
    /// @param isYes The side deposited, `true` for YES and `false` for NO.
    /// @param caller The address that initiated the deposit.
    /// @param to The address that received the minted shares.
    /// @param amount The amount of outcome tokens deposited.
    /// @param shares The amount of shares minted.
    event Deposit(
        bytes32 indexed id, bool isYes, address indexed caller, address indexed to, uint256 amount, uint256 shares
    );

    /// @notice Emitted on a redemption from the `isYes` side of market `id`.
    /// @param id The market the redemption was made from.
    /// @param isYes The side redeemed, `true` for YES and `false` for NO.
    /// @param caller The address that initiated the redemption.
    /// @param onBehalf The address whose shares were burned.
    /// @param to The address that received the outcome tokens.
    /// @param shares The amount of shares burned.
    /// @param amount The amount of outcome tokens redeemed.
    event Redeem(
        bytes32 indexed id,
        bool isYes,
        address indexed caller,
        address onBehalf,
        address indexed to,
        uint256 shares,
        uint256 amount
    );

    /// @notice Emitted when `authorizer` sets whether `authorized` may act on its behalf.
    /// @param authorizer The address granting or revoking the authorization.
    /// @param authorized The address being authorized or deauthorized.
    /// @param newIsAuthorized The new authorization status.
    event SetAuthorization(address indexed authorizer, address indexed authorized, bool newIsAuthorized);

    /// @notice The parameters that define a market served by the vault.
    /// @dev The market id is the hash of (`collateralToken`, `conditionId`, `vaultAdapter`).
    struct MarketParams {
        /// @dev The market's collateral ERC-20, also the asset a complete set of outcome tokens merges into.
        IERC20 collateralToken;
        /// @dev The ConditionalTokens condition id of the binary market.
        bytes32 conditionId;
        /// @dev The adapter that invests merged collateral into a vault and divests it on demand. It may switch the
        /// underlying vault or charge fees; the vault does not depend on either.
        IVaultAdapter vaultAdapter;
    }

    /// @dev Holds the per-side state (shares and dangling balance) for one side (YES or NO) of one market.
    struct Side {
        uint256 totalShares;
        /// @dev Outcome tokens of this side held by the vault and not yet merged, tracked internally instead of read
        /// from ConditionalTokens so a market's balance is isolated from others sharing the same position id.
        uint256 danglingBalance;
        mapping(address user => uint256 shares) shares;
    }

    /// @notice Returns the total shares minted against the `outcome` side of market `marketId`.
    /// @param marketId The id of the market, the hash of its (`collateralToken`, `conditionId`, `vaultAdapter`).
    /// @param outcome The side to query, `true` for YES and `false` for NO.
    /// @return The total shares minted on that side.
    function totalShares(bytes32 marketId, bool outcome) external view returns (uint256);

    /// @notice Returns the shares held by `user` on the `outcome` side of market `marketId`.
    /// @param marketId The id of the market, the hash of its (`collateralToken`, `conditionId`, `vaultAdapter`).
    /// @param outcome The side to query, `true` for YES and `false` for NO.
    /// @param user The address whose shares are queried.
    /// @return The shares held by `user` on that side.
    function sharesOf(bytes32 marketId, bool outcome, address user) external view returns (uint256);

    /// @notice Returns the dangling outcome-token balance the vault holds for the `outcome` side of market `marketId`:
    /// tokens received but not yet merged into collateral. Tracked internally per market so a market's balance is
    /// isolated from others sharing the same ConditionalTokens position id.
    /// @param marketId The id of the market, the hash of its (`collateralToken`, `conditionId`, `vaultAdapter`).
    /// @param outcome The side to query, `true` for YES and `false` for NO.
    /// @return The dangling outcome-token balance held on that side.
    function danglingBalance(bytes32 marketId, bool outcome) external view returns (uint256);

    /// @notice Deposits `assets` outcome tokens of the `isYes` side of `marketParams` and mints shares to `to`.
    /// @dev Pulls the outcome tokens from `msg.sender`, then rebalances the market: any complete sets the deposit
    /// enables are merged into collateral and invested.
    /// @param marketParams The market to deposit into.
    /// @param isYes The side to deposit, `true` for YES and `false` for NO.
    /// @param assets The amount of outcome tokens to deposit.
    /// @param to The address that will own the minted shares.
    /// @return shares The amount of shares minted.
    function deposit(MarketParams calldata marketParams, bool isYes, uint256 assets, address to)
        external
        returns (uint256 shares);

    /// @notice Burns `shares` of the `isYes` side of `marketParams` from `onBehalf` and sends the redeemed outcome
    /// tokens to `to`.
    /// @dev Pays out of the dangling outcome tokens first, and only divests collateral through the adapter to split
    /// into a fresh pair when the dangling balance is insufficient. `msg.sender` must be `onBehalf` itself or an
    /// address it has authorized via `setAuthorization`.
    /// @param marketParams The market to redeem from.
    /// @param isYes The side to redeem, `true` for YES and `false` for NO.
    /// @param shares The amount of shares to burn.
    /// @param onBehalf The address whose shares are burned.
    /// @param to The address that will receive the outcome tokens.
    /// @return assets The amount of outcome tokens sent to `to`.
    function redeem(MarketParams calldata marketParams, bool isYes, uint256 shares, address onBehalf, address to)
        external
        returns (uint256 assets);

    /// @notice Returns whether `authorized` may spend `authorizer`'s shares (i.e. redeem on its behalf).
    /// @param authorizer The address that owns the shares.
    /// @param authorized The address whose authorization is queried.
    /// @return Whether `authorized` is authorized to act on behalf of `authorizer`.
    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    /// @notice Sets whether `authorized` may spend `msg.sender`'s shares (i.e. redeem on its behalf).
    /// @param authorized The address to authorize or deauthorize.
    /// @param newIsAuthorized The new authorization status.
    function setAuthorization(address authorized, bool newIsAuthorized) external;
}
