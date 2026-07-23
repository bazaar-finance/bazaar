# Funding

Funding tethers the perp's traded price to its index. Bazaar's implementation has no keeper and no discrete funding events — it accrues **continuously, per second**, updated lazily whenever any price-touching function runs.

## Mark price

The mark is an EMA of batch execution VWAPs:

- Each batch's weight scales with its share of rolling volume (which itself decays linearly to zero over 60 minutes), capped at **10%** per batch. There is no floor — a dust fill against deep volume gets ~0 weight, so a tiny wash trade can't nudge the mark. The 10% cap is the manipulation bound — no single batch, however large, can move the mark more than 10% of the way to its print.
- Before entering the EMA, the batch print itself is clamped to **±5% of the index** — an implausible fill price can't be injected into the mark, and the steady-state mark stays within that band of index.
- With no trades, the mark **decays linearly back to the index over 1 hour** — a stale mark cannot pin funding away from index indefinitely.

## Funding rate

```
premium = (mark − index) / index
rate    = clamp(premium / 8, ±0.5% per hour)
```

The ÷8 dampening turns a persistent 4% premium into 0.5%/h — strong enough to arbitrage real skew, weak enough not to whipsaw. Longs pay shorts when mark > index and vice versa.

The rate accrues into a cumulative **funding index denominated in price units** (rate × index price, 1e18), so a position's funding PnL is simply `Δindex × size` — no per-position bookkeeping between touches.

## Settlement

Funding settles to cash **exactly once — when position shares close** (including liquidation and ADL paths, where the estate's accrued funding rides through the vault's aggregate and settles at unwind). Between touches it exists only as the index delta inside solvency math.

## Oracle-gap guards

- Oracle silent > **12 hours** (market closed over a weekend): the accrual window restarts at the new tick — no funding accrues over the dark period.
- Latest oracle tick more than **30 minutes** after the last funding accrual: pre-tick accrual is limited to the 30 minutes before the tick.

Both guards prevent a reopening market from instantly charging a weekend's worth of funding computed against a stale mark.
