# Funding

Funding tethers the perp's traded price to its index. Bazaar's implementation has no keeper and no discrete funding events — it accrues **continuously, per second**, updated lazily whenever any price-touching function runs.

## Mark price

The mark is an EMA of execution VWAPs — one update per matching transaction, fed the volume-weighted average price of that transaction's fills:

- Each update's weight scales with its share of rolling volume (which itself decays linearly to zero over 60 minutes), capped at **10%** per update. Weight itself has no floor — a dust fill against deep volume gets ~0 weight, so a tiny wash trade can't nudge the mark. The 10% cap is the single-update bound: no matching transaction, however large, moves the mark more than 10% of the way to its print.
- The *denominator* that share is measured against is floored at **2% of per-side open-interest notional** (`VOLUME_FLOOR_BP`, taken on the larger side and counting the vault's inherited inventory). Rolling volume is fed only by prior fills, so without the floor a pair with no other traders would let one account supply the entire denominator and read every dust print as volume-dominant. Denominating the floor in open interest keeps it scale-free — funding transfers a percentage of open interest, so pricing the cost of moving the mark in the same units holds an attacker's cost-to-payoff ratio fixed on pairs of any size. Only the weighting denominator is floored; rolling volume itself keeps recording true traded notional.
- Before entering the EMA, the print itself is clamped to **±4% of the index** (`MAX_MARK_DEVIATION_BP`) — an implausible fill price can't be injected into the mark, and the steady-state mark stays within that band of index.
- With no trades, the mark **decays linearly back to the index over 1 hour** — a stale mark cannot pin funding away from index indefinitely.

## Funding rate

```
premium = (mark − index) / index
rate    = clamp(premium / dampener, ±ceiling per hour)

                        ceiling      dampener
session-bound pairs      0.5%/h         ÷ 8
continuously traded      0.1%/h         ÷ 40
```

Longs pay shorts when mark > index and vice versa.

The two pairings exist because a session-bound pair accrues funding only while its oracle is fresh — roughly a fifth of the week — so matching a 24/7 pair's corrective force per calendar week takes a higher ceiling per accruing hour. Neither number is chosen independently: each dampener is *derived* from its own ceiling against the shared ±4% band, so a mark sitting exactly at the band edge yields exactly that ceiling and the clamp is never reached from strictly inside the band. Declaring band, rate and dampener independently is what would leave a stretch of the band over which funding is already saturated and stops responding to further mark movement — the region a manipulated mark aims for. The two land at comparable calendar horizons anyway: 8 accruing hours is a little over a day on a session pair, 40 a little under two on a continuous one.

A ceiling and a dampener are never mixed across pair types, so the choice changes how hard funding pulls, never how far the mark may sit from index.

The rate accrues into a cumulative **funding index denominated in price units** (rate × index price, 1e18), so a position's funding PnL is simply `Δindex × size` — no per-position bookkeeping between touches.

## Settlement

Funding settles to cash **exactly once — when position shares close** (including liquidation and ADL paths, where the estate's accrued funding rides through the vault's aggregate and settles at unwind). Between touches it exists only as the index delta inside solvency math.

## Oracle-gap guards

- Oracle silent > **12 hours** (market closed over a weekend): the accrual window restarts at the new tick — no funding accrues over the dark period.
- Latest oracle tick more than **30 minutes** after the last funding accrual: pre-tick accrual is limited to the 30 minutes before the tick.

Both guards prevent a reopening market from instantly charging a weekend's worth of funding computed against a stale mark.
