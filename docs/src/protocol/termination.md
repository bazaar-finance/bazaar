# Termination & Settlement

Perpetuals on real-world assets need an exit ramp: feeds get decommissioned, companies get acquired, assets redenominate. Every Bazaar market can be wound down **without anyone's permission** — five independent paths, each ending with positions cash-settled at a defined price and withdrawals open forever after.

## The five paths

| Path | Trigger | Gate |
|---|---|---|
| **Scheduled** (UMA) | A known *future* cessation: delisting, oracle decommission, structural change (splits, spinoffs, special dividends > 5%, redenominations), or Pyth contract migration | $1,000 bond, 12 h UMA liveness; `lastTradingTs` must be ≥ 12 h (the liveness) in the future, so the cutoff can't land before the dispute window ends |
| **Post-cessation** (UMA) | The event *already happened* — proposer supplies only the cessation timestamp; UMA verifiers check the event and timestamp, and the pair settles at the on-chain-verified Pyth tick from that moment | $1,000 bond, 72 h liveness (acceptance halts the market instantly, so scrutiny precedes approval); the timestamp must be in the past and **no more than 7 days old** (`MAX_CESSATION_LOOKBACK`) |
| **Stale oracle** | No Pyth update for **21 days** — objectively provable on-chain, no UMA needed | none; anyone |
| **Insurer vote** | Matured insurance shares voting yes reach **60%** of the total-share snapshot taken at proposal, within 7 days | $500 bond (forfeited to the fund if the vote fails); 7-day share maturity to vote; 7-day execution window; 14-day proposal cooldown |
| **Autonomous** | Realized bad debt (`deficit > 0`), ADL timeout (24 h), or books-vs-balance shortfall | none — self-executing inside the health check |

The autonomous path fixes the settlement price at the live price mid-transaction and opens the same settlement window as every other path, rather than terminating on the spot. Freezing withdrawals instantly is precisely what the insolvency check needs, and routing through the window means those positions get the same per-user settlement as a planned wind-down. The one exception is a books-vs-balance shortfall with no usable price, which goes straight to *emergency* termination (raw collateral, pro-rata, no window).

Market-driven price moves are explicitly *not* valid termination grounds — anticipated volatility is tradeable risk, not a structural event.

## Settlement price discipline

Both UMA paths converge on the same settlement machinery: acceptance freezes the pair's price feed at `lastTradingTs` (for post-cessation a timestamp already in the past, so trading halts immediately) and the pair then settles at the **Pyth tick closest to cessation** — a signed historical update in `[ts − 2 s, ts]`, verified on-chain, never a number typed into the proposal. For the first 3 hours — measured from the *later* of `lastTradingTs` and UMA acceptance — only that genuine tick is accepted (bad or empty data cannot force a fallback while a real tick may exist); after the grace, it falls back to the frozen last stored price so a market can never strand un-terminated. Trading and matching halt past the scheduled timestamp; once the price is fixed, the live liquidation engine is off entirely and positions change only through settlement at that frozen price.

Binding the price to a signed Pyth tick stops a proposer *inventing* a number, but on the post-cessation path they still choose *which* historical tick is read. That is why the cessation timestamp is capped at `MAX_CESSATION_LOOKBACK` (7 days): without it, a proposer holding a position could scan the asset's entire price history for the print that settles most favourably, and UMA voters would have to judge "is this the right moment?" against an unbounded search space. Inside the window, voters need only check placement against a cessation event they can still verify from public sources — and a timestamp that sits far from that event, or looks selected for price rather than accuracy, is grounds to dispute. A genuinely older cessation terminates through the stale-price path instead.

The non-UMA paths pin their price at execution instead: an insurer-vote termination settles at a fresh oracle tick (≤ 2 s old) supplied with the execute call, and a stale-oracle termination at the newest confidence-cleared price the oracle still serves — falling back to the pair's last stored price when even that read fails, with the 21-day staleness gate enforced either way.

The proposer of a successful UMA termination earns 0.1% of the pair's insurance fund (capped $100) — a bounty for noticing dead markets. Both UMA paths quote their bond from `requiredTerminationBond()` rather than the $1,000 constant: UMA derives its own minimum from an owner-settable final fee, so the constant is a floor that tracks upward.

## Proposer-supplied text

Both UMA proposals take two free-text arguments — `proposeTermination(pair, pairDescription, lastTradingTs, reason)` and `proposePostCessationTermination(pair, pairDescription, priceTimestamp, reason)` — that end up inside the claim UMA voters read. Because the claim is the entire basis on which a human decides to dispute, that text is treated as hostile input:

- **Length**: `reason` ≤ 1,000 bytes, `pairDescription` ≤ 100 bytes; neither may be empty.
- **Charset**: `pairDescription` allows letters, digits, space, and `. , & / -`. `reason` allows the same set plus `: ? = # % _ ~ +` so evidence URLs survive. Every other byte — including all non-ASCII, and **square brackets in both fields** — is rejected at submission.
- **Placement**: the contract writes every field and instruction block itself, then splices `reason` last, between square-bracket fences that label it untrusted proposer text and mark where it ends. The charset is what makes those fences unforgeable, so the colon the URL set re-admits is defused structurally: no proposer string can close the fence, resume the contract's voice, or add a criterion.

The listing claim applies the [same discipline](listing.md) to its `description`.

## The 48-hour settlement window

Every non-emergency path is **two-stage**. The terminator first *fixes* the settlement price (`fixSettlementPrice`), which opens a **48-hour settlement window**; only after it elapses can anyone call `finalizeTermination`. Trading, orders, ADL, deposits, and **all** withdrawals (collateral and insurance alike) are frozen for the duration, so nobody exits ahead of the accounting.

The window exists to do one job: **mark every open position to the final price before anyone is paid.** During it, `liquidate()` becomes the settlement entry point — anyone may pass a list of addresses, with no price update and no ETH, because the settlement price is already fixed (this is what makes it work on dead feeds). Settling is pure accounting and harmless to the target: it needs no solvency threshold at all, because marking a position at a price that will never change cannot alter what its owner is owed.

Each settled position does one of two things:

- **A loser's** realized loss is deducted from their collateral and **released from the principal ledger**, which is what funds winners' profits. Any loss exceeding their collateral is registered as **bad debt**.
- **A winner's** profit is registered as a **claim** — the per-user figure that makes a correct pro-rata payout computable at all.

Settling pays the caller a bounty of `max($0.10, 2 bp of notional)`, charged **to the settled position itself** — debited from whatever collateral it has left once its own PnL is booked, exactly like every other fee in the protocol. Winners and losers are treated identically, and each pays only for its own settlement. Because the debit hits the bucket and the principal ledger in the same step, the cash leaving is always backed by that ledger reduction: a bounty can never reach another user's reserved principal. A winner whose remaining collateral falls short of the bounty pays the difference out of its registered claim — transferred to the settler *as a claim*, not cash, so the pot and the total claims are both unchanged and the frozen ratio every other winner receives is untouched; the settler collects it at the same pro-rata terms after finalize. Only a position with neither collateral nor claim left falls to the insurance fund — so the incentive to settle survives exactly the scenario where it matters most, a drained fund in a deep insolvency.

Why any of this is necessary: liquidation only fires on observed live ticks, but termination events are precisely discontinuities — delistings, mergers, feed deaths. A position that gaps from healthy to deeply insolvent on the final print was never liquidatable at that price. Without a settlement pass, its bad debt is invisible, and winners get promised 100% of a pot that cannot pay them — a first-come-first-served drain.

## The settlement waterfall

At `finalizeTermination` the pair computes, once and for all:

1. **Bad debt is charged to the insurance fund**, shrinking the insurers' remainder.
2. The **profit ratio is frozen** from the cash actually held:

   `profitRatio = min(100%, surplus / total registered claims)`, where `surplus = USDC balance − principal ledger − insurers' remainder`.

3. **Black-swan backstop:** in the impossible case that cash cannot even cover the principal ledger, principal itself is haircut pro-rata against the pot.

Withdrawals then pay **principal + claim × frozen ratio**. Two properties follow:

- **Principal is reserved at every moment**, with no deadline. Your deposit, minus your own trading losses, is never at risk from someone else's bankruptcy — and it doesn't expire if you never show up.
- **Profit shortfalls are shared at one uniform percentage** across every registered winner, regardless of who withdraws first.

Deriving the ratio from the real USDC balance rather than from netted per-side aggregates is deliberate: a net figure can read near-zero on an internally hedged side, where a trivial shortfall would wipe out every winner's profit. Anchoring on cash also folds in any drift automatically.

A user who was never settled during the window is not stranded: their first withdrawal settles them inline, paying principal plus a junior profit credit clipped to whatever surplus remains. Settlement also stays open **forever** after finalize, so a late-discovered loss keeps releasing reserved principal into the surplus.

Two terminal modes exist: *normal* (as above) and *emergency* (books-vs-balance failure: PnL is skipped entirely and raw collateral returns pro-rata, with no window). A pair terminates exactly once, into exactly one mode; insurance LPs' withdrawal gates open at finalize.

> **Note on inherited inventory.** When the vault holds liquidation estates at termination, they settle for their full entry→settlement value **including the funding leg** — matching how the same estates settle on every other path. Dropping that leg would let the estates' funding obligation vanish while their counterparties still collected theirs.
