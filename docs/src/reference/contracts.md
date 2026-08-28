# Contracts

Access-control legend: **anyone** = permissionless · **bonded** = permissionless with economic stake · **wired** = callable only by a registered protocol contract.

## BazaarPair — `src/BazaarPair.sol`

One EIP-1167 clone per market. Initialized once by the factory.

| Function | Access | Purpose |
|---|---|---|
| `depositCollateral` / `withdrawCollateral` | anyone / meta-tx | collateral in/out; withdrawal enforces IMR at bracket prices and, while a position is open, retention of `mmrBp` (continuously traded) or `imrBp` (session-bound) of notional in collateral proper |
| `createOrder` / `cancelOrders` | anyone / meta-tx | matching happens on arrival, inside `createOrder` itself — see [Orders](../protocol/orders.md) and [Matching](../protocol/matching.md) |
| `executeTriggeredOrders(execs[], …)` | anyone | fires triggered stops against a fresh Pyth price for a $0.25 tip per stop, charged to each stop's owner |
| `unloadVault(maxSteps, …)` | anyone | crosses the vault's pending liquidation inventory into the book for a reward — see [Liquidations](../protocol/liquidations.md) |
| `sweepExpired(orderIds[])` | anyone | janitor: cancels-and-unlinks expired orders that no walk has touched yet |
| `liquidate(users[], …)` | anyone | full liquidation of insolvent buckets — and, once a settlement price is fixed, the terminal-settlement entry point (no price update, no ETH, no solvency threshold) |
| `executeAdl(winners[], …)` | anyone | Dutch-auction deleveraging |
| `depositToInsurance` / `requestInsuranceWithdrawal` / `executeInsuranceWithdrawal` | anyone / meta-tx | insurance LP flows |
| `refreshPrice` | anyone | push a Pyth update, roll funding/margin state |
| `creditInsurance` | wired (terminator) | books forfeited insurer bonds |
| `setScheduledTermination` / `fixSettlementPrice` | wired (terminator) | lifecycle transitions (`finalizeTermination` is public after the 48 h settlement window; settling positions at the fixed price runs through `liquidate`) |

Key views: `book` (list heads and counts), `positionBuckets`, `orders` (including each order's `prevInBook`/`nextInBook` links), `lastPairPrice`, `getSharesAsOf`, plus everything on the lens.

## BazaarFactory — `src/BazaarFactory.sol`

| Function | Access |
|---|---|
| `proposePairDeployment` / `settleDeploymentProposal` | anyone (bonded) |
| `proposeUmaIdentifierUpgrade` / `settleIdentifierUpgradeProposal` | anyone (bonded) |
| `activateIdentifierUpgrade` | anyone, once the 14-day post-approval timelock elapses |
| `expireStuckDeploymentProposal` / `expireStuckIdentifierUpgradeProposal` | anyone, once the proposal is provably unsettleable |
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
| `updateAndFetchPrice` / `fetchHistoricalPrice` | anyone, payable (Pyth fee) |
| `tryReadFreshPrice` / `tryReadStalePrice` / `getUpdateFee` / `getCompositeId` | view |

## BazaarPairTerminator — `src/BazaarPairTerminator.sol`

| Function | Access |
|---|---|
| `proposeTermination` / `proposePostCessationTermination` / `settleTerminationProposal` | anyone (bonded) — both proposals take a `pairDescription` and a `reason`, [charset- and length-bounded](../protocol/termination.md#proposer-supplied-text) |
| `terminateScheduledPair` / `terminateStalePair` | anyone |
| `proposeInsurerTermination` / `voteForInsurerTermination` / `executeInsurerTermination` | insurance shareholders (bonded) / anyone to execute |
| `registerPair` | wired (factory) |
| UMA callbacks | wired (recorded OO) |
| `requiredTerminationBond` / `getLockedShares` / `isPair` | view |

## BazaarPairLens — `src/BazaarPairLens.sol`

Stateless views: `getPositionBucket`, `checkBucketSolvency`, `getInsuranceSharePrice`, `getInsuranceDepositValue`, `getAdlScoreThreshold`, `getAdlScore` (a candidate's auction score and eligibility, exactly as `executeAdl` ranks them — sort submissions by it descending), `getTerminalEntitlement` (post-termination payout components: collateral, registered claim, frozen ratio), `getTerminalSettlementBounty` (a sweep keeper's reward for settling a position at the fixed price), `getMaxWithdrawable` (the largest withdrawal the margin/retention gates would accept — pass the conservative bracket price: spot − conf for a long, spot + conf for a short), `getPendingLiquidationExposure`, `getAuxState`, `getBookDepth` (a head-to-tail page of one book side, read through the pair's `book()` heads and `orders()` links — for depth displays and hint computation), `findPredecessor` (the resume-able hint helper for `MatchHints.pred`), plus constant getters for EIP-712 domains/typehashes, order lifetimes, min collateral, insurance-withdrawal limits, and vault-health thresholds. Note: the pair's `getUserActiveLimitOrders` mutates (lazy cleanup) — `eth_call` it, don't index it as pure.

## External dependencies

| Dependency | Used for |
|---|---|
| Pyth (`IPyth`) | all pricing |
| UMA Optimistic Oracle V3 | listings, identifier upgrades, terminations (address immutable) |
| USDC (ERC-20 + ERC-2612) | sole collateral |
| Arbitrum `ArbSys` (`0x64`) | L2 block numbers |
| OpenZeppelin | `Clones`, `SafeERC20`, `Math`, `Initializable`, `ReentrancyGuard`, `EnumerableSet`, `ECDSA`, `Strings` |
