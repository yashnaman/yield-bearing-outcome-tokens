// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IVaultAdapter} from "src/interface/IVaultAdapter.sol";
import {IYieldBearingOutcomeTokens} from "src/interface/IYieldBearingOutcomeTokens.sol";

/// @title FeeChargingVaultAdapter
/// @notice An *honest* adapter that charges a flat fee on every `invest`: it skims `feeBips` of the incoming
/// collateral to a sink and invests the rest. It reports `investedBalance` accurately (net of the fee) and always
/// honors `divest` up to that balance. The `MarketParams` docs state the adapter "may charge fees; the vault does not
/// depend on either" — this exercises that as a first-class scenario, distinct from the malicious adapter.
contract FeeChargingVaultAdapter is IVaultAdapter {
    IERC4626 public immutable VAULT;
    IERC20 public immutable COLLATERAL_TOKEN;
    address public immutable YIELD_BEARING_OUTCOME_TOKENS;
    uint256 public immutable FEE_BIPS;
    address public constant FEE_SINK = address(0xFEE5);

    mapping(bytes32 id => uint256 shares) public sharesOf;

    error Unauthorized();

    modifier onlyYieldBearingOutcomeTokens() {
        require(msg.sender == YIELD_BEARING_OUTCOME_TOKENS, Unauthorized());
        _;
    }

    constructor(IERC4626 vault, address yieldBearingOutcomeTokens, uint256 feeBips) {
        VAULT = vault;
        COLLATERAL_TOKEN = IERC20(vault.asset());
        YIELD_BEARING_OUTCOME_TOKENS = yieldBearingOutcomeTokens;
        FEE_BIPS = feeBips;
    }

    function _id(IYieldBearingOutcomeTokens.MarketParams calldata marketParams) internal view returns (bytes32) {
        return
            keccak256(abi.encodePacked(address(marketParams.collateralToken), marketParams.conditionId, address(this)));
    }

    function investedBalance(IYieldBearingOutcomeTokens.MarketParams calldata marketParams)
        external
        view
        returns (uint256)
    {
        return VAULT.convertToAssets(sharesOf[_id(marketParams)]);
    }

    function invest(IYieldBearingOutcomeTokens.MarketParams calldata marketParams, uint256 amount)
        external
        onlyYieldBearingOutcomeTokens
    {
        uint256 fee = amount * FEE_BIPS / 10_000;
        uint256 net = amount - fee;
        if (fee > 0) require(COLLATERAL_TOKEN.transfer(FEE_SINK, fee), "fee transfer failed");
        require(COLLATERAL_TOKEN.approve(address(VAULT), net), "approve failed");
        sharesOf[_id(marketParams)] += VAULT.deposit(net, address(this));
    }

    function divest(IYieldBearingOutcomeTokens.MarketParams calldata marketParams, uint256 amount)
        external
        onlyYieldBearingOutcomeTokens
    {
        sharesOf[_id(marketParams)] -= VAULT.withdraw(amount, msg.sender, address(this));
    }
}
