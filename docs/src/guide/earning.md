# Earning on Bazaar

Three permissionless ways to earn from the protocol's operation, ordered by how much infrastructure they demand. (Building a frontend? That's its own page: [Integrators](integrators.md).)

## Insurance LP

**What it is:** deposit USDC into a specific market's insurance fund and hold shares of it. You are selling crash insurance on that one market — steady fee income against tail risk.

**You earn** a pro-rata slice of everything the fund collects: insurance fees on every fill, all collateral seized from liquidated traders, the vault's liquidation-unwind profits, slashed sequencer bonds, and forfeited governance bonds.

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

**What it is:** run a bot that calls permissionless maintenance functions and collects the bounty attached to each. No bond, no stake — just gas and uptime. All bounties pay in USDC, immediately, from the pair's insurance fund or the offender's bond.

| Opportunity | Call | Bounty | What your bot watches |
|---|---|---|---|
| Liquidations | `liquidate(users[], priceUpdate)` | max($0.10, 2 bp of notional) per position | position health vs. lagged MMR (`checkBucketSolvency` on the lens) |
| ADL execution | `executeAdl(winners[], priceUpdate)` | 0.1% of averted bad debt | `isAdlPending`; rank winners by `getAdlScore` on the lens, descending — it reproduces the on-chain ranking exactly, and a mis-sorted batch reverts |
| Censorship proofs | `challengeOmission(...)` | 1% of the censored notional (min ~$3 of the $20 floor) | `BatchRecorded` events vs. your own view of the resting book |
| Stale-flag proofs | `challengeStaleBatch(...)` | 0.5% of batch notional | batches flagged `isStale` vs. Pyth's actual publish times |
| Dead-market cleanup | `terminateStalePair`, `terminateScheduledPair`, UMA settlement pokes | 0.1% (10 bp) of the fund, capped $100 (proposals) | oracle silence > 21 days; passed cessation timestamps |
| Terminal settlement | `liquidate` (settlement mode) during the 48 h window, then `finalizeTermination` | `max($0.10, 2 bp of notional)` per position, from that position's own remaining collateral (`getTerminalSettlementBounty` on the lens quotes it per position) | a pair whose settlement price is fixed; needs no `priceUpdate` and no ETH |

Practical notes: every price-touching call takes a `priceUpdate` — your bot pushes the Pyth update and acts on it atomically (Pyth's fee is paid in ETH, refunded when unused). Bounty payments use non-reverting transfers: use a clean address that can receive USDC. Liquidation and challenge markets are competitive — latency matters; ADL and termination cleanup are sleepier niches.

## Sequencing

**What it is:** run the off-chain matcher for one or more markets. You watch resting orders, sort them, and submit `matchBatch` a few times per second. This is the protocol's most demanding — and most rewarded — role.

**You earn**, per fill you match: the dynamic taker fee (**0.75 bp → 3.75 bp**, priced by how utilized global sequencer capacity is), 0.25 bp from the maker, and **$0.03 flat from each side**. On thin-order flow the flats dominate; at scale the basis points do.

**You stake:** ≥ **$1,000** bond in `BazaarSequencer`, which caps your throughput at **14× bond per rolling 30 minutes** — more volume requires more skin. Withdrawal respects the same window.

**You're slashed for** exactly two provable offenses (see [Sequencers & Fraud Proofs](../protocol/sequencers.md)):

- **Censoring an order** that should have matched: 7% of the notional. The operational discipline this imposes: *include every live in-range order you saw at your observation block* — the engine auto-cancels the ones that can't pay, and witnesses the ones it skips, so honest inclusion is always safe.
- **Mislabeling a batch as price-stale** when a fresh Pyth tick existed: 1%.

There is no slashing for downtime, for matching slowly, or for someone else matching first — competition is by fee capture, not liveness obligations.

**Minimum viable setup:** an Arbitrum node or reliable RPC, a Pyth Hermes price stream, an indexer of the pair's `OrderUpdated`/`BatchRecorded` events to maintain the resting book, sort logic per the [matching invariants](../protocol/matching.md), and a funded relayer key. Start on one quiet market with the minimum bond; capacity and fee revenue scale with the bond as you grow.
