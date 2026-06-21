// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";

/// @title IVaultAdapter
/// @author yashnaman
/// @notice Interface that the per-market adapter used by YieldBearingOutcomeTokens must implement to invest merged
/// collateral into a yield-bearing vault and divest it on demand.
/// @dev Every call receives the full `MarketParams`. An adapter MUST treat each market in isolation:
/// - reject `marketParams` whose collateral (or condition) it does not support;
/// - account invested funds per market id, so `investedBalance` returns only that market's balance.
/// These are security-critical invariants: without per-market accounting one market could read or divest another
/// market's funds, since the adapter custodies the pooled collateral.
interface IVaultAdapter {
    /// @notice Returns the collateral currently recoverable for `marketParams` if its position were withdrawn now.
    /// @dev Must be denominated in outcome-token decimals and scoped to this single market. ConditionalTokens assumes
    /// outcome-token decimals equal collateral decimals, so the adapter is responsible for any conversion.
    function investedBalance(IYieldBearingOutcomeTokens.MarketParams calldata marketParams)
        external
        view
        returns (uint256);

    /// @notice Invests `amount` of collateral, already transferred to the adapter, into the vault for `marketParams`.
    /// @dev Must revert if the adapter does not support `marketParams.collateralToken`.
    function invest(IYieldBearingOutcomeTokens.MarketParams calldata marketParams, uint256 amount) external;

    /// @notice Divests `amount` of collateral for `marketParams` from the vault and transfers it back to the caller.
    /// @dev The mirror of `invest`. Must revert if `amount` exceeds the funds this market has invested, so one market
    /// can never pull another's collateral.
    function divest(IYieldBearingOutcomeTokens.MarketParams calldata marketParams, uint256 amount) external;
}
