# Bazaar

**Permissionless perpetual futures on anything with a price feed — no admin keys, no whitelists, no off-switch.**

Bazaar is a USDC-margined perpetual-futures protocol built for Arbitrum. Any asset with a [Pyth](https://pyth.network) price feed — crypto, equities, FX, indices — can be listed permissionlessly through an [UMA Optimistic Oracle](https://uma.xyz) assertion and traded on an on-chain central limit order book. Order matching is performed in batches by **permissionless, bonded sequencers** whose honesty is enforced by on-chain fraud proofs rather than trust.

The protocol is immutable: no owner, no pauser, no upgradeable proxies, no governance token. Every privileged action is either fully permissionless, economically bonded, or adjudicated by UMA's optimistic oracle. The single mutable pointer in the system is which UMA oracle contract does that adjudication — and swapping it requires a $5,000-bonded assertion that survives a 14-day public dispute window, followed by a 14-day activation timelock during which the incoming oracle has no authority and traders who distrust it can exit (insurance-LP withdrawals remain subject to their 20-day cooldown).

> ⚠️ **Status: pre-audit, work in progress.** Do not use with real funds.

## Highlights

- **List anything with a Pyth feed.** Anyone can propose a market by posting a $1,000 UMA bond plus a ≥$3,000 insurance seed. UMA verifiers check the listing against objective criteria (feed validity, spot-linear non-expiring asset, correct trading-schedule flag); after a 48-hour challenge window the pair deploys as an EIP-1167 clone.
- **On-chain CLOB, off-chain sorting.** Orders rest on-chain. Sequencers submit sorted order-ID lists; the contract re-verifies sort order inline and matches deterministically in three passes, so the book's semantics are fully on-chain.
- **Fraud-proof sequencer accountability.** Every batch commits a hash of its execution witnesses. For 29 minutes anyone can prove an order was censored (7% slash) or a batch was falsely marked price-stale (1% slash).
- **Dynamic risk engine.** Initial margin floats between 4% and 80% (25× to 1.25× leverage) driven by volatility, realized liquidation gaps, and insurance-fund health. Maintenance margin is always half of initial, with a 24-hour grace lag so a rising requirement can't instantly liquidate existing positions.
- **Defense in depth.** Liquidation → vault inventory unwound on the book → auto-deleveraging Dutch auction → per-pair insurance fund → PnL haircut waterfall → guaranteed-settlement termination. Every failure mode ends in a defined state; nothing strands user funds behind a revert.
- **Gasless UX.** Every user action supports EIP-712 meta-transactions with relayer fees paid in USDC, plus ERC-2612 permit for approval-free deposits.
- **Equities-aware.** Non-24/7 assets (stocks, FX) trade under a stale-oracle regime off-hours: doubled initial margin, fills confined to ±10% of the last price, market orders disabled. Non-USD-quoted assets use permissionless composite feeds (e.g. `DAX/EUR × EUR/USD`).

## Architecture

```
                    ┌────────────────────┐
                    │   BazaarFactory    │
                    │ UMA-gated listings │
                    └─────────┬──────────┘
                              │ deploys EIP-1167 clones
                              ▼
 ┌──────────────────┐   ┌────────────────────┐   ┌──────────────────────┐
 │ BazaarSequencer  │◄─►│     BazaarPair     │◄─►│ BazaarPairTerminator │
 │ bonds · volume   │   │ one per market:    │   │ scheduled · cessation│
 │ caps · fraud     │   │ orders · matching  │   │ stale-oracle · vote  │
 │ proofs           │   │ margin · funding   │   │ wind-down paths      │
 └──────────────────┘   │ ADL · insurance    │   └──────────────────────┘
                        └───┬────────────┬───┘
                            │            │
                            ▼            ▼
                   ┌──────────────┐  ┌────────────────┐
                   │ BazaarOracle │  │ BazaarPairLens │
                   │ Pyth adapter │  │ read-only views│
                   └──────────────┘  └────────────────┘
```

| Contract | Purpose |
|---|---|
| [`BazaarPair`](src/BazaarPair.sol) | One clone per market. Holds orders, positions, collateral, the insurance fund, funding state, and termination state. All internal accounting is 1e18; USDC (6 decimals) only at the edges. |
| [`BazaarFactory`](src/BazaarFactory.sol) | Permissionless pair listing via UMA assertions. Also the only "governance": the UMA oracle address itself can be swapped by a $5,000-bonded, 14-day-liveness assertion, which then waits out a 14-day activation timelock before taking effect. |
| [`BazaarSequencer`](src/BazaarSequencer.sol) | Sequencer bond registry ($1,000 minimum), 30-minute rolling volume caps (14× bond), utilization-priced taker fees, and the two fraud-proof challenges. |
| [`BazaarOracle`](src/BazaarOracle.sol) | Stateless Pyth adapter: confidence-bracketed prices (spot ± confidence), a stale-price confidence ladder, historical price proofs for challenges, and permissionless composite feed registration. |
| [`BazaarPairTerminator`](src/BazaarPairTerminator.sol) | Four independent ways to wind a market down (see [Termination](#termination--settlement)). |
| [`BazaarPairLens`](src/BazaarPairLens.sol) | Read-only computed views (solvency, share prices, ADL thresholds, EIP-712 constants) kept out of the pair's bytecode. |

To stay under the EIP-170 code-size limit, heavy logic lives in externally deployed libraries called via `DELEGATECALL` that operate directly on pair storage: `MatchingEngineLib`, `OrderManagementLib`, `CollateralLib`, `LiquidationLib`, `AdlLib`, `InsuranceVaultLib`, `RiskParamsLib`, `FundingLib`, `TerminationLib` — see [`src/libraries/`](src/libraries).

## Life of a trade

1. **Deposit** USDC into a pair (`depositCollateral`, min $1). Collateral backs one net position per user per market.
2. **Order** — five types: `Market`, `Limit` (post-only supported), `StopLimit`, `TakeProfit`, `StopLoss`. Orders rest on-chain with block-stamped lifetimes. Creation enforces initial margin against worst-case exposure including your resting orders.
3. **Match** — a bonded sequencer snapshots the book at an `observationBlock` (≤12 L2 blocks old), sorts the resting orders into four lists (`longLimits`, `shortLimits`, `longMarkets`, `shortMarkets`), and calls `matchBatch`. The contract re-verifies sort order and runs three passes:
   - **Pass A** — vault liquidation inventory vs. resting limits, inside an oracle band of ±min(5%, current MMR);
   - **Pass B** — market orders vs. limits (limit is always maker; skipped when the oracle is stale);
   - **Pass C** — limits vs. limits (older order is maker; self-matches and post-only violations auto-cancel).
   Per-fill margin failures auto-cancel the failing order — matched or canceled, every walked order ends in a provable state.
4. **Accountability** — the batch's execution witnesses (worst fill per side, oracle price, skipped-order list, sequencer, blocks) are hashed into `batchHashes` and emitted. For 29 minutes anyone can submit `challengeOmission` or `challengeStaleBatch` against the preimage.
5. **Carry** — funding accrues continuously (see [Funding](#funding)); the position carries until closed, liquidated, auto-deleveraged, or the pair terminates.

### Order parameters

| Constraint | Value |
|---|---|
| Minimum order notional | $5 (full position closes always allowed) |
| Market order slippage cap | 5% (`maxSlippageBp ≤ 500`) |
| Market order lifetime | 12 L2 blocks (~3 s); 1 active per user |
| Limit order lifetime | ~3 s minimum to ~1 year maximum |
| Active limit + stop-limit orders | ≤100 per user |
| TakeProfit / StopLoss | 1 each per position, never expire |
| Tick / lot size | none — prices and sizes are raw 1e18 |

## Sequencing & fraud proofs

Anyone can sequence by bonding USDC in `BazaarSequencer`:

| Parameter | Value |
|---|---|
| Minimum bond | $1,000 |
| Matching capacity | 14× bond per rolling 30 minutes |
| Batch size | no protocol ceiling — `maxMatches` (must be > 0) is the sequencer's own gas circuit-breaker |
| Omission challenge | 7% of min(batch, order) notional, min $20 — 1% to challenger, 6% to the pair's insurance fund |
| Stale-flag challenge | 1% of batch notional, min $20 — split 50/50 challenger / insurance |
| Challenge window | 29 minutes per batch (strictly inside the 30-minute volume-retention window) |

The omission challenge makes censorship strictly unprofitable: the 7% slash exceeds the 5% maximum a sequencer could ever extract via slippage, and the insurance fund (not the victim) receives the bulk so self-censoring is not a payday. Orders skipped for margin reasons during stale-oracle batches are recorded in the batch witness (`staleSkippedIds`) and are unchallengeable — the sequencer demonstrably included them.

Sequencer revenue: a dynamic taker fee that rises with global bond utilization (0.75 bp when utilization ≤50% up to 3.75 bp at ≥90%), plus 0.25 bp from makers and a $0.03 flat fee per side.

## Risk engine

**Margin.** Initial margin requirement (IMR) = 3% base × three multipliers, each ramping linearly from 1× to 3×: price-variance EMA (~14% → ~100% annualized vol), realized liquidation-gap EMA (0 → 3% gap), and insurance-fund shortfall vs. target. Non-24/7 assets get a further 1.5×. Clamped to 4%–80% (25× down to 1.25× max leverage). New pairs warm up at a 20% IMR floor (5× leverage; 30% for non-continuously traded pairs) for their first 5 days and 50,000 price updates. **MMR is always IMR/2**, and existing positions are judged against a 24-hour-lagged MMR (hourly ring buffer) so a spiking requirement can't retroactively liquidate them — a falling one helps immediately.

**Liquidation.** `liquidate(users[], priceUpdate)` is permissionless. Insolvent positions are fully liquidated: collateral is seized into the insurance fund and the position transfers to the pair's vault at its *bankruptcy price* (the price where equity = 0), aggregated into a single net inventory. Keepers earn `max($0.10, 2 bp of notional)` per position, paid from insurance. The vault then exits its inventory on the order book (Pass A, within ±min(5%, MMR) of oracle), by netting against opposite-side liquidations, or through ADL.

**Auto-deleveraging.** If the vault's expected loss exceeds 80% of the insurance fund, trading freezes and a 10-minute Dutch auction opens: profitable counterparties are ranked by profit-to-collateral score, the eligibility threshold decays from 25× toward 0, and anyone may submit winners (≤25 per call, 0.1% of averted bad debt as reward). Winners are closed at the estates' average bankruptcy price — the standard perp-DEX socialization mechanism. Hysteresis (cancel at 60%) prevents flapping; a 24-hour ADL timeout terminates the pair instead of letting it limp.

**Insurance fund.** Per-pair and share-based — anyone can LP (min $5). It absorbs vault losses and liquidation rewards, and earns maker/taker insurance fees, seized collateral, netting profits, and forfeited bonds. Target size is 2%–10% of open interest depending on volatility and realized gaps; the taker insurance fee scales up sharply when the fund is below target and discounts to zero when above (see [`RiskParamsLib`](src/libraries/RiskParamsLib.sol)). Withdrawals take a 20-day cooldown into a 3-day window, are rate-limited (0.5% of OI per 6h below target; max(1% OI, 10% fund) per withdrawal above), and shares must mature 7 days before voting on insurer terminations.

**Solvency invariant.** Every batch, liquidation, ADL, and exposure-bearing withdrawal re-checks vault health: liquidation exposure vs. insurance (→ ADL), realized bad debt (→ termination), and books-vs-actual USDC balance within 0.1% (→ emergency termination). Internal PnL moves are booked as insurance↔deposits *transfers* so the sum always matches the token balance.

## Funding

Funding accrues continuously (per second, pro-rata against a 1-hour interval) from the premium between a manipulation-resistant **mark price** and the Pyth index: the premium is dampened ÷8 and capped at ±0.5% per hour. Mark price is an EMA of batch execution VWAPs whose weight is volume-scaled and capped at 10% per batch with no floor (dust fills get ~zero weight), with each batch print clamped to ±5% of index (single-batch manipulation resistance); it decays back to index over an hour without trades. Funding settles to cash exactly once — when position shares close.

## Fees

Per fill, on notional, deducted from each side's collateral:

| Stream | Maker | Taker |
|---|---|---|
| Sequencer | 0.25 bp + $0.03 flat | 0.75–3.75 bp (utilization-priced) + $0.03 flat |
| Integrator (per-order referral address) | 0.25 bp | 0.25 bp |
| Insurance | 0.5 bp | dynamic — scales with fund shortfall; risk-*reducing* size pays at most the base closing fee |

1% of every fee stream is skimmed to a bug-bounty address fixed at factory deployment. Other flows: liquidation keeper `max($0.10, 2 bp)`, ADL executor 0.1% of averted bad debt, UMA termination proposer 0.1% of insurance (capped $100, once per pair).

## Listing a market

```
proposePairDeployment(baseFeedId, isContinuouslyTraded, totalAmount, description)
```

- `totalAmount ≥ $4,000`: $1,000 UMA assertion bond (refunded on success) + the rest seeds the pair's insurance fund.
- UMA verifiers check 7 objective criteria over a 48-hour liveness window — Pyth feed validity, correct 24/7 vs. trading-hours flag, USD denomination (non-USD via composite feeds, which must be non-continuous), linear non-expiring spot exposure (no futures/options/leveraged tokens), no 1:1 duplicates of existing listings.
- On resolution the factory clones the pair, seeds its insurance fund, and registers it with the sequencer and terminator. A false assertion loses the bond to the disputer and refunds the seed.

## Termination & settlement

Perps on real-world assets need an exit ramp — feeds get decommissioned, companies get acquired, assets stop existing. Every path ends with positions cash-settled at a defined price and withdrawals open:

| Path | Trigger | Bond / gate |
|---|---|---|
| Scheduled (UMA) | Known future cessation (delisting, oracle decommission, structural change) | $1,000 bond, 12 h liveness; settles at the Pyth tick at cessation (3 h grace), falling back to the frozen last price |
| Post-cessation (UMA) | Event already happened; proposer supplies the cessation timestamp, pair settles at the on-chain-verified Pyth tick from that moment | $1,000 bond, 72 h liveness |
| Stale oracle | No Pyth update for 21 days — objective, no UMA needed | none, anyone |
| Insurer vote | Matured shares voting yes reach 60% of the total-share snapshot taken at proposal; 7-day vote | $500 bond (forfeited if the vote fails) |
| Autonomous | Realized bad debt, ADL timeout (24 h), or books-vs-balance shortfall | none — self-executing |

Normal termination settles PnL at the final price; if insurance can't cover the winning side, winners are haircut pro-rata, and in deep insolvency principal itself is haircut pro-rata — never first-come-first-served. Emergency termination (balance shortfall) skips PnL entirely and returns collateral pro-rata.

## Repository layout

```
src/
├── BazaarPair.sol              # Core market: orders, positions, insurance, lifecycle
├── BazaarFactory.sol           # UMA-gated listings, EIP-1167 cloning
├── BazaarSequencer.sol         # Bonds, volume caps, fraud proofs
├── BazaarOracle.sol            # Pyth adapter + composite feeds
├── BazaarPairTerminator.sol    # Wind-down paths
├── BazaarPairLens.sol          # Read-only views
├── interfaces/
└── libraries/                  # DELEGATECALL externals + inlined helpers
    ├── MatchingEngineLib.sol   # Three-pass batch matching + witnesses
    ├── OrderManagementLib.sol  # Order creation/cancel/cleanup
    ├── CollateralLib.sol       # Deposits/withdrawals incl. terminal modes
    ├── LiquidationLib.sol      # Bankruptcy pricing, vault aggregation
    ├── AdlLib.sol              # Dutch-auction auto-deleveraging
    ├── InsuranceVaultLib.sol   # LP shares, cooldowns, rate limits
    ├── RiskParamsLib.sol       # Dynamic IMR/MMR + fee curves
    ├── FundingLib.sol          # Mark EMA + funding index
    ├── TerminationLib.sol      # Settlement waterfall
    ├── MetaTxLib.sol           # EIP-712 meta-transactions
    ├── BucketLib.sol           # Position solvency math
    ├── VaultHealthLib.sol      # ADL/termination triggers
    ├── MmrSampleLib.sol        # 24h-lagged MMR ring buffer
    ├── BazaarMathLib.sol       # Fixed-point + effective-price helpers
    └── BazaarTypes.sol         # Structs, enums, protocol constants
script/                         # DeployLibraries + DeployBazaar + network config
test/
├── unit/                       # 26 test files: per-library and per-mechanism
└── integration/                # 28 test files: end-to-end, incl. zero-sum invariant
```

## Documentation

The full protocol book — mechanism deep-dives, parameter tables, contract reference, and guides — lives in [`docs/`](docs) as an [mdBook](https://rust-lang.github.io/mdBook/):

```bash
mdbook serve docs    # browse at http://localhost:3000
```

A GitHub Actions workflow builds and deploys the book to GitHub Pages on every push that touches `docs/`.

## Development

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) and Node.js (for the Pyth SDK dependency).

```bash
git clone --recursive <repo-url> && cd bazaar
npm install          # @pythnetwork/pyth-sdk-solidity
forge build
forge test
```

The test suite is 768 tests across 68 suites, including a zero-sum accounting invariant, crisis-backstop scenarios, and negative-path coverage. CI runs `forge fmt --check`, build, and tests on every push.

### Local deployment

Create a `.env` (gitignored) with at least `ANVIL_RPC_URL`, `ANVIL_PRIVATE_KEY`, `ANVIL_WALLET`; for testnets add `ARBITRUM_SEPOLIA_RPC_URL`/`ARBITRUM_MAINNET_RPC_URL`, a keystore `ACCOUNT`/`SENDER`, and `ARBISCAN_API_KEY` for verification.

```bash
make anvil                                        # terminal 1: local node
make deploy-anvil                                 # terminal 2: full stack + mocks, mints test USDC
make deploy-pair-anvil FEED_ID=0x... DESC="ETH/USD"   # propose + settle a pair through mock UMA
make set-price-anvil FEED_ID=0x... PRICE=2000     # push a mock Pyth price
make create-order-anvil PAIR=0x... LIMIT_PRICE=2000 SIZE=0.01 IS_LONG=true
```

Contract addresses land in `.anvil-addresses`. Run `make help` for the full list.

### Production deployment

Deployment is two-step because the external libraries are linked by address:

1. `forge script script/DeployLibraries.s.sol --broadcast` — deploys the 8 external libraries and prints a `libraries = [...]` block;
2. paste that block into `foundry.toml`, then `make deploy-arb-sepolia` (or `deploy-arb-mainnet`).

| Network | Chain ID | Notes |
|---|---|---|
| Arbitrum One | 42161 | Production target: native USDC, Pyth, UMA OOv3 |
| Arbitrum Sepolia | 421614 | Real Pyth + testnet USDC, mock UMA (no official OOv3 there) |
| Base Sepolia | 84532 | Real UMA OOv3 — used only to exercise full dispute flows; `BazaarPair` itself requires Arbitrum's ArbSys precompile |

## Security

- **Unaudited.** This codebase has not undergone a professional audit. Known open items are tracked in the issue tracker.
- No admin keys: there is nothing to compromise, but also no one who can pause a bad deployment. Termination paths are the only brakes.
- A 1% tax on all fee streams flows to a bug-bounty address (an immutable, set at factory deployment) as standing white-hat incentive.
- Sequencer misconduct is bounded by bond economics — see [Sequencing & fraud proofs](#sequencing--fraud-proofs).

## License

[AGPL-3.0-only](LICENSE). If you fork this protocol and run it as a service, you must open-source your modifications under the same license — including the network-use provision of §13.
