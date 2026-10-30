# Contracts

Access-control legend: **anyone** = permissionless · **bonded** = permissionless with economic stake · **wired** = callable only by a registered protocol contract.

## BazaarPair — `src/BazaarPair.sol`

One EIP-1167 clone per market. Initialized once by the factory.

| Function | Access | Purpose |
|---|---|---|
| `depositCollateral` / `withdrawCollateral` | anyone / meta-tx | collateral in/out; withdrawal enforces IMR at bracket prices and, while a position is open, retention of `mmrBp` (continuously traded) or `imrBp` (session-bound) of notional in collateral proper |
| `createOrder` / `cancelOrders` / `amendOrders` | anyone / meta-tx | matching happens on arrival, inside `createOrder` itself; `amendOrders` reprices or resizes resting limit orders in place, never crossing the book — see [Orders](../protocol/orders.md) and [Matching](../protocol/matching.md) |
| `executeTriggeredOrders(execs[], …)` | anyone | fires triggered stops against a fresh Pyth price, earning each order's escrowed bounty in proportion to what the call fills, and all that is left once it completes the order or rests it in the book (an execution in the creation block of an order the stale fallback left unarmed pays that share to the owner); a fired order the book could not finish stays live; an armed StopLimit takes a fresh `prioritySeq` and rests behind every order already at its price, unless it fired with less than the 240-block minimum lifetime left, when what it could not fill stays live outside the book instead |
| `unloadVault(maxSteps, …)` | anyone | crosses the vault's pending liquidation inventory into the book for a reward — see [Liquidations](../protocol/liquidations.md) |
| `sweepExpired(orderIds[])` | anyone, while trading is live | janitor: cancels-and-unlinks expired orders that no walk has touched yet, and returns the escrowed bounty of any terminal or expired trigger order to its owner |
| `liquidate(users[], …)` | anyone | full liquidation of insolvent buckets — and, once a settlement price is fixed, the terminal-settlement entry point (no price update, no ETH, no solvency threshold; a tip of up to $0.05 per position settled for someone else) |
| `executeAdl(winners[], deferredWinners[], …)` | anyone | Dutch-auction deleveraging — `winners` closes against the vault's inventory, `deferredWinners` against the [deferred liquidations](../protocol/adl.md#two-cohorts-one-batch); either list may be empty, not both |
| `depositToInsurance` / `requestInsuranceWithdrawal` / `executeInsuranceWithdrawal` | anyone / meta-tx | insurance LP flows; the deposit and the execute both carry a `priceUpdate` and price shares at the mark — the execute needs a fresh one on a live pair (none once terminated), the deposit only while the vault holds liquidated inventory (empty update and no ETH otherwise); the deposit is refused while an ADL window is pending or would open at the price it carries. On a live pair the execute takes at least two calls: the first locks the requested shares' value and pays nothing, the next pays the lower of that and their value once its claim opens (`getInsuranceWithdrawalLock`), held to the fund's headroom while the vault holds inventory, with any rest left requested for a later call; a terminated pair pays in one. A relayed lock pulls its relayer fee from the wallet, with an optional `permitData`; the paying call's fee comes out of the payout |
| `refreshPrice` | anyone | push a Pyth update, roll funding/margin state and judge vault health (what opens an ADL window on a book too thin to trade); may pay the caller the refresh bounty |
| `claimFees` | anyone (pays only the caller's own balance) | withdraw every payout the pair owes the caller — keeper rewards, integrator fees, the bug-bounty tax, relayer fees, the UMA proposer reward, refunded trigger bounties — see [Fees](../protocol/fees.md#how-payouts-are-paid); open in every pair state; the balance owed is read through the lens's `claimableFees(pair, who)` |
| `creditInsurance` | wired (terminator) | books forfeited insurer bonds |
| `setScheduledTermination` / `fixSettlementPrice` | wired (terminator) | lifecycle transitions (`finalizeTermination` is public once every position is settled at the fixed price, or 14 days after the fix; settling runs through `liquidate`) |

Key views: `book` (list heads and counts), `positionBuckets`, `orders` (including each order's `prevInBook`/`nextInBook` links), `lastPairPrice`, `pairVault` (the vault aggregates), `marginRequirements` / `getLaggedMmr` (the current rates, and the lowest MMR recorded over the trailing 24 h; a position is judged at the lower of the two MMRs), `currentFundingIndex`, `metaTxNonces`, `insuranceShares`, `getSharesAsOf`, `adlScoreDeposit` (the window deposit ADL ranking subtracts), `deferredLiquidations(i)` (the accounts a `liquidate()` left open for the auction — `auxState().deferredCount` gives the length), plus everything on the lens. State with no dedicated getter — the liquidation slippage/drift EMAs, the reopen-gap floor, the insurance-withdrawal rate-limit window — is readable through `extsload(slot)`, one raw storage word per call, which reaches callers that cannot use `eth_getStorageAt` (other contracts, subgraphs). Slots are fixed per implementation (every pair is a clone of one); take them from `forge inspect BazaarPair storage-layout`, or use the lens views built on them.

## BazaarFactory — `src/BazaarFactory.sol`

| Function | Access |
|---|---|
| `proposePairDeployment` / `settleDeploymentProposal` | anyone (bonded) |
| `proposeUmaIdentifierUpgrade` / `settleIdentifierUpgradeProposal` | anyone (bonded) |
| `activateIdentifierUpgrade` | anyone, once the 12-day post-approval timelock elapses |
| `expireStuckDeploymentProposal` / `expireStuckIdentifierUpgradeProposal` | anyone, once liveness has passed (plus the 14-day dispute grace if the proposal was disputed); settles if it can, otherwise approves an undisputed proposal and discards a disputed one |
| `claimSeedRefund` | anyone (pays only the caller's own credit) |
| `assertionResolvedCallback` / `assertionDisputedCallback` | wired (the UMA OO recorded per assertion) |
| `getPairAddress` / `isPair` / `getAllPairs` / `pairsCount` / proposal getters | view |
| `umaIdentifierIsLive` | view — the one-call monitoring endpoint; false means listings and UMA terminations are failing closed |
| `requiredDeploymentBond` / `requiredIdentifierUpgradeBond` | view — quote before approving; the constants are floors under UMA's live minimum |

`oo` is immutable; `umaIdentifier` is the single governed parameter. See [Markets & Listing](../protocol/listing.md#the-only-governance-swapping-the-uma-identifier).

## BazaarOracle — `src/BazaarOracle.sol`

| Function | Access |
|---|---|
| `registerComposite` | anyone (idempotent) |
| `updateAndFetchPrice` / `fetchFirstPriceAtOrAfter` / `fetchChainedMedian` | anyone, payable (Pyth fee) |
| `tryReadFreshPrice` / `tryReadStalePrice` / `getUpdateFee` / `getSampleSetFee` / `getCompositeId` | view |

## BazaarPairTerminator — `src/BazaarPairTerminator.sol`

| Function | Access |
|---|---|
| `proposeTermination` / `settleTerminationProposal` | anyone (bonded) — the proposal declares a numbered reason category, and its one free-text field is its `reason`, [charset- and length-bounded](../protocol/termination.md#proposer-supplied-text) |
| `terminateScheduledPair` / `terminateStalePair` | anyone |
| `proposeInsurerTermination` (a bare proposal, bonded) / `voteForInsurerTermination` / `executeInsurerTermination` | mature insurance shareholders to propose and vote; anyone to execute. Every `proposeTermination` claim opens a vote too, under its assertion id |
| `consumeInsurerLevy` | wired (pair) — draws a redeeming yes-voter's levy on a terminated pair |
| `registerPair` | wired (factory) |
| UMA callbacks | wired (recorded OO) |
| `requiredTerminationBond` / `getLockedShares` / `getInsurerVote` / `insurerScheduled` / `settlementRule` / `isPair` | view — `settlementRule(pair)` tells a keeper which prints `terminateScheduledPair` needs ([how](../protocol/termination.md#supplying-the-settlement-prints)) |

## BazaarPairLens — `src/BazaarPairLens.sol`

Read-only views (its only state is the immutable `factory` it was deployed against): `getPositionBucket`, `checkBucketSolvency`, `getInsuranceSharePrice` / `getInsuranceDepositValue` (insurance share value at the pair's stored mark, on the redemption basis), `quoteInsuranceDeposit` / `quoteInsuranceWithdrawal` (what a deposit of a given size would mint, or a redemption pay, at a caller-supplied mark — quote against the live Pyth price your transaction will carry, since the pair refuses a stale one while the vault holds inventory), `getInsuranceWithdrawalBudget` (what the pair's cumulative 6-hour insurance-withdrawal budget still admits, the budget itself, when it refills, and the coverage and live target that pick the regime — the same arithmetic execution enforces; the budget is shared across all insurers and checked at the *paying call*, a cooldown after the request, so treat it as a reading of the moment rather than a reservation), `getInsuranceWithdrawalLock` (whether an LP's redemption is locked, the amount it locked, when its paying call opens and when the window closes, from the same timing rule execution enforces), `getAdlScoreThreshold`, `getAdlScore` (a candidate's auction score and eligibility — sort submissions by it descending, ties by ascending address; it reproduces the on-chain ranking of the `winners` cohort exactly, and scores the `deferredWinners` cohort at the pair's last stored price with the live funding index, which matches the on-chain ranking whenever the transaction stores nothing newer), `getTerminalEntitlement` (post-termination payout components: collateral, registered claim, the two frozen ratios, and the cash payout), `getMaxWithdrawable` (the largest amount `withdrawCollateral` accepts right now, one "max" before and after termination: live, the margin, retention and order-reserve bound capped at the deposits ledger, and 0 whenever the pair would refuse the withdrawal outright — pass the conservative bracket price: spot − conf for a long, spot + conf for a short; the one refusal it cannot foresee is a position holder's, for liquidation exposure beyond the fund before an ADL window latches. After finalize, the terminal amount in collateral units, with a still-open position realized at the settlement price), `getPendingLiquidationExposure` (the vault's inventory aggregate, including its size-weighted seizure time, from which the unload floor opens toward bankruptcy over 3 minutes), `claimableFees` (what one claimant may pull from one pair, and that pair's escrow total), `getClaimableFees` / `getClaimableFeesAll` (the unclaimed payout balance a claimant holds on each pair — for a chosen list, or every pair under the wired `factory`), `getUserActiveLimitOrders` / `outstandingOrderExposure` (a user's live resting orders and their per-side limit-priced notional and remaining size, read from the pair's storage without the lazy cleanup the pair's own sweeps perform; this is not what the pair's gates reserve, which values each order against the mark and adds the fill debit — `getMaxWithdrawable` applies that rule), `markPrice`, `adlEpoch`, `adlTerminationTs` (the pair's mark as it reads at the current block — its premium tally over the larger of its volume tally and the open-interest floor, carried on the last stored price — its ADL ranking epoch and its armed auction deadline, which the pair keeps internal), `getAuxState`, `getBookDepth` (a head-to-tail page of one book side, read through the pair's `book()` heads and `orders()` links — for depth displays and hint computation), `findPredecessor` (the resume-able hint helper for `MatchHints.pred` and for the hint fields of an `amendOrders` id word), `amendIdWord` (packs an order id and up to two hints into the first word of an `amendOrders` triple), `nextOrderId` (the id counter that order ids, amended orders' queue positions and armed StopLimits' queue positions all draw from), `triggerBounty` (the keeper bounty a trigger order still holds in escrow), plus constant getters for EIP-712 domains/typehashes, order lifetimes, min collateral, insurance-withdrawal limits, the liquidator reward (`getLiquidationRewardConstants`), the vault-health constants (the ADL reserve share, the unload band cap, the ADL timeout and batch size), and the mark-price constants (`getMarkConstants`: the maker exposure window in L2 blocks, the volume floor, the single-call cap, the print band and the decay period).

## External dependencies

| Dependency | Used for |
|---|---|
| Pyth (`IPyth`) | all pricing |
| UMA Optimistic Oracle V3 | listings, identifier upgrades, terminations (address immutable) |
| USDC (ERC-20 + ERC-2612) | sole collateral |
| Arbitrum `ArbSys` (`0x64`) | L2 block numbers |
| OpenZeppelin | `Clones`, `SafeERC20`, `IERC20Permit` (the pair's permit calls), `Math`, `SafeCast`, `Initializable`, `ReentrancyGuardTransient` (the pair; its flag lives in transient storage, so a clone needs no initialization and a guarded call pays no storage write), `ReentrancyGuard` (factory, terminator), `EnumerableSet`, `ECDSA`, `MessageHashUtils`, `Strings` |
