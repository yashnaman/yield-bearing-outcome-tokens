// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

/// @title SharesMathLib
/// @author yashnaman
/// @notice Share/asset conversions for one side of a market, in the style of morpho-blue's SharesMathLib.
/// @dev Both conversions round down, so the rounding error always favours the pool over the caller. The rounding
/// direction is part of each function's name; there is deliberately no `Up` variant, because no call site needs one.
library SharesMathLib {
    /// @dev Virtual shares and assets, added to the totals in every conversion so that an empty side has a defined
    /// and un-manipulable share price. See OpenZeppelin's ERC-4626 inflation-attack note.
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    /// @dev Shares minted for `assets`, priced against the side's totals before the deposit.
    function toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return assets * (totalShares + VIRTUAL_SHARES) / (totalAssets + VIRTUAL_ASSETS);
    }

    /// @dev Assets owed for `shares`, priced against the side's current totals.
    function toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return shares * (totalAssets + VIRTUAL_ASSETS) / (totalShares + VIRTUAL_SHARES);
    }
}
