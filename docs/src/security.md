# Security & Status

> ⚠️ **Pre-audit, work in progress. Do not use with real funds.**

## Posture

- **No admin keys.** There is nothing to compromise — but also no one who can pause a bad deployment. The [termination paths](protocol/termination.md) are the only brakes, and anyone can pull them when their objective conditions hold.
- **Sequencer misconduct is bounded, not prevented**: bonds, volume caps, and [fraud proofs](protocol/sequencers.md) make censorship and stale-flag abuse provable and unprofitable.
- **Accounting is tamper-evident**: the insurance + deposits ledgers are reconciled against the actual USDC balance (0.1% tolerance) on every major state-changing flow — matching, liquidations, ADL, and exposure-bearing withdrawals; a mismatch freezes the market into pro-rata emergency withdrawal rather than letting anyone race the exit.
- **A standing white-hat budget**: 1% of every fee stream accrues to a bug-bounty address fixed at factory deployment.

## Testing

768 tests across 68 suites (`test/unit`, `test/integration`), including zero-sum accounting invariants, crisis-backstop scenarios (insurance drain, deficit, deep-insolvency haircuts), negative-path suites, and regression pins for previously fixed issues (funding double-count in ADL, Pass-A walk direction, SafeERC20 migration against silently-failing tokens). CI runs `forge fmt --check`, build, and the full suite on every push.

## Known open items

Tracked for transparency; all pre-mainnet blockers:

- Open findings from the internal security review are tracked in `SECURITY_AUDIT.md` at the repo root, kept current as remediations land.
- Quantitative line coverage is currently unmeasurable — `forge coverage` fails with stack-too-deep even at `--ir-minimum` — so coverage gaps are audited manually in `TEST_COVERAGE_AUDIT.md` at the repo root.

## Reporting

Until a formal bug-bounty program exists, report vulnerabilities privately to the maintainer rather than opening a public issue.
