# Protocol Parameters

All constants live in `src/libraries/BazaarTypes.sol`, `src/libraries/RiskParamsLib.sol`, and the contracts that use them. Values below are verified against the code.

## Order book & matching

| Parameter | Value |
|---|---|
| `MIN_ORDER_AMOUNT` | $5 notional (full closes exempt) |
| `MAX_SLIPPAGE_BP` | 1000 (10%) — market/stop-loss slippage cap |
| `MAX_PLACEMENT_DEVIATION_BP` | 5000 — a `Limit` order's resting price must be within ±50% of the mark at creation; `StopLimit` is exempt (its limit anchors to its trigger) |
| `MIN_ORDER_LIFETIME_BLOCKS` / max | 12 blocks (~3 s) / ~1 year |
| `MAX_ACTIVE_LIMIT_ORDERS_PER_USER` | 32 (Limit + StopLimit) |
| TP/SL per position | 1 each |
| `MAX_CANCELS_PER_CALL` | 200 |
| `MAX_WALK_STEPS` | 32 — ceiling on a walk's node budget (`MatchHints.maxSteps`; 0 selects the default) and on the insertion-hint repair walk |
| Insertion hints | up to 4 predecessor candidates (`MatchHints.pred..pred4`), outside the EIP-712 payload |
| `MAX_TRIGGER_EXECS_PER_CALL` | 20 stops per `executeTriggeredOrders` call |
| `TRIGGER_TIP` | $0.25 per fired stop, charged to the stop's owner |
| `TERMINAL_SETTLEMENT_TIP` | $0.10 per position settled for someone else at the fixed terminal price — from the position's remaining collateral, insurance topping up; after finalize from the insurers' residual, bankrupt stragglers only |
| `LIQ_MAX_SLIPPAGE_BP` | 500 — cap on the oracle leg of the unload bound: the vault takes makers within ±min(5%, current MMR) of oracle or at any price that beats the estates' fund-neutral price, within the fund's headroom above its reserve; the same band edge is the ADL release level |
| `ADL_RESERVE_BP` | 2,000 — 20% of the insurance target on open interest, kept out of unloads and the ADL gate for the losses no bound can refuse |
| `LIQ_INLINE_UNLOAD_STEPS` | 16 — node budget for the unload walk inside `liquidate()` |
| Integrator fee | 0.25 bp maker + 0.25 bp taker — only on orders naming an integrator |

## Margin

| Parameter | Value |
|---|---|
| `BASE_IMR_BP` | 300 (3%) |
| Stress move `M` | the one risk reading margin and the fund target both derive from. `V` = 3% × vol multiplier; continuous `M` = V/2 + liquidation-gap EMA; non-continuous `M` = max(V, reopen-gap EMA) + liquidation-gap EMA. Clamped to 2% … 40% (`MIN_STRESS_MOVE_BP` … `MAX_STRESS_MOVE_BP`, exactly half the IMR clamps) |
| Volatility multiplier | 1×→6× (through 3× at 100% ann. vol, capped at ~157%) |
| Liquidation-gap term | ADDS its EMA to `M` at full size rather than multiplying: the gap is realized shortfall past bankruptcy, so it is the amount by which maintenance margin proved too thin. A negative EMA adds nothing |
| Insurance multiplier | 1×→3× as the fund goes target → empty. Applied to IMR only, after `M`, and never to the target |
| Non-continuous multiplier | 2× — scales the warmup floor; past warmup the same closure prior is the whole-vs-half vol curve in `M` |
| Reopen-gap leg | a peak-hold of \|reopen return\| across ≥ 1 h price gaps (closures, halts, trading breaks; `REOPEN_GAP_MIN_STALENESS`), harmonic decay τ = 180 d (`REOPEN_GAP_EMA_TAU`), capped at 40% (`REOPEN_GAP_EMA_CAP_BP`) — so MMR covers the full demonstrated reopen, a cap-sized gap lands exactly on the 80% IMR clamp, and the same number reaches the fund target at full size |
| IMR | 2 × `M` × insurance multiplier, clamped to 4% … 80% (25× … 1.25× leverage) |
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
| `FUNDING_INTERVAL` | 1 h |
| Rate ceiling | ±0.5% per hour on session-bound pairs (`MAX_FUNDING_RATE_SESSION`), ±0.1% on continuously traded ones (`MAX_FUNDING_RATE_CONTINUOUS`) — a session pair accrues only while its oracle is fresh, so it needs more per accruing hour for the same weekly force |
| Premium dampening | ÷ 8 (session) / ÷ 40 (continuous) — derived from each ceiling against the shared mark band, never mixed across pair types, so the clamp is never reached from strictly inside the band |
| Mark EMA alpha | 0 … 10% per update (one per matching transaction, fed the walk's VWAP), scaled by the fill's share of rolling volume (`VOLUME_HALFLIFE` = 60 min, decayed linearly); alpha itself has no floor, but the denominator is floored at `VOLUME_FLOOR_BP` = 2% of per-side open-interest notional |
| `MAX_MARK_DEVIATION_BP` | 400 — fills clamped to ±4% of index before entering the mark EMA |
| `MARK_DECAY_PERIOD` | 1 h to index with no trades |
| Oracle-gap guards | ≤ 30 min accrual on old ticks; > 12 h gap skips the dark period |

## Liquidation, ADL & insurance

| Parameter | Value |
|---|---|
| Liquidation keeper reward | max($0.10, 2 bp of notional), capped at insurance free capital |
| `MAX_LIQUIDATION_PRICE_AGE` | 10 min — oldest stale-fallback price `liquidate()` will judge solvency against; past it the caller must supply a `priceUpdate` |
| Vault-unload keeper reward | 2 bp of unloaded notional on any amount, plus a $0.25 floor (`UNLOAD_BOUNTY_MIN`) when the call unloads ≥ $1,250 (`UNLOAD_BOUNTY_MIN_NOTIONAL`, where 2 bp overtakes the floor) or clears the inventory — so a thin-book keeper is never unpaid, and slicing one unload into many earns no premium. Paid from insurance, capped at its free capital |
| ADL trigger / release | opens when expected loss > free capital above the reserve; releases once that capital could finish the remaining inventory at the unload band's edge |
| ADL auction | 25× score → ~0, quadratic, 10 min; restarts at 25× after a ≥ 1 h price gap; ≤ 25 winners per call |
| ADL timeout | 24 h, then a 30 min fresh-priced runway → settlement window opens at the live price |
| ADL executor reward | 0.1% of averted bad debt, capped at insurance free capital |
| Insurance target | the pair's stress move `M` × `INSURANCE_TARGET_KAPPA_BP` (1×), clamped to 2% … 10% of OI — the same reading maintenance margin is set to, so coverage per unit of maintenance margin is constant across pairs and regimes |
| Insurance LP | min $5 deposit; 20-day cooldown + 3-day window; rate limits min(0.5% OI, 5% fund) / 6 h (below target), max(1% OI, 10% fund) (above) |
| Insurance share pricing | mint and redeem against free capital (fund less the seizure earmarked against held inventory) plus the inventory's unrealized result at the mark — a deposit counts gain and loss, a redemption counts loss only. The loss deduction stops at the capital above the reserve (`ADL_RESERVE_BP`), since the auction charges the rest to winners. A redemption on a live pair always needs a fresh mark; a deposit needs one only while the vault holds inventory, and reads no price at all when it is flat |
| Maker insurance fee | 0.5 bp flat |
| Taker insurance fee | base 0.5 bp … 2 bp (scales with target ratio); below target × (1 + 49·deficit²), 45 bp hard cap; never below the base rate |
| `BUG_BOUNTY_TAX_BP` | 100 (1% of all fee streams) |

## Oracle

| Parameter | Value |
|---|---|
| `MAX_PRICE_STALENESS` | 2 s, every submission path |
| `MAX_CONFIDENCE_BP` | 200 (2% confidence cap) |
| `REFRESH_BOUNTY` | $0.25 per `refreshPrice` call, paid from insurance |
| `REFRESH_BOUNTY_MIN_GAP` | 10 min — the pre-refresh stored price must be older than this |
| Refresh bounty floors | insurance free capital > $10,000 and OI notional > $10,000 (`REFRESH_BOUNTY_MIN_INSURANCE` / `REFRESH_BOUNTY_MIN_OI_NOTIONAL`) |

## Meta-transactions

| Parameter | Value |
|---|---|
| `MAX_RELAYER_FEE` | $1 per meta-transaction, accrued to the relayer's claimable balance |
| `MAX_DEADLINE_WINDOW` | 10 s max signature deadline |

## Payouts

| Parameter | Value |
|---|---|
| Payout mechanism | every third-party payout (keeper rewards, integrator fees, bug-bounty tax, relayer fees, UMA proposer reward) accrues to a per-pair claimable balance — `claimableFees(address)` to read, `claimFees()` to withdraw, `FeeAccrued` per accrual; open in every pair state |

## Listing & termination

| Parameter | Value |
|---|---|
| Listing | ≥ $4,000 = $1,000 UMA bond + ≥ $3,000 seed (`MIN_INSURANCE_SEED`); 48 h liveness |
| UMA identifier upgrade | $5,000 bond, 2-day liveness, then a 14-day activation timelock (`IDENTIFIER_UPGRADE_TIMELOCK`) after approval |
| `DVM_DISPUTE_GRACE` | 14 days on top of liveness before a **disputed** proposal may be discarded as unsettleable; shared by the deployment and identifier tracks (it bounds the DVM, not the claim) |
| Bond constants | floors, not fixed amounts — `requiredDeploymentBond()` / `requiredIdentifierUpgradeBond()` / `requiredTerminationBond()` each return `max(constant, UMA's live minimum)` |
| Proposer free text | listing `description` ≤ 200 bytes; termination `reason` ≤ 1,000 and `pairDescription` ≤ 100 (`MAX_REASON_LENGTH`, `MAX_PAIR_DESCRIPTION_LENGTH`); restricted ASCII, no square brackets |
| Scheduled termination | $1,000 bond, 12 h liveness, `lastTradingTs` ≥ 12 h out; 12 h precise-tick grace from the later of the cutoff and UMA acceptance |
| Stale-oracle termination | 21 days |
| Terminal settlement escape hatch | 14 days after `fixSettlementPrice`, `finalizeTermination` no longer waits for every position to be settled (deposits + all withdrawals stay frozen until finalize) |
| Insurer sweep grace | after an escape-hatch finalize, insurance withdrawals wait until every position is settled or 14 days beyond the hatch (`INSURER_SWEEP_GRACE`; 28 days after the fix at the latest) |
| Insurer vote | $500 bond; 60% of shares; 7-day vote + 7-day execution window; 14-day cooldown; 7-day share maturity |
| Balance-check tolerance | 0.1% (`USDC_BALANCE_TOLERANCE_BP`) |
| UMA proposer reward | 0.1% of fund, cap $100, once per pair |
