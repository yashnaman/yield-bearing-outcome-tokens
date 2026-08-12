# Yield-Bearing Outcome Tokens

Yield-Bearing Outcome Tokens lets users earn yield on their idle binary-market outcome tokens. It accepts the YES and NO outcome tokens of any Gnosis ConditionalTokens binary market, matches them into complete sets, and merges those sets into collateral that is deposited into the market's ERC-4626 vault. Yield is distributed back to each side by splitting it into fresh YES/NO pairs, so the scarce (fully matched) side earns the full rate while the surplus side is diluted by its utilization — which pays suppliers to provide the missing side and mechanically shrinks the idle pile.

The whole scheme rests on a single fact: the par identity `1 YES + 1 NO ⇌ 1 collateral`. The protocol only ever merges complete sets into collateral and splits collateral back into complete sets, both at par, never relying on market prices. Because the same collateral backs both sides at once and splitting always succeeds, every redemption can reconstitute the outcome tokens it owes, and the protocol stays solvent to the token even through resolution, since `splitPosition` and `mergePositions` only require the condition to be prepared, not resolved. Each `(market, side)` runs its own share index, in the spirit of a lending pool's liquidity index, so deposits and redemptions are pure ERC-4626-style share conversions.

The deployment is permissionless and immutable: anyone can create the pool for any binary market over any ERC-4626 vault, and no contract has an owner, an admin or an upgrade path.

## Design

### One pool per market, one ledger for all of them

A market is the pair `(yieldVault, conditionId)`: the ERC-4626 vault its merged collateral is invested into, and the ConditionalTokens condition. Each market gets **its own `OutcomeYieldPool` contract**, deployed by `OutcomeYieldPoolFactory` at a CREATE2 address that is a pure function of `(factory, yieldVault, conditionId)` and can be predicted with `getPoolAddress` before deployment. `deployPool` is permissionless and idempotent, so a caller can bundle "create the market if it does not exist, then deposit" into one transaction.

Custody and bookkeeping are deliberately split:

- **The pool holds the funds** — its market's ConditionalTokens outcome tokens and its ERC-4626 vault shares. It has no storage of its own at all; `yieldVault` and `conditionId` are immutables, which is why every function takes only a side and an amount.
- **The factory holds the ledger.** Shares are ERC-6909 tokens on the factory, under a share id derived from the pool address and the side. Holders query balances, transfer, and grant operators on the factory — once, for every market at a time — while the funds backing those shares stay in per-market contracts that cannot reach each other.

The payoff is that isolation between markets is *physical* rather than bookkept. There is no per-market ledger of dangling tokens or vault shares to maintain, no balance-delta guard to enforce, and a hostile yield vault can only ever reach the funds of the market that chose it. Meanwhile a single `setOperator` still covers every market, and wallets, indexers and order books integrate one address instead of one per market.

### Share ids

A share id is `uint160(pool) | (isYes ? 1 << 160 : 0)` — **the pool address in the low 160 bits, the side in bit 160**. This is the id convention Uniswap v4 uses for its ERC-6909 claims (`Currency.toId` / `fromId`), so recovering the pool is the canonical truncating cast `address(uint160(id))` and the pool address is legible in the raw id:

```
NO  id: 0x000000000000000000000000 5fbdb2315678afecb367f032d93f642f64180aa3
YES id: 0x000000000000000000000001 5fbdb2315678afecb367f032d93f642f64180aa3
                                 ^ side bit                ^ pool address, verbatim
```

The map is injective because the address and the side occupy disjoint bits. Folding the side *into* the address range would not be: with `pool` for YES and `pool + 1` for NO, a pool at `X` and a pool at `X + 1` would collide on the id `X + 1` and their holders' balances would add together in the same slot.

`mint` and `burn` derive the id from `msg.sender` via `ShareIdLib`, so a caller can only ever touch its own two ids and can never mint or burn a real pool's shares. A corollary is that no id carrying junk above bit 160 is ever mintable, so such an id can never hold a balance.

Each side of a market therefore has two ids: the ConditionalTokens **position id** of its outcome token (the id you transfer to when depositing) and the factory's ERC-6909 **share id** (the id you hold a balance under). A share is worth strictly more than one outcome token once yield has accrued. Neither is exposed as a contract accessor — both are pure functions of the market, so consumers derive them. See [Deriving everything off-chain](#deriving-everything-off-chain).

### Deposits arrive as ERC-1155 transfers

`onERC1155Received` is the only place a deposit is priced and credited. Sending a market's outcome tokens to its pool **is** the deposit — no `setApprovalForAll`, no second transaction — with the side read from the position id and the account to credit taken from the transfer's `data` (`abi.encode(to)`, or empty to credit the sender). `deposit` is a convenience wrapper that performs exactly that transfer on the caller's behalf, so there is one code path and no way for the two forms to price a deposit differently.

Two consequences worth knowing:

- Outcome tokens can no longer be *donated* to a pool, since every transfer in is credited to someone.
- Batch transfers from third parties are rejected, because a batch carries both sides at once while each side is priced against its own supply. Send one transfer per side.

Because the share count is decided inside the ERC-1155 callback, `deposit` returns nothing — a callback cannot pass a value back out through ConditionalTokens. Read the minted shares from the `Deposit` event, or from the recipient's balance on the factory.

### Rebalancing

Merging is **best-effort**. After crediting a deposit the pool calls `mergeAndDeposit` on itself, so the merge and the vault deposit share a subframe that can roll back together: a vault that reverts on the deposit unwinds the merge too rather than blocking the whole deposit. Both sides then keep their dangling tokens and the merge is retried on a later deposit or on any permissionless `mergeAndDeposit` call — so both sides of a market may dangle simultaneously.

Redemption pays out of dangling outcome tokens first, and only withdraws collateral from the vault to split into a fresh pair when they are insufficient.

## Accepted risks

These are properties the protocol accepts rather than guards against. Each is a deliberate trade, and each has a bound worth understanding before deploying against an unusual vault.

### Vault rounding

Every hop through the yield vault rounds against the pool. Entering, `deposit` mints `floor(collateral / assetsPerShare)` shares; exiting, `withdraw` burns `ceil(...)` shares and hands back only what was asked for. Either way the pool forfeits **up to `assetsPerShare - 1` per hop**, and nothing tries to detect or bound it — there is no minimum merge size and no check that the shares minted are worth what was paid.

Rounding is a continuum, not a cliff: a mint that rounds all the way to zero shares is only the small end of the same `floor`, so rejecting that one case would leave every other case leaking anyway, and would still hand the vault a 2-wei merge that credits back less than 2.

Against the vaults this is intended for — a standard ERC-4626 over USDC-like collateral, where `assetsPerShare` is ~1 in asset units — the bound is ~1 wei per hop. Honest users pay a wei, and grinding it into 1 USDC of damage costs an attacker ~1e6 transactions, far more gas than the value destroyed.

**Note what the bound is denominated in.** It scales with the vault's `assetsPerShare`, not with a constant, and `deployPool` is permissionless over any ERC-4626 — so a vault whose share is worth many units of its asset makes each hop cost proportionally more. Anyone pointing this at a vault outside that shape should re-run the arithmetic for their own `assetsPerShare` first. `testCeilRoundedExitStrandsAtMostOneShareEipCorrect` measures the effect at a deliberately pathological `assetsPerShare` of 1e9.

The limiting case is a vault that takes the collateral and books nothing at all: `mergeAndDeposit` ignores the share count the vault returns, so such a vault destroys the whole merge. That is the same `floor` taken to `assetsPerShare = infinity`, and it is where the bound above stops holding — which is why **the vault a market picks is load-bearing**. See `testZeroShareDepositLosesPrincipalAcceptedRisk`.

### A share id does not prove a market is real

Because `mint` derives the id from `msg.sender`, **any contract can mint in its own id namespace**, exactly as anyone can deploy an ERC-20. Holding a balance under some id is therefore not evidence that the id belongs to a real market.

Consumers that need that guarantee check the address instead: `factory.getPoolAddress(yieldVault, conditionId) == pool` for the market they mean to use. That is one call on-chain, or pure local arithmetic off-chain. The core ships no `isGenuinePool`/`isGenuineId` reverse lookup, because a consumer always starts from the market it wants rather than from an unknown address, and verifying on every mint would cost every deposit and redeem gas for a property only integrators need, and only once.

### A dead vault blocks the redemptions that need it

`investedBalance` short-circuits on an empty position, so a pool holding only dangling outcome tokens never calls into the vault and can always be exited. A redemption that genuinely needs to divest, however, cannot be served by a vault that will not answer — the pool can neither value nor liquidate the position. That failure is the vault's, contained to the market that chose it, and is the residual the short-circuit deliberately does not cover.

### Mutable `asset()`

`COLLATERAL` is read from `yieldVault.asset()` exactly once, at construction. A vault whose `asset()` changes later is pinned to whatever it returned then, so no two functions can disagree about which token backs the market — but the market also cannot follow the vault to a new asset. A vault that is its own asset is rejected outright, since its `balanceOf` would mean both "collateral held" and "vault shares held" at the same time.

## Deriving everything off-chain

The core is deliberately close to actions-only: it exposes what the chain alone can do, plus the market identity. Everything else — ids, balances, accounting — is a pure function of the market, so it is computed rather than stored or served. Everything below needs only the factory address, the pool creation code, and `(yieldVault, conditionId, isYes)`.

**Pool address.** CREATE2 over the factory, with the market pair as salt:

```
salt         = keccak256(abi.encode(yieldVault, conditionId))
initCode     = OutcomeYieldPool.creationCode
            ++ abi.encode(CONDITIONAL_TOKENS, yieldVault, conditionId)
pool         = address(keccak256(0xff ++ factory ++ salt ++ keccak256(initCode))[12:])
```

`CONDITIONAL_TOKENS` is a factory immutable, read once. On-chain, `factory.getPoolAddress(yieldVault, conditionId)` does the same thing — the one derivation kept on-chain, because an integrator contract cannot cheaply embed the creation code.

**Share id.** `uint160(pool) | (isYes ? 1 << 160 : 0)`, and back with `address(uint160(id))`. Defined once in [`ShareIdLib`](src/libraries/ShareIdLib.sol), which the factory and the pool both use and which nothing exposes.

**Position id.** As ConditionalTokens derives it, from the pool's pinned `COLLATERAL()`:

```
collectionId = CTHelpers.getCollectionId(bytes32(0), conditionId, isYes ? 1 : 2)
positionId   = keccak256(abi.encodePacked(collateral, collectionId))
```

ConditionalTokens exposes `getCollectionId` and `getPositionId` itself, so this needs no local elliptic-curve maths — though the same code is vendored in [`CTHelpers`](src/vendor/CTHelpers.sol), and `test/unit/CTHelpers.t.sol` pins the two to agree.

Read the collateral from `pool.COLLATERAL()`, **not** from `pool.YIELD_VAULT().asset()`. The pool pins its collateral at construction, and a vault that changes its `asset()` afterwards would otherwise hand you the wrong collateral and therefore the wrong position ids. That is why `COLLATERAL()` is the one derived value still kept on-chain: it is the only one current chain state cannot reproduce.

**Balances and accounting.** Each is a composition of calls the caller can make directly:

| was | compute it as |
| --- | --- |
| `pool.danglingBalance(isYes)` | `conditionalTokens.balanceOf(pool, positionId(isYes))` |
| `pool.investedBalance()` | `v = yieldVault.balanceOf(pool)`; then `v == 0 ? 0 : yieldVault.previewRedeem(v)` |
| `pool.totalAssets(isYes)` | `danglingBalance(isYes) + investedBalance()` |
| `pool.totalShares(isYes)` | `factory.totalSupply(shareId(isYes))` |
| holder balance | `factory.balanceOf(holder, shareId(isYes))` |

The zero short-circuit on `investedBalance` matters: a pool holding no vault position must not call `previewRedeem` at all, so that a market whose vault has stopped answering can still be read.

**Market discovery.** The `PoolDeployed(yieldVault, conditionId, pool)` event, which is not derivable and is the reason it exists.

`test/Base.t.sol` implements every one of these as a helper, and the whole suite runs through them — so the claim that a consumer can derive it all is what the tests actually exercise.

## Invariants

`test/invariant/` runs these as stateful fuzz campaigns (`FOUNDRY_PROFILE=ci` for 256 runs × 512 depth). `Invariant.t.sol` drives several honest markets; `AdversarialInvariant.t.sol` adds a market wired to a fully hostile vault that shares the same collateral and condition — and therefore the same ConditionalTokens position ids — as the honest ones.

| Invariant | Property |
|---|---|
| `shareConservation` | Tracked actors always hold exactly each side's total share supply. |
| `danglingMatchesHeldTokens` | A pool's reported dangling balance is exactly the ConditionalTokens balance it holds. Two pools sharing a position id are separate accounts and never bleed into one another. |
| `vaultShareIsolation` | Each pool holds ERC-4626 shares of its own vault only. |
| `sideBackingCoversFlows` | Merging and splitting preserve `dangling + invested` on each side, so a side's backing always covers everything that flowed in minus what flowed out. |
| `yesNoDifferenceConservation` | Exact, rounding-free token conservation: no outcome token ever crosses between pools. |
| `vaultSolvency` | Markets never claim more collateral than their underlying vault holds. |
| `allHoldersCanRedeem` | Redeeming every share across every market and side succeeds simultaneously. |

The adversarial suite restates the same properties against the hostile market — `honestShareConservation`, `vaultShareIsolationWithHostileMarket`, `honestBackingNeverLeaks`, `honestHoldersCanRedeem` — so that anything the hostile market siphoned out of an honest pool would surface as a shortfall.

## Repository structure

```
src/
  OutcomeYieldPool.sol           core: deposit, redeem, merge/invest, withdraw/split
  OutcomeYieldPoolFactory.sol    CREATE2 deployment + the shared ERC-6909 share ledger
  interface/                     the documented external surface
  libraries/SharesMathLib.sol    share <-> asset conversion, with the virtual offsets
  libraries/ShareIdLib.sol       the (pool, side) -> ERC-6909 share id mapping
  vendor/CTHelpers.sol           forked Gnosis id derivation — third-party, not in audit scope
test/
  Base.t.sol                     shared fixture: real ConditionalTokens, mock collateral + vault, one market
  unit/                          fixture-free: the id mapping, and CTHelpers vs the real contract
  integration/                   behavioural suites
  invariant/                     stateful fuzz campaigns
  mocks/                         collateral and vault mocks, including hostile ones
  vendor/CTImport.sol            compiles the 0.5.x ConditionalTokens so tests can deploy the real thing
```

Full NatSpec lives on the interfaces in [`src/interface`](src/interface); the implementations carry `@inheritdoc` plus short inline comments. [`IOutcomeYieldPool.sol`](src/interface/IOutcomeYieldPool.sol) is the surface to read first. [`IConditionalTokens.sol`](src/interface/IConditionalTokens.sol) and [`IERC1155TokenReceiver.sol`](src/interface/IERC1155TokenReceiver.sol) describe the external ConditionalTokens dependency and the receiver hooks the pool implements.

## Development

```sh
forge build
forge test                       # 256 fuzz runs, 64x64 invariants
FOUNDRY_PROFILE=ci forge test    # 5000 fuzz runs, 256x512 invariants
forge fmt --check
```

The test suite deploys the **real** Gnosis ConditionalTokens (Solidity 0.5.x, via `vm.deployCode`) rather than a mock, which is why the build spans two compiler versions and why `solc` is not pinned in `foundry.toml`.

## License

Files in this repository are publicly available under license GPL-2.0-or-later, see [LICENSE](LICENSE).
