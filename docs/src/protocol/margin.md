# Margin & Leverage

Margin requirements in Bazaar are **dynamic**: they respond to realized volatility, realized liquidation quality, and insurance-fund health, rather than being set per-market by governance.

## Initial margin (IMR)

Recomputed at most once per minute:

```
IMR = 3% base
      × volatility multiplier      (1× → 3× as annualized vol goes ~14% → ~100%)
      × liquidation-gap multiplier (1× → 3× as realized gap EMA goes 0 → 3%)
      × insurance multiplier       (1× → 3× as the fund goes target → empty)
      × 1.5 if not continuously traded (stocks, FX)
clamped to [4%, 80%]               (25× down to 1.25× max leverage)
```

- **Volatility** is an EMA of annualized squared returns (τ = 5 days).
- **Liquidation gap** is a size-weighted, time-decayed EMA (τ = 3 days) of how far liquidation fills landed from bankruptcy prices — a market that liquidates badly gets more conservative automatically.
- **Insurance health** compares the fund to its [target ratio](insurance.md).

**Warmup:** a new market's IMR is floored at **20%** (5× leverage; 30% for non-continuously traded pairs) until it is 5 days old *and* has seen 50,000 price updates. Thin, young books don't get 25× leverage.

IMR is what's checked at order creation and collateral withdrawal — always against **worst-case exposure**: current position plus resting orders in the worse direction, including the flip case. Under a stale oracle, requirements double.

## Maintenance margin (MMR) and the 24-hour grace

**MMR = IMR / 2, always.** A position is liquidatable when equity < MMR × notional (see [Liquidations](liquidations.md)).

Because IMR is dynamic, a volatility spike could raise MMR and instantly liquidate positions that were healthy a minute ago. Bazaar prevents this with a **lagged MMR**: the pair samples MMR hourly into a 25-slot ring buffer, and existing positions are judged against

```
effectiveMMR = min(reference, current)
reference    = the newest sample ≥ 24 h old   (if the position is ≥ 24 h old)
             = the position's entry MMR        (otherwise)
```

A *rising* requirement cannot liquidate you for 24 hours; a *falling* one helps you immediately. The grace re-anchors every time you increase risk (open, add, flip), and a closed position forfeits it entirely.

## Solvency math

All solvency questions go through one function — `BucketLib.calculateState`:

```
unrealizedPnl = ±(currentNotional − entryValue)
fundingPnl    = ∓(currentFundingIndex − entryFundingIndex) × size / 1e18
equity        = collateral + unrealizedPnl + fundingPnl
isSolvent     = max(0, equity) ≥ effectiveMMR × currentNotional  AND  equity > 0
```

Matching, withdrawals, liquidations, and ADL all call the same math with the same lagged-MMR inputs, so a position cannot be simultaneously "healthy" to one subsystem and "liquidatable" to another.
