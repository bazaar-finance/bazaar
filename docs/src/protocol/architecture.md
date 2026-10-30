# Architecture

```
                    ┌────────────────────┐
                    │   BazaarFactory    │
                    │ UMA-gated listings │
                    └─────────┬──────────┘
                              │ deploys EIP-1167 clones
                              ▼
                        ┌────────────────────┐   ┌──────────────────────┐
                        │     BazaarPair     │◄─►│ BazaarPairTerminator │
                        │ one per market:    │   │ scheduled · insurer  │
                        │ book · matching    │   │ vote · stale-oracle  │
                        │ margin · funding   │   │ wind-down paths      │
                        │ ADL · insurance    │   └──────────────────────┘
                        └───┬────────────┬───┘
                            │            │
                            ▼            ▼
                   ┌──────────────┐  ┌────────────────┐
                   │ BazaarOracle │  │ BazaarPairLens │
                   │ Pyth adapter │  │ read-only views│
                   └──────────────┘  └────────────────┘
```

One `BazaarPair` clone = one market. Each clone holds its own order book, positions, collateral ledger, insurance fund, funding state, and lifecycle flags. The factory, terminator, oracle adapter, and lens are shared protocol-wide singletons. See [Contracts](../reference/contracts.md) for the per-contract API surface.

## Code-size strategy

`BazaarPair` would blow past the EIP-170 24 KB limit many times over, so the logic is split three ways:

- **External DELEGATECALL libraries** — deployed once, linked by address, and executed in the calling contract's storage context: `MatchingEngineLib`, `OrderManagementLib`, `CollateralLib`, `LiquidationLib`, `AdlLib`, `InsuranceVaultLib`, `RiskParamsLib`, `FundingLib`, `TerminationLib`, `MetaTxLib`, `VaultHealthLib`, linked by `BazaarPair`, and `ClaimTextLib`, linked by `BazaarFactory` and `BazaarPairTerminator` for the static text of the UMA claims they assert. Their bytecode does not count toward the linking contract's limit. Five of them (`AdlLib`, `InsuranceVaultLib`, `MatchingEngineLib`, `TerminationLib`, `VaultHealthLib`) in turn link `RiskParamsLib`. All twelve must be deployed on the target chain and passed as `--libraries` flags before the contracts that link them can be deployed — see [Self-Deployment](../guide/deployment.md).
- **Inlined internal libraries** — small, hot helpers compiled into callers: `BazaarTypes` (structs/constants), `OrderBookLib` (the sorted doubly-linked book lists), `BucketLib` (solvency math), `MmrSampleLib` (lagged-MMR ring buffer), `FeeEscrowLib` (the claimable-balance escrow every payout accrues through), `BazaarMathLib` (fixed-point + effective prices).
- **`BazaarPairLens`** — computed views (solvency checks, insurance share values and LP flow quotes, ADL scores and constants, EIP-712 constants) that never needed to be in the pair.

Even split three ways the budget is tight: `BazaarPair` sits right at the EIP-170 ceiling, with `MatchingEngineLib` the next artifact behind it, and `foundry.toml` compiles everything at a single global `optimizer_runs = 150` so the artifact the size gate measures is identical to the artifact that ships. The gas cost is modest — the hot paths (the matching walk, liquidation, settlement) are storage-dominated, where optimizer runs matter least. The limits are enforced as a test over every contract and external library that ships, rather than via `forge build --sizes`, whose gate would also fail on test-only harnesses.

## Units & conventions

| Convention | Value |
|---|---|
| Internal precision | 1e18 (`BAZAAR_SCALE`) for all prices, sizes, notionals, collateral |
| Token edge | USDC, 6 decimals — converted only at transfer boundaries; deposits floored to 1e12 granularity so no unbacked dust is credited |
| Basis points | `BP_SCALE = 10_000` (1 bp = 0.01%) |
| Extended basis points | `EBP_SCALE = 1_000_000` — fee rates; 100 EBP = 1 bp |
| Block numbers | Arbitrum L2 blocks via the `ArbSys` precompile (`0x64`), ~250 ms cadence — **not** `block.number`, which tracks L1 on Arbitrum |
| Notional | `size × price / 1e18` |

## Accounting invariant

The pair tracks two ledgers — `totalCollateralDeposited` (D, the deposits ledger: every bucket's collateral plus the open positions' net unrealized PnL — the vault's inherited inventory included, whose loss reaches the ledger only when the inventory [exits](liquidations.md#exiting-the-inventory) — since realized PnL moves buckets but not the ledger) and `insuranceFundBalance` (I). All internal value movements (vault PnL, ADL credits, fee flows) are booked as transfers between ledgers — **I↔D**, or from either into the fee escrow below — never bare credits. Alongside them sits a third claim on the same cash: the [fee escrow](fees.md#how-payouts-are-paid) (E), the unclaimed total the pair owes third parties. Every verdict on vault health — run by every matching transaction that fills, liquidation, unload, ADL execution, price refresh, insurance redemption and priced withdrawal — re-checks `balanceOf(pair) ≥ I + D + E` within a 0.1% tolerance, ahead of the exposure verdict so a pending ADL window cannot defer it; a shortfall opens the [settlement window](termination.md) at the live price. A withdrawal that reads no price (a flat account's) runs the same comparison on its own and is refused while it fails, until the next priced flow — anyone can call `refreshPrice` — fixes the settlement price. Escrowed fees belong in that expectation exactly like principal and insurance — omitting them would let the fund look solvent on cash already owed away. This is the protocol's tamper-evident seal: if value ever leaks, the market freezes and settles pro-rata on the cash actually held rather than letting a first-mover drain it.
