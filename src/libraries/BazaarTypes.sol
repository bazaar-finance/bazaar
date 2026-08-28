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
    ///  slot7: orderType(1)+isLong(1)+isPostOnly(1)+isIoc(1)+inBook(1)+creationBlock(8)+expiryBlock(8)+canceledBlock(8) = 29 bytes
    ///  slot8: filledBlock(8)+prevInBook(8)+nextInBook(8) = 24 bytes
    ///  A full fill stamps filledBlock and clears both links in a single slot-8 write; a cancel
    ///  stamps canceledBlock and clears inBook in a single slot-7 write.
    ///
    ///  prevInBook/nextInBook thread the resting order book through the orders mapping as two
    ///  doubly-linked lists (bids: limitPrice DESC, orderId ASC; asks: limitPrice ASC, orderId
    ///  ASC — see OrderBookLib). uint64 links are safe: orderIds come from a per-pair monotonic
    ///  counter starting at 1, which cannot plausibly reach 2^64. inBook is an explicit
    ///  membership flag rather than a link sentinel because a singleton head has both links 0 —
    ///  indistinguishable from a non-member without a head lookup — and the flag makes unlink an
    ///  unconditionally safe no-op on orders that never rested (untriggered stops, market
    ///  orders).
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
        bool isIoc;
        bool inBook;
        uint64 creationBlock;
        uint64 expiryBlock;
        uint64 canceledBlock;
        uint64 filledBlock;
        uint64 prevInBook;
        uint64 nextInBook;
    }

    /// @notice Head state of the pair's resting order book: two sorted doubly-linked lists
    ///         threaded through the orders mapping via Order.prevInBook/nextInBook.
    /// @dev One slot. bidHead is the best bid (highest limitPrice, oldest orderId at ties);
    ///      askHead is the best ask (lowest limitPrice, oldest at ties); 0 = empty side. The
    ///      counts track live nodes per side for lens pagination and traversal invariants.
    ///      Ordering keys off limitPrice alone — every restable type (Limit, TakeProfit, armed
    ///      StopLimit) is limit-priced, so list order is oracle-independent and never decays.
    struct OrderBook {
        uint64 bidHead;
        uint64 askHead;
        uint64 bidCount;
        uint64 askCount;
    }

    /// @notice Caller-supplied execution aids for the matching walk and book insertion. Not part
    ///         of any EIP-712 payload: hints are position predictions, not user intent, so a
    ///         relayer attaches fresh ones at submission time (like priceUpdate). Every hint is
    ///         verified against the actual neighbors before linking — a wrong hint can only fail
    ///         placement, never mis-place an order.
    /// @dev pred is the orderId the new order should rest directly behind (0 = insert at head);
    ///      pred2..pred4 are fallback candidates (0 = unused) tried in sequence when earlier ones
    ///      have left the book. maxSteps caps nodes visited by the matching walk (0 = protocol
    ///      default MAX_WALK_STEPS).
    struct MatchHints {
        uint64 pred;
        uint64 pred2;
        uint64 pred3;
        uint64 pred4;
        uint32 maxSteps;
    }

    /// @notice The user-intent half of an order creation — exactly the fields covered by the
    ///         EIP-712 CreateOrder payload (execution aids like MatchHints and priceUpdate ride
    ///         outside the signature).
    struct OrderSpec {
        OrderType orderType;
        bool isLong;
        bool isPostOnly;
        bool isIoc; // Limit only: fill what crosses on arrival, cancel the remainder
        uint256 size;
        uint256 triggerPrice;
        uint256 limitPrice;
        uint256 maxSlippageBp;
        uint64 expirationBlock; // absolute L2 block (not TTL)
        address integrator;
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
    ///         Written by InsuranceVaultLib.depositToInsurance, read by
    ///         BazaarPair.getSharesAsOf.
    /// @dev `shares` is deliberately FULL-WIDTH (two slots per lot, not one). Packing it beside
    ///      `ts` would need an overflow guard on append, and repeated drain-and-recapitalize
    ///      cycles inflate the share supply — so that guard could permanently brick insurance
    ///      deposits while the fund was still alive. A share count can be as large as the supply
    ///      itself, so it gets a whole slot; the extra SSTORE per deposit is the price of never
    ///      bricking recap.
    struct DepositLot {
        uint64 ts;
        uint256 shares;
    }

    struct PairPrice {
        uint256 spotPrice;
        uint256 emaVarianceBp;
        uint256 updateTs;
        uint256 lowPrice; // spotPrice − Pyth confidence, floored at 1 wei
        uint256 highPrice; // spotPrice + Pyth confidence
    }

    /// @notice The price observation the variance EMA was last advanced from.
    /// @dev Held separately from PairPrice so the variance clock is independent of the price
    ///      clock. PairPrice.updateTs advances on every stored price, so measuring the sampling
    ///      interval against it would put every interval on a pair touched more often than
    ///      RiskParamsLib.VARIANCE_UPDATE_COOLDOWN under the cooldown, discarding every sample
    ///      and pinning the EMA at its seed value for the life of the pair. Advancing this
    ///      sample only when the EMA advances makes a fast update cadence defer a sample rather
    ///      than drop it, and keeps the measured return and the interval it is annualized over
    ///      spanning the same two observations.
    ///      Packed into one slot. uint192 is not the binding constraint on price magnitude: the
    ///      pair's own notional math (size × price / BAZAAR_SCALE) overflows well below it, so a
    ///      price this field could not hold is unusable protocol-wide. Publish times are Unix
    ///      seconds.
    struct VarianceSample {
        uint192 spotPrice;
        uint64 publishTs;
    }

    /// @dev Peak-hold floor for a non-continuously traded pair's reopen gap: the largest
    ///      |return| observed across a market discontinuity — closure, halt, or trading break
    ///      (a price-storage gap of at least RiskParamsLib.REOPEN_GAP_MIN_STALENESS) — decayed
    ///      slowly between observations. Feeds calculateIMRandMMR's gap leg — the non-continuous
    ///      IMR is 2 x max(vol curve, gapEmaBp) — so margin covers the pair's demonstrated jump
    ///      risk, which intraday variance says little about. Packed into one slot; gapEmaBp is
    ///      capped at REOPEN_GAP_EMA_CAP_BP so uint192 is never binding.
    struct ReopenGapEma {
        uint64 lastObsTs; // publishTime of the last accepted observation (0 = none yet)
        uint192 gapEmaBp; // peak-hold reopen-gap magnitude in bp
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

    // Cap on slippage for vault liquidation fills (5%). The effective Pass A band is
    // min(this, current MMR) — tightens with the margin cushion in calm regimes.
    uint256 internal constant LIQ_MAX_SLIPPAGE_BP = 500;

    // Bug bounty tax
    uint256 internal constant BUG_BOUNTY_TAX_BP = 100;

    /// @notice Smallest insurance seed a pair may be initialized with.
    /// @dev Lives here because two contracts enforce it at different moments and must not drift:
    ///      BazaarFactory rejects an under-funded proposal up front, and BazaarPair.initialize
    ///      rejects an under-funded seed at deployment — which happens inside OOv3's resolve
    ///      callback, where a revert would take settlement down with it and strand both the escrow
    ///      and the pairId permanently. One constant makes the two checks the same check.
    uint256 internal constant MIN_INSURANCE_SEED = 3_000 * BAZAAR_SCALE;

    // Order constants (shared between BazaarPair and OrderManagementLib)
    uint256 internal constant MIN_ORDER_AMOUNT = 5 * BAZAAR_SCALE;
    uint256 internal constant MAX_SLIPPAGE_BP = 500; // 5% max slippage for market-type orders

    // Order-lifetime constants, in Arbitrum L2 blocks (~250ms each, 4 blocks/sec).
    uint64 internal constant MIN_ORDER_LIFETIME_BLOCKS = 12; // ~3 s
    uint64 internal constant MAX_ORDER_LIFETIME_BLOCKS = 365 * 24 * 60 * 60 * 4; // ~126.1M, ~1 year

    // Per-user active-order caps (bounds the exposure-tally iteration in deposit/withdraw margin
    // checks and each user's worst-case book footprint)
    uint256 internal constant MAX_ACTIVE_LIMIT_ORDERS_PER_USER = 100; // Limit + StopLimit combined

    // Shared node-visit ceiling for book walks: caps the matching walk (MatchHints.maxSteps is
    // clamped to it; 0 selects it as the default) and caps OrderBookLib's insert repair walk.
    // Sized so the worst-case arrival — 32 cold settlements in one transaction — stays a modest
    // fraction of an Arbitrum block, leaving the chain's throughput to other traffic. A taker
    // wanting more depth splits it across transactions.
    uint256 internal constant MAX_WALK_STEPS = 32;

    // Keeper tip for executing a triggered StopLimit/StopLoss, charged from the stop owner's
    // bucket collateral at execution time (like a trading fee — no escrow). An owner whose
    // collateral cannot cover it has the stop auto-canceled instead, mirroring the fee-coverage
    // rule in the fill margin gate. No tip is charged when a stop arms immediately at creation.
    uint256 internal constant TRIGGER_TIP = BAZAAR_SCALE / 4; // $0.25

    // unloadVault pays its caller max(UNLOAD_BOUNTY_MIN, LIQUIDATION_FEE_EBP of unloaded
    // notional) from insurance, gated on either unloading at least UNLOAD_BOUNTY_MIN_NOTIONAL or
    // clearing the inventory outright. The floor covers a keeper's gas even in an expensive
    // block, so clearing inventory is always worth doing rather than worth waiting out; the
    // notional gate is set exactly where the bps term overtakes that floor
    // (UNLOAD_BOUNTY_MIN / LIQUIDATION_FEE_EBP), so splitting one large unload into many
    // minimum-sized calls earns no more than doing it in one — only the final clearing call can
    // ever collect the floor on a small amount.
    uint256 internal constant UNLOAD_BOUNTY_MIN = BAZAAR_SCALE / 4; // $0.25
    uint256 internal constant UNLOAD_BOUNTY_MIN_NOTIONAL = 1_250 * BAZAAR_SCALE; // 2 bp of this == $0.25

    // Bounds one executeTriggeredOrders call (each exec can run a full walk).
    uint256 internal constant MAX_TRIGGER_EXECS_PER_CALL = 20;

    // Node budget for the unload walk run inline at the end of liquidate() — bounds the
    // liquidator's gas; the permissionless unloadVault handles anything deeper.
    uint256 internal constant LIQ_INLINE_UNLOAD_STEPS = 16;

    // Sentinel: TP/SL orders never expire by block
    uint64 internal constant NEVER_EXPIRE_BLOCK = type(uint64).max;

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

    // OrderFilled is the sole per-fill event: it carries fillSize/fillPrice/fees plus the
    // maker/taker label in `isMaker`, so no separate match-level event is emitted. A pair match
    // emits two (one per side); a vault-liquidation close emits one (the user side, always maker).
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
        bool isMaker // this side rested in the book and set the fill price; false = taker
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
        bool isOracleStale; // stale price fallback in use — position-holder withdrawals revert
        uint256 normalTerminationPrice; // settlement price for normal termination
        uint256 normalTerminalCollateralRatioBp; // principal haircut for deep-insolvency normal termination (BP_SCALE/0 = none)
        bool isVaultHealthy; // result of vault health check (only relevant when exposure present)
        uint8 vaultHealthReason; // reason code from vault health check
        uint256 outstandingLongOrderExposure; // total notional of user's active long limit orders
        uint256 outstandingShortOrderExposure; // total notional of user's active short limit orders
        uint64 currentBlock; // L2 block number at tx execution time
        address usdcToken; // USDC address — terminal branch reads cash for the surplus clip
        bool isContinuouslyTraded; // selects the retained-cash floor rate: mmrBp (24/7) vs imrBp (session-bound)
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

    /// @notice Shared context for one arrival-matching transaction — built once by BazaarPair
    ///         and passed by reference to the walk library. Snapshotting the price, funding
    ///         index, fee rates, and margin params up front makes every fill in the transaction
    ///         judge against the same basis.
    struct ArrivalContext {
        uint256 cachedPrice; // single valuation basis for the whole tx: existing and fresh exposure alike
        int256 cachedFundingIdx;
        uint256 insuranceFeeEbp;
        uint256 closingFeeEbp;
        bool isOracleStale;
        MarginRequirements marginReqs;
        bytes32 pairId;
        uint64 currentBlock;
        address usdc;
        address bugBountyAddress;
    }

    /// @notice Accumulated results of one walk (memory-only, never stored). Fills add their
    ///         deltas here; a single finalize step applies everything to storage once per walk.
    struct ArrivalResult {
        uint256 fillCount;
        // Σ fillNotional — the VWAP numerator (Σ price×size ≡ Σ notional) and unloaded notional.
        uint256 totalMatchedVolume;
        uint256 totalFillSize; // VWAP denominator

        // Liquidation-EMA accumulators (unload walks only)
        int256 sumLiqGapTimesSize;
        uint256 totalLiqFillSize;
        uint256 liqCount;

        // OI deltas, fees, vault PnL — populated during the walk, applied in finalize
        int256 deltaLongOI;
        int256 deltaShortOI;
        int256 deltaLongWeightedEntry;
        int256 deltaShortWeightedEntry;
        uint256 totalIntegratorFees;
        uint256 totalInsuranceFees;
        int256 totalVaultPnl;

        // Deposits-ledger headroom remaining for fee attribution: seeded from
        // totalCollateralDeposited at walk start, drawn down by every charged fill. Fees
        // are collected from book collateral but settled against the deposits ledger in
        // finalize, and book collateral can legitimately exceed that ledger (open losers
        // back profits that were already withdrawn) — so a fill whose fees exceed the
        // remaining budget has ALL its fees waived (nothing charged, nothing paid out)
        // rather than collecting a fee the ledger cannot fund.
        uint256 feeBudget;

        // Integrator dedup buffer (preallocated to 2x the walk's node cap — each fill can
        // append two distinct integrators, one per side)
        IntegratorAccum[] integratorAccums;
        uint256 integratorCount;

        uint256 nodesVisited; // enforced against the walk's node cap, counting skips too
    }

    /// @notice Compact per-walk summary returned to BazaarPair for its post-walk hooks
    ///         (mark-price VWAP, liquidation-gap EMA, vault health, unload bounty).
    struct WalkSummary {
        uint256 totalMatchedVolume;
        uint256 totalFillSize;
        int256 sumLiqGapTimesSize;
        uint256 totalLiqFillSize;
        uint256 liqCount;
    }

    /// @notice One triggered-stop execution request: the stop's id plus the hints its walk and
    ///         (for StopLimit) its remainder insertion should use.
    struct TriggerExec {
        uint64 orderId;
        MatchHints hints;
    }

    // -------------------- TerminationLib Structs --------------------

    /// @notice Parameters for TerminationLib.executeTermination
    struct TerminationParams {
        bool isEmergency;
        uint256 terminationPrice;
        address usdc; // USDC token address for balanceOf
        bytes32 pairId;
        int256 currentFundingIndex; // frozen funding index — settles the estate funding leg
    }

    /// @notice Terminal-settlement state for the two-stage normal termination (frozen-ratio
    ///         design). Registered profit claims accumulate during the 48h settlement window;
    ///         finalize charges bad debt to insurance and freezes profitRatioBp once. Principal
    ///         (totalCollateralDeposited) is reserved at all times; profits pay only from the
    ///         surplus = cash - D - I. Lives in BazaarPair storage, passed to libs by reference.
    struct TerminalSettlement {
        uint256 totalProfitClaims; // Σ registered winner PnL (window settlements only)
        uint256 terminalBadDebt; // Σ uncovered losses (loss beyond collateral, funding incl.)
        uint256 profitRatioBp; // frozen at finalize: min(BP_SCALE, surplus / claims)
        uint256 profitReserve; // still-unpaid portion of registered claims x ratio
    }

    /// @notice Parameters for the internal _settleOne terminal-settlement helper. No marginReqs:
    ///         settlement PnL ignores margins, and the bucket-update event uses a zeroed default.
    struct TerminalSettleParams {
        uint256 settlementPrice; // the fixed terminal price
        int256 currentFundingIndex;
        bool postFinalize; // false: window (register claims); true: junior/late path
        bool payBounty; // false for inline self-settlement during withdraw
        bytes32 pairId;
        address usdc;
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
        OrderSpec spec; // the signed user intent, nested to keep flattened field count low under via_ir
        uint256 currentPrice; // cached oracle price
        int256 currentFundingIndex;
        MarginRequirements marginReqs;
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
        uint256 reopenGapBp; // ReopenGapEma.gapEmaBp for non-continuously traded pairs, 0 otherwise (raises the fund target)
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
