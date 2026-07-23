# Protocol Parameters

All constants live in `src/libraries/BazaarTypes.sol`, `src/libraries/RiskParamsLib.sol`, and the contracts that use them. Values below are verified against the code.

## Orders & matching

| Parameter | Value |
|---|---|
| `MIN_ORDER_AMOUNT` | $5 notional (full closes exempt) |
| `MAX_SLIPPAGE_BP` | 500 (5%) — market/stop-loss slippage cap |
| `MARKET_ORDER_LIFETIME_BLOCKS` | 12 L2 blocks (~3 s) |
| `MIN_ORDER_LIFETIME_BLOCKS` / max | 12 blocks (~3 s) / ~1 year |
| `MAX_ACTIVE_LIMIT_ORDERS_PER_USER` | 100 (Limit + StopLimit) |
| Active market orders per user | 1 · TP/SL: 1 each per position |
| `MAX_CANCELS_PER_CALL` | 200 |
| `MAX_OBSERVATION_BLOCK_AGE` | 12 L2 blocks |
| `LIQ_MAX_SLIPPAGE_BP` | 500 — cap on the Pass-A band; effective band is ±min(5%, current MMR) |
| Integrator fee | 0.25 bp maker + 0.25 bp taker — only on orders naming an integrator |

## Sequencers

| Parameter | Value |
|---|---|
| `MIN_BOND` | $1,000 |
| `VOLUME_CAP_MULTIPLIER` | 14× bond per rolling 30 min (`NUM_BUCKETS` × `BUCKET_DURATION`) |
| Challenge window | 29 min (`SEQUENCER_WINDOW`), strictly inside the 30-min volume window |
| `OMISSION_PENALTY_BP` | 700 (7%), min $20 — 1% challenger / 6% insurance |
| `STALE_PENALTY_BP` | 100 (1%), min $20 — 50/50 challenger / insurance |
| Maker sequencer fee | 0.25 bp |
| Taker sequencer fee | 0.75 bp (≤ 50% util) → 3.75 bp (≥ 90%) |
| `SEQUENCER_FLAT_FEE_PER_SIDE` | $0.03 per side, on top of bps fees |

## Margin

| Parameter | Value |
|---|---|
| `BASE_IMR_BP` | 300 (3%) |
| Multipliers | volatility, liquidation-gap, insurance — each 1×→3× |
| Non-continuous multiplier | 1.5× |
| IMR clamp | 4% … 80% (25× … 1.25× leverage) |
| Warmup floor | 20% IMR (30% for non-continuously traded pairs) for 5 days *and* 50,000 price updates |
| MMR | IMR / 2 |
| MMR grace | 24 h lag, 25 hourly samples |
| `STALE_MARGIN_MULTIPLIER` | 2× on new fills under stale oracle |
| `MAX_STALE_DEVIATION_BP` | 1000 (±10% stale-fill band) |
| `MIN_COLLATERAL_AMOUNT` | $1 minimum collateral deposit |

## Funding

| Parameter | Value |
|---|---|
| `FUNDING_INTERVAL` / cap | 1 h / ±0.5% per hour |
| Premium dampening | ÷ 8 |
| Mark EMA alpha | 0 … 10% per batch, volume-scaled (no floor) |
| `MAX_MARK_DEVIATION_BP` | 500 — fills clamped to ±5% of index before entering the mark EMA |
| `MARK_DECAY_PERIOD` | 1 h to index with no trades |
| Oracle-gap guards | ≤ 30 min accrual on old ticks; > 12 h gap skips the dark period |

## Liquidation, ADL & insurance

| Parameter | Value |
|---|---|
| Liquidation keeper reward | max($0.10, 2 bp of notional) |
| ADL trigger / cancel | expected loss > 80% / < 60% of fund |
| ADL auction | 25× score → ~0, quadratic, 10 min; ≤ 25 winners per call |
| ADL timeout | 24 h → termination |
| ADL executor reward | 0.1% of averted bad debt |
| Insurance target | 2% … 10% of OI (vol-scaled, ≥ 3× gap EMA) |
| Insurance LP | min $5 deposit; 20-day cooldown + 3-day window; rate limits 0.5% OI / 6 h (below target), max(1% OI, 10% fund) (above) |
| Maker insurance fee | 0.5 bp flat |
| Taker insurance fee | base 0.5 bp … 2 bp (scales with target ratio); below target × (1 + 49·deficit²), 45 bp hard cap; discounted toward 0 above target |
| `BUG_BOUNTY_TAX_BP` | 100 (1% of all fee streams) |

## Oracle

| Parameter | Value |
|---|---|
| `MAX_PRICE_STALENESS` / user tier | 2 s / 10 s |
| `MAX_CONFIDENCE_BP` | 200 (2% confidence cap) |

## Meta-transactions

| Parameter | Value |
|---|---|
| `MAX_RELAYER_FEE` | $1 per meta-transaction |
| `MAX_DEADLINE_WINDOW` | 30 s max signature deadline |

## Listing & termination

| Parameter | Value |
|---|---|
| Listing | ≥ $4,000 = $1,000 UMA bond + ≥ $3,000 seed; 48 h liveness |
| UMA oracle upgrade | $5,000 bond, 14-day liveness, then a 14-day activation timelock (`ORACLE_UPGRADE_TIMELOCK`) after approval |
| Scheduled termination | $1,000 bond, 12 h liveness, `lastTradingTs` ≥ 12 h out; 3 h precise-tick grace |
| Post-cessation termination | $1,000 bond, 72 h liveness |
| Stale-oracle termination | 21 days |
| Insurer vote | $500 bond; 60% of shares; 7-day vote + 7-day execution window; 14-day cooldown; 7-day share maturity |
| Balance-check tolerance | 0.1% (`USDC_BALANCE_TOLERANCE_BP`) |
| UMA proposer reward | 0.1% of fund, cap $100, once per pair |
