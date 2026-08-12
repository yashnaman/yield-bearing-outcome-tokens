// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {Test} from "forge-std/Test.sol";

import {ShareIdLib} from "src/libraries/ShareIdLib.sol";

/// @notice The (pool, side) -> share id mapping, tested directly.
/// @dev Fixture-free: the mapping is pure arithmetic, and the core deliberately exposes none of it on-chain, so there
/// is no contract to call. These are the tests that used to run against the factory's `idFor` / `poolOfId` /
/// `isYesOfId` before those were removed as off-chain-derivable.
contract ShareIdLibTest is Test {
    /// @dev Recovering the pool from an id is a plain truncating cast — the same recovery Uniswap v4 uses for its
    /// ERC-6909 claim ids. Stated here rather than shipped as a contract function.
    function _poolOfId(uint256 id) internal pure returns (address) {
        return address(uint160(id));
    }

    function _isYesOfId(uint256 id) internal pure returns (bool) {
        return id & ShareIdLib.YES_FLAG != 0;
    }

    /// @dev The mapping is injective and invertible: an id names exactly one pool and one side.
    function testShareIdRoundTrips(address anyPool) public pure {
        uint256 yes = ShareIdLib.idFor(anyPool, true);
        uint256 no = ShareIdLib.idFor(anyPool, false);

        assertTrue(yes != no, "the two sides get different ids");
        assertEq(_poolOfId(yes), anyPool, "YES id resolves back to the pool");
        assertEq(_poolOfId(no), anyPool, "NO id resolves back to the pool");
        assertTrue(_isYesOfId(yes), "YES id reads as YES");
        assertFalse(_isYesOfId(no), "NO id reads as NO");
    }

    /// @dev The pool address occupies the id's low 160 bits untouched, so the address is legible in the raw id. This is
    /// the property that makes share ids debuggable by eye.
    function testShareIdContainsThePoolAddress(address anyPool) public pure {
        assertEq(
            ShareIdLib.idFor(anyPool, false), uint256(uint160(anyPool)), "the NO id IS the pool address, zero-extended"
        );
        assertEq(
            ShareIdLib.idFor(anyPool, true), uint256(uint160(anyPool)) | (1 << 160), "the YES id adds only bit 160"
        );
    }

    /// @dev Pins the worked example in README.md § Share ids, so the documented hex cannot drift from the derivation.
    function testShareIdHexMatchesTheDocumentedExample() public pure {
        address p = 0x5FbDB2315678afecb367f032d93F642f64180aa3;

        assertEq(
            ShareIdLib.idFor(p, false),
            uint256(bytes32(hex"0000000000000000000000005fbdb2315678afecb367f032d93f642f64180aa3")),
            "NO id"
        );
        assertEq(
            ShareIdLib.idFor(p, true),
            uint256(bytes32(hex"0000000000000000000000015fbdb2315678afecb367f032d93f642f64180aa3")),
            "YES id"
        );
    }

    /// @dev The reason the side bit sits above the address rather than being folded into it. Under a `pool` / `pool + 1`
    /// scheme a pool at X and a pool at X+1 would both claim the id X+1, and their holders' balances would add together
    /// in the same slot.
    function testAdjacentPoolAddressesNeverCollide() public pure {
        address a = address(uint160(0x1234));
        address b = address(uint160(0x1235)); // deliberately adjacent

        uint256[4] memory ids = [
            ShareIdLib.idFor(a, true), ShareIdLib.idFor(a, false), ShareIdLib.idFor(b, true), ShareIdLib.idFor(b, false)
        ];

        for (uint256 i; i < 4; ++i) {
            for (uint256 j = i + 1; j < 4; ++j) {
                assertTrue(ids[i] != ids[j], "no two ids of adjacent pools collide");
            }
        }
    }

    /// @dev Fuzzed injectivity across two independent pools, which is the property the ledger's correctness rests on:
    /// two markets must never share a slot.
    function testNoTwoMarketsShareAnId(address poolA, address poolB) public pure {
        vm.assume(poolA != poolB);

        uint256[4] memory ids = [
            ShareIdLib.idFor(poolA, true),
            ShareIdLib.idFor(poolA, false),
            ShareIdLib.idFor(poolB, true),
            ShareIdLib.idFor(poolB, false)
        ];

        for (uint256 i; i < 4; ++i) {
            for (uint256 j = i + 1; j < 4; ++j) {
                assertTrue(ids[i] != ids[j], "distinct (pool, side) pairs get distinct ids");
            }
        }
    }
}
