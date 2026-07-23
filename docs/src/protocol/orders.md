# Orders

Orders rest on-chain in the pair's `orders` mapping and are matched in [sequencer batches](matching.md). Every user has **one net position per market** (a *position bucket*); orders modify it.

## Order types

| Type | Priced by | Trigger | Notes |
|---|---|---|---|
| `Market` | oracle ± `maxSlippageBp` | — | slippage cap 5%; 12-block (~3 s) lifetime; **1 active per user**; rejected while the oracle is stale |
| `Limit` | `limitPrice` | — | the only post-only-capable type |
| `StopLimit` | `limitPrice` | arms at `triggerPrice` | limit must be on the fillable side of the trigger (buy: limit ≥ trigger) |
| `TakeProfit` | `limitPrice` | — | position-reducing only: opposite direction, `size ≤ position`, **1 per position**, never expires |
| `StopLoss` | oracle ± `maxSlippageBp` | arms at `triggerPrice` | same restrictions as TakeProfit |

Stops are trigger-gated against the **batch's settlement oracle price**, not a sequencer-chosen price — a sequencer cannot arm a stop early. Buy stops fire at price ≥ trigger, sell stops at ≤ (inclusive).

## Creation rules

- Minimum order notional **$5**, with one exemption: an exact full-close of your position is always allowed.
- Initial-margin check at creation covers **worst-case exposure**: your position plus all resting orders in whichever direction is worse — including the flip case. Under a stale oracle the requirement doubles.
- Anti-DoS caps: ≤ **100** active Limit+StopLimit orders per user, **1** active Market order, 1 TakeProfit + 1 StopLoss per position. These bound both the sequencer's calldata and the exposure-tally iteration cost.
- Lifetimes are stamped in Arbitrum L2 blocks: minimum ~3 s (12 blocks), maximum ~1 year; market orders always ~3 s; TP/SL never expire.
- Every order can carry an `integrator` address that earns a [referral fee](fees.md) on fills.

## Cancellation & cleanup

- `cancelOrders(orderIds[], …)` — creator-only, up to 200 per call.
- Expired limit orders are swept lazily during creation, withdrawal, and the `getUserActiveLimitOrders` query (the matching walk merely skips them); sweeps emit the same `OrderUpdated(Canceled)` event.
- The matching engine **auto-cancels** orders in four situations: a fill that would fail the owner's margin check, a self-match (newer order cancels), a post-only order that would take instead of make, and a resting TP/SL left oversized after a fill shrinks or flips the position. Auto-cancellation is what makes [omission challenges](sequencers.md) sound — every walked order ends in a provable terminal state.

## Order lifecycle

```
createOrder ──► resting ──┬─► filled          (matchBatch, full or partial fills)
                          ├─► canceled        (user, auto-cancel, lazy sweep)
                          └─► expired         (block-stamped lifetime passes)
```

`filledBlock` / `canceledBlock` stamps plus `creationBlock ≤ observationBlock` liveness rules are exactly what omission challenges replay — see [Sequencers & Fraud Proofs](sequencers.md).
