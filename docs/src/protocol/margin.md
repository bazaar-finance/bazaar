# Margin & Leverage

Margin requirements in Bazaar are **dynamic**: they respond to realized volatility, realized liquidation quality, and insurance-fund health, rather than being set per-market by governance.

## The stress move

Every risk number on a pair comes off **one** reading: the *stress move* `M`, the price move that maintenance margin is set to survive. Margin is twice it and the [insurance target](insurance.md) is equal to it, so a market that turns risky raises both together and in proportion — rather than through two curves over the same estimators that drift apart at every clamp and slope.

```
V = 3% base × volatility multiplier   (1× at ~14% annualized vol, through 3× at ~100%,
                                       same line continuing to a 6× cap at ~157%)

continuous (crypto):         M = V / 2                     + liquidation-gap EMA
non-continuous (stocks, FX): M = max(V, reopen-gap EMA)     + liquidation-gap EMA
clamped to [2%, 40%]
```

- **Volatility** is an EMA of annualized squared returns (τ = 5 days). Its multiplier is the only leg allowed past 3×: the curve is linear in *variance*, which holds margin-per-daily-σ roughly constant as vol rises — capping it at 3× would price 100% and 230% vol identically — and it is the only *ex-ante* leg, so it must carry regimes the reactive legs (which price realized damage) haven't caught up to yet.
- **The asset-class split** is the closure prior. A 24/7 pair takes half the vol curve as its maintenance level; a session-bound pair takes the whole of it, because no keeper can interpose across a closure.
- **Liquidation gap** is a size-weighted, time-decayed EMA (τ = 3 days) of how far liquidation fills landed from bankruptcy prices. It **adds** rather than multiplies: a fill landing 3% past bankruptcy is 3% of realized shortfall, in the same units as the level itself, so it is exactly the amount by which maintenance margin proved too thin. The same bad fill therefore costs a calm market and a volatile one the same 3%, and the term self-cancels — once margin has grown by the gap and fills stop landing past bankruptcy, the EMA decays away. A negative EMA (fills better than bankruptcy) adds nothing; it is evidence the level holds, not licence to lower it.

## Initial margin (IMR)

Recomputed at most once per minute:

```
IMR = 2 × M × insurance multiplier   (1× → 3× as the fund goes target → empty)
clamped to [4%, 80%]                 (25× down to 1.25× max leverage)
```

**Insurance health** compares the fund to its [target ratio](insurance.md), and it is the one leg that is *not* part of the stress move. It reads the fund's current level rather than the market's risk, so it scales what traders are charged and never what the fund is sized to hold. Feeding it back into the target would close a loop with no stable resting point: a fund below target would raise the target, deepening its own measured shortfall.

**Reopen-gap leg (non-continuous pairs only):** intraday variance says little about how far a stock jumps across a discontinuity, so the stress move learns them directly. Whenever a stored price ends a gap of **≥ 1 h** — overnight and weekend closures, trading-halt reopens, lunch/maintenance breaks — the |return| across the gap feeds a **peak-hold** estimator: the held value decays harmonically (τ = 180 days), then takes the max with the new observation, capped at 40%. The threshold's job is only to exclude routine on-chain quiet periods, whose returns the volatility EMA already prices; the refresh bounty holds economically live pairs to a ~10-minute update cadence, so an hour without a stored price is a genuine market discontinuity, not keeper latency. The peak-hold composes with the volatility curve by max — the same reopen feeds both estimators, and max counts it once. Because the maintenance level *is* the stress move, a position at MMR survives an exact repeat of the worst observed gap, and initial margin survives twice it. One severe earnings gap therefore lifts the pair's margin for months, while a mean-tracking EMA would average it away against dozens of quiet nights. The 40% cap is the stress-move ceiling, so a cap-sized reopen lands exactly on the 80% IMR clamp. The same number reaches the fund target at full size.

**Warmup:** a new market's IMR is floored at **20%** (5× leverage; 40% for non-continuously traded pairs, which have no reopen-gap history yet) until it is 5 days old *and* has seen 50,000 price updates. Thin, young books don't get 25× leverage.

IMR is what's checked at order creation and collateral withdrawal — always against **worst-case exposure**: current position plus resting orders in the worse direction, including the flip case. A stale oracle adds no surcharge — gap risk is already in the always-on IMR above — but it does gate *release*: a position holder's withdrawal requires a fresh price outright (see [the stale-price regime](oracle.md#the-stale-price-regime-market-hours)).

## The retained-collateral floor

Passing IMR is not sufficient to withdraw. While a position is open, the account must also keep a floor of margin in **collateral proper — cash, not equity**: `mmrBp` of current notional on continuously traded pairs, the full `imrBp` on session-bound ones. Unrealized profit does not count toward it.

The floor does two jobs the IMR check alone cannot. It guarantees the fee that closes the position is always payable, since fees come out of collateral rather than out of equity. And it keeps margin in money that survives a reversal: paper profit evaporates in the same move it would need to buffer. The asset-class split follows from what liquidation can do — on a 24/7 market a keeper can interpose as the position deteriorates, so maintenance-level cash is enough; across a reopen gap no liquidation can interpose at all, which is why session-bound pairs hold the initial level instead.

`BazaarPairLens.getMaxWithdrawable` returns the largest withdrawal both gates would accept.

## Maintenance margin (MMR) and the 24-hour grace

**MMR = IMR / 2, always.** A position is liquidatable when equity < MMR × notional (see [Liquidations](liquidations.md)).

Because IMR is dynamic, a volatility spike could raise MMR and instantly liquidate positions that were healthy a minute ago. Bazaar prevents this with a **lagged MMR**: the pair samples MMR hourly into a 25-slot ring buffer, and existing positions are judged against

```
effectiveMMR = min(reference, current)
reference    = the newest sample ≥ 24 h older than the mark   (if the position is ≥ 24 h old)
             = the position's entry MMR                        (otherwise)
```

A *rising* requirement cannot liquidate you for 24 hours; a *falling* one helps you immediately. The grace re-anchors every time you increase risk (open, add, flip), and a closed position forfeits it entirely.

The 24 hours are counted back from the timestamp of the price the position is being valued against, not from the block the call lands in. The two are the same whenever the caller supplies a fresh price; they diverge on a closed-market pair falling back to the last stored price, and there the threshold stays the one that was in force 24 hours before that mark. Both halves of the solvency test then describe the same instant, so a keeper cannot record an adverse price and wait for the sample window to roll onto a higher requirement before calling.

## Solvency math

All solvency questions go through one function — `BucketLib.calculateState`:

```
unrealizedPnl = ±(currentNotional − entryValue)
fundingPnl    = ∓(currentFundingIndex − entryFundingIndex) × size / 1e18
equity        = collateral + unrealizedPnl + fundingPnl
isSolvent     = max(0, equity) ≥ effectiveMMR × currentNotional  AND  equity > 0
```

Matching, withdrawals, liquidations, and ADL all call the same math with the same lagged-MMR inputs, so a position cannot be simultaneously "healthy" to one subsystem and "liquidatable" to another.
