// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title MaliciousERC4626
/// @notice A deliberately hostile ERC-4626 vault used to prove the core contract is never harmed by the vault a market
/// integrates with. Every knob models a way a rogue yield venue could try to misbehave: lie about `convertToAssets`,
/// short-pay or withhold on `withdraw`, or reenter the core contract during `deposit`/`withdraw`. It custodies whatever
/// collateral is deposited (like an honest vault) but otherwise answers however the test configures it.
contract MaliciousERC4626 {
    IERC20 public immutable asset_;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // --- convertToAssets manipulation ---
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

    /* ERC-4626 SUBSET */

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

    /// @dev Honest by default, but returns an arbitrary lie when armed — the core uses this to value a market's
    /// invested balance, so a lie inflates the redeemable assets the core thinks it can pay.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (useFakeAssets) return fakeAssets;
        uint256 supply = totalSupply;
        return supply == 0 ? shares : shares * totalAssets() / supply;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = convertToShares(assets);
        require(asset_.transferFrom(msg.sender, address(this), assets), "transferFrom failed");
        totalSupply += shares;
        balanceOf[receiver] += shares;
        _maybeReenter(ReenterOn.DEPOSIT);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        _maybeReenter(ReenterOn.WITHDRAW);
        shares = convertToShares(assets);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        // Best-effort, possibly short-paid transfer; if the vault is underfunded or withholds, the caller's subsequent
        // split reverts, which is the point (a hostile vault can only DoS its own market, never another's funds).
        uint256 payout = assets * withdrawPayoutBips / 10_000;
        if (payout > 0) require(asset_.transfer(receiver, payout), "transfer failed");
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
