// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";
import {IConditionalTokens} from "src/interface/IConditionalTokens.sol";

/// @notice Attacker-controlled "yield vault" stubs used by the market-isolation suite.
/// @dev Every one of these is pointed at a *genuine* vault's share token as its `asset()`, which is the setup that
/// turned the old singleton's shared ERC-20 balance into a drain. They implement only the ERC-4626 surface the pool
/// touches, and each lies on a different call. The receiver hooks are here because a hostile vault has to be able to
/// hold outcome tokens it will re-deposit during a callback.
///
/// @dev KNOWN LIMITATION, carried over verbatim from the PoC files these were extracted from: the pool divests via
/// `YIELD_VAULT.withdraw(...)`, and these stubs implement `redeem` instead, which the pool never calls. The divest
/// path therefore reverts on the missing selector *before* any reentrancy hook below can fire. The isolation
/// assertions in {MarketIsolationTest} still hold, but they currently hold trivially — nothing reenters. Implementing
/// `withdraw` here is what would make those tests exercise the path they describe; it is deliberately not done in the
/// same change that restructured them, so that the restructure stays behaviour-neutral.
abstract contract HostileERC4626 {
    address public immutable assetAddr;

    /// @dev What `previewRedeem` claims the pool's position is worth. Also gates `balanceOf`, so a vault holding
    /// nothing can still claim a position and reach the pool's divest path.
    uint256 public previewValue;

    constructor(address a) {
        assetAddr = a;
    }

    function asset() external view returns (address) {
        return assetAddr;
    }

    function setPreview(uint256 v) external {
        previewValue = v;
    }

    function balanceOf(address) external view virtual returns (uint256) {
        return previewValue == 0 ? 0 : 1;
    }

    function previewRedeem(uint256) external view returns (uint256) {
        return previewValue;
    }

    function previewWithdraw(uint256) external view virtual returns (uint256) {
        return 1;
    }

    /// @dev Pulls the collateral and books it 1:1, so the market looks healthy from outside.
    function deposit(uint256 assets, address) external virtual returns (uint256) {
        require(IERC20(assetAddr).transferFrom(msg.sender, address(this), assets), "pull failed");
        return assets;
    }

    /// @dev Delivers nothing and burns nothing — the shape that defeated the singleton's underflow guard.
    function redeem(uint256, address, address) external virtual returns (uint256) {
        return 0;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}

/// @notice Takes the collateral honestly, then tries to sweep it somewhere else.
contract SweepingVault is HostileERC4626 {
    constructor(address a) HostileERC4626(a) {}

    function sweep(address to) external {
        IERC20(assetAddr).transfer(to, IERC20(assetAddr).balanceOf(address(this)));
    }
}

/// @notice Books shares but never pulls the collateral, keeping its constructor-granted allowance alive so it can try
/// to spend the pool's balance later through {drain}.
contract PassiveVault is HostileERC4626 {
    constructor(address a) HostileERC4626(a) {}

    function balanceOf(address) external pure override returns (uint256) {
        return 0;
    }

    function previewWithdraw(uint256 assets) external pure override returns (uint256) {
        return assets;
    }

    function deposit(uint256 assets, address) external pure override returns (uint256) {
        return assets; // books shares, pulls NOTHING
    }

    /// @notice Exercises the unbounded allowance the pool grants its vault in the constructor.
    function drain(address pool, uint256 amt, address to) external {
        IERC20(assetAddr).transferFrom(pool, to, amt);
    }
}

/// @notice Reenters a *second* pool's `deposit` from inside its own exit, which under the singleton let one market's
/// merge manufacture another market's balance delta.
contract ReenteringVault is HostileERC4626 {
    IConditionalTokens public immutable CT;

    OutcomeYieldPool public targetPool;
    uint256 public amt;
    address public beneficiary;
    bool internal armed;

    constructor(address a, IConditionalTokens c) HostileERC4626(a) {
        CT = c;
    }

    function arm(OutcomeYieldPool p, uint256 m, address b) external {
        targetPool = p;
        amt = m;
        beneficiary = b;
        armed = true;
        CT.setApprovalForAll(address(p), true);
    }

    function redeem(uint256, address, address) external override returns (uint256) {
        if (armed) {
            armed = false;
            // Nested merge on the other market. Under the singleton this delivered collateral into the one shared
            // balance and satisfied the *outer* market's delta check.
            targetPool.deposit(false, amt, beneficiary);
        }
        return 0;
    }
}

/// @notice Reenters `deposit` on its OWN market from inside its exit, which under the singleton let the nested merge
/// be charged to the phantom dangling balance `redeem` credited before `splitPosition` had minted anything.
contract SelfReenteringVault is HostileERC4626 {
    IConditionalTokens public immutable CT;

    OutcomeYieldPool public ownPool;
    uint256 public amt;
    address public beneficiary;
    bool internal armed;
    /// @dev Once armed, stop pulling so the nested merge's collateral stays in the pool.
    bool internal passive;

    constructor(address a, IConditionalTokens c) HostileERC4626(a) {
        CT = c;
    }

    function setPool(OutcomeYieldPool p) external {
        ownPool = p;
    }

    function arm(uint256 m, address b) external {
        amt = m;
        beneficiary = b;
        armed = true;
        passive = true;
        CT.setApprovalForAll(address(ownPool), true);
    }

    function deposit(uint256 assets, address) external override returns (uint256) {
        if (passive) return assets;
        require(IERC20(assetAddr).transferFrom(msg.sender, address(this), assets), "pull failed");
        return assets;
    }

    function redeem(uint256, address, address) external override returns (uint256) {
        if (armed) {
            armed = false;
            // Deposit the YES leg into THIS SAME market mid-exit.
            ownPool.deposit(true, amt, beneficiary);
        }
        return 0;
    }
}
