// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice Minimal ERC4626-style vault sufficient for the YieldBearingOutcomeTokens core.
/// @dev Shares track 1:1 with deposited assets. Only the functions the core uses are implemented; cast its address to
/// IERC4626 when wiring it up.
contract MockERC4626 {
    IERC20 public immutable asset_;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(IERC20 _asset) {
        asset_ = _asset;
    }

    function asset() external view returns (address) {
        return address(asset_);
    }

    function totalAssets() public view returns (uint256) {
        return asset_.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : assets * supply / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : shares * totalAssets() / supply;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        require(asset_.transferFrom(msg.sender, address(this), assets), "transferFrom failed");
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = convertToShares(assets);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        require(asset_.transfer(receiver, assets), "transfer failed");
    }
}
