# Earning on Bazaar

Two permissionless ways to earn from the protocol's operation, ordered by how much infrastructure they demand. (Building a frontend? That's its own page: [Integrators](integrators.md).)

## Insurance LP

**What it is:** deposit USDC into a specific market's insurance fund and hold shares of it. You are selling crash insurance on that one market — steady fee income against tail risk.

**You earn** a pro-rata slice of everything the fund collects: insurance fees on every fill, all collateral seized from liquidated traders, the vault's liquidation-unwind profits, and forfeited governance bonds.

**You risk** the fund's payouts: liquidation-unwind losses, ADL winner credits, keeper rewards — and in a market collapse, the fund is the last cushion before trader haircuts, so it can be drained. Share price = fund ÷ shares; it floats both ways.

**The terms** (full detail: [Insurance Fund](../protocol/insurance.md)):

| Rule | Value |
|---|---|
| Minimum deposit | $5 — per market, choose which books you back |
| Exit | request → **20-day cooldown** → 3-day execution window |
| Exit rate limits | slower when the fund is below target — you cannot stampede out of a thinning backstop |
| Crisis lock | withdrawals blocked while ADL is pending, a termination is scheduled, or the 48 h settlement window is open (bad debt is charged to the fund at finalize — LPs cannot exit ahead of it) |
| Governance | matured shares (7 days) vote on shutting the market down (60% threshold) |

The honest framing: you get paid *because* your capital is locked in exactly the moments you'd want it out. Size accordingly.

## Keeper bounties

**What it is:** run a bot that calls permissionless maintenance functions and collects the bounty attached to each. No bond, no stake — just gas and uptime. All bounties pay in USDC, immediately — most from the pair's insurance fund; trigger tips and terminal-settlement bounties come from the serviced position's own collateral.

| Opportunity | Call | Bounty | What your bot watches |
|---|---|---|---|
| Liquidations | `liquidate(users[], priceUpdate)` | max($0.10, 2 bp of notional) per position | position health vs. lagged MMR (`checkBucketSolvency` on the lens) |
| Trigger execution | `executeTriggeredOrders(execs[], priceUpdate)` | $0.25 per fired stop (`TRIGGER_TIP`), charged to the stop's owner; ≤ 20 per call | untriggered stops' trigger prices vs. the live Pyth price |
| Vault unloading | `unloadVault(maxSteps, priceUpdate)` | max($0.25, 2 bp of unloaded notional), paid when ≥ $1,250 notional unloads or the call clears the inventory | `getPendingLiquidationExposure` on the lens after liquidations |
| Price refresh | `refreshPrice(priceUpdate)` | $0.25 when the stored price is > 10 min old, on pairs holding > $10k insurance and > $10k OI | quiet pairs' last stored-price timestamps |
| ADL execution | `executeAdl(winners[], priceUpdate)` | 0.1% of averted bad debt | `isAdlPending`; rank winners by `getAdlScore` on the lens, descending — it reproduces the on-chain ranking exactly, and a mis-sorted submission reverts |
| Dead-market cleanup | `terminateStalePair`, `terminateScheduledPair`, UMA settlement pokes | 0.1% (10 bp) of the fund, capped $100 (proposals) | oracle silence > 21 days; passed cessation timestamps |
| Terminal settlement | `liquidate` (settlement mode) during the 48 h window, then `finalizeTermination` | `max($0.10, 2 bp of notional)` per position, from that position's own remaining collateral (`getTerminalSettlementBounty` on the lens quotes it per position) | a pair whose settlement price is fixed; needs no `priceUpdate` and no ETH |

Practical notes: every price-touching call takes a `priceUpdate` — your bot pushes the Pyth update and acts on it atomically (Pyth's fee is paid in ETH, refunded when unused). Bounty payments use non-reverting transfers: use a clean address that can receive USDC. Liquidation and trigger-execution markets are competitive — latency matters; unloading, ADL, and termination cleanup are sleepier niches.
