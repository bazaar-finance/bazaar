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
                        │ one per market:    │   │ scheduled · cessation│
                        │ book · matching    │   │ stale-oracle · vote  │
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

- **External DELEGATECALL libraries** — deployed once, linked by address, and executed in the pair's storage context: `MatchingEngineLib`, `OrderManagementLib`, `CollateralLib`, `LiquidationLib`, `AdlLib`, `InsuranceVaultLib`, `RiskParamsLib`, `FundingLib`, `TerminationLib`, `MetaTxLib`. Their bytecode does not count toward the pair's limit. All ten carry link references in `BazaarPair` and must be deployed on the target chain and passed as `--libraries` flags before it can be deployed — see [Self-Deployment](../guide/deployment.md).
- **Inlined internal libraries** — small, hot helpers compiled into callers: `BazaarTypes` (structs/constants), `OrderBookLib` (the sorted doubly-linked book lists), `BucketLib` (solvency math), `VaultHealthLib` (ADL/termination triggers), `MmrSampleLib` (lagged-MMR ring buffer), `BazaarMathLib` (fixed-point + effective prices).
- **`BazaarPairLens`** — computed views (solvency checks, share prices, ADL thresholds, EIP-712 constants) that never needed to be in the pair.

Even split three ways the budget is tight: `BazaarPair` and `MatchingEngineLib` are the two artifacts nearest the EIP-170 ceiling, and `foundry.toml` compiles everything at a single global `optimizer_runs = 150` so the artifact the size gate measures is identical to the artifact that ships. The gas cost is modest — the hot paths (the matching walk, liquidation, settlement) are storage-dominated, where optimizer runs matter least. The limits are enforced as a test (`test/unit/ContractSizeTest.t.sol`, production contracts only) rather than via `forge build --sizes`, whose gate would also fail on test-only harnesses.

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

The pair tracks two ledgers — `totalCollateralDeposited` (D, sum of every position bucket's collateral) and `insuranceFundBalance` (I). All internal value movements (vault PnL, ADL credits, fee flows) are booked as **I↔D transfers**, never bare credits, so `I + D` always equals the USDC the contract should hold. Every matching transaction, liquidation, unload, ADL execution, and withdrawal re-checks `balanceOf(pair) ≥ I + D` within a 0.1% tolerance; a shortfall triggers autonomous [emergency termination](termination.md). This is the protocol's tamper-evident seal: if value ever leaks, the market freezes into pro-rata withdrawal mode rather than letting a first-mover drain it.
