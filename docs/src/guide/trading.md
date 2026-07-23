# Trading

A practical guide to trading on Bazaar. Plain language first; every section links to the technical chapter that governs it.

## Getting in

1. **Fund**: hold USDC on Arbitrum. That's the only collateral — no ETH needed if you use a [gasless relayer](../protocol/meta-transactions.md), and even the USDC approval can ride a permit signature.
2. **Deposit**: `depositCollateral` into the specific market you want to trade (min $1). Collateral is per-market; a blowup in one market cannot touch your balance in another.
3. **Trade**: place orders. You hold **one net position per market** — buying 2 ETH long then selling 3 flips you to 1 short.

## Order types, practically

| You want to… | Use | Behavior |
|---|---|---|
| Fill now at market | `Market` | fills against resting limits at up to your slippage cap (max 5%); lives ~3 seconds; one at a time |
| Rest at your price | `Limit` | sits on the book until filled, canceled, or expired (up to ~1 year); `postOnly` guarantees you're the maker |
| Enter on a breakout | `StopLimit` | arms when price crosses your trigger, then acts as a limit |
| Lock in profit | `TakeProfit` | reduce-only limit against your position; one per position |
| Cap your loss | `StopLoss` | reduce-only market-style close when price crosses your trigger; one per position |

Minimum order: **$5** notional (closing your whole position is always allowed). Stops trigger on the *oracle* price of the batch, so a sequencer can't fire your stop early.

## Leverage & staying solvent

- Your maximum leverage is dynamic — up to **25×** in calm, well-capitalized markets, less in volatile ones, at most 5× in a market's first days, and a third less on stocks/FX (non-24/7 markets carry a 1.5× margin multiplier). The current requirement is on-chain (`BazaarPairLens.checkBucketSolvency`).
- **Initial margin** gates new orders and withdrawals, counted against your worst case (position + everything resting). **Maintenance margin is half of initial** — below it, anyone may liquidate you.
- Rising margin requirements give existing positions a **24-hour grace**; falling ones help you immediately. See [Margin & Leverage](../protocol/margin.md).
- **Funding** accrues continuously, capped at ±0.5%/hour: longs pay shorts when the market trades above index, and vice versa. It settles when you close. See [Funding](../protocol/funding.md).

## What can happen to you

Honest list, in increasing order of severity:

- **Your order auto-cancels.** If your equity drifts below what a fill would require, the match cancels your order instead of filling it. Resubmit after topping up.
- **Liquidation.** Below maintenance margin, your position is closed *entirely* (no partials) and your remaining collateral is seized. Set stops, or watch `checkBucketSolvency`. See [Liquidations](../protocol/liquidations.md).
- **Auto-deleveraging (ADL).** In a crisis, the *most profitable, most leveraged* traders on the winning side can be force-closed at a worse-than-market (but never loss-making) price to keep the market solvent. If you're up big with high leverage during chaos, you're first in line. See [Auto-Deleveraging](../protocol/adl.md).
- **Market termination.** If the underlying dies (delisting, feed decommission), the market cash-settles at a final price and you withdraw. In deep insolvency, payouts are haircut pro-rata — never race-to-exit. See [Termination](../protocol/termination.md).

## Fees you'll pay

Roughly: **fractions of a basis point plus $0.03 per side**. Makers pay ~1 bp all-in; takers pay a utilization-priced sequencer fee (0.75–3.75 bp) plus an insurance fee that rises when the market's backstop is thin — and *closing* risk is always cheaper than opening it. Exact table: [Fees](../protocol/fees.md).

## Stocks & FX after hours

Non-24/7 markets keep trading on the last price when their venue closes: margin requirement doubles for new fills, prices are boxed to ±10% of the last print, and market orders are disabled until the venue reopens. See [Price Oracle](../protocol/oracle.md#the-stale-price-regime-market-hours).

## Getting out

`withdrawCollateral` any time your equity covers initial margin on what remains — valued conservatively at the pessimistic edge of the oracle's confidence band. Flat (no position, no orders)? Withdraw everything, any time. Two freezes to know about: if you hold a position, withdrawals are blocked for as long as ADL remains *pending* (until the crisis clears or the 24-hour ADL timeout terminates the market — the 10-minute clock is only the auction's score decay); and *all* withdrawals pause during the ~1-hour terminal sweep just before a dying market settles.
