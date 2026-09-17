# Termination & Settlement

Perpetuals on real-world assets need an exit ramp: feeds get decommissioned, companies get acquired, assets redenominate. Every Bazaar market can be wound down **without anyone's permission** — four independent paths, each ending with positions cash-settled at a defined price and withdrawals open forever after.

## The four paths

| Path | Trigger | Gate |
|---|---|---|
| **Scheduled** (UMA) | A cessation event, announced or already occurred: delisting, oracle decommission, structural change (splits, spinoffs, special dividends > 5%, redenominations), or Pyth contract migration | $1,000 bond, 12 h UMA liveness; `lastTradingTs` must be ≥ 12 h (the liveness) in the future, so the cutoff can't land before the dispute window ends — an event that has already happened is proposed at that earliest cutoff |
| **Stale oracle** | No Pyth update for **21 days** — objectively provable on-chain, no UMA needed | none; anyone |
| **Insurer vote** | Matured insurance shares voting yes reach **60%** of the total-share snapshot taken at proposal, within 7 days | $500 bond (forfeited to the fund if the vote fails); 7-day share maturity to propose or vote, the listing seed included; 7-day execution window; 14-day proposal cooldown |
| **Autonomous** | Realized bad debt (`deficit > 0`), ADL timeout (24 h, plus a 30 min fresh-priced runway — see [ADL](adl.md)), or books-vs-balance shortfall | none — self-executing inside the health check |

The autonomous path fixes the settlement price at the live price mid-transaction and opens the same settlement window as every other path, rather than terminating on the spot. Freezing withdrawals instantly is precisely what the insolvency check needs, and routing through the window means those positions get the same per-user settlement as a planned wind-down. A books-vs-balance shortfall takes the same route: the missing cash simply shows up in the payout ratios at finalize.

Market-driven price moves are explicitly *not* valid termination grounds — anticipated volatility is tradeable risk, not a structural event.

## Settlement price discipline

Acceptance freezes the pair's price feed at `lastTradingTs` and the pair then settles at the **Pyth tick at the cutoff** — a signed historical update in `[ts − 2 s, ts]`, verified on-chain, never a number typed into the proposal. For the first 12 hours — measured from the *later* of `lastTradingTs` and UMA acceptance, because a disputed proposal can resolve at the DVM days after its cutoff has passed — only that genuine tick is accepted (bad or empty data cannot force a fallback while a real tick may exist); after the grace, it falls back to the frozen last stored price so a market can never strand un-terminated. The grace matches the proposal liveness because it answers the same question — how long an interested party needs to notice a termination and act — and it has to carry that alone: posting the tick costs gas plus the Pyth fee and pays nothing, while waiting the window out and calling with empty calldata costs only gas, so whichever side the stale mark favors has the cheaper action. It is not longer because limbo freezes withdrawals, matching and liquidation until the price is fixed; posting the tick ends limbo immediately, so the length only ever delays the fallback. Trading and matching halt past the scheduled timestamp; once the price is fixed, the live liquidation engine is off entirely and positions change only through settlement at that frozen price.

Binding the price to a signed Pyth tick stops a proposer *inventing* a number, and requiring the cutoff to sit at least the liveness in the future stops them *choosing* one: the price at `lastTradingTs` is unknown when the proposal is filed, so no historical print can be shopped. An event that has already happened — a feed that went dark, an asset already delisted — is proposed at the earliest cutoff the contract accepts; if the feed has no tick there, the pair settles once the grace elapses at its last stored price, the last fresh, confidence-checked print the pair itself recorded. A feed dead for more than 21 days can also be terminated through the stale-oracle path without any proposal.

The non-UMA paths pin their price at execution instead: an insurer-vote termination settles at a fresh oracle tick (≤ 2 s old) supplied with the execute call, and a stale-oracle termination at the pair's own last stored price — the oracle is read only as a liveness probe; the 21-day gate is enforced against the stored price's age, and against the probe's publish time as well whenever the oracle still answers.

The proposer of a successful UMA termination earns 0.1% of the pair's insurance fund (capped $100), credited to their claimable balance on the pair and withdrawn with `claimFees()` — a bounty for noticing dead markets. The bond is quoted from `requiredTerminationBond()` rather than the $1,000 constant: UMA derives its own minimum from an owner-settable final fee, so the constant is a floor that tracks upward.

## Proposer-supplied text

The UMA proposal takes two free-text arguments — `proposeTermination(pair, pairDescription, lastTradingTs, reason)` — that end up inside the claim UMA voters read. Because the claim is the entire basis on which a human decides to dispute, that text is treated as hostile input:

- **Length**: `reason` ≤ 1,000 bytes, `pairDescription` ≤ 100 bytes; neither may be empty.
- **Charset**: `pairDescription` allows letters, digits, space, and `. , & / -`. `reason` allows the same set plus `: ? = # % _ ~ +` so evidence URLs survive. Every other byte — including all non-ASCII, and **square brackets in both fields** — is rejected at submission.
- **Placement**: the contract writes every field and instruction block itself, then splices `reason` last, between square-bracket fences that label it untrusted proposer text and mark where it ends. The charset is what makes those fences unforgeable, so the colon the URL set re-admits is defused structurally: no proposer string can close the fence, resume the contract's voice, or add a criterion.

The listing claim applies the [same discipline](listing.md) to its `description`.

## The settlement window

Every path is **two-stage**. The terminator first *fixes* the settlement price (`fixSettlementPrice`), which opens the **settlement window**; `finalizeTermination` is allowed once **every position has been settled** at that price — the pair knows, because open interest reaches zero — or, as an escape hatch, **14 days** after the fix. Trading, orders, ADL, deposits, and **all** withdrawals (collateral and insurance alike) are frozen while the window is open, so nobody exits ahead of the accounting.

The window exists to do one job: **mark every open position to the final price before anyone is paid.** `liquidate()` becomes the settlement entry point — anyone may pass a list of addresses, with no price update and no ETH, because the settlement price is already fixed (this is what makes it work on dead feeds). Settling is pure accounting and harmless to the target: it needs no solvency threshold, because marking a position at a price that will never change cannot alter what its owner is owed. Settling someone else's position earns a **$0.10** tip (`TERMINAL_SETTLEMENT_TIP`), escrowed for `claimFees()` like every keeper reward: the settled position pays it from whatever collateral its settlement leaves it, charged like a trading fee, and insurance tops up what the collateral cannot cover. Settling your own position is free. One batched call clears a book.

Each settled position does one of two things:

- **A loser's** realized loss is deducted from their collateral. Any loss exceeding their collateral is tallied as **bad debt**.
- **A winner's** profit is registered as a **claim**, the per-user figure paid at the frozen profit ratio.

Neither touches the deposits ledger. That is deliberate: the ledger obeys an identity the live protocol maintains at every step — the sum of every bucket's collateral, plus the open positions' unrealized PnL, plus the value of the vault's inherited inventory, equals the ledger plus any pre-termination deficit — and finalize derives what traders are owed from that identity. It holds only while settlement leaves the ledger alone.

Why any of this is necessary: liquidation only fires on observed live ticks, but termination events are precisely discontinuities — delistings, mergers, feed deaths. A position that gaps from healthy to deeply insolvent on the final print was never liquidatable at that price. Without a settlement pass, its bad debt is invisible, and winners get promised 100% of a pot that cannot pay them — a first-come-first-served drain.

Gating finalize on completeness rather than on a clock is what makes the payout exact, and the gate cannot be held hostage: nobody can withdraw until finalize, settling is permissionless and tipped, the order of settlement cannot change anyone's outcome, and settlement cannot revert for a position that exists. Every open position is a paying target for a keeper, and every winner with a payout waiting has a second reason to sweep the whole book rather than just their own position: a bankrupt position settled before finalize has its shortfall booked before the ratios are frozen, so it is charged to the insurers' residual, and shared across every registered winner at one ratio if that runs out, instead of landing on whoever withdraws last. The 14-day escape hatch only bounds the case where nobody settles at all.

## The settlement waterfall

At `finalizeTermination` the pair computes, once and for all:

1. **The total owed to traders**, from the ledger identity. With every position settled the unrealized term is zero, so `owed = ledger + deficit + bad debt − inventory value at the settlement price`: the sum of every bucket's collateral plus every registered claim, without summing over accounts. The vault's inherited inventory is retired here — its loss is its counterparties' gain and its gain their loss, both already inside the buckets and claims.
2. **The pot**: the USDC balance less the fee escrow.
3. **Two frozen ratios.** Principal is senior: if the pot covers `owed − claims`, the principal ratio is 100% and the profit ratio is `min(100%, (pot − principal) / claims)`. If cash cannot even cover principal — only a books-vs-balance gap gets there — principal is paid pro-rata on the pot and profits pay nothing.
4. **The insurance fund becomes the residual**: the pot less everything reserved for traders.

Withdrawals then pay **collateral × principal ratio + claim × profit ratio**. Three properties follow:

- **Principal is reserved at every moment**, with no deadline. Your deposit, minus your own trading losses, is never at risk from someone else's bankruptcy — and it doesn't expire if you never show up.
- **Insurance is junior to every trader.** Because the fund is whatever remains after traders are paid, it absorbs bad debt, the pre-termination deficit and the inventory's loss before any winner is cut, and inherits the inventory's gain — whether or not each item was tallied.
- **Profit shortfalls are shared at one uniform percentage** across every registered winner, regardless of who withdraws first.

If finalize ran through the escape hatch, a position it did not wait for settles on its owner's first withdrawal (or when anyone settles it through `liquidate`). Its equity was already inside the total owed at collateral plus PnL, so a solvent position realizes to exactly that figure; a bankrupt one was counted below zero, so the insurers' residual funds its shortfall as far as it goes, and that funded amount moves into the ledger. Whatever the residual cannot fund is never credited to the ledger — the books never claim cash the pot does not hold — and leaves the last withdrawals short by that amount, the case the completeness gate exists to prevent. Settling a bankrupt straggler after finalize earns the settler the same tip, from whatever residual its shortfall left (all-or-nothing); a solvent straggler pays none, since finalize already reserved its equity in full and settling it harms nobody.

Insurers cannot exit ahead of that settlement. After an escape-hatch finalize, `executeInsuranceWithdrawal` reverts (`InsuranceVaultLib__SweepIncomplete`) while any position is still open, until **14 days** beyond the escape hatch (`INSURER_SWEEP_GRACE`, so 28 days after the fix at the latest). Settling is permissionless, so an LP releases the gate by settling the remaining positions themselves, collecting the tip on any bankrupt one — an indexer lists them from `PositionBucketUpdated` events; the grace only bounds the case where nobody does.

A pair terminates exactly once; insurance LPs' withdrawal gates open at finalize — after an escape-hatch finalize, once the remaining positions are settled or the grace elapses — and their shares redeem against the residual. Finalize retires the vault's inventory and releases the collateral earmarked against it in the same step, so the residual is redeemable in full: with no inventory left to value, [share pricing](insurance.md) collapses to the residual over the supply, reads no mark, and needs no price update.

> **Note on inherited inventory.** The inventory is valued at the settlement price from the liquidated traders' original entry, **including the funding leg** — matching how the coverage ratio and the ADL gate value it. Dropping that leg would let the inventory's funding obligation vanish while its counterparties still collected theirs.
