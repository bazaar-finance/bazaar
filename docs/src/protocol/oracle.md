# Price Oracle

`BazaarOracle` is a **stateless Pyth adapter** shared by all pairs. It never stores prices — each pair caches its own last price — and it is entirely permissionless: anyone can push Pyth updates (paying Pyth's fee in ETH) or register composite feeds.

## Freshness

A supplied Pyth price must be at most **2 s** old (`MAX_PRICE_STALENESS`) on every price-resolving entry point — order creation (and the arrival matching inside it), trigger execution, liquidations, vault unloading, ADL, collateral withdrawal, insurance withdrawal, and insurance deposit while the vault holds inventory — no matter who submits the transaction.

Each of those entry points accepts a `priceUpdate` byte array so callers can atomically refresh Pyth and act on the fresh price in one transaction. Two seconds is a bot's budget, not a human's: the update travels as calldata, so it is fixed at signing time, and wallet-confirmation latency alone normally exceeds the window. A caller who cannot submit that fast has two routes:

- **Send an empty `priceUpdate`** and let the call resolve against the pair's on-chain Pyth cache, which is checked against the same 2 s bound at execution time. On an actively traded pair the arrival flow itself keeps the cache warm, and the [refresh bounty](../guide/earning.md#keeper-bounties) pays keepers $0.25 to push updates to quiet pairs that still carry meaningful insurance and open interest; on a pair no one is refreshing the cache falls outside the bound and the call reverts.
- **Sign a meta-transaction** and let a relayer submit it. `priceUpdate` is not part of any EIP-712 payload, so the relayer attaches a fresh price at submission time and a signature minted earlier still lands on it. See [Meta-transactions](meta-transactions.md).

## Confidence brackets

Pyth publishes a confidence interval alongside every price. Bazaar consumes it two ways:

- **Sanity gate** — any price with confidence > **2%** of spot is rejected outright (`MAX_CONFIDENCE_BP`). A band that wide means the publishers disagree enough that neither edge is a usable margin input, so the read fails rather than picking one.
- **Directional brackets** — reads return `(spot, low = spot − conf, high = spot + conf)`. Withdrawal checks value long exposure at `low` and short exposure at `high` — you cannot withdraw against the optimistic edge of the confidence band. Liquidations and ADL deliberately use plain spot: the 2% gate is the conservatism there, and bracket-pricing forced closures would systematically favor one side.

Non-positive prices revert unconditionally on every path — operating on a zero price would mass-liquidate an entire side.

## The stale-price regime (market hours)

Equities and FX stop ticking when their venues close, and a perp on them cannot simply halt — funding, margin, and liquidations still need a price. Pairs listed as *not continuously traded* keep operating on the last price under tightened rules:

- Fill prices are confined to ±10% of the last stored price (`MAX_STALE_DEVIATION_BP`). Which side of the band is violated decides who dies: an arrival that would cross a maker priced out of band *away* from it is canceled and the maker stays (deep resting is legitimate gap positioning), while a maker priced out of band *toward* the arrival is itself canceled and the walk continues — otherwise one such order at the head would blockade that side for the whole closure. Non-crossing arrivals insert normally, and the book never rests crossed. See [Matching](matching.md#stale-oracle).
- Market orders are rejected at creation and trigger execution reverts — both are priced off the oracle.
- **Liquidation stops trusting the fallback after 10 minutes.** Seizure takes a whole bucket, so a mark that old may no longer confiscate collateral (`MAX_LIQUIDATION_PRICE_AGE`); a keeper carrying a fresh `priceUpdate` liquidates regardless. See [Liquidations](liquidations.md).
- Margin carries **no stale surcharge**: closure-gap risk is priced into the pair's always-on IMR instead — **twice the larger** of its vol curve and its own observed reopen gap (see [the stress move](margin.md#the-stress-move)) — so a fill needs the same IMR whether the oracle is fresh or stale.
- **Position holders cannot withdraw collateral against the stale fallback.** Around a closure, off-chain venues (pre-market, 24/7 books) print the reopen hours before the oracle can, so releasing equity at the frozen mark would let a holder who is already dead at the real price withdraw down to an IMR computed at the stale one — converting their loss into vault deficit that a termination passes to the winning side. No margin *rate* closes that channel (a rate can't price information the oracle hasn't seen); withholding release does. While stale, the vault accepts deposits but releases no position-holder equity; flat and order-only accounts are unaffected, and withdrawals resume with the first fresh print.
- **Insurance shares cannot be priced against the stale fallback either.** The fund is sized to absorb the reopen gap (the learned gap reaches its target at full size), so a redemption judged at the frozen mark would let an LP leave ahead of exactly the loss the fund exists to take. Deposits meet the same refusal, but only while the vault holds liquidated inventory — the one case where a deposit has to value something the frozen mark cannot see. Whichever way that inventory moved across the closure, pricing it at the frozen mark hands the difference to whoever can already see the reopen, and there is no conservative figure to charge a depositor instead, because a reopen can print anywhere. With the vault flat a deposit reads no price at all and stays open, so recapitalizing a drained fund is never blocked by market hours. Both resume with the first fresh print, and a pair whose feed has died releases its LPs once the stale-oracle termination settles it.
- **[ADL](adl.md) refuses the fallback outright**, as does the timeout that would terminate a stuck auction. Ranking and settlement are already immune — both run off frozen values — but the health gate, the batch sizing and the executor reward all read the live mark, and the last of those is steerable through it alone. Blocking both together is what makes it safe to wait: neither can act on a closed venue, so the auction cannot be terminated out from under itself. They resume together at the reopen, where the first stored price gives the auction a 30-minute head start before termination becomes callable.

Every reopen also teaches the pair's risk curve: the first stored price after a ≥ 1 h gap — a closure, a trading halt, or a market break — is compared against the last price before it, and the |return| feeds the reopen-gap peak-hold, which raises margin and the insurance target together.

When no fresh price is available, reads fall down a **confidence ladder**: any-age spot if its confidence still qualifies → Pyth's EMA price if *its* confidence qualifies → the pair's last stored price. Each rung is gated, so garbage never silently becomes the settlement price.

## Composite feeds

Non-USD-quoted assets multiply or divide through an FX leg (`registerComposite(baseId, quoteId, invertQuote)`, permissionless, idempotent; legs must be raw Pyth feeds — composites cannot nest). Bracket math pairs each leg's bound with the direction that moves the composite the same way, publish time is the *older* of the two legs, and both legs are confidence-checked — plus the *composed* bracket must itself sit within the 2% cap, because relative widths add under multiplication (1.8% + 0.15% passes; 1.2% + 1.2% fails). USDC itself is hardcoded to $1 — collateral is not oracle-priced.

## Historical proofs

`fetchHistoricalPrice(feedId, priceUpdate, minPublishTime, maxPublishTime)` parses a Pyth update bounded to a publish-time window. It exists for adjudication: [scheduled terminations](termination.md) settle at a tick from the 2 s window ending at the scheduled cutoff.
