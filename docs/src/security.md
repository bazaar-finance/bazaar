# Security & Status

> ⚠️ **Pre-audit, work in progress. The protocol is not yet deployed — there is no official deployment on any network. Do not use with real funds.**

## Posture

- **No admin keys.** There is nothing to compromise — but also no one who can pause a bad deployment. The [termination paths](protocol/termination.md) are the only brakes, and anyone can pull them when their objective conditions hold.
- **One governed parameter, and it is the loudest one**: the UMA identifier assertions are adjudicated under. It moves only through a $5,000-bonded assertion, a 2-day dispute window, a whitelist re-check, and a 14-day activation timelock users can exit during — and while it is off UMA's live whitelist, listings and UMA terminations [fail closed](protocol/listing.md#the-only-governance-swapping-the-uma-identifier) rather than entering an undisputable pipeline. `BazaarFactory.umaIdentifierIsLive()` is the one-call monitoring endpoint; alarm when it turns false.
- **Matching fairness is structural, not promised**: the order book lives on-chain, sorted, and [matching happens on arrival](protocol/matching.md) — price-time priority and every fill price are enforced by the contract itself. No trusted matcher exists to censor, front-run, or misprice anyone.
- **Accounting is tamper-evident**: the insurance and deposits ledgers plus the unclaimed fee escrow are reconciled against the actual USDC balance (0.1% tolerance) on every major state-changing flow — matching, liquidations, ADL, and exposure-bearing withdrawals; a mismatch fixes the settlement price and freezes the market; finalize then pays principal pro-rata on the cash actually held rather than letting anyone race the exit.
- **A white-hat budget that starts accruing at launch**: 1% of every fee stream is skimmed into the claimable balance of a bug-bounty address fixed at factory deployment. Nothing has accrued yet — the protocol is not deployed and charges no fees.

## Testing

The suite (`test/unit`, `test/integration`) includes zero-sum accounting invariants, crisis-backstop scenarios (insurance drain, deficit, deep-insolvency haircuts), negative-path suites, and targeted pins on the accounting edges that are easiest to get wrong — funding accrual through the ADL path, the unload walk's price band, and silently-failing ERC-20s. CI pins Foundry to v1.4.3 and runs `forge fmt --check`, build, and the full suite on every push; EIP-170 limits are enforced as a test (`test/unit/ContractSizeTest.t.sol`) over production contracts only.

## Reporting

- **Reporting a vulnerability**: please use GitHub's private vulnerability reporting — go to the [Security tab](https://github.com/bazaar-finance/bazaar/security/advisories/new) and select *Report a vulnerability*. Do not open a public issue for security findings.
- **No bug-bounty program at this stage.** Valid findings are credited to the reporter in the published advisory. A retroactive reward may be considered for significant findings once the project is funded, but none is promised or guaranteed. The 1% fee skim above is future funding for a program that does not exist yet — it holds nothing and can pay nothing.
- **Scope and triage**: [`SECURITY.md`](https://github.com/bazaar-finance/bazaar/blob/master/SECURITY.md) in the repository lists what is in scope, what is out of scope, and what makes a report actionable. Reports are triaged on a best-effort basis by a small team; no response time is guaranteed.
