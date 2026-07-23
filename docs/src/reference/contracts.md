# Contracts

Access-control legend: **anyone** = permissionless · **bonded** = permissionless with economic stake · **wired** = callable only by a registered protocol contract.

## BazaarPair — `src/BazaarPair.sol`

One EIP-1167 clone per market. Initialized once by the factory.

| Function | Access | Purpose |
|---|---|---|
| `depositCollateral` / `withdrawCollateral` | anyone / meta-tx | collateral in/out; withdrawal enforces IMR at bracket prices |
| `createOrder` / `cancelOrders` | anyone / meta-tx | see [Orders](../protocol/orders.md) |
| `matchBatch` | bonded sequencer | three-pass batch matching |
| `liquidate(users[], …)` | anyone | full liquidation of insolvent buckets |
| `executeAdl(winners[], …)` | anyone | Dutch-auction deleveraging |
| `depositToInsurance` / `requestInsuranceWithdrawal` / `executeInsuranceWithdrawal` | anyone / meta-tx | insurance LP flows |
| `refreshPrice` | anyone | push a Pyth update, roll funding/margin state |
| `creditInsuranceFromSequencer` | wired (sequencer) | books slash proceeds |
| `setScheduledTermination` / `fixSettlementPrice` / `creditInsuranceFromTerminator` | wired (terminator) | lifecycle transitions (`finalizeTermination` is public after the 1 h sweep window) |

Key views: `batchHashes`, `positionBuckets`, `orders`, `lastPairPrice`, `getSharesAsOf`, plus everything on the lens.

## BazaarFactory — `src/BazaarFactory.sol`

| Function | Access |
|---|---|
| `proposePairDeployment` / `settleDeploymentProposal` | anyone (bonded) |
| `proposeUmaOracleUpgrade` / `settleOracleUpgradeProposal` | anyone (bonded) |
| `activateOracleUpgrade` | anyone, once the 14-day post-approval timelock elapses |
| `assertionResolvedCallback` / `assertionDisputedCallback` | wired (the UMA OO recorded per assertion) |
| `getPairAddress` / `isPair` / `getAllPairs` / `pairsCount` / proposal getters | view |

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
| `proposeTermination` / `proposePostCessationTermination` / `settleTerminationProposal` | anyone (bonded) |
| `terminateScheduledPair` / `terminateStalePair` | anyone |
| `proposeInsurerTermination` / `voteForInsurerTermination` / `executeInsurerTermination` | insurance shareholders (bonded) / anyone to execute |
| `registerPair` | wired (factory) |
| UMA callbacks | wired (recorded OO) |

## BazaarPairLens — `src/BazaarPairLens.sol`

Stateless views: `getPositionBucket`, `checkBucketSolvency`, `getInsuranceSharePrice`, `getInsuranceDepositValue`, `getAdlScoreThreshold`, `getPendingLiquidationExposure`, `getAuxState`, plus constant getters for EIP-712 domains/typehashes, order lifetimes, min collateral, insurance-withdrawal limits, vault-health thresholds, and the flat sequencer fee. Note: the pair's `getUserActiveLimitOrders` mutates (lazy cleanup) — `eth_call` it, don't index it as pure.

## External dependencies

| Dependency | Used for |
|---|---|
| Pyth (`IPyth`) | all pricing |
| UMA Optimistic Oracle V3 | listings, oracle upgrades, terminations |
| USDC (ERC-20 + ERC-2612) | sole collateral |
| Arbitrum `ArbSys` (`0x64`) | L2 block numbers |
| OpenZeppelin | `Clones`, `SafeERC20`, `Math`, `Initializable`, `ReentrancyGuard`, `EnumerableSet`, `ECDSA`, `Strings` |
