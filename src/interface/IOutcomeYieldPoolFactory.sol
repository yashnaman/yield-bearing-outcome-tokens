// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {IERC6909TokenSupply} from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

/// @title IOutcomeYieldPoolFactory
/// @author yashnaman
/// @notice The surface an {IOutcomeYieldPool} needs from its factory: the shared ERC-6909 share ledger it mints and
/// burns against.
/// @dev Declared separately so the pool can call the factory while the factory references the pool's creation code,
/// which would otherwise be a circular import. Extends the ERC-6909 token-supply interface, which is where
/// `totalSupply`, `balanceOf` and the operator/allowance surface come from.
/// @dev Only what the pool actually calls is declared here. Share-id arithmetic lives in {ShareIdLib} and is not
/// exposed on-chain at all; `deployPool` and `getPoolAddress` are on the concrete factory, since both mention the
/// concrete pool type.
interface IOutcomeYieldPoolFactory is IERC6909TokenSupply {
    /// @notice Emitted when a pool is deployed for the (`yieldVault`, `conditionId`) market.
    event PoolDeployed(IERC4626 indexed yieldVault, bytes32 indexed conditionId, address pool);

    /// @notice Mints `amount` shares of the caller's `isYes` side to `to`.
    /// @dev The id is derived from `msg.sender` via {ShareIdLib}, so a caller can only ever mint its own two ids. That
    /// is not the same as proving the caller is a real pool — see README.md § Accepted risks.
    function mint(address to, bool isYes, uint256 amount) external;

    /// @notice Burns `amount` shares of the caller's `isYes` side from `owner`, on `spender`'s authority.
    /// @dev Applies the same authorization as ERC-6909 `transferFrom`: `owner` acts freely, an operator of `owner`
    /// acts freely, and anyone else spends a per-id allowance. The caller forwards the `spender` that initiated the
    /// redemption, since the factory sees only the pool as `msg.sender`.
    function burn(address spender, address owner, bool isYes, uint256 amount) external;
}
