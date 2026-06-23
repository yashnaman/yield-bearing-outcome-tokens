// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

/// @notice Minimal but complete ERC-4626 vault sufficient for the YieldBearingOutcomeTokens core. Shares track the
/// pool's asset balance, starting 1:1. Implements the full `IERC4626` surface (including its `IERC20` share token) so
/// it can be used directly as an `IERC4626` rather than only through the subset the core happens to call.
contract MockERC4626 is IERC4626 {
    IERC20 public immutable asset_;

    string public name = "Mock Vault Shares";
    string public symbol = "mVS";

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(IERC20 _asset) {
        asset_ = _asset;
    }

    /* ERC-20 SHARE TOKEN */

    function decimals() external view returns (uint8) {
        return asset_.decimals();
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    /* ERC-4626 ACCOUNTING */

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

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(balanceOf[owner]);
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf[owner];
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    /* ERC-4626 ENTRY POINTS */

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        require(asset_.transferFrom(msg.sender, address(this), assets), "transferFrom failed");
        totalSupply += shares;
        balanceOf[receiver] += shares;
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        require(asset_.transferFrom(msg.sender, address(this), assets), "transferFrom failed");
        totalSupply += shares;
        balanceOf[receiver] += shares;
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = convertToShares(assets);
        _spendShares(owner, shares);
        require(asset_.transfer(receiver, assets), "transfer failed");
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = convertToAssets(shares);
        _spendShares(owner, shares);
        require(asset_.transfer(receiver, assets), "transfer failed");
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev Burns `shares` from `owner`, consuming the caller's allowance unless the caller is the owner.
    function _spendShares(address owner, uint256 shares) internal {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                allowance[owner][msg.sender] = allowed - shares;
            }
        }
        balanceOf[owner] -= shares;
        totalSupply -= shares;
    }
}
