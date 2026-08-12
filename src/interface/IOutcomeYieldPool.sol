// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

/// @title IOutcomeYieldPool
/// @author yashnaman
/// @notice A single-market pool that earns yield on idle binary-market outcome tokens without ever trading on price.
/// @dev Deposited YES and NO tokens are matched into complete sets and merged into collateral at par, which is
/// invested in the market's ERC-4626 vault. Yield is distributed back by splitting it into fresh YES/NO pairs, so the
/// fully matched side earns the full rate and the surplus side is diluted by its utilization. Each side runs its own
/// share index, in the spirit of a lending pool's liquidity index.
/// @dev One pool serves exactly one market, so every function here takes only a side and an amount. The pool holds the
/// market's funds, while its shares are ERC-6909 tokens on the factory — so balances, transfers and operator grants
/// live on the factory, once for every market, while custody stays physically per market.
/// @dev This surface is deliberately near actions-only: a pool exposes nothing a caller could compute for itself from
/// the factory address, the pool creation code and (`yieldVault`, `conditionId`, `isYes`) — no position ids, no share
/// ids, no accounting views. What remains beyond the actions is the market identity, plus {COLLATERAL}, which is the
/// one value current chain state cannot reproduce. See README.md § Deriving everything off-chain.
interface IOutcomeYieldPool {
    /* ERRORS */

    /// @notice Thrown when a collateral approval granted in the constructor did not return true.
    error ApproveFailed();

    /// @notice Thrown when `conditionId` does not have exactly two outcome slots. An unprepared condition also lands
    /// here, since it reports zero slots.
    error NotBinaryCondition();

    /// @notice Thrown when the yield vault's `asset()` cannot back a market, i.e. it is the zero address or the vault
    /// itself.
    error InvalidCollateral();

    /// @notice Thrown when an ERC-1155 receiver hook is called by anything but the ConditionalTokens contract.
    error NotConditionalTokens();

    /// @notice Thrown when tokens pushed to this pool are not one of its two outcome positions.
    error UnknownPositionId();

    /// @notice Thrown when a batch transfer this pool did not initiate is pushed to it.
    error BatchDepositNotSupported();

    /* EVENTS */

    /// @notice Emitted on a deposit into the `isYes` side of this pool.
    /// @param isYes The side deposited, `true` for YES and `false` for NO.
    /// @param caller The address that initiated the deposit.
    /// @param to The address that received the minted shares.
    /// @param assets The amount of outcome tokens deposited.
    /// @param shares The amount of ERC-6909 shares minted.
    event Deposit(bool isYes, address indexed caller, address indexed to, uint256 assets, uint256 shares);

    /// @notice Emitted on a redemption from the `isYes` side of this pool.
    /// @param isYes The side redeemed, `true` for YES and `false` for NO.
    /// @param caller The address that initiated the redemption.
    /// @param onBehalf The address whose shares were burned.
    /// @param to The address that received the outcome tokens.
    /// @param shares The amount of ERC-6909 shares burned.
    /// @param assets The amount of outcome tokens redeemed.
    event Redeem(
        bool isYes, address indexed caller, address indexed onBehalf, address indexed to, uint256 shares, uint256 assets
    );

    /* MARKET IDENTITY */

    /// @notice The ERC-4626 vault this pool invests merged collateral into.
    /// @dev With {CONDITION_ID}, the pair that identifies this market and fixes the pool's own address. Kept on-chain
    /// so a pool is self-describing — everything else about it follows from these two.
    function YIELD_VAULT() external view returns (IERC4626);

    /// @notice The ConditionalTokens condition id of this market.
    function CONDITION_ID() external view returns (bytes32);

    /// @notice The collateral backing this market, read from `YIELD_VAULT.asset()` exactly once at construction.
    /// @dev Kept on-chain despite (`YIELD_VAULT`, `CONDITION_ID`) being the market identity, because this is the one
    /// value a caller cannot recover from current chain state: a vault whose `asset()` changes after deployment is
    /// pinned here to whatever it returned then, and calling `YIELD_VAULT().asset()` today would yield the wrong
    /// collateral — and therefore the wrong position ids — for exactly the hostile vaults that matter.
    function COLLATERAL() external view returns (IERC20);

    /* DEPOSIT & REDEEM */

    /// @notice Deposits `assets` outcome tokens of the `isYes` side and mints ERC-6909 shares to `to`.
    /// @dev Requires `setApprovalForAll(pool)` on ConditionalTokens first, since this pulls the outcome tokens from
    /// `msg.sender`. The push form needs neither: send the outcome tokens straight to the pool with ConditionalTokens'
    /// `safeTransferFrom`, passing the recipient as `abi.encode(to)` in the transfer's `data` (or leaving `data` empty
    /// to credit the sender). This function is that same path — it performs exactly that transfer on the caller's
    /// behalf — so the two can never price a deposit differently.
    /// @dev Returns nothing: the share count is decided inside the ERC-1155 callback that credits the deposit, which
    /// cannot pass a value back out through ConditionalTokens. Read it from the {Deposit} event, or from `to`'s
    /// balance on the factory.
    /// @dev Then rebalances, best-effort: any complete sets the deposit enables are merged into collateral and
    /// invested. If the yield vault reverts on that deposit the merge is rolled back, both sides stay dangling, and
    /// the match is retried on a later deposit or on any permissionless {mergeAndDeposit} call.
    /// @param isYes The side to deposit, `true` for YES and `false` for NO.
    /// @param assets The amount of outcome tokens to deposit.
    /// @param to The address that will own the minted shares.
    function deposit(bool isYes, uint256 assets, address to) external;

    /// @notice Burns `shares` of the `isYes` side from `onBehalf` and sends the redeemed outcome tokens to `to`.
    /// @dev Pays out of the pool's dangling outcome tokens first, and only withdraws collateral from the yield vault
    /// to split into a fresh pair when they are insufficient. The shares are burned on the factory, which applies the
    /// same authorization as ERC-6909 `transferFrom`: `msg.sender` must be `onBehalf`, an operator of `onBehalf`, or
    /// hold a sufficient allowance over that side's share id.
    /// @param isYes The side to redeem, `true` for YES and `false` for NO.
    /// @param shares The amount of shares to burn.
    /// @param onBehalf The address whose shares are burned.
    /// @param to The address that will receive the outcome tokens.
    /// @return assets The amount of outcome tokens sent to `to`.
    function redeem(bool isYes, uint256 shares, address onBehalf, address to) external returns (uint256 assets);

    /// @notice Merges every complete set the pool currently holds into collateral and invests it in the yield vault.
    /// @dev Permissionless and idempotent: it reads the amount to merge from the pool's own ConditionalTokens
    /// balances, so it takes no arguments and cannot be misrouted. A no-op when the pool holds no complete set.
    /// Reverts only if the yield vault itself reverts on the deposit, which is how {deposit} defers a merge the vault
    /// refuses. A vault that accepts the collateral but rounds the share count down — including to zero — is not
    /// treated as a refusal; see README.md § Accepted risks.
    function mergeAndDeposit() external;
}
