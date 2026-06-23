// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";

/// @title ERC4626VaultAdapter
/// @author yashnaman
/// @notice A vault adapter that invests merged collateral into a single ERC-4626 vault on behalf of one
/// YieldBearingOutcomeTokens instance.
/// @dev Supports exactly one collateral token (the vault's `asset()`) but any number of markets/conditions that use
/// it. It keeps per-market vault-share accounting so `investedBalance` returns only the querying market's balance,
/// and so a market can never divest more than it invested. The vault's `asset()` is the market's collateral token;
/// ConditionalTokens assumes outcome-token decimals equal collateral decimals, so balances need no conversion.
contract ERC4626VaultAdapter is IVaultAdapter {
    /// @notice The ERC-4626 vault that holds the invested collateral.
    IERC4626 public immutable VAULT;

    /// @notice The single collateral token this adapter supports, equal to the vault's underlying asset.
    IERC20 public immutable COLLATERAL_TOKEN;

    /// @notice The YieldBearingOutcomeTokens instance allowed to invest and divest through this adapter.
    address public immutable YIELD_BEARING_OUTCOME_TOKENS;

    /// @notice Vault shares held on behalf of each market id, so each market's invested balance is tracked in
    /// isolation. The id matches YieldBearingOutcomeTokens' `keccak256(collateralToken, conditionId, vaultAdapter)`.
    mapping(bytes32 id => uint256 shares) public sharesOf;

    error Unauthorized();
    error ApproveFailed();
    error ZeroAddress();
    error UnsupportedCollateral();

    /// @dev Reverts if the caller is not the authorized YieldBearingOutcomeTokens instance. Without this, anyone could
    /// call `divest` and pull the vault's assets to themselves.
    modifier onlyYieldBearingOutcomeTokens() {
        require(msg.sender == YIELD_BEARING_OUTCOME_TOKENS, Unauthorized());
        _;
    }

    /// @dev Reverts unless the market's collateral is the single token this adapter supports.
    modifier onlySupportedCollateral(IYieldBearingOutcomeTokens.MarketParams calldata marketParams) {
        require(address(marketParams.collateralToken) == address(COLLATERAL_TOKEN), UnsupportedCollateral());
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

    /// @dev Recomputes the market id the same way YieldBearingOutcomeTokens does.
    function _id(IYieldBearingOutcomeTokens.MarketParams calldata marketParams) internal view returns (bytes32) {
        return
            keccak256(abi.encodePacked(address(marketParams.collateralToken), marketParams.conditionId, address(this)));
    }

    /// @inheritdoc IVaultAdapter
    /// @dev Only the shares booked to this market are converted, so other markets' funds are never reported here.
    function investedBalance(IYieldBearingOutcomeTokens.MarketParams calldata marketParams)
        external
        view
        onlySupportedCollateral(marketParams)
        returns (uint256)
    {
        return VAULT.convertToAssets(sharesOf[_id(marketParams)]);
    }

    /// @inheritdoc IVaultAdapter
    /// @dev The collateral is already held by this adapter, so it is simply approved and deposited; the minted vault
    /// shares are booked to this market.
    function invest(IYieldBearingOutcomeTokens.MarketParams calldata marketParams, uint256 amount)
        external
        onlyYieldBearingOutcomeTokens
        onlySupportedCollateral(marketParams)
    {
        require(COLLATERAL_TOKEN.approve(address(VAULT), amount), ApproveFailed());
        uint256 mintedShares = VAULT.deposit(amount, address(this));
        sharesOf[_id(marketParams)] += mintedShares;
    }

    /// @inheritdoc IVaultAdapter
    /// @dev Withdraws straight to the caller (the YieldBearingOutcomeTokens instance) and burns the shares from this
    /// market's bucket. The subtraction reverts if the market tries to divest more shares than it owns.
    function divest(IYieldBearingOutcomeTokens.MarketParams calldata marketParams, uint256 amount)
        external
        onlyYieldBearingOutcomeTokens
        onlySupportedCollateral(marketParams)
    {
        uint256 burntShares = VAULT.withdraw(amount, msg.sender, address(this));
        sharesOf[_id(marketParams)] -= burntShares;
    }
}
