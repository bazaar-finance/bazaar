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

    /// @notice What an arriving order does with the size the book could not fill it for.
    ///         GTC — rest the remainder in the book. Only Limit and StopLimit can honour this;
    ///               the types that never rest behave as IOC whatever they carry.
    ///         IOC — fill what crosses on arrival, cancel the remainder.
    ///         FOK — fill the whole size on arrival or revert the transaction, leaving no
    ///               partial and no order behind.
    /// @dev One axis with three mutually exclusive values rather than a flag per behaviour: the
    ///      combinations that separate booleans would allow (IOC and FOK at once, neither) have
    ///      no meaning, and making them unrepresentable is cheaper than rejecting them. The three
    ///      cases are also a strict ordering of how long an order may live, which is why they
    ///      share one field instead of describing independent properties.
    enum TimeInForce {
        GTC,
        IOC,
        FOK
    }

    // -------------------- Structs --------------------

    /// @dev Packed layout (5 slots, zero padding — the walk copies a full Order per node
    ///  visited and creation writes every slot, so slot count is the dominant per-order storage
    ///  cost):
    ///  slot0: creator(20)+canceledBlock(8)+orderType(1)+isLong(1)+isPostOnly(1)+tif(1) = 32
    ///  slot1: integrator(20)+expiryBlock(8)+inBook(1)+maxSlippageBp(3) = 32
    ///  slot2: triggerPrice(16)+limitPrice(16) = 32
    ///  slot3: size(16)+filledSize(16) = 32
    ///  slot4: creationBlock(8)+filledBlock(8)+prevInBook(8)+nextInBook(8) = 32
    ///
    ///  The terminal stamps are deliberately placed in slots that creation already leaves
    ///  non-zero — canceledBlock beside `creator`, filledBlock beside `creationBlock`. A stamp
    ///  written into an otherwise-zero slot would cost a fresh SSTORE rather than a dirty one,
    ///  which on the cancel path is most of the transaction. For the same reason the two book
    ///  links share slot 4 rather than sitting alone: clearing them on unlink then rewrites a
    ///  slot that is already non-zero.
    ///
    ///  uint128 prices/sizes are not the binding constraint on magnitude: the notional math
    ///  (size × price / BAZAAR_SCALE) makes any value near 2^128 unusable protocol-wide long
    ///  before the field saturates, and creation checks the narrowing casts. maxSlippageBp is
    ///  bounded by MAX_SLIPPAGE_BP at creation, far inside uint24.
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
        uint64 canceledBlock;
        OrderType orderType;
        bool isLong;
        bool isPostOnly;
        TimeInForce tif;
        address integrator;
        uint64 expiryBlock;
        bool inBook;
        uint24 maxSlippageBp;
        uint128 triggerPrice;
        uint128 limitPrice;
        uint128 size;
        uint128 filledSize;
        uint64 creationBlock;
        uint64 filledBlock;
        uint64 prevInBook;
        uint64 nextInBook;
    }

    /// @notice Head state of the pair's resting order book: two sorted doubly-linked lists
    ///         threaded through the orders mapping via Order.prevInBook/nextInBook.
    /// @dev One slot. bidHead is the best bid (highest limitPrice, oldest orderId at ties);
    ///      askHead is the best ask (lowest limitPrice, oldest at ties); 0 = empty side. The
    ///      counts track live nodes per side for lens pagination and traversal invariants.
    ///      Ordering keys off limitPrice alone — every restable type (Limit and armed StopLimit)
    ///      is limit-priced, so list order is oracle-independent and never decays.
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
        TimeInForce tif;
        uint256 size;
        uint256 triggerPrice;
        uint256 limitPrice;
        uint256 maxSlippageBp;
        uint64 expirationBlock; // absolute L2 block (not TTL)
        address integrator;
    }

    /// @dev Packed layout (4 slots — every fill copies both sides' buckets and settles them
    ///  back, so slot count is the dominant per-fill storage cost):
    ///  slot0: isLong(1)+size(16) = 17
    ///  slot1: entryValue(16)+collateral(16) = 32
    ///  slot2: entryFundingIndex(32)
    ///  slot3: takeProfitOrderId(8)+stopLossOrderId(8)+entryMmrBp(4)+mmrUpdateTs(8) = 28
    ///  uint128 size/entryValue/collateral are not the binding magnitude constraint: the
    ///  notional math overflows uint256 far below 2^128-scale values, and collateral is bounded
    ///  by the pair's deposits ledger. entryFundingIndex stays full-width — it is an unbounded
    ///  cumulative index. Order ids fit uint64 (per-pair monotonic counter from 1); entryMmrBp
    ///  is a bp rate bounded by the margin curve, far inside uint32.
    struct PositionBucket {
        bool isLong;
        uint128 size;
        uint128 entryValue;
        uint128 collateral;
        int256 entryFundingIndex;
        uint64 takeProfitOrderId;
        uint64 stopLossOrderId;
        uint32 entryMmrBp;
        uint64 mmrUpdateTs; // timestamp entryMmrBp was last set (open/increase/flip); 0 when flat
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
        // The insurance target ratio the margin curve last computed, cached here because the
        // ADL gate and the unload walk size the fund's reserve from it and reach the vault
        // through libraries that do not carry the EMAs it is derived from.
        uint256 targetInsuranceRatioBp;
        // Collateral the fund actually received alongside the inventory it still holds, in
        // BAZAAR_SCALE precision. Tracked rather than recovered from the two notionals: the
        // bankruptcy price folds in the funding the estate had accrued before liquidation, and
        // the vault's funding leg realizes that same stretch again from the estate's entry, so
        // a recovery from entry − bankruptcy would count it twice and misplace the price at
        // which the inventory is whole. Decremented proportionally with every unit that leaves.
        uint256 pendingLiqSeized;
    }

    /// @notice Pull-payment escrow for every USDC the pair owes a third party: integrator fees,
    ///         the bug-bounty tax, keeper tips and rewards (trigger execution, vault unload,
    ///         liquidation, ADL, price refresh), the UMA proposer reward and relayer fees.
    ///         Payers credit `claimable` through FeeEscrowLib.credit instead of pushing USDC, so
    ///         no entry point runs a token transfer to an address outside the protocol's trust
    ///         boundary; recipients withdraw via BazaarPair.claimFees.
    /// @dev `total` is the sum of all `claimable` balances — a liability against the pair's
    ///      USDC that every books-vs-cash formula must reserve alongside D and I: the health
    ///      check's expected balance, and the terminal surplus/reserve computations. USDC for
    ///      these fees stays in the contract until claimed, so omitting `total` anywhere reads
    ///      escrowed fee cash as distributable surplus.
    struct FeeEscrow {
        uint256 total;
        mapping(address => uint256) claimable;
    }

    struct MarginRequirements {
        uint256 imrBp;
        uint256 mmrBp;
        uint256 lastUpdateTs;
        // The 24h-lagged MMR applicable to the current batch (newest sample recorded at least
        // MMR_GRACE_PERIOD before the mark being valued against) and the timestamp of the sample
        // it came from; both 0 when the ring holds nothing that old. The timestamp is what lets
        // BucketLib.effectiveMmr reject a sample taken before
        // a position existed — entryMmrBp is by definition the rate as of the bucket's
        // mmrUpdateTs, so a sample stamped earlier than that describes a rate the position never
        // opened under. Populated only in the per-batch in-memory copy returned by
        // BazaarPair._marginReqsWithLag(); the slots in the `marginRequirements` storage variable
        // are intentionally left 0 and never read (solvency always reads the memory copy).
        uint256 laggedMmrBp;
        uint256 laggedMmrTs;
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

    /// @dev Deliberately UNPACKED, unlike Order and PositionBucket. Packing this to two slots
    ///  would save a few thousand gas on the price write, but the mask/shift code for it lands
    ///  in BazaarPair — which sits at the EIP-170 ceiling — rather than in a library, and the
    ///  contract cannot afford it. The two packed structs carry far more gas value per byte
    ///  spent: they are read and written per fill, and their access code lives in the matching
    ///  library.
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
        uint256 settlementPrice; // fixed terminal price (0 while the pair is live)
        uint256 terminalPrincipalRatioBp; // frozen at finalize: cash paid per unit of bucket collateral
        uint256 terminalProfitRatioBp; // frozen at finalize: cash paid per unit of registered profit claim
        uint256 terminalProfitClaims; // Σ registered winner profit (settlement-window tally)
        uint256 terminalBadDebt; // Σ settled losses beyond collateral (settlement-window tally)
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
    // A position is liquidated against the newest sample recorded at least MMR_GRACE_PERIOD
    // before the mark it is valued against (the "lagged" MMR), so a rising MMR can't liquidate an
    // existing position for MMR_GRACE_PERIOD. That substitution is conditioned on the sample
    // being no older than the
    // position's own mmrUpdateTs, not on the position's age: because the sample grid is
    // MMR_SAMPLE_INTERVAL-spaced while the rate itself moves on IMR_UPDATE_COOLDOWN, the newest
    // sample at or below the cutoff can predate the position, and applying it would judge the
    // position against a market it never traded in. Positions with no qualifying sample use their
    // own entry MMR.
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

    // Stale-fallback fill band. Fresh-oracle fills are unbanded: the fill-time margin gates
    // price fresh exposure at the live oracle and charge the fill-vs-mark gap up front, and
    // FundingLib clamps every print to ±MAX_MARK_DEVIATION_BP of index before it enters the mark
    // EMA — an off-mark fill is economically real for its two parties and cannot drag the
    // funding mark everyone else pays against. Under the stale fallback those gates judge
    // against an aged reference, so fills are confined to cachedPrice × (1 ± band). A breach
    // toward the taker cancels the resting maker; away from the taker, the arrival.
    uint256 internal constant MAX_STALE_DEVIATION_BP = 1000;

    // Cap on the oracle leg of the vault unload bound (5%): the vault takes makers within
    // min(this, current MMR) of the oracle, or at any price that beats the estates' fund-neutral
    // price, whichever admits more. The same band edge is where the ADL auction stops closing
    // winners: it releases once the fund above its reserve could finish the remaining inventory
    // there.
    uint256 internal constant LIQ_MAX_SLIPPAGE_BP = 500;

    /// @notice Share of the insurance target the unload walk may never spend, in bp of the
    ///         target ratio. Free capital above this reserve is what the vault may lose selling
    ///         inventory and what the ADL gate measures expected loss against; the reserve
    ///         itself stays for the realizations no bound can refuse — opposing liquidations
    ///         netting at the oracle price, a capped seizure coming due — and for the keeper
    ///         rewards the fund pays. Sized from the target rather than the fund so it is a
    ///         fixed dollar amount at any moment: a walk that spends free capital moves the
    ///         budget one for one and never re-derives a fresh share of what is left.
    uint256 internal constant ADL_RESERVE_BP = 2_000;

    // Bug bounty tax
    uint256 internal constant BUG_BOUNTY_TAX_BP = 100;

    /// @notice Smallest insurance seed a pair may be initialized with.
    /// @dev Lives here because two contracts enforce it at different moments and must not drift:
    ///      BazaarFactory rejects an under-funded proposal up front, and BazaarPair.initialize
    ///      rejects an under-funded seed at deployment — which happens inside OOv3's resolve
    ///      callback, where a revert would take settlement down with it and strand both the escrow
    ///      and the pairId permanently. One constant makes the two checks the same check.
    uint256 internal constant MIN_INSURANCE_SEED = 3_000 * BAZAAR_SCALE;

    // Termination constants (shared between BazaarPair and InsuranceVaultLib)
    /// @dev Escape hatch for finalize: once this much time has passed since the settlement price
    ///      was fixed, finalizeTermination proceeds with positions still open. Lives here because
    ///      InsuranceVaultLib measures the insurers' sweep grace from the same point, and the two
    ///      must not drift.
    uint256 internal constant TERMINAL_SETTLEMENT_ESCAPE = 14 days;
    /// @dev After an escape-hatch finalize, insurance withdrawals wait for every position finalize
    ///      did not wait for to be settled, or for this much time beyond the escape hatch,
    ///      whichever comes first.
    uint256 internal constant INSURER_SWEEP_GRACE = 14 days;

    // Order constants (shared between BazaarPair and OrderManagementLib)
    uint256 internal constant MIN_ORDER_AMOUNT = 5 * BAZAAR_SCALE;
    uint256 internal constant MAX_SLIPPAGE_BP = 1000; // 10% max slippage for market-type orders
    // Placement sanity band for a Limit order's resting price (±50% of the mark at creation).
    // Deliberately wide: resting deep to catch a reopen gap is a legitimate strategy the margin
    // system is built for, so this only rejects prices that can be nothing but an input error —
    // or an attempt to satisfy notional checks at a price the market will never see.
    uint256 internal constant MAX_PLACEMENT_DEVIATION_BP = 5000;

    // Order-lifetime constants, in Arbitrum L2 blocks (~250ms each, 4 blocks/sec).
    uint64 internal constant MIN_ORDER_LIFETIME_BLOCKS = 12; // ~3 s
    uint64 internal constant MAX_ORDER_LIFETIME_BLOCKS = 365 * 24 * 60 * 60 * 4; // ~126.1M, ~1 year

    // Per-user active-order cap (Limit + StopLimit combined). Bounds each user's worst-case book
    // footprint and, more sharply, the exposure tally that createOrder and withdrawCollateral run
    // over the caller's active-order set: that walk re-reads every live order, so its cost grows
    // linearly with this number and the cap sets the worst case a single caller can impose.
    // Matched to MAX_WALK_STEPS so the protocol's two bounded per-transaction iterations share one
    // ceiling — sized, like that one, to keep the worst case a modest fraction of an Arbitrum
    // block. Sixteen price levels a side is well beyond what an on-chain maker quotes: every
    // level is its own transaction here, so depth is bought with gas rather than posted freely.
    uint256 internal constant MAX_ACTIVE_LIMIT_ORDERS_PER_USER = 32;

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

    // Keeper tip for settling another trader's position at the fixed terminal price. Before
    // finalize every open position holds the completeness gate shut for everyone, so every
    // settlement by a non-owner pays: from whatever collateral the settled position has left,
    // with insurance covering the remainder. After finalize only a bankrupt straggler harms
    // anyone (its shortfall stays unbooked until it is settled), so only that settlement pays,
    // from the insurers' residual. Owners settle their own positions for nothing, as the
    // withdrawal path already does.
    uint256 internal constant TERMINAL_SETTLEMENT_TIP = BAZAAR_SCALE / 10; // $0.10

    // unloadVault pays its caller max(UNLOAD_BOUNTY_MIN, LIQUIDATION_FEE_EBP of unloaded
    // notional) from insurance free capital, gated on either unloading at least UNLOAD_BOUNTY_MIN_NOTIONAL or
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

    /// @notice Runway a timed-out auction gets, measured from the first stored price after the
    ///         timeout, before anyone may terminate the pair on the clock.
    /// @dev Non-continuously traded pairs cannot execute ADL while their market is closed: every
    ///      ADL path requires a fresh price, and no signed update exists to supply. Without this
    ///      grace the auction and the termination it is racing both unblock in the same block at
    ///      reopen, and whoever calls first wins — with termination favoured, since the auction
    ///      needs its winners submitted in a sorted batch. That is the auction's strongest moment
    ///      (threshold fully decayed, reopen gap finally on-chain), so it is the worst one to lose
    ///      by a race. Arming from the stored price rather than from a wall-clock offset keeps the
    ///      window independent of how long the market was shut: a weekend and a holiday closure
    ///      both yield exactly this much fresh-priced runway.
    uint256 internal constant ADL_TERMINATION_GRACE = 30 minutes;

    /// @notice Score ceiling the Dutch-auction threshold decays from (pnl = 25× collateral).
    uint256 internal constant ADL_MAX_SCORE = 25 * BAZAAR_SCALE;

    /// @notice Share of the bad debt a batch averts that the executor is paid, from insurance.
    /// @dev Shared with AdlLib: the payout is a fund debit proportional to the size closed, so
    ///      the size that restores health has to account for it or every batch lands just the
    ///      reward's worth short of the release level.
    uint256 internal constant ADL_EXECUTOR_REWARD_BP = 10; // 0.1%

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

    /// @notice Emitted when a fee or reward is accrued to `recipient`'s claimable balance.
    event FeeAccrued(bytes32 indexed pairId, address indexed recipient, uint256 amount);

    /// @notice Emitted when an escrowed fee balance is paid out.
    event FeesClaimed(bytes32 indexed pairId, address indexed recipient, uint256 amount);

    event CollateralWithdrawn(bytes32 indexed pairId, address indexed user, uint256 amount);

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
        bool isPairTerminated; // finalized: no new principal
        uint256 scheduledTerminationTs; // scheduled termination timestamp (0 if none)
        uint64 currentBlock; // L2 block number at tx execution time
    }

    /// @notice Parameters for withdrawCollateral
    struct CollateralWithdrawParams {
        uint256 amount; // withdrawal amount in BAZAAR precision
        uint256 currentPrice; // current spot price (BAZAAR precision)
        int256 currentFundingIndex; // current global funding index
        MarginRequirements marginReqs; // current margin requirements
        bytes32 pairId; // pair identifier for events
        bool isPairTerminated; // finalized: terminal payout branch
        bool pendingTermination; // scheduledTerminationTs has passed but the settlement price is not yet fixed
        bool isOracleStale; // stale price fallback in use — position-holder withdrawals revert
        uint256 settlementPrice; // fixed terminal price (terminal branch only)
        bool isVaultHealthy; // result of vault health check (only relevant when exposure present)
        uint8 vaultHealthReason; // reason code from vault health check
        uint256 outstandingLongOrderExposure; // active long-order exposure: max(limit notional, size × mark) per side
        uint256 outstandingShortOrderExposure; // active short-order exposure: max(limit notional, size × mark) per side
        uint64 currentBlock; // L2 block number at tx execution time
        bool isContinuouslyTraded; // selects the retained-cash floor rate: mmrBp (24/7) vs imrBp (session-bound)
    }

    // -------------------- LiquidationLib Structs --------------------

    struct LiquidateParams {
        uint256 currentPrice;
        int256 currentFundingIndex;
        MarginRequirements marginReqs;
        bytes32 pairId;
        uint64 currentBlock;
    }

    struct LiquidateResult {
        uint256 liquidatedCount;
        uint256 totalUpfrontReward; // accrued to the liquidator's claimable balance: Σ max(floor, 2bps × notional) per position, capped at the fund's free capital
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
        uint256 settlementPrice; // the fixed terminal price
        address usdc; // USDC token address for balanceOf
        bytes32 pairId;
        int256 currentFundingIndex; // frozen funding index — values the estate's funding leg
        // Fee-escrow liability. Fees earned before termination stay owed to their earners and
        // their USDC stays claimable, so the distributable pot nets it out first; counting it
        // would pay it to traders and insurers twice over.
        uint256 claimableFeesTotal;
        bool sweepComplete; // true when no trader position was left open at finalize
    }

    /// @notice Terminal-settlement state. The two tallies accumulate while positions are
    ///         settled at the fixed price; finalize turns them, together with the vault
    ///         ledgers, into the two frozen payout ratios. Lives in BazaarPair storage, passed
    ///         to libs by reference.
    struct TerminalSettlement {
        uint256 totalProfitClaims; // Σ registered winner PnL (settlements before finalize)
        uint256 terminalBadDebt; // Σ settled losses beyond collateral (funding incl.)
        uint256 principalRatioBp; // frozen at finalize: cash paid per unit of bucket collateral
        uint256 profitRatioBp; // frozen at finalize: cash paid per unit of registered claim
    }

    /// @notice Parameters for the internal _settleOne terminal-settlement helper. No marginReqs:
    ///         settlement PnL ignores margins, and the bucket-update event uses a zeroed default.
    struct TerminalSettleParams {
        uint256 settlementPrice; // the fixed terminal price
        int256 currentFundingIndex;
        bool postFinalize; // false: tally into the settlement state; true: realize against the frozen ledgers
        bytes32 pairId;
    }

    // -------------------- OrderManagementLib Structs --------------------

    struct CreateOrderParams {
        bytes32 pairId;
        OrderSpec spec; // the signed user intent, nested to keep flattened field count low under via_ir
        uint256 currentPrice; // cached oracle price
        int256 currentFundingIndex;
        MarginRequirements marginReqs;
        uint256 nextOrderId; // will be updated
        uint256 outstandingLongOrderExposure; // active long-order exposure: max(limit notional, size × mark) per side
        uint256 outstandingShortOrderExposure; // active short-order exposure: max(limit notional, size × mark) per side
        uint64 currentBlock; // L2 block number at tx execution time
    }

    // -------------------- InsuranceVaultLib Structs --------------------

    /// @notice Rate-limit state for insurance withdrawals
    struct InsuranceWithdrawalRateLimitState {
        uint256 withdrawnThisPeriod;
        uint256 periodStart;
        uint256 periodCap;
    }

    /// @notice Parameters for executeInsuranceWithdrawal. The mark, the variance EMA and the
    ///         liquidation-gap EMA are read from the pair's storage through the storage pointers
    ///         the call carries alongside this struct.
    struct InsuranceWithdrawParams {
        bool isPairTerminated;
        uint256 scheduledTerminationTs;
        uint8 vaultHealthReason; // isVaultHealthy verdict judged in this call: 0 = healthy, 1 = liquidation exposure over insurance (0 on a terminated pair)
        bool isContinuouslyTraded; // false adds the reopen-gap leg to the fund target
        address umaContract; // BazaarPairTerminator, asked for the caller's vote-locked shares
        int256 currentFundingIndex; // live cumulative funding index, for valuing the vault's inherited inventory
        uint256 settlementPriceFixedTs; // when the settlement price was fixed; anchors the post-finalize sweep grace
    }

    // -------------------- AdlLib Structs --------------------

    /// @notice Result of an ADL execution batch
    struct AdlResult {
        uint256 eligibleSize;
        uint256 eligibleCount;
        uint256 highestAdlScore;
        uint256 lowestAdlScore;
        uint256 totalLiqSize; // total size settled via ADL
        uint256 settlementPrice; // price the batch settled at: avg bankruptcy price, or a mark better for the fund
    }

    /// @notice Parameters for AdlLib.executeAdlCore
    struct AdlParams {
        bool adlLongs;
        uint256 adlSnapshotPrice;
        int256 adlSnapshotFundingIndex;
        // Start of the auction's CURRENT Dutch-decay run, which a market discontinuity restarts.
        // Distinct from the pair's adlPendingSince, which dates the window itself and stays
        // monotone so the termination clock cannot be pushed back.
        uint256 adlAuctionStartTs;
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
