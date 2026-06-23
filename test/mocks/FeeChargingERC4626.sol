// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title FeeChargingERC4626
/// @notice An *honest* ERC-4626 vault that skims a flat `FEE_BIPS` deposit fee to a sink and keeps only the net. It
/// reports `convertToAssets` accurately (net of the fee) and always honors `withdraw` up to its backing. Used to show
/// the core contract does not depend on the vault returning everything it received: depositors simply absorb the fee.
contract FeeChargingERC4626 {
    IERC20 public immutable asset_;
    uint256 public immutable FEE_BIPS;
    address public constant FEE_SINK = address(0xFEE5);

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(IERC20 _asset, uint256 feeBips) {
        asset_ = _asset;
        FEE_BIPS = feeBips;
    }

    function asset() external view returns (address) {
        return address(asset_);
    }

    function totalAssets() public view returns (uint256) {
        return asset_.balanceOf(address(this));
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : shares * totalAssets() / supply;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(asset_.transferFrom(msg.sender, address(this), assets), "transferFrom failed");

        uint256 fee = assets * FEE_BIPS / 10_000;
        uint256 net = assets - fee;

        // Price the net contribution against the pool as it stood *before* this deposit.
        uint256 supply = totalSupply;
        uint256 assetsBefore = totalAssets() - assets;
        shares = supply == 0 ? net : net * supply / assetsBefore;

        if (fee > 0) require(asset_.transfer(FEE_SINK, fee), "fee transfer failed");

        totalSupply = supply + shares;
        balanceOf[receiver] += shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        uint256 supply = totalSupply;
        shares = assets * supply / totalAssets();
        balanceOf[owner] -= shares;
        totalSupply = supply - shares;
        require(asset_.transfer(receiver, assets), "transfer failed");
    }
}
