// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

/// @title FeeChargingERC4626
/// @notice An *honest* ERC-4626 vault that skims a flat `FEE_BIPS` deposit fee to a sink and keeps only the net. It
/// reports `convertToAssets`/`previewRedeem` accurately (net of the fee) and always honors `withdraw` up to its
/// backing. Used to show the core contract does not depend on the vault returning everything it received: depositors
/// simply absorb the fee. Implements the full `IERC4626` surface (including its `IERC20` share token), with
/// fee-inclusive previews as the standard requires.
contract FeeChargingERC4626 is IERC4626 {
    IERC20 public immutable asset_;
    uint256 public immutable FEE_BIPS;
    address public constant FEE_SINK = address(0xFEE5);

    string public name = "Fee Vault Shares";
    string public symbol = "fVS";

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(IERC20 _asset, uint256 feeBips) {
        asset_ = _asset;
        FEE_BIPS = feeBips;
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

    /// @dev Fee-inclusive: prices the post-fee net contribution against the current pool, mirroring `deposit`.
    function previewDeposit(uint256 assets) public view returns (uint256) {
        uint256 net = assets - assets * FEE_BIPS / 10_000;
        uint256 supply = totalSupply;
        return supply == 0 ? net : net * supply / totalAssets();
    }

    /// @dev Fee-inclusive inverse of `previewDeposit`: the gross assets needed to mint `shares`.
    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        uint256 net = supply == 0 ? shares : shares * totalAssets() / supply;
        // Gross up so that, after the fee is skimmed, `net` remains. Round up to never under-charge.
        return (net * 10_000 + (10_000 - FEE_BIPS) - 1) / (10_000 - FEE_BIPS);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    /* ERC-4626 ENTRY POINTS */

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
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = previewMint(shares);
        require(asset_.transferFrom(msg.sender, address(this), assets), "transferFrom failed");

        uint256 fee = assets * FEE_BIPS / 10_000;
        if (fee > 0) require(asset_.transfer(FEE_SINK, fee), "fee transfer failed");

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
