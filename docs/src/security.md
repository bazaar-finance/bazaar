# Security & Status

> ⚠️ **Pre-audit, work in progress. The protocol is not yet deployed — there is no official deployment on any network. Do not use with real funds.**

## Posture

- **No admin keys.** There is nothing to compromise — but also no one who can pause a bad deployment. The [termination paths](protocol/termination.md) are the only brakes, and anyone can pull them when their objective conditions hold.
- **One governed parameter, and it is the loudest one**: the UMA identifier assertions are adjudicated under. It moves only through a $5,000-bonded assertion, a 2-day dispute window, a whitelist re-check, and a 14-day activation timelock users can exit during — and while it is off UMA's live whitelist, listings and UMA terminations [fail closed](protocol/listing.md#the-only-governance-swapping-the-uma-identifier) rather than entering an undisputable pipeline. `BazaarFactory.umaIdentifierIsLive()` is the one-call monitoring endpoint; alarm when it turns false.
- **Sequencer misconduct is bounded, not prevented**: bonds, volume caps, and [fraud proofs](protocol/sequencers.md) make censorship and stale-flag abuse provable and unprofitable.
- **Accounting is tamper-evident**: the insurance + deposits ledgers are reconciled against the actual USDC balance (0.1% tolerance) on every major state-changing flow — matching, liquidations, ADL, and exposure-bearing withdrawals; a mismatch freezes the market into pro-rata emergency withdrawal rather than letting anyone race the exit.
- **A standing white-hat budget**: 1% of every fee stream accrues to a bug-bounty address fixed at factory deployment.

## Testing

844 tests across 74 suites (`test/unit`, `test/integration`), including zero-sum accounting invariants, crisis-backstop scenarios (insurance drain, deficit, deep-insolvency haircuts), negative-path suites, and targeted pins on the accounting edges that are easiest to get wrong — funding accrual through the ADL path, the Pass-A walk direction, and silently-failing ERC-20s. CI pins Foundry to v1.4.3 and runs `forge fmt --check`, build, and the full suite on every push; EIP-170 limits are enforced as a test (`test/unit/ContractSizeTest.t.sol`) over production contracts only.

## Reporting

Until a formal bug-bounty program exists, report vulnerabilities by opening an issue in the [GitHub repository](https://github.com/bazaar-finance/bazaar/issues).
