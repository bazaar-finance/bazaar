# Orders

Orders live in the pair's `orders` mapping and are matched **on arrival** ([Matching](matching.md)):
creating an order and trading are the same transaction. Every user has **one net position per
market** (a *position bucket*); orders modify it.

## Order types

| Type | Priced by | Trigger | Notes |
|---|---|---|---|
| `Market` | book prices, bounded by oracle ± `maxSlippageBp` | — | slippage cap 10%; fills immediately, remainder cancels — never rests; rejected while the oracle is stale |
| `Limit` | `limitPrice` | — | the only type that takes `isPostOnly`, and the only one that can rest (`tif: GTC`) |
| `StopLimit` | `limitPrice` | arms at `triggerPrice` | limit must be on the fillable side of the trigger (buy: limit ≥ trigger) |
| `TakeProfit` | book prices, bounded by oracle ± `maxSlippageBp` | fires at `triggerPrice` **in your favour** | position-reducing only: opposite direction, size capped at the live position (`type(uint256).max` = all of it), **1 per position**, never expires |
| `StopLoss` | book prices, bounded by oracle ± `maxSlippageBp` | fires at `triggerPrice` **against you** | same restrictions as TakeProfit |

**Time-in-force.** One field, `tif`, with three values — what the order does with size the book
could not fill it for:

| `tif` | Remainder | Accepted on |
|---|---|---|
| `GTC` | rests in the book | every type (the types that never rest ignore it) |
| `IOC` | canceled, the partial stands | `Limit` |
| `FOK` | **the transaction reverts** — no partial, no order | `Limit`, `Market` |

`FOK` is all-or-none: if the walk cannot fill the whole size, the revert unwinds the fills it had
already settled along with the order's own creation, so nothing survives. It is the one
time-in-force that can fail after doing work, and the caller pays the gas either way.

`FOK` is accepted on `Market` where `IOC` is not, because a Bazaar market order is bounded by
`maxSlippageBp` rather than unbounded — "all of it, within my tolerance, or none" is a real
instruction, while "cancel the remainder" is what a market order already does. Neither is accepted
on the trigger types: those rest outside the book rather than crossing on arrival, and a TP/SL caps
its size against the live position when it fires, so "the entire amount" names no fixed quantity.

`isPostOnly` is a separate commitment and the opposite one — crossing anything cancels the order
before any fill — so it cannot be combined with `IOC` or `FOK`.

**Sizing a TP/SL.** The size is capped against the live position when the order *fires*, not when
you write it, so a close-only order can never take past flat and open a reverse one. To close the
whole position whatever it turns out to be, pass `type(uint256).max` — any size at or above the
position closes exactly the position. Nothing is rejected for being too big, and a position that
later shrinks — through a partial close, a partial liquidation, or a partial deleverage — leaves
the order armed for what remains rather than cancelling it. Only a position that goes flat or
flips side cancels a TP/SL, because neither can reduce anything then.

Size `0` is rejected for every order type, TP/SL included: with `max` available as the
close-everything idiom, zero carries no meaning.

Capping bounds the close; it does not make the order persistent. A book too thin to absorb the
resolved size fills what it can and cancels the remainder like any market execution, which leaves
the surviving position without a target until you arm a new one.

**Trigger orders.** StopLimit, StopLoss and TakeProfit all wait *outside* the book until an oracle
price reaches their trigger. If a fresh price already satisfies the trigger at creation, the order
arms immediately in the same transaction; otherwise anyone may fire it later through
`executeTriggeredOrders` with a fresh Pyth price. The executor earns a flat `TRIGGER_TIP` ($0.25),
charged to the owner at execution like a trading fee (nothing is reserved at creation) and accrued
to the executor's claimable balance. An owner whose collateral cannot cover the tip has the order
auto-canceled instead, mirroring the fee-coverage rule every fill applies. Triggers
are evaluated against the oracle price the executor proves, never a price the executor chooses.

Stops and take-profits fire on **opposite** sides of the market, because a stop exists to cap a
loss and a take-profit to realize a gain:

| Position | Order side | Stop fires when | Take-profit fires when |
|---|---|---|---|
| Long | sell (`isLong = false`) | price ≤ trigger | price ≥ trigger |
| Short | buy (`isLong = true`) | price ≥ trigger | price ≤ trigger |

Both comparisons are inclusive at the trigger. On firing, a StopLoss or TakeProfit executes
**market-style** — it takes whatever the book offers within oracle ± `maxSlippageBp` and cancels any
unfilled remainder, so it never lingers as resting liquidity. A StopLimit instead *becomes* a limit
order: it matches what crosses and rests the remainder in the book at its limit price.

A profit target that must fill at an exact price is a plain `Limit` order — that is the
limit-priced counterpart to `TakeProfit`, and unlike a TakeProfit it provides depth to the book
while it waits.

## Creation rules

- Minimum order notional **$5**, with one exemption: a full-close of your position is always
  allowed — at creation and again when a partial fill leaves a full-close remainder. A TP/SL is
  measured on its capped size (what it could actually close), so an oversized one counts as a
  full close rather than as its written notional.
- Initial-margin check at creation covers **worst-case exposure**: your position plus all resting
  orders in whichever direction is worse — including the flip case. The requirement is the same
  under a stale oracle — gap risk lives in non-24/7 markets' always-on margin, not in a
  stale-mode rate.
- A `Limit` order's resting price must sit within **±50%** of the mark at creation
  (`MAX_PLACEMENT_DEVIATION_BP`). The band is deliberately wide: resting deep to catch a reopen gap
  is a legitimate strategy the margin system is built for, so it only rejects prices that can be
  nothing but an input error — or an attempt to satisfy the notional minimum at a price the market
  will never see. `StopLimit` is exempt, because its limit anchors to its trigger rather than to the
  mark, and wrong-side configurations are rejected on their own terms.
- Anti-DoS caps: ≤ **32** active Limit+StopLimit orders per user, 1 TakeProfit + 1 StopLoss per
  position. These bound the exposure-tally iteration cost and each user's worst-case book
  footprint. The order cap matches the matching walk's node budget, so the protocol's two bounded
  per-transaction iterations share one ceiling; 16 price levels a side is well beyond what an
  on-chain maker quotes, since every level costs a transaction here.
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
  the trigger tip, and a TP/SL whose position went flat or flipped side (an oversized one is
  capped, not canceled). Every auto-cancel unlinks in the same transaction. A `FOK` order is the
  exception that never reaches an auto-cancel: the same situations revert its transaction instead,
  so there is no order left to unlink.

## Order lifecycle

```
createOrder ──► matched on arrival ──┬─► filled          (full or partial fills, same tx or later)
                                     ├─► resting         (GTC remainder in the book; stops outside it)
                                     ├─► canceled        (user, auto-cancel, sweep)
                                     └─► expired         (block-stamped lifetime passes)
```

`filledBlock` / `canceledBlock` stamps plus the `inBook` flag make every order's terminal state
and book membership readable on-chain at any time.
