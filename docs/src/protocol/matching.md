# Batch Matching

Matching runs in **batches**: a bonded sequencer snapshots the resting book off-chain, sorts it, and calls

```solidity
matchBatch(
    OrderLists calldata lists,      // {longLimits, shortLimits, longMarkets, shortMarkets}
    uint256 maxMatches,             // sequencer's gas circuit-breaker (must be > 0; no protocol ceiling)
    bytes[] calldata priceUpdate,   // Pyth update for the settlement price
    uint64 observationBlock         // L2 block at which the book was snapshotted
)
```

The contract does not trust the sorting — it re-verifies order, type, and tiebreaks inline while walking, and reverts on any violation.

## Sort invariants

| List | Primary sort | Tiebreak |
|---|---|---|
| `longLimits` | `limitPrice` DESC | `orderId` ASC |
| `shortLimits` | `limitPrice` ASC | `orderId` ASC |
| `longMarkets` / `shortMarkets` | `maxSlippageBp` DESC | `orderId` ASC |

Price-time priority is therefore enforced with order IDs (per-pair monotonic counter) as the FIFO axis.

## The three passes

| Pass | Who crosses | Maker rule | Notes |
|---|---|---|---|
| **A** | vault liquidation inventory × limits | vault has no order; limit's price fills | only inside a band of min(`LIQ_MAX_SLIPPAGE_BP` = 5%, current MMR) around oracle; runs even when the oracle is stale — liquidation flow is forced |
| **B** | markets × limits | **limit is always maker**; fill at the limit's effective price | two deterministic sub-walks (long-markets first); skipped entirely when the oracle is stale |
| **C** | limits × limits | **older orderId is maker**; fill at maker's price | post-only violations and self-matches auto-cancel the newer order |

Market and StopLoss orders have an *effective price* of oracle ± their slippage cap; limit-typed orders use their limit price. The same `effectivePrice` function drives matching **and** omission challenges, so the two can never disagree.

## Per-fill checks

Each prospective fill re-checks the owner's margin at the fresh oracle price:

- **Fails normal IMR** → the order is **auto-canceled** (stamped `canceledBlock`, event emitted). A user who drifted insolvent since creation cannot haunt the book.
- **Passes normal but fails the 2× stale-IMR check** (only relevant in stale-oracle batches) → the order is skipped and its ID recorded in the batch witness `staleSkippedIds[]`, keeping it alive for the next fresh batch — and unchallengeable for this one.
- **Stale price band** (also stale-only) — a fill priced more than ±10% (`MAX_STALE_DEVIATION_BP`) from the last oracle price is voided: both sides are skipped and recorded in `staleSkippedIds[]`, so the void reads as a legitimate skip rather than an omission.

Fills realize proportional PnL and funding on closing portions, classify open/add/close/flip by size, and update both sides' buckets plus open-interest aggregates.

## Observation-block discipline

`observationBlock` must be in the past and at most **12 L2 blocks** (~3 s) old. Orders created after it revert the batch (`OrderCreatedAfterObservation`); orders already filled at it revert (`StaleFilledOrder`); orders canceled, filled, or expired in the race window are skipped without penalty. This pins every batch to a verifiable snapshot of the book — the anchor for censorship proofs.

## The batch witness

`_finalize` assembles a `BatchInfo` struct — total matched notional, oracle price, execution/observation blocks, timestamp, sequencer, stale flag, the **worst fill per side per type** (price + orderId FIFO watermarks), two Pass-C cross-side witnesses used to catch market-order censorship, and `staleSkippedIds[]` — hashes it into `batchHashes[batchId]`, and emits the full preimage in `BatchRecorded`. Anyone can later re-derive the hash and prove misconduct against it: see [Sequencers & Fraud Proofs](sequencers.md).

Zero-match batches store no hash and are unchallengeable — with no fills there is no matched range to have been censored from.

## Volume capacity

Before walking, the pair asks the sequencer registry for the caller's remaining capacity (bond × 14 over a rolling 30 minutes) and reverts if none; fills that would cross the boundary partial-fill up to it. Matched volume is recorded back to the registry after the walk.
