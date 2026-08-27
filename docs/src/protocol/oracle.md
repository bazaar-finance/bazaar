# Price Oracle

`BazaarOracle` is a **stateless Pyth adapter** shared by all pairs. It never stores prices — each pair caches its own last price — and it is entirely permissionless: anyone can push Pyth updates (paying Pyth's fee in ETH) or register composite feeds.

## Freshness

A supplied Pyth price must be at most **2 s** old (`MAX_PRICE_STALENESS`) on every price-resolving entry point — sequencer batches, liquidations, ADL, order creation, collateral withdrawal, insurance withdrawal — no matter who submits the transaction.

Each of those entry points accepts a `priceUpdate` byte array so callers can atomically refresh Pyth and act on the fresh price in one transaction. Two seconds is a bot's budget, not a human's: the update travels as calldata, so it is fixed at signing time, and wallet-confirmation latency alone normally exceeds the window. A caller who cannot submit that fast has two routes:

- **Send an empty `priceUpdate`** and let the call resolve against the pair's on-chain Pyth cache, which is checked against the same 2 s bound at execution time. On an actively matched pair the sequencer's own batches keep the cache inside it; on a quiet pair they do not, and the call reverts.
- **Sign a meta-transaction** and let a relayer submit it. `priceUpdate` is not part of any EIP-712 payload, so the relayer attaches a fresh price at submission time and a signature minted earlier still lands on it. See [Meta-transactions](meta-transactions.md).

## Confidence brackets

Pyth publishes a confidence interval alongside every price. Bazaar consumes it two ways:

- **Sanity gate** — any price with confidence > **2%** of spot is rejected outright (`MAX_CONFIDENCE_BP`). A band that wide means the publishers disagree enough that neither edge is a usable margin input, so the read fails rather than picking one.
- **Directional brackets** — reads return `(spot, low = spot − conf, high = spot + conf)`. Withdrawal checks value long exposure at `low` and short exposure at `high` — you cannot withdraw against the optimistic edge of the confidence band. Liquidations and ADL deliberately use plain spot: the 2% gate is the conservatism there, and bracket-pricing forced closures would systematically favor one side.

Non-positive prices revert unconditionally on every path — operating on a zero price would mass-liquidate an entire side.

## The stale-price regime (market hours)

Equities and FX stop ticking when their venues close, and a perp on them cannot simply halt — funding, margin, and liquidations still need a price. Pairs listed as *not continuously traded* keep operating on the last price under tightened rules:

- Fill prices are confined to ±10% of the last stored price (`MAX_STALE_DEVIATION_BP`); the maker of an out-of-band fill is skipped and witnessed (`staleSkippedIds`), not canceled.
- Market orders are rejected at creation, and Pass B (markets × limits) is skipped in batches.
- Margin carries **no stale surcharge**: closure-gap risk is priced into the pair's always-on IMR instead — the larger of 2× its vol curve and its own observed reopen gap (see [Margin](margin.md)) — so a fill needs the same IMR whether the batch is fresh or stale.
- **Position holders cannot withdraw collateral against the stale fallback.** Around a closure, off-chain venues (pre-market, 24/7 books) print the reopen hours before the oracle can, so releasing equity at the frozen mark would let a holder who is already dead at the real price withdraw down to an IMR computed at the stale one — converting their loss into vault deficit that a termination passes to the winning side. No margin *rate* closes that channel (a rate can't price information the oracle hasn't seen); withholding release does. While stale, the vault accepts deposits but releases no position-holder equity; flat and order-only accounts are unaffected, and withdrawals resume with the first fresh print.

Every reopen also teaches the margin curve: the first stored price after a ≥ 1 h gap — a closure, a trading halt, or a market break — is compared against the last price before it, and the |return| feeds the reopen-gap floor.

When no fresh price is available, reads fall down a **confidence ladder**: any-age spot if its confidence still qualifies → Pyth's EMA price if *its* confidence qualifies → the pair's last stored price. Each rung is gated, so garbage never silently becomes the settlement price.

## Composite feeds

Non-USD-quoted assets multiply or divide through an FX leg (`registerComposite(baseId, quoteId, invertQuote)`, permissionless, idempotent; legs must be raw Pyth feeds — composites cannot nest). Bracket math pairs each leg's bound with the direction that moves the composite the same way, publish time is the *older* of the two legs, and both legs are confidence-checked — plus the *composed* bracket must itself sit within the 2% cap, because relative widths add under multiplication (1.8% + 0.15% passes; 1.2% + 1.2% fails). USDC itself is hardcoded to $1 — collateral is not oracle-priced.

## Historical proofs

`fetchHistoricalPrice(feedId, priceUpdate, minPublishTime, maxPublishTime)` parses a Pyth update bounded to a publish-time window. It exists for adjudication: [stale-flag challenges](sequencers.md) prove a fresh tick existed, and [scheduled terminations](termination.md) settle at a tick from the 2 s window ending at the cessation timestamp.
