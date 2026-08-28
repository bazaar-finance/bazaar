# Protocol Parameters

All constants live in `src/libraries/BazaarTypes.sol`, `src/libraries/RiskParamsLib.sol`, and the contracts that use them. Values below are verified against the code.

## Order book & matching

| Parameter | Value |
|---|---|
| `MIN_ORDER_AMOUNT` | $5 notional (full closes exempt) |
| `MAX_SLIPPAGE_BP` | 500 (5%) — market/stop-loss slippage cap |
| `MIN_ORDER_LIFETIME_BLOCKS` / max | 12 blocks (~3 s) / ~1 year |
| `MAX_ACTIVE_LIMIT_ORDERS_PER_USER` | 100 (Limit + StopLimit) |
| TP/SL per position | 1 each |
| `MAX_CANCELS_PER_CALL` | 200 |
| `MAX_WALK_STEPS` | 32 — ceiling on a walk's node budget (`MatchHints.maxSteps`; 0 selects the default) and on the insertion-hint repair walk |
| Insertion hints | up to 4 predecessor candidates (`MatchHints.pred..pred4`), outside the EIP-712 payload |
| `MAX_TRIGGER_EXECS_PER_CALL` | 20 stops per `executeTriggeredOrders` call |
| `TRIGGER_TIP` | $0.25 per fired stop, charged to the stop's owner |
| `LIQ_MAX_SLIPPAGE_BP` | 500 — cap on the liquidation-unload band; effective band is ±min(5%, current MMR) |
| `LIQ_INLINE_UNLOAD_STEPS` | 16 — node budget for the unload walk inside `liquidate()` |
| Integrator fee | 0.25 bp maker + 0.25 bp taker — only on orders naming an integrator |

## Margin

| Parameter | Value |
|---|---|
| `BASE_IMR_BP` | 300 (3%) |
| Multipliers | volatility 1×→6× (through 3× at 100% ann. vol, capped at ~157%); liquidation-gap and insurance each 1×→3× |
| Non-continuous multiplier | 2× |
| Reopen-gap leg | non-continuous IMR = 2 × max(vol curve, reopen-gap EMA). The EMA is a peak-hold of \|reopen return\| across ≥ 1 h price gaps (closures, halts, trading breaks; `REOPEN_GAP_MIN_STALENESS`), harmonic decay τ = 180 d (`REOPEN_GAP_EMA_TAU`), capped at 40% (`REOPEN_GAP_EMA_CAP_BP`) — so MMR covers the full demonstrated reopen, and a cap-sized gap doubles to exactly the 80% IMR clamp |
| IMR clamp | 4% … 80% (25× … 1.25× leverage) |
| Warmup floor | 20% IMR (40% for non-continuously traded pairs) for 5 days *and* 50,000 price updates |
| MMR | IMR / 2 |
| MMR grace | 24 h lag, 25 hourly samples |
| `MAX_STALE_DEVIATION_BP` | 1000 (±10% stale-fill band) |
| Stale withdrawal gate | a position holder's withdrawal requires a fresh price (reverts on the stale fallback); flat and order-only accounts are exempt, deposits unaffected |
| `MIN_COLLATERAL_AMOUNT` | $5 minimum collateral deposit |
| Retained-collateral floor | a position-holding account must keep margin in collateral proper (cash, not equity): `mmrBp` of current notional on continuously traded pairs, `imrBp` on session-bound pairs. Guarantees the fee that closes the position is always payable, and keeps margin in money that survives a reversal — paper profit evaporates in the same move it would need to buffer, and across a reopen gap no liquidation can interpose |

## Funding

| Parameter | Value |
|---|---|
| `FUNDING_INTERVAL` / cap | 1 h / ±0.5% per hour |
| Premium dampening | ÷ 8 |
| Mark EMA alpha | 0 … 10% per update (one per matching transaction, fed the walk's VWAP), volume-scaled (no floor) |
| `MAX_MARK_DEVIATION_BP` | 500 — fills clamped to ±5% of index before entering the mark EMA |
| `MARK_DECAY_PERIOD` | 1 h to index with no trades |
| Oracle-gap guards | ≤ 30 min accrual on old ticks; > 12 h gap skips the dark period |

## Liquidation, ADL & insurance

| Parameter | Value |
|---|---|
| Liquidation keeper reward | max($0.10, 2 bp of notional) |
| Vault-unload keeper reward | max($0.25 `UNLOAD_BOUNTY_MIN`, 2 bp of unloaded notional), paid from insurance when ≥ $1,250 notional unloads (`UNLOAD_BOUNTY_MIN_NOTIONAL`, the point where 2 bp overtakes the floor) or the unload clears the inventory; all-or-nothing on insurance coverage |
| ADL trigger / cancel | expected loss > 80% / < 60% of fund |
| ADL auction | 25× score → ~0, quadratic, 10 min; ≤ 25 winners per call |
| ADL timeout | 24 h → settlement window opens at the live price |
| ADL executor reward | 0.1% of averted bad debt |
| Insurance target | 2% … 10% of OI — max(vol-scaled, 3× liquidation-gap EMA, ½ × reopen-gap EMA on non-continuous pairs) |
| Insurance LP | min $5 deposit; 20-day cooldown + 3-day window; rate limits 0.5% OI / 6 h (below target), max(1% OI, 10% fund) (above) |
| Maker insurance fee | 0.5 bp flat |
| Taker insurance fee | base 0.5 bp … 2 bp (scales with target ratio); below target × (1 + 49·deficit²), 45 bp hard cap; discounted toward 0 above target |
| `BUG_BOUNTY_TAX_BP` | 100 (1% of all fee streams) |

## Oracle

| Parameter | Value |
|---|---|
| `MAX_PRICE_STALENESS` | 2 s, every submission path |
| `MAX_CONFIDENCE_BP` | 200 (2% confidence cap) |
| `REFRESH_BOUNTY` | $0.25 per `refreshPrice` call, paid from insurance |
| `REFRESH_BOUNTY_MIN_GAP` | 10 min — the pre-refresh stored price must be older than this |
| Refresh bounty floors | insurance fund > $10,000 and OI notional > $10,000 (`REFRESH_BOUNTY_MIN_INSURANCE` / `REFRESH_BOUNTY_MIN_OI_NOTIONAL`) |

## Meta-transactions

| Parameter | Value |
|---|---|
| `MAX_RELAYER_FEE` | $1 per meta-transaction |
| `MAX_DEADLINE_WINDOW` | 10 s max signature deadline |

## Listing & termination

| Parameter | Value |
|---|---|
| Listing | ≥ $4,000 = $1,000 UMA bond + ≥ $3,000 seed (`MIN_INSURANCE_SEED`); 48 h liveness |
| UMA identifier upgrade | $5,000 bond, 2-day liveness, then a 14-day activation timelock (`IDENTIFIER_UPGRADE_TIMELOCK`) after approval |
| `DVM_DISPUTE_GRACE` | 14 days on top of liveness before a **disputed** proposal may be discarded as unsettleable; shared by the deployment and identifier tracks (it bounds the DVM, not the claim) |
| Bond constants | floors, not fixed amounts — `requiredDeploymentBond()` / `requiredIdentifierUpgradeBond()` / `requiredTerminationBond()` each return `max(constant, UMA's live minimum)` |
| Proposer free text | listing `description` ≤ 200 bytes; termination `reason` ≤ 1,000 and `pairDescription` ≤ 100 (`MAX_REASON_LENGTH`, `MAX_PAIR_DESCRIPTION_LENGTH`); restricted ASCII, no square brackets |
| Scheduled termination | $1,000 bond, 12 h liveness, `lastTradingTs` ≥ 12 h out; 3 h precise-tick grace |
| Post-cessation termination | $1,000 bond, 72 h liveness; cessation timestamp ≤ 7 days old (`MAX_CESSATION_LOOKBACK`) |
| Stale-oracle termination | 21 days |
| Terminal settlement window | 48 h between `fixSettlementPrice` and `finalizeTermination` (deposits + all withdrawals frozen) |
| Terminal settlement bounty | `max($0.10, 2 bp of notional)` per position, debited from that position's own remaining collateral (insurance only when a position is wiped out by its own loss) |
| Insurer vote | $500 bond; 60% of shares; 7-day vote + 7-day execution window; 14-day cooldown; 7-day share maturity |
| Balance-check tolerance | 0.1% (`USDC_BALANCE_TOLERANCE_BP`) |
| UMA proposer reward | 0.1% of fund, cap $100, once per pair |
