// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";

/// @title MaliciousVaultAdapter
/// @notice A deliberately hostile `IVaultAdapter` used to prove the vault never trusts an adapter. Every knob models a
/// way a rogue adapter could try to misbehave: lie about `investedBalance`, short-pay or skip `divest`, or reenter the
/// vault during `invest`/`divest`. It custodies whatever collateral is invested (like a real adapter) but otherwise
/// answers however the test configures it.
contract MaliciousVaultAdapter is IVaultAdapter {
    IERC20 public immutable COLLATERAL;

    // --- investedBalance manipulation ---
    bool public useFakeBalance;
    uint256 public fakeBalance;

    // --- divest manipulation ---
    /// @dev Basis points of the requested amount actually sent back on `divest` (10_000 = honest, 0 = steal/withhold).
    uint256 public divestPayoutBips = 10_000;

    // --- reentrancy ---
    enum ReenterOn {
        NONE,
        INVEST,
        DIVEST
    }

    ReenterOn public reenterOn;
    address public reenterTarget;
    bytes public reenterData;
    bool private reentered;

    constructor(IERC20 collateral) {
        COLLATERAL = collateral;
    }

    /* CONFIG */

    function setFakeBalance(bool on, uint256 value) external {
        useFakeBalance = on;
        fakeBalance = value;
    }

    function setDivestPayoutBips(uint256 bips) external {
        divestPayoutBips = bips;
    }

    function setReentrancy(ReenterOn on, address target, bytes calldata data) external {
        reenterOn = on;
        reenterTarget = target;
        reenterData = data;
    }

    /* IVaultAdapter */

    function investedBalance(IYieldBearingOutcomeTokens.MarketParams calldata)
        external
        view
        override
        returns (uint256)
    {
        if (useFakeBalance) return fakeBalance;
        return COLLATERAL.balanceOf(address(this));
    }

    function invest(IYieldBearingOutcomeTokens.MarketParams calldata, uint256) external override {
        // Collateral was already transferred to this adapter by the vault; just optionally reenter.
        _maybeReenter(ReenterOn.INVEST);
    }

    function divest(IYieldBearingOutcomeTokens.MarketParams calldata, uint256 amount) external override {
        _maybeReenter(ReenterOn.DIVEST);
        uint256 payout = amount * divestPayoutBips / 10_000;
        if (payout > 0) {
            // Best-effort transfer; if the adapter is underfunded this reverts, which is the point (it can only DoS
            // its own market, never another's funds).
            require(COLLATERAL.transfer(msg.sender, payout), "divest transfer failed");
        }
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
