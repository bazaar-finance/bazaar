# Markets & Listing

Anyone can list a market. The factory gates listings through an UMA Optimistic Oracle assertion instead of a governance vote or admin whitelist.

## Flow

```
proposePairDeployment(baseFeedId, isContinuouslyTraded, totalAmount, description)
        │  pulls totalAmount USDC (≥ $4,000)
        │  ├─ $1,000 → UMA assertion bond (refunded to proposer on success)
        │  └─ ≥ $3,000 → escrowed insurance-fund seed
        ▼
   48-hour UMA liveness window (anyone can dispute)
        ▼
assertionResolvedCallback / settleDeploymentProposal
        ├─ truthful → EIP-1167 clone deployed, seeded, registered with
        │             sequencer + terminator; pairId = baseFeedId
        └─ disputed-and-false → bond lost to disputer, seed refunded
```

## What UMA verifiers check

The assertion text embeds seven objective criteria:

1. **Feed validity** — `baseFeedId` exists in Pyth's registry and matches the description.
2. **Trading-schedule flag** — `isContinuouslyTraded = true` only for genuinely 24/7 assets (crypto). Stocks, FX, and anything with market hours must be `false` (they get a 1.5× margin multiplier and the stale-oracle regime). Composites must be `false`.
3. **Eligible asset** — an actual tradeable asset or broad market index, USD-denominated.
4. **Composite quote leg** — non-USD quotes only through approved fiat legs (EUR, GBP, JPY, CHF, CAD, AUD, NZD, SEK, NOK, DKK, SGD, HKD, CNH).
5. **Linear, non-expiring spot exposure** — the test is: *could someone hold this asset indefinitely and experience exactly its price change?* Futures, options, bonds, leveraged/inverse products, volatility indices, rate products, pegged/rebased assets, and prediction markets are excluded.
6. **No 1:1 duplicates** — no wrapped BTC next to BTC, no S&P 500 ETF next to the index (propose the index itself), unless the underlying has no Pyth feed.
7. **Non-USD assets only as composites.**

A market whose pair was previously [terminated](termination.md) can be re-proposed.

## Non-USD assets: composite feeds

Assets quoted in another currency (e.g. DAX in EUR) trade against a **composite feed**: `price = base × quote` or `base ÷ quote` depending on the FX feed's direction. Composites are registered permissionlessly and idempotently in `BazaarOracle` (`registerComposite(baseId, quoteId, invertQuote)`); the composite ID — `keccak256(baseId ‖ quoteId ‖ invertQuote)` — is then used anywhere a feed ID is expected. A composite is only as fresh as its stalest leg, and both legs are confidence-checked.

## The only governance: swapping the UMA oracle

`proposeUmaOracleUpgrade(newOracle, newIdentifier)` — a $5,000 bond and a **14-day** liveness window (deliberately stricter than listings: this pointer adjudicates every future listing and termination). One pending upgrade at a time. In-flight assertions resolve against the oracle recorded when they were proposed, so an upgrade cannot strand them.

Approval does not swap the pointer — it queues the upgrade behind a further **14-day** activation timelock (`ORACLE_UPGRADE_TIMELOCK`). Until anyone calls `activateOracleUpgrade()` after the timelock, the incoming oracle has zero authority, so traders who distrust it have a guaranteed exit window (insurance-LP withdrawals remain subject to their 20-day cooldown, which outlasts the timelock). Candidates are conformance-probed — code present, basic OOv3 views answer — at proposal and again at activation; a probe failure at activation *cancels* the upgrade and keeps the incumbent, so a dud candidate can never brick governance.
