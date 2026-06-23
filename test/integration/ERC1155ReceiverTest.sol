// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/BaseTest.sol";
import {IERC1155TokenReceiver} from "src/interface/IERC1155TokenReceiver.sol";

/// @notice The vault only accepts ERC1155 transfers forwarded by ConditionalTokens, and advertises the receiver
/// interface via ERC165.
contract ERC1155ReceiverTest is BaseTest {
    function testSupportsReceiverInterface() public view {
        assertTrue(
            vault.supportsInterface(type(IERC1155TokenReceiver).interfaceId), "advertises ERC1155 receiver interface"
        );
    }

    function testDoesNotSupportRandomInterface() public view {
        assertFalse(vault.supportsInterface(0xffffffff), "rejects unknown interface id");
        assertFalse(vault.supportsInterface(0x01ffc9a7), "does not over-claim ERC165 itself");
    }

    /// @dev The hooks return their ERC1155 magic-value selectors.
    function testHooksReturnMagicValues() public view {
        assertEq(
            vault.onERC1155Received(address(0), address(0), 0, 0, ""),
            IERC1155TokenReceiver.onERC1155Received.selector,
            "returns onERC1155Received magic value"
        );

        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);
        assertEq(
            vault.onERC1155BatchReceived(address(0), address(0), ids, amounts, ""),
            IERC1155TokenReceiver.onERC1155BatchReceived.selector,
            "returns onERC1155BatchReceived magic value"
        );
    }
}
