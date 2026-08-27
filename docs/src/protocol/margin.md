# Margin & Leverage

Margin requirements in Bazaar are **dynamic**: they respond to realized volatility, realized liquidation quality, and insurance-fund health, rather than being set per-market by governance.

## Initial margin (IMR)

Recomputed at most once per minute:

```
IMR = 3% base
      × volatility multiplier      (1× at ~14% annualized vol, through 3× at ~100%,
                                    same line continuing to a 6× cap at ~157%)
      × liquidation-gap multiplier (1× → 3× as realized gap EMA goes 0 → 3%)
      × insurance multiplier       (1× → 3× as the fund goes target → empty)
      non-continuous (stocks, FX): IMR = 2 × max(result above, reopen-gap EMA — see below)
clamped to [4%, 80%]               (25× down to 1.25× max leverage)
```

- **Volatility** is an EMA of annualized squared returns (τ = 5 days). Its multiplier is the only one allowed past 3×: the curve is linear in *variance*, which holds margin-per-daily-σ roughly constant as vol rises — capping it at 3× would price 100% and 230% vol identically — and it is the only *ex-ante* leg, so it must carry regimes the reactive legs (which price realized damage) haven't caught up to yet.
- **Liquidation gap** is a size-weighted, time-decayed EMA (τ = 3 days) of how far liquidation fills landed from bankruptcy prices — a market that liquidates badly gets more conservative automatically.
- **Insurance health** compares the fund to its [target ratio](insurance.md).

**Reopen-gap floor (non-continuous pairs only):** intraday variance says little about how far a stock jumps across a discontinuity, so the margin curve learns them directly. Whenever a stored price ends a gap of **≥ 1 h** — overnight and weekend closures, trading-halt reopens, lunch/maintenance breaks — the |return| across the gap feeds a **peak-hold** estimator: the held value decays harmonically (τ = 180 days), then takes the max with the new observation, capped at 40%. The threshold's job is only to exclude routine on-chain quiet periods, whose returns the volatility EMA already prices; the refresh bounty holds economically live pairs to a ~10-minute update cadence, so an hour without a stored price is a genuine market discontinuity, not keeper latency. The gap EMA composes with the volatility curve by max — the same reopen feeds both estimators, and max counts it once — and the *winning* leg is then doubled by the non-continuous prior: `IMR = 2 × max(vol curve, gap EMA)`. Doubling the winner puts the maintenance level (IMR/2) at the full demonstrated reopen and initial margin at twice it — a position at MMR survives an exact repeat of the worst observed gap. One severe earnings gap therefore lifts the pair's margin for months, while a mean-tracking EMA would average it away against dozens of quiet nights.

**Warmup:** a new market's IMR is floored at **20%** (5× leverage; 40% for non-continuously traded pairs, which have no reopen-gap history yet) until it is 5 days old *and* has seen 50,000 price updates. Thin, young books don't get 25× leverage.

IMR is what's checked at order creation and collateral withdrawal — always against **worst-case exposure**: current position plus resting orders in the worse direction, including the flip case. A stale oracle adds no surcharge — gap risk is already in the always-on IMR above — but it does gate *release*: a position holder's withdrawal requires a fresh price outright (see [the stale-price regime](oracle.md#the-stale-price-regime-market-hours)).

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
