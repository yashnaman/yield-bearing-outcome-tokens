// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.34;

import {ERC6909TokenSupply} from "@openzeppelin/contracts/token/ERC6909/extensions/ERC6909TokenSupply.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {IConditionalTokens} from "src/interface/IConditionalTokens.sol";
import {IOutcomeYieldPoolFactory} from "src/interface/IOutcomeYieldPoolFactory.sol";
import {ShareIdLib} from "src/libraries/ShareIdLib.sol";
import {OutcomeYieldPool} from "src/OutcomeYieldPool.sol";

/// @title OutcomeYieldPoolFactory
/// @author yashnaman
/// @notice Deploys {OutcomeYieldPool} instances at deterministic addresses, one per market, and holds the shared
/// ERC-6909 ledger of every market's shares.
/// @dev Pools hold the funds; this contract holds only the ledger, so nothing here custodies value and one market's
/// funds are never reachable through another. Keeping the ledger in one place is what makes a single `setOperator`
/// cover every market and gives wallets and indexers one address to integrate instead of one per market.
/// @dev {mint} and {burn} derive the share id from `msg.sender` via {ShareIdLib}, so a caller can only ever touch its
/// own two ids. The corollary is that any contract can mint in its own id namespace, exactly as anyone can deploy an
/// ERC-20, so holding a balance under some id is not evidence the id belongs to a real market. A consumer that needs
/// that guarantee checks `getPoolAddress(yieldVault, conditionId) == pool` for the market it means to use.
/// @dev Deliberately exposes no id arithmetic and no reverse lookups: a share id is a pure function of (pool, side),
/// so anything off-chain recomputes it. See README.md § Deriving everything off-chain.
contract OutcomeYieldPoolFactory is IOutcomeYieldPoolFactory, ERC6909TokenSupply {
    /// @notice Thrown when a bound dependency is the zero address.
    error ZeroAddress();

    /// @notice The ConditionalTokens contract every deployed pool is bound to.
    /// @dev An immutable, so the CREATE2 salt is the (`yieldVault`, `conditionId`) pair alone and the deployed address
    /// is a pure function of (factory, yieldVault, conditionId).
    IConditionalTokens public immutable CONDITIONAL_TOKENS;

    /// @param conditionalTokens The ConditionalTokens contract backing every market this factory serves.
    constructor(IConditionalTokens conditionalTokens) {
        require(address(conditionalTokens) != address(0), ZeroAddress());

        CONDITIONAL_TOKENS = conditionalTokens;
    }

    /* DEPLOYMENT */

    /// @notice Deploys the pool for the (`yieldVault`, `conditionId`) market at its deterministic address, or returns
    /// the existing one.
    /// @dev Permissionless and idempotent, so a caller can bundle "create the market if it does not exist, then
    /// deposit" into one transaction without knowing which case it is in. Only an already-deployed market
    /// short-circuits: a market the pool's constructor rejects — non-binary, unprepared, or unusable collateral —
    /// still reverts, because no code was ever placed at that address.
    /// @dev The market's collateral is deliberately not part of the salt; each pool caches `yieldVault.asset()` once
    /// as an immutable instead.
    /// @param yieldVault The ERC-4626 vault the market invests merged collateral into; its `asset()` is the collateral.
    /// @param conditionId The ConditionalTokens condition id of the binary market.
    /// @return pool The market's pool, freshly deployed or already existing.
    function deployPool(IERC4626 yieldVault, bytes32 conditionId) external returns (OutcomeYieldPool pool) {
        address predicted = getPoolAddress(yieldVault, conditionId);
        if (predicted.code.length != 0) return OutcomeYieldPool(predicted);

        pool = new OutcomeYieldPool{salt: _salt(yieldVault, conditionId)}(CONDITIONAL_TOKENS, yieldVault, conditionId);

        emit PoolDeployed(yieldVault, conditionId, address(pool));
    }

    /// @notice Returns the address the pool for the (`yieldVault`, `conditionId`) market is (or would be) deployed at.
    /// @param yieldVault The ERC-4626 vault the market invests merged collateral into.
    /// @param conditionId The ConditionalTokens condition id of the binary market.
    /// @return pool The deterministic pool address, whether or not it has been deployed yet.
    function getPoolAddress(IERC4626 yieldVault, bytes32 conditionId) public view returns (address pool) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(OutcomeYieldPool).creationCode, abi.encode(CONDITIONAL_TOKENS, yieldVault, conditionId)
            )
        );
        bytes32 data =
            keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(yieldVault, conditionId), initCodeHash));
        pool = address(uint160(uint256(data)));
    }

    /* LEDGER */

    /// @inheritdoc IOutcomeYieldPoolFactory
    function mint(address to, bool isYes, uint256 amount) external {
        _mint(to, ShareIdLib.idFor(msg.sender, isYes), amount);
    }

    /// @inheritdoc IOutcomeYieldPoolFactory
    function burn(address spender, address owner, bool isYes, uint256 amount) external {
        uint256 id = ShareIdLib.idFor(msg.sender, isYes);

        // Trusting the caller's `spender` is not an escalation: the id is derived from `msg.sender`, so a contract that
        // misreports one can only misreport it about shares that it alone is able to mint.
        if (spender != owner && !isOperator(owner, spender)) {
            _spendAllowance(owner, spender, id, amount);
        }

        _burn(owner, id, amount);
    }

    /* INTERNAL */

    /// @dev The salt is the market pair, so a (`yieldVault`, `conditionId`) maps to exactly one pool per factory.
    function _salt(IERC4626 yieldVault, bytes32 conditionId) internal pure returns (bytes32) {
        return keccak256(abi.encode(yieldVault, conditionId));
    }
}
