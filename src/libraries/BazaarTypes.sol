// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

/// @title BazaarTypes
/// @notice Shared type definitions for BazaarPair and its libraries
library BazaarTypes {
    // -------------------- Enums --------------------

    enum OrderType {
        Market,
        Limit,
        StopLimit,
        TakeProfit,
        StopLoss
    }

    enum OrderAction {
        Created,
        Updated,
        Canceled,
        Filled
    }

    // -------------------- Structs --------------------

    /// @dev Packed layout notes (for gas):
    ///  slot0: creator (20)
    ///  slot1: integrator (20)
    ///  slot2: triggerPrice (32)
    ///  slot3: limitPrice (32)
    ///  slot4: maxSlippageBp (32) — kept u256 for forward-compat with future precision
    ///  slot5: size (32)
    ///  slot6: filledSize (32)
    ///  slot7: orderType(1) + isLong(1) + isPostOnly(1) + creationBlock(8) + expiryBlock(8) + canceledBlock(8) + filledBlock(8) = 35 bytes → splits slot
    ///         Solidity packs: orderType(1)+isLong(1)+isPostOnly(1)+creationBlock(8)+expiryBlock(8)+canceledBlock(8) = 27 bytes slot7
    ///         filledBlock(8) = 8 bytes slot8
    struct Order {
        address creator;
        address integrator;
        uint256 triggerPrice;
        uint256 limitPrice;
        uint256 maxSlippageBp;
        uint256 size;
        uint256 filledSize;
        OrderType orderType;
        bool isLong;
        bool isPostOnly;
        uint64 creationBlock;
        uint64 expiryBlock;
        uint64 canceledBlock;
        uint64 filledBlock;
    }

    struct PositionBucket {
        bool isLong;
        uint256 size;
        uint256 entryValue;
        uint256 collateral;
        int256 entryFundingIndex;
        uint256 takeProfitOrderId;
        uint256 stopLossOrderId;
        uint256 entryMmrBp;
        uint256 activeMarketOrderId; // 1-active-market cap (0 = none, mirrors TP/SL pattern)
        uint256 mmrUpdateTs; // timestamp entryMmrBp was last set (open/increase/flip); 0 when flat
    }

    /// @notice One hourly snapshot of the pair's maintenance-margin rate, for the 24h-lagged
    ///         liquidation threshold. Stored in a fixed ring buffer (max 24 = 24 hours).
    struct MmrSample {
        uint64 ts; // block.timestamp the sample was taken
        uint256 mmrBp; // marginRequirements.mmrBp at that time
    }

    struct BucketState {
        int256 unrealizedPnl;
        int256 fundingPnl;
        int256 totalPnl;
        uint256 adjustedSize;
        uint256 currentNotional;
        uint256 entryValue;
        uint256 minRequiredCollateral;
        uint256 availableEquity;
        uint256 effectiveCollateral;
        int256 adjustedEntryFundingIndex;
        bool isSolvent;
        uint256 entryMmrBp;
        uint256 mmrUpdateTs; // carried from the bucket; persisted by updateFromState
    }

    struct FillResult {
        int256 longOIDelta;
        int256 shortOIDelta;
        int256 longWeightedDelta;
        int256 shortWeightedDelta;
        int256 sizeDelta;
        int256 realizedPnl;
        uint256 newSize;
        uint256 newEntryValue;
        uint256 newCollateral;
        bool newIsLong;
    }

    /// @notice Aggregate summary of a matchBatch call — hashed and stored for challenges.
    ///         Fields are hashed via abi.encode (not stored raw) so widths don't need to pack.
    /// @dev Per-type same-side aggregates carry the worst-priority order that matched
    ///      in each (side, type) bucket. For longs we track lowest eff price + highest
    ///      orderId at that price (FIFO). Symmetric for shorts. Pass-C-only fields are
    ///      witnesses for market-omission cross-side checks.
    struct BatchInfo {
        uint256 totalMatchNotional; // sum of all match notionals (bazaar-scale)
        uint256 oraclePrice; // oracle price at observationBlock
        uint64 executionBlock;
        uint64 observationBlock;
        uint64 matchTimestamp; // block.timestamp at execution
        address sequencer;
        bool isStale; // oracle stale at observationBlock

        // Cross-pass same-side (price, id) FIFO witnesses
        uint256 lowestLongLimitPrice;
        uint256 lowestLongLimitId;
        uint256 highestShortLimitPrice;
        uint256 highestShortLimitId;
        uint256 lowestLongMarketPrice;
        uint256 lowestLongMarketId;
        uint256 highestShortMarketPrice;
        uint256 highestShortMarketId;

        // Pass-C-only cross-side witnesses for market omission challenges
        uint256 lowestShortLimitPriceC;
        uint256 highestLongLimitPriceC;

        // Order IDs that passed normal IMR but failed stale-IMR (2x) — only populated
        // during stale batches. Membership rejects challenges in challengeOmission.
        uint256[] staleSkippedIds;
    }

    struct Vault {
        uint256 totalLongOI;
        uint256 totalShortOI;
        uint256 longWeightedEntrySum;
        uint256 shortWeightedEntrySum;
        uint256 totalCollateralDeposited;
        uint256 insuranceFundBalance;
        // Aggregate pending liquidation tracking (single-direction)
        uint256 pendingLiqSize; // total size of pending liquidations
        uint256 pendingLiqEntryNotional; // sum(entryPrice_i × size_i) — for PnL at match
        uint256 pendingLiqBankruptcyNotional; // sum(bankruptcyPrice_i × size_i) — for ADL settlement
        int256 pendingLiqEntryFundingIndex; // size-weighted avg of the liquidatees' ENTRY funding indices — settlement realizes funding over entry → close (estates' pre-liquidation balances + vault holding window together)
        bool pendingLiqIsLong; // original position direction (true = vault holds longs)
        // Realized bad debt: cumulative loss that exceeded the insurance fund and was dropped
        // (insurance floored at 0). A non-zero value is a definitive insolvency signal — the
        // vault cannot honor all claims — and triggers termination via isVaultHealthy.
        uint256 deficit;
    }

    /// @notice Absorb a loss into the insurance fund, recording any uncovered overrun as realized
    ///         bad debt. Shared by the Pass-A vault close (MatchingEngineLib) and the
    ///         opposing-liquidation netting (LiquidationLib) so the bad-debt accounting can't drift.
    ///         A non-zero `deficit` is the insolvency signal that isVaultHealthy terminates on.
    function absorbLossIntoInsurance(Vault storage v, uint256 loss) internal {
        if (loss > v.insuranceFundBalance) {
            v.deficit += loss - v.insuranceFundBalance;
            v.insuranceFundBalance = 0;
        } else {
            v.insuranceFundBalance -= loss;
        }
    }

    struct MarginRequirements {
        uint256 imrBp;
        uint256 mmrBp;
        uint256 lastUpdateTs;
        // The 24h-lagged MMR applicable to the current batch (newest sample >= MMR_GRACE_PERIOD
        // old, or 0 if none). Populated only in the per-batch in-memory copy returned by
        // BazaarPair._marginReqsWithLag(); the slot in the `marginRequirements` storage variable
        // is intentionally left 0 and never read (solvency always reads the memory copy).
        uint256 laggedMmrBp;
    }

    /// @notice Fixed ring buffer of hourly MMR samples. Sized to MMR_SAMPLE_COUNT (25) so that
    ///         hourly sampling retains a full 24h of history: 24 one-hour intervals need 25
    ///         sample points, so the oldest retained sample is >= 24h old in steady state and the
    ///         "newest sample at least 24h old" lookup actually has something to find.
    struct MmrSampleBuffer {
        MmrSample[25] samples; // chronological ring (MMR_SAMPLE_COUNT slots)
        uint256 head; // index of the next write slot
        uint256 count; // number of valid samples (<= MMR_SAMPLE_COUNT)
        uint256 lastSampleTs; // timestamp of the most recent sample
    }

    /// @notice Per-deposit insurance lot for vote-maturity (anti-snipe) tracking.
    ///         uint64 + uint192 pack into a single storage slot. Written by
    ///         InsuranceVaultLib.depositToInsurance, read by BazaarPair.getSharesAsOf.
    struct DepositLot {
        uint64 ts;
        uint192 shares;
    }

    struct PairPrice {
        uint256 spotPrice;
        uint256 emaVarianceBp;
        uint256 updateTs;
        uint256 lowPrice; // spotPrice − Pyth confidence, floored at 1 wei
        uint256 highPrice; // spotPrice + Pyth confidence
    }

    struct LiquidationGapEma {
        int256 emaGapBp;
        uint256 lastLiquidationTs;
        uint256 decayedSize;
    }

    struct IntegratorAccum {
        address integrator;
        uint256 amount;
    }

    /// @notice Auxiliary state vars exposed via the BazaarPair.auxState() batch getter.
    /// @dev Used by BazaarPairLens / frontends. Kept as a single getter to save bytecode
    ///      vs ~12 individual auto-generated getters.
    struct AuxState {
        uint256 lastFundingUpdateTs;
        uint256 lastMarkUpdateTs;
        uint256 rollingVolume;
        uint256 pairCreatedTs;
        uint256 priceUpdateCount;
        uint256 adlSnapshotPrice;
        int256 adlSnapshotFundingIndex; // funding index frozen at trigger; keepers score winners against this
        bool adlLongs;
        uint256 normalTerminationPrice;
        uint256 emergencyTerminalCollateralWithdrawalRatioBp;
        uint256 normalTerminalWinnersPayoutRatioBp;
        address bugBountyAddress;
    }

    /// @notice Groups scalar state variables shared with MatchingEngineLib via DELEGATECALL
    struct MatchingState {
        uint256 nextBatchId;
    }

    // -------------------- Constants --------------------

    int32 internal constant USDC_EXPONENT = -6;
    uint256 internal constant USDC_SCALE = 10 ** uint32(uint32(6)); // 1e6
    int32 internal constant BAZAAR_EXPONENT = -18;
    uint32 internal constant BAZAAR_DECIMALS = 18;
    uint256 internal constant BAZAAR_SCALE = 1e18;
    uint256 internal constant BP_SCALE = 10_000;
    uint256 internal constant EBP_SCALE = 1_000_000;

    // 24h-lagged maintenance-margin (anti-abrupt-liquidation). MMR is sampled at most once per
    // MMR_SAMPLE_INTERVAL into a ring buffer of MMR_SAMPLE_COUNT entries (24h of history).
    // A position older than MMR_GRACE_PERIOD is liquidated against the newest sample that is at
    // least MMR_GRACE_PERIOD old (the "lagged" MMR), so a rising MMR can't liquidate an existing
    // position for MMR_GRACE_PERIOD; newer positions use their own entry MMR.
    uint256 internal constant MMR_SAMPLE_INTERVAL = 1 hours;
    // 25 (not 24) slots: retaining a strictly >=24h-old sample under hourly sampling needs 25
    // points (24 one-hour intervals have 25 endpoints). Must match MmrSampleBuffer.samples length.
    uint256 internal constant MMR_SAMPLE_COUNT = 25;
    uint256 internal constant MMR_GRACE_PERIOD = 24 hours;

    // Sequencer fees in EBP
    uint256 internal constant MAKER_SEQUENCER_FEE_EBP = 25;
    uint256 internal constant TAKER_SEQUENCER_FEE_EBP = 75;

    // Flat sequencer fee per side ($0.03 in BAZAAR_SCALE), added on top of bps fees
    uint256 internal constant SEQUENCER_FLAT_FEE_PER_SIDE = 3 * BAZAAR_SCALE / 100; // $0.03

    // Integrator fees in EBP — charged only on orders that carry an integrator address;
    // direct-to-contract orders (integrator = address(0)) pay no integrator fee.
    uint256 internal constant MAKER_INTEGRATOR_FEE_EBP = 25;
    uint256 internal constant TAKER_INTEGRATOR_FEE_EBP = 25;

    // Liquidator reward in EBP of liquidated notional (2 bps). The per-position reward is
    // max(MIN_LIQUIDATOR_REWARD, LIQUIDATION_FEE_EBP of notional), paid at liquidation time.
    uint256 internal constant LIQUIDATION_FEE_EBP = 200;

    // Insurance fees in EBP
    uint256 internal constant MAKER_INSURANCE_FEE_EBP = 50;

    uint256 internal constant MAX_STALE_DEVIATION_BP = 1000;
    uint256 internal constant STALE_MARGIN_MULTIPLIER = 2;

    // Cap on slippage for vault liquidation fills (5%). The effective Pass A band is
    // min(this, current MMR) — tightens with the margin cushion in calm regimes.
    uint256 internal constant LIQ_MAX_SLIPPAGE_BP = 500;

    // Sentinel taker order ID for vault liquidation matches
    uint256 internal constant LIQ_TAKER_SENTINEL = type(uint256).max;

    // Bug bounty tax
    uint256 internal constant BUG_BOUNTY_TAX_BP = 100;

    // Order constants (shared between BazaarPair and OrderManagementLib)
    uint256 internal constant MIN_ORDER_AMOUNT = 5 * BAZAAR_SCALE;
    uint256 internal constant MAX_SLIPPAGE_BP = 500; // 5% max slippage for market-type orders

    // Block-based lifetime constants — Arbitrum ~250ms blocks (4 blocks/sec).
    // Derived from prior time-based 4s / 4s / 365d limits.
    uint64 internal constant MIN_ORDER_LIFETIME_BLOCKS = 12; // ~3 s
    uint64 internal constant MARKET_ORDER_LIFETIME_BLOCKS = 12; // ~3 s
    uint64 internal constant MAX_ORDER_LIFETIME_BLOCKS = 365 * 24 * 60 * 60 * 4; // ~126.1M, ~1 year

    // Per-user active-order caps (prevents calldata-flood DoS)
    uint256 internal constant MAX_ACTIVE_LIMIT_ORDERS_PER_USER = 100; // Limit + StopLimit combined

    // Sentinel: TP/SL orders never expire by block
    uint64 internal constant NEVER_EXPIRE_BLOCK = type(uint64).max;

    // Omission challenge penalty: 7% of min(batchNotional, orderNotional).
    // Chosen so that max sequencer gain from skipping (5% market-slippage) < penalty.
    uint256 internal constant OMISSION_PENALTY_BP = 700;

    // Liquidation reward floor (shared between BazaarPair and LiquidationLib).
    // Reward = max(this, LIQUIDATION_FEE_EBP of notional); the floor covers gas on small positions.
    uint256 internal constant MIN_LIQUIDATOR_REWARD = BAZAAR_SCALE / 10; // 0.10 USDC

    // ADL constants (shared between BazaarPair, AdlLib, BazaarPairLens)
    uint256 internal constant ADL_AUCTION_DURATION = 10 minutes;

    /// @notice Score ceiling the Dutch-auction threshold decays from (pnl = 25× collateral).
    uint256 internal constant ADL_MAX_SCORE = 25 * BAZAAR_SCALE;

    // Risk model constants (shared between BazaarPair and InsuranceVaultLib)
    uint256 internal constant VARIANCE_LOW = 2_000_000; // ~14% annualized vol
    uint256 internal constant VARIANCE_EXTREME = 100_000_000; // ~100% annualized vol
    uint256 internal constant INSURANCE_TARGET_BASE = 200; // 2% minimum target
    uint256 internal constant INSURANCE_TARGET_MAX = 1_000; // 10% maximum target

    // -------------------- Events --------------------

    /// @notice Emitted once per successful matchBatch call. Contains the full BatchInfo
    ///         preimage so challengers can reconstruct without extra storage.
    event BatchRecorded(bytes32 indexed pairId, uint256 indexed batchId, address indexed sequencer, BatchInfo info);

    // OrdersMatched was removed (MatchingEngineLib EIP-170 headroom): every field it carried is
    // in the two same-transaction OrderFilled events — fillSize/fillPrice/fees verbatim, and the
    // maker/taker labeling now lives in OrderFilled.isMaker. Pair matches emit two OrderFilled
    // events (one per side); vault-liquidation closes emit one (the user side, always maker).
    event OrderFilled(
        bytes32 indexed pairId,
        uint256 indexed orderId,
        address indexed user,
        bool isLong,
        uint256 fillSize,
        uint256 totalFilledSize,
        uint256 remainingSize,
        uint256 executionPrice,
        uint256 fee,
        bool isFullyFilled,
        bool isMaker // this side rested (rebate-tier sequencer fee); false = taker
    );

    event PositionModified(
        bytes32 indexed pairId,
        address indexed user,
        bool isLong,
        int256 sizeDelta,
        uint256 newSize,
        uint256 newEntryValue,
        uint256 newCollateral,
        uint256 executionPrice,
        uint256 fee,
        int256 realizedPnl
    );

    /// @dev Bundled payload — keeps the OrderUpdated emit signature shallow enough for via_ir.
    struct OrderUpdatePayload {
        OrderAction action;
        OrderType orderType;
        bool isLong;
        bool isPostOnly;
        uint256 size;
        uint256 filledSize;
        uint256 triggerPrice;
        uint256 limitPrice;
        uint256 maxSlippageBp;
        uint64 canceledBlock;
        uint64 filledBlock;
        uint64 expiryBlock;
        uint64 creationBlock;
    }

    event OrderUpdated(
        bytes32 indexed pairId, uint256 indexed orderId, address indexed owner, OrderUpdatePayload payload
    );

    event PositionBucketUpdated(
        bytes32 indexed pairId,
        address indexed owner,
        bool isLong,
        uint256 size,
        uint256 entryValue,
        uint256 collateral,
        int256 entryFundingIndex,
        int256 globalFundingIndex,
        uint256 imrBp,
        uint256 mmrBp,
        uint256 entryMmrBp
    );

    event MetaTransactionExecuted(
        bytes32 indexed pairId,
        address indexed user,
        address indexed relayer,
        bytes32 functionId,
        uint256 nonce,
        uint256 relayerFee
    );

    event CollateralDeposited(bytes32 indexed pairId, address indexed user, uint256 amount);

    event CollateralWithdrawn(bytes32 indexed pairId, address indexed user, uint256 amount, bool positionClosed);

    event InsuranceDeposited(bytes32 indexed pairId, address indexed user, uint256 amount, uint256 sharesReceived);

    event InsuranceWithdrawalRequested(bytes32 indexed pairId, address indexed user, uint256 shareAmount);

    event InsuranceWithdrawalExecuted(
        bytes32 indexed pairId, address indexed user, uint256 shareAmount, uint256 usdcAmount
    );

    // -------------------- CollateralLib Structs --------------------

    /// @notice Parameters for depositCollateral
    struct DepositParams {
        uint256 amount; // deposit amount in BAZAAR precision
        int256 currentFundingIndex; // current global funding index
        MarginRequirements marginReqs; // current margin requirements
        bytes32 pairId; // pair identifier for events
        bool isPairTerminatedEmergency; // whether pair is emergency-terminated
        bool isPairTerminatedNormal; // whether pair is normal-terminated
        uint256 scheduledTerminationTs; // scheduled termination timestamp (0 if none)
        uint64 currentBlock; // L2 block number at tx execution time
    }

    /// @notice Parameters for withdrawCollateral
    struct CollateralWithdrawParams {
        uint256 amount; // withdrawal amount in BAZAAR precision (0 = full)
        uint256 currentPrice; // current spot price (BAZAAR precision)
        int256 currentFundingIndex; // current global funding index
        MarginRequirements marginReqs; // current margin requirements
        bytes32 pairId; // pair identifier for events
        bool isPairTerminatedEmergency; // whether pair is emergency-terminated
        bool isPairTerminatedNormal; // whether pair is normal-terminated
        bool pendingTermination; // scheduledTerminationTs has passed but terminatePair() not yet executed
        uint256 emergencyHaircutBp; // emergencyTerminalCollateralWithdrawalRatioBp
        bool isOracleStale; // true when oracle is stale
        uint256 normalTerminationPrice; // settlement price for normal termination
        uint256 normalTerminalWinnersPayoutRatioBp; // payout ratio for winning positions on normal termination
        uint256 normalTerminalCollateralRatioBp; // principal haircut for deep-insolvency normal termination (BP_SCALE/0 = none)
        bool isVaultHealthy; // result of vault health check (only relevant when exposure present)
        uint8 vaultHealthReason; // reason code from vault health check
        uint256 outstandingLongOrderExposure; // total notional of user's active long limit orders
        uint256 outstandingShortOrderExposure; // total notional of user's active short limit orders
        uint64 currentBlock; // L2 block number at tx execution time
    }

    /// @notice Result from withdrawCollateral
    struct CollateralWithdrawResult {
        uint256 withdrawAmount; // amount to transfer to user (BAZAAR precision)
        uint256 totalCollateralDecrease; // amount to subtract from pairVault.totalCollateralDeposited
        bool positionClosed; // true if position was fully settled (normal termination)
        bool isLong; // direction of closed position (only valid if positionClosed)
        uint256 closedSize; // size of closed position (only valid if positionClosed)
        uint256 closedEntryValue; // entry value of closed position (only valid if positionClosed)
    }

    // -------------------- LiquidationLib Structs --------------------

    struct LiquidateParams {
        uint256 currentPrice;
        int256 currentFundingIndex;
        MarginRequirements marginReqs;
        bytes32 pairId;
        uint64 currentBlock;
        address usdc; // USDC token — LiquidationLib pays the liquidator reward directly (EIP-170 relief for BazaarPair)
    }

    struct LiquidateResult {
        uint256 liquidatedCount;
        uint256 totalUpfrontReward; // sum of max(floor, 2bps × notional) per position, for the caller to transfer
    }

    // -------------------- MatchingEngineLib Structs --------------------

    /// @notice Shared matching context — built once by BazaarPair and passed by reference
    ///         to the walk library to minimize calldata/memory copies.
    struct MatchContext {
        uint256 cachedPrice;
        uint256 cachedLow; // existing-portion valuation: long buckets at low
        uint256 cachedHigh; // existing-portion valuation: short buckets at high
        int256 cachedFundingIdx;
        uint256 insuranceFeeEbp;
        uint256 takerSequencerFeeEbp;
        uint256 remainingCapacity;
        uint256 closingFeeEbp;
        bool isOracleStale;
        MarginRequirements marginReqs;
        bytes32 pairId;
        uint64 observationBlock;
        uint64 currentBlock;
        address usdc;
        address bugBountyAddress;
        address sequencer;
        uint256 bugBountyTaxBp;
        uint256 maxMatches; // sequencer-supplied gas-safety circuit breaker
    }

    /// @notice Bundled order-ID lists for matchBatch. Bundling 4 calldata arrays into one
    ///         struct reduces stack pressure on the matching engine entry point under via_ir.
    struct OrderLists {
        uint256[] longLimits;
        uint256[] shortLimits;
        uint256[] longMarkets;
        uint256[] shortMarkets;
    }

    /// @notice Accumulated results for a full matchBatch call (memory-only, never stored).
    ///         Per-type aggregates are populated during the walk and copied into BatchInfo at finalize.
    /// @dev `staleSkippedIds` is preallocated to totalIds capacity at executeBatch entry; only
    ///      indices [0, staleSkippedCount) are valid. At finalize, the array is truncated via
    ///      assembly to staleSkippedCount before being copied to BatchInfo.
    /// @dev Aggregate (OI deltas, fees) and IntegratorBag are bundled here too — saves stack
    ///      pressure in the matching engine by avoiding separate mem-pointer params.
    struct BatchResult {
        uint256 successCount;
        // Σ fillNotional across all passes — serves triple duty: capacity checks + recordVolume,
        // the VWAP numerator (Σ price×size ≡ Σ notional), and BatchInfo.totalMatchNotional.
        // (Former sumPriceTimesSize / totalMatchNotional fields accumulated this same number.)
        uint256 totalMatchedVolume;
        uint256 totalFillSize; // VWAP denominator

        // Cross-pass same-side aggregates
        uint256 lowestLongLimitPrice;
        uint256 lowestLongLimitId;
        uint256 highestShortLimitPrice;
        uint256 highestShortLimitId;
        uint256 lowestLongMarketPrice;
        uint256 lowestLongMarketId;
        uint256 highestShortMarketPrice;
        uint256 highestShortMarketId;

        // Pass-C-only cross-side witnesses
        uint256 lowestShortLimitPriceC;
        uint256 highestLongLimitPriceC;

        // Stale-skip list — preallocated; staleSkippedCount tracks valid prefix length.
        uint256[] staleSkippedIds;
        uint256 staleSkippedCount;

        // Liquidation-EMA accumulators (Pass A)
        int256 sumLiqGapTimesSize;
        uint256 totalLiqFillSize;
        uint256 liqCount;

        // Aggregate (OI deltas, fees, vault PnL) — populated during walk, applied in _finalize
        int256 deltaLongOI;
        int256 deltaShortOI;
        int256 deltaLongWeightedEntry;
        int256 deltaShortWeightedEntry;
        uint256 totalUserSeqFees;
        uint256 totalIntegratorFees;
        uint256 totalInsuranceFees;
        int256 totalVaultPnl;

        // Integrator dedup buffer (preallocated to 2x the batch fill bound at executeBatch
        // entry — each match can append two distinct integrators, one per side)
        IntegratorAccum[] integratorAccums;
        uint256 integratorCount;
    }

    // -------------------- TerminationLib Structs --------------------

    /// @notice Parameters for TerminationLib.executeTermination
    struct TerminationParams {
        bool isEmergency;
        uint256 terminationPrice;
        address usdc; // USDC token address for balanceOf
        bytes32 pairId;
    }

    /// @notice Results from TerminationLib.executeTermination — written back by BazaarPair
    struct TerminationResult {
        bool isEmergency;
        bool isNormal;
        uint256 normalTerminationPrice;
        uint256 emergencyCollateralRatioBp;
        uint256 winnersPayoutRatioBp;
        uint256 normalCollateralRatioBp; // principal haircut for deep-insolvency normal termination (BP_SCALE = none)
    }

    // -------------------- OrderManagementLib Structs --------------------

    struct CreateOrderParams {
        bytes32 pairId;
        bool isLong;
        uint256 size;
        uint256 triggerPrice;
        uint256 limitPrice;
        uint256 maxSlippageBp;
        OrderType orderType;
        uint64 expirationBlock; // absolute block number (not TTL)
        bool isPostOnly;
        address integrator;
        uint256 currentPrice; // cached oracle price
        int256 currentFundingIndex;
        MarginRequirements marginReqs;
        bool isOracleStale;
        uint256 nextOrderId; // will be updated
        uint256 outstandingLongOrderExposure; // total notional of user's active long limit orders
        uint256 outstandingShortOrderExposure; // total notional of user's active short limit orders
        uint64 currentBlock; // L2 block number at tx execution time
    }

    // -------------------- InsuranceVaultLib Structs --------------------

    /// @notice Rate-limit state for insurance withdrawals
    struct InsuranceWithdrawalRateLimitState {
        uint256 withdrawnThisPeriod;
        uint256 periodStart;
        uint256 periodCap;
    }

    /// @notice Parameters for executeInsuranceWithdrawal
    struct InsuranceWithdrawParams {
        bool isPairTerminatedEmergency;
        bool isPairTerminatedNormal;
        uint256 scheduledTerminationTs;
        uint256 adlPendingSince;
        uint256 spotPrice;
        uint256 emaVarianceBp;
        int256 emaGapBp;
        uint256 lockedShares; // shares locked in active insurer-vote termination proposal
    }

    // -------------------- AdlLib Structs --------------------

    /// @notice Result of an ADL execution batch
    struct AdlResult {
        uint256 eligibleSize;
        uint256 eligibleCount;
        uint256 highestAdlScore;
        uint256 lowestAdlScore;
        uint256 totalLiqSize; // total size settled via ADL
        uint256 settlementPrice; // avgBP used for settlement
    }

    /// @notice Parameters for AdlLib.executeAdlCore
    struct AdlParams {
        bool adlLongs;
        uint256 adlSnapshotPrice;
        int256 adlSnapshotFundingIndex;
        uint256 adlPendingSince;
        uint256 currentPrice;
        // Live funding index at execution — used for SETTLEMENT valuation and bucket-update events,
        // not for ranking.
        int256 currentFundingIndex;
        MarginRequirements marginRequirements;
        bytes32 pairId;
        uint256 adlId; // installment id for this executeAdl call; emitted in AdlExecuted
        uint64 currentBlock;
    }
}
