// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {ERC4626VaultAdapter} from "src/adapters/ERC4626VaultAdapter.sol";

/// @title IERC4626VaultAdapterFactory
/// @author yashnaman
/// @notice Interface for the stateless factory that deterministically deploys one ERC4626VaultAdapter per ERC-4626
/// vault for a single YieldBearingOutcomeTokens instance.
/// @dev The factory is bound to one YieldBearingOutcomeTokens instance at construction, so the CREATE2 salt is the
/// vault address alone. A given factory can therefore deploy at most one adapter per vault: redeploying for the same
/// vault reverts, which makes the adapter address a pure function of (factory, vault).
interface IERC4626VaultAdapterFactory {
    /// @notice Emitted when an adapter is deployed for `vault`.
    /// @param vault The ERC-4626 vault the adapter invests into.
    /// @param adapter The deployed adapter.
    event AdapterDeployed(IERC4626 indexed vault, address adapter);

    /// @notice The YieldBearingOutcomeTokens instance every adapter from this factory is bound to.
    function YIELD_BEARING_OUTCOME_TOKENS() external view returns (address);

    /// @notice Deploys the adapter for `vault` at its deterministic address.
    /// @dev Uses CREATE2 with the vault address as salt; reverts if the adapter already exists.
    function deployAdapter(IERC4626 vault) external returns (ERC4626VaultAdapter adapter);

    /// @notice Returns the address the adapter for `vault` will have (or already has).
    /// @dev Pure CREATE2 prediction; the address is valid whether or not `deployAdapter` has been called yet.
    function getAdapterAddress(IERC4626 vault) external view returns (address adapter);
}
