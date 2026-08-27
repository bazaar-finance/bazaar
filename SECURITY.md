# Security Policy

> ⚠️ **Pre-audit, work in progress. The protocol is not yet deployed — there is no official
> deployment on any network. Do not use with real funds.**

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting: go to the
[Security tab](https://github.com/bazaar-finance/bazaar/security/advisories/new) and select
*Report a vulnerability*. **Do not open a public issue for security findings.**

A useful report names the affected contract and function, the conditions the attack needs, and what
an attacker gains. A failing Foundry test against this repository is the clearest possible form of
proof, and the fastest way to get a finding confirmed.

Reports are triaged on a best-effort basis by a small team. No response time is guaranteed.

## What reporters can expect

- **There is no bug-bounty program at this stage.** Valid findings are credited to the reporter in
  the published advisory. A retroactive reward may be considered for significant findings once the
  project is funded, but none is promised or guaranteed.
- The contracts do carry an on-chain white-hat budget: 1% of every fee stream is skimmed to a
  bug-bounty address fixed at factory deployment (`BUG_BOUNTY_TAX_BP`). Nothing has accrued and
  nothing can be paid from it — the protocol is not deployed and charges no fees. Treat it as
  future funding for a program that does not exist yet, not as a bounty you are reporting into.
- Please give us a reasonable window to publish an advisory before disclosing publicly. Nothing is
  deployed, so no user funds are at risk today; that changes the moment a deployment exists.

## Scope

**In scope** — the protocol source and the tooling that deploys it:

- `src/` — pair, factory, sequencer, oracle, terminator, lens, and all libraries
- `script/` — deployment scripts and network configuration
- The documented protocol invariants: zero-sum accounting, solvency and margin math, the matching
  engine's three passes, funding accrual, liquidation and ADL pricing, the insurance waterfall, the
  termination and settlement paths, listing gating, and the sequencer fraud proofs

**Out of scope:**

- Third-party dependencies — Pyth, UMA, OpenZeppelin, forge-std. Report those upstream. A finding
  about *how Bazaar integrates* them is in scope; a finding *inside* them is not.
- Test-only contracts, mocks, and harnesses under `test/`
- Gas optimizations, style, and documentation typos with no security consequence
- Findings that assume a privileged role the protocol does not have — see below

## Posture

Read this before reporting; it rules out a class of findings that do not apply here.

- **No admin keys.** No owner, no pauser, no upgradeable proxies, no governance token. There is
  nothing to compromise — but also no one who can pause a bad deployment, and no upgrade path for a
  bug found after launch. The [termination paths][termination] are the only brakes, and anyone can
  pull them when their objective conditions hold. Reports premised on a compromised admin, a
  malicious owner, or a missing pause switch are out of scope by construction.
- **One governed parameter**, and it is the loudest one: the UMA identifier that assertions are
  adjudicated under. It moves only through a bonded assertion (at least $5,000,
  `IDENTIFIER_UPGRADE_BOND_USDC`), a 2-day dispute window (`IDENTIFIER_UPGRADE_LIVENESS`), a
  whitelist re-check, and a 14-day activation timelock (`IDENTIFIER_UPGRADE_TIMELOCK`) users can
  exit during. While the identifier is off UMA's live whitelist, listings and UMA terminations fail
  closed rather than entering an undisputable pipeline. `BazaarFactory.umaIdentifierIsLive()` is the
  one-call monitoring endpoint.
- **Sequencer misconduct is bounded, not prevented.** Bonds, volume caps, and
  [fraud proofs][sequencers] are designed to make censorship and stale-flag abuse provable and
  unprofitable — not impossible. A report showing misconduct that is *profitable* or *unprovable*
  is squarely in scope.
- **Accounting is tamper-evident.** The insurance and deposits ledgers are reconciled against the
  actual USDC balance (0.1% tolerance, `USDC_BALANCE_TOLERANCE_BP`) on every major state-changing
  flow — matching, liquidations, ADL, and exposure-bearing withdrawals. A mismatch freezes the
  market into pro-rata emergency withdrawal rather than letting anyone race the exit.
- **Unaudited.** This codebase has not undergone a professional audit. Assume undiscovered bugs.

Full posture and testing detail: [Security & Status][security] in the book.

## Supported versions

There are no releases and no deployments. Only the current `master` branch is in scope; there is
nothing older to support.

| Version  | Supported |
| -------- | --------- |
| `master` | ✅        |

[termination]: https://docs.bazaar.finance/protocol/termination.html
[sequencers]: https://docs.bazaar.finance/protocol/sequencers.html
[security]: https://docs.bazaar.finance/security.html
