// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC4626VaultAdapterFactory} from "src/interface/IERC4626VaultAdapterFactory.sol";
import {ERC4626VaultAdapter} from "src/adapters/ERC4626VaultAdapter.sol";

/// @title ERC4626VaultAdapterFactory
/// @author yashnaman
/// @notice Deploys ERC4626VaultAdapter instances at deterministic addresses for a single YieldBearingOutcomeTokens
/// instance.
/// @dev Holds no storage state: the YieldBearingOutcomeTokens instance is fixed at construction as an immutable, so
/// every adapter is bound to it and the CREATE2 salt is the vault address alone. The deployed address is therefore a
/// pure function of (factory, vault) and can be predicted with `getAdapterAddress` before deployment.
contract ERC4626VaultAdapterFactory is IERC4626VaultAdapterFactory {
    /// @inheritdoc IERC4626VaultAdapterFactory
    address public immutable YIELD_BEARING_OUTCOME_TOKENS;

    error ZeroAddress();

    /// @param yieldBearingOutcomeTokens The instance every adapter deployed by this factory is bound to.
    constructor(address yieldBearingOutcomeTokens) {
        require(yieldBearingOutcomeTokens != address(0), ZeroAddress());

        YIELD_BEARING_OUTCOME_TOKENS = yieldBearingOutcomeTokens;
    }

    /// @inheritdoc IERC4626VaultAdapterFactory
    /// @dev The CREATE2 deployment reverts if an adapter already exists at the address, so each vault can be deployed
    /// only once per factory.
    function deployAdapter(IERC4626 vault) external returns (ERC4626VaultAdapter adapter) {
        adapter = new ERC4626VaultAdapter{salt: _salt(vault)}(vault, YIELD_BEARING_OUTCOME_TOKENS);

        emit AdapterDeployed(vault, address(adapter));
    }

    /// @inheritdoc IERC4626VaultAdapterFactory
    function getAdapterAddress(IERC4626 vault) external view returns (address adapter) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(ERC4626VaultAdapter).creationCode, abi.encode(vault, YIELD_BEARING_OUTCOME_TOKENS))
        );
        bytes32 data = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(vault), initCodeHash));
        adapter = address(uint160(uint256(data)));
    }

    /// @dev The salt is the vault address, so a vault maps to exactly one adapter per factory.
    function _salt(IERC4626 vault) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(address(vault))));
    }
}
