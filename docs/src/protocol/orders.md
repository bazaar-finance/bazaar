# Orders

Orders live in the pair's `orders` mapping and are matched **on arrival** ([Matching](matching.md)):
creating an order and trading are the same transaction. Every user has **one net position per
market** (a *position bucket*); orders modify it.

## Order types

| Type | Priced by | Trigger | Notes |
|---|---|---|---|
| `Market` | book prices, bounded by oracle ± `maxSlippageBp` | — | slippage cap 10%; fills immediately, remainder cancels — never rests; rejected while the oracle is stale |
| `Limit` | `limitPrice` | — | the only type that takes `isPostOnly`, and the only one that rests without a trigger (`tif: GTC`) |
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
later shrinks — through a partial close or a partial deleverage — leaves the order armed for what
remains rather than cancelling it. Only a position that goes flat or flips side cancels a TP/SL,
because neither can reduce anything then.

Size `0` is rejected for every order type, TP/SL included: with `max` available as the
close-everything idiom, zero carries no meaning.

Capping bounds the close; it does not consume the order. A book too thin to absorb the resolved
size fills what it can, and the order stays live outside the book for the part it could not
close: the next execution re-evaluates the trigger against the price it carries and prices a
fresh bound, so a target is never lost to a thin moment.

**Trigger orders.** StopLimit, StopLoss and TakeProfit all wait *outside* the book until an oracle
price reaches their trigger. If a fresh price already satisfies the trigger at creation, the order
arms immediately in the same transaction; otherwise anyone may fire it later through
`executeTriggeredOrders` with a fresh Pyth price. Triggers are evaluated against the oracle price
the executor proves, never a price the executor chooses.

**Keeper bounty.** Every trigger order carries a bounty of the owner's choosing, packed into the
high 128 bits of `triggerPrice` (`(bounty << 128) | price`, in 18-decimal precision and a multiple
of 1e12 — a whole number of USDC's 6-decimal units — and therefore inside the EIP-712 signature;
every other type must leave those bits zero). It is pulled from the owner's *wallet* when the order is
created and held in the pair's fee escrow against the order; collateral is never charged, so a
stop on a thin account pays its executor like any other, and no margin gate stands between an
owner and a protective order. Each execution earns the executor the share of the bounty that it
filled, in proportion to what remained of the order when it fired; the whole remainder pays out
when the order completes or, for a StopLimit, rests. An execution by the creation itself (a fresh
price that already meets the trigger arms the order on arrival) pays that share to the owner's
claimable balance instead, and so does an `executeTriggeredOrders` execution in the same block on
an order whose creation ran on the stale fallback: leaving such an order unarmed and firing it in
the same block is the submitter's doing, not a keeper's service. Any other execution pays its
caller, including one in the creation transaction that fires on a later print than the creation
read. A bounty of zero is allowed: it means the owner intends to fire the order themselves. What an order
still holds when it is canceled, expires, or dies to an auto-cancel returns to the owner's
claimable balance — immediately on an owner cancel or an auto-cancel inside the order's own
execution, otherwise through `cancelOrders` on the dead order or the permissionless
`sweepExpired` — and is withdrawn with `claimFees` like any other
balance. A StopLimit whose resting slot the executor's hints cannot reach is skipped untouched —
no bounty, no fill — for a later executor with fresh hints, so one stale hint never fails another
owner's stop.

Stops and take-profits fire on **opposite** sides of the market, because a stop exists to cap a
loss and a take-profit to realize a gain:

| Position | Order side | Stop fires when | Take-profit fires when |
|---|---|---|---|
| Long | sell (`isLong = false`) | price ≤ trigger | price ≥ trigger |
| Short | buy (`isLong = true`) | price ≥ trigger | price ≤ trigger |

Both comparisons are inclusive at the trigger. On firing, a StopLoss or TakeProfit executes
**market-style** — it takes whatever the book offers within oracle ± `maxSlippageBp`. It never
rests as book liquidity: an unfilled remainder stays live outside the book and fires again on the
next execution, with a bound priced off that execution's oracle. A StopLimit instead *becomes* a
limit order: it matches what crosses and rests the remainder in the book at its limit price. It
queues by when it rests, not when it was created: a StopLimit a keeper arms takes the next value
from the id counter as its `prioritySeq`, behind every order already at its limit price, and its
`Triggered` event carries that value (one that arms in its own creation transaction already holds
the newest position, its id). A
trigger order that runs out of walk budget while still crossing keeps its fills and stays live
the same way, so resting orders planted in front of the real liquidity cannot end it. A StopLimit
that fires with less than the minimum lifetime (240 blocks) left before its expiry does not rest
either, because every order in the book stands open to fills for at least that long before it can
expire. It matches what crosses and the remainder stays live outside the book (a sub-$5 remainder
is still canceled as dust), so a later execution can fill it until it expires. Firing it when
nothing crosses therefore leaves it as it was rather than ending it. A StopLimit created with close to the minimum lifetime may never rest unless it
fires on arrival; give it a longer expiry if it should rest when it fires.

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
- A `Limit` order's limit price must sit within **±50%** of the oracle price at creation or
  amendment (`MAX_PLACEMENT_DEVIATION_BP`). The band is deliberately wide: resting deep to catch a reopen gap
  is a legitimate strategy the margin system is built for, so it only rejects prices that can be
  nothing but an input error — or an attempt to satisfy the notional minimum at a price the market
  will never see. `StopLimit` is exempt, because its limit anchors to its trigger rather than to the
  oracle price, and wrong-side configurations are rejected on their own terms.
- Anti-DoS caps: ≤ **32** active Limit+StopLimit orders per user, 1 TakeProfit + 1 StopLoss per
  position. These bound the exposure-tally iteration cost and each user's worst-case book
  footprint. The order cap matches the matching walk's node budget, so the protocol's two bounded
  per-transaction iterations share one ceiling; 16 price levels a side is well beyond what an
  on-chain maker quotes, since every level costs a transaction here. `IOC` and `FOK` limits never
  rest, so they take no slot: a user at the cap can still send one.
- Lifetimes are stamped in Arbitrum L2 blocks: minimum ~1 min (240 blocks), maximum ~1 year (a
  longer expiry is clamped to it); TP/SL never expire; Market, `IOC` and `FOK` orders are terminal
  within their own transaction and ignore the expiry field. The minimum holds for every entry into
  the book, not only creation: an [amendment](#amending) that moves an order needs that much life
  left, and a StopLimit that fires with less does not rest.
- Every order can carry an `integrator` address that earns a [referral fee](fees.md) on fills.

## Amending

`amendOrders(amends[], …)` rewrites resting limit orders in place. `amends` is a flat
array of word triples — for each amendment an id word (the order id in its low 64 bits, with up to
two optional insertion hints packed above it), the new price and the new total size — so one
amendment names one of the caller's orders and the price and size it should carry afterwards; the order keeps its id, its
expiry, its integrator and its place in the owner's order set, and nothing about the position or the
vault moves. Up to `MAX_AMENDS_PER_CALL` (32, the per-user order cap) per call, all or nothing: any
amendment that fails reverts the whole batch.

- **Queue position.** A new price, or a larger size at the same price, is a new claim on a level: the
  order goes to the back, behind every order already resting there. A smaller size at the same price
  keeps its place, since it takes nothing from anyone behind it. The place is carried by `prioritySeq`,
  which equals the order's id until an amendment moves it and then takes the next value from the id
  counter — so ids have gaps where amendments (and keeper-armed StopLimits, see
  [trigger orders](#order-types)) drew values, and no two resting orders can ever tie. When the new
  price and queue position still sort between the order's current neighbours — a requote by less
  than the gap to the next order on its side — the order is rewritten where it stands and the
  book's links are not touched: a side is strictly sorted with no ties, so the slot is unique and
  a relink would rebuild exactly the links that are there. Only a move that changes the order's
  neighbours relinks it, and a move onto a price another order already rests at always does,
  since the order queues behind it.
- **Exposure.** The same split applies to the order's two exposure stamps — the block it entered the
  book at its current price and size, and how far on the far side of the index it stood then — which
  decide how much of a fill against it enters the [mark price](funding.md#mark-price) and at what
  premium: a reprice or a larger size restarts both, measuring the premium against the amendment's
  index (or stamping zero on the stale fallback); a smaller size keeps both, since what remains has
  stood there all along.
- **Minimum lifetime.** An amendment that moves the order (a new price, or a larger size) needs at
  least the 240 blocks (~1 min) of life left that a new order is created with, and is refused
  otherwise (`AmendTooCloseToExpiry`). Without it, an order resting deep in the book could move to
  the front in its last block and, one block later, sit at the head as an expired order that the
  next taker's walk spends a step removing: a wall of them would use up the walk's budget before it
  reached the real liquidity. A smaller size at the same price stays allowed until the order
  expires. Amending never changes the expiry, so an order close to it is requoted by cancelling it
  and placing a new one.
- **Never a taker.** A price at or through the best resting order on the other side is refused
  (`AmendWouldCross`): the order would have to walk the book, pay taker fees and pass the fill gates,
  which is what a new order does. Send a taker order instead. The same check keeps a post-only order
  post-only and rules out a self-match, the caller's own opposite-side orders included.
- **Same rules as creation.** The new price must sit inside the ±50% placement band, the remainder
  (new size less what has filled) must clear the $5 notional floor with the usual full-close exemption,
  and the new size must exceed the filled size — at or below it the order would be complete, which is
  a cancel. Only resting good-till-cancelled `Limit` orders qualify: stops wait outside the book with
  a bounty and position links of their own, and IOC/FOK orders never rest.
- **Margin once, on the result.** After the batch the owner's orders are reserved exactly as a new
  order is reserved (see [initial margin](margin.md)): a bid at the oracle price, an ask at the larger of its limit and the
  oracle price (a StopLimit still waiting for its trigger at the largest of its trigger, its limit
  and the oracle price), with the fill gate's debit on top — the maker fee, and the loss a limit on the wrong
  side of the oracle price books when it fills; the position plus that exposure has to clear initial margin together
  with that debit and the position's unrealized loss. Shrinking only ever lowers the
  requirement, but the gate judges the whole set left after the batch, so a set that a later price
  move or margin-rate rise has left short of it must still come back under it: a shrink that leaves
  it short reverts (`cancelOrders` has no margin gate), and repricing an order onto the wrong side of the oracle price costs
  the loss it would then book. The gate does not read every resting order to reach that verdict:
  it first takes an upper bound on the set's reservation from a running per-account tally (see
  [initial margin](margin.md#the-resting-order-tally)), and reads the orders one by one, pruning
  expired ones as it goes, only when the bound does not clear the owner.
- **Why it is cheaper.** Every write lands in slots already in use, the owner's tally included, and the fixed cost of
  a call — the price, the margin curve, the signature — is paid once for the batch. No fill can
  happen, so no health check runs.
- **Hints.** Insertion hints are optional and ride inside the id word: bits 64–127 and 128–191 each
  name an order to rest directly behind at the new price (`BazaarPairLens.findPredecessor` finds it,
  `amendIdWord` packs it), and the top 64 bits must be zero. They are consulted only when the move
  changes the order's neighbours; a move that keeps them is written in place and ignores them. The
  caller's hints lead the placement and the order's old neighbours follow as the fallback anchor,
  so a requote by a few ticks needs no hint while a jump across the book takes one. Every
  candidate is verified against the real
  neighbours before linking — a hint can fail a placement, never misplace an order — and when none
  brackets the slot, a repair walk of up to `MAX_WALK_STEPS` (32) nodes starts from the first live
  candidate; a slot further than that from it is refused (`OrderBookLib__HintRepairExhausted`),
  which is then a cancel and a new order. The hints are part of the signed words, so a relayer cannot refresh them; a hinted
  amendment that fails reverts whole without consuming the nonce.
- Each amendment that changes the order emits `OrderAmended` with the new price, the new total size
  (filled part included, as `OrderUpdated` reports it) and `prioritySeq`; everything else about the
  order is as its `OrderUpdated` (`Created`) left it, its fills aside, so an indexer can re-sort its
  book from events alone. A `prioritySeq` above the last one reported means
  the order was queued anew behind its price level; an unchanged one, that it shrank where it stood.

## Cancellation & cleanup

- `cancelOrders(orderIds[], …)` — creator-only, up to 200 per call. Canceling unlinks the order
  from the book in the same write, so no walk can ever fill it afterwards.
- Expired orders are removed by whoever touches them first: the matching walk cancels-and-unlinks
  an expired maker on contact, a withdrawal sweeps the owner's set, as do a creation that finds the
  set at its cap and an amendment whose margin gate has to read the set (see
  [the resting-order tally](margin.md#the-resting-order-tally)), and anyone may call the permissionless `sweepExpired(orderIds[])` janitor. Until then an expired order sits inert — still linked, but
  unable to fill.
- The matching engine **auto-cancels** orders in these situations: a fill that would fail the
  owner's margin check, a self-match (the incoming order cancels), a post-only order that would
  take instead of make, an IOC/Market/dust remainder, an order that ran out of walk budget while
  still crossing, a fill outside the stale-fallback price band (see
  [Matching](matching.md#stale-oracle)), and a TP/SL whose position went flat or flipped side (an
  oversized one is capped, not canceled). A fired trigger order is exempt from the margin,
  self-match and budget cases: each leaves it live outside the book for its next execution, since
  each is a book state a third party could arrange. A fired TP/SL's unfilled remainder stays live
  however small; a fired StopLimit's sub-$5 remainder that is not a full close is canceled like
  any other. Every auto-cancel unlinks in the same transaction. A `FOK` order is the exception that never reaches an auto-cancel: the
  same situations revert its transaction instead, so there is no order left to unlink. A trigger
  order canceled inside its own execution pays the executor for what it filled and returns the
  rest to the owner at once; one canceled by the fence, a liquidation or a deleverage keeps its
  bounty in escrow until `cancelOrders` or `sweepExpired` returns it.
- A StopLimit left live by an exhausted budget, or by firing with less than the minimum lifetime
  left, is re-evaluated like any pending trigger order:
  if the oracle has moved back across its trigger by the next execution, it waits again rather
  than resting at its limit.

## Order lifecycle

```
createOrder ──► matched on arrival ──┬─► filled          (full or partial fills, same tx or later)
                                     ├─► resting         (GTC remainder in the book; stops outside it)
                                     │      └─► amended  (new price/size in place, same id; back of the level unless shrinking)
                                     ├─► canceled        (user, auto-cancel, sweep)
                                     └─► expired         (block-stamped lifetime passes)
```

`filledBlock` / `canceledBlock` stamps plus the `inBook` flag make every order's terminal state
and book membership readable on-chain at any time.
