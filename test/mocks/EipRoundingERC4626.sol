// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @notice An ERC-4626 mock that rounds the way the EIP mandates: `previewRedeem` DOWN, `previewWithdraw` UP.
/// @dev {MockERC4626} rounds shares down on exit, the opposite of the EIP, which is why it cannot express the
/// exit-rounding cases below. `virtual` throughout so each case can override exactly one call.
contract EipRoundingERC4626 {
    IERC20 public immutable asset_;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;

    constructor(IERC20 a) {
        asset_ = a;
    }

    function asset() external view returns (address) {
        return address(asset_);
    }

    function totalAssets() public view returns (uint256) {
        return asset_.balanceOf(address(this));
    }

    function deposit(uint256 assets, address receiver) public virtual returns (uint256 shares) {
        uint256 supply = totalSupply;
        shares = supply == 0 ? assets : assets * supply / totalAssets();
        require(asset_.transferFrom(msg.sender, address(this), assets), "pull failed");
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function previewRedeem(uint256 shares) public view virtual returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : shares * totalAssets() / supply; // DOWN, per EIP
    }

    function previewWithdraw(uint256 assets) public view virtual returns (uint256 shares) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        return (assets * supply + totalAssets() - 1) / totalAssets(); // UP, per EIP
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual returns (uint256 assets) {
        assets = previewRedeem(shares);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        require(asset_.transfer(receiver, assets), "transfer failed");
    }

    /// @dev The exit the pool actually uses. Burns the `ceil`-rounded share count and hands back exactly `assets`, so
    /// whatever the rounding (or the fee) over-burned stays here rather than following the caller out.
    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256 shares) {
        shares = previewWithdraw(assets);
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        require(asset_.transfer(receiver, assets), "transfer failed");
    }
}

/// @notice EIP-correct vault with an EXIT fee: `previewRedeem` rounds down, `previewWithdraw` rounds up.
contract ExitFeeVault is EipRoundingERC4626 {
    uint256 public constant FEE_BIPS = 1000; // 10%

    constructor(IERC20 a) EipRoundingERC4626(a) {}

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return super.previewRedeem(shares) * (10_000 - FEE_BIPS) / 10_000; // down
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 gross = (assets * 10_000 + (10_000 - FEE_BIPS) - 1) / (10_000 - FEE_BIPS); // up
        uint256 supply = totalSupply;
        return supply == 0 ? gross : (gross * supply + totalAssets() - 1) / totalAssets(); // up
    }
}

/// @notice EIP-correct ceil-rounding exit at a HIGH assets-per-share, no fee. The base already rounds
/// `previewWithdraw` up and `previewRedeem` down, which is the whole shape the stranded-value case exploits.
contract CeilWithdrawVault is EipRoundingERC4626 {
    constructor(IERC20 a) EipRoundingERC4626(a) {}
}

/// @notice Silently mints ZERO shares instead of reverting. {ZeroShareRevertingERC4626} is the reverting counterpart.
contract ZeroShareVault is EipRoundingERC4626 {
    constructor(IERC20 a) EipRoundingERC4626(a) {}

    function deposit(uint256 assets, address) public override returns (uint256) {
        require(asset_.transferFrom(msg.sender, address(this), assets), "pull failed");
        return 0; // takes the collateral, books nothing
    }
}

/// @notice A vault that becomes uncallable after the fact, to test that a pool needing no vault interaction is not
/// held hostage by one that has stopped answering.
contract BreakableVault is EipRoundingERC4626 {
    bool public broken;

    constructor(IERC20 a) EipRoundingERC4626(a) {}

    function breakIt() external {
        broken = true;
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        require(!broken, "vault dead");
        return super.previewRedeem(shares);
    }
}
