# Price Oracle

`BazaarOracle` is a **stateless Pyth adapter** shared by all pairs. It never stores prices — each pair caches its own last price — and it is entirely permissionless: anyone can push Pyth updates (paying Pyth's fee in ETH) or register composite feeds.

## Freshness tiers

| Path | Staleness bound |
|---|---|
| Bots & meta-transactions (sequencer batches, liquidations, relayed user actions) | **2 s** (`MAX_PRICE_STALENESS`) |
| Direct user transactions | **10 s** (`MAX_PRICE_STALENESS_USER`) |

Every price-touching entry point accepts a `priceUpdate` byte array so callers can atomically refresh Pyth and act on the fresh price in one transaction.

## Confidence brackets

Pyth publishes a confidence interval alongside every price. Bazaar consumes it two ways:

- **Sanity gate** — any price with confidence > **2%** of spot is rejected outright (`MAX_CONFIDENCE_BP`). A band that wide means the publishers disagree enough that neither edge is a usable margin input, so the read fails rather than picking one.
- **Directional brackets** — reads return `(spot, low = spot − conf, high = spot + conf)`. Withdrawal checks value long exposure at `low` and short exposure at `high` — you cannot withdraw against the optimistic edge of the confidence band. Liquidations and ADL deliberately use plain spot: the 2% gate is the conservatism there, and bracket-pricing forced closures would systematically favor one side.

Non-positive prices revert unconditionally on every path — operating on a zero price would mass-liquidate an entire side.

## The stale-price regime (market hours)

Equities and FX stop ticking when their venues close, and a perp on them cannot simply halt — funding, margin, and liquidations still need a price. Pairs listed as *not continuously traded* keep operating on the last price under tightened rules:

- New fills require **2× initial margin** (`STALE_MARGIN_MULTIPLIER`).
- Fill prices are confined to ±10% of the last stored price (`MAX_STALE_DEVIATION_BP`).
- Market orders are rejected at creation, and Pass B (markets × limits) is skipped in batches.
- Orders that pass normal margin but fail the stale 2× check are skipped and witnessed (`staleSkippedIds`), not canceled.

When no fresh price is available, reads fall down a **confidence ladder**: any-age spot if its confidence still qualifies → Pyth's EMA price if *its* confidence qualifies → the pair's last stored price. Each rung is gated, so garbage never silently becomes the settlement price.

## Composite feeds

Non-USD-quoted assets multiply or divide through an FX leg (`registerComposite(baseId, quoteId, invertQuote)`, permissionless, idempotent; legs must be raw Pyth feeds — composites cannot nest). Bracket math pairs each leg's bound with the direction that moves the composite the same way, publish time is the *older* of the two legs, and both legs are confidence-checked — plus the *composed* bracket must itself sit within the 2% cap, because relative widths add under multiplication (1.8% + 0.15% passes; 1.2% + 1.2% fails). USDC itself is hardcoded to $1 — collateral is not oracle-priced.

## Historical proofs

`fetchHistoricalPrice(feedId, priceUpdate, minPublishTime, maxPublishTime)` parses a Pyth update bounded to a publish-time window. It exists for adjudication: [stale-flag challenges](sequencers.md) prove a fresh tick existed, and [scheduled terminations](termination.md) settle at a tick from the 2 s window ending at the cessation timestamp.
