# Sequencers & Fraud Proofs

Sequencing is **permissionless**: anyone who bonds USDC in `BazaarSequencer` can submit batches to any pair. There is no whitelist, no rotation, no leader election — sequencers compete, and the protocol makes misbehavior provable and unprofitable rather than impossible.

## Bonds & capacity

| Parameter | Value |
|---|---|
| Minimum bond | $1,000 (`MIN_BOND`) |
| Matching capacity | 14× bond per rolling 30-minute window (`VOLUME_CAP_MULTIPLIER`; `NUM_BUCKETS` × `BUCKET_DURATION`) — its inverse (≈7.14% of volume) is also the withdrawal floor, sized to cover the 7% max omission slash |
| Withdrawal rule | remaining bond ≥ $1,000 (or exactly 0) **and** ≥ what your last-30-minute volume requires |

Volume is tracked in 30 one-minute circular buckets per sequencer plus a global aggregate. The capacity rule means a sequencer's worst-case slashable misconduct is always a bounded multiple of what they have at stake.

## Sequencer revenue

- Dynamic taker fee: 0.75 bp while global bond utilization ≤ 50%, rising linearly to 3.75 bp at ≥ 90% — high utilization simultaneously pays sequencers more and invites more bonding.
- 0.25 bp maker fee and $0.03 flat per side (see [Fees](fees.md)).

## Challenge 1 — omission (censorship)

`challengeOmission(pair, batchId, batchInfo, omittedOrderId)` — prove the sequencer left out an order that should have matched. The caller supplies the batch preimage (verified against the stored hash) and the censored order ID; the contract replays the decision:

1. Preimage hash matches `batchHashes[batchId]`.
2. The order exists, was created ≤ `observationBlock`, and was still alive at `executionBlock` (not canceled, filled, or expired).
3. Market/StopLoss orders are unchallengeable in stale batches (they're excluded from stale matching by design).
4. The order is not in `staleSkippedIds[]` — if it is, the sequencer demonstrably included it and the walk skipped it legitimately.
5. Stop orders must actually have been triggered at the batch's oracle price.
6. **In-range check**: the order's effective price beats the worst same-side fill recorded in the witness (FIFO orderId tiebreak at equal price). Market orders get a second, always-on cross-side check against the Pass-C witnesses — this catches both total market-order censorship and "include only the most aggressive market to game the cutoff" selective censorship.

**Slash: 7% of min(batch notional, censored order's notional), minimum $20 — 1% to the challenger, 6% to the pair's insurance fund.** The penalty deliberately exceeds the 5% maximum slippage a sequencer could ever extract by censoring, and the victim is deliberately *not* the payee — so self-censoring your own order is never profitable. Per-batch slashes are capped at 7% of the batch's notional, and each (pair, batch, order) can be won once.

## Challenge 2 — false stale flag

`challengeStaleBatch(pair, batchId, batchInfo, priceData)` — prove a batch was labeled "oracle stale" when a fresh Pyth tick existed. The challenger supplies a Pyth price proof with publish time in `[matchTimestamp − 2 s, matchTimestamp − 1 s]` (the 1-second grace concedes that a sequencer can't see a tick mined the same second it built the batch). Verified through `BazaarOracle.fetchHistoricalPrice`.

**Slash: 1% of batch notional, minimum $20 — split 50/50 challenger / insurance fund.**

Why it matters: stale batches run under a laxer regime (no market orders, wider margin) — a sequencer who *pretends* the oracle is stale could selectively suppress market flow. This challenge makes the stale flag itself accountable.

## What the design intentionally does not punish

- **Not sequencing at all.** Bazaar has no liveness slashing; the incentive to sequence is fee revenue, and multiple sequencers can serve the same pair.
- **Omitting an entire side of the limit book.** With no same-side fills there is no witness to measure against; the deterrent is forgone fees plus competition.
- **Deferring below-cutoff orders.** A sequencer with a bounded gas budget may legitimately include only the most aggressive orders; the FIFO witness only condemns skipping an order *better* than one that matched.

Both challenges run within **29 minutes** of the batch's `matchTimestamp` (`SEQUENCER_WINDOW`) — kept strictly below the 30-minute volume-retention window so a batch's bond stays in the withdrawal floor for its entire challenge life; slashes are capped at the sequencer's remaining bond and push USDC into the pair's insurance fund.
