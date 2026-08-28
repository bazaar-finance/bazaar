# Arrival Matching

Bazaar keeps its limit order book **on-chain and sorted**: two doubly-linked lists per pair,
threaded through the orders themselves (`prevInBook`/`nextInBook`), with the heads in one storage
slot. Bids sort by `limitPrice` DESC, asks ASC, ties by `orderId` ASC — an order at an occupied
price queues behind the orders already there, so price-time priority is a structural invariant,
not a promise.

Matching happens **on arrival**, inside `createOrder` itself: the incoming order walks the
opposing list from its head while it crosses, fills at each resting maker's limit price, and then
either rests its remainder in the book or cancels it. There is no separate match transaction and
no third party in the fill path — the taker pays for the liquidity it consumes.

## The walk

For each node, in order:

1. **Re-read the head from storage.** A fill can cancel resting TP/SL orders anywhere in the book
   (the oversize fence), so no pointer survives a settlement in memory.
2. **Stop if the best price no longer crosses** the taker's bound (its limit price, or
   oracle ± `maxSlippageBp` for Market/StopLoss).
3. **Count the node** against the walk's step budget (`MatchHints.maxSteps`, clamped to
   `MAX_WALK_STEPS` = 64; 0 selects the default). The budget counts *nodes visited*, skips
   included, so expired dust cannot push a taker past their gas budget.
4. **Expired maker** → canceled and unlinked on contact; walk continues.
5. **Fill** `min(remaining, remaining)` at the **maker's** limit price. Both sides pass the margin
   gate at the transaction's oracle price; a failing maker is auto-canceled (walk retries the next
   head), a failing taker has its remainder canceled. Fees, PnL, and funding settle per fill
   through the same bucket machinery as every other close.

## Remainder disposition

| Case | Outcome |
|---|---|
| GTC limit / TakeProfit, no longer crossing | rests in the book (positioned by insertion hints) |
| Market, StopLoss execution, or IOC | canceled |
| post-only that crossed a live maker | canceled before any fill |
| self-match (maker is the taker's own order) | incoming remainder canceled; the resting order stays |
| step budget hit while still crossing | canceled — the book must never rest crossed |
| remainder notional < $5 | canceled, unless it is an exact full-close of the creator's position |

Every one of these writes a terminal state (`filledBlock` or `canceledBlock`) and unlinks the
order from the book atomically, so a canceled order is out of every walk's reach within its own
transaction.

## Insertion hints

Resting a remainder needs a position in the sorted list. The caller supplies up to four
predecessor candidates (`MatchHints.pred..pred4`, computed off-chain from the live book); the
contract verifies each against the actual neighbors and, if all are stale, repairs by walking from
the first live candidate (or the head), capped at `MAX_WALK_STEPS` nodes. A wrong hint can only
*fail* placement (typed revert, resubmit with fresh hints) — never mis-place an order. Hints ride
**outside** the EIP-712 payload, like `priceUpdate`: they are execution aids a relayer attaches at
submission time, not signed intent.

## Per-fill checks

Each prospective fill re-checks the owner's margin at the transaction's oracle price:

- **Fails IMR** → the order is **auto-canceled** (stamped `canceledBlock`, unlinked, event
  emitted). A user who drifted insolvent since creation cannot haunt the book.
- Fresh exposure is margined at the oracle price with a one-sided incipient-loss debit for the
  fill-vs-oracle gap; closing portions realize PnL and funding up front and reject on bad debt
  (liquidation is the only path that may realize a loss beyond collateral).

## Stale oracle

Session-bound pairs run on the stale fallback (`lastPairPrice`) outside trading hours. While
stale:

- Non-crossing arrivals **insert** normally — overnight gap positioning is the point of the
  always-on margin model.
- A crossing fills only against makers priced within ±10% (`MAX_STALE_DEVIATION_BP`) of the last
  stored price. An arrival that would cross an **out-of-band** maker is canceled outright (the
  maker stays; the list is price-sorted, so nothing deeper could fill either).
- Market orders and trigger execution revert — both are priced off the oracle, and a stale
  reference can neither bound a fill nor arm a stop.

The book can therefore never rest crossed, in either regime, and reopen needs no special
uncrossing step.

## Triggered orders and the vault

Two flows have no arriving order to piggyback on:

- **Stops** — `executeTriggeredOrders` lets anyone fire triggered StopLimit/StopLoss orders
  against a fresh Pyth price for a flat tip charged to the stop's owner. See
  [Orders](orders.md).
- **Liquidation inventory** — `liquidate()` crosses freshly seized inventory into the book
  inline (bounded), and the permissionless `unloadVault` finishes the job for a reward. Both use
  the liquidation price band min(`LIQ_MAX_SLIPPAGE_BP` = 5%, current MMR) around oracle. See
  [Liquidations](liquidations.md).

## After the walk

A transaction's fills settle their aggregates once: open-interest totals, the fee-ledger debit,
the mark-price VWAP (funding's anchor), the liquidation-gap EMA (for unload fills), and a vault
health re-check. Fees are the insurance system's dynamic rates plus optional integrator referral
fees — see [Fees](fees.md).
