// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

/**
 *     @title ERC-1155 Multi Token Receiver Interface
 *     @dev See https://eips.ethereum.org/EIPS/eip-1155
 */
interface IERC1155TokenReceiver is IERC165 {
    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data)
        external
        returns (bytes4);

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4);
}
