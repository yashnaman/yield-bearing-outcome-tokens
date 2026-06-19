// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";

/// @title ERC4626VaultAdapter
/// @author yashnaman
/// @notice A vault adapter that invests merged collateral into an ERC-4626 vault on behalf of a single
/// YieldBearingOutcomeTokens instance.
/// @dev The vault's `asset()` is the market's collateral token. ConditionalTokens assumes outcome-token decimals equal
/// collateral decimals, so balances need no conversion.
contract ERC4626VaultAdapter is IVaultAdapter {
    /// @notice The ERC-4626 vault that holds the invested collateral.
    IERC4626 public immutable VAULT;

    /// @notice The collateral token invested into the vault, equal to the vault's underlying asset.
    IERC20 public immutable COLLATERAL_TOKEN;

    /// @notice The YieldBearingOutcomeTokens instance allowed to invest and divest through this adapter.
    address public immutable YIELD_BEARING_OUTCOME_TOKENS;

    error Unauthorized();
    error ApproveFailed();
    error ZeroAddress();

    /// @dev Reverts if the caller is not the authorized YieldBearingOutcomeTokens instance. Without this, anyone could
    /// call `divest` and pull the vault's assets to themselves.
    modifier onlyYieldBearingOutcomeTokens() {
        require(msg.sender == YIELD_BEARING_OUTCOME_TOKENS, Unauthorized());
        _;
    }

    /// @param vault The ERC-4626 vault to invest collateral into.
    /// @param yieldBearingOutcomeTokens The only address permitted to invest and divest through this adapter.
    constructor(IERC4626 vault, address yieldBearingOutcomeTokens) {
        require(address(vault) != address(0), ZeroAddress());
        require(yieldBearingOutcomeTokens != address(0), ZeroAddress());

        VAULT = vault;
        COLLATERAL_TOKEN = IERC20(vault.asset());
        YIELD_BEARING_OUTCOME_TOKENS = yieldBearingOutcomeTokens;
    }

    /// @inheritdoc IVaultAdapter
    function investedBalance() external view returns (uint256) {
        return VAULT.convertToAssets(VAULT.balanceOf(address(this)));
    }

    /// @inheritdoc IVaultAdapter
    /// @dev The collateral is already held by this adapter, so it is simply approved and deposited. `deposit` pulls
    /// exactly `amount`, leaving no residual allowance.
    function invest(uint256 amount) external onlyYieldBearingOutcomeTokens {
        require(COLLATERAL_TOKEN.approve(address(VAULT), amount), ApproveFailed());
        VAULT.deposit(amount, address(this));
    }

    /// @inheritdoc IVaultAdapter
    /// @dev Withdraws straight to the caller, which the modifier guarantees is the YieldBearingOutcomeTokens instance.
    function divest(uint256 amount) external onlyYieldBearingOutcomeTokens {
        VAULT.withdraw(amount, msg.sender, address(this));
    }
}
