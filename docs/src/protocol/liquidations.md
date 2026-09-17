# Liquidations

`liquidate(usersToLiquidate[], priceUpdate)` is permissionless — any keeper can liquidate any set of positions whose equity has fallen below maintenance margin (judged by the same [lagged-MMR solvency math](margin.md) the rest of the protocol uses, at plain oracle spot).

**How old a mark may confiscate collateral.** On a [stale fallback](oracle.md#the-stale-price-regime-market-hours) the call reverts once that stored price is more than **10 minutes** old (`MAX_LIQUIDATION_PRICE_AGE`). The fallback carries no expiry of its own — it stays authoritative until some call stores a newer one — and seizure takes a position's *entire* bucket rather than its shortfall, so without a ceiling an account that breached maintenance margin for a single tick would stay seizable at that tick for as long as the pair went untouched, long after the market traded back through it. The ceiling redirects liquidation onto a fresh price rather than withdrawing the power: past it, a caller supplying `priceUpdate` (and Pyth's fee in `msg.value`) liquidates normally.

## What happens to a liquidated position

Liquidation is **full** — there are no partials:

1. The entire remaining collateral is seized into the pair's **insurance fund**.
2. The position itself transfers to the pair's **vault** at its *bankruptcy price* — the price at which its equity would have been exactly zero:

   ```
   long:  bankruptcy = (entryValue − collateral − fundingPnl) / size
   short: bankruptcy = (entryValue + collateral + fundingPnl) / size
   ```

3. The keeper earns `max($0.10, 2 bp of notional)` per position from the insurance fund, with no profit-contingent component — the reward does not depend on how the vault later exits the inventory. (The fund is debited and the keeper's claimable balance credited in the same step — no transfer runs inside the liquidation, so nothing about the keeper's address can block it. The reward is capped at the fund's *free capital*: the collateral just seized is earmarked against the inventory it arrived with and never pays the keeper, so a fund holding nothing else pays nothing, and the liquidations themselves still commit.)
4. The user's TP/SL/market orders are canceled and the bucket fully reset.

## The vault: one aggregate, not a queue

Inherited inventory is aggregated into a single net, single-direction holding — sums of size, entry notional, bankruptcy notional, and a size-weighted entry funding index. There is no per-estate FIFO: unwinding is O(1) regardless of how many accounts were liquidated.

A liquidation on the *opposite* side nets against the aggregate immediately: the overlapping quantity's price legs cancel at oracle and funding legs cancel at the current index, realizing PnL on the spot; the remainder can flip the aggregate's direction.

## Exiting the inventory

The vault is not a market maker — it exits as fast as the book allows:

- **Inline, inside `liquidate()` itself**: freshly seized inventory is crossed into the resting book before the transaction re-evaluates vault health, within a fixed node budget (`LIQ_INLINE_UNLOAD_STEPS` = 16) that keeps the liquidator's gas predictable.
- **Permissionless `unloadVault(maxSteps, priceUpdate)`**: any keeper finishes deeper inventory for **2 bp of the notional it unloads**, from the insurance fund. The rate is paid on any amount, so a keeper that drains a thin book is never left with nothing; a **$0.25** floor (`UNLOAD_BOUNTY_MIN`) is added on top only when at least **$1,250** unloads (where the rate overtakes it) or the call clears the inventory, which is what stops a keeper earning a premium by slicing one unload into many. Capped at the fund's free capital — never paid from the seizure earmarked against inventory still held.
- **Opposite-side netting** (above).
- **[Auto-deleveraging](adl.md)** when the book can't absorb it and the fund is threatened.

Both unload paths fill only inside the **unload bound** and within the fund's **headroom**. The bound is the looser of two anchors: the estates' *fund-neutral price* — the price at which closing the inventory pays back exactly the collateral seized with it, net of the funding accrued since the estates entered (their entry basis less the seizure, carried forward by that funding) — and **min(5%, current MMR) from oracle** (`LIQ_MAX_SLIPPAGE_BP`). A maker beyond both is refused, so a bid that deviates more than the band from the oracle still fills if it beats bankruptcy, and a bid under bankruptcy still fills if it stays inside the band. The headroom is what the fund may spend on fills inside that bound: its free capital above a **reserve** of 20% of the [insurance target](insurance.md) on open interest (`ADL_RESERVE_BP`), less the loss the inventory already carries at the mark, less the caller's reward. A fill is measured against a reference price: beyond it a fill lowers the loss the remainder carries by at least what it costs and is always taken; inside it a fill costs the difference per unit, and the walk takes only what the headroom covers, trimming the last maker and stopping. While the fund's capital above the reserve covers the inventory's loss at the mark — the healthy side of the ADL gate — the reference is the nearer of the neutral price and the oracle, because the headroom has already set that loss aside: spending it to zero leaves the fund above its reserve by exactly the remaining inventory's loss at the mark, so the pair ends the walk healthy. An unload can never take the fund below its reserve, and never push a pair over the ADL trigger — which is why health is judged *after* the walk, letting stale bids absorb inventory before any auction opens. A walk that starts past the trigger has nothing set aside, so its reference is the neutral price itself: it takes only fills that cost the fund nothing, spends neither the base nor the reserve, cannot book a deficit, and leaves the rest to the auction. Both paths run even under a stale oracle; liquidation flow is forced flow, the bankruptcy leg reads no price at all, and the headroom is judged at the same mark the fills are.

Vault PnL from these exits is booked as an insurance↔deposits transfer (profits refill the fund; losses drain it, never past the headroom). `deficit` — realized bad debt that [winds the pair down](termination.md) — is reserved for genuine insolvency: a netting loss the fund cannot cover, or a seizure the deposits ledger could not back, which surfaces when that estate settles. Note that once a pair's settlement price is fixed, this live liquidation path is off: positions are marked to the frozen price by permissionless settlement instead.

Every liquidation fill also feeds the **liquidation-gap EMA** — the realized distance between exit price and bankruptcy price. It adds straight into the pair's [stress move](margin.md#the-stress-move) at full size, because a fill landing that far past bankruptcy is exactly the amount by which maintenance margin proved too thin, so it raises margin and the insurance-fund target together. Bad liquidations make the market automatically more conservative, and the term recedes on its own once fills stop landing past bankruptcy.
