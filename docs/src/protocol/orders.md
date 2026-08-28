# Orders

Orders live in the pair's `orders` mapping and are matched **on arrival** ([Matching](matching.md)):
creating an order and trading are the same transaction. Every user has **one net position per
market** (a *position bucket*); orders modify it.

## Order types

| Type | Priced by | Trigger | Notes |
|---|---|---|---|
| `Market` | book prices, bounded by oracle ± `maxSlippageBp` | — | slippage cap 5%; fills immediately, remainder cancels — never rests; rejected while the oracle is stale |
| `Limit` | `limitPrice` | — | GTC by default; the only type that takes `isPostOnly` or `isIoc` |
| `StopLimit` | `limitPrice` | arms at `triggerPrice` | limit must be on the fillable side of the trigger (buy: limit ≥ trigger) |
| `TakeProfit` | `limitPrice` | — | position-reducing only: opposite direction, `size ≤ position`, **1 per position**, never expires; **rests in the book from creation** |
| `StopLoss` | book prices, bounded by oracle ± `maxSlippageBp` | arms at `triggerPrice` | same restrictions as TakeProfit |

**Time-in-force.** A Limit order with `isIoc` fills whatever crosses on arrival and cancels the
remainder instead of resting. `isPostOnly` is the opposite commitment — crossing anything cancels
the order before any fill. The two are mutually exclusive.

**Stops.** An untriggered StopLimit/StopLoss rests *outside* the book. If a fresh oracle price
already meets the trigger at creation (buy fires at price ≥ trigger, sell at ≤, inclusive), the
stop arms immediately in the same transaction. Otherwise anyone may fire it later through
`executeTriggeredOrders` with a fresh Pyth price: the executor earns a flat `TRIGGER_TIP` ($0.25)
charged to the stop's owner like a trading fee — no escrow. An owner whose collateral cannot cover
the tip has the stop auto-canceled instead, mirroring the fee-coverage rule every fill applies.
Triggers are evaluated against the oracle price the executor proves, never a price the executor
chooses.

## Creation rules

- Minimum order notional **$5**, with one exemption: an exact full-close of your position is
  always allowed — at creation and again when a partial fill leaves a full-close remainder.
- Initial-margin check at creation covers **worst-case exposure**: your position plus all resting
  orders in whichever direction is worse — including the flip case. The requirement is the same
  under a stale oracle — gap risk lives in non-24/7 markets' always-on margin, not in a
  stale-mode rate.
- Anti-DoS caps: ≤ **100** active Limit+StopLimit orders per user, 1 TakeProfit + 1 StopLoss per
  position. These bound the exposure-tally iteration cost and each user's worst-case book
  footprint.
- Lifetimes are stamped in Arbitrum L2 blocks: minimum ~3 s (12 blocks), maximum ~1 year; TP/SL
  never expire; Market orders are terminal within their own transaction.
- Every order can carry an `integrator` address that earns a [referral fee](fees.md) on fills.

## Cancellation & cleanup

- `cancelOrders(orderIds[], …)` — creator-only, up to 200 per call. Canceling unlinks the order
  from the book in the same write, so no walk can ever fill it afterwards.
- Expired orders are removed by whoever touches them first: the matching walk cancels-and-unlinks
  an expired maker on contact, the owner's lazy sweeps run during creation, withdrawal, and the
  `getUserActiveLimitOrders` query, and anyone may call the permissionless
  `sweepExpired(orderIds[])` janitor. Until then an expired order sits inert — still linked, but
  unable to fill.
- The matching engine **auto-cancels** orders in these situations: a fill that would fail the
  owner's margin check, a self-match (the incoming order cancels), a post-only order that would
  take instead of make, an IOC/Market/step-capped/dust remainder, a stop whose owner cannot cover
  the trigger tip, and a resting TP/SL left oversized after a fill shrinks or flips the position.
  Every auto-cancel unlinks in the same transaction.

## Order lifecycle

```
createOrder ──► matched on arrival ──┬─► filled          (full or partial fills, same tx or later)
                                     ├─► resting         (GTC remainder in the book; stops outside it)
                                     ├─► canceled        (user, auto-cancel, sweep)
                                     └─► expired         (block-stamped lifetime passes)
```

`filledBlock` / `canceledBlock` stamps plus the `inBook` flag make every order's terminal state
and book membership readable on-chain at any time.
