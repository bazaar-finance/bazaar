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

    /// @notice The lifecycle step an OrderUpdated event reports. Fills are reported by Trade and
    ///         amendments by OrderAmended.
    ///         Created   — createOrder stored the order; its arrival walk, if any, follows.
    ///         Triggered — a StopLimit, StopLoss or TakeProfit met its trigger and began its
    ///                     walk, either on arrival or when a keeper fired it. The payload shows
    ///                     a TP/SL's size already capped at the position it closes, and a
    ///                     keeper-armed StopLimit's new prioritySeq.
    ///         Canceled  — terminal; cancelReason says why.
    enum OrderAction {
        Created,
        Triggered,
        Canceled
    }

    /// @notice Why an order was canceled. None on every OrderUpdated that is not a cancellation.
    ///         Owner          — its owner canceled it, directly or through a relayer.
    ///         Expired        — its expiry block had passed.
    ///         Unfilled       — a Market or IOC Limit order still had size left when its walk
    ///                          ended. A fired StopLoss or TakeProfit is never canceled for this:
    ///                          it stays live outside the book for the next execution.
    ///         BelowMinimum   — its remainder was worth less than MIN_ORDER_AMOUNT and was not a
    ///                          live full close, so it could not rest.
    ///         PostOnly       — a post-only order would have filled on arrival.
    ///         SelfMatch      — it would have filled against a resting order of its own owner.
    ///         StepLimit      — its walk used up its node budget while it still crossed the book.
    ///                          Never applied to a trigger-gated order: one that hits the budget
    ///                          keeps its fills and stays live for the next execution.
    ///         Margin         — the fill would have failed its owner's margin check, including
    ///                          the requirement that collateral cover the fill's fee.
    ///         PriceBand      — under the stale-price fallback, the fill fell outside
    ///                          MAX_STALE_DEVIATION_BP of the fallback price.
    ///         PositionClosed — a TakeProfit or StopLoss whose position went flat or flipped side,
    ///                          leaving nothing for it to close.
    ///         Liquidated     — its owner's position was liquidated.
    ///         Deleveraged    — its owner's position was closed in full by ADL.
    enum CancelReason {
        None,
        Owner,
        Expired,
        Unfilled,
        BelowMinimum,
        PostOnly,
        SelfMatch,
        StepLimit,
        Margin,
        PriceBand,
        PositionClosed,
        Liquidated,
        Deleveraged
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
    ///  slot4: prioritySeq(6)+filledBlock(8)+restedBlock(4)+restedPremiumPpm(2)+prevInBook(6)
    ///         +nextInBook(6) = 32
    ///
    ///  nextInBook keeps the top of slot 4: the walk reads it at every node it visits, and a field
    ///  that ends at the word boundary is read with one shift and no mask.
    ///
    ///  The terminal stamps are deliberately placed in slots that creation already leaves
    ///  non-zero — canceledBlock beside `creator`, filledBlock beside `prioritySeq`. A stamp
    ///  written into an otherwise-zero slot would cost a fresh SSTORE rather than a dirty one,
    ///  which on the cancel path is most of the transaction. For the same reason the two book
    ///  links and the two resting stamps share slot 4 rather than sitting alone: linking writes
    ///  all four into a slot prioritySeq already made non-zero, and clearing the links on unlink
    ///  then rewrites a slot that is already non-zero.
    ///
    ///  uint128 prices/sizes are not the binding constraint on magnitude: the notional math
    ///  (size × price / BAZAAR_SCALE) makes any value near 2^128 unusable protocol-wide long
    ///  before the field saturates, and creation checks the narrowing casts. maxSlippageBp is
    ///  bounded by MAX_SLIPPAGE_BP at creation, far inside uint24.
    ///
    ///  prevInBook/nextInBook thread the resting order book through the orders mapping as two
    ///  doubly-linked lists (bids: limitPrice DESC, prioritySeq ASC; asks: limitPrice ASC,
    ///  prioritySeq ASC — see OrderBookLib). uint48 links and a uint48 prioritySeq are safe: ids
    ///  and queue positions come from one per-pair monotonic counter starting at 1, which cannot
    ///  plausibly reach 2^48. inBook is an explicit membership flag rather than a link sentinel
    ///  because a singleton head has both links 0 — indistinguishable from a non-member without
    ///  a head lookup — and the flag makes unlink an unconditionally safe no-op on orders that
    ///  never rested (untriggered stops, market orders).
    ///
    ///  restedBlock is the L2 block from which the order has stood where it now stands: written
    ///  by every link into the book (a remainder resting on arrival, a StopLimit arming, an
    ///  amendment that moves the order), kept by a size reduction, which relinks nothing, and by
    ///  an arrival on the stale fallback, which leaves a trigger order waiting outside the book
    ///  with its trigger unjudged (MatchingEngineLib.executeArrival). For a resting maker it is
    ///  the start of its exposure, read as the weight its fills carry into the mark
    ///  (FundingLib.makerExposureWeight): a standing offer on the far side of the index is a
    ///  quote anyone could have taken, and the longer it stood untaken the more a print against
    ///  it says about where the market clears. For a trigger order the stale fallback left
    ///  waiting it is the creation block, which executeTriggers compares with its own: an
    ///  execution in that block pays the bounty to the owner rather than the caller. Zero for an
    ///  order that has stood nowhere — one that never rested, or a trigger order whose creation
    ///  read a fresh price that did not meet its trigger. Stored as the block's low 32 bits and
    ///  compared modulo 2^32, which is exact for any order younger than 2^32 blocks — decades at
    ///  Arbitrum's cadence, far past any order's lifetime.
    ///
    ///  restedPremiumPpm is how far on the far side of the index the order stood when that link
    ///  was made — a bid's distance above the index or an ask's below it, in millionths of the
    ///  index, rounded up and capped at the mark's band (FundingLib.restedPremiumOf). Zero for
    ///  a link on the near side or at the index, and for one made without a fresh index (the
    ///  stale fallback), since a quote measured against an old price was not on offer at the
    ///  distance it reads. It is the most premium a fill against the order can carry into the
    ///  mark (FundingLib.printPriceOf): restedBlock prices how long a quote stood, and this
    ///  prices where it stood. Without it a quote that rested safely on the near side would
    ///  enter the mark at full weight the moment the index moved through it, though it was never
    ///  on offer on the far side to anyone. What a stamp can still overstate is bounded by how
    ///  far the index moves within MAX_PRICE_STALENESS, the age a fresh index may have: a quote
    ///  stamped against a slightly older price can sit on the near side of the live one. Every
    ///  link writes it and a size reduction keeps it, as with restedBlock; it is read only while
    ///  the order rests.
    ///
    ///  prioritySeq is the order's place within its price level, drawn from the same counter as
    ///  the ids: the order's own id at creation, and a fresh counter value whenever the order
    ///  joins its level later than that — an amend that sends it to the back (a new price, or a
    ///  larger size), or a keeper arming a StopLimit, which enters the book only then. It
    ///  therefore equals the id for every order that rested on arrival and was never amended. The
    ///  id stays the storage key and the handle every link, set, escrow and event uses; only the
    ///  queue position moves. Sharing the counter keeps every value unique across both uses, so
    ///  two resting orders can never tie, and leaves the ids with gaps, which nothing relies on.
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
        uint48 prioritySeq;
        uint64 filledBlock;
        uint32 restedBlock;
        uint16 restedPremiumPpm;
        uint48 prevInBook;
        uint48 nextInBook;
    }

    /// @notice Head state of the pair's resting order book: two sorted doubly-linked lists
    ///         threaded through the orders mapping via Order.prevInBook/nextInBook.
    /// @dev One slot. bidHead is the best bid (highest limitPrice, lowest prioritySeq at ties);
    ///      askHead is the best ask (lowest limitPrice, lowest prioritySeq at ties); 0 = empty
    ///      side. The counts track live nodes per side for lens pagination and traversal
    ///      invariants. Ordering keys off limitPrice, never an oracle price — every restable
    ///      type (Limit and armed StopLimit) is limit-priced, so list order is
    ///      oracle-independent and never decays.
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
    /// @dev `triggerPrice` carries two fields: the trigger price in its low 128 bits and, for
    ///      the trigger-gated types (StopLimit, StopLoss, TakeProfit), the keeper bounty in its
    ///      high 128 bits — `(bounty << 128) | price`. The bounty is in BAZAAR precision and
    ///      must be a whole number of USDC units (a multiple of 1e12); it is pulled from the
    ///      owner's wallet at creation and pays whoever executes the order. Zero means the owner
    ///      expects to fire the order themselves. Packed rather than declared because the struct
    ///      is at the width the compiler accepts, and because riding inside a signed field puts
    ///      the bounty under the EIP-712 signature with no payload change. Non-trigger types must
    ///      leave the high bits clear.
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
    ///  slot3: takeProfitOrderId(8)+stopLossOrderId(8) = 16
    ///  uint128 size/entryValue/collateral are not the binding magnitude constraint: the
    ///  notional math overflows uint256 far below 2^128-scale values, and collateral is bounded
    ///  by the pair's deposits ledger. entryFundingIndex stays full-width — it is an unbounded
    ///  cumulative index. Order ids fit uint64 (per-pair monotonic counter from 1). A bucket
    ///  carries no maintenance rate of its own: every position is judged against the pair's
    ///  (BucketLib.effectiveMmrBp).
    struct PositionBucket {
        bool isLong;
        uint128 size;
        uint128 entryValue;
        uint128 collateral;
        int256 entryFundingIndex;
        uint64 takeProfitOrderId;
        uint64 stopLossOrderId;
    }

    /// @notice Per-account tallies over the orders in its active set, from which the creation,
    ///         amendment and withdrawal margin gates bound the set's reservation
    ///         (CollateralLib._restingBound) without reading every order. No field depends on
    ///         the mark, so the bound is taken at gate time against whatever price the gate
    ///         judges by, and it is exact whenever every bid rests at or below that price and
    ///         every ask at or above it.
    /// @dev Three slots: sizes and the stop count, the limit notionals, the two price bounds.
    ///      The fields never understate the live set. Every order that joins the set adds its
    ///      full size and its limit notional at creation; an amendment subtracts no more than
    ///      the order's remaining leg at its old limit and adds the remaining leg at the new one;
    ///      a cancel subtracts the remaining leg; nothing else writes them. Fills, expiry, the
    ///      cancels of a liquidation or a deleverage and the arming of a StopLimit leave them
    ///      where they are, so the tallies drift above the set they describe until the exact
    ///      sweep rewrites them from what it read (CollateralLib._sweepRestingReserve). A field
    ///      that would overflow is pinned at its maximum, which the bound refuses to use, so the
    ///      gate falls back to the sweep. `highestBid` only ever rises between sweeps and
    ///      `lowestAsk` only ever falls, so each stays a bound on the live set when the order it
    ///      came from leaves. `stopCount` counts waiting StopLimits, whose reservation is keyed
    ///      off the trigger and is not bounded here, so any non-zero count sends the gate down
    ///      the exact sweep; its maximum is the marker a subtraction that would underflow
    ///      leaves, which the next sweep clears.
    struct RestingTally {
        uint96 bidSize; // Σ remaining size over resting bids
        uint96 askSize; // Σ remaining size over resting asks
        uint32 stopCount; // waiting StopLimits; type(uint32).max marks the tally invalid
        uint128 bidLimitNotional; // Σ remaining × limit over bids, BAZAAR precision
        uint128 askLimitNotional; // Σ remaining × limit over asks, BAZAAR precision
        uint128 highestBid; // at or above every resting bid's limit (0 = none recorded)
        uint128 lowestAsk; // at or below every resting ask's limit (0 = none recorded)
    }

    /// @notice One hourly sample of the pair's maintenance-margin rate and of its open interest:
    ///         the lowest rate in force and the lowest open interest seen during one sampling
    ///         interval, stamped with the instant that interval opened. The rate backs the
    ///         24h-lagged liquidation threshold and the open interest backs the trailing figure
    ///         the fund's reserve is sized on. Stored in a fixed ring buffer of MMR_SAMPLE_COUNT
    ///         slots, packed into one word each so a lookup reads a sample in a single load.
    struct MmrSample {
        uint64 ts; // the instant the sampled interval opened
        uint32 mmrBp; // lowest marginRequirements.mmrBp seen from then until the interval closed
        uint128 oiSize; // lowest per-side open interest (RiskParamsLib.openInterestSize) seen over the same stretch
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
        uint256 pendingLiqBankruptcyNotional; // sum of the estates' zero-equity notionals (LiquidationLib.bankruptcyNotionalOf) — for ADL settlement
        int256 pendingLiqEntryFundingIndex; // size-weighted avg of the liquidatees' ENTRY funding indices — settlement realizes funding over entry → close (estates' pre-liquidation balances + vault holding window together)
        bool pendingLiqIsLong; // original position direction (true = vault holds longs)
        // Realized bad debt: cumulative loss that exceeded the insurance fund and was dropped
        // (insurance floored at 0). A non-zero value is a definitive insolvency signal — the
        // vault cannot honor all claims — and triggers termination via isVaultHealthy. Folded
        // into the total owed at finalize, after which the field takes its terminal meaning:
        // the open positions' negative equity beyond the principal every other bucket holds
        // (registered claims are not netted against it), which the derivation could not
        // subtract and which their settlement consumes before crediting the ledger
        // (TerminationLib.executeTermination, CollateralLib._settleOne).
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
        // What the deposits ledger owes the insurance fund, in BAZAAR_SCALE precision: the part
        // of every collection into the fund (a liquidation seizure, a vault gain) that the ledger
        // could not pay because winners had already realized against the position and withdrawn
        // the cash. The ledger runs on deposits alone, so that cash is gone, not missing; the fund
        // recovers it by netting the balance against its own transfers into the ledger when
        // inventory settles at a loss, and finalize subtracts what is still outstanding from the
        // total owed to traders. Without it the fund would front cash that is sitting in the
        // ledger unclaimed, and finalize would reserve that cash as principal for a bucket that
        // does not exist.
        uint256 ledgerArrears;
        // When the inventory the vault holds was seized, as a size-weighted mean over the estates
        // in it. The unload walk opens its floor from the band edge toward the fund-neutral
        // price over UNLOAD_FLOOR_DECAY measured from here, so the estates' residual equity is
        // offered to the whole market before the walk will part with it at bankruptcy. Set when
        // the aggregate is seeded or taken over by the opposite side, blended by size when an
        // estate joins it, and untouched when inventory leaves, so a remainder keeps its age.
        // Zero only for inventory staged outside absorb, which the walk treats as fully aged.
        uint64 pendingLiqSeizedTs;
        // The lowest per-side open interest the sample ring has seen over the trailing
        // MMR_GRACE_PERIOD, as of the last margin-curve refresh. The reserve is sized on the
        // lower of this and live open interest (RiskParamsLib.reserveOiSizeOf), so open interest
        // counts toward it only once it has been held for that long: live open interest counts
        // matched positions of one owner, and sized on it alone the reserve could be raised
        // within a transaction, taking the fund's capital above it to zero and turning a loss
        // the fund can carry into an ADL window. Cached here because the reserve's consumers
        // reach the vault through libraries that do not carry the ring. Zero while no sampled
        // interval is that old, in which case live open interest sizes the reserve alone; a
        // window in which open interest touched zero stores 1, the smallest size.
        uint128 trailingOiSize;
    }

    /// @notice Pull-payment escrow for every USDC the pair owes a third party: integrator fees,
    ///         the bug-bounty tax, keeper tips and rewards (trigger bounties, vault unload,
    ///         liquidation, ADL, price refresh), the UMA proposer reward and relayer fees.
    ///         Payers credit `claimable` through FeeEscrowLib.credit instead of pushing USDC, so
    ///         no entry point runs a token transfer to an address outside the protocol's trust
    ///         boundary; recipients withdraw via BazaarPair.claimFees.
    /// @dev `total` is the sum of all `claimable` balances plus every `bounty` still held — a
    ///      liability against the pair's USDC that every books-vs-cash formula must reserve
    ///      alongside D and I: the health check's expected balance, and the terminal
    ///      surplus/reserve computations. USDC for these fees stays in the contract until
    ///      claimed, so omitting `total` anywhere reads escrowed fee cash as distributable
    ///      surplus.
    ///
    ///      `bounty` holds each trigger order's keeper bounty from creation until it is
    ///      assigned: pulled from the owner's wallet when the order is created, paid to the
    ///      executor in proportion to what each execution fills (the remainder on completion or
    ///      on resting), and returned to the owner's claimable balance when the order dies
    ///      unexecuted. Assignment moves value from `bounty` into `claimable` and leaves `total`
    ///      unchanged, so the cash pulled at creation backs the liability throughout.
    struct FeeEscrow {
        uint256 total;
        mapping(address => uint256) claimable;
        mapping(uint256 => uint256) bounty;
    }

    struct MarginRequirements {
        uint256 imrBp;
        uint256 mmrBp;
        uint256 lastUpdateTs;
        // The 24h-lagged MMR applicable to the current batch: the lowest rate recorded from the
        // interval in force MMR_GRACE_PERIOD before the mark being valued against up to now, the
        // open interval included, or where the ring does not reach back that far the lowest rate
        // it holds (MmrSampleLib.laggedMmr); 0 only before anything is recorded. Populated only
        // in the per-batch in-memory copy returned by BazaarPair._marginReqsWithLag(); the slot in
        // the `marginRequirements` storage variable is intentionally left 0 and never read
        // (solvency always reads the memory copy).
        uint256 laggedMmrBp;
    }

    /// @notice Fixed ring buffer of hourly MMR and open-interest samples. Sized to
    ///         MMR_SAMPLE_COUNT (25): the 24 one-hour intervals of a day fill 24 slots, and the
    ///         spare keeps the interval that was in force a full day before the newest close in
    ///         the ring, so the lookup for a sample at least 24h old has something to find in
    ///         steady state. The cursor fields share one word.
    struct MmrSampleBuffer {
        MmrSample[25] samples; // chronological ring (MMR_SAMPLE_COUNT slots)
        uint8 head; // index of the next write slot
        uint8 count; // number of valid samples (<= MMR_SAMPLE_COUNT)
        uint64 lastSampleTs; // the instant the open interval began: the last close, or the first record
        uint32 intervalMinBp; // lowest rate seen in the open interval; 0 before the first record
        uint128 intervalMinOi; // lowest open interest seen in the open interval
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
    ///      capped at REOPEN_GAP_EMA_CAP_BP so uint128 is never binding.
    ///
    ///      The slot also carries the two discontinuity instants an insurance redemption's
    ///      paying call waits out (InsuranceVaultLib.claimOpensAt): `lastObsTs` for a storage
    ///      gap, and `lastJumpTs` for a stored price at least RiskParamsLib.MIN_STRESS_MOVE_BP
    ///      from the variance sample, whether or not that store also ended a gap.
    struct ReopenGapEma {
        uint64 lastObsTs; // publishTime of the last accepted observation (0 = none yet)
        uint128 gapEmaBp; // peak-hold reopen-gap magnitude in bp
        uint64 lastJumpTs; // publishTime of the last stored price at least RiskParamsLib.MIN_STRESS_MOVE_BP from the variance sample (0 = none yet)
    }

    /// @notice The two halves of a liquidation's outcome, advanced by the same unload batches and
    ///         so sharing one accumulated weight: a decay line for each half, and the weight.
    /// @dev `slippage` is execution cost against the oracle — how far a fill lands past it — and
    ///      feeds the maintenance level, which has to pay for closing a position out. `drift` is
    ///      how far the oracle itself travelled past the estates' bankruptcy price before the vault
    ///      could clear the inventory, and feeds the insurance target, which is sized on what
    ///      liquidations lose beyond that level. Each fill is recorded floored at zero, and
    ///      slippage capped at LIQ_MAX_SLIPPAGE_BP, before it is weighted
    ///      (MatchingEngineLib._settleVaultLiquidation), so neither is ever negative. Both stay
    ///      full-width: drift has no structural bound above.
    ///
    ///      Each half is its value as of its own anchor, in RiskParamsLib.GAP_EMA_SCALE units per
    ///      basis point, read faded harmonically by the time since that anchor
    ///      (RiskParamsLib.fadedLiquidationGapsOf). A batch moves an anchor toward the present only
    ///      by the share of that line it adds (RiskParamsLib.updateLiquidationGapEmaBatch), so an
    ///      anchor can predate the last batch and the stored value then sits above every reading
    ///      taken since: read them through the faded form, never raw. `decayedSize` is the
    ///      accumulated size of every batch, discounted at each batch by the time since the one
    ///      before (`lastLiquidationTs`). All three timestamps are pushed forward across market
    ///      closures so the fades and the discount age only tradeable time
    ///      (RiskParamsLib._suspendFadeAcrossClosure). Zero timestamps mean no batch has been
    ///      recorded.
    struct LiquidationGapEma {
        uint256 slippage;
        uint256 drift;
        uint64 slippageAnchorTs;
        uint64 driftAnchorTs;
        uint64 lastLiquidationTs;
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
        uint256 lastMarkUpdateTs; // the mark line's anchor, which can predate the last print (FundingLib.MarkState)
        uint256 rollingVolume; // the line's volume at that anchor, so at least what it reads now
        uint256 pairCreatedTs;
        uint256 priceUpdateCount;
        uint256 adlSnapshotPrice;
        int256 adlSnapshotFundingIndex; // funding index frozen at trigger; keepers score winners against this
        bool adlLongs;
        uint256 settlementPrice; // fixed terminal price (0 while the pair is live)
        uint256 terminalPrincipalRatio; // derived at finalize, and again after a late bankrupt settlement: cash paid per unit of bucket collateral (BAZAAR_SCALE = 100%)
        uint256 terminalProfitRatio; // derived at finalize, and again after a late bankrupt settlement: cash paid per unit of registered profit claim (BAZAAR_SCALE = 100%)
        uint256 terminalProfitClaims; // Σ registered winner profit not yet paid out (settlement-window tally, less post-finalize payouts)
        uint256 terminalBadDebt; // Σ settled losses beyond collateral (settlement-window tally)
        address bugBountyAddress;
        uint256 deferredCount; // opposite-side liquidations left open for the auction to close; BazaarPair.deferredLiquidations(i) lists them
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
    // MMR_SAMPLE_INTERVAL into a ring buffer of MMR_SAMPLE_COUNT entries (24h of history); each
    // sample is the lowest rate in force during its interval. Every position, however recently
    // opened, is liquidated against the lower of the current rate and the lowest rate recorded
    // from MMR_GRACE_PERIOD before the mark it is valued against up to the present, the open
    // interval included (the "lagged" MMR), so a rising MMR can't liquidate anyone until it has
    // held for MMR_GRACE_PERIOD: a rate that is high at two instants a day apart but not in
    // between never reaches the threshold, and a dip counts from the moment it is recorded. Each
    // sample is stamped with the instant its interval opened, the earliest its rate can have been
    // in force, so the window opens on the interval in force at the cutoff and spans the whole
    // period. A pair whose samples do not reach back that far yet is judged against the lowest
    // rate it has recorded.
    //
    // The same ring samples per-side open interest, and the same MMR_GRACE_PERIOD is the lookback
    // of the trailing minimum the fund's reserve is sized on (Vault.trailingOiSize).
    uint256 internal constant MMR_SAMPLE_INTERVAL = 1 hours;
    // One slot more than the 24 hourly intervals of a day, so the interval in force a full day
    // before the newest close stays in the ring. Must match MmrSampleBuffer.samples length.
    uint256 internal constant MMR_SAMPLE_COUNT = 25;
    uint256 internal constant MMR_GRACE_PERIOD = 24 hours;

    // Integrator fees in EBP — charged only on orders that carry an integrator address;
    // direct-to-contract orders (integrator = address(0)) pay no integrator fee.
    uint256 internal constant MAKER_INTEGRATOR_FEE_EBP = 25;
    uint256 internal constant TAKER_INTEGRATOR_FEE_EBP = 25;

    // Keeper rate in EBP of notional (2 bps): paid on the inventory a liquidation's nettings
    // retire, on what its inline unload or an unloadVault call sells into the book, on what an
    // ADL batch retires with each deferred account it seizes (LiquidationLib.seizureReward), and
    // on the inventory an ADL batch closes for the inventory's own exposure, valued at the mark,
    // where that is more than the share of the bad debt the close averts (AdlLib._closeReward).
    uint256 internal constant LIQUIDATION_FEE_EBP = 200;

    // Insurance fees in EBP
    uint256 internal constant MAKER_INSURANCE_FEE_EBP = 50;

    // Stale-fallback fill band. Fresh-oracle fills are unbanded: the fill-time margin gates
    // price fresh exposure at the live oracle and charge the fill-vs-mark gap up front, and
    // FundingLib clamps every print to ±MAX_MARK_DEVIATION_BP of index before its premium enters
    // the mark's tallies — an off-mark fill is economically real for its two parties and moves
    // the funding mark everyone else pays against no further than a print at the band edge.
    // Under the stale fallback those gates judge against an aged reference, so fills are confined
    // to cachedPrice × (1 ± band). A breach toward the taker cancels the resting maker; away from
    // the taker, the arrival.
    uint256 internal constant MAX_STALE_DEVIATION_BP = 1000;

    // Cap on the oracle leg of the vault unload bound (5%): the vault takes makers within
    // min(this, BucketLib.effectiveMmrBp) of the oracle at once, and makers beyond that edge
    // which still beat the estates' fund-neutral price once the floor has opened to them
    // (UNLOAD_FLOOR_DECAY). The same band edge is where the ADL auction stops closing winners:
    // it releases once the fund above its reserve could finish the remaining inventory there.
    uint256 internal constant LIQ_MAX_SLIPPAGE_BP = 500;

    // How long the unload walk takes to open its floor from the band edge to the estates'
    // fund-neutral price, measured from the inventory's size-weighted seizure time. Inside the
    // band the vault sells at once; the residual equity beyond the edge is offered to the whole
    // market for this long before the walk will part with it at bankruptcy, so the price it
    // fetches is set by competing bids rather than by whoever bids in the seizing transaction.
    uint256 internal constant UNLOAD_FLOOR_DECAY = 3 minutes;

    /// @notice Share of the insurance target the unload walk may never spend, in bp of the
    ///         target ratio. Free capital above this reserve is what the vault may lose selling
    ///         inventory, what the ADL gate measures expected loss against, and what an opposing
    ///         liquidation's netting has to fit inside to run at all — one that does not is
    ///         deferred to the auction, which closes it against its own counterparties instead.
    ///         The reserve itself stays for the realizations no bound can refuse: the
    ///         holding-window funding a deleveraged slice carries, and the keeper rewards the
    ///         fund pays. Sized from the target rather than the fund so it is a fixed dollar
    ///         amount at any moment: a walk that spends free capital moves the budget one for
    ///         one and never re-derives a fresh share of what is left.
    uint256 internal constant ADL_RESERVE_BP = 1_000;

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
    /// @dev How far a Pyth publish time may sit from the block timestamp, in either direction,
    ///      for the pair to act on the price; also the settlement window before a cutoff under
    ///      UMA's rule. One number because the settlement print is the last print the pair would
    ///      have accepted as current at the cutoff.
    uint256 internal constant MAX_PRICE_STALENESS = 3 seconds;
    /// @dev How long before a scheduled cutoff limbo begins: from then until the price is fixed
    ///      nothing trades, liquidates, deposits or withdraws. Nothing may trade once the
    ///      settlement print can be public, and knowing it is enough: fills execute at makers'
    ///      prices whatever print the transaction stores, so a trader who has seen the print can
    ///      pick off every quote on the wrong side of it. With one window of lead the last trading
    ///      block is stamped a second before the window opens, which hides the print only while
    ///      Pyth's clock runs no further ahead of the block timestamp than a print takes to be
    ///      delivered. Two windows stamp it a window and a second before, so it stays hidden until
    ///      the skew passes a full window on top of that delivery time. The lead is kept that
    ///      short because no position can be liquidated during it.
    uint256 internal constant LIMBO_LEAD = 2 * MAX_PRICE_STALENESS;
    /// @dev A cutoff is scheduled at least this far after the scheduling block: the limbo lead
    ///      plus one second, so limbo begins after the block, and the settlement window opens a
    ///      window and a second after it, the margin LIMBO_LEAD gives the last trading block.
    uint256 internal constant MIN_CUTOFF_LEAD = LIMBO_LEAD + 1;

    // Order constants (shared between BazaarPair and OrderManagementLib)
    uint256 internal constant MIN_ORDER_AMOUNT = 5 * BAZAAR_SCALE;
    uint256 internal constant MAX_SLIPPAGE_BP = 1000; // 10% max slippage for market-type orders
    // Placement sanity band for a Limit order's resting price (±50% of the mark at creation).
    // Deliberately wide: resting deep to catch a reopen gap is a legitimate strategy the margin
    // system is built for, so this only rejects prices that can be nothing but an input error —
    // or an attempt to satisfy notional checks at a price the market will never see.
    uint256 internal constant MAX_PLACEMENT_DEVIATION_BP = 5000;

    // Order-lifetime constants, in Arbitrum L2 blocks (~250ms each, 4 blocks/sec). The floor
    // keeps a resting order a quote takers can act on: an order at the top of the book stands
    // open to fills for at least a minute before it can expire into a dead node that the next
    // walk spends a step removing. Every link into the book is held to it, not only creation: an
    // amendment that moves an order is refused with less than this left, and a StopLimit fired
    // with less keeps its remainder live outside the book instead of resting it. It stays short
    // enough that an order's own expiry still retires the quotes of an owner who has gone silent,
    // the only such backstop the pair has.
    uint64 internal constant MIN_ORDER_LIFETIME_BLOCKS = 240; // ~1 min
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

    // Rounding slack the resting-reservation bound adds to the figures it stands in for
    // (CollateralLib._restingBound). The exact sweep floors each order's notional and each loss
    // leg on its own, while the bound floors one product over the whole side, and a difference
    // of two floors can exceed the floor of the difference by one; two legs per order, over at
    // most MAX_ACTIVE_LIMIT_ORDERS_PER_USER orders, is the most the bound can fall short by
    // without this.
    uint256 internal constant RESTING_BOUND_SLACK = 2 * MAX_ACTIVE_LIMIT_ORDERS_PER_USER;

    // Amendments per amendOrders call. The per-user cap above bounds how many resting limit
    // orders a caller can have, so a batch this size can requote every one of them; the ceiling
    // keeps the worst case — every item repriced into a slot its hints miss, each paying a full
    // repair walk — a modest fraction of an Arbitrum block.
    uint256 internal constant MAX_AMENDS_PER_CALL = MAX_ACTIVE_LIMIT_ORDERS_PER_USER;

    // Shared node-visit ceiling for book walks: caps the matching walk (MatchHints.maxSteps is
    // clamped to it; 0 selects it as the default) and caps OrderBookLib's insert repair walk.
    // Sized so the worst-case arrival — 32 cold settlements in one transaction — stays a modest
    // fraction of an Arbitrum block, leaving the chain's throughput to other traffic. A taker
    // wanting more depth splits it across transactions.
    uint256 internal constant MAX_WALK_STEPS = 32;

    // Keeper tip for settling another trader's position at the fixed terminal price. Before
    // finalize every open position holds the completeness gate shut for everyone, so every
    // settlement by a non-owner pays: from whatever collateral the settled position has left,
    // with insurance covering the remainder. After finalize only a bankrupt straggler harms
    // anyone (its shortfall stays unbooked until it is settled), so only that settlement pays,
    // from the insurers' residual. Insurance pays toward a tip only for a position worth at
    // least MIN_ORDER_AMOUNT at the settlement price; a smaller one pays what its own collateral
    // covers (CollateralLib._paySettlementTip gives the reason). Owners settle their own
    // positions for nothing, as the withdrawal path already does.
    uint256 internal constant TERMINAL_SETTLEMENT_TIP = BAZAAR_SCALE / 20; // $0.05

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

    // What unloadVault passes to MatchingEngineLib.unloadBook where liquidate() passes the credit
    // its liquidations left (LiquidateResult.unloadPrepaid): the caller is a keeper earning the
    // unload bounty above, not a liquidator whose walk only tops up what it was already paid.
    uint256 internal constant UNLOAD_BY_KEEPER = type(uint256).max;

    // Bounds one executeTriggeredOrders call (each exec can run a full walk).
    uint256 internal constant MAX_TRIGGER_EXECS_PER_CALL = 20;

    // Node budget for the unload walk run inline at the end of liquidate() — bounds the
    // liquidator's gas; the permissionless unloadVault handles anything deeper.
    uint256 internal constant LIQ_INLINE_UNLOAD_STEPS = 16;

    // Sentinel: TP/SL orders never expire by block
    uint64 internal constant NEVER_EXPIRE_BLOCK = type(uint64).max;

    // Flat liquidation reward (shared between BazaarPair and LiquidationLib): due for every
    // position a liquidate() call seizes and every account it newly records as deferred. A
    // netting account earns LIQUIDATION_FEE_EBP of what it retires instead when that is larger,
    // and the call's inline unload adds whatever the rate on what it sells exceeds the remaining
    // flat rewards. It covers the keeper's gas when the call takes little or no exposure off
    // the fund. Also the floor of the per-seizure reward an ADL batch pays. An
    // account whose position is worth less than MIN_ORDER_AMOUNT earns at most its own equity
    // instead (LiquidationLib.flatReward).
    uint256 internal constant MIN_LIQUIDATOR_REWARD = BAZAAR_SCALE / 20; // 0.05 USDC

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

    /// @notice Share of the bad debt an ADL close averts that the executor is paid, from
    ///         insurance: on top of the seizure reward for a close against a deferred account, and
    ///         in place of LIQUIDATION_FEE_EBP of the closed notional at the mark for a close of
    ///         the inventory's own exposure where it is the larger.
    /// @dev Shared with AdlLib: the payout is a fund debit proportional to the size closed, so
    ///      the size that restores health has to account for it or every batch lands just the
    ///      reward's worth short of the release level.
    uint256 internal constant ADL_EXECUTOR_REWARD_BP = 10; // 0.1%
    /// @notice The most opposite-side liquidations the vault may leave open as deferred at
    ///         once. The bound is a gas ceiling, and the auction sets it rather than the gate:
    ///         the gate costs a bucket read per entry, but a batch may scan the whole submitted
    ///         cohort for each listed account, so the auction's worst case grows as the product
    ///         of the two and is the first to reach a block. It is the size of a working set,
    ///         not a queue of everything outstanding — when full, a newcomer replaces the entry
    ///         with the smallest loss beyond its collateral, so what stays untracked is what
    ///         matters least, and a later liquidate() picks it up once room frees or the
    ///         inventory it would have netted against is gone.
    uint256 internal constant MAX_DEFERRED_LIQUIDATIONS = 16;

    // Risk model constants (shared between BazaarPair and InsuranceVaultLib)
    uint256 internal constant VARIANCE_LOW = 2_000_000; // ~14% annualized vol
    uint256 internal constant VARIANCE_EXTREME = 100_000_000; // ~100% annualized vol
    uint256 internal constant INSURANCE_TARGET_BASE = 200; // 2% minimum target
    uint256 internal constant INSURANCE_TARGET_MAX = 1_000; // 10% maximum target

    // -------------------- Events --------------------

    /// @notice One fill between a resting maker order and the taker that crossed it: the sole
    ///         per-fill record, one event per fill, so summing fillSize counts volume once.
    /// @dev The taker is either an arriving order or the pair itself unloading liquidation
    ///      inventory into the book. A vault fill reports the pair's own address as `taker`,
    ///      and 0 for takerOrderId, takerFee and takerRemaining.
    /// @param pairId The pair
    /// @param maker Owner of the resting order
    /// @param taker Owner of the arriving order, or the pair for a vault fill
    /// @param makerOrderId The resting order
    /// @param takerOrderId The arriving order; 0 for a vault fill
    /// @param takerIsLong True when the taker bought and the maker sold
    /// @param fillSize Size filled
    /// @param price Fill price: the maker's limit price
    /// @param makerFee Fee charged to the maker for this fill, integrator and insurance legs together
    /// @param takerFee Fee charged to the taker for this fill, integrator and insurance legs together
    /// @param makerRemaining The maker order's unfilled size after this fill; 0 means fully filled
    /// @param takerRemaining The taker order's unfilled size after this fill
    event Trade(
        bytes32 indexed pairId,
        address indexed maker,
        address indexed taker,
        uint256 makerOrderId,
        uint256 takerOrderId,
        bool takerIsLong,
        uint256 fillSize,
        uint256 price,
        uint256 makerFee,
        uint256 takerFee,
        uint256 makerRemaining,
        uint256 takerRemaining
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

    /// @notice The order's stored state at an OrderUpdated event, plus what the event reports.
    ///         cancelReason is None unless action is Canceled.
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
        uint64 prioritySeq;
        TimeInForce tif;
        address integrator;
        CancelReason cancelReason;
    }

    /// @notice An order was created, triggered or canceled. Fills are reported by Trade and
    ///         amendments by OrderAmended.
    event OrderUpdated(
        bytes32 indexed pairId, uint256 indexed orderId, address indexed owner, OrderUpdatePayload payload
    );

    /// @notice amendOrders gave a resting limit order a new price and/or size. `size` is the
    ///         order's new total size, filled part included, as OrderUpdated reports it. Only what
    ///         an amendment can change is reported: the order's type, side, expiry and integrator
    ///         are as its Created event left them, and its filled size is what its Trade events sum
    ///         to. `prioritySeq` is the queue position the order now holds: a value above the one last
    ///         reported means the order was queued anew behind its price level and its resting
    ///         exposure restarted in this block, an unchanged one that it shrank where it stood.
    /// @dev Three words of data rather than OrderUpdated's full payload: a requote is the book's
    ///      most frequent write, and an indexer already holds the fields an amendment cannot touch.
    event OrderAmended(
        bytes32 indexed pairId,
        uint256 indexed orderId,
        address indexed owner,
        uint256 limitPrice,
        uint256 size,
        uint256 prioritySeq
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
        uint256 mmrBp
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

    /// @notice Emitted when a trigger order's keeper bounty is pulled from its owner's wallet
    ///         into the escrow at creation.
    event TriggerBountyEscrowed(bytes32 indexed pairId, uint256 indexed orderId, uint256 amount);

    /// @notice Emitted when part of a trigger order's escrowed bounty is assigned: to the
    ///         executor for what it filled or armed, or back to the owner when the order ends
    ///         unexecuted. The same amount is reported through FeeAccrued for the recipient.
    event TriggerBountyReleased(
        bytes32 indexed pairId, uint256 indexed orderId, address indexed recipient, uint256 amount
    );

    /// @notice Emitted when an escrowed fee balance is paid out.
    event FeesClaimed(bytes32 indexed pairId, address indexed recipient, uint256 amount);

    event CollateralWithdrawn(bytes32 indexed pairId, address indexed user, uint256 amount);

    /// @notice Emitted when the settlement of a bankrupt position finalize did not wait for leaves
    ///         `unfunded` of its shortfall beyond the insurers' residual, and the two payout
    ///         ratios PairTerminated reported are derived again on the entitlements still unpaid.
    ///         The ratios reported here supersede the earlier ones for every later withdrawal.
    event TerminalRatiosRefrozen(bytes32 indexed pairId, uint256 unfunded, uint256 principalRatio, uint256 profitRatio);

    event InsuranceDeposited(bytes32 indexed pairId, address indexed user, uint256 amount, uint256 sharesReceived);

    event InsuranceWithdrawalRequested(bytes32 indexed pairId, address indexed user, uint256 shareAmount);

    /// @notice A redemption paid out: `shareAmount` burned for `usdcAmount` (BAZAAR precision),
    ///         which includes any relayer fee carved from it. On a live pair this is a paying
    ///         execute call, after an InsuranceWithdrawalLocked; while the vault holds inventory it
    ///         can redeem part of the request, the rest staying requested for a later one.
    event InsuranceWithdrawalExecuted(
        bytes32 indexed pairId, address indexed user, uint256 shareAmount, uint256 usdcAmount
    );

    /// @notice The first execute call of a live-pair redemption: nothing is burned or paid. It
    ///         records `lockedAmount`, what the requested shares are worth now (BAZAAR precision).
    ///         The second call, from `claimOpensTs` until the request's window closes, pays the
    ///         lower of `lockedAmount` and what the same shares are worth then, held to the fund's
    ///         headroom while the vault holds inventory. A later price discontinuity can push the
    ///         opening back (InsuranceVaultLib.claimOpensAt).
    event InsuranceWithdrawalLocked(
        bytes32 indexed pairId, address indexed user, uint256 shareAmount, uint256 lockedAmount, uint256 claimOpensTs
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
        uint256 currentPrice; // the price the position is valued at: the conservative bracket for a holder, spot otherwise
        uint256 spotPrice; // the spot the resting orders are reserved against (0 when no price was read: the set is then empty)
        int256 currentFundingIndex; // current global funding index
        MarginRequirements marginReqs; // current margin requirements
        bytes32 pairId; // pair identifier for events
        bool isPairTerminated; // finalized: terminal payout branch
        bool pendingTermination; // limbo: LIMBO_LEAD before scheduledTerminationTs has passed, the settlement price not yet fixed
        bool isOracleStale; // stale price fallback in use — position-holder withdrawals revert
        uint256 settlementPrice; // fixed terminal price (terminal branch only)
        bool isVaultHealthy; // result of vault health check (only relevant when exposure present)
        uint8 vaultHealthReason; // reason code from vault health check
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
        uint256 unloadPrepaid; // the credit the inline unload's rate must exceed before it pays more: what processLiquidations paid (per account its flat reward, or for a netting LIQUIDATION_FEE_EBP of the overlap when larger; capped at the fund's free capital) less the nettings' rate, floored at zero
        uint256 deferredCount; // opposite-side positions left open because netting them would take the fund below its reserve
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

        // The mark-price print: the fills against makers resting on the far side of the oracle,
        // each at its print price and scaled by its maker's exposure
        // (MatchingEngineLib._accrueMarkPrint). Kept apart from the totals above, which price the
        // unload reward and gate the post-walk health check on everything that filled. Held as
        // Σ fillSize × print price × weight and Σ fillSize × weight until the summary divides
        // both by FundingLib.MAKER_EXPOSURE_BLOCKS.
        uint256 markNotional; // the mark's VWAP numerator and volume, times the exposure window
        uint256 markSize; // the mark's VWAP denominator, times the exposure window

        // Liquidation-EMA accumulators (unload walks only)
        int256 sumLiqSlipTimesSize;
        int256 sumLiqDriftTimesSize;
        uint256 totalLiqFillSize;

        // OI deltas, fees, vault PnL — populated during the walk, applied in finalize
        int256 deltaLongOI;
        int256 deltaShortOI;
        int256 deltaLongWeightedEntry;
        int256 deltaShortWeightedEntry;
        uint256 totalIntegratorFees;
        uint256 totalInsuranceFees;
        int256 totalVaultPnl;
        // The seizure earmarked against the vault inventory an unload walk released: it pays the
        // walk's loss ahead of the ledger's arrears (RiskParamsLib.fundLedgerFrom).
        uint256 vaultEarmarkReleased;

        // Deposits-ledger headroom remaining for fee attribution: seeded from
        // totalCollateralDeposited at walk start, drawn down by every charged fill. Fees
        // are collected from book collateral but settled against the deposits ledger in
        // finalize, and book collateral can legitimately exceed that ledger (open losers
        // back profits that were already withdrawn) — so a fill whose fees exceed the
        // remaining budget has ALL its fees waived (nothing charged, nothing paid out)
        // rather than collecting a fee the ledger cannot fund.
        uint256 feeBudget;

        // The taker's remainder as its walk began, after a TP/SL was capped to the position it
        // can close: the base a trigger order's bounty is paid pro rata against.
        uint256 takerRemainingAtStart;

        // Integrator dedup buffer (preallocated to 2x the walk's node cap — each fill can
        // append two distinct integrators, one per side)
        IntegratorAccum[] integratorAccums;
        uint256 integratorCount;

        uint256 nodesVisited; // enforced against the walk's node cap, counting skips too
    }

    /// @notice Compact per-walk summary returned to BazaarPair for its post-walk hooks: the
    ///         mark-price update, the liquidation-gap EMA, the vault health re-check and the
    ///         unloaded size. The unload reward is priced inside the library from the full
    ///         matched volume, which therefore stays out of the summary.
    struct WalkSummary {
        uint256 totalFillSize;
        uint256 markNotional;
        uint256 markSize;
        int256 sumLiqSlipTimesSize;
        int256 sumLiqDriftTimesSize;
        uint256 totalLiqFillSize;
    }

    /// @notice Per-walk figures for the vault's unload: which side it sells, the deepest price
    ///         it takes, the reference price a fill is measured against, and how much the fund
    ///         may spend on fills inside that reference.
    struct UnloadPlan {
        bool vaultIsLong;
        uint256 bound;
        uint256 referencePrice;
        int256 headroom;
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
    ///         ledgers, into the two frozen payout ratios. After finalize the claims tally falls
    ///         as claims are paid, and both ratios are derived again whenever a bankrupt
    ///         position settled late leaves a shortfall the residual cannot fund. Lives in
    ///         BazaarPair storage, passed to libs by reference.
    struct TerminalSettlement {
        uint256 totalProfitClaims; // Σ registered winner PnL not yet paid out (registered before finalize)
        uint256 terminalBadDebt; // Σ settled losses beyond collateral (funding incl.)
        uint256 principalRatio; // derived at finalize, and again after a late bankrupt settlement: cash paid per unit of bucket collateral (BAZAAR_SCALE = 100%)
        uint256 profitRatio; // derived at finalize, and again after a late bankrupt settlement: cash paid per unit of registered claim (BAZAAR_SCALE = 100%)
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
        uint64 currentBlock; // L2 block number at tx execution time
        address usdc; // the pair's collateral token, pulled from for a trigger order's bounty
    }

    /// @notice Parameters for OrderManagementLib.amendOrders. The margin requirements reach it as
    ///         a storage pointer, so they are not among these.
    struct AmendOrdersParams {
        bytes32 pairId;
        uint256 currentPrice; // the mark the placement band and the margin gate are judged against
        int256 currentFundingIndex;
        uint256 nextOrderId; // the counter both ids and queue positions are drawn from; advanced and returned
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
        bool isContinuouslyTraded; // false adds the reopen-gap leg to the fund target and takes the session execution window
        address umaContract; // BazaarPairTerminator, asked for the caller's vote-locked shares
        int256 currentFundingIndex; // live cumulative funding index, for valuing the vault's inherited inventory
        uint256 settlementPriceFixedTs; // when the settlement price was fixed; anchors the post-finalize sweep grace
        bytes32 pairId; // carried by the lock and payout events the library emits
    }

    // -------------------- AdlLib Structs --------------------

    /// @notice Result of an ADL execution batch
    struct AdlResult {
        uint256 eligibleSize;
        uint256 eligibleCount;
        uint256 highestAdlScore;
        uint256 lowestAdlScore;
        uint256 totalLiqSize; // total size settled via ADL
        // The inventory leg's settlement price: avg bankruptcy price, or a mark better for the fund.
        // What the leg closes past its restoring figure settles at the mark.
        uint256 settlementPrice;
        uint256 deferredClosedSize; // size of deferred accounts closed against their own counterparties
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
