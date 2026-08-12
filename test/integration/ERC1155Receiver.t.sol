// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {BaseTest} from "test/Base.t.sol";
import {IERC6909} from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import {IERC6909TokenSupply} from "@openzeppelin/contracts/interfaces/IERC6909.sol";
import {IERC1155TokenReceiver} from "src/interface/IERC1155TokenReceiver.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";
import {IOutcomeYieldPool} from "src/interface/IOutcomeYieldPool.sol";

/// @notice The pool accepts ERC1155 transfers of its market's outcome tokens, and advertises the receiver
/// interface via ERC165.
contract ERC1155ReceiverTest is BaseTest {
    function testSupportsReceiverInterface() public view {
        assertTrue(
            pool.supportsInterface(type(IERC1155TokenReceiver).interfaceId), "advertises ERC1155 receiver interface"
        );
    }

    function testSupportsERC165InteraceItself() public view {
        assertTrue(pool.supportsInterface(0x01ffc9a7), "supports ERC165 itself as well");
    }

    /// @dev The shares are ERC-6909 tokens on the *factory*, not on the pool, so the two contracts advertise
    /// different things: the pool is a receiver, the factory is the token.
    function testERC6909LivesOnTheFactoryNotThePool() public view {
        assertFalse(pool.supportsInterface(type(IERC6909).interfaceId), "the pool is not the token");

        assertTrue(factory.supportsInterface(type(IERC6909).interfaceId), "the factory advertises ERC6909");
        assertTrue(factory.supportsInterface(type(IERC6909TokenSupply).interfaceId), "and the token-supply extension");
    }

    function testDoesNotSupportRandomInterface() public view {
        assertFalse(pool.supportsInterface(0xffffffff), "rejects unknown interface id");
    }

    /// @dev The hooks credit deposits, so they only listen to ConditionalTokens. Anyone else calling them directly
    /// would be claiming a transfer that never happened.
    function testHooksRejectCallersOtherThanConditionalTokens() public {
        vm.expectRevert(IOutcomeYieldPool.NotConditionalTokens.selector);
        pool.onERC1155Received(address(pool), address(0), yesPositionId, 1, "");

        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);
        vm.expectRevert(IOutcomeYieldPool.NotConditionalTokens.selector);
        pool.onERC1155BatchReceived(address(pool), address(0), ids, amounts, "");
    }

    /// @dev A transfer from the pool to itself moves nothing, so it is acknowledged but credits no deposit. This is
    /// what a redemption whose `to` is the pool collapses to.
    function testSelfTransferIsAcknowledgedButCreditsNothing() public {
        vm.prank(address(ct));
        assertEq(
            pool.onERC1155Received(address(pool), address(pool), yesPositionId, 1, ""),
            IERC1155TokenReceiver.onERC1155Received.selector,
            "returns onERC1155Received magic value"
        );

        assertEq(factory.totalSupply(yesShareId), 0, "a self-transfer mints no shares");
    }

    /// @dev The batch hook returns its magic value for the pool's own `splitPosition` mint, the only batch it takes.
    function testBatchHookReturnsMagicValueForOwnSplit() public {
        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);
        vm.prank(address(ct));
        assertEq(
            pool.onERC1155BatchReceived(address(pool), address(0), ids, amounts, ""),
            IERC1155TokenReceiver.onERC1155BatchReceived.selector,
            "returns onERC1155BatchReceived magic value"
        );
    }
}
