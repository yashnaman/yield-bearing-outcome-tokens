// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

/// @title IVaultAdapter
/// @author yashnaman
/// @notice Interface that the per-market adapter used by YieldBearingOutcomeTokens must implement to invest merged
/// collateral into a yield-bearing vault and divest it on demand.
interface IVaultAdapter {
    /// @notice Returns the collateral currently recoverable from the vault if everything were withdrawn now.
    /// @dev Must be denominated in outcome-token decimals. ConditionalTokens assumes outcome-token decimals equal
    /// collateral decimals, so the adapter is responsible for any conversion before returning the amount.
    function investedBalance() external view returns (uint256);

    /// @notice Invests `amount` of collateral, already transferred to the adapter, into the vault.
    function invest(uint256 amount) external;

    /// @notice Divests `amount` of collateral from the vault and transfers it back to the caller.
    /// @dev The mirror of `invest`. The returned collateral lets the vault split and hand outcome tokens to a withdrawer.
    function divest(uint256 amount) external;
}
