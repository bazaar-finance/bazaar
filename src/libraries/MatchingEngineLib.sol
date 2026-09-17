// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";
import {BucketLib} from "./BucketLib.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";
import {OrderBookLib} from "./OrderBookLib.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";

/// @title MatchingEngineLib
/// @notice Arrival-matching engine over the on-chain sorted book: an incoming order walks the
///         opposing list from its head while it crosses, fills at each resting maker's limit
///         price, and then either rests its remainder in the book (GTC limits, via insertion
///         hints) or cancels it (Market/StopLoss execution, IOC, post-only violation,
///         self-match, step-cap, dust). A fill-or-kill arrival takes neither branch: it reverts
///         unless the walk filled it completely. Also executes triggered stops and unloads vault
///         liquidation inventory through the same fill machinery.
///         Runs via DELEGATECALL from BazaarPair — has direct storage access.
///
/// Key invariants:
///  • Fills price at the MAKER's limitPrice: the resting side is always the maker, because only
///    a resting order carries a book position for the arriving side to trade against. (For a
///    just-created order that is also the older-id side; a stop fired later by a keeper takes
///    against makers that may be newer than itself.)
///  • The book never rests crossed: every disposition that could leave a still-crossing
///    remainder (step-cap, far-side band breach, self-match, margin failure) cancels the
///    incoming order.
///  • The walk re-reads its side's head from storage every iteration and never carries a next
///    pointer across a settlement: a settlement unlinks the maker it just consumed or
///    auto-cancels one that fails its margin gate, and can terminate the TAKER's own order
///    through the oversize fence, so any cached pointer or cached liveness would go stale.
///  • Margin checks always use normal IMR against the tx's cached price. Failure → auto-cancel.
///  • Fills are banded only under the stale fallback (±MAX_STALE_DEVIATION_BP of the cached
///    price); fresh-oracle fills are unbanded — the margin gates and FundingLib's index clamp
///    carry the defense. A stale maker priced beyond the band away from the taker cancels the
///    INCOMING order's remainder; one priced beyond it toward the taker is itself canceled and
///    the walk continues.
library MatchingEngineLib {
    using EnumerableSet for EnumerableSet.UintSet;

    // -------------------- Errors --------------------
    // Do not trim these error args (or PositionModified's duplicate fields) to save code size:
    // under via_ir it shifts inlining decisions and makes the library BIGGER, not smaller.
    // Re-measure with `forge build --sizes` before any such change.
    error MatchingEngineLib__InvalidTriggerBatch(uint256 count);
    error MatchingEngineLib__BlockedOracleStale(); // oracle-priced execution needs a fresh price
    error MatchingEngineLib__FillOrKillUnfilled(uint256 orderId, uint256 remaining);

    // -------------------- Memory state --------------------

    /// @dev Memory-cached node: one maker (rebuilt from storage every walk iteration) or the
    ///      taker (built once — its immutable fields cannot change mid-walk, and filledSize is
    ///      only advanced by this walk itself).
    struct Head {
        uint256 orderId;
        uint256 remaining;
        BazaarTypes.Order order;
    }

    /// @dev The taker's bucket image and per-walk aggregates, carried in memory across the
    ///      walk. The image starts as a copy of the stored bucket and is kept current by every
    ///      fill with exactly the field mapping updateFromState persists, so per-fill margin
    ///      gates and fee classification judge it as they would judge storage — but the bucket
    ///      is written back, and the taker's position events emitted, once per walk instead of
    ///      once per fill. Safe because nothing else the walk touches can alias the taker's
    ///      bucket: self-match cancels the arrival before any fill, so every maker settled
    ///      mid-walk belongs to another account. The TP/SL slot pointers are NOT part of the
    ///      image lifecycle — they stay storage-resident (persist/cancel/fence write them
    ///      directly), and the flush deliberately leaves them untouched.
    struct TakerCtx {
        BazaarTypes.PositionBucket bkt; // live image; flushed by _flushTaker
        bool posWasLong; // position side at walk start — drives the flush-time TP/SL fence
        uint256 sizeAtStart; // position size at walk start (no TP/SL can exist on a flat start)
        // Walk invariants. Held here rather than as locals so the walk loop's frame stays inside
        // the Yul stack scheduler's reach.
        bool isLong; // the taker's side
        uint256 bound; // worst price the taker will cross to (limit, or slippage-bounded mark)
        uint256 fills;
        int256 sizeDeltaAcc;
        int256 realizedPnlAcc;
        uint256 feeAcc;
        uint256 volumeAcc; // Σ fillNotional — VWAP numerator for the flush event
        uint256 fillSizeAcc; // Σ fillSize — VWAP denominator
    }

    /// @dev Per-side fee breakdown for a crossed fill.
    struct PairFees {
        uint256 longIntegratorFee;
        uint256 shortIntegratorFee;
        uint256 longInsuranceFee;
        uint256 shortInsuranceFee;
        uint256 longTotalFee;
        uint256 shortTotalFee;
    }

    /// @dev Bundle of per-fill parameters and mid-fill products, structured to keep the fill
    ///      path and the settle tail within stack depth: everything the tail needs rides behind
    ///      this one pointer instead of holding its own stack slot across the
    ///      persist/apply/aggregate/emit calls.
    struct FillParams {
        uint256 fillSize;
        uint256 fillPrice;
        bool makerIsLong;
        PairFees fees; // written by _fillCrossed after the fee computation
        BazaarTypes.BucketState longState; // written by _fillCrossed from the long creator's bucket
        BazaarTypes.BucketState shortState; // written by _fillCrossed from the short creator's bucket
    }

    /// @dev Bundle of all vault-fill locals — keeps function call sites within stack depth.
    struct VaultFillData {
        uint256 fillSize;
        uint256 execPrice;
        uint256 fillNotional;
        uint256 makerIntFee;
        uint256 makerInsFee;
        uint256 makerTotalFee;
    }

    // Outcomes of one crossed-fill attempt.
    uint8 private constant FILLED = 0; // fill settled; walk continues
    uint8 private constant MAKER_DEAD = 1; // maker auto-canceled; walk retries the next head
    uint8 private constant TAKER_DEAD = 2; // taker cannot proceed; caller cancels its remainder

    // State of the taker's order when the walk loop exits.
    uint8 private constant ALIVE = 0; // remainder rests or cancels per the disposition rules
    uint8 private constant DEAD = 1; // remainder must be canceled
    uint8 private constant GONE = 2; // a fill already stamped the order terminal

    // ================================================================
    // EXTERNAL ENTRY POINTS
    // ================================================================

    /// @notice Match a just-created order against the book and dispose of its remainder.
    /// @dev Untriggered stops (StopLimit/StopLoss whose trigger the fresh price does not meet,
    ///      or any stop created under the stale fallback) do not walk: they rest outside the
    ///      book until executeTriggers fires them. A stop whose trigger a fresh price already
    ///      meets arms immediately here, with no keeper and no tip.
    ///
    ///      A fill-or-kill taker always reaches its enforcement point (_disposeRemainder):
    ///      creation confines that time-in-force to Limit and Market, neither of which is
    ///      trigger-gated, so the early return above cannot swallow one before the walk runs.
    /// @return sum Compact fill totals for the pair's post-walk hooks.
    function executeArrival(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        BazaarTypes.OrderBook storage book,
        uint256 takerId,
        BazaarTypes.MatchHints memory hints,
        BazaarTypes.ArrivalContext memory ctx
    ) external returns (BazaarTypes.WalkSummary memory sum) {
        {
            BazaarTypes.Order storage t = orders[takerId];
            BazaarTypes.OrderType ot = t.orderType;
            // Market orders price and bound off the oracle; a stale fallback cannot bound a fill.
            if (ot == BazaarTypes.OrderType.Market && ctx.isOracleStale) {
                revert MatchingEngineLib__BlockedOracleStale();
            }
            if (_isTriggerGated(ot)) {
                if (ctx.isOracleStale || !_triggerReached(ot, t.isLong, t.triggerPrice, ctx.cachedPrice)) {
                    return sum;
                }
            }
        }
        uint256 cap = _resolveCap(hints.maxSteps);
        BazaarTypes.ArrivalResult memory res = _initResult(pairVault, cap);
        _walkTaker(orders, positionBuckets, userActiveLimitOrders, book, takerId, hints, cap, ctx, res);
        _finalizeTx(pairVault, feeEscrow, ctx, res);
        sum = _summarize(res);
    }

    /// @notice Execute triggered StopLimit/StopLoss orders against a fresh oracle price.
    /// @dev Per order, every disqualifier is a silent skip — racing keepers must not revert each
    ///      other's batches: wrong type, terminal state, already in the book (an armed
    ///      StopLimit), expiry, or an unmet trigger. The keeper tip is charged from the owner's
    ///      bucket collateral before the walk (so the fill margin checks see post-tip
    ///      collateral) and accrues to the keeper's claimable balance; an owner who cannot
    ///      cover it has the stop auto-canceled instead, mirroring the fee-coverage rule in
    ///      _checkMargin.
    ///
    ///      The whole batch shares one accumulator and settles storage once at the end. What
    ///      keeps one owner's outcome from coupling to another's is preserved per exec: each
    ///      stop's tip is charged against its own bucket, each walk margin-gates its own fills
    ///      against its own bucket, and the shared fee budget only ever shrinks by charges that
    ///      settle (a waived or refunded attempt restores exactly what it reserved) — the same
    ///      running-ledger sequence a per-exec settle would produce, without rewriting the
    ///      vault slots per exec.
    /// @return executedCount Number of stops that actually fired (fills or armed insertions).
    /// @return sum Aggregate fill totals across all execs for the pair's post-walk hooks.
    function executeTriggers(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.TriggerExec[] calldata execs,
        BazaarTypes.ArrivalContext memory ctx
    ) external returns (uint256 executedCount, BazaarTypes.WalkSummary memory sum) {
        if (execs.length == 0 || execs.length > BazaarTypes.MAX_TRIGGER_EXECS_PER_CALL) {
            revert MatchingEngineLib__InvalidTriggerBatch(execs.length);
        }
        // Trigger evaluation and StopLoss pricing are oracle-derived; a stale fallback price can
        // neither arm a stop nor bound its fill.
        if (ctx.isOracleStale) revert MatchingEngineLib__BlockedOracleStale();
        uint256 cap = _resolveCap(0);
        // The integrator-dedup buffer must hold every fill of every exec in the batch.
        BazaarTypes.ArrivalResult memory res = _initResult(pairVault, cap * execs.length);
        uint256 tipsTotal;
        for (uint256 i; i < execs.length; ++i) {
            uint256 orderId = execs[i].orderId;
            BazaarTypes.Order storage o = orders[orderId];
            BazaarTypes.OrderType ot = o.orderType;
            if (!_isTriggerGated(ot)) continue;
            if (o.creator == address(0) || o.canceledBlock != 0 || o.filledBlock != 0 || o.inBook) continue;
            if (o.expiryBlock < ctx.currentBlock) continue;
            if (!_triggerReached(ot, o.isLong, o.triggerPrice, ctx.cachedPrice)) continue;
            {
                BazaarTypes.PositionBucket storage bucket = positionBuckets[o.creator];
                // The tip debits the deposits ledger too, and D can legitimately sit below an
                // individual bucket's collateral (realized-but-unwithdrawn PnL). res.feeBudget
                // IS the batch's running view of D (seeded from it, drawn down by every tip and
                // settled fee charge). Skip rather than underflow: reverting here would take
                // every other owner's stop in the batch down with it, exactly when the vault is
                // most distressed.
                if (res.feeBudget < BazaarTypes.TRIGGER_TIP) continue;
                if (bucket.collateral < BazaarTypes.TRIGGER_TIP) {
                    Head memory dead;
                    dead.orderId = orderId;
                    dead.order = o;
                    _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, dead, ctx);
                    continue;
                }
                unchecked {
                    // Guarded by the collateral check above; the running budget mirrors D.
                    bucket.collateral -= uint128(BazaarTypes.TRIGGER_TIP);
                    res.feeBudget -= BazaarTypes.TRIGGER_TIP;
                    tipsTotal += BazaarTypes.TRIGGER_TIP;
                }
            }

            BazaarTypes.MatchHints memory hints = execs[i].hints;
            // The keeper's insertion hints are safe to honour (every candidate is verified
            // against the real neighbours before linking), but its step budget is NOT: hitting
            // the cap while still crossing CANCELS the remainder, so a keeper choosing
            // maxSteps = 1 could fill a stop against one dust node and destroy the rest of a
            // protective order it was paid to execute. The stop's owner never authorised this
            // caller, so the budget is always the protocol default here.
            hints.maxSteps = 0;
            // The node cap bounds each stop's own walk; the fee budget and fill aggregates
            // carry across the batch.
            res.nodesVisited = 0;
            _walkTaker(orders, positionBuckets, userActiveLimitOrders, book, orderId, hints, cap, ctx, res);
            unchecked {
                ++executedCount;
            }
        }
        // Tips leave the deposits ledger and become a claimable liability — the keeper pulls
        // them via claimFees, so no transfer can fail mid-batch.
        if (tipsTotal > 0) {
            pairVault.totalCollateralDeposited -= tipsTotal;
            FeeEscrowLib.credit(feeEscrow, ctx.pairId, msg.sender, tipsTotal);
        }
        _finalizeTx(pairVault, feeEscrow, ctx, res);
        sum = _summarize(res);
    }

    /// @notice Cross the vault's pending liquidation inventory into the book, down to the unload
    ///         bound and within the insurance fund's headroom (_planUnload), until the inventory,
    ///         the crossing book, the headroom, or the node budget runs out. Shared by
    ///         liquidate()'s inline unload and unloadVault.
    /// @param payReward When true (the permissionless unloadVault path), the caller earns
    ///        max(UNLOAD_BOUNTY_MIN, LIQUIDATION_FEE_EBP of unloaded notional) from insurance —
    ///        gated by UNLOAD_BOUNTY_MIN_NOTIONAL so dust-sized unloads can't farm the flat
    ///        floor, capped at the fund's free capital, and accrued to the caller's
    ///        claimable balance (pulled via claimFees). liquidate()'s inline unload passes
    ///        false: the liquidator is already paid per position.
    /// @return sum Fill totals for the pair's post-walk hooks.
    function unloadBook(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        BazaarTypes.OrderBook storage book,
        uint256 maxSteps,
        bool payReward,
        BazaarTypes.ArrivalContext memory ctx
    ) external returns (BazaarTypes.WalkSummary memory sum) {
        if (pairVault.pendingLiqSize == 0) return sum;
        uint256 cap = maxSteps == 0
            ? BazaarTypes.MAX_WALK_STEPS
            : (maxSteps < BazaarTypes.MAX_WALK_STEPS ? maxSteps : BazaarTypes.MAX_WALK_STEPS);
        BazaarTypes.ArrivalResult memory res = _initResult(pairVault, cap);
        // The vault unwinds its inherited side against the counterparties who take it over:
        // inherited longs sell to resting bids; inherited shorts buy from resting asks.
        UnloadPlan memory plan = _planUnload(pairVault, ctx, payReward);

        while (pairVault.pendingLiqSize > 0) {
            uint64 headId = plan.vaultIsLong ? book.bidHead : book.askHead;
            if (headId == 0) break;
            unchecked {
                ++res.nodesVisited;
            }
            if (res.nodesVisited > cap) break; // remainder stays as vault inventory
            Head memory m;
            m.orderId = headId;
            m.order = orders[headId];
            if (m.order.expiryBlock < ctx.currentBlock) {
                _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, m, ctx);
                continue;
            }
            // Sorted list: the first maker past the bound means everything deeper is too.
            if (plan.vaultIsLong ? m.order.limitPrice < plan.bound : m.order.limitPrice > plan.bound) break;
            m.remaining = m.order.size - m.order.filledSize;
            // What one unit of this maker does to the headroom: a fill beyond the reference
            // price raises it and is always taken; a fill inside it spends it, and takes only
            // what is left.
            int256 delta = plan.vaultIsLong
                ? int256(uint256(m.order.limitPrice)) - int256(plan.referencePrice)
                : int256(plan.referencePrice) - int256(uint256(m.order.limitPrice));
            // The cap is passed alongside the maker rather than written into m.remaining, which
            // must stay the maker's true remainder so a trimmed fill persists and reports as the
            // partial fill it is.
            uint256 sizeCap = type(uint256).max;
            bool trimmed;
            if (delta < 0) {
                if (plan.headroom <= 0) break;
                uint256 affordable = Math.mulDiv(uint256(plan.headroom), BazaarTypes.BAZAAR_SCALE, uint256(-delta));
                if (affordable == 0) break;
                if (affordable < m.remaining) {
                    sizeCap = affordable;
                    trimmed = true;
                }
            }
            uint256 filled =
                _fillVault(orders, positionBuckets, userActiveLimitOrders, pairVault, book, m, sizeCap, ctx, res);
            plan.headroom += BazaarMathLib.signedMulDiv(delta, int256(filled), int256(BazaarTypes.BAZAAR_SCALE));
            // A trimmed fill spent the last of the headroom, and every maker deeper costs more
            // per unit.
            if (trimmed && filled > 0) break;
        }

        _finalizeTx(pairVault, feeEscrow, ctx, res);

        // The caller is paid the bps rate on whatever it actually unloaded. The flat floor is
        // reserved for a call that did a whole unit of work — one that moved at least
        // UNLOAD_BOUNTY_MIN_NOTIONAL, or finished the inventory. Granting the floor to every call
        // would let a keeper slice one large unload into minimum-sized pieces and collect it on
        // each, paying itself many times the intended rate out of insurance. Below that bar the
        // rate still pays, because a keeper that drains every in-band maker on a thin book has
        // done all the work available and must not come away with nothing. Slicing gains nothing
        // under this rule: the bps total is identical however the unload is divided, and the
        // floor can be earned at most once per inventory.
        if (payReward) {
            uint256 reward = Math.mulDiv(res.totalMatchedVolume, BazaarTypes.LIQUIDATION_FEE_EBP, BazaarTypes.EBP_SCALE);
            if (res.totalMatchedVolume >= BazaarTypes.UNLOAD_BOUNTY_MIN_NOTIONAL || pairVault.pendingLiqSize == 0) {
                if (reward < BazaarTypes.UNLOAD_BOUNTY_MIN) reward = BazaarTypes.UNLOAD_BOUNTY_MIN;
            }
            // A walk that filled nothing earns nothing: no fills means totalMatchedVolume is 0,
            // and the floor is unreachable because pendingLiqSize can only reach 0 through a fill.
            // Capped at the fund's free capital: the seizure still earmarked against open
            // inventory is what settles that inventory, and a reward drawn from it would
            // resurface as a shortfall on the next fill, booked as deficit. The reserve may pay
            // it — it is held for exactly the payouts no bound can refuse — the earmark may not.
            // The reward moves from insurance into the claimable-fee escrow (pulled later via
            // claimFees), so the unload itself never runs a token transfer.
            uint256 free = RiskParamsLib.insuranceFreeCapital(pairVault);
            if (reward > free) reward = free;
            if (reward > 0) {
                pairVault.insuranceFundBalance -= reward;
                FeeEscrowLib.credit(feeEscrow, ctx.pairId, msg.sender, reward);
            }
        }

        sum = _summarize(res);
    }

    // ================================================================
    // THE TAKER WALK
    // ================================================================

    /// @dev Walk the opposing list from its head while the taker crosses, then dispose of the
    ///      remainder. `cap` counts NODES VISITED (skips included), so expired dust in the
    ///      crossing region cannot push the caller past their gas budget. The taker's bucket
    ///      rides in `tc` as a memory image across the whole walk and is flushed to storage
    ///      (with its position events) exactly once at the end.
    function _walkTaker(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.OrderBook storage book,
        uint256 takerId,
        BazaarTypes.MatchHints memory hints,
        uint256 cap,
        BazaarTypes.ArrivalContext memory ctx,
        BazaarTypes.ArrivalResult memory res
    ) private {
        Head memory t;
        t.orderId = takerId;
        t.order = orders[takerId];
        t.remaining = t.order.size - t.order.filledSize;
        TakerCtx memory tc;
        tc.bkt = positionBuckets[t.order.creator];
        tc.posWasLong = tc.bkt.isLong;
        tc.sizeAtStart = tc.bkt.size;
        // Bind a firing TP/SL to the position it closes, at the only moment the answer can be
        // right: the size is capped at whatever the position holds, so a caller who wrote
        // type(uint256).max to mean "all of it" closes exactly the position and no more. A
        // position that went flat or flipped to the order's own side leaves nothing to reduce
        // (filling there would OPEN exposure), which zeroes `remaining` and kills the order
        // below. The capped amount is written back to storage because the fill path stamps an
        // order terminal on filledSize == size, and an uncapped size would never reach it.
        // Walk status: ALIVE while the taker can keep trading, DEAD when its remainder must be
        // canceled, GONE when a fill already terminated its order (nothing left to dispose).
        uint8 status = ALIVE;
        if (_isPositionReducing(t.order.orderType)) {
            uint256 posSize = (tc.bkt.size != 0 && tc.bkt.isLong != t.order.isLong) ? uint256(tc.bkt.size) : 0;
            if (t.order.size > posSize) {
                // posSize fits: it is a uint128 bucket size.
                t.order.size = uint128(posSize);
                orders[takerId].size = uint128(posSize);
                t.remaining = posSize > t.order.filledSize ? posSize - t.order.filledSize : 0;
            }
            if (t.remaining == 0) status = DEAD;
        }
        tc.isLong = t.order.isLong;
        tc.bound = BazaarMathLib.effectivePrice(
            t.order.orderType, t.order.limitPrice, tc.isLong, t.order.maxSlippageBp, ctx.cachedPrice
        );

        while (t.remaining > 0) {
            uint64 headId = tc.isLong ? book.askHead : book.bidHead;
            if (headId == 0) break;
            Head memory m;
            m.orderId = headId;
            m.order = orders[headId];
            uint256 mPrice = m.order.limitPrice;
            if (tc.isLong ? mPrice > tc.bound : mPrice < tc.bound) break; // best price no longer crosses
            unchecked {
                ++res.nodesVisited;
            }
            if (res.nodesVisited > cap) {
                // Still crossing at the cap: the remainder must die — resting it would leave a
                // crossed book.
                status = DEAD;
                break;
            }
            if (m.order.expiryBlock < ctx.currentBlock) {
                _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, m, ctx);
                continue;
            }
            if (ctx.isOracleStale) {
                // Fresh-oracle fills are unbanded: the margin gates price fresh exposure at the
                // live oracle and charge the fill-vs-mark gap up front, and FundingLib clamps
                // every print to ±MAX_MARK_DEVIATION_BP of index before it enters the mark EMA —
                // an off-mark fill is economically real for its two parties and cannot drag the
                // funding mark everyone else pays against. Under the stale fallback those gates
                // judge against an aged reference, so fills are confined to
                // ±MAX_STALE_DEVIATION_BP of it. The two violation directions get opposite
                // dispositions:
                //  • FAR side — maker priced beyond the band away from the taker. The taker is
                //    the one demanding out-of-band execution; the list is price-sorted so nothing
                //    deeper could fill either, and the remainder cannot rest against a maker it
                //    crosses. Cancel the INCOMING order; the maker stays (resting far from an
                //    aged reference is legitimate gap positioning).
                //  • NEAR side — maker priced beyond the band toward the taker. Cancelling takers
                //    here instead would let one such order at the head execute every arrival on
                //    this side for the whole closed session. Cancel the MAKER and retry the next
                //    head, exactly like an expired one.
                // Runs before the post-only check so a post-only arrival is judged against the
                // first maker it could actually fill with, not against near-side garbage.
                uint256 hi = ctx.cachedPrice * (BazaarTypes.BP_SCALE + BazaarTypes.MAX_STALE_DEVIATION_BP)
                    / BazaarTypes.BP_SCALE;
                uint256 lo = ctx.cachedPrice * (BazaarTypes.BP_SCALE - BazaarTypes.MAX_STALE_DEVIATION_BP)
                    / BazaarTypes.BP_SCALE;
                if (tc.isLong ? mPrice > hi : mPrice < lo) {
                    status = DEAD;
                    break;
                }
                if (tc.isLong ? mPrice < lo : mPrice > hi) {
                    _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, m, ctx);
                    continue;
                }
            }
            if (t.order.isPostOnly) {
                // Crossing a live maker at all is the violation; cancel before any fill.
                status = DEAD;
                break;
            }
            if (m.order.creator == t.order.creator) {
                // Self-match cancels the newer order, and the arriving side is always newer.
                status = DEAD;
                break;
            }
            m.remaining = m.order.size - m.order.filledSize;
            uint8 outcome = _fillCrossed(orders, positionBuckets, userActiveLimitOrders, book, m, t, tc, ctx, res);
            if (outcome == TAKER_DEAD) {
                status = DEAD;
                break;
            }
            // Guard the invariant that nothing a fill touches can terminate the TAKER's own
            // order. Every account settled mid-walk is a maker's (self-match cancels the
            // arrival before any fill), and the TP/SL fence only ever cancels orders held in
            // the bucket it settles — so the taker's stamps should still be clear. Re-read
            // rather than trust the memory copy: continuing with a canceled order would let it
            // keep trading, and the check is cheap against the fill it follows.
            if (outcome == FILLED && orders[takerId].canceledBlock != 0) {
                status = GONE;
                break;
            }
            // FILLED or MAKER_DEAD: loop re-reads the head, which the fill/cancel just advanced.
        }

        _disposeRemainder(orders, positionBuckets, userActiveLimitOrders, book, t, tc, hints, status, ctx);
        _flushTaker(orders, positionBuckets, book, t.order.creator, tc, ctx);
    }

    /// @dev Dispose of the taker's post-walk remainder: rest it, cancel it, leave it alone, or —
    ///      for a fill-or-kill taker — revert.
    ///      Market, StopLoss/TakeProfit executions, and IOC limits never rest — a thin book
    ///      therefore leaves a fired TP/SL dead rather than resting for the part it could not
    ///      close. A sub-minimum remainder rests only under the live full-close exemption
    ///      (mirroring creation), so partial fills cannot mint resting dust.
    ///
    ///      Fill-or-kill is enforced here because this is the one point every arriving taker
    ///      reaches with its outcome known: the walk exits through it whether the book was empty,
    ///      the cross ran out, a gate killed the order mid-walk, or the size was filled exactly.
    ///      Anything but a complete fill reverts, which unwinds the fills this walk already
    ///      settled along with the order's own creation — the all-or-none guarantee is bought by
    ///      the revert, not by predicting the depth beforehand. Note that the kill fires on any
    ///      incomplete outcome, including a walk that exhausted its node budget while still
    ///      crossing: the order did not fill, and why it did not is not a distinction the flag
    ///      draws.
    ///      Split from _walkTaker so the walk loop's frame stays inside the Yul stack
    ///      scheduler's reach.
    function _disposeRemainder(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.OrderBook storage book,
        Head memory t,
        TakerCtx memory tc,
        BazaarTypes.MatchHints memory hints,
        uint8 status,
        BazaarTypes.ArrivalContext memory ctx
    ) private {
        // A complete fill is the only survivable outcome for a fill-or-kill taker: ALIVE with
        // nothing remaining. DEAD and GONE both mean the order stopped short, and an ALIVE
        // remainder is the ordinary partial the flag exists to forbid.
        if (t.order.tif == BazaarTypes.TimeInForce.FOK && (status != ALIVE || t.remaining != 0)) {
            revert MatchingEngineLib__FillOrKillUnfilled(t.orderId, t.remaining);
        }
        if (status == GONE) return; // already canceled mid-walk; nothing left to dispose
        if (status == DEAD) {
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, t, ctx);
            return;
        }
        if (t.remaining == 0) return; // fully filled; _persistFill stamped it terminal

        if (_isOracleDerivedPrice(t.order.orderType) || t.order.tif == BazaarTypes.TimeInForce.IOC) {
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, t, ctx);
            return;
        }
        uint256 remNotional = Math.mulDiv(t.remaining, t.order.limitPrice, BazaarTypes.BAZAAR_SCALE);
        // A sub-minimum remainder rests only when it is a live full close. The full-close test
        // reads the walk image, not storage: mid-walk fills have not been flushed yet.
        bool restable = remNotional >= BazaarTypes.MIN_ORDER_AMOUNT
            || (tc.bkt.size > 0 && tc.bkt.isLong != tc.isLong && t.remaining == tc.bkt.size);
        if (!restable) {
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, t, ctx);
            return;
        }
        OrderBookLib.insert(orders, book, t.orderId, hints);
    }

    /// @dev Write the taker's walk-carried bucket image back to storage, run the TP/SL fence
    ///      against the final position, and emit the taker's position events — once per walk.
    ///      No-op when the walk filled nothing. The TP/SL slot pointers are deliberately not
    ///      written from the image: they are storage-resident throughout (persist/cancel/fence
    ///      mutate them directly), and a whole-image write here would resurrect a pointer one
    ///      of those paths already cleared.
    ///
    ///      The fence runs on the FINAL position with the walk-start side as reference. Within
    ///      one walk the position moves monotonically (shrink toward flat, then grow on the
    ///      order's own side after a flip), so "final state flat or flipped" holds exactly when
    ///      some fill's post-state would have tripped a per-fill fence — the canceled set is
    ///      identical, and nothing external can observe the pointers between fills of one
    ///      transaction.
    function _flushTaker(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.OrderBook storage book,
        address user,
        TakerCtx memory tc,
        BazaarTypes.ArrivalContext memory ctx
    ) private {
        if (tc.fills == 0) return;
        BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
        bucket.isLong = tc.bkt.isLong;
        bucket.size = tc.bkt.size;
        bucket.entryValue = tc.bkt.entryValue;
        bucket.collateral = tc.bkt.collateral;
        bucket.entryFundingIndex = tc.bkt.entryFundingIndex;
        bucket.entryMmrBp = tc.bkt.entryMmrBp;
        bucket.mmrUpdateTs = tc.bkt.mmrUpdateTs;

        {
            uint256 keep = (tc.bkt.size > 0 && tc.bkt.isLong != tc.posWasLong) ? 0 : uint256(tc.bkt.size);
            if (tc.sizeAtStart != 0 && keep == 0) {
                _cancelTpSlOverSize(user, bucket, keep, orders, book, ctx.pairId, ctx.currentBlock);
            }
        }

        emit BazaarTypes.PositionModified(
            ctx.pairId,
            user,
            tc.bkt.isLong,
            tc.sizeDeltaAcc,
            tc.bkt.size,
            tc.bkt.entryValue,
            tc.bkt.collateral,
            // Volume-weighted average of this walk's fill prices — the single price that,
            // over totalFillSize, reproduces the taker's exact traded notional.
            Math.mulDiv(tc.volumeAcc, BazaarTypes.BAZAAR_SCALE, tc.fillSizeAcc),
            tc.feeAcc,
            tc.realizedPnlAcc
        );
        BucketLib.emitBucketUpdate(user, bucket, ctx.cachedFundingIdx, ctx.marginReqs, ctx.pairId);
    }

    /// @dev One crossed maker/taker fill: fees, margin gates, then settlement. Mapped into the
    ///      long/short frame so the settlement tail and events are side-symmetric. The maker's
    ///      bucket is read fresh from storage (a different maker each node); the taker's side
    ///      reads the walk image in `tc`, which every settled fill keeps current.
    function _fillCrossed(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.OrderBook storage book,
        Head memory makerH,
        Head memory takerH,
        TakerCtx memory tc,
        BazaarTypes.ArrivalContext memory ctx,
        BazaarTypes.ArrivalResult memory res
    ) private returns (uint8) {
        bool takerIsLong = tc.isLong;
        Head memory longH = takerIsLong ? takerH : makerH;
        Head memory shortH = takerIsLong ? makerH : takerH;

        FillParams memory p;
        p.makerIsLong = !takerIsLong;
        p.fillPrice = makerH.order.limitPrice;
        p.fillSize = takerH.remaining < makerH.remaining ? takerH.remaining : makerH.remaining;
        uint256 fillNotional = Math.mulDiv(p.fillSize, p.fillPrice, BazaarTypes.BAZAAR_SCALE);

        BazaarTypes.PositionBucket memory makerBucketMem = positionBuckets[makerH.order.creator];
        BazaarTypes.PositionBucket memory longBucketMem = takerIsLong ? tc.bkt : makerBucketMem;
        BazaarTypes.PositionBucket memory shortBucketMem = takerIsLong ? makerBucketMem : tc.bkt;
        p.longState = BucketLib.calculateState(longBucketMem, ctx.cachedPrice, ctx.cachedFundingIdx, ctx.marginReqs);
        p.shortState = BucketLib.calculateState(shortBucketMem, ctx.cachedPrice, ctx.cachedFundingIdx, ctx.marginReqs);

        p.fees = _computePairFees(
            p.fillSize,
            fillNotional,
            p.fillPrice,
            p.makerIsLong,
            p.longState,
            p.shortState,
            longBucketMem,
            shortBucketMem,
            longH,
            shortH,
            ctx
        );

        // All-or-nothing fee waiver against the deposits-ledger budget (both sides waived
        // together so charge == payout holds per fill). Fees are collected from bucket
        // collateral but settled against the deposits ledger in finalize, and bucket collateral
        // can legitimately exceed that ledger — so a fill whose fees exceed the remaining budget
        // has ALL its fees waived rather than collecting a fee the ledger cannot fund; rejecting
        // the fill instead would freeze the book exactly when the ledger is drained.
        unchecked {
            uint256 fillFees = p.fees.longTotalFee + p.fees.shortTotalFee;
            if (fillFees > res.feeBudget) {
                PairFees memory waived;
                p.fees = waived;
            } else {
                res.feeBudget -= fillFees;
            }
        }

        // Margin-gate the maker first: a failing maker is auto-canceled and the walk retries
        // the next head, exactly like an expired one.
        {
            Head memory mkH = p.makerIsLong ? longH : shortH;
            BazaarTypes.PositionBucket memory mkBucket = p.makerIsLong ? longBucketMem : shortBucketMem;
            BazaarTypes.BucketState memory mkState = p.makerIsLong ? p.longState : p.shortState;
            uint256 mkFee = p.makerIsLong ? p.fees.longTotalFee : p.fees.shortTotalFee;
            if (!_checkMargin(
                    mkBucket, mkState, p.makerIsLong, p.fillSize, p.fillPrice, mkFee, ctx.cachedPrice, ctx.marginReqs
                )) {
                // Nothing settles, so return the budget this attempt reserved — otherwise a run
                // of margin-failing makers would exhaust it and silently waive the fees of
                // genuine fills later in the same walk.
                unchecked {
                    res.feeBudget += p.fees.longTotalFee + p.fees.shortTotalFee;
                }
                _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, mkH, ctx);
                return MAKER_DEAD;
            }
        }
        {
            BazaarTypes.PositionBucket memory tkBucket = p.makerIsLong ? shortBucketMem : longBucketMem;
            BazaarTypes.BucketState memory tkState = p.makerIsLong ? p.shortState : p.longState;
            uint256 tkFee = p.makerIsLong ? p.fees.shortTotalFee : p.fees.longTotalFee;
            if (!_checkMargin(
                    tkBucket, tkState, !p.makerIsLong, p.fillSize, p.fillPrice, tkFee, ctx.cachedPrice, ctx.marginReqs
                )) {
                unchecked {
                    res.feeBudget += p.fees.longTotalFee + p.fees.shortTotalFee; // nothing settled
                }
                // The taker's cancel happens in _walkTaker so the remainder rule stays in one place.
                return TAKER_DEAD;
            }
        }

        _settleFill(orders, positionBuckets, userActiveLimitOrders, book, longH, shortH, tc, p, ctx, res);
        return FILLED;
    }

    /// @dev Persist + apply a crossed fill and fold it into the walk aggregates. Split from
    ///      _fillCrossed so the fill path's frame stays shallow enough for the Yul stack
    ///      scheduler: the settle tail keeps every struct alive at once, so it reads the
    ///      fee/state products through `p` rather than holding each as its own stack slot.
    ///      The maker's side settles to storage here; the taker's side settles into the walk
    ///      image, which _flushTaker persists once at walk end.
    function _settleFill(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.OrderBook storage book,
        Head memory longH,
        Head memory shortH,
        TakerCtx memory tc,
        FillParams memory p,
        BazaarTypes.ArrivalContext memory ctx,
        BazaarTypes.ArrivalResult memory res
    ) private {
        uint256 fillNotional = Math.mulDiv(p.fillSize, p.fillPrice, BazaarTypes.BAZAAR_SCALE);
        _persistFill(orders, positionBuckets, userActiveLimitOrders, book, longH, p.fillSize, ctx.currentBlock);
        _persistFill(orders, positionBuckets, userActiveLimitOrders, book, shortH, p.fillSize, ctx.currentBlock);

        BazaarTypes.FillResult memory longResult;
        BazaarTypes.FillResult memory shortResult;
        if (p.makerIsLong) {
            longResult = _applyFillMaker(
                orders,
                positionBuckets,
                book,
                longH.order.creator,
                p.longState,
                true,
                p.fillSize,
                p.fillPrice,
                p.fees.longTotalFee,
                ctx
            );
            shortResult = _applyFillTaker(tc, p.shortState, false, p.fillSize, p.fillPrice, p.fees.shortTotalFee, ctx);
        } else {
            longResult = _applyFillTaker(tc, p.longState, true, p.fillSize, p.fillPrice, p.fees.longTotalFee, ctx);
            shortResult = _applyFillMaker(
                orders,
                positionBuckets,
                book,
                shortH.order.creator,
                p.shortState,
                false,
                p.fillSize,
                p.fillPrice,
                p.fees.shortTotalFee,
                ctx
            );
        }
        unchecked {
            tc.volumeAcc += fillNotional;
            tc.fillSizeAcc += p.fillSize;
            ++tc.fills;
        }

        _aggregateFill(res, longResult, shortResult, p.fees, p.fillSize, fillNotional, longH, shortH);
        _accumulateFillIntegratorFees(res, longH, shortH, p.fees);
        _emitFillEvents(ctx, longH, shortH, p, longResult, shortResult);
    }

    function _aggregateFill(
        BazaarTypes.ArrivalResult memory res,
        BazaarTypes.FillResult memory longResult,
        BazaarTypes.FillResult memory shortResult,
        PairFees memory fees,
        uint256 fillSize,
        uint256 fillNotional,
        Head memory longH,
        Head memory shortH
    ) private pure {
        unchecked {
            res.deltaLongOI += longResult.longOIDelta + shortResult.longOIDelta;
            res.deltaShortOI += longResult.shortOIDelta + shortResult.shortOIDelta;
            res.deltaLongWeightedEntry += longResult.longWeightedDelta + shortResult.longWeightedDelta;
            res.deltaShortWeightedEntry += longResult.shortWeightedDelta + shortResult.shortWeightedDelta;
            res.totalIntegratorFees += fees.longIntegratorFee + fees.shortIntegratorFee;
            res.totalInsuranceFees += fees.longInsuranceFee + fees.shortInsuranceFee;

            ++res.fillCount;
            res.totalMatchedVolume += fillNotional; // = Σ fillNotional: the VWAP numerator
            res.totalFillSize += fillSize;

            longH.remaining -= fillSize;
            shortH.remaining -= fillSize;
            // Fits: fills are capped at each order's remaining (see _persistFill).
            longH.order.filledSize += uint128(fillSize);
            shortH.order.filledSize += uint128(fillSize);
        }
    }

    function _accumulateFillIntegratorFees(
        BazaarTypes.ArrivalResult memory res,
        Head memory longH,
        Head memory shortH,
        PairFees memory fees
    ) private pure {
        address longInt = longH.order.integrator;
        address shortInt = shortH.order.integrator;
        if (longInt == shortInt) {
            res.integratorCount = _accumulateIntegratorFee(
                res.integratorAccums, res.integratorCount, longInt, fees.longIntegratorFee + fees.shortIntegratorFee
            );
        } else {
            res.integratorCount =
                _accumulateIntegratorFee(res.integratorAccums, res.integratorCount, longInt, fees.longIntegratorFee);
            res.integratorCount =
                _accumulateIntegratorFee(res.integratorAccums, res.integratorCount, shortInt, fees.shortIntegratorFee);
        }
    }

    /// @dev Per-fill events: an OrderFilled per side (the per-price trade record), plus the
    ///      MAKER's PositionModified — the maker is a different account at every node, so its
    ///      position settles per fill. The taker's PositionModified is emitted once per walk by
    ///      _flushTaker, with the walk's VWAP and net deltas.
    function _emitFillEvents(
        BazaarTypes.ArrivalContext memory ctx,
        Head memory longH,
        Head memory shortH,
        FillParams memory p,
        BazaarTypes.FillResult memory longResult,
        BazaarTypes.FillResult memory shortResult
    ) private {
        emit BazaarTypes.OrderFilled(
            ctx.pairId,
            longH.orderId,
            longH.order.creator,
            true,
            p.fillSize,
            longH.order.filledSize,
            longH.remaining,
            p.fillPrice,
            p.fees.longTotalFee,
            longH.remaining == 0,
            p.makerIsLong
        );
        emit BazaarTypes.OrderFilled(
            ctx.pairId,
            shortH.orderId,
            shortH.order.creator,
            false,
            p.fillSize,
            shortH.order.filledSize,
            shortH.remaining,
            p.fillPrice,
            p.fees.shortTotalFee,
            shortH.remaining == 0,
            !p.makerIsLong
        );
        Head memory mkH = p.makerIsLong ? longH : shortH;
        BazaarTypes.FillResult memory mkResult = p.makerIsLong ? longResult : shortResult;
        emit BazaarTypes.PositionModified(
            ctx.pairId,
            mkH.order.creator,
            mkResult.newIsLong,
            mkResult.sizeDelta,
            mkResult.newSize,
            mkResult.newEntryValue,
            mkResult.newCollateral,
            p.fillPrice,
            p.makerIsLong ? p.fees.longTotalFee : p.fees.shortTotalFee,
            mkResult.realizedPnl
        );
    }

    /// @dev Compute both sides' fees for a crossed fill. The maker pays the flat maker-tier
    ///      insurance rate; the taker pays the dynamic insurance rate, split between
    ///      risk-reducing and risk-adding notionals. Integrator fees are charged only on orders
    ///      that carry an integrator address — direct-to-contract traders pay no integrator fee.
    function _computePairFees(
        uint256 fillSize,
        uint256 fillNotional,
        uint256 fillPrice,
        bool makerIsLong,
        BazaarTypes.BucketState memory longState,
        BazaarTypes.BucketState memory shortState,
        BazaarTypes.PositionBucket memory longBucket,
        BazaarTypes.PositionBucket memory shortBucket,
        Head memory longHead,
        Head memory shortHead,
        BazaarTypes.ArrivalContext memory ctx
    ) private pure returns (PairFees memory fees) {
        unchecked {
            uint256 makerIntFee = (fillNotional * BazaarTypes.MAKER_INTEGRATOR_FEE_EBP) / BazaarTypes.EBP_SCALE;
            uint256 takerIntFee = (fillNotional * BazaarTypes.TAKER_INTEGRATOR_FEE_EBP) / BazaarTypes.EBP_SCALE;
            uint256 makerInsFee = (fillNotional * BazaarTypes.MAKER_INSURANCE_FEE_EBP) / BazaarTypes.EBP_SCALE;

            uint256 takerInsFee;
            {
                BazaarTypes.BucketState memory takerState;
                BazaarTypes.PositionBucket memory takerBucket;
                bool takerIsLong;
                if (makerIsLong) {
                    takerState = shortState;
                    takerBucket = shortBucket;
                    takerIsLong = false;
                } else {
                    takerState = longState;
                    takerBucket = longBucket;
                    takerIsLong = true;
                }
                if (takerState.adjustedSize == 0 || takerBucket.isLong == takerIsLong) {
                    takerInsFee = (fillNotional * ctx.insuranceFeeEbp) / BazaarTypes.EBP_SCALE;
                } else {
                    // Closing is never more expensive than opening: the closing portion pays the
                    // base (closing) rate, which the dynamic rate never dips below, so the
                    // deficit stress multiplier lands only on the risk-adding portion.
                    uint256 closingSize = fillSize > takerState.adjustedSize ? takerState.adjustedSize : fillSize;
                    uint256 closingNotional = Math.mulDiv(closingSize, fillPrice, BazaarTypes.BAZAAR_SCALE);
                    uint256 riskAddingNotional = fillNotional - closingNotional;
                    takerInsFee = (closingNotional * ctx.closingFeeEbp) / BazaarTypes.EBP_SCALE
                        + (riskAddingNotional * ctx.insuranceFeeEbp) / BazaarTypes.EBP_SCALE;
                }
            }

            if (makerIsLong) {
                fees.longIntegratorFee = makerIntFee;
                fees.longInsuranceFee = makerInsFee;
                fees.shortIntegratorFee = takerIntFee;
                fees.shortInsuranceFee = takerInsFee;
            } else {
                fees.shortIntegratorFee = makerIntFee;
                fees.shortInsuranceFee = makerInsFee;
                fees.longIntegratorFee = takerIntFee;
                fees.longInsuranceFee = takerInsFee;
            }
            if (longHead.order.integrator == address(0)) fees.longIntegratorFee = 0;
            if (shortHead.order.integrator == address(0)) fees.shortIntegratorFee = 0;
            fees.longTotalFee = fees.longIntegratorFee + fees.longInsuranceFee;
            fees.shortTotalFee = fees.shortIntegratorFee + fees.shortInsuranceFee;
        }
    }

    // ================================================================
    // VAULT UNLOAD FILLS
    // ================================================================

    /// @dev One fill of vault inventory against the resting maker at the head, capped at the
    ///      maker's remainder, the inventory, and `sizeCap` (the headroom the walk has left for
    ///      it). The maker's leg settles into its own bucket; the vault's PnL accumulates in
    ///      `res` and settles through insurance in finalize. Returns the size filled, 0 when the
    ///      maker was auto-canceled instead.
    function _fillVault(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.OrderBook storage book,
        Head memory makerH,
        uint256 sizeCap,
        BazaarTypes.ArrivalContext memory ctx,
        BazaarTypes.ArrivalResult memory res
    ) private returns (uint256) {
        VaultFillData memory data;
        data.fillSize = makerH.remaining;
        if (data.fillSize > sizeCap) data.fillSize = sizeCap;
        if (data.fillSize > pairVault.pendingLiqSize) data.fillSize = pairVault.pendingLiqSize;
        if (data.fillSize == 0) return 0;

        data.execPrice = makerH.order.limitPrice;
        data.fillNotional = Math.mulDiv(data.fillSize, data.execPrice, BazaarTypes.BAZAAR_SCALE);

        unchecked {
            // No integrator on the order → no integrator fee (direct-to-contract traders
            // aren't charged for a front-end they didn't use).
            data.makerIntFee = makerH.order.integrator == address(0)
                ? 0
                : (data.fillNotional * BazaarTypes.MAKER_INTEGRATOR_FEE_EBP) / BazaarTypes.EBP_SCALE;
            data.makerInsFee = (data.fillNotional * BazaarTypes.MAKER_INSURANCE_FEE_EBP) / BazaarTypes.EBP_SCALE;
            data.makerTotalFee = data.makerIntFee + data.makerInsFee;
        }

        // All-or-nothing fee waiver against the deposits-ledger budget (rationale in
        // _fillCrossed).
        if (data.makerTotalFee > res.feeBudget) {
            data.makerIntFee = 0;
            data.makerInsFee = 0;
            data.makerTotalFee = 0;
        } else {
            unchecked {
                res.feeBudget -= data.makerTotalFee;
            }
        }

        BazaarTypes.PositionBucket memory makerBucket = positionBuckets[makerH.order.creator];
        BazaarTypes.BucketState memory makerState =
            BucketLib.calculateState(makerBucket, ctx.cachedPrice, ctx.cachedFundingIdx, ctx.marginReqs);

        if (!_checkMargin(
                makerBucket,
                makerState,
                makerH.order.isLong,
                data.fillSize,
                data.execPrice,
                data.makerTotalFee,
                ctx.cachedPrice,
                ctx.marginReqs
            )) {
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, makerH, ctx);
            return 0; // head advanced; the unload loop retries the next maker
        }

        _persistFill(orders, positionBuckets, userActiveLimitOrders, book, makerH, data.fillSize, ctx.currentBlock);
        BazaarTypes.FillResult memory mr = _applyFillMaker(
            orders,
            positionBuckets,
            book,
            makerH.order.creator,
            makerState,
            makerH.order.isLong,
            data.fillSize,
            data.execPrice,
            data.makerTotalFee,
            ctx
        );

        int256 vaultPnl = _settleVaultLiquidation(
            pairVault, res, data.fillSize, data.execPrice, data.fillNotional, ctx.cachedFundingIdx
        );

        unchecked {
            res.deltaLongOI += mr.longOIDelta;
            res.deltaShortOI += mr.shortOIDelta;
            res.deltaLongWeightedEntry += mr.longWeightedDelta;
            res.deltaShortWeightedEntry += mr.shortWeightedDelta;
            res.totalIntegratorFees += data.makerIntFee;
            res.totalInsuranceFees += data.makerInsFee;
            res.totalVaultPnl += vaultPnl;
            ++res.fillCount;
            res.totalMatchedVolume += data.fillNotional;
            res.totalFillSize += data.fillSize;
            makerH.remaining -= data.fillSize;
            // Fits: the fill is capped at the maker's remaining (see _persistFill).
            makerH.order.filledSize += uint128(data.fillSize);
        }

        res.integratorCount = _accumulateIntegratorFee(
            res.integratorAccums, res.integratorCount, makerH.order.integrator, data.makerIntFee
        );

        emit BazaarTypes.OrderFilled(
            ctx.pairId,
            makerH.orderId,
            makerH.order.creator,
            makerH.order.isLong,
            data.fillSize,
            makerH.order.filledSize,
            makerH.remaining,
            data.execPrice,
            data.makerTotalFee,
            makerH.remaining == 0,
            true
        );
        emit BazaarTypes.PositionModified(
            ctx.pairId,
            makerH.order.creator,
            mr.newIsLong,
            mr.sizeDelta,
            mr.newSize,
            mr.newEntryValue,
            mr.newCollateral,
            data.execPrice,
            data.makerTotalFee,
            mr.realizedPnl
        );
        return data.fillSize;
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

    /// @dev Computed once from start-of-walk state. Three quantities anchor the walk.
    ///
    ///      The fund-neutral price: the price at which closing the inventory pays back exactly
    ///      the collateral seized with it, net of the funding accrued since the estates entered
    ///      — the entry basis less the seizure, carried forward by that funding, valued per unit.
    ///      A fill at it costs the fund nothing; each unit sold away from it costs the distance.
    ///
    ///      The bound is the looser of two anchors: the fund-neutral price itself, and the oracle
    ///      moved min(LIQ_MAX_SLIPPAGE_BP, MMR) against the vault. A maker beyond both is refused,
    ///      so a fill outside the band that still beats the estates' bankruptcy price goes through,
    ///      and so does one under bankruptcy that stays inside the band. Neither anchor moves
    ///      during the walk: every fill releases a proportional slice of the aggregate, so the
    ///      neutral price is invariant, and the oracle is fixed within the transaction.
    ///
    ///      The headroom is what the fund may spend on fills inside the bound: free capital above
    ///      its reserve (RiskParamsLib.vaultAdlExposure), less the loss the inventory already
    ///      carries at the mark, less the caller's reward when one is paid, since that leaves the
    ///      fund after the walk and must not come out of the reserve. A fill is measured against
    ///      the reference price: beyond it a fill lowers the loss the remainder carries by at
    ///      least what it costs, so it is always taken; inside it a fill costs the difference per
    ///      unit, and the walk takes only what the headroom covers. While the base covers the
    ///      loss at the mark — the gate's own healthy condition — the reference is the nearer of
    ///      the neutral price and the oracle, because the headroom has already set that loss
    ///      aside: spending it to zero leaves the fund above its reserve by exactly the remaining
    ///      inventory's loss at the mark, the pair ends the walk healthy, and the post-walk
    ///      verdict opens the auction only if the price has moved since. Past the trigger nothing
    ///      was set aside, so a fill at the mark would draw cash the fund does not hold above its
    ///      reserve: the reference is the neutral price and the walk takes only fills that cost
    ///      the fund nothing, leaving the rest to the auction. An unload can therefore never take
    ///      the fund below its reserve, and never carry a pair over the ADL trigger it did not
    ///      start past.
    ///
    ///      Rounded toward the vault: the neutral price rounds up as a floor and down as a
    ///      ceiling, and sizes round down.
    /// @param pairVault The pair's vault aggregates
    /// @param ctx The walk context: oracle price, funding index and margin requirements
    /// @param payReward Whether the caller earns the unload reward this walk
    /// @return plan The side, bound, reference price and headroom for the walk
    function _planUnload(BazaarTypes.Vault storage pairVault, BazaarTypes.ArrivalContext memory ctx, bool payReward)
        private
        view
        returns (UnloadPlan memory plan)
    {
        plan.vaultIsLong = pairVault.pendingLiqIsLong;
        uint256 size = pairVault.pendingLiqSize;
        uint256 oracle = ctx.cachedPrice;

        (uint256 expectedLoss, uint256 base,,) =
            RiskParamsLib.vaultAdlExposure(pairVault, oracle, ctx.cachedFundingIdx, ctx.marginReqs.mmrBp);
        plan.headroom = int256(base) - int256(expectedLoss);

        // Positive when the index rose since the estates' entry: paid by inherited longs,
        // received by inherited shorts — the term _settleVaultLiquidation realizes on a fill.
        // Either way it raises the fund-neutral price: a long that has paid must sell that
        // much higher to break even, a short that has received can buy back that much higher.
        int256 rawFunding = BazaarMathLib.signedMulDiv(
            ctx.cachedFundingIdx - pairVault.pendingLiqEntryFundingIndex, int256(size), int256(BazaarTypes.BAZAAR_SCALE)
        );
        // The seizure sits on the sale side of the ledger for longs (the vault sells and must
        // recover it) and on the purchase side for shorts (the vault buys and may spend it).
        int256 neutralNotional = plan.vaultIsLong
            ? int256(pairVault.pendingLiqEntryNotional) - int256(pairVault.pendingLiqSeized) + rawFunding
            : int256(pairVault.pendingLiqEntryNotional) + int256(pairVault.pendingLiqSeized) + rawFunding;
        uint256 neutral;
        if (neutralNotional > 0) {
            neutral = Math.mulDiv(
                uint256(neutralNotional),
                BazaarTypes.BAZAAR_SCALE,
                size,
                plan.vaultIsLong ? Math.Rounding.Ceil : Math.Rounding.Floor
            );
        }
        uint256 mmrBp = ctx.marginReqs.mmrBp;
        uint256 bandBp = mmrBp < BazaarTypes.LIQ_MAX_SLIPPAGE_BP ? mmrBp : BazaarTypes.LIQ_MAX_SLIPPAGE_BP;
        // The headroom pre-charges the inventory's loss at the mark, so a fill at the mark is
        // free only while the base actually covers that loss. Past the trigger it does not, and
        // the reference moves to the neutral price: the only fills left are the ones that cost
        // the fund nothing.
        bool funded = base >= expectedLoss;
        if (plan.vaultIsLong) {
            uint256 bandEdge = oracle * (BazaarTypes.BP_SCALE - bandBp) / BazaarTypes.BP_SCALE;
            plan.bound = neutral < bandEdge ? neutral : bandEdge;
            plan.referencePrice = funded && oracle < neutral ? oracle : neutral;
        } else {
            uint256 bandEdge = oracle * (BazaarTypes.BP_SCALE + bandBp) / BazaarTypes.BP_SCALE;
            plan.bound = neutral > bandEdge ? neutral : bandEdge;
            plan.referencePrice = funded && oracle > neutral ? oracle : neutral;
        }

        // The caller's reward is paid after the walk on the notional actually filled, so it is
        // reserved on the notional the walk could fill at most: the whole inventory at the
        // price furthest from the oracle the bound admits.
        if (payReward) {
            uint256 dearest = plan.vaultIsLong ? oracle : (plan.bound > oracle ? plan.bound : oracle);
            uint256 reward = Math.mulDiv(
                Math.mulDiv(size, dearest, BazaarTypes.BAZAAR_SCALE),
                BazaarTypes.LIQUIDATION_FEE_EBP,
                BazaarTypes.EBP_SCALE
            );
            if (reward < BazaarTypes.UNLOAD_BOUNTY_MIN) reward = BazaarTypes.UNLOAD_BOUNTY_MIN;
            plan.headroom -= int256(reward);
        }
    }

    /// @dev Settle one vault-liquidation fill: compute vault PnL (price + funding accrued on the
    ///      inventory from the liquidatees' entries through this close), update gap-EMA
    ///      accumulators, and decrement the pending-liq aggregates proportionally.
    function _settleVaultLiquidation(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.ArrivalResult memory res,
        uint256 fillSize,
        uint256 execPrice,
        uint256 fillNotional,
        int256 currentFundingIndex
    ) private returns (int256 vaultPnl) {
        unchecked {
            uint256 existingSize = pairVault.pendingLiqSize;
            // Proportional entry notional for this fill, rounded ONCE and reused verbatim by the
            // aggregate decrement below — the PnL settled into insurance must match exactly the
            // notional released from the books (a via-avg-price recompute double-rounds and drifts).
            uint256 entryPortion = Math.mulDiv(pairVault.pendingLiqEntryNotional, fillSize, existingSize);
            vaultPnl = pairVault.pendingLiqIsLong
                ? int256(fillNotional) - int256(entryPortion)
                : int256(entryPortion) - int256(fillNotional);

            // Realize funding accrued on the pending-liq inventory from the LIQUIDATEES' ENTRIES
            // through this close (pendingLiqEntryFundingIndex is their entry-weighted index, not
            // the liquidation-time index), so funding stays zero-sum: this one signed term settles
            // both the dead estates' pre-liquidation balances and the vault's holding window into
            // insurance. The counterparty of this fill settles its own tab (if it is closing)
            // inside its fill via _applyFillMaker into its OWN bucket — its side never routes
            // through insurance, which is why the vault's side needs this explicit entry. (A
            // slice closed against a deleveraged winner books the same two legs, see
            // AdlLib._settleInventorySlice.) The index is a size-weighted average, so it's
            // unchanged on a proportional partial close.
            int256 rawFunding = BazaarMathLib.signedMulDiv(
                currentFundingIndex - pairVault.pendingLiqEntryFundingIndex,
                int256(fillSize),
                int256(BazaarTypes.BAZAAR_SCALE)
            );
            vaultPnl += pairVault.pendingLiqIsLong ? -rawFunding : rawFunding;

            // Gap-EMA accumulators (against avg bankruptcy price)
            uint256 avgBP = Math.mulDiv(pairVault.pendingLiqBankruptcyNotional, BazaarTypes.BAZAAR_SCALE, existingSize);
            int256 gapBp;
            if (avgBP != 0) {
                gapBp = pairVault.pendingLiqIsLong
                    ? (int256(avgBP) - int256(execPrice)) * int256(BazaarTypes.BP_SCALE) / int256(avgBP)
                    : (int256(execPrice) - int256(avgBP)) * int256(BazaarTypes.BP_SCALE) / int256(avgBP);
            }
            res.sumLiqGapTimesSize += gapBp * int256(fillSize);
            res.totalLiqFillSize += fillSize;
            ++res.liqCount;

            // Decrement vault aggregate proportionally (entryPortion shared with the PnL above)
            uint256 bkPortion = Math.mulDiv(pairVault.pendingLiqBankruptcyNotional, fillSize, existingSize);
            uint256 seizedPortion = Math.mulDiv(pairVault.pendingLiqSeized, fillSize, existingSize);
            pairVault.pendingLiqSize = existingSize - fillSize;
            pairVault.pendingLiqEntryNotional -= entryPortion;
            pairVault.pendingLiqBankruptcyNotional -= bkPortion;
            pairVault.pendingLiqSeized -= seizedPortion;
        }
    }

    // ================================================================
    // FILL HELPERS
    // ================================================================

    function _persistFill(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.OrderBook storage book,
        Head memory h,
        uint256 fillSize,
        uint64 currentBlock
    ) private {
        BazaarTypes.Order storage stored = orders[h.orderId];
        uint256 newFilled;
        unchecked {
            newFilled = uint256(h.order.filledSize) + fillSize;
        }
        // Fits: fills are capped at the order's remaining, so newFilled <= size (uint128).
        stored.filledSize = uint128(newFilled);
        if (newFilled == h.order.size) {
            stored.filledBlock = currentBlock;
            OrderBookLib.unlink(orders, book, h.orderId);
            BazaarTypes.OrderType ot = h.order.orderType;
            if (ot == BazaarTypes.OrderType.Limit || ot == BazaarTypes.OrderType.StopLimit) {
                userActiveLimitOrders[h.order.creator].remove(h.orderId);
            } else if (ot == BazaarTypes.OrderType.TakeProfit) {
                positionBuckets[h.order.creator].takeProfitOrderId = 0;
            } else if (ot == BazaarTypes.OrderType.StopLoss) {
                positionBuckets[h.order.creator].stopLossOrderId = 0;
            }
        }
    }

    /// @dev Auto-cancel an order — used for expiry-on-contact, self-match, post-only violation,
    ///      margin failure, step-cap, stale-band, dust, and IOC/market remainders. Sets
    ///      canceledBlock, unlinks from the book, clears the appropriate slot pointer, emits
    ///      OrderUpdated.
    function _autoCancelOrder(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.OrderBook storage book,
        Head memory h,
        BazaarTypes.ArrivalContext memory ctx
    ) private {
        BazaarTypes.Order storage stored = orders[h.orderId];
        stored.canceledBlock = ctx.currentBlock;
        OrderBookLib.unlink(orders, book, h.orderId);

        BazaarTypes.OrderType ot = h.order.orderType;
        if (ot == BazaarTypes.OrderType.Limit || ot == BazaarTypes.OrderType.StopLimit) {
            userActiveLimitOrders[h.order.creator].remove(h.orderId);
        } else if (ot == BazaarTypes.OrderType.TakeProfit) {
            positionBuckets[h.order.creator].takeProfitOrderId = 0;
        } else if (ot == BazaarTypes.OrderType.StopLoss) {
            positionBuckets[h.order.creator].stopLossOrderId = 0;
        }

        emit BazaarTypes.OrderUpdated(
            ctx.pairId,
            h.orderId,
            h.order.creator,
            BazaarTypes.OrderUpdatePayload({
                action: BazaarTypes.OrderAction.Canceled,
                orderType: ot,
                isLong: h.order.isLong,
                isPostOnly: h.order.isPostOnly,
                size: h.order.size,
                filledSize: h.order.filledSize,
                triggerPrice: h.order.triggerPrice,
                limitPrice: h.order.limitPrice,
                maxSlippageBp: h.order.maxSlippageBp,
                canceledBlock: ctx.currentBlock,
                filledBlock: h.order.filledBlock,
                expiryBlock: h.order.expiryBlock,
                creationBlock: h.order.creationBlock
            })
        );
    }

    // ================================================================
    // MARGIN + APPLY FILL
    // ================================================================

    /// @notice Margin gate for a candidate fill. Classifies the trade by SIZE (open / add / close /
    ///         flip), realizes PnL on closing portions, and applies a one-sided incipient-loss debit
    ///         on fresh exposure. Returns false (caller auto-cancels) on any of:
    ///           - open/add: post-debit collateral < required IMR
    ///           - fresh exposure: incipient loss exceeds collateral (would open insolvent at the mark)
    ///           - close/flip: realized loss exceeds collateral (would create bad debt)
    ///           - partial close: post-realization collateral < MMR on the remainder
    ///           - flip: post-close collateral < IMR on residual
    /// @dev The caller passes the batch's resolved margin requirements — there is no stale branch
    ///      inside. Risk-reducing fills are judged against MMR rather than IMR, which is why the
    ///      whole struct is threaded rather than a rate: the partial-close branch needs the lagged
    ///      sample and its timestamp together to resolve the remainder's effective MMR.
    function _checkMargin(
        BazaarTypes.PositionBucket memory bucket,
        BazaarTypes.BucketState memory state,
        bool isLong,
        uint256 fillSize,
        uint256 executionPrice,
        uint256 fee,
        uint256 cachedPrice,
        BazaarTypes.MarginRequirements memory marginReqs
    ) internal pure returns (bool) {
        // The fee must be fully coverable by the bucket's own collateral. If it isn't, flooring the
        // deduction at 0 would under-collect the fee while finalize still decrements D (and pays out)
        // the full nominal amount — draining the shared deposit pool and eventually bricking the last
        // withdrawer. Reject instead: the caller auto-cancels this order and skips it, so only fills
        // whose fee is fully collectable ever proceed (nominal fee == collected fee thereafter).
        if (state.effectiveCollateral < fee) return false;
        uint256 collateralAfterFee = state.effectiveCollateral - fee;

        uint256 newExposureSize; // size of fresh exposure (drives incipient-loss debit)
        // Notional driving the IMR/MMR requirement. Fresh exposure is valued at the oracle price,
        // never at the price the fill crossed at: the execution price sets the position's cost basis
        // (entryValue), while the requirement must cover what the position is worth now — which is
        // what calculateState, liquidation and withdrawal all measure it against one block later.
        // Pricing it at the fill would let a cross far below the mark open a large position against
        // a near-zero requirement, and would admit positions already past maintenance margin the
        // moment they exist. For fresh exposure the execution price enters only through the
        // incipient-loss debit below, which charges the fill-vs-mark gap exactly once.
        uint256 newTotalNotional;
        uint256 effectiveBp;

        if (bucket.size == 0) {
            // Open from flat
            newExposureSize = fillSize;
            newTotalNotional = Math.mulDiv(fillSize, cachedPrice, BazaarTypes.BAZAAR_SCALE);
            effectiveBp = marginReqs.imrBp;
        } else if (bucket.isLong == isLong) {
            // Same-side add
            newExposureSize = fillSize;
            newTotalNotional = state.currentNotional + Math.mulDiv(fillSize, cachedPrice, BazaarTypes.BAZAAR_SCALE);
            effectiveBp = marginReqs.imrBp;
        } else if (fillSize <= bucket.size) {
            // Partial / full close — apply realized PnL up front, reject if it underwaters collateral
            newExposureSize = 0;

            uint256 closedEntryValue = Math.mulDiv(state.entryValue, fillSize, bucket.size);
            uint256 closedNotional = Math.mulDiv(fillSize, executionPrice, BazaarTypes.BAZAAR_SCALE);
            int256 realizedPnl = bucket.isLong
                ? int256(closedNotional) - int256(closedEntryValue)
                : int256(closedEntryValue) - int256(closedNotional);
            // Funding settles on the closed shares (mirrors _applyFillCore) — gate on the
            // combined sum so the gate and settlement agree.
            int256 closedFunding =
                BazaarMathLib.signedMulDiv(state.fundingPnl, int256(fillSize), int256(uint256(bucket.size)));

            int256 postFillCol = int256(collateralAfterFee) + realizedPnl + closedFunding;
            if (postFillCol < 0) return false; // bad debt — must liquidate instead
            collateralAfterFee = uint256(postFillCol);

            uint256 remaining = bucket.size - fillSize;
            newTotalNotional = Math.mulDiv(remaining, cachedPrice, BazaarTypes.BAZAAR_SCALE);
            // 24h-lagged effective MMR for the surviving remainder (consistent with BucketLib).
            effectiveBp = BucketLib.effectiveMmr(
                state.mmrUpdateTs, state.entryMmrBp, marginReqs.laggedMmrBp, marginReqs.laggedMmrTs, marginReqs.mmrBp
            );
        } else {
            // Flip — close existing fully, residual = fillSize − bucket.size on the new side
            uint256 closedNotional = Math.mulDiv(bucket.size, executionPrice, BazaarTypes.BAZAAR_SCALE);
            int256 realizedPnl = bucket.isLong
                ? int256(closedNotional) - int256(state.entryValue)
                : int256(state.entryValue) - int256(closedNotional);

            // Flip closes the whole position — its entire fundingPnl settles (mirrors _applyFillCore).
            int256 postCloseCol = int256(collateralAfterFee) + realizedPnl + state.fundingPnl;
            if (postCloseCol < 0) return false; // bad debt on closed portion — must liquidate
            collateralAfterFee = uint256(postCloseCol);

            newExposureSize = fillSize - bucket.size;
            newTotalNotional = Math.mulDiv(newExposureSize, cachedPrice, BazaarTypes.BAZAAR_SCALE);
            effectiveBp = marginReqs.imrBp;
        }

        // One-sided incipient PnL on fresh exposure: debit losses, ignore gains. The debit must be
        // fully coverable by collateral. Flooring it at 0 would admit a fill whose fresh exposure is
        // already underwater by more than the account holds — the position opens insolvent at the
        // oracle mark, seizable for far less than it owes, while the gap between execution price and
        // mark accrues to the counterparty as profit drawn from totalCollateralDeposited. Reject
        // instead, matching the realized-loss gates on the close and flip branches.
        if (newExposureSize > 0) {
            uint256 loss;
            if (isLong && executionPrice > cachedPrice) {
                loss = Math.mulDiv(newExposureSize, executionPrice - cachedPrice, BazaarTypes.BAZAAR_SCALE);
            } else if (!isLong && cachedPrice > executionPrice) {
                loss = Math.mulDiv(newExposureSize, cachedPrice - executionPrice, BazaarTypes.BAZAAR_SCALE);
            }
            if (loss > collateralAfterFee) return false;
            collateralAfterFee -= loss;
        }

        uint256 requiredMargin = Math.mulDiv(effectiveBp, newTotalNotional, BazaarTypes.BP_SCALE);
        return collateralAfterFee >= requiredMargin;
    }

    /// @dev Pure position-transition math for one side of a fill: classifies the trade by size
    ///      (open / add / close / flip), realizes PnL and funding on closing portions, charges
    ///      the fee, and mutates `state` to the post-fill position. Storage-free: the maker
    ///      wrapper persists the result per fill, the taker wrapper folds it into the walk
    ///      image. `view` only for the block.timestamp grace-clock stamps.
    /// @return result OI/weighted-entry deltas, realized PnL, and the post-fill position fields.
    /// @return newPosIsLong The position's side after the fill (== posWasLong unless the fill
    ///         opened from flat or flipped).
    function _applyFillCore(
        BazaarTypes.BucketState memory state,
        bool posWasLong,
        bool orderIsLong,
        uint256 fillSize,
        uint256 executionPrice,
        uint256 fee,
        BazaarTypes.ArrivalContext memory ctx
    ) private view returns (BazaarTypes.FillResult memory result, bool newPosIsLong) {
        newPosIsLong = posWasLong;

        uint256 fillNotional = Math.mulDiv(fillSize, executionPrice, BazaarTypes.BAZAAR_SCALE);
        uint256 originalSize = state.adjustedSize;
        bool originalIsLong = posWasLong;

        // _checkMargin guarantees effectiveCollateral >= fee for every fill that reaches here, so
        // this never floors a shortfall away. Kept as a checked subtraction (not unchecked/floored):
        // if the coverage invariant were ever violated it reverts the transaction rather than
        // silently under-collecting.
        state.effectiveCollateral = state.effectiveCollateral - fee;

        if (originalSize == 0) {
            state.adjustedSize = fillSize;
            state.entryValue = fillNotional;
            newPosIsLong = orderIsLong;
            state.adjustedEntryFundingIndex = ctx.cachedFundingIdx;
            state.entryMmrBp = ctx.marginReqs.mmrBp;
            state.mmrUpdateTs = block.timestamp; // (re)stamp grace clock when entry MMR is set

            result.sizeDelta = int256(fillSize);
            if (orderIsLong) {
                result.longOIDelta = int256(fillSize);
                result.longWeightedDelta = int256(fillNotional);
            } else {
                result.shortOIDelta = int256(fillSize);
                result.shortWeightedDelta = int256(fillNotional);
            }
        } else if (originalIsLong == orderIsLong) {
            uint256 newSize;
            uint256 newEntryValue;
            unchecked {
                newSize = state.adjustedSize + fillSize;
                newEntryValue = state.entryValue + fillNotional;
            }
            int256 newWeightedFunding = BazaarMathLib.signedMulDiv(
                state.adjustedEntryFundingIndex * int256(state.adjustedSize) + ctx.cachedFundingIdx * int256(fillSize),
                1,
                int256(newSize)
            );
            state.adjustedSize = newSize;
            state.entryValue = newEntryValue;
            state.adjustedEntryFundingIndex = newWeightedFunding;
            state.entryMmrBp = ctx.marginReqs.mmrBp;
            state.mmrUpdateTs = block.timestamp; // (re)stamp grace clock when entry MMR is set

            result.sizeDelta = int256(fillSize);
            if (orderIsLong) {
                result.longOIDelta = int256(fillSize);
                result.longWeightedDelta = int256(fillNotional);
            } else {
                result.shortOIDelta = int256(fillSize);
                result.shortWeightedDelta = int256(fillNotional);
            }
        } else {
            uint256 closingSize = fillSize > state.adjustedSize ? state.adjustedSize : fillSize;
            uint256 closingEntryValue = Math.mulDiv(state.entryValue, closingSize, state.adjustedSize);
            uint256 closingNotional = Math.mulDiv(closingSize, executionPrice, BazaarTypes.BAZAAR_SCALE);

            if (originalIsLong) {
                result.realizedPnl = int256(closingNotional) - int256(closingEntryValue);
                result.longOIDelta = -int256(closingSize);
                result.longWeightedDelta = -int256(closingEntryValue);
            } else {
                result.realizedPnl = int256(closingEntryValue) - int256(closingNotional);
                result.shortOIDelta = -int256(closingSize);
                result.shortWeightedDelta = -int256(closingEntryValue);
            }

            // Cash-settle funding accrued on the closed shares (their proportional slice of the
            // position's fundingPnl). The remainder keeps its entry funding index, so its slice
            // stays unrealized and keeps accruing — every unit of funding settles exactly once,
            // when its shares close. No insurance/ledger movement: like realized price PnL, the
            // temporal float is policed by the equity-gated withdrawal and liquidation paths
            // (unrealized funding is already counted in availableEquity).
            int256 settledFunding =
                BazaarMathLib.signedMulDiv(state.fundingPnl, int256(closingSize), int256(state.adjustedSize));

            // Apply price PnL + funding as ONE signed adjustment: the components may have
            // opposite signs, and _checkMargin gates only their sum, so applying them
            // sequentially could underflow on a combination the gate correctly admitted.
            int256 totalRealized = result.realizedPnl + settledFunding;
            if (totalRealized > 0) {
                unchecked {
                    state.effectiveCollateral += uint256(totalRealized);
                }
            } else if (totalRealized < 0) {
                // Invariant: _checkMargin upstream rejects fills whose realized loss (incl.
                // funding) exceeds collateral. Reaching this branch with insufficient collateral
                // indicates a logic bug; underflow reverts rather than silently absorbing bad debt.
                state.effectiveCollateral = state.effectiveCollateral - uint256(-totalRealized);
            }

            if (fillSize >= state.adjustedSize) {
                uint256 remainingFillSize;
                unchecked {
                    remainingFillSize = fillSize - state.adjustedSize;
                }
                result.sizeDelta = -int256(state.adjustedSize) + int256(remainingFillSize);

                if (remainingFillSize != 0) {
                    uint256 newNotional = Math.mulDiv(remainingFillSize, executionPrice, BazaarTypes.BAZAAR_SCALE);
                    state.adjustedSize = remainingFillSize;
                    state.entryValue = newNotional;
                    newPosIsLong = orderIsLong;
                    state.adjustedEntryFundingIndex = ctx.cachedFundingIdx;
                    state.entryMmrBp = ctx.marginReqs.mmrBp;
                    state.mmrUpdateTs = block.timestamp; // (re)stamp grace clock when entry MMR is set
                    if (orderIsLong) {
                        unchecked {
                            result.longOIDelta += int256(remainingFillSize);
                            result.longWeightedDelta += int256(newNotional);
                        }
                    } else {
                        unchecked {
                            result.shortOIDelta += int256(remainingFillSize);
                            result.shortWeightedDelta += int256(newNotional);
                        }
                    }
                } else {
                    state.adjustedSize = 0;
                    state.entryValue = 0;
                    state.adjustedEntryFundingIndex = 0;
                    state.entryMmrBp = 0;
                    state.mmrUpdateTs = 0; // clear grace clock when fully flat
                }
            } else {
                result.sizeDelta = -int256(fillSize);
                unchecked {
                    state.adjustedSize -= fillSize;
                    state.entryValue -= closingEntryValue;
                }
            }
        }

        result.newSize = state.adjustedSize;
        result.newEntryValue = state.entryValue;
        result.newCollateral = state.effectiveCollateral;
        result.newIsLong = newPosIsLong;
    }

    /// @dev Maker-side settlement of one fill: run the position math, persist the bucket, emit
    ///      its position events, and run the TP/SL fence — all per fill, because each node the
    ///      walk consumes belongs to a different maker.
    function _applyFillMaker(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.OrderBook storage book,
        address user,
        BazaarTypes.BucketState memory state,
        bool orderIsLong,
        uint256 fillSize,
        uint256 executionPrice,
        uint256 fee,
        BazaarTypes.ArrivalContext memory ctx
    ) internal returns (BazaarTypes.FillResult memory result) {
        BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
        uint256 originalSize = state.adjustedSize;
        bool wasLong = bucket.isLong;

        bool newIsLong;
        (result, newIsLong) = _applyFillCore(state, wasLong, orderIsLong, fillSize, executionPrice, fee, ctx);

        if (newIsLong != wasLong) bucket.isLong = newIsLong;
        BucketLib.updateFromState(bucket, state);
        BucketLib.emitBucketUpdate(user, bucket, ctx.cachedFundingIdx, ctx.marginReqs, ctx.pairId);

        // TP/SL fence. `keep` is how much position a close-only order may still reduce: what is
        // left after the fill, or 0 if the fill flipped the side. A mere shrink needs no action —
        // a firing TP/SL caps itself at the live position, so one sized for a bigger position
        // just closes what is there. Only keep == 0 strands them: flat leaves nothing to reduce,
        // and after a flip the order's side would OPEN exposure rather than close it. The
        // originalSize guard skips the fill that opens a position from flat, which can have no
        // TP/SL to strand.
        {
            uint256 keep = (state.adjustedSize > 0 && newIsLong != wasLong) ? 0 : state.adjustedSize;
            if (originalSize != 0 && keep == 0) {
                _cancelTpSlOverSize(user, bucket, keep, orders, book, ctx.pairId, ctx.currentBlock);
            }
        }
    }

    /// @dev Taker-side settlement of one fill: run the position math and fold the result into
    ///      the walk image and aggregates. No storage write and no position events here — the
    ///      taker settles the same account on every fill of the walk, so _flushTaker persists
    ///      and announces the net effect once. The TP/SL fence likewise runs at flush, against
    ///      the final position.
    function _applyFillTaker(
        TakerCtx memory tc,
        BazaarTypes.BucketState memory state,
        bool orderIsLong,
        uint256 fillSize,
        uint256 executionPrice,
        uint256 fee,
        BazaarTypes.ArrivalContext memory ctx
    ) private view returns (BazaarTypes.FillResult memory result) {
        bool newIsLong;
        (result, newIsLong) = _applyFillCore(state, tc.bkt.isLong, orderIsLong, fillSize, executionPrice, fee, ctx);

        tc.bkt.isLong = newIsLong;
        BucketLib.updateMemoryFromState(tc.bkt, state);
        unchecked {
            tc.sizeDeltaAcc += result.sizeDelta;
            tc.realizedPnlAcc += result.realizedPnl;
            tc.feeAcc += fee;
        }
    }

    /// @dev Cancel every TP/SL with more size left than `currentSize`, the largest position a
    ///      close-only order may still reduce. Callers pass 0 to strand all of them, which is the
    ///      only case that arises: a position with room left needs no cancellation, because a
    ///      firing TP/SL caps itself at whatever the position holds.
    ///      Both types wait outside the book, so the unlink is a no-op here; it is kept because
    ///      this is the shared exit for every path that empties a position and must stay correct
    ///      if a close-only type ever rests again.
    function _cancelTpSlOverSize(
        address user,
        BazaarTypes.PositionBucket storage bucket,
        uint256 currentSize,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        bytes32 pairId,
        uint64 currentBlock
    ) internal {
        if (bucket.takeProfitOrderId != 0) {
            BazaarTypes.Order storage tpOrder = orders[bucket.takeProfitOrderId];
            if (
                tpOrder.canceledBlock == 0 && tpOrder.filledBlock == 0
                    && tpOrder.size - tpOrder.filledSize > currentSize
            ) {
                tpOrder.canceledBlock = currentBlock;
                OrderBookLib.unlink(orders, book, bucket.takeProfitOrderId);
                _emitOrderCanceled(pairId, bucket.takeProfitOrderId, user, tpOrder);
            }
            bucket.takeProfitOrderId = 0;
        }
        if (bucket.stopLossOrderId != 0) {
            BazaarTypes.Order storage slOrder = orders[bucket.stopLossOrderId];
            if (
                slOrder.canceledBlock == 0 && slOrder.filledBlock == 0
                    && slOrder.size - slOrder.filledSize > currentSize
            ) {
                slOrder.canceledBlock = currentBlock;
                OrderBookLib.unlink(orders, book, bucket.stopLossOrderId);
                _emitOrderCanceled(pairId, bucket.stopLossOrderId, user, slOrder);
            }
            bucket.stopLossOrderId = 0;
        }
    }

    function _emitOrderCanceled(bytes32 pairId, uint256 orderId, address owner, BazaarTypes.Order storage o) private {
        emit BazaarTypes.OrderUpdated(
            pairId,
            orderId,
            owner,
            BazaarTypes.OrderUpdatePayload({
                action: BazaarTypes.OrderAction.Canceled,
                orderType: o.orderType,
                isLong: o.isLong,
                isPostOnly: o.isPostOnly,
                size: o.size,
                filledSize: o.filledSize,
                triggerPrice: o.triggerPrice,
                limitPrice: o.limitPrice,
                maxSlippageBp: o.maxSlippageBp,
                canceledBlock: o.canceledBlock,
                filledBlock: o.filledBlock,
                expiryBlock: o.expiryBlock,
                creationBlock: o.creationBlock
            })
        );
    }

    // ================================================================
    // WALK SETUP + FINALIZE
    // ================================================================

    /// @dev Resolve a caller-supplied step budget: 0 selects the protocol default, anything else
    ///      is clamped to the ceiling.
    function _resolveCap(uint32 rawMaxSteps) private pure returns (uint256) {
        if (rawMaxSteps == 0) return BazaarTypes.MAX_WALK_STEPS;
        return rawMaxSteps < BazaarTypes.MAX_WALK_STEPS ? rawMaxSteps : BazaarTypes.MAX_WALK_STEPS;
    }

    function _initResult(BazaarTypes.Vault storage pairVault, uint256 cap)
        private
        view
        returns (BazaarTypes.ArrivalResult memory res)
    {
        res.feeBudget = pairVault.totalCollateralDeposited;
        // Each fill can append two distinct integrators (one per side).
        res.integratorAccums = new BazaarTypes.IntegratorAccum[](2 * cap + 2);
    }

    function _summarize(BazaarTypes.ArrivalResult memory res)
        private
        pure
        returns (BazaarTypes.WalkSummary memory sum)
    {
        sum.totalMatchedVolume = res.totalMatchedVolume;
        sum.totalFillSize = res.totalFillSize;
        sum.sumLiqGapTimesSize = res.sumLiqGapTimesSize;
        sum.totalLiqFillSize = res.totalLiqFillSize;
        sum.liqCount = res.liqCount;
    }

    /// @dev Apply a walk's accumulated deltas to storage: OI aggregates, the fee-ledger debit,
    ///      the vault-PnL insurance transfer, the bug-bounty skim, and the integrator fee
    ///      accruals. Runs once per walk (once per batch for executeTriggers) so storage is
    ///      touched a bounded number of times regardless of fill count. No token leaves here:
    ///      every third-party payment accrues in the fee escrow and is pulled via claimFees.
    function _finalizeTx(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        BazaarTypes.ArrivalContext memory ctx,
        BazaarTypes.ArrivalResult memory res
    ) private {
        if (res.fillCount == 0) return;

        _updateVaultAggregates(
            pairVault, res.deltaLongOI, res.deltaShortOI, res.deltaLongWeightedEntry, res.deltaShortWeightedEntry
        );

        // Bounded by the walk's fee budget (seeded from this ledger), so this cannot
        // underflow; checked arithmetic makes a budget regression revert loudly instead of
        // wrapping the ledger to ~2^256 and poisoning every downstream solvency check.
        pairVault.totalCollateralDeposited -= res.totalIntegratorFees + res.totalInsuranceFees;

        // Apply unloaded-inventory vault PnL through insurance
        if (res.totalVaultPnl > 0) {
            // A vault profit is value flowing from the trader pot to insurance: its counterpart
            // is the surviving opposite side's deepening losses, which they will realize into
            // smaller buckets and withdraw LESS from the deposits ledger. Book it as a D → I
            // TRANSFER — a bare insurance credit raises expectedBalance (I + D) above actual
            // USDC with no cash counterpart, permanently, and enough accumulated vault/netting
            // profits would false-trigger the reason-3 shortfall termination. Capped at D
            // defensively; an uncredited excess errs as unclaimable surplus, never as an
            // unbacked claim.
            uint256 gain = uint256(res.totalVaultPnl);
            uint256 take = gain < pairVault.totalCollateralDeposited ? gain : pairVault.totalCollateralDeposited;
            pairVault.totalCollateralDeposited -= take;
            unchecked {
                pairVault.insuranceFundBalance += take;
            }
        } else if (res.totalVaultPnl < 0) {
            // A vault loss is value flowing from insurance to the trader pot: it is the backing
            // for the surviving counterparties' offsetting gains, which they will realize into
            // bucket collateral and withdraw FROM the deposits ledger. Book it as an I → D
            // TRANSFER (mirroring AdlLib._settleInventorySlice), not a bare insurance debit — otherwise
            // the deposits ledger drifts below Σ bucket.collateral and the last withdrawers
            // underflow it despite their claims being fully cash-backed. I + D is invariant
            // under the transfer, so the books-vs-USDC health check's expected balance is
            // unmoved. The uncovered overrun is unbacked bad debt (claims stay intact, backing
            // is gone): recorded as realized deficit so the post-walk isVaultHealthy terminates
            // the pair.
            uint256 loss = uint256(-res.totalVaultPnl);
            uint256 funded = loss < pairVault.insuranceFundBalance ? loss : pairVault.insuranceFundBalance;
            pairVault.insuranceFundBalance -= funded;
            pairVault.totalCollateralDeposited += funded;
            if (loss > funded) {
                pairVault.deficit += loss - funded;
            }
        }

        // Bug bounty tax skims the two fee streams
        uint256 bbFromIntegrator =
            Math.mulDiv(res.totalIntegratorFees, BazaarTypes.BUG_BOUNTY_TAX_BP, BazaarTypes.BP_SCALE);
        uint256 bbFromInsurance =
            Math.mulDiv(res.totalInsuranceFees, BazaarTypes.BUG_BOUNTY_TAX_BP, BazaarTypes.BP_SCALE);
        uint256 totalBugBounty = bbFromIntegrator + bbFromInsurance;

        uint256 netInsuranceFees = res.totalInsuranceFees - bbFromInsurance;
        if (netInsuranceFees > 0) {
            unchecked {
                pairVault.insuranceFundBalance += netInsuranceFees;
            }
        }

        if (totalBugBounty > 0) {
            if (ctx.bugBountyAddress == address(0)) {
                unchecked {
                    pairVault.insuranceFundBalance += totalBugBounty;
                }
            } else {
                FeeEscrowLib.credit(feeEscrow, ctx.pairId, ctx.bugBountyAddress, totalBugBounty);
            }
        }

        _accrueIntegratorFees(
            pairVault, feeEscrow, ctx.pairId, res.integratorAccums, res.integratorCount, BazaarTypes.BUG_BOUNTY_TAX_BP
        );
    }

    // ================================================================
    // SHARED SMALL HELPERS
    // ================================================================

    function _isOracleDerivedPrice(BazaarTypes.OrderType ot) internal pure returns (bool) {
        return ot == BazaarTypes.OrderType.Market || ot == BazaarTypes.OrderType.StopLoss
            || ot == BazaarTypes.OrderType.TakeProfit;
    }

    /// @dev True for the close-only types, which may only ever shrink their owner's position.
    function _isPositionReducing(BazaarTypes.OrderType ot) internal pure returns (bool) {
        return ot == BazaarTypes.OrderType.TakeProfit || ot == BazaarTypes.OrderType.StopLoss;
    }

    /// @dev Bind a firing TP/SL to the position it is closing. `size == 0` means "whatever the
    ///      position holds"; any other size is capped at it. Both are resolved here, at the only
    ///      moment the answer can be right — the position may have grown, shrunk, or vanished
    ///      since creation, and a keeper fires the order much later than its owner wrote it.
    ///
    ///      The resolved amount is written back to storage rather than kept in memory: the
    ///      fill path stamps an order terminal on `filledSize == size`, so a size-0 order left
    ///      at 0 would close the position and still read as live, and the emitted events would
    ///      report a size the order never traded.
    /// @dev True for the types that wait outside the book for an oracle price to reach them.
    function _isTriggerGated(BazaarTypes.OrderType ot) internal pure returns (bool) {
        return ot == BazaarTypes.OrderType.StopLimit || ot == BazaarTypes.OrderType.StopLoss
            || ot == BazaarTypes.OrderType.TakeProfit;
    }

    /// @dev Has this trigger-gated order's condition been met at `oraclePrice`? Stops fire when
    ///      the market moves against the position, take-profits when it moves in favour, so the
    ///      two use mirrored comparisons. Shared by arrival-time arming and executeTriggers so
    ///      both paths agree on when an order is live.
    function _triggerReached(BazaarTypes.OrderType ot, bool isLong, uint256 triggerPrice, uint256 oraclePrice)
        internal
        pure
        returns (bool)
    {
        return ot == BazaarTypes.OrderType.TakeProfit
            ? BazaarMathLib.takeProfitTriggerReached(isLong, triggerPrice, oraclePrice)
            : BazaarMathLib.stopTriggerReached(isLong, triggerPrice, oraclePrice);
    }

    // ================================================================
    // VAULT AGGREGATE UPDATE
    // ================================================================

    function _updateVaultAggregates(
        BazaarTypes.Vault storage pairVault,
        int256 deltaLongOI,
        int256 deltaShortOI,
        int256 deltaLongWeightedEntry,
        int256 deltaShortWeightedEntry
    ) internal {
        if (deltaLongOI >= 0) {
            unchecked {
                pairVault.totalLongOI += uint256(deltaLongOI);
            }
        } else {
            uint256 decrease = uint256(-deltaLongOI);
            pairVault.totalLongOI = pairVault.totalLongOI > decrease ? pairVault.totalLongOI - decrease : 0;
        }
        if (deltaShortOI >= 0) {
            unchecked {
                pairVault.totalShortOI += uint256(deltaShortOI);
            }
        } else {
            uint256 decrease = uint256(-deltaShortOI);
            pairVault.totalShortOI = pairVault.totalShortOI > decrease ? pairVault.totalShortOI - decrease : 0;
        }
        if (deltaLongWeightedEntry >= 0) {
            unchecked {
                pairVault.longWeightedEntrySum += uint256(deltaLongWeightedEntry);
            }
        } else {
            uint256 decrease = uint256(-deltaLongWeightedEntry);
            pairVault.longWeightedEntrySum =
                pairVault.longWeightedEntrySum > decrease ? pairVault.longWeightedEntrySum - decrease : 0;
        }
        if (deltaShortWeightedEntry >= 0) {
            unchecked {
                pairVault.shortWeightedEntrySum += uint256(deltaShortWeightedEntry);
            }
        } else {
            uint256 decrease = uint256(-deltaShortWeightedEntry);
            pairVault.shortWeightedEntrySum =
                pairVault.shortWeightedEntrySum > decrease ? pairVault.shortWeightedEntrySum - decrease : 0;
        }
    }

    // ================================================================
    // FEE DISTRIBUTION HELPERS
    // ================================================================

    function _accumulateIntegratorFee(
        BazaarTypes.IntegratorAccum[] memory accums,
        uint256 count,
        address integrator,
        uint256 feeAmount
    ) internal pure returns (uint256 newCount) {
        if (feeAmount == 0) return count;
        for (uint256 k; k < count;) {
            if (accums[k].integrator == integrator) {
                unchecked {
                    accums[k].amount += feeAmount;
                }
                return count;
            }
            unchecked {
                ++k;
            }
        }
        accums[count].integrator = integrator;
        accums[count].amount = feeAmount;
        unchecked {
            return count + 1;
        }
    }

    /// @dev Credit each integrator's net fee (after the bug-bounty tax) to its claimable
    ///      balance. The dedup buffer never holds address(0) with a non-zero amount (zero-
    ///      integrator fees are zeroed at computation), but a defensive insurance credit keeps
    ///      any such amount inside the books rather than stranding it in the escrow total.
    function _accrueIntegratorFees(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        bytes32 pairId,
        BazaarTypes.IntegratorAccum[] memory accums,
        uint256 count,
        uint256 bugBountyTaxBp
    ) internal {
        uint256 netMultiplier = BazaarTypes.BP_SCALE - bugBountyTaxBp;
        for (uint256 i; i < count;) {
            address integrator = accums[i].integrator;
            uint256 amount = accums[i].amount;
            if (amount > 0) {
                uint256 netAmount = Math.mulDiv(amount, netMultiplier, BazaarTypes.BP_SCALE);
                if (integrator == address(0)) {
                    unchecked {
                        pairVault.insuranceFundBalance += netAmount;
                    }
                } else {
                    FeeEscrowLib.credit(feeEscrow, pairId, integrator, netAmount);
                }
            }
            unchecked {
                ++i;
            }
        }
    }
}
