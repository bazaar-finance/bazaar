# Contracts

Access-control legend: **anyone** = permissionless · **bonded** = permissionless with economic stake · **wired** = callable only by a registered protocol contract.

## BazaarPair — `src/BazaarPair.sol`

One EIP-1167 clone per market. Initialized once by the factory.

| Function | Access | Purpose |
|---|---|---|
| `depositCollateral` / `withdrawCollateral` | anyone / meta-tx | collateral in/out; withdrawal enforces IMR at bracket prices and, while a position is open, the `max(0.5% of notional, $5)` retained floor |
| `createOrder` / `cancelOrders` | anyone / meta-tx | see [Orders](../protocol/orders.md) |
| `matchBatch` | bonded sequencer | three-pass batch matching |
| `liquidate(users[], …)` | anyone | full liquidation of insolvent buckets — and, once a settlement price is fixed, the terminal-settlement entry point (no price update, no ETH, no solvency threshold) |
| `executeAdl(winners[], …)` | anyone | Dutch-auction deleveraging |
| `depositToInsurance` / `requestInsuranceWithdrawal` / `executeInsuranceWithdrawal` | anyone / meta-tx | insurance LP flows |
| `refreshPrice` | anyone | push a Pyth update, roll funding/margin state |
| `creditInsuranceFromSequencer` | wired (sequencer) | books slash proceeds |
| `setScheduledTermination` / `fixSettlementPrice` / `creditInsuranceFromTerminator` | wired (terminator) | lifecycle transitions (`finalizeTermination` is public after the 48 h settlement window; settling positions at the fixed price runs through `liquidate`) |

Key views: `batchHashes`, `positionBuckets`, `orders`, `lastPairPrice`, `getSharesAsOf`, plus everything on the lens.

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

## BazaarSequencer — `src/BazaarSequencer.sol`

| Function | Access |
|---|---|
| `deposit` / `withdraw` | anyone (own bond) |
| `challengeOmission` / `challengeStaleBatch` | anyone |
| `recordVolume` | wired (registered pairs) |
| `registerPair` | wired (factory) |
| `checkVolumeCapacity` / `getRollingVolume` / `getDynamicTakerSequencerFee` | view |

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

Stateless views: `getPositionBucket`, `checkBucketSolvency`, `getInsuranceSharePrice`, `getInsuranceDepositValue`, `getAdlScoreThreshold`, `getAdlScore` (a candidate's auction score and eligibility, exactly as `executeAdl` ranks them — sort batches by it descending), `getTerminalEntitlement` (post-termination payout components: collateral, registered claim, frozen ratio), `getTerminalSettlementBounty` (a sweep keeper's reward for settling a position at the fixed price), `getMaxWithdrawable` (the largest withdrawal the margin/retention gates would accept — pass the conservative bracket price: spot − conf for a long, spot + conf for a short), `getPendingLiquidationExposure`, `getAuxState`, plus constant getters for EIP-712 domains/typehashes, order lifetimes, min collateral, insurance-withdrawal limits, vault-health thresholds, and the flat sequencer fee. Note: the pair's `getUserActiveLimitOrders` mutates (lazy cleanup) — `eth_call` it, don't index it as pure.

## External dependencies

| Dependency | Used for |
|---|---|
| Pyth (`IPyth`) | all pricing |
| UMA Optimistic Oracle V3 | listings, identifier upgrades, terminations (address immutable) |
| USDC (ERC-20 + ERC-2612) | sole collateral |
| Arbitrum `ArbSys` (`0x64`) | L2 block numbers |
| OpenZeppelin | `Clones`, `SafeERC20`, `Math`, `Initializable`, `ReentrancyGuard`, `EnumerableSet`, `ECDSA`, `Strings` |
