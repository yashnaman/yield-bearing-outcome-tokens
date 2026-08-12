// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

/// @title ShareIdLib
/// @author yashnaman
/// @notice The mapping from a (pool, side) pair to the ERC-6909 share id that represents it.
/// @dev A library rather than a function on either contract because both need it — {OutcomeYieldPoolFactory} derives
/// the id from `msg.sender` on every mint and burn, which is what confines a caller to its own two ids, and
/// {OutcomeYieldPool} derives its own two at construction. Stating the formula once keeps a security-critical mapping
/// from drifting between them.
/// @dev Nothing here is exposed on-chain. Consumers that need an id compute it themselves; see README.md § Deriving
/// everything off-chain.
library ShareIdLib {
    /// @dev Set in a share id iff the id is the YES side. Sits at bit 160, immediately above the 160-bit pool address,
    /// so the address occupies the id's low bits untouched and recovering it is a plain truncating cast —
    /// `address(uint160(id))`, the same id convention Uniswap v4 uses for its ERC-6909 claims.
    uint256 internal constant YES_FLAG = 1 << 160;

    /// @dev Injective in (`pool`, `isYes`) because the address bits and the side bit never overlap, so no two markets
    /// can ever share an id. Folding the side *into* the address range would not be: with `pool` for YES and
    /// `pool + 1` for NO, a pool at `X` and a pool at `X + 1` would collide on the id `X + 1` and their holders'
    /// balances would add together in the same slot.
    function idFor(address pool, bool isYes) internal pure returns (uint256) {
        return uint256(uint160(pool)) | (isYes ? YES_FLAG : 0);
    }
}
