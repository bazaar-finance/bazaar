# Earning on Bazaar

Two permissionless ways to earn from the protocol's operation, ordered by how much infrastructure they demand. (Building a frontend? That's its own page: [Integrators](integrators.md).)

## Insurance LP

**What it is:** deposit USDC into a specific market's insurance fund and hold shares of it. You are selling crash insurance on that one market — steady fee income against tail risk.

**You earn** a pro-rata slice of everything the fund keeps: insurance fees on every fill, forfeited governance bonds, and whatever the vault's inherited inventory returns above the collateral seized alongside it. That seizure is not income the moment it lands — it is earmarked against the position the vault just inherited and leaves again when that position closes, so what you keep is the part the close did not need.

**You risk** the fund's payouts: liquidation-unwind losses, ADL winner credits, keeper rewards — and in a market collapse, the fund is the last cushion before trader haircuts, so it can be drained. Shares are priced off the fund's value at the mark and float both ways: while the vault holds liquidated inventory, an exit is charged that inventory's unrealized loss (never paid its unrealized gain), and a deposit is priced at fair value on a fresh mark — you don't pay for a loss you didn't underwrite, and you don't buy a pending recovery at a discount. Details: [Insurance Fund](../protocol/insurance.md).

**The terms** (full detail: [Insurance Fund](../protocol/insurance.md)):

| Rule | Value |
|---|---|
| Minimum deposit | $5 — per market, choose which books you back. `depositToInsurance` takes a `priceUpdate`: while the vault holds liquidated inventory the deposit is priced at the mark and needs a fresh one, so on a closed venue it waits for the reopen; with the vault flat no price is read and an empty update works |
| Exit | request → **20-day cooldown** → 3-day execution window |
| Exit rate limits | slower when the fund is below target — you cannot stampede out of a thinning backstop |
| Crisis lock | withdrawals blocked while the vault's liquidation exposure exceeds the ADL trigger (judged live by the execute call, against the price it fetches), a termination is scheduled, or the settlement window is open (the fund becomes the residual at finalize — LPs cannot exit ahead of it); after an escape-hatch finalize, until the remaining positions are settled (you can settle them yourself through `liquidate`) or 14 days beyond the hatch |
| Market hours | the execute call needs a fresh oracle price (≤ 2 s old), so on non-24/7 markets exits happen during trading hours — the frozen closing mark is refused; a market whose feed has died releases LPs once the 21-day stale termination settles it. Deposits face the same gate only while the vault holds liquidated inventory, since that is the only case where a deposit has to price it |
| Governance | matured shares (7 days, the listing seed included) propose and vote on shutting the market down (60% threshold) |

The honest framing: you get paid *because* your capital is locked in exactly the moments you'd want it out. Size accordingly.

## Keeper bounties

**What it is:** run a bot that calls permissionless maintenance functions and collects the bounty attached to each. No bond, no stake — just gas and uptime. All bounties are USDC, credited to your address's claimable balance on the pair the moment you earn them and withdrawn in one `claimFees()` call per pair — most are funded from the pair's insurance fund (capped at its free capital — never the seizure earmarked against inventory the vault still holds); trigger tips come from the serviced stop's own collateral, and settlement tips from the settled position's.

| Opportunity | Call | Bounty | What your bot watches |
|---|---|---|---|
| Liquidations | `liquidate(users[], priceUpdate)` | max($0.10, 2 bp of notional) per position | position health vs. lagged MMR (`checkBucketSolvency` on the lens); carry a `priceUpdate` on a closed market — a stale stored price older than 10 min cannot seize collateral |
| Trigger execution | `executeTriggeredOrders(execs[], priceUpdate)` | $0.25 per fired stop (`TRIGGER_TIP`), charged to the stop's owner; ≤ 20 per call | untriggered stops' trigger prices vs. the live Pyth price |
| Vault unloading | `unloadVault(maxSteps, priceUpdate)` | 2 bp of unloaded notional always; floor of $0.25 when ≥ $1,250 unloads or the call clears the inventory | `getPendingLiquidationExposure` on the lens after liquidations |
| Price refresh | `refreshPrice(priceUpdate)` | $0.25 when the stored price is > 10 min old, on pairs holding > $10k of free insurance capital and > $10k OI | quiet pairs' last stored-price timestamps — the refresh also judges vault health, so on a book too thin to trade it is what opens an ADL window (and starts its 24 h clock) once inherited inventory drifts past the trigger |
| ADL execution | `executeAdl(winners[], priceUpdate)` | 0.1% of averted bad debt | `isAdlPending`; rank winners by `getAdlScore` on the lens, descending — it reproduces the on-chain ranking exactly, and a mis-sorted submission reverts |
| Dead-market cleanup | `terminateStalePair`, `terminateScheduledPair`, UMA settlement pokes | 0.1% (10 bp) of the fund, capped $100 (proposals) | oracle silence > 21 days; scheduled cutoffs that have passed |
| Terminal settlement | `liquidate` (settlement mode) while the settlement window is open, then `finalizeTermination` | $0.10 per position settled for someone else (`TERMINAL_SETTLEMENT_TIP`): from the position's remaining collateral, insurance topping up; after an escape-hatch finalize only bankrupt stragglers pay, from the insurers' residual | a pair whose settlement price is fixed — every open position, listed from `PositionBucketUpdated` events; needs no `priceUpdate` and no ETH |

Practical notes: every price-touching call takes a `priceUpdate` — your bot pushes the Pyth update and acts on it atomically (Pyth's fee is paid in ETH, refunded when unused). Bounties are never pushed to you: watch `FeeAccrued` events or ask the lens (`getClaimableFeesAll(you)` lists the balance on every pair in one call), and call `claimFees()` whenever a balance is worth the gas — one claim per pair sweeps every bounty kind, and it works in every pair state, including after termination. Liquidation and trigger-execution markets are competitive — latency matters; unloading, ADL, and termination cleanup are sleepier niches.
