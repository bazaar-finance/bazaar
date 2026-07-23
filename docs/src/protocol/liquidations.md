# Liquidations

`liquidate(usersToLiquidate[], priceUpdate)` is permissionless — any keeper can batch-liquidate positions whose equity has fallen below maintenance margin (judged by the same [lagged-MMR solvency math](margin.md) the rest of the protocol uses, at plain oracle spot).

## What happens to a liquidated position

Liquidation is **full** — there are no partials:

1. The entire remaining collateral is seized into the pair's **insurance fund**.
2. The position itself transfers to the pair's **vault** at its *bankruptcy price* — the price at which its equity would have been exactly zero:

   ```
   long:  bankruptcy = (entryValue − collateral − fundingPnl) / size
   short: bankruptcy = (entryValue + collateral + fundingPnl) / size
   ```

3. The keeper is paid `max($0.10, 2 bp of notional)` per position from the insurance fund, unconditionally — the reward does not depend on how the vault later exits the inventory. (Payouts use a non-reverting transfer; a failed payout restores the fund rather than blocking the batch, and the payment is skipped entirely — never partially — when the fund can't cover it.)
4. The user's TP/SL/market orders are canceled and the bucket fully reset.

## The vault: one aggregate, not a queue

Inherited inventory is aggregated into a single net, single-direction holding — sums of size, entry notional, bankruptcy notional, and a size-weighted entry funding index. There is no per-estate FIFO: unwinding is O(1) regardless of how many accounts were liquidated.

A liquidation on the *opposite* side nets against the aggregate immediately: the overlapping quantity's price legs cancel at oracle and funding legs cancel at the current index, realizing PnL on the spot; the remainder can flip the aggregate's direction.

## Exiting the inventory

The vault is not a market maker — it exits as fast as the book allows:

- **Pass A of every batch**: the aggregate fills against resting limits on its own side, but only within **min(5%, current MMR) of oracle** — the vault will not dump into a hole, and with the band capped at MMR a band-edge fill lands near bankruptcy price in calm regimes. Pass A runs even under a stale oracle; liquidation flow is forced flow.
- **Opposite-side netting** (above).
- **[Auto-deleveraging](adl.md)** when the book can't absorb it and the fund is threatened.

Vault PnL from these exits is booked as an insurance↔deposits transfer (profits refill the fund; losses drain it, overrun becoming `deficit` — realized bad debt that [terminates the pair](termination.md)).

Every liquidation fill also feeds the **liquidation-gap EMA** — the realized distance between exit price and bankruptcy price — which raises IMR in markets that liquidate badly and sizes the insurance-fund target. Bad liquidations make the market automatically more conservative.
