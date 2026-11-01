# Bazaar v1 — Audit Scope

## 1. Overview

Bazaar is an immutable, permissionless perpetual-futures protocol for Arbitrum One. Each market is
an EIP-1167 clone of `BazaarPair` that holds an on-chain sorted order book, matches orders on
arrival with price-time priority, margins positions in USDC against Pyth prices, and backs its own
liquidations with a per-pair insurance vault, auto-deleveraging (ADL) as the last resort. Anyone can
list a market through a bonded UMA Optimistic Oracle V3 assertion, and every market can be wound
down to cash through one of four termination paths. There is no owner, no pauser and no upgrade
path; the one governed value is the UMA identifier assertions are adjudicated under.

Specification (the docs book):

| Topic | Page |
|---|---|
| Architecture, ledgers, code-size split | https://docs.bazaar.finance/protocol/architecture.html |
| Orders | https://docs.bazaar.finance/protocol/orders.html |
| Arrival matching | https://docs.bazaar.finance/protocol/matching.html |
| Margin and leverage | https://docs.bazaar.finance/protocol/margin.html |
| Funding | https://docs.bazaar.finance/protocol/funding.html |
| Liquidations and the vault unload | https://docs.bazaar.finance/protocol/liquidations.html |
| Auto-deleveraging | https://docs.bazaar.finance/protocol/adl.html |
| Insurance fund | https://docs.bazaar.finance/protocol/insurance.html |
| Fees and pull payments | https://docs.bazaar.finance/protocol/fees.html |
| Price oracle | https://docs.bazaar.finance/protocol/oracle.html |
| Listing and UMA governance | https://docs.bazaar.finance/protocol/listing.html |
| Termination and settlement | https://docs.bazaar.finance/protocol/termination.html |
| Gasless (relayed) transactions | https://docs.bazaar.finance/protocol/meta-transactions.html |
| Parameters | https://docs.bazaar.finance/reference/parameters.html |
| Security posture | https://docs.bazaar.finance/security.html |

The same pages are in the repository under `docs/src/`. Where the code and the docs disagree, treat
the disagreement as a finding.

## 2. Frozen target

| Item | Value |
|---|---|
| Repository | https://github.com/bazaar-finance/bazaar |
| Tag | `v1.0.0-rc1` |
| Commit | `182d354c01458bbcda8db5ce67a177520048d787` |
| Target chain | Arbitrum One (chain id 42161) |
| Compiler | solc 0.8.34 |
| Optimizer | on, `optimizer_runs = 150` for every contract |
| Codegen | `via_ir = true` (required: `BazaarPair` exceeds the stack limit under legacy codegen) |
| EVM version | `cancun` (the bytecode uses `MCOPY` and transient storage) |
| Test-only setting | `dynamic_test_linking = true`; deployed bytecode is byte-identical with it on or off |
| Dependencies | OpenZeppelin Contracts 5.4.0 (`lib/openzeppelin-contracts`), Pyth SDK `@pythnetwork/pyth-sdk-solidity` 4.2.0 (npm), forge-std 1.9.7; UMA's `lib/protocol` is used by one test only |

The line counts in section 3, the link table below and the test count in section 10 were all
taken at this commit.

### Deployment shape

- `BazaarFactory` deploys each market as an EIP-1167 clone (`Clones.clone`) of one `BazaarPair`
  implementation. The implementation's constructor calls `_disableInitializers()`; each clone is
  initialized once through `initialize`.
- `BazaarOracle` (Pyth adapter and composite-feed registry), `BazaarPairTerminator` and
  `BazaarPairLens` are protocol-wide singletons.
- Arbitrum One dependency addresses, as configured in `script/HelperConfig.s.sol`: Pyth
  Core `0xff1a0f4744e8582DF1aE09D5611b887B6a12925C`, native USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`, UMA OptimisticOracleV3
  `0xa6147867264374F324524E30C02C331cF28aa879`.

### Externally linked libraries

Twelve libraries hold external or public functions and are deployed once, then linked by address
(`script/LinkedLibraries.sol` is the single list; `script/DeployLibraries.s.sol` deploys them in
dependency order). Their code runs by `DELEGATECALL` in the caller's storage context. The link
graph below follows the calls to each library's external and public functions in the source.

| Library | Linked by |
|---|---|
| `MatchingEngineLib` | `BazaarPair` |
| `OrderManagementLib` | `BazaarPair` |
| `CollateralLib` | `BazaarPair` |
| `LiquidationLib` | `BazaarPair` |
| `AdlLib` | `BazaarPair` |
| `InsuranceVaultLib` | `BazaarPair` |
| `FundingLib` | `BazaarPair` |
| `TerminationLib` | `BazaarPair` |
| `MetaTxLib` | `BazaarPair` |
| `VaultHealthLib` | `BazaarPair` |
| `RiskParamsLib` | `BazaarPair`, and the libraries `AdlLib`, `InsuranceVaultLib`, `MatchingEngineLib`, `TerminationLib`, `VaultHealthLib` |
| `ClaimTextLib` | `BazaarFactory`, `BazaarPairTerminator` |

`BazaarOracle` and `BazaarPairLens` link no library. `BazaarTypes`, `OrderBookLib`, `BucketLib`,
`MmrSampleLib`, `FeeEscrowLib` and `BazaarMathLib` are internal libraries, inlined into their
callers.

## 3. Files in scope

Counts are non-blank, non-comment lines (natspec included in "comment"), computed per file by a
tokenizer that skips `//` comments and `/* */` blocks and does not mistake `//` inside a string
literal for a comment.

### Tier 1 — full scope (21 files, 9,903 lines)

| File | Lines | Role |
|---|---:|---|
| `src/BazaarPair.sol` | 1,256 | Market contract: entry points, price resolution, vault-health verdict, termination glue |
| `src/BazaarPairTerminator.sol` | 961 | UMA, insurer-vote, scheduled and stale-oracle termination paths |
| `src/BazaarFactory.sol` | 574 | UMA-gated listing, identifier governance, clone deployment |
| `src/BazaarOracle.sol` | 377 | Pyth adapter, composite feeds, confidence and staleness rules |
| `src/libraries/MatchingEngineLib.sol` | 1,428 | Arrival walk, trigger execution, vault unload, per-fill margin checks, fees |
| `src/libraries/AdlLib.sol` | 1,113 | ADL batches, deferred liquidations, winner closes, executor rewards |
| `src/libraries/RiskParamsLib.sol` | 725 | Margin curve, insurance target, reserve, unload planner, fund-ledger helpers, bounties |
| `src/libraries/OrderManagementLib.sol` | 632 | Order creation, cancel, amend, expiry sweep; the creation and amendment margin gates |
| `src/libraries/CollateralLib.sol` | 607 | Deposits, withdrawals, books-vs-cash check, fee claims, terminal settlement, resting-order tally |
| `src/libraries/BazaarTypes.sol` | 523 | Structs, constants, events |
| `src/libraries/InsuranceVaultLib.sol` | 397 | Insurance shares, deposits, forward-priced redemptions, rate limits |
| `src/libraries/LiquidationLib.sol` | 370 | Seizure, netting against the vault inventory, deferral, rewards |
| `src/libraries/OrderBookLib.sol` | 218 | Sorted doubly-linked book lists, in-place rewrite of a resting order |
| `src/libraries/FundingLib.sol` | 212 | Mark tallies and funding-index accrual |
| `src/libraries/TerminationLib.sol` | 112 | Finalize: total owed, payout ratios |
| `src/libraries/BucketLib.sol` | 99 | Position solvency math |
| `src/libraries/VaultHealthLib.sol` | 68 | Liquidation-exposure (ADL gate) check |
| `src/libraries/MetaTxLib.sol` | 67 | EIP-712 relayed calls, nonces |
| `src/libraries/MmrSampleLib.sol` | 66 | Lagged-MMR ring buffer |
| `src/libraries/BazaarMathLib.sol` | 62 | Fixed point, exponent conversion |
| `src/libraries/FeeEscrowLib.sol` | 36 | Claimable-balance escrow for every third-party payout |
| **Total** | **9,903** | |

### Tier 2 — riskiest subset for a competition (12 files, 6,730 lines)

| File | Lines |
|---|---:|
| `src/libraries/MatchingEngineLib.sol` | 1,428 |
| `src/libraries/AdlLib.sol` | 1,113 |
| `src/BazaarPairTerminator.sol` | 961 |
| `src/libraries/RiskParamsLib.sol` | 725 |
| `src/libraries/OrderManagementLib.sol` | 632 |
| `src/libraries/CollateralLib.sol` | 607 |
| `src/libraries/InsuranceVaultLib.sol` | 397 |
| `src/libraries/LiquidationLib.sol` | 370 |
| `src/libraries/OrderBookLib.sol` | 218 |
| `src/libraries/TerminationLib.sol` | 112 |
| `src/libraries/BucketLib.sol` | 99 |
| `src/libraries/VaultHealthLib.sol` | 68 |
| **Total** | **6,730** |

This covers the matching engine and order management, liquidation and ADL, the insurance vault, the
termination lifecycle, collateral accounting with the resting-order tally, and the risk library
those paths call into:
`RiskParamsLib` holds the unload planner (`planUnload`, `unloadRewardPayable`), the fund-ledger
helpers (`fundLedgerFrom`, `bankruptcyCloseCost`, `redemptionHeadroom`, `vaultAdlExposure`), the ADL
reserve (`adlReserve`) and the margin curve (`calculateIMRandMMR`, `liquidationImrBp`).
`BazaarPair`, `FundingLib` and `BazaarTypes` are required reading for it, since the tier's files are
called from the pair.

### Out of scope (6 files, 1,129 lines)

| File | Lines | Reason |
|---|---:|---|
| `src/BazaarPairLens.sol` | 850 | Read-only views for frontends and keepers. No contract calls it on-chain: the factory stores its address and reads `factory()` from it once in the constructor as a wiring check. Known limitation: `getMaxWithdrawable` does not reproduce the liquidation-exposure refusal a position holder's withdrawal can meet before an ADL window latches, as its natspec states. |
| `src/libraries/ClaimTextLib.sol` | 179 | Static UMA claim text (pure functions returning bytes); its correctness as prose matters to UMA verifiers, not to the contracts' state. |
| `src/interfaces/IUmaOptimisticOracleV3.sol` | 55 | Interface |
| `src/interfaces/IBazaarPair.sol` | 22 | Interface |
| `src/interfaces/IBazaarOracle.sol` | 19 | Interface |
| `src/interfaces/IArbSys.sol` | 4 | Interface |

Also out of scope: `script/`, `test/` (including mocks), `examples/`, `docs/`, and the dependencies
themselves (OpenZeppelin, Pyth SDK, UMA, forge-std). How Bazaar integrates its dependencies is in
scope, including whether the local interface `IUmaOptimisticOracleV3` matches the deployed oracle's
ABI, since the factory decodes `getAssertion` results to decide proposal outcomes.

All files: 27, 11,032 lines (9,903 in scope + 1,129 out of scope).

## 4. Build and test

### Requirements

- Foundry **v1.4.3**, the version CI pins (`.github/workflows/test.yml`, `foundry-rs/foundry-toolchain@v1`
  with `version: v1.4.3`). Later versions disagree with it on `forge fmt` rules.
- Node.js and npm: `foundry.toml` remaps `@pythnetwork/pyth-sdk-solidity/` into `node_modules/`.
- Git submodules (`lib/forge-std`, `lib/openzeppelin-contracts`, `lib/protocol`).

### Commands

```bash
git clone --recursive https://github.com/bazaar-finance/bazaar.git bazaar
```

```bash
git checkout v1.0.0-rc1
```

```bash
npm ci
```

```bash
foundryup --install v1.4.3
```

```bash
forge build
```

```bash
forge test -vvv
```

CI runs `forge fmt --check`, `forge build` and `forge test -vvv` on every push. It sets
`FOUNDRY_PROFILE=ci`; `foundry.toml` defines no `ci` profile, so forge resolves it to the default
settings above (same compiler, optimizer, via-IR and invariant settings). `make build` and
`make test` wrap the same commands.

### Build cost

`via_ir` is mandatory and the IR pipeline is bounded by solc's peak memory, not by CPU. A cold
build is one large solc process: plan for several GB of free RAM (8 GB or more is comfortable) and
tens of minutes. Incremental builds after a test-only edit are much faster because
`dynamic_test_linking` keeps library edits from recompiling the whole graph. Avoid running two cold
builds on one machine at once.

### Suites

| Suite | Command |
|---|---|
| Unit (`test/unit`) | `forge test --match-path "test/unit/*"` |
| Integration (`test/integration`) | `forge test --match-path "test/integration/*"` |
| Stateful invariants (handler-based) | `forge test --match-contract ZeroSumHandlerInvariantTest` |
| Zero-sum scenario suite | `forge test --match-contract ZeroSumInvariantTest` |
| EIP-170 size gate | `forge test --match-contract ContractSizeTest` |

`test/integration/ZeroSumHandlerInvariantTest.t.sol` drives a multi-actor handler (trading,
cancelling and amending resting orders, withdrawals against open positions, price moves,
liquidation, unloads, ADL, funding accrual) and checks five invariants: `invariant_zeroSum`,
`invariant_check3Solvency`, `invariant_openInterestMatchesPositions`,
`invariant_deferredListedOnlyInsideWindow` and `invariant_restingTallyNeverUnderstates`. The
`[invariant]` section of `foundry.toml` sets `runs = 64`, `depth = 160`, `fail_on_revert = false`;
raise them for a deeper campaign:

```bash
FOUNDRY_INVARIANT_RUNS=512 FOUNDRY_INVARIANT_DEPTH=320 forge test --match-contract ZeroSumHandlerInvariantTest
```

`test/integration/ZeroSumInvariantTest.t.sol` holds fixed scenarios (trade lifecycle, funding
accrual, liquidation and vault close, a vault whipsaw, seizures against a thin ledger, termination)
that assert the zero-sum identity at each step.

`test/unit/ContractSizeTest.t.sol` (`test_deployableContractsFitEip170`) enforces EIP-170 over the
production contracts and external libraries only; `forge build --sizes` would also fail on
test-only harnesses. `BazaarPair` and `MatchingEngineLib` sit close to the limit, so a fix that
grows either may need bytes found elsewhere; `forge build --sizes` shows the current margins.

## 5. Actors and privileges

**There is no owner, no pauser, no admin key and no upgrade path.** Markets are EIP-1167 clones of
one fixed implementation, every external address the contracts trust is immutable, and no function
lets any account change a fee, a risk parameter, an oracle or a payout rule. Every role below is
permissionless; the only access-controlled calls are between the protocol's own contracts and from
UMA's oracle (listed at the end).

| Actor | Entry points | Paid | Main limits |
|---|---|---|---|
| Trader (maker or taker) | `BazaarPair.depositCollateral`, `withdrawCollateral`, `createOrder`, `cancelOrders`, `amendOrders`, `claimFees` | Pays maker and taker fees (fees.md) | `MIN_ORDER_AMOUNT` and `MIN_COLLATERAL_AMOUNT` ($5); `MAX_ACTIVE_LIMIT_ORDERS_PER_USER` (32); `MAX_CANCELS_PER_CALL` (200); `MAX_AMENDS_PER_CALL` (32); IMR on worst-case exposure plus a cash floor while a position is open |
| Trigger keeper | `executeTriggeredOrders` (up to `MAX_TRIGGER_EXECS_PER_CALL`, 20) | The owner-chosen bounty, escrowed from the owner's wallet at creation and paid pro rata to what an execution fills | The bounty goes to the owner when the order's own creation walk executes it, or when an execution lands in the creation block of an order the stale fallback left unarmed |
| Liquidator | `liquidate` | `MIN_LIQUIDATOR_REWARD` ($0.05) per seized or deferred account, at most the account's equity below $5 of notional; a netting earns max($0.05, 2 bp of the overlap) (`LIQUIDATION_FEE_EBP`); the inline unload pays 2 bp on what it sells beyond that | Capped at insurance free capital; a stored price older than `MAX_LIQUIDATION_PRICE_AGE` (10 minutes) needs a fresh update |
| Vault unloader | `unloadVault` | 2 bp of unloaded notional, raised to `UNLOAD_BOUNTY_MIN` ($0.25) when at least `UNLOAD_BOUNTY_MIN_NOTIONAL` ($1,250) unloads or the inventory clears | Capped by `RiskParamsLib.unloadRewardPayable`; fills nothing and pays nothing on the stale fallback |
| Price refresher | `refreshPrice` | `REFRESH_BOUNTY` ($0.10) for a newer stored price | At most once per `REFRESH_BOUNTY_MIN_GAP` (5 minutes) while the vault holds at least $1,250 of inventory, otherwise once per `REFRESH_BOUNTY_HEARTBEAT` (1 day); only while free capital exceeds `REFRESH_BOUNTY_MIN_INSURANCE` ($5,000) |
| ADL executor | `executeAdl` (up to `MAX_ADL_WINNERS_PER_BATCH`, 25, per list) | For the inventory's own exposure closed (at most what the fund could not carry as the batch began, less every deferred account the batch absorbs), max(2 bp of the notional at the mark, `ADL_EXECUTOR_REWARD_BP` (0.1%) of the bad debt the close averts), nothing for units closed only so deferred accounts can be absorbed; per deferred account it seizes, max($0.05, 2 bp of what it retires) plus 0.1% of the bad debt its cohort close averts ($0.05 alone for one moved into the inventory) | Capped at free capital; refuses the stale fallback |
| Expiry janitor | `sweepExpired` | Nothing | |
| Terminal settler | `liquidate` once the settlement price is fixed (settlement mode, through `CollateralLib.settleTerminalPositions`), then `finalizeTermination` | `TERMINAL_SETTLEMENT_TIP` ($0.05) per position settled for someone else, from that position's collateral, topped up from insurance for positions of at least $5 | `finalizeTermination` runs once open interest is zero, or after `TERMINAL_SETTLEMENT_ESCAPE` (14 days) |
| Insurance LP | `depositToInsurance`, `requestInsuranceWithdrawal`, `executeInsuranceWithdrawal` | Taker insurance fees, forfeited bonds, inventory gains | `INSURANCE_WITHDRAWAL_COOLDOWN` (13 days), `INSURANCE_WITHDRAWAL_WINDOW_CONTINUOUS` / `INSURANCE_WITHDRAWAL_WINDOW_SESSION` (2 / 4 days, by the pair's trading calendar), forward-priced claim (`INSURANCE_WITHDRAWAL_CLAIM_DELAY`, `INSURANCE_WITHDRAWAL_REOPEN_CLAIM_DELAY`), per-period rate limits, headroom while inventory is held; junior to every trader at termination |
| Insurer voter | `BazaarPairTerminator.proposeInsurerTermination` (bond `TERMINATION_PROPOSAL_BOND`, $1,000; shares older than `INSURER_SHARE_MATURITY_PERIOD`, 4 days), `voteForInsurerTermination`, `executeInsurerTermination` (anyone) | Nothing | Passes at `INSURER_TERMINATION_THRESHOLD_BP` (60%) of the snapshot; cutoff between `INSURER_TERMINATION_MIN_LEAD` (2 hours) and `INSURER_TERMINATION_MAX_LEAD` (14 days) out; at most `INSURER_MAX_LIVE_VOTES` (8) live votes per voter; a costed outcome locks yes-voters' shares for `INSURER_POST_FIX_LOCK` (13 days) and levies part of them (`INSURER_LEVY_BP`, `INSURER_LEVY_FLOOR_BP`) to the bug-bounty address |
| Lister | `BazaarFactory.proposePairDeployment`, `settleDeploymentProposal`, `expireStuckDeploymentProposal`, `claimSeedRefund`; `BazaarOracle.registerComposite` (write-once) | Bond returned on approval | At least `MIN_DEPLOYMENT_AMOUNT` ($4,000): a bond of at least `DEPLOYMENT_BOND_USDC` ($1,000) and a seed of at least `MIN_INSURANCE_SEED` ($3,000); `DEPLOYMENT_LIVENESS` (48 hours); one pair and one pending proposal per raw base feed |
| UMA termination proposer | `BazaarPairTerminator.proposeTermination`, `settleTerminationProposal` | 0.1% of the fund, capped at $100 and at free capital, once per pair, to the first acceptance that schedules it | Bond of at least `TERMINATION_PROPOSAL_BOND` ($1,000); `TERMINATION_PROPOSAL_LIVENESS` (12 hours); `MAX_REASON_LENGTH` |
| UMA disputer | `disputeAssertion` on OOv3 (outside Bazaar) | UMA's dispute payout | Bazaar sets no escalation manager, so disputes go to UMA's DVM |
| Identifier proposer | `BazaarFactory.proposeUmaIdentifierUpgrade`, `settleIdentifierUpgradeProposal`, `expireStuckIdentifierUpgradeProposal`, `activateIdentifierUpgrade` (anyone) | Bond returned on approval | See the governed parameter below |
| Relayer | The eight entry points that accept a signature: `depositCollateral`, `withdrawCollateral`, `createOrder`, `cancelOrders`, `amendOrders`, `depositToInsurance`, `requestInsuranceWithdrawal`, `executeInsuranceWithdrawal` | The signed `relayerFee`, at most `MAX_RELAYER_FEE` ($1), pulled from the signer's wallet | `MetaTxLib.verifyAndConsume`: EIP-712, EOA signatures, sequential nonce, deadline at most `MAX_DEADLINE_WINDOW` (10 s) ahead; `priceUpdate`, match hints and `permitData` are not signed; a relayed `createOrder` runs the default walk |
| Integrator | Named in an order's `OrderSpec.integrator` field | 0.25 bp per side, less the bug-bounty tax | Fixed per order; vault unloads pay none |
| Bug-bounty address | `claimFees` | `BUG_BOUNTY_TAX_BP` (1%) of insurance and integrator fees, plus forfeited levy shares | Fixed at factory deployment |

### Contract-to-contract privileges

| Caller | May call | Check |
|---|---|---|
| `BazaarFactory` | `BazaarPair.initialize`, in the same transaction as `Clones.clone` | `initializer` (the implementation's own initializer is disabled) |
| `BazaarFactory` | `BazaarPairTerminator.registerPair` | `onlyFactory` |
| `BazaarPairTerminator` | `BazaarPair.setScheduledTermination`, `fixSettlementPrice`, `creditInsurance` | `msg.sender == umaContract`, set once at `initialize` |
| A registered pair | `BazaarPairTerminator.consumeInsurerLevy` | Registered-pair check |
| UMA OOv3 | `assertionResolvedCallback`, `assertionDisputedCallback` on the factory and the terminator | `msg.sender == assertionOo[assertionId]`, recorded only for assertions the contract created |

### The one governed parameter

The UMA identifier that every listing, identifier-upgrade and termination assertion is adjudicated
under (`umaIdentifier`; the protocol deploys under `ASSERT_TRUTH2`). The OOv3 address itself is
immutable. A change works as follows (listing.md, "The only governance"):

- `proposeUmaIdentifierUpgrade(newIdentifier)` posts a bond of at least
  `IDENTIFIER_UPGRADE_BOND_USDC` ($5,000; `requiredIdentifierUpgradeBond()` tracks UMA's minimum
  upward) under a liveness of `IDENTIFIER_UPGRADE_LIVENESS` (2 days). The candidate must be on UMA's
  live IdentifierWhitelist (resolved through the Finder, as OOv3 resolves it) and must start with
  `ASSERT_TRUTH`. One proposal can be pending at a time.
- Approval queues the change behind `IDENTIFIER_UPGRADE_TIMELOCK` (12 days). Anyone can then call
  `activateIdentifierUpgrade()`, which re-checks the whitelist; a candidate de-whitelisted meanwhile
  cancels the upgrade and keeps the incumbent.
- A disputed proposal waits up to `DVM_DISPUTE_GRACE` (14 days) past liveness before
  `expireStuckIdentifierUpgradeProposal` can discard it; an undisputed one past its expiration is
  approved even if its settlement reverts.
- While `umaIdentifierIsLive()` is false, new listings and UMA termination proposals revert; the
  identifier-upgrade path, as the repair path, then asserts under the proposed identifier.

## 6. External dependencies and trust assumptions

### Pyth (through `BazaarOracle`)

How it is used:

- **Pull updates.** Callers attach Pyth update data (`priceUpdate`) and ETH for Pyth's fee. A pair
  reads Pyth's on-chain cache first (`tryReadFreshPrice`) and pays for the supplied update
  (`updateAndFetchPrice`) only when the cache holds no fresh, in-confidence price; unspent ETH is
  refunded to the caller. `priceUpdate` is never part of a signed meta-transaction payload.
- **Staleness.** `MAX_PRICE_STALENESS` (3 s) applies to every price-resolving entry point. Pyth's age
  check is two-sided, so a publish time up to 3 s ahead of the block is accepted; the pair clamps
  future-dated timestamps where it computes ages. A price is stored only when its publish time is
  newer than the stored one and not after a scheduled cutoff, and nothing is stored once the
  settlement price is fixed.
- **Confidence.** Prices whose confidence exceeds `MAX_CONFIDENCE_BP` (2%) of the price are rejected;
  composites check each leg and the composed bracket. Reads return spot ± confidence: withdrawals
  value longs at the low edge and shorts at the high edge, while liquidations and ADL use spot. The
  termination price sources (`fetchFirstPriceAtOrAfter`, `fetchChainedMedian`) apply no confidence
  cap, by design.
- **Stale-oracle regime.** Only session pairs (`isContinuouslyTraded == false`) fall back to the
  stored `lastPairPrice`. On the fallback, fills are banded to ±`MAX_STALE_DEVIATION_BP` (10%),
  market orders and trigger executions revert, the mark and funding are frozen, unloads fill
  nothing, position holders cannot withdraw, LP redemptions are refused, `executeAdl` refuses to
  run, and liquidations use the stored price within `MAX_LIQUIDATION_PRICE_AGE`. Continuous pairs
  have no fallback: a priced call reverts until a fresh price lands.
- **Composites.** `registerComposite(baseId, quoteId, invertQuote)` is permissionless and
  write-once; a composite is as fresh as its stalest leg. A listing must name a registered
  composite or a raw feed Pyth already holds a price for, so legs cannot be attached after UMA
  approved a single-feed claim.
- **Termination prices.** Settlement prints are archived updates supplied as calldata, since Pyth's
  cache holds only the latest print. A UMA-scheduled pair (and a vote-scheduled pair whose claim UMA
  upheld) accepts only the feed's first print in [T − `MAX_PRICE_STALENESS`, T], parsed with Pyth's
  uniqueness check so the caller cannot pick a later tick. A vote-scheduled pair whose claim UMA has
  not upheld settles at the median of `SETTLEMENT_SAMPLE_COUNT` (5) prints chained from the cutoff,
  at least `SETTLEMENT_SAMPLE_SPACING` (10 minutes) apart. Once a path's last-resort time passes, and
  on the stale path, the pair settles at its last stored price, never at Pyth's permissionlessly
  writable cache.

Trusted: Pyth's publishers and attestation for the price and confidence values; the Pyth Core
contract at the immutable `BazaarOracle.pyth` address (Pyth's own governance can upgrade it; see
section 9, item 28); availability of
signed updates off-chain for keepers and frontends, which is a liveness rather than a safety
assumption. Defended against: stale and future-dated prices, wide confidence, tick-picking from
the cache or from a batch of updates at termination, composite re-registration, and a feed that
goes quiet (session fallback, stale termination after `ORACLE_DEAD_THRESHOLD`).

### UMA Optimistic Oracle V3

How it is used: listings and identifier upgrades (`BazaarFactory`) and termination claims
(`BazaarPairTerminator`) each call `assertTruth` with the proposer as asserter, the Bazaar contract
as callback recipient, no escalation manager (disputes escalate to UMA's DVM), USDC as currency, a
bond of the larger of the protocol floor and `getMinimumBond(USDC)`, the current `umaIdentifier`
(the proposed one for an identifier upgrade in degraded mode), and the livenesses listed in
section 5. Right after the call each contract records `assertionOo[assertionId]`; both callbacks
require `msg.sender == assertionOo[assertionId]`, so an assertion the contract did not create is
refused. Proposals are keyed by assertion id (`deploymentProposals`, `identifierUpgradeProposals`,
`terminationProposals`, and the insurer vote a claim opens).

Callback behaviour:

- OOv3 pays bonds before it calls back, so an asserter or disputer that cannot receive USDC makes
  settlement revert. The factory bounds this with `expireStuckDeploymentProposal` and
  `expireStuckIdentifierUpgradeProposal`: an undisputed proposal past its expiration is approved by
  reading the assertion back (`_approvalIsFixed`, since a failed settlement attempt proves nothing
  inside OOv3's reentrancy lock), and a disputed one is discarded after `DVM_DISPUTE_GRACE`. A
  resolved proposal makes a late callback a no-op.
- An approved listing deploys the clone, transfers the seed and registers the pair inside the
  callback; rejections only write storage, and the escrowed seed is credited for `claimSeedRefund`.
- An accepted termination schedules the pair through `try p.setScheduledTermination(...)`, emitting
  `TerminationScheduleRefused` on a refusal and re-raising an empty revert (out of gas) as
  `BazaarPairTerminator__ScheduleOutOfGas`, so a starved settlement cannot consume the assertion.
- The dispute callbacks only record the dispute (the terminator's only emits an event), because a
  revert there would make disputes impossible.

Trusted: the DVM resolves disputed claims honestly and within its published round limits; OOv3's
semantics (no dispute after `expirationTime`; an undisputed assertion settles truthful); UMA's
IdentifierWhitelist. UMA governance can raise the minimum bond (the floors track it upward) and
de-whitelist identifiers (the protocol fails closed). Defended against: price-feed identifiers
posing as truth identifiers (`ASSERT_TRUTH` prefix plus the live whitelist), crafted proposer text
(a 1–200 byte ASCII subset for listing descriptions, `_validateReason` for termination reasons),
stuck proposals, late acceptance backdating a cutoff (`MIN_CUTOFF_LEAD`), and duplicate markets over
one raw feed.

**Explicit test area: assertion-request spoofing and duplicate-request poisoning.** Please try to
make a protocol flow act on an assertion it did not create, or on the wrong one of two:

- an assertion made directly on OOv3 with the factory or terminator as callback recipient, and the
  same claim, bond, identifier and liveness as a live proposal;
- `settleDeploymentProposal`, `settleIdentifierUpgradeProposal`, `settleTerminationProposal` and the
  expiry paths called with ids the contract never issued, or with ids of proposals already resolved;
- two proposals that collide on an assertion id or a pending slot (same block, same proposer, a
  re-proposal after rejection or expiry, a re-listing after termination), and callbacks that arrive
  after an expiry path resolved their proposal;
- callbacks that re-enter the protocol while OOv3's lock is held;
- decoding of `getAssertion` through the local `IUmaOptimisticOracleV3` struct against the deployed
  OOv3.

### Native USDC

USDC (Circle's native token on Arbitrum One, 6 decimals) is the only collateral and is valued at
$1. Internal accounting is 1e18 fixed point and converts only at transfer boundaries: deposits are
floored to 1e12 granularity so the amount credited equals the amount pulled, payouts round down,
and the dust stays in the pair, which the books-versus-balance tolerance
(`USDC_BALANCE_TOLERANCE_BP`) absorbs. ERC-2612 permits are attempted best-effort and fall back to
an existing allowance.

Blacklisting: outbound USDC goes only to the account whose own balance is paid
(`withdrawCollateral`, `executeInsuranceWithdrawal`, `claimFees`, `claimSeedRefund`), to a new pair
(its seed), or back to the poster of a refunded insurer-vote bond, where a failed refund falls back
to crediting the pair's insurance. A blacklisted account can therefore strand only its own balance. Every
third-party payout (keeper rewards, integrator fees, relayer fees, the bug-bounty tax, the UMA
proposer reward, settlement tips) is credited through `FeeEscrowLib.credit` and pulled with
`claimFees`, so no recipient can make a liquidation, ADL step, unload, refresh, fill or settlement
revert. UMA bond payouts are OOv3's own transfers; see the callback notes above.

Trusted: Circle's token contract keeps standard ERC-20 semantics and 6 decimals (it is an
upgradeable proxy that Circle controls, and a pause would halt every flow). Defended against:
silently failing transfers (OpenZeppelin `SafeERC20`) and precision loss crediting value that was
not pulled. `CollateralLib.isBalanceShort` treats an unreadable `balanceOf` as no shortfall rather
than freezing the pair.

### ArbSys precompile and the Arbitrum sequencer

`BazaarPair._l2Block` reads `IArbSys(address(0x64)).arbBlockNumber()`, because `block.number` on
Arbitrum approximates the L1 block. L2 block numbers serve as a clock only for order expiry and
`MIN_ORDER_LIFETIME_BLOCKS`, fill and cancel stamps, the maker resting age that weights the funding
mark (`MAKER_EXPOSURE_BLOCKS`), and the creation-block rule for trigger bounties; time-based rules
use `block.timestamp`. Trusted: the sequencer orders transactions and sets timestamps within
Arbitrum's bounds, and block production stops during an outage (see section 9, items 3, 4 and 12).
No sequencer-uptime feed is used.

## 7. Invariants to break

Each is stated by the docs or asserted by the test suite. A sequence of calls that violates one is
in scope whatever its profit.

1. **Zero-sum conservation.** Valued at the pair's stored mark (or at the fixed settlement price
   once one is set), the sum of trader equity, registered terminal profit claims, the vault
   inventory's value, the insurance fund (I), the fee escrow (E) and the ledger's arrears, less the
   recorded deficit and terminal bad debt, equals the pair's USDC balance up to truncation dust
   that only ever favours the contract (`invariant_zeroSum`).
2. **Cash covers the books.** The pair's USDC balance never sits below I + D + E by more than
   `USDC_BALANCE_TOLERANCE_BP` (10 bp) without the next health verdict fixing the settlement price,
   and no collateral withdrawal or insurance redemption succeeds while it does (architecture.md,
   "Accounting invariant").
3. **Open interest is exact and two-sided.** `totalLongOI` and `totalShortOI` equal the sums of the
   position sizes on each side (`invariant_openInterestMatchesPositions`), and the two sides are
   equal once the vault's inventory (`pendingLiqSize`) is counted on its own side.
4. **Price-time priority.** The book rests sorted by price and then by priority sequence, never
   rests crossed, and holds no two orders that tie; every fill executes at the resting maker's limit
   price against the best-priced, earliest-queued maker. An amendment that keeps the order's
   neighbours is rewritten where it stands and leaves the book exactly as an unlink and an insert
   would (`OrderBookLib.staysInPlace`). A fill out of priority, or at a price the book did not offer,
   is a finding (matching.md, orders.md).
5. **Only an order's owner bounds its execution.** A caller's hints, step budget and price update
   can make the caller's own call fail or do less, but never mis-place, shrink or cancel another
   owner's order; a trigger order a keeper's walk cannot finish keeps its fills and stays live
   (matching.md).
6. **Only liquidation realizes a loss beyond collateral.** Every fill, for takers, makers and unload
   makers alike, passes the per-fill margin check, and a withdrawal never pays out unrealized PnL:
   while a position is open the account keeps a cash floor of `mmrBp` (24/7 pairs) or `imrBp`
   (session pairs) of notional in collateral (matching.md, margin.md).
7. **The resting-order tally never understates the live set.** Each size and limit notional in an
   account's `RestingTally` sits at or above the live sum unless pinned at its maximum, `highestBid`
   and `lowestAsk` bound every live limit, and `stopCount` covers the waiting `StopLimit` orders
   unless marked invalid, so a creation, amendment or withdrawal gate that passes an account on
   `CollateralLib._restingBound` never admits what reading the orders would refuse
   (`invariant_restingTallyNeverUnderstates`, margin.md).
8. **No keeper is paid from collateral that backs an open estate.** On a live pair every reward
   funded from insurance (liquidation, unload, ADL, refresh bounty, UMA proposer reward) is capped at
   free capital, the fund balance less the seizure earmarked against held inventory (fees.md).
9. **An unload never opens an ADL window.** An unload's fills stay inside the unload bound and the
   fund's headroom, never take the fund below its reserve, and, with the caller's reward capped by
   `RiskParamsLib.unloadRewardPayable`, never carry the pair over the ADL trigger it did not start
   past (liquidations.md).
10. **ADL is fund-neutral at worst and never favourable to the winner.** Winners close at the
    estates' average bankruptcy price or at the mark, a winner whose PnL at that price would be
    negative is skipped, and a batch closes no more than its sizing (`_sizeToRestoreHealth`, or
    `_sizeToAffordNettings` while deferred accounts are listed) requires, with the executor's reward
    counted so that paying it never leaves the fund short of releasing the window (adl.md).
11. **The fund's outlay on an estate never exceeds the loss beyond its bankruptcy price.** A
    settlement pays its loss from the estate's own seized collateral first, then net of the ledger's
    arrears, and only then from free capital (liquidations.md, adl.md).
12. **Deferred liquidations exist only inside an ADL window** (`invariant_deferredListedOnlyInsideWindow`).
13. **Termination pays in strict seniority.** At finalize the fee escrow comes off the pot first,
    principal (the sum of collateral) is paid next, pro rata if the pot is short, registered profit
    claims share what remains at one ratio, and insurers own only the residual; trader payouts never
    exceed the cash finalize reserved, including after an escape-hatch finalize re-freezes the
    ratios (`TerminationLib.freezeRatios`, `CollateralLib._refreezeRatios`, termination.md).
14. **Nothing strands behind a revert.** No liquidation, ADL step, unload, price refresh, fill,
    settlement or relayed call transfers tokens to a third party; every such payout is pulled with
    `claimFees`, which stays open in every pair state; settlement cannot revert for a position that
    exists; and a pair terminates exactly once (fees.md, termination.md).
15. **No trade sees the settlement print.** From `LIMBO_LEAD` (6 s) before a scheduled cutoff no
    fill, deposit or insurance flow executes, no price published after the cutoff is stored, and no
    price at all is stored once the settlement price is fixed.
16. **Governance fails closed.** While `umaIdentifierIsLive()` is false, `proposePairDeployment` and
    `proposeTermination` revert, so no assertion enters a pipeline that cannot be disputed
    (listing.md).
17. **One market per asset feed.** No two non-terminated pairs, and no two pending proposals, share
    a raw Pyth feed (`pairAddressByBaseFeed`, `pendingDeploymentByBaseFeed`).

## 8. Focus areas

Ranked by where subtle risk concentrates, judged from the code and from where the internal reviews
found most of their defects.

1. **ADL batches and deferred liquidations.** `AdlLib.executeAdlCore`, `_sizeToRestoreHealth`,
   `_sizeToAffordNettings`, `_releaseFigures`, `_closeAdlWinners`, `_deferredPass`,
   `_resolveDeferred`, `_closeSeized`, `_seizeRemainingDeferred`, `_settleInventorySlice`,
   `_listedNettings`, `_closeReward`, `_payRewards`; `LiquidationLib.processLiquidations`,
   `nettingAffordable`,
   `_netOpposingLiquidation`, `defer`; `RiskParamsLib.fundLedgerFrom`, `bankruptcyCloseCost`. A batch
   mutates the inventory and the deferred list while it runs, sizes its closes against a reserve,
   the ledger's arrears and holding-window funding, and rounds toward the fund. A wrong figure either
   haircuts winners for nothing or books a deficit, which terminates the pair. The executor's reward
   enters those solves (`_closeReward`, `Rewards.paidSize`), and within a batch a cohort that covers
   a deferred account has to stay the better-paid route.
2. **The vault-health verdict and the ledgers.** `BazaarPair._vaultHealthVerdict`,
   `isVaultHealthy`, `refreshPrice`, `_terminatePair`; `CollateralLib.isBalanceShort`,
   `_debitLedger`; `VaultHealthLib.checkLiqExposure`; `RiskParamsLib.vaultAdlExposure`,
   `insuranceFreeCapital`. One verdict opens and releases ADL windows, freezes markets and triggers
   autonomous termination. Check every path that moves I, D, E, `ledgerArrears` or `deficit` for an
   order of operations that breaks the identity, defers the books-versus-cash check, or releases a
   window early.
3. **The vault unload, a forced taker.** `MatchingEngineLib.unloadBook`, `_fillVault`,
   `_settleVaultLiquidation`, `_finalizeTx`; `RiskParamsLib.planUnload`, `unloadRewardPayable`;
   `BazaarPair.unloadVault` and the inline walk inside `liquidate`. The caller controls both the
   maker side and the timing; the bound combines the fund-neutral price, the band edge and a floor
   that decays over `UNLOAD_FLOOR_DECAY`; and the fills feed the liquidation-gap readings that set
   margin for everyone.
4. **Arrival matching and per-fill margin.** `MatchingEngineLib.executeArrival`, `_walkTaker`,
   `_fillCrossed`, `_settleFill`, `_checkMargin`, `_autoCancelOrder`, `executeTriggers`,
   `_disposeRemainder`, `_settleBounty`, `_accrueMarkPrint`; `OrderBookLib.insert`, `_walkToSlot`,
   `locate`, `unlink`; `OrderManagementLib.createOrder`, `amendOrders`, `_amendOne`, `sweepExpired`;
   `CollateralLib._orderReserve`, `_fillDebitOf`. Priority and fill prices are enforced only here;
   hints and step budgets come from the caller; while the oracle is fresh, sibling accounts can trade
   with each other at any price inside the placement band (`MAX_PLACEMENT_DEVIATION_BP`, ±50%); and
   margin can leave a bucket by routes other than `withdrawCollateral` (a realized loss to a sibling,
   fees, bounties).
5. **The resting-order tally and in-place amends.** `CollateralLib._restingBound`,
   `_sweepRestingReserve`, `_tallyAdd`, `_tallySub`, `withdrawCollateral`;
   `OrderManagementLib._requireCreationAffordable`, `_requireAmendedSetAffordable`,
   `_exactAmendReserve`, `_amendOne`, `cancelOrder`; `OrderBookLib.staysInPlace`, `restamp`. This is
   the newest code in scope. The creation, amendment and withdrawal gates pass an account on an upper
   bound from a per-account tally without reading its orders, so any path that lets the tally
   understate the set is a margin bypass. Check every writer of an active order against the tally,
   the rounding slack (`RESTING_BOUND_SLACK`), saturation and the invalid marker, and the fallback to
   the exact sweep. An amendment written in place must leave the book, the order's queue position
   and its exposure stamps exactly as an unlink and an insert would.
6. **The termination lifecycle.** `BazaarPairTerminator.proposeTermination`,
   `_handleTerminationResolution`, `terminateScheduledPair`, `settlementRule`, `_settleByChain`,
   `_insurerSettlementBounds`, `_umaCutoffInForce`, `proposeInsurerTermination`,
   `voteForInsurerTermination`, `executeInsurerTermination`, `terminateStalePair`;
   `BazaarPair.setScheduledTermination`, `_pastTradingCutoff`, `fixSettlementPrice`,
   `finalizeTermination`; `TerminationLib.executeTermination`, `freezeRatios`;
   `CollateralLib.settleTerminalPositions`, `_settleOne`, `_refreezeRatios`, `_paySettlementTip`.
   Questions worth time: precedence between UMA and insurer cutoffs; whether any caller can choose
   the settlement print; and finalize through the escape hatch with positions still open.
7. **The insurance vault.** `InsuranceVaultLib.depositToInsurance`, `sharesForDeposit`,
   `requestInsuranceWithdrawal`, `executeInsuranceWithdrawal`, `_lockOrClaim`, `claimOpensAt`,
   `_enforceRateLimit`, `withdrawalCapOf`, `withdrawalWindowOf`; `RiskParamsLib.redemptionHeadroom`,
   `lossPastHeadroom`;
   `BazaarPairTerminator.getLockedShares`, `consumeInsurerLevy`. LP cohorts can try to exit ahead of
   losses the share price does not see yet, or to buy the haircut gains of an ADL window; shares are
   marked to market while inventory is held; votes lock shares and levy them.
8. **Risk inputs that wash open interest can move.** `RiskParamsLib.calculateIMRandMMR`,
   `liquidationImrBp`, `calculateVariance`, `_observeReopenGap`, `adlReserve`, `reserveOiSizeOf`,
   `payRefreshBounty`; `MmrSampleLib.laggedMmr`; `BucketLib.effectiveMmrBp`;
   `FundingLib.updateMarkPrice`, `updateFundingIndex`. A long and a short held in two wallets raise
   open interest within one transaction at the cost of margin and fees; each consumer relies on its
   own lag, trailing minimum or floor.
9. **Listing, governance and the UMA callbacks.** `BazaarFactory.proposePairDeployment`,
   `assertionResolvedCallback`, `assertionDisputedCallback`, `_handleDeploymentResolution`,
   `_executePairDeployment`, `expireStuckDeploymentProposal`, `_approvalIsFixed`, `claimSeedRefund`,
   `proposeUmaIdentifierUpgrade`, `activateIdentifierUpgrade`,
   `expireStuckIdentifierUpgradeProposal`, `_identifierWhitelisted`, `_isAssertTruthIdentifier`,
   `_isValidDescription`; `BazaarOracle.registerComposite`. Includes the spoofing and duplicate-request
   cases in section 6.
10. **Price resolution, relayed calls and ETH refunds.** `BazaarPair._getCurrentPairPrice`,
    `_buildAndStorePairPrice`, `_resolveUser`, `_sendWithRelayerFee`, `_refundEth`;
    `MetaTxLib.verifyAndConsume`; `BazaarOracle.tryReadFreshPrice`, `updateAndFetchPrice`,
    `tryReadStalePrice`, `fetchFirstPriceAtOrAfter`, `fetchChainedMedian`. Resolution is cache-first
    and `priceUpdate` is unsigned, so a relayer or keeper chooses which fresh print a call sees. ETH
    refunds go to the caller at the end of payable entry points while the transient guard is held;
    functions without the guard, such as `finalizeTermination`, stay reachable from that callback.

## 9. Known issues and accepted risks

Everything below is a known property of the current code. Reports that restate one of these items
without a new consequence (a larger impact, a cheaper path, or a broken bound) are duplicates.

### Oracle and pricing

1. **A liquidation can run on a stored price up to 10 minutes old.** On a session pair, when
   neither Pyth's cache nor the caller supplies a fresh price, `liquidate` judges accounts against
   the stored mark if it is within `MAX_LIQUIDATION_PRICE_AGE` (10 minutes); a 24/7 pair has no stale
   fallback and reverts instead. Accepted: the mark was fresh when stored, the owner can
   top up or store a newer price inside the window, the caller earns only the standard reward, and
   the MMR lookback is anchored to the mark's own timestamp.
2. **A stale mark can fix the settlement price on a deficit or a cash shortfall.** The health
   verdict fixes the settlement price on any recorded deficit or books-versus-balance shortfall
   without consulting staleness, and every flow that runs it on a session pair's stale fallback can
   fix it at that mark: `refreshPrice` (with no age bound), `unloadVault` outside an ADL window, a
   `createOrder` that fills inside the stale band, and a `liquidate` within
   `MAX_LIQUIDATION_PRICE_AGE`. Accepted: nothing that runs on a stale mark can create either
   condition in correct code, so the check only freezes a pair a defect elsewhere has already
   broken, and an age bound would delay that freeze. A flat withdrawal reads no price; it runs the
   books-versus-balance check on its own and is refused while that fails.
3. **24/7 pairs halt when Pyth and Arbitrum clocks drift apart by more than 3 s.** On continuous
   pairs a clock skew or delivery lag beyond `MAX_PRICE_STALENESS` (3 s) halts every priced entry
   point until fresh updates land. Accepted pending a mainnet measurement of the revert rate.
   `terminateScheduledPair` selects prints by publish time against the cutoff and
   `terminateStalePair` needs no fresh price, so both keep working; the pair's own insolvency and
   ADL-timeout freezes run inside priced entry points and wait with them.
4. **24/7 pairs have no restart grace after an outage.** The first fresh price after a sequencer or
   oracle outage decides seizures, so a trader who could have topped up at the restart price can
   lose residual equity (up to about MMR × notional) to the fund. Documented in liquidations.md; no
   code change.
5. **`terminateStalePair` is bondless and one-step.** Anyone can terminate a pair at its last stored
   price once both the latest confidence-cleared tick in Pyth's on-chain cache and the pair's stored
   price (its creation, if it never stored one) are older than `ORACLE_DEAD_THRESHOLD` (21 days). A
   quiet pair on a feed that still publishes off-chain can therefore be settled at a price at least
   21 days old. Accepted: one on-chain Pyth push resets the clock, and the refresh bounty's daily
   heartbeat (`REFRESH_BOUNTY_HEARTBEAT`) pays keepers to push while the fund's free capital exceeds
   `REFRESH_BOUNTY_MIN_INSURANCE` ($5,000).

### Margin and risk parameters

6. **A margin-rate rise just before a quiet stretch reaches maintenance late.** The curve is
   recomputed (at most once per `IMR_UPDATE_COOLDOWN`, 1 minute) and the lagged-MMR ring advanced (at
   most one sample closes per `MMR_SAMPLE_INTERVAL`, 1 hour) only when a call reaches
   `RiskParamsLib.calculateIMRandMMR`. A rise set shortly before a stretch with no calls is not
   recorded as the rate in force during that stretch, so positions keep the pre-rise maintenance
   rate until post-stretch samples cover the `MMR_GRACE_PERIOD` (24 hours) lookback: the grace
   stretches by the length of the stall. Accepted as lenient-only: it defers a rise, and a fall
   applies at once through `BucketLib.effectiveMmrBp` (the lower of lagged and current).
7. **The reopen-gap estimator can be timed on quiet session pairs.** It measures the move between
   two stores separated by at least `REOPEN_GAP_MIN_STALENESS` (1 hour). On a session pair nobody
   trades, where the refresh bounty pays only its daily heartbeat (too little vault inventory) or
   nothing (free capital at or below `REFRESH_BOUNTY_MIN_INSURANCE`), stores can be hours apart
   inside a session, and whoever ends the silence picks the instant, so an intraday
   extreme can read as a reopen gap. The reading is capped at `REOPEN_GAP_EMA_CAP_BP` (2,500 bp),
   decays with `REOPEN_GAP_EMA_TAU` (130 days), and raises IMR at once while maintenance follows only
   as the 24-hour lagged rate catches up. Accepted; the preferred fix (gap between two Pyth prints
   proven consecutive) is recorded for a later version.
8. **Self-dealt estates move the liquidation-gap readings within a designed bound.** The slippage
   and drift readings weigh each unload batch against a prior of at least `LIQ_GAP_PRIOR_FLOOR_BP`
   (1% of per-side open interest), so a batch of size x (as a fraction of that floor) moves them at
   most x/(1+x) of the way to its own reading, and small estates sold at the band edge add up like
   one estate of their total size; zero-slippage batches 26 s or more apart dilute a reading
   geometrically. Accepted as the designed bound.
9. **The funding mark reads a sustained premium in full.** The mark is the ratio of two fading
   tallies fed only by fills against makers resting on the far side of the oracle, each print
   clamped to ±`MAX_MARK_DEVIATION_BP` (400 bp) of the index. An attacker who sustains a far-side
   premium on a pair with honest flow above the volume floor has it read in full; a block of capped
   calls can reach the band edge; after a stream stops, a busy pair holds its reading for a while
   before fading; the window average treats up to 3 s before the anchor as zero premium. Accepted:
   the cost is the sniping risk of a far-side quote that honest flow can hit.
10. **Insurance entry points do not refresh the cached insurance target or trailing open interest.**
    The deposit gate, the redemption headroom and the withdrawal budget's held-open-interest term
    read the values the last recompute cached (the below-target rate limit derives its target live).
    Judged negligible within the refresh-bounty cadence, but not quantified.

### Matching and orders

11. **Fresh-oracle fills between users carry no price band.** Only stale-fallback fills are banded
    (`MAX_STALE_DEVIATION_BP`, 10%). Accepted: an off-mark fill is solvent and passes both sides'
    per-fill margin checks, and the funding mark clamps every print to 400 bp of the index, so an
    off-market print moves the mark no further than a print at the band edge.
12. **Order expiry counts Arbitrum L2 blocks.** L2 blocks stop during a sequencer outage, so a
    resting limit can outlive its intended wall-clock life and fill at its stale limit at the
    restart, bounded by the maker's margin gate. Accepted for cost: a wall-clock bound needs another
    `Order` storage slot or a narrower field.
13. **A relayer can collect the keeper bounty of a signed trigger order it relays.** `priceUpdate`
    is not part of the signed payload. In one transaction a relayer can land a fresh print on the
    trigger's unmet side, create the signed stop, push a later print that meets the trigger and fire
    the stop for its bounty. The bounty goes to the owner only when the creation's own arrival walk
    executes the order, or when `executeTriggeredOrders` runs in the block a stale-fallback creation
    left it in. A second route needs only one print: an order the creation's walk armed but could
    not fill completely is paid to whoever completes it later in that block, including a relayer
    that supplies the liquidity itself. Accepted: the owner's loss is bounded by the bounty they
    chose, and the first route needs two prints straddling the trigger, each within 3 s of the block
    timestamp.

### Liquidation, ADL and insurance

14. **A realized winner can be held to what the deposits ledger holds until the vault's inventory
    exits.** A seizure moves the estate's whole collateral from the deposits ledger to insurance, so
    a solvent winner's withdrawal can revert `CollateralLib__LedgerShortfall` until the inventory is
    unloaded or closed. Accepted: the stuck amount is bounded by the inventory's loss less the margin
    its new counterparties posted, the `available` amount is always withdrawable, and outside an ADL
    window anyone can end the wait with a rewarded `unloadVault`, as far as the book absorbs the
    inventory; inside one, where `unloadVault` reverts, an `executeAdl` close or an affordable
    opposing netting does.
15. **ADL completeness is not enforced on-chain.** `AdlLib._scanEligibleWinners` checks descending
    score only among the winners a keeper submits (position buckets are not enumerable), so a keeper
    can spare an eligible higher-scored account. Accepted: the batch's sizing caps the close whoever
    is named (naming fewer eligible winners closes less, never more), the executor's reward does not
    depend on who bears the close, the Dutch threshold limits substitutes to accounts that cleared
    it, and `AdlExecuted` carries the inventory leg's highest and lowest admitted score while each
    `UserAdld` carries a closed winner's score, for off-chain monitoring.
16. **A keeper's ADL sort can lose a race to a newer Pyth tick.** The deferred cohort is ranked at
    the pair's stored price; a batch whose update carries a different mark can fail its ordering
    check and revert. Liveness friction only (gas); the docs give keepers a score-and-retry recipe.
17. **The ADL timeout runway is a wall-clock instant armed once.** The first fresh price stored
    after a window has been pending for `ADL_TIMEOUT_DURATION` (24 hours) arms `adlTerminationTs`
    `ADL_TERMINATION_GRACE` (30 minutes) later, and nothing pushes it back. An outage or session close
    that starts after arming uses up the runway, so the first fresh-priced health check after the
    gap can terminate the pair before `executeAdl` runs. Accepted: the runway exists so that a
    timeout lapsing during a closure still leaves time to deleverage after the reopen, and a closure
    that starts inside the runway uses it up.
18. **Haircuts of a window that never releases are not refunded.** If an ADL window never releases
    and the pair terminates, the winners already deleveraged keep only what their closes paid;
    insurance is junior at termination, so a solvent fund keeps those haircuts in its residual.
    Open design question; a refund tier ahead of the insurers' residual is under consideration.
19. **`_seizeRemainingDeferred` has no side filter or affordability gate.** It seizes every listed
    account still open and insolvent. It is safe only because every account it can reach sits on one side: the
    per-account pass delists accounts on the batch-start inventory side first, and nothing lists an
    account mid-batch. Its natspec states the invariant; a path that breaks it is in scope.
20. **An ADL batch pays nothing for closes made only so deferred accounts can be absorbed.** Units
    the inventory leg closes past its restoring figure, or past what the fund could not carry as the
    batch began less the deferred accounts it absorbs, earn only those accounts' seizure rewards. A
    batch whose listed accounts are at least as large as the inventory closes all of it, moves them
    into a new inventory and earns their $0.05 floors alone, which is thin pay for running that
    window. Accepted by choice: paying
    those units would reward absorbing an account over closing it against a cohort that covers it,
    which spares the fund the loss.
21. **A cohort stays the executor's better-paid route only within one batch.** An account netted by
    an earlier call (`liquidate`, or `executeAdl` with no winners) no longer reduces a later batch's
    paid units, so netting first and running the leg next can pay more than closing the account
    against a covering cohort, by at most about 1% of the netting's cost, while the fund bears that
    cost. Separately, a batch that empties the inventory seizes every account still listed at the
    $0.05 floor (`_seizeRemainingDeferred`), including accounts within their collateral that a
    cohort-kept inventory would leave listed and unpaid, which can tip the totals by that floor.
    Accepted: an affordable netting is the protocol's own first resolution, and window-scoped state
    would need new storage and still miss nettings made before the window's first batch.
22. **Insurance redemptions stay open until shortly before a scheduled cutoff.** An LP with a matured
    request can exit between a termination's acceptance and the halt `LIMBO_LEAD` (6 s) before the
    cutoff. Accepted: the cutoff print exposes the fund to no loss that live trading would not, and a
    lock from scheduling would hold LPs for as long as the proposer chose, since a UMA cutoff has no
    upper bound.
23. **A session pair's withdrawal window can lapse across a long closure.** Both execute calls need
    a fresh price, so on a pair with trading hours only the venue's trading hours count toward
    `INSURANCE_WITHDRAWAL_WINDOW_SESSION` (4 days). A longer closure (Easter on a venue shut both Good
    Friday and Easter Monday, a week-long holiday such as Lunar New Year) can leave a request with no
    usable hour, and the LP files again and serves a new `INSURANCE_WITHDRAWAL_COOLDOWN`. Accepted:
    the LP loses time, not funds, and a longer window would give LPs more freedom to pick the moment
    they lock.

### Listing, termination, governance and deployment

24. **A listing slot can be held by repeated self-disputed proposals.** One proposal per raw base
    feed can be pending at a time, so an attacker can propose a claim the DVM will reject, dispute
    it, and repeat, delaying that asset's listing until each vote resolves (at most
    `DEPLOYMENT_LIVENESS` + `DVM_DISPUTE_GRACE`, 16 days, for a dispute that can never settle).
    Accepted: no funds on any live pair are reachable, each cycle burns part of the attacker's bond,
    and the pattern is visible on-chain.
25. **The single identifier-upgrade slot can be held by a proposer who wins every race.** Only one
    identifier-upgrade proposal can be pending, and an approved one blocks new proposals until its
    `IDENTIFIER_UPGRADE_TIMELOCK` ends. A candidate must be on UMA's live whitelist, start with
    `ASSERT_TRUTH` and differ from the current identifier, so while UMA whitelists one successor,
    every valid proposal names it and is approved once the incumbent's retirement makes the upgrade
    necessary. By disputing their own proposal an attacker can delay that approval by about one DVM
    vote (typically 2–4 days), at the cost of the share UMA burns from the losing bond. If UMA ever
    whitelists two such identifiers and one is unfit, a proposer who re-proposes the unfit one first
    after every rejection can hold the slot for as long as they keep paying (a bond lost, or partly
    burned, every cycle), and so keep the protocol in degraded mode after the incumbent is retired.
    Accepted: the block costs liveness, never funds (in degraded mode new listings and UMA
    termination proposals revert, while trading, withdrawals and the other three termination paths
    continue), each cycle is costly and visible on-chain, and one pending slot per candidate
    identifier is the recorded fix should UMA's whitelist ever make the two-identifier case
    reachable.
26. **Settlement tips topped up from insurance are paid ahead of traders.** Before finalize, a
    settled position worth at least `MIN_ORDER_AMOUNT` ($5) whose own collateral cannot pay
    `TERMINAL_SETTLEMENT_TIP` ($0.05) has the rest topped up from the nominal insurance balance
    (`CollateralLib._paySettlementTip`). The credit goes to the fee escrow, which finalize takes off
    the pot first, so when the pot cannot pay every principal and registered claim the tip reduces
    the traders' ratios rather than the insurers' residual. Accepted: the cost is at most $0.05 per
    such position, and it pays keepers to settle bankrupt positions before the ratios freeze, which
    books their shortfall then rather than leaving it to the holders still in after finalize.
27. **A termination claim UMA can never settle never schedules the pair.** OOv3 pays bonds before
    it calls back, so a claim whose bond recipient cannot receive USDC can never settle, and
    `BazaarPairTerminator` has no expiry path for it. The claim holds nothing: `proposeTermination`
    accepts any number of claims per pair, so anyone can propose the same event again, and the
    other termination paths are unaffected. The insurer vote the claim opened still runs: an
    undisputed claim reads as upheld once its liveness ends, while a disputed one reads as pending
    and, after `CLAIM_VERDICT_GRACE` (14 days), settles as an unjudged vote, which levies its
    yes-voters even if the DVM upheld the claim (unless the vote met a cutoff UMA had already
    verified). Accepted: it needs a USDC-blacklisted bond recipient, and its cost falls on that
    claim and its voters, not on the pair.
28. **The Pyth contract address is immutable.** `BazaarOracle.pyth` is set at deployment to Pyth Core
    (`0xff1a0f4744e8582DF1aE09D5611b887B6a12925C`), the original Arbitrum One contract, which Pyth upgraded in
    place in August 2026. Pyth's list also names a second contract with the same interface and separate
    storage, Pyth Core Compatible (`0xe15357fB7ab31E091583b9c4b4135BB2f176f38e`), which Bazaar does not use,
    and it does not say how long it will maintain either. If Pyth Core stopped accepting updates, pairs
    could store no new price: 24/7 pairs would halt, session pairs would stay on their stale fallback,
    and markets would wind down through the UMA claim category for a Pyth contract migration or, after
    `ORACLE_DEAD_THRESHOLD`, `terminateStalePair`; new listings would need a new deployment. Accepted:
    there is no upgrade path by design, and the termination paths are the way out.
29. **Deployment-environment checks still to run.** The build targets `cancun` (`MCOPY` and transient
    storage), which Arbitrum One supports since ArbOS 20; the Arbitrum Sepolia rehearsal is the
    planned confirmation. `DeployBazaar` probes the USDC, Pyth and OOv3 addresses for code,
    distinctness, decimals and live calls before broadcasting, but a wrong-but-live address of the
    right shape (for example bridged USDC.e, which also has 6 decimals) is detectable only by reading
    the literals against the issuers' published lists. All three matched those lists on 2026-11-01;
    they have to be read again before a mainnet deployment.

### Accepted residuals of fixed issues

30. **In-band vault unloads fill at once.** Fills inside the unload band (the lower of the maintenance
    rate and `LIQ_MAX_SLIPPAGE_BP`, 5%) are immediate, so whoever wins the liquidation race can also
    buy the seized inventory at the band edge; beyond the edge the floor opens toward the
    fund-neutral price only over `UNLOAD_FLOOR_DECAY` (3 minutes), and fills that cost the fund stay
    within its headroom. The extraction is bounded by the band.
31. **The ADL reserve is sized on live open interest during a pair's first day.**
    `RiskParamsLib.reserveOiSizeOf` takes the lower of live open interest and its trailing minimum
    over `MMR_GRACE_PERIOD`, and live open interest alone until a sampled interval is that old, so a
    new pair's reserve can be inflated with wash open interest, and open interest held for a day
    counts in full.
32. **The margin rate can be lifted for a minute by a wash opened just before a recompute.** Open
    interest opened before the next post-cooldown recompute enters the stored IMR for up to
    `IMR_UPDATE_COOLDOWN`; inside a cooldown `liquidate` can be more lenient than ADL or withdrawals,
    never stricter, and past it `liquidate` judges at the live rate, which can sit above the stored
    rate withdrawals read until the next refresh. Positions opened during a genuine rise are
    maintained at the lagged rate for up to a day.
33. **A netting's reward can bring an ADL window forward.** The 2 bp netting reward is paid from free
    capital and is not counted by `nettingAffordable`, so it can open a window earlier by what it
    pays.

### Test-suite limits

34. **The stateful suite is not shown to reach realized bad debt.** The handler exercises funding
    carry under held inventory (`accrueFunding`) and records the deepest deficit a sequence books
    (`ghostMaxDeficit`), but no assertion reads it, so whether a fuzzed sequence reaches the bad-debt
    regime is unmeasured; that regime is pinned by deterministic tests.

## 10. Prior review

The codebase has been through eight rounds of internal security review. The later rounds split the
code by subsystem, traced every candidate finding against the source with worked numbers, and, in
the most recent round, reproduced every Medium with a forge proof of concept before it was fixed.
Every finding from those rounds is fixed or listed in section 9. The test suite holds 1,773 test
functions in 112 files under `test/unit` and `test/integration` at the time of writing, including
fuzz tests, fixed zero-sum scenarios and the handler-based invariant suite. **The protocol has not
had a professional audit.** The internal review reports can be shared with the selected auditor on
request.

## 11. Logistics

| Item | Value |
|---|---|
| Contact | bazaarfi@proton.me |
| Timing | Flexible; start and completion dates agreed with the firm |
| Budget | To be quoted, for the full scope and for the competition subset (section 3) |
| Deliverables | A written report with severity-ranked findings and proofs of concept where practical; a fix review of the remediation commit(s); a final report naming the reviewed fix commit |
| Communication | Channel and response times agreed with the firm |
| Code freeze | Only audit fixes touch `src/` between the tag and the fix review |
