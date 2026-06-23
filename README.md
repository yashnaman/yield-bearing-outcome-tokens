# Yield-Bearing Outcome Tokens

Yield-Bearing Outcome Tokens is a permissionless, immutable singleton vault that lets users earn yield on their idle binary-market outcome tokens. It accepts the YES and NO outcome tokens of any Gnosis ConditionalTokens binary market, matches them into complete sets, and merges those sets into collateral that is deposited into the market's ERC-4626 vault. Yield is distributed back to each side by splitting it into fresh YES/NO pairs, so the scarce (fully matched) side earns the full rate while the surplus side is diluted by its utilization, which pays suppliers to provide the missing side and mechanically shrinks the idle pile.

The whole scheme rests on a single fact: the par identity `1 YES + 1 NO ⇌ 1 collateral`. The vault only ever merges complete sets into collateral and splits collateral back into complete sets, both at par, never relying on market prices. Because the same collateral backs both sides at once and splitting always succeeds, every redemption can reconstitute the outcome tokens it owes, and the contract stays solvent to the token even through resolution, since `splitPosition` and `mergePositions` only require the condition to be prepared, not resolved. Each `(market, side)` runs its own share index, in the spirit of a lending pool's liquidity index, so deposits and redemptions are pure ERC-4626-style share conversions.

## Repository Structure

[`YieldBearingOutcomeTokens.sol`](src/YieldBearingOutcomeTokens.sol) contains the core contract: a single vault serving every market, with `deposit` and `redeem` entry points and the internal merge/invest and withdraw/split rebalancing logic. A market is identified by the pair `(vault, conditionId)`: The ERC-4626 vault its merged collateral is invested into, and the ConditionalTokens condition. t relies only on the `CONDITIONAL_TOKENS` contract and each market's ERC-4626 vault.

The `src/interface` directory holds the contract interfaces. [`IYieldBearingOutcomeTokens.sol`](src/interface/IYieldBearingOutcomeTokens.sol) defines the vault's events and external surface. [`IConditionalTokens.sol`](src/interface/IConditionalTokens.sol) and [`IERC1155TokenReceiver.sol`](src/interface/IERC1155TokenReceiver.sol) describe the external ConditionalTokens dependency and the ERC-1155 receiver hooks the vault implements.

The `src/libraries` directory contains [`CTHelpers.sol`](src/libraries/CTHelpers.sol), the helper used to derive ConditionalTokens collection and position ids.

The `test` directory contains the test suite, including `test/mocks` with contracts designed exclusively for testing such as a mock ERC-4626 vault.
