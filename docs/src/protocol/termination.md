# Termination & Settlement

Perpetuals on real-world assets need an exit ramp: feeds get decommissioned, companies get acquired, assets redenominate. Every Bazaar market can be wound down **without anyone's permission** — five independent paths, each ending with positions cash-settled at a defined price and withdrawals open forever after.

## The five paths

| Path | Trigger | Gate |
|---|---|---|
| **Scheduled** (UMA) | A known *future* cessation: delisting, oracle decommission, structural change (splits, spinoffs, special dividends > 5%, redenominations), or Pyth contract migration | $1,000 bond, 12 h UMA liveness; `lastTradingTs` must be ≥ 12 h (the liveness) in the future, so the cutoff can't land before the dispute window ends |
| **Post-cessation** (UMA) | The event *already happened* — proposer supplies only the cessation timestamp; UMA verifiers check the event and timestamp, and the pair settles at the on-chain-verified Pyth tick from that moment | $1,000 bond, 72 h liveness (acceptance halts the market instantly, so scrutiny precedes approval) |
| **Stale oracle** | No Pyth update for **21 days** — objectively provable on-chain, no UMA needed | none; anyone |
| **Insurer vote** | Matured insurance shares voting yes reach **60%** of the total-share snapshot taken at proposal, within 7 days | $500 bond (forfeited to the fund if the vote fails); 7-day share maturity to vote; 7-day execution window; 14-day proposal cooldown |
| **Autonomous** | Realized bad debt (`deficit > 0`), ADL timeout (24 h), or books-vs-balance shortfall | none — self-executing inside the health check |

Market-driven price moves are explicitly *not* valid termination grounds — anticipated volatility is tradeable risk, not a structural event.

## Settlement price discipline

Both UMA paths converge on the same settlement machinery: acceptance freezes the pair's price feed at `lastTradingTs` (for post-cessation a timestamp already in the past, so trading halts immediately) and the pair then settles at the **Pyth tick closest to cessation** — a signed historical update in `[ts − 2 s, ts]`, verified on-chain, never a number typed into the proposal. For the first 3 hours — measured from the *later* of `lastTradingTs` and UMA acceptance — only that genuine tick is accepted (bad or empty data cannot force a fallback while a real tick may exist); after the grace, it falls back to the frozen last stored price so a market can never strand un-terminated. Trading and matching halt past the scheduled timestamp.

The non-UMA paths pin their price at execution instead: an insurer-vote termination settles at a fresh oracle tick (≤ 2 s old) supplied with the execute call, and a stale-oracle termination at the newest confidence-cleared price the oracle still serves — falling back to the pair's last stored price when even that read fails, with the 21-day staleness gate enforced either way.

The proposer of a successful UMA termination earns 0.1% of the pair's insurance fund (capped $100) — a bounty for noticing dead markets.

## The terminal sweep window

Every non-emergency path is **two-stage**: the terminator first *fixes* the settlement price (`fixSettlementPrice`, opening a 1-hour sweep window) and only afterwards can anyone call `finalizeTermination`. During the window, `liquidate()` switches modes: it prices every position at the **fixed settlement price** — no oracle read, no update fee, which is what makes it work on dead feeds — and its threshold drops from maintenance margin to **equity ≤ 0** (price risk is gone, so seizing solvent holders' residual equity would be confiscation). Swept positions enter the vault's pending-liquidation inventory at their bankruptcy price, so their negative equity flows into the settlement waterfall below instead of silently truncating.

Why it exists: liquidation can only fire on observed live ticks, but termination events are precisely discontinuities — delistings, mergers, feed deaths. A position that gaps from healthy to negative equity on the final print was never liquidatable, and without the sweep its bad debt would be invisible at settlement: winners would be promised 100% of PnL against a pot that cannot pay, a first-come-first-served drain. The window gives keepers a guaranteed interval to fold that bad debt into the waterfall. Finalize never *requires* a completed sweep (an unliquidatable straggler must not brick settlement — unswept positions just settle as before), and all deposits and withdrawals (collateral and insurance alike) are frozen from price-fix to finalize so nobody exits ahead of the accounting.

## The settlement waterfall

Normal termination settles every position's PnL at the final price through the withdrawal path:

1. **Insurance fund** absorbs the net shortfall (including settling the vault's remaining liquidation inventory at its average bankruptcy price).
2. If the fund can't cover: **winners' PnL is haircut pro-rata** (`winnersPayoutRatioBp`) — losers still pay in full.
3. Deep insolvency ("rung 4"): winners' PnL goes to zero and **principal itself is haircut pro-rata** against the actual USDC held.

Everything is ratio-based against a snapshot — **never first-come-first-served**. Two terminal modes exist: *normal* (PnL settled as above) and *emergency* (books-vs-balance failure: PnL is skipped entirely and raw collateral returns pro-rata). A pair terminates exactly once, into exactly one mode; insurance LPs' withdrawal gates all open at termination.
