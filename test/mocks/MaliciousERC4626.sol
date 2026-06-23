// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

/// @title MaliciousERC4626
/// @notice A deliberately hostile ERC-4626 vault used to prove the core contract is never harmed by the vault a market
/// integrates with. Every knob models a way a rogue yield venue could try to misbehave: lie about the redeemable
/// balance, short-pay or withhold on `withdraw`, or reenter the core contract during `deposit`/`withdraw`. It custodies
/// whatever collateral is deposited (like an honest vault) but otherwise answers however the test configures it.
/// Implements the full `IERC4626` surface (including its `IERC20` share token) so it can stand in as any vault.
contract MaliciousERC4626 is IERC4626 {
    IERC20 public immutable asset_;

    string public name = "Evil Vault Shares";
    string public symbol = "eVS";

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // --- balance lie ---
    bool public useFakeAssets;
    uint256 public fakeAssets;

    // --- withdraw manipulation ---
    /// @dev Basis points of the requested assets actually sent back on `withdraw` (10_000 = honest, 0 = steal/withhold).
    uint256 public withdrawPayoutBips = 10_000;

    // --- reentrancy ---
    enum ReenterOn {
        NONE,
        DEPOSIT,
        WITHDRAW
    }

    ReenterOn public reenterOn;
    address public reenterTarget;
    bytes public reenterData;
    bool private reentered;

    constructor(IERC20 _asset) {
        asset_ = _asset;
    }

    /* CONFIG */

    function setFakeAssets(bool on, uint256 value) external {
        useFakeAssets = on;
        fakeAssets = value;
    }

    function setWithdrawPayoutBips(uint256 bips) external {
        withdrawPayoutBips = bips;
    }

    function setReentrancy(ReenterOn on, address target, bytes calldata data) external {
        reenterOn = on;
        reenterTarget = target;
        reenterData = data;
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

    /// @dev Honest by default, but returns an arbitrary lie when armed. The core values a market's invested balance via
    /// `previewRedeem` (which delegates here), so a lie inflates the redeemable assets the core thinks it can pay.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (useFakeAssets) return fakeAssets;
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

    /// @dev Inherits the `convertToAssets` lie so the core's invested-balance valuation can be inflated on demand.
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
        _maybeReenter(ReenterOn.DEPOSIT);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = convertToShares(shares); // 1:1-ish stand-in; mint is unused by the core
        require(asset_.transferFrom(msg.sender, address(this), assets), "transferFrom failed");
        totalSupply += shares;
        balanceOf[receiver] += shares;
        emit Deposit(msg.sender, receiver, assets, shares);
        _maybeReenter(ReenterOn.DEPOSIT);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        _maybeReenter(ReenterOn.WITHDRAW);
        shares = convertToShares(assets);
        _spendShares(owner, shares);
        _payout(assets, receiver);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        _maybeReenter(ReenterOn.WITHDRAW);
        assets = convertToAssets(shares);
        _spendShares(owner, shares);
        _payout(assets, receiver);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev Best-effort, possibly short-paid transfer; if the vault is underfunded or withholds, the caller's
    /// subsequent split reverts, which is the point (a hostile vault can only DoS its own market, never another's
    /// funds).
    function _payout(uint256 assets, address receiver) internal {
        uint256 payout = assets * withdrawPayoutBips / 10_000;
        if (payout > 0) require(asset_.transfer(receiver, payout), "transfer failed");
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

    function _maybeReenter(ReenterOn on) internal {
        if (reenterOn != on || reentered || reenterTarget == address(0)) return;
        reentered = true;
        (bool ok,) = reenterTarget.call(reenterData);
        // Swallow the result: a reverting reentrancy attempt should not mask the primary call's own behavior in tests
        // that assert on the outer effect.
        ok;
    }
}
