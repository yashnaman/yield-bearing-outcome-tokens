// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";

/// @notice A MockERC4626 that, like solmate's ERC4626, reverts when a deposit would mint zero shares. Seed its
/// exchange rate above 1 (deposit 1 share's worth, then donate assets) so small deposits round down to zero shares
/// and revert — the vault behavior that forces the core to defer a tiny merge.
contract ZeroShareRevertingERC4626 is MockERC4626 {
    constructor(IERC20 _asset) MockERC4626(_asset) {}

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        shares = super.deposit(assets, receiver);
        require(shares != 0, "ZERO_SHARES");
    }
}
