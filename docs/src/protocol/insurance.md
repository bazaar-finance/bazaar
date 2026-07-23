# Insurance Fund

Each pair has its own insurance fund, held inside the pair contract and owned by **share-based LPs** — anyone can capitalize any market and earn its fee flow. There is no protocol-wide fund: a meme-coin market's blowup cannot touch the ETH market's backstop.

## Flows

**In:** maker + taker insurance [fees](fees.md) · seized liquidatee collateral · vault unwind profits · slashed sequencer bonds · forfeited termination bonds · the listing seed (≥ $3,000)

**Out:** vault unwind losses · ADL winner credits · liquidation keeper rewards · ADL executor rewards · UMA termination-proposer rewards

Losses beyond the fund become `deficit` — realized bad debt — which [terminates the pair](termination.md). The fund is the last cushion before winners get haircut.

## Target sizing

The fund's target is **2%–10% of open interest**, interpolated on the same volatility EMA that drives margin, and floored at 3× the realized liquidation-gap EMA. The taker insurance fee then steers the fund toward target: sharply higher when underfunded, discounted to zero when at 2× target. Risk-*reducing* fills pay at most the base closing fee (keeping any surplus discount) — deleveraging is never punished.

## LP mechanics

| Rule | Value |
|---|---|
| Minimum deposit | $5 |
| Share pricing | `fund / totalShares`; first deposit 1:1. A fund wiped below $1 by bad debt starts a new **share epoch** on the next deposit: pre-drain balances lazily read as zero (that stake truly went to zero) and the rescuer is minted 1:1 against only their own contribution. Fund value left with no live LPs is priced into permanently locked shares at `address(0)`, so a new depositor can't buy the pre-existing buffer for the price of their deposit |
| Withdrawal | two-step: request → **20-day cooldown** → **3-day execution window** |
| Rate limit (below target) | 0.5% of OI notional per 6-hour period — one cumulative budget shared by all LPs, so Sybil-splitting doesn't help |
| Rate limit (above target) | max(1% of OI, 10% of fund) against the same 6-hour budget |
| Voting maturity | shares must be 7 days old to vote on insurer terminations; deposit lots are tracked 21 days as snipe-vote defense |
| Deposits | ≤ 100 per user per rolling 7 days |

Withdrawals are blocked while ADL is pending or a termination is scheduled — LPs cannot front-run the exact events they are paid to backstop. Shares committed to an active insurer-vote proposal are likewise locked until it resolves. Once a pair *is* terminated, every gate opens: LPs always have an exit after settlement.

Insurance LPs also hold a governance right: proposing and voting on [insurer-vote termination](termination.md) of their pair — the people with capital at risk can shut the market down.
