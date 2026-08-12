// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

/// @title ERC-1155 Multi Token Receiver Interface
/// @dev See https://eips.ethereum.org/EIPS/eip-1155
interface IERC1155TokenReceiver is IERC165 {
    /// @notice Handles the receipt of a single ERC-1155 token type.
    /// @param operator The address that initiated the transfer.
    /// @param from The address the tokens were transferred from.
    /// @param id The id of the token type transferred.
    /// @param value The amount of tokens transferred.
    /// @param data Additional data with no specified format, forwarded from the transfer.
    /// @return `bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))` to accept the transfer.
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data)
        external
        returns (bytes4);

    /// @notice Handles the receipt of multiple ERC-1155 token types.
    /// @param operator The address that initiated the transfer.
    /// @param from The address the tokens were transferred from.
    /// @param ids The ids of the token types transferred, in the same order as `values`.
    /// @param values The amounts of each token type transferred, in the same order as `ids`.
    /// @param data Additional data with no specified format, forwarded from the transfer.
    /// @return `bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))` to accept the
    /// transfer.
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4);
}
