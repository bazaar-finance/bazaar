# Arrival Matching

Bazaar keeps its limit order book **on-chain and sorted**: two doubly-linked lists per pair,
threaded through the orders themselves (`prevInBook`/`nextInBook`), with the heads in one storage
slot. Bids sort by `limitPrice` DESC, asks ASC, ties by `prioritySeq` ASC — an order at an occupied
price queues behind the orders already there, so price-time priority is a structural invariant,
not a promise. `prioritySeq` is the order's id until the order joins its level late — an
[amendment](orders.md#amending) sends it to the back, or a keeper arms a StopLimit, which enters the
book only then — when it takes a fresh value from the same counter.

Matching happens **on arrival**, inside `createOrder` itself: the incoming order walks the
opposing list from its head while it crosses, fills at each resting maker's limit price, and then
either rests its remainder in the book or cancels it. There is no separate match transaction and
no third party in the fill path — the taker pays for the liquidity it consumes.

## The walk

For each node, in order:

1. **Re-read the head from storage.** A settlement unlinks the maker it just consumed, and a
   margin failure auto-cancels one, so no pointer survives a settlement in memory.
2. **Stop if the best price no longer crosses** the taker's bound (its limit price, or
   oracle ± `maxSlippageBp` for Market, StopLoss and TakeProfit).
3. **Count the node** against the walk's step budget (`MatchHints.maxSteps`, clamped to
   `MAX_WALK_STEPS` = 32; 0 selects the default). The budget counts *nodes visited*, skips
   included, so expired dust cannot push a taker past their gas budget. Only a self-submitted
   `createOrder` sets its own budget: a relayed one and every `executeTriggeredOrders` execution run
   the default.
4. **Expired maker** → canceled and unlinked on contact; walk continues.
5. **Band, post-only, self-match.** Under the stale fallback the maker must sit inside the price
   band (see [Stale oracle](#stale-oracle)); then a post-only taker, or a maker owned by the
   taker's own account, stops the walk (see the table below).
6. **Fill** `min(taker remaining, maker remaining)` at the **maker's** limit price. Both sides pass the margin
   gate at the transaction's oracle price; a failing maker is auto-canceled (walk retries the next
   head), a failing taker has its remainder canceled (a fired trigger order stays live instead).
   Fees, PnL, and funding settle per fill through the same bucket machinery as every other close.

## Remainder disposition

| Case | Outcome |
|---|---|
| GTC limit / armed StopLimit, no longer crossing | rests in the book (positioned by insertion hints); a StopLimit fired with less than the 240-block minimum lifetime left stays live outside the book instead |
| Market or IOC | canceled |
| StopLoss/TakeProfit execution | stays live outside the book; the next execution re-evaluates the trigger and prices a fresh bound |
| any incomplete outcome for a FOK taker | **transaction reverts** — the walk's settled fills unwind with it |
| post-only that crossed a live maker | canceled before any fill |
| self-match (maker is the taker's own order) | incoming remainder canceled (a fired trigger order stays live outside the book); the resting order stays |
| step budget hit while still crossing | canceled — the book must never rest crossed; a trigger order instead keeps its fills and stays live for the next execution |
| remainder notional < $5 | canceled, unless it is an exact full-close of the creator's position |

Every cancellation writes its terminal stamp (`canceledBlock`; a complete fill writes
`filledBlock`) and unlinks the order from the book atomically, so a canceled order is out of every
walk's reach within its own transaction. A fired trigger order is the one taker that can leave its
walk neither resting nor terminal: the node budget, its owner's own resting order at the head, or
a fill its margin could not carry — and, for a StopLoss or TakeProfit, simply running out of
crossing liquidity — leaves it live outside the book, with the fills it took standing, until its
next execution or its owner's cancel. Short of a complete fill, only a position that is gone ends
a TP/SL; a StopLimit that runs out of crossing liquidity rests what is left, or cancels it as dust
under the $5 rule above. A StopLimit fired with less than the 240-block minimum lifetime left
cannot rest, so what is left stays live outside the book like a TP/SL's (see
[Orders](orders.md#order-types)).

## Insertion hints

Resting a remainder needs a position in the sorted list. The caller supplies up to four
predecessor candidates (`MatchHints.pred..pred4`, computed off-chain from the live book); the
contract verifies each against the actual neighbors and, if all are stale, repairs by walking from
the first live candidate (or the head), capped at `MAX_WALK_STEPS` nodes. A wrong hint can only
*fail* placement — never mis-place an order: a typed revert on your own `createOrder` (resubmit
with fresh hints), and a silent per-order skip inside a keeper's `executeTriggeredOrders` batch, so
one stale hint never reverts another owner's stop. Hints ride
**outside** the EIP-712 payload, like `priceUpdate`: they are execution aids a relayer attaches at
submission time, not signed intent. (`amendOrders` is the exception: its hints are packed into the
signed words — see [Amending](orders.md#amending).)

## Per-fill checks

Each prospective fill re-checks the owner's margin at the transaction's oracle price, judging the
account as the fill would leave it: collateral less the fee, plus the PnL and funding the fill
realizes, less the unrealized loss of whatever position survives the fill. Unrealized gains are
never credited.

- A fill that **adds exposure** (an open, an add, the new side of a flip) must leave that margin at
  or above IMR on the resulting notional. Fresh exposure is margined at the oracle price, with a
  one-sided incipient-loss debit for the fill-vs-oracle gap. Creation reserves that debit and the
  maker fee for every order that leaves the account's worst-case notional (the position plus its
  resting orders in the worse direction, this order included) above the position's current
  notional, and for every order of a flat account (see [initial margin](margin.md)), so such a
  maker fails here only through what has changed since it rested — the oracle, the margin rate,
  accrued funding. Any other order, such as a reduction with nothing resting behind it, rests with
  no reserve at all, so whether its fill passes can depend on how much of it the taker takes.
- A fill that **reduces** a position must not leave bad debt, and must leave the remainder at or
  above IMR at the pair's current rate — or, failing that, with a margin-to-MMR ratio no lower
  than the account held before, whether the remainder ends above maintenance or under it.
  Closing at the oracle price keeps that ratio (fees aside), so an account below IMR, even one
  under maintenance, can still close through several makers as long as each fill's distance from
  the oracle stays within the account's own margin rate. Admitting any remainder that covers MMR
  instead would let a reduction sold at a deep discount to the owner's own second account carry
  the band between IMR and MMR out of a position that stays open, margin the withdrawal gates
  would have kept. A full close needs only to leave no bad debt, judged at its fill price:
  liquidation is the only path that may realize a loss beyond collateral.
- A failing fill **auto-cancels** the order (stamped `canceledBlock`, unlinked, `OrderUpdated`
  emitted with `cancelReason` `Margin`); a fired trigger order taking the fill stays live outside
  the book instead. A user who drifted insolvent since creation cannot haunt the book.

## Stale oracle

Session-bound pairs run on the stale fallback (`lastPairPrice`) whenever no fresh price is
available — outside trading hours, or when a call brings no update and the on-chain price has aged
out. While stale:

- Non-crossing arrivals **insert** normally — overnight gap positioning is the point of the
  always-on margin model.
- A crossing fills only against makers priced within ±10% (`MAX_STALE_DEVIATION_BP`) of the last
  stored price. The two violation directions get **opposite dispositions**:
  - **Far side** — the maker is priced beyond the band *away* from the taker. The taker is the one
    demanding out-of-band execution, so the **incoming order** is canceled and the maker stays
    (resting far from an aged reference is legitimate gap positioning). The list is price-sorted,
    so nothing deeper could have filled either.
  - **Near side** — the maker is priced beyond the band *toward* the taker. Here the **maker** is
    canceled and the walk retries the next head, exactly like an expired one. Cancelling takers
    instead would let a single such order at the head kill every arrival on that side for the whole
    closed session.

  Both checks run before the post-only test, so a post-only arrival is judged against the first
  maker it could actually fill with rather than against near-side garbage.
- Market orders and trigger execution revert — both are priced off the oracle, and a stale
  reference can neither bound a fill nor arm a stop. A trigger order created while stale waits
  unarmed for a fresh price. The vault's unload fills nothing and pays nothing until one arrives.

The book can therefore never rest crossed, in either regime, and reopen needs no special
uncrossing step.

## Triggered orders and the vault

Two flows have no arriving order to piggyback on:

- **Stops** — `executeTriggeredOrders` lets anyone fire triggered StopLimit/StopLoss/TakeProfit
  orders (up to 20 per call, `MAX_TRIGGER_EXECS_PER_CALL`) against a fresh Pyth price for the
  bounty the owner escrowed with the order. See
  [Orders](orders.md).
- **Liquidation inventory** — `liquidate()` crosses freshly seized inventory into the book
  inline (bounded), and the permissionless `unloadVault` finishes the job for a reward. Both fill
  only inside the unload bound — the liquidation band min(`LIQ_MAX_SLIPPAGE_BP` = 5%, MMR) around
  oracle, with MMR the lower of the current rate and its lagged minimum, plus, once the floor has
  opened to it over three minutes, the region out to the estates' fund-neutral price — and within
  the insurance fund's headroom above its reserve. See [Liquidations](liquidations.md).

## After the walk

A transaction's fills settle their aggregates once: open-interest totals, the fee-ledger debit and
the insurance, integrator and bug-bounty credits it funds, the vault's PnL on unload fills (through
insurance), the mark-price update (funding's anchor: the exposure-weighted VWAP of the fills against makers
resting on the far side of the oracle, each at no more premium than its maker entered the book at —
see [Funding](funding.md#mark-price)), the slippage and drift
EMAs (for unload fills), and a vault health re-check. Fees are the insurance fee (a flat maker rate, a dynamic taker rate) plus optional
integrator referral fees — see [Fees](fees.md).
