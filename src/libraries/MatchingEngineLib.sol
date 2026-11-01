// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";
import {BucketLib} from "./BucketLib.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";
import {FundingLib} from "./FundingLib.sol";
import {OrderBookLib} from "./OrderBookLib.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";

/// @title MatchingEngineLib
/// @notice Arrival-matching engine over the on-chain sorted book: an incoming order walks the
///         opposing list from its head while it crosses, fills at each resting maker's limit
///         price, and then either rests its remainder in the book (GTC limits, via insertion
///         hints), cancels it (Market, IOC, post-only violation, self-match, step-cap, dust), or
///         — for a fired trigger order — leaves it live outside the book for its next
///         execution. A fill-or-kill arrival takes none of these: it reverts unless the walk
///         filled it completely. Also executes triggered stops and unloads vault liquidation
///         inventory through the same fill machinery.
///         Runs via DELEGATECALL from BazaarPair — has direct storage access.
///
/// Key invariants:
///  • Fills price at the MAKER's limitPrice: the resting side is always the maker, because only
///    a resting order carries a book position for the arriving side to trade against. (For a
///    just-created order that is also the older-id side; a stop fired later by a keeper takes
///    against makers that may be newer than itself.)
///  • The book never rests crossed: every disposition that could leave a still-crossing
///    remainder (step-cap, far-side band breach, self-match, margin failure) cancels the
///    incoming order, or for a trigger order keeps it outside the book.
///  • The walk re-reads its side's head from storage every iteration and never carries a next
///    pointer across a settlement: a settlement unlinks the maker it just consumed or
///    auto-cancels one that fails its margin gate, so any cached pointer would go stale. No
///    fill can end the TAKER's own order — every account settled mid-walk is a maker's — and
///    the walk re-reads the taker's stamps after each fill to hold that.
///  • Margin checks judge each fill by the account it would leave at the tx's cached price —
///    IMR on exposure it adds; on a reduction, IMR on the remainder or else a margin-to-MMR
///    ratio no lower than before. A failing maker is auto-canceled; a failing taker is disposed
///    of as above.
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
        // Why the order is being auto-canceled, set by the gate that kills it. It rides here rather
        // than as an argument to _autoCancelOrder: the optimizer compiles a separate copy of a
        // function for each distinct literal passed to it, and there is one reason per gate.
        BazaarTypes.CancelReason cancelReason;
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
    ///      meets arms immediately here, with no keeper: the share of its bounty this execution
    ///      earns goes back to the owner's claimable balance, and the rest stays escrowed for
    ///      whoever finishes it. A stop the stale fallback leaves unjudged is stamped with this
    ///      block (Order.restedBlock), so that an execution in the same block pays the owner
    ///      too (executeTriggers); a stop a fresh price left unmet carries no stamp.
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
        bool triggerGated;
        {
            BazaarTypes.Order storage t = orders[takerId];
            BazaarTypes.OrderType ot = t.orderType;
            // Market orders price and bound off the oracle; a stale fallback cannot bound a fill.
            if (ot == BazaarTypes.OrderType.Market && ctx.isOracleStale) {
                revert MatchingEngineLib__BlockedOracleStale();
            }
            triggerGated = _isTriggerGated(ot);
            if (triggerGated) {
                if (ctx.isOracleStale) {
                    // The stale fallback cannot judge the trigger, so the stop waits unarmed
                    // whatever the live price says. The block it was left in is stamped: an
                    // execution in that block pays the bounty to the owner (executeTriggers).
                    t.restedBlock = uint32(ctx.currentBlock);
                    return sum;
                }
                if (!_triggerReached(ot, t.isLong, t.triggerPrice, ctx.cachedPrice)) return sum;
            }
        }
        uint256 cap = _resolveCap(hints.maxSteps);
        BazaarTypes.ArrivalResult memory res = _initResult(pairVault, cap);
        // Only trigger types hold a bounty, so the settle (and its escrow read) is skipped for
        // the rest. The fill count before the walk is read from storage rather than written as
        // the zero a fresh order has: a literal here would make the optimizer compile a second
        // copy of _settleBounty specialised to it.
        uint256 filledBefore;
        if (triggerGated) filledBefore = orders[takerId].filledSize;
        _walkTaker(orders, positionBuckets, userActiveLimitOrders, book, takerId, hints, cap, ctx, res);
        if (triggerGated) {
            _settleBounty(
                orders, feeEscrow, ctx.pairId, takerId, filledBefore, res.takerRemainingAtStart, orders[takerId].creator
            );
        }
        _finalizeTx(pairVault, feeEscrow, ctx, res);
        sum = _summarize(res);
    }

    /// @notice Execute triggered StopLimit/StopLoss/TakeProfit orders against a fresh oracle
    ///         price. Each execution earns the caller the share of the order's escrowed bounty
    ///         that it filled or armed (_settleBounty); nothing is taken from the owner's
    ///         collateral, so a stop on a thin account pays its executor like any other. An
    ///         execution in the block a stale-fallback creation left the order waiting in pays
    ///         that share to the owner instead.
    /// @dev Per order, every disqualifier is a silent skip — racing keepers must not revert each
    ///      other's batches: wrong type, terminal state, already in the book (an armed
    ///      StopLimit), expiry, an unmet trigger, or a StopLimit whose resting slot the keeper's
    ///      hints cannot reach (resolved before the walk, so a skipped stop is left untouched).
    ///      A stop stays live outside the book, eligible again on the next call, when its walk
    ///      died on the node budget, its owner's own order at the head or a fill its margin could
    ///      not carry; when a StopLoss or TakeProfit ran out of crossing liquidity; and when a
    ///      StopLimit with less than MIN_ORDER_LIFETIME_BLOCKS of its life left ends its walk
    ///      with more than dust over. Otherwise a StopLimit's remainder rests in the book or is
    ///      canceled as dust, and a StopLoss or TakeProfit whose position is gone is canceled
    ///      (_disposeRemainder).
    ///
    ///      An execution in the block a creation on the stale fallback left the order in pays
    ///      the owner because no keeper service was needed: a trigger the fresh price already
    ///      meets arms on arrival, with no keeper and the bounty returned (executeArrival), so
    ///      the stale fallback — which judges no trigger — is the one way an order whose trigger
    ///      the live price meets reaches this function unarmed, and whether a creation carries a
    ///      price is the submitter's choice, since priceUpdate sits outside the signed payload.
    ///      Paying the owner for an execution in that block leaves a relayer nothing to gain from
    ///      withholding the update and firing the signed order itself; a keeper that
    ///      independently fires such a stop in that block forgoes a bounty the owner would have
    ///      kept had the creation carried the price. An order whose creation read a fresh price
    ///      carries no stamp (executeArrival), so a keeper completing it in that block — a
    ///      take-profit the arrival could only part-fill, against liquidity that came later in
    ///      the block — is paid as usual. The stamp is read before the walk, since a StopLimit
    ///      remainder that rests re-stamps it with this block.
    ///
    ///      The whole batch shares one accumulator and settles storage once at the end. What
    ///      keeps one owner's outcome from coupling to another's is preserved per exec: each
    ///      walk margin-gates its own fills against its own bucket, and the shared fee budget
    ///      only ever shrinks by charges that settle (a waived or refunded attempt restores
    ///      exactly what it reserved) — the same running-ledger sequence a per-exec settle would
    ///      produce, without rewriting the vault slots per exec.
    /// @param orders The pair's order storage.
    /// @param positionBuckets The pair's position buckets.
    /// @param userActiveLimitOrders Each owner's live Limit/StopLimit ids.
    /// @param pairVault The pair's vault aggregates.
    /// @param feeEscrow The pair's fee and bounty escrow.
    /// @param book The pair's book heads/counts.
    /// @param execs The orders to fire, each with its walk and insertion hints.
    /// @param ctx The transaction's matching context.
    /// @param seqCounter The pair's id counter, the source of an armed StopLimit's queue position.
    /// @return executedCount Number of eligible orders whose walk ran, whether or not it filled.
    /// @return sum Aggregate fill totals across all execs for the pair's post-walk hooks.
    /// @return nextSeq seqCounter advanced past every queue position the batch drew; the pair
    ///         stores it back as the counter.
    function executeTriggers(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.TriggerExec[] calldata execs,
        BazaarTypes.ArrivalContext memory ctx,
        uint256 seqCounter
    ) external returns (uint256 executedCount, BazaarTypes.WalkSummary memory sum, uint256 nextSeq) {
        if (execs.length == 0 || execs.length > BazaarTypes.MAX_TRIGGER_EXECS_PER_CALL) {
            revert MatchingEngineLib__InvalidTriggerBatch(execs.length);
        }
        // Trigger evaluation and StopLoss pricing are oracle-derived; a stale fallback price can
        // neither arm a stop nor bound its fill.
        if (ctx.isOracleStale) revert MatchingEngineLib__BlockedOracleStale();
        uint256 cap = _resolveCap(0);
        // The integrator-dedup buffer must hold every fill of every exec in the batch.
        BazaarTypes.ArrivalResult memory res = _initResult(pairVault, cap * execs.length);
        for (uint256 i; i < execs.length; ++i) {
            uint256 orderId = execs[i].orderId;
            BazaarTypes.Order storage o = orders[orderId];
            BazaarTypes.OrderType ot = o.orderType;
            if (!_isTriggerGated(ot)) continue;
            if (o.creator == address(0) || o.canceledBlock != 0 || o.filledBlock != 0 || o.inBook) continue;
            if (o.expiryBlock < ctx.currentBlock) continue;
            if (!_triggerReached(ot, o.isLong, o.triggerPrice, ctx.cachedPrice)) continue;

            BazaarTypes.MatchHints memory hints = execs[i].hints;
            if (ot == BazaarTypes.OrderType.StopLimit) {
                // A StopLimit is the one trigger type whose remainder rests, and resting it is
                // the one step of an exec that can fail: past MAX_WALK_STEPS from the keeper's
                // hints the book gives up, and a revert there would unwind every other owner's
                // stop in the batch. Resolve the slot now, before the walk fills anything. That
                // is sound because the walk never touches the side the stop rests on — it
                // consumes the opposite side's head, and the TP/SL fence it runs cancels only
                // orders that never rest — so a predecessor found here still brackets the slot
                // when the remainder is placed. Unreachable means the keeper's view of the book
                // is stale: skip like any other disqualifier, leaving the order exactly as it
                // was for a keeper carrying fresh hints. Otherwise hand the found predecessor to
                // the insert as an exact hint, so it links without a second walk.
                //
                // The stop joins its price level only now, so the slot is resolved under a fresh
                // queue position from the id counter, the value an amend that moves an order also
                // draws (BazaarTypes.Order). Under its creation id it would sort ahead of every
                // order at that price created after it, including orders resting there since
                // before it armed. The position is written once the slot is found and before the
                // walk, so the insert that rests the remainder reads the value the slot was
                // resolved under. A stop that does not end up resting — filled whole, canceled as
                // dust, or left fired outside the book for its next execution, which draws again —
                // leaves its drawn value unused, and a gap in the counter is harmless.
                uint48 seq = uint48(seqCounter); // counter values stay far below 2^48 (BazaarTypes.Order)
                (bool found, uint64 pred) = OrderBookLib.locate(orders, book, orderId, seq, hints);
                if (!found) continue;
                o.prioritySeq = seq;
                unchecked {
                    ++seqCounter;
                }
                hints.pred = pred;
                hints.pred2 = 0;
                hints.pred3 = 0;
                hints.pred4 = 0;
            }

            // The keeper's insertion hints are safe to honour (every candidate is verified
            // against the real neighbours before linking), but its step budget is NOT: the
            // budget decides how much of the order executes, and the stop's owner never
            // authorised this caller, so the walk always runs the protocol default here.
            hints.maxSteps = 0;
            // The node cap bounds each stop's own walk; the fee budget and fill aggregates
            // carry across the batch.
            res.nodesVisited = 0;
            uint256 filledBefore = o.filledSize;
            address recipient = o.restedBlock == uint32(ctx.currentBlock) ? o.creator : msg.sender;
            _walkTaker(orders, positionBuckets, userActiveLimitOrders, book, orderId, hints, cap, ctx, res);
            _settleBounty(orders, feeEscrow, ctx.pairId, orderId, filledBefore, res.takerRemainingAtStart, recipient);
            unchecked {
                ++executedCount;
            }
        }
        _finalizeTx(pairVault, feeEscrow, ctx, res);
        sum = _summarize(res);
        nextSeq = seqCounter;
    }

    /// @dev Assign the part of a trigger order's escrowed bounty that one execution earned.
    ///      `recipient` is who earns it: the keeper for executeTriggers, or the owner when no
    ///      keeper service was rendered — an arrival-time execution, or one in the block a
    ///      stale-fallback creation left the order in — so the share goes back to the owner's
    ///      claimable balance. Paid in proportion to the size this execution filled out of what
    ///      remained when it started, so a wall of dust that fills a sliver earns a sliver; the
    ///      whole remainder pays out once the order completes or rests, because nothing is left
    ///      for a later executor to do. An order the walk killed pays the executor for what it
    ///      filled before the kill and returns the rest to the owner, since no executor can
    ///      ever complete it. The proportion is over the remainder as the walk began it — a
    ///      TP/SL's is capped to the position it could close — so the denominator is never
    ///      smaller than the fill.
    function _settleBounty(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.FeeEscrow storage feeEscrow,
        bytes32 pairId,
        uint256 orderId,
        uint256 filledBefore,
        uint256 remainingAtStart,
        address recipient
    ) private {
        uint256 held = feeEscrow.bounty[orderId];
        if (held == 0) return;
        BazaarTypes.Order storage o = orders[orderId];
        uint256 pay;
        if (o.filledBlock != 0 || o.inBook) {
            pay = held;
        } else {
            uint256 filledNow = o.filledSize - filledBefore;
            if (filledNow != 0) pay = Math.mulDiv(held, filledNow, remainingAtStart);
        }
        if (pay != 0) FeeEscrowLib.assignBounty(feeEscrow, pairId, orderId, recipient, pay);
        // A walk that killed the order (a dust remainder, a position that is gone) still pays
        // for what it closed; only the rest goes back to the owner.
        if (o.canceledBlock != 0 && held != pay) {
            FeeEscrowLib.assignBounty(feeEscrow, pairId, orderId, o.creator, held - pay);
        }
    }

    /// @notice Cross the vault's pending liquidation inventory into the book, down to the unload
    ///         bound and within the insurance fund's headroom (RiskParamsLib.planUnload), until
    ///         the inventory, the crossing book, the headroom, or the node budget runs out.
    ///         Shared by liquidate()'s inline unload and unloadVault.
    /// @param prepaid Who is paid and how. BazaarTypes.UNLOAD_BY_KEEPER for unloadVault: the
    ///        caller earns LIQUIDATION_FEE_EBP of the unloaded notional, raised to
    ///        UNLOAD_BOUNTY_MIN once the call unloads UNLOAD_BOUNTY_MIN_NOTIONAL or clears the
    ///        inventory, so dust-sized unloads can't farm the flat floor. Otherwise the credit
    ///        the enclosing liquidate() left (LiquidateResult.unloadPrepaid): what it already paid,
    ///        after the fund's cap, less LIQUIDATION_FEE_EBP of the inventory its nettings retired;
    ///        0 when the call only re-submitted listed accounts. The caller earns whatever
    ///        LIQUIDATION_FEE_EBP of the unloaded notional exceeds it, so the call is paid its
    ///        nettings' rate plus the larger of its remaining flat rewards and the rate on what it
    ///        unloaded. Either way the payment is capped at the fund's free capital and, while the
    ///        inventory left carries a loss at the mark, at what that capital above the reserve
    ///        covers the loss by (RiskParamsLib.unloadRewardPayable), and accrued to the caller's
    ///        claimable balance (pulled via claimFees).
    /// @return sum Fill totals for the pair's post-walk hooks.
    function unloadBook(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        BazaarTypes.OrderBook storage book,
        uint256 maxSteps,
        uint256 prepaid,
        BazaarTypes.ArrivalContext memory ctx
    ) external returns (BazaarTypes.WalkSummary memory sum) {
        // Nothing crosses against the stale fallback. The frozen mark is the last price anyone
        // stored, while off-chain venues can already show where the market will reopen, so a
        // maker who sees the reopen would take the inventory at the frozen mark only when it
        // favours the vault: the fund would exit exactly when holding pays and hold when it loses.
        // The inventory waits for a fresh mark instead. liquidate() still seizes against a
        // fallback no older than MAX_LIQUIDATION_PRICE_AGE, so only its inline walk waits; a stale
        // unloadVault fills nothing and earns nothing. Every gap-EMA sample the walk records is
        // therefore measured against a fresh oracle, never one whose error would read as depth.
        if (pairVault.pendingLiqSize == 0 || ctx.isOracleStale) return sum;
        uint256 cap = maxSteps == 0
            ? BazaarTypes.MAX_WALK_STEPS
            : (maxSteps < BazaarTypes.MAX_WALK_STEPS ? maxSteps : BazaarTypes.MAX_WALK_STEPS);
        BazaarTypes.ArrivalResult memory res = _initResult(pairVault, cap);
        // The vault unwinds its inherited side against the counterparties who take it over:
        // inherited longs sell to resting bids; inherited shorts buy from resting asks.
        BazaarTypes.UnloadPlan memory plan =
            RiskParamsLib.planUnload(pairVault, ctx.cachedPrice, ctx.cachedFundingIdx, ctx.marginReqs, prepaid);

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
                m.cancelReason = BazaarTypes.CancelReason.Expired;
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

        // The caller is paid the bps rate on whatever it actually unloaded. For a keeper's
        // unloadVault the flat floor is reserved for a call that did a whole unit of work — one
        // that moved at least UNLOAD_BOUNTY_MIN_NOTIONAL, or finished the inventory. Granting the
        // floor to every call would let a keeper slice one large unload into minimum-sized pieces
        // and collect it on each, paying itself many times the intended rate out of insurance.
        // Below that bar the rate still pays, because a keeper that drains every in-band maker on
        // a thin book has done all the work available and must not come away with nothing.
        // Slicing gains nothing under this rule: the bps total is identical however the unload
        // is divided, and the floor can be earned at most once per inventory.
        //
        // A liquidation's walk pays only what the rate exceeds the credit its liquidations left,
        // so the flat rewards and the rate on the sale are never both paid.
        uint256 reward = Math.mulDiv(res.totalMatchedVolume, BazaarTypes.LIQUIDATION_FEE_EBP, BazaarTypes.EBP_SCALE);
        if (prepaid == BazaarTypes.UNLOAD_BY_KEEPER) {
            if (res.totalMatchedVolume >= BazaarTypes.UNLOAD_BOUNTY_MIN_NOTIONAL || pairVault.pendingLiqSize == 0) {
                if (reward < BazaarTypes.UNLOAD_BOUNTY_MIN) reward = BazaarTypes.UNLOAD_BOUNTY_MIN;
            }
        } else {
            reward = reward > prepaid ? reward - prepaid : 0;
        }
        // A walk that filled nothing earns nothing: no fills means totalMatchedVolume is 0, and
        // the keeper's floor is unreachable because pendingLiqSize can only reach 0 through a
        // fill. Capped at the fund's free capital: the seizure still earmarked against open
        // inventory is what settles that inventory, and a reward drawn from it would resurface as
        // a shortfall on the next fill, booked as deficit. The reserve may pay it — it is held for
        // exactly the payouts no bound can refuse — the earmark may not. Capped too at what free
        // capital above the reserve covers the remaining inventory's loss at the mark by: where
        // the fills left the pair on the healthy side of the ADL gate, the reward must not carry
        // it over (RiskParamsLib.unloadRewardPayable). The reward moves from insurance into the
        // claimable-fee escrow (pulled later via claimFees), so the unload itself never runs a
        // token transfer.
        reward = RiskParamsLib.unloadRewardPayable(pairVault, ctx.cachedPrice, ctx.cachedFundingIdx, reward);
        if (reward > 0) {
            pairVault.insuranceFundBalance -= reward;
            FeeEscrowLib.credit(feeEscrow, ctx.pairId, msg.sender, reward);
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
        // right: what remains of the order is capped at whatever the position holds, so a
        // caller who wrote type(uint256).max to mean "all of it" closes exactly the position
        // and no more. A position that went flat or flipped to the order's own side leaves
        // nothing to reduce (filling there would OPEN exposure), which zeroes `remaining` and
        // kills the order below. The cap is applied to the remainder, not the whole size: an
        // order that already filled part of the position on an earlier execution has shrunk the
        // position by exactly that part, and capping the size alone would count the earlier
        // fill against the position twice and close too little. The cap lives only in the walk's
        // image of the order, which is what the fill path stamps terminal against
        // (filledSize == size) and what its events report; the stored size keeps the owner's
        // intent, so an order written for "all of it" still covers a position that grows
        // between two executions.
        // Walk status: ALIVE while the taker can keep trading, DEAD when its remainder must be
        // canceled, GONE when a fill already terminated its order (nothing left to dispose).
        uint8 status = ALIVE;
        if (_isPositionReducing(t.order.orderType)) {
            uint256 posSize = (tc.bkt.size != 0 && tc.bkt.isLong != t.order.isLong) ? uint256(tc.bkt.size) : 0;
            if (t.remaining > posSize) {
                // Fits: filledSize is a uint128 and posSize a uint128 bucket size at most as
                // large as the remainder it replaces.
                t.order.size = uint128(t.order.filledSize + posSize);
                t.remaining = posSize;
            }
            if (t.remaining == 0) {
                status = DEAD;
                t.cancelReason = BazaarTypes.CancelReason.PositionClosed;
            }
        }
        res.takerRemainingAtStart = t.remaining;
        // Every caller reaches here with a trigger-gated order only once its trigger is met, so
        // this is the one point that sees every stop and take-profit fire. Reported after the
        // cap above, so a TP/SL's event carries the size it will actually close.
        if (_isTriggerGated(t.order.orderType)) {
            _emitOrderUpdated(ctx.pairId, t, BazaarTypes.OrderAction.Triggered, BazaarTypes.CancelReason.None);
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
                // Still crossing at the cap: the remainder cannot rest, since that would leave
                // a crossed book. _disposeRemainder cancels it, or for a trigger order keeps it
                // fired outside the book for the next execution.
                status = DEAD;
                t.cancelReason = BazaarTypes.CancelReason.StepLimit;
                break;
            }
            if (m.order.expiryBlock < ctx.currentBlock) {
                m.cancelReason = BazaarTypes.CancelReason.Expired;
                _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, m, ctx);
                continue;
            }
            if (ctx.isOracleStale) {
                // Fresh-oracle fills are unbanded: the margin gates price fresh exposure at the
                // live oracle and charge the fill-vs-mark gap up front, and FundingLib clamps
                // every print to ±MAX_MARK_DEVIATION_BP of index before its premium enters the
                // mark's tallies — an off-mark fill is economically real for its two parties and
                // moves the funding mark everyone else pays against no further than a print at
                // the band edge. Under the stale fallback those gates judge against an aged
                // reference, so fills are confined to ±MAX_STALE_DEVIATION_BP of it. The two
                // violation directions get opposite dispositions:
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
                    t.cancelReason = BazaarTypes.CancelReason.PriceBand;
                    break;
                }
                if (tc.isLong ? mPrice < lo : mPrice > hi) {
                    m.cancelReason = BazaarTypes.CancelReason.PriceBand;
                    _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, m, ctx);
                    continue;
                }
            }
            if (t.order.isPostOnly) {
                // Crossing a live maker at all is the violation; cancel before any fill.
                status = DEAD;
                t.cancelReason = BazaarTypes.CancelReason.PostOnly;
                break;
            }
            if (m.order.creator == t.order.creator) {
                // Self-match stops the newer order, and the arriving side is always newer.
                // _disposeRemainder cancels it, or for a trigger order keeps it fired outside
                // the book.
                status = DEAD;
                t.cancelReason = BazaarTypes.CancelReason.SelfMatch;
                break;
            }
            m.remaining = m.order.size - m.order.filledSize;
            uint8 outcome = _fillCrossed(orders, positionBuckets, userActiveLimitOrders, book, m, t, tc, ctx, res);
            if (outcome == TAKER_DEAD) {
                status = DEAD;
                t.cancelReason = BazaarTypes.CancelReason.Margin;
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
    ///      Market orders and IOC limits never rest and cancel whatever they could not fill. A
    ///      fired StopLoss/TakeProfit never rests either, but its remainder stays LIVE outside
    ///      the book: its price bound is derived from the oracle at each firing, so resting it
    ///      at one firing's bound would leave a limit that goes stale as the oracle moves, while
    ///      cancelling it would strip a protective order at the moment the market reached it.
    ///      The next execution re-evaluates the trigger and prices a fresh bound. The same
    ///      holds for any trigger order whose walk died with its position still open (node
    ///      budget, self-match, a fill its margin could not carry): the fills it took stand and
    ///      the rest waits for the next execution, so nothing planted in the book can end a
    ///      stop. So does what a StopLimit fired with less than MIN_ORDER_LIFETIME_BLOCKS of its
    ///      life left could not fill, since it may not rest. Everything else that dies at the cap
    ///      is canceled: resting it would leave a crossed book. A sub-minimum remainder rests
    ///      only under the live full-close exemption (mirroring creation), so partial fills
    ///      cannot mint resting dust.
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
            // A trigger order dies to its walk only when its position is gone. Running out of
            // budget, meeting its owner's own resting order at the head, or a fill that its
            // owner's margin cannot carry at the head's price all leave it fired outside the
            // book for the next execution: none is a defect of the order, and each is a state
            // the book can be steered into — a wall in front of the liquidity, a book cleared
            // down to the owner's own bid, a maker planted at the worst admissible price — so
            // cancelling on any of them would let a third party strip a protective stop, and
            // the self-match case would let an owner void a keeper's fills by resting a bid
            // behind the liquidity. The owner's own order is theirs to cancel when they want
            // the stop to proceed past it. Post-only and the stale band cannot reach a trigger
            // order: creation refuses the flag and the stale fallback never fires one.
            if (_isTriggerGated(t.order.orderType) && t.cancelReason != BazaarTypes.CancelReason.PositionClosed) {
                return;
            }
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, t, ctx);
            return;
        }
        if (t.remaining == 0) return; // fully filled; _persistFill stamped it terminal

        if (_isPositionReducing(t.order.orderType)) return; // stays fired, outside the book
        if (t.order.orderType == BazaarTypes.OrderType.Market || t.order.tif == BazaarTypes.TimeInForce.IOC) {
            t.cancelReason = BazaarTypes.CancelReason.Unfilled;
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, t, ctx);
            return;
        }
        uint256 remNotional = Math.mulDiv(t.remaining, t.order.limitPrice, BazaarTypes.BAZAAR_SCALE);
        // A sub-minimum remainder rests only when it is a live full close. The full-close test
        // reads the walk image, not storage: mid-walk fills have not been flushed yet.
        bool restable = remNotional >= BazaarTypes.MIN_ORDER_AMOUNT
            || (tc.bkt.size > 0 && tc.bkt.isLong != tc.isLong && t.remaining == tc.bkt.size);
        if (!restable) {
            t.cancelReason = BazaarTypes.CancelReason.BelowMinimum;
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, t, ctx);
            return;
        }
        // A remainder rests only with MIN_ORDER_LIFETIME_BLOCKS of its life left, the floor every
        // link into the book is held to: a quote at the head then stands open to fills for that
        // long before it can expire into a dead node a later walk spends a step removing.
        // Creation always leaves that much, so only a StopLimit fired after its creation block
        // can be short of it. Its remainder then stays fired outside the book, as when its walk
        // runs out of budget, and a later execution can fill it until it expires. Cancelling it
        // would let whoever picks the moment to fire it strip the stop of its last minute by
        // firing when nothing crosses.
        if (t.order.expiryBlock < ctx.currentBlock + BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS) return;
        // The far-side premium is stamped only against a fresh index: a remainder measured
        // against the stale fallback's older price was not on offer at the distance it reads.
        OrderBookLib.insert(orders, book, t.orderId, hints, ctx.currentBlock, ctx.isOracleStale ? 0 : ctx.cachedPrice);
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

        {
            uint256 keep = (tc.bkt.size > 0 && tc.bkt.isLong != tc.posWasLong) ? 0 : uint256(tc.bkt.size);
            if (tc.sizeAtStart != 0 && keep == 0) {
                _cancelTpSlOverSize(bucket, keep, orders, book, ctx.pairId, ctx.currentBlock);
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
                mkH.cancelReason = BazaarTypes.CancelReason.Margin;
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
        _accrueMarkPrint(res, p.makerIsLong ? longH : shortH, p.fillSize, fillNotional, ctx);
        _accumulateFillIntegratorFees(res, longH, shortH, p.fees);
        _emitFillEvents(ctx, longH, shortH, p, longResult, shortResult);
    }

    /// @dev Fold one fill into the mark-price accumulators. Only a fill against a maker resting on
    ///      the far side of the oracle counts — a bid above it or an ask below it. It counts in
    ///      proportion to how long the maker had stood in the book at its current price and size
    ///      (FundingLib.makerExposureWeight), and at no more premium than the maker stood at when
    ///      it linked (Order.restedPremiumPpm, FundingLib.printPriceOf). A quote on the far side
    ///      is a standing offer anyone could have taken at a profit, so a print against one that
    ///      stood untaken says where the market clears, and the longer it stood the more it says
    ///      — but only for the premium it was on offer at. A quote that linked nearer the index
    ///      than it now sits reaches its current premium only because the index moved after it
    ///      linked, and its owner can take it in the transaction that stores the move, before
    ///      anyone else could; it counts at its stamp, and one stamped zero (linked on the near
    ///      side, or against the stale fallback) not at all. A quote on the near side can rest at no risk,
    ///      and a print against it shows nothing a fill's own two parties could not arrange
    ///      between themselves at any admissible price; the same holds for a far-side quote taken
    ///      in the block it was placed, which was never on offer to anyone else. Such prints leave
    ///      the mark to decay toward the index, and add nothing to the rolling volume the counting
    ///      prints are weighed against, so they cannot dilute them either. The unweighted totals
    ///      stay in totalMatchedVolume/totalFillSize for the unload reward and the post-walk
    ///      health check.
    ///      The accumulators hold notional × weight and size × weight, the notional at the print
    ///      price; _summarize divides both by MAKER_EXPOSURE_BLOCKS once per walk. Unchecked
    ///      because nothing here can overflow: a counted notional is a uint128 size times, over
    ///      1e18, the uint128 limit or (for an ask) a price below the oracle price, so under 2^196
    ///      for any oracle price under 2^128; the weight is at most MAKER_EXPOSURE_BLOCKS, and a
    ///      batch settles far fewer than 2^20 fills.
    function _accrueMarkPrint(
        BazaarTypes.ArrivalResult memory res,
        Head memory makerH,
        uint256 fillSize,
        uint256 fillNotional,
        BazaarTypes.ArrivalContext memory ctx
    ) private pure {
        uint256 price = makerH.order.limitPrice;
        bool isLong = makerH.order.isLong;
        if (isLong ? price <= ctx.cachedPrice : price >= ctx.cachedPrice) return;
        uint256 restedPremium = makerH.order.restedPremiumPpm;
        if (restedPremium == 0) return;
        uint256 weight = FundingLib.makerExposureWeight(ctx.currentBlock, makerH.order.restedBlock);
        uint256 printPrice = FundingLib.printPriceOf(isLong, price, restedPremium, ctx.cachedPrice);
        uint256 notional =
            printPrice == price ? fillNotional : Math.mulDiv(fillSize, printPrice, BazaarTypes.BAZAAR_SCALE);
        unchecked {
            res.markNotional += notional * weight;
            res.markSize += fillSize * weight;
        }
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

    /// @dev Per-fill events: the fill's Trade record, plus the MAKER's PositionModified — the
    ///      maker is a different account at every node, so its position settles per fill. The
    ///      taker's PositionModified is emitted once per walk by _flushTaker, with the walk's
    ///      VWAP and net deltas.
    function _emitFillEvents(
        BazaarTypes.ArrivalContext memory ctx,
        Head memory longH,
        Head memory shortH,
        FillParams memory p,
        BazaarTypes.FillResult memory longResult,
        BazaarTypes.FillResult memory shortResult
    ) private {
        Head memory mkH = p.makerIsLong ? longH : shortH;
        Head memory tkH = p.makerIsLong ? shortH : longH;
        emit BazaarTypes.Trade(
            ctx.pairId,
            mkH.order.creator,
            tkH.order.creator,
            mkH.orderId,
            tkH.orderId,
            !p.makerIsLong,
            p.fillSize,
            p.fillPrice,
            p.makerIsLong ? p.fees.longTotalFee : p.fees.shortTotalFee,
            p.makerIsLong ? p.fees.shortTotalFee : p.fees.longTotalFee,
            mkH.remaining,
            tkH.remaining
        );
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
            makerH.cancelReason = BazaarTypes.CancelReason.Margin;
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

        int256 vaultPnl = _settleVaultLiquidation(pairVault, res, ctx, data.fillSize, data.execPrice, data.fillNotional);

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
        _accrueMarkPrint(res, makerH, data.fillSize, data.fillNotional, ctx);

        res.integratorCount = _accumulateIntegratorFee(
            res.integratorAccums, res.integratorCount, makerH.order.integrator, data.makerIntFee
        );

        // The vault is the taker: it has no order and pays no fee.
        emit BazaarTypes.Trade(
            ctx.pairId,
            makerH.order.creator,
            address(this),
            makerH.orderId,
            0,
            !makerH.order.isLong,
            data.fillSize,
            data.execPrice,
            data.makerTotalFee,
            0,
            makerH.remaining,
            0
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

    /// @dev Settle one vault-liquidation fill: compute vault PnL (price + funding accrued on the
    ///      inventory from the liquidatees' entries through this close), update gap-EMA
    ///      accumulators, and decrement the pending-liq aggregates proportionally.
    function _settleVaultLiquidation(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.ArrivalResult memory res,
        BazaarTypes.ArrivalContext memory ctx,
        uint256 fillSize,
        uint256 execPrice,
        uint256 fillNotional
    ) private returns (int256 vaultPnl) {
        int256 currentFundingIndex = ctx.cachedFundingIdx;
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

            // Gap-EMA accumulators, split at the oracle. SLIPPAGE is the fill against the oracle:
            // the execution cost of closing the inventory, which is what maintenance margin has
            // to pay for. DRIFT is the oracle against the estates' average bankruptcy price: how
            // far the market ran past the level margin was set to survive while the vault held
            // the position, which is what the fund has to cover. Measuring both against the
            // bankruptcy price alone would fuse them into one number that reads as neither —
            // blind to a thin book whenever slippage stays inside MMR, and unbounded above it
            // because a short bought back in a squeeze can print arbitrarily far past bankruptcy.
            // Both legs read a fresh oracle: unloadBook never walks against the stale fallback.
            uint256 oracle = ctx.cachedPrice;
            if (oracle != 0) {
                bool vaultIsLong = pairVault.pendingLiqIsLong;
                int256 slipBp = vaultIsLong
                    ? (int256(oracle) - int256(execPrice)) * int256(BazaarTypes.BP_SCALE) / int256(oracle)
                    : (int256(execPrice) - int256(oracle)) * int256(BazaarTypes.BP_SCALE) / int256(oracle);

                uint256 avgBP =
                    Math.mulDiv(pairVault.pendingLiqBankruptcyNotional, BazaarTypes.BAZAAR_SCALE, existingSize);
                int256 driftBp;
                if (avgBP != 0) {
                    driftBp = vaultIsLong
                        ? (int256(avgBP) - int256(oracle)) * int256(BazaarTypes.BP_SCALE) / int256(avgBP)
                        : (int256(oracle) - int256(avgBP)) * int256(BazaarTypes.BP_SCALE) / int256(avgBP);
                }

                // Each fill is recorded at what it cost the fund, floored at zero. A reading on
                // the fund's side — a fill better than the oracle, or an oracle that has not yet
                // reached the estates' bankruptcy price — is value the unload has already paid
                // into the fund; letting it pull an EMA negative would count it twice, once in the
                // fund's balance and again by damping the response to the next genuine cost. The
                // fill still enters the weight at full size, as a zero-cost sample, so clean
                // liquidations dilute a later bad one instead of cancelling it with banked
                // credit. On slippage the floor also drops the windfall of stale makers left on
                // the fund's side of a moving oracle: a fast market fills them first, and netting
                // them against the fills behind them in the same walk would hide the thin book
                // beyond.
                //
                // Slippage is also capped at LIQ_MAX_SLIPPAGE_BP. The unload bound keeps every
                // fill inside that band of the oracle unless the fund-neutral price is looser,
                // which takes the market having moved more than the band past it in the fund's
                // favor — and there the walk takes any maker that still beats it. A reading
                // beyond the band measures that latitude, not the cost of a forced exit. Drift is
                // not capped: a large reading there is a genuine overrun.
                if (slipBp > 0) {
                    if (slipBp > int256(BazaarTypes.LIQ_MAX_SLIPPAGE_BP)) {
                        slipBp = int256(BazaarTypes.LIQ_MAX_SLIPPAGE_BP);
                    }
                    res.sumLiqSlipTimesSize += slipBp * int256(fillSize);
                }
                if (driftBp > 0) res.sumLiqDriftTimesSize += driftBp * int256(fillSize);
                res.totalLiqFillSize += fillSize;
            }

            // Decrement vault aggregate proportionally (entryPortion shared with the PnL above)
            uint256 bkPortion = Math.mulDiv(pairVault.pendingLiqBankruptcyNotional, fillSize, existingSize);
            uint256 seizedPortion = Math.mulDiv(pairVault.pendingLiqSeized, fillSize, existingSize);
            pairVault.pendingLiqSize = existingSize - fillSize;
            pairVault.pendingLiqEntryNotional -= entryPortion;
            pairVault.pendingLiqBankruptcyNotional -= bkPortion;
            pairVault.pendingLiqSeized -= seizedPortion;
            res.vaultEarmarkReleased += seizedPortion;
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
    ///      margin failure, step-cap, stale-band, dust, IOC/market remainders, and a TP/SL whose
    ///      position is gone. Sets canceledBlock, unlinks from the book, clears the appropriate
    ///      slot pointer, emits OrderUpdated with h.cancelReason. Does not touch the escrow: a
    ///      canceled trigger order's bounty is refunded by the settle that follows a walk, or
    ///      lazily through cancelOrders / sweepExpired.
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

        h.order.canceledBlock = ctx.currentBlock;
        _emitOrderUpdated(ctx.pairId, h, BazaarTypes.OrderAction.Canceled, h.cancelReason);
    }

    /// @dev Emit OrderUpdated from the walk's memory image of an order rather than re-reading
    ///      storage. The image is current: a maker's is loaded fresh each iteration, and the
    ///      taker's receives every fill and the TP/SL size cap as they are written to storage.
    function _emitOrderUpdated(
        bytes32 pairId,
        Head memory h,
        BazaarTypes.OrderAction action,
        BazaarTypes.CancelReason reason
    ) private {
        BazaarTypes.Order memory o = h.order;
        emit BazaarTypes.OrderUpdated(
            pairId,
            h.orderId,
            o.creator,
            BazaarTypes.OrderUpdatePayload({
                action: action,
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
                prioritySeq: o.prioritySeq,
                tif: o.tif,
                integrator: o.integrator,
                cancelReason: reason
            })
        );
    }

    // ================================================================
    // MARGIN + APPLY FILL
    // ================================================================

    /// @notice Margin gate for a candidate fill. Classifies the trade by SIZE (open / add / close /
    ///         flip) and judges the account as the fill would leave it at the mark: collateral after
    ///         the fee and the PnL and funding the fill realizes, less the unrealized loss of the
    ///         position that survives the fill and the incipient loss of fresh exposure. Unrealized
    ///         gains are never credited. Returns false (caller auto-cancels) on any of:
    ///           - the fee exceeds collateral
    ///           - open/add/flip: that margin falls short of IMR on the resulting notional
    ///           - close/flip: that margin is negative (the fill would leave bad debt)
    ///           - partial close: that margin is below IMR on the remainder, and its ratio to the
    ///             remainder's MMR is lower than the account's was before the fill
    /// @dev The caller passes the batch's resolved margin requirements — there is no stale branch
    ///      inside. The whole struct is threaded rather than a rate because a partial close reads
    ///      both rates: the current IMR for the outright pass, and the lagged MMR to resolve the
    ///      remainder's effective rate (BucketLib.effectiveMmrBp) for the ratio.
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

        // The held position's unrealized loss (price and funding together, at the mark) is owed
        // whether or not this fill touches it. Margin that left it out would treat an account
        // underwater by more than its collateral as still holding that collateral: it could add
        // exposure against money its losses already consume, and a partial fill at an off-market
        // price against a colluding counterparty could move value out of an account whose equity
        // cannot back it, leaving the difference as bad debt. Gains are not credited: paper profit
        // is only as good as the mark and evaporates in the move it would need to buffer, the same
        // reason the incipient debit below is one-sided.
        uint256 heldLoss = state.totalPnl < 0 ? uint256(-state.totalPnl) : 0;

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
            // Same-side add: the held position survives whole, so all of its loss comes off.
            if (heldLoss > collateralAfterFee) return false;
            collateralAfterFee -= heldLoss;
            newExposureSize = fillSize;
            newTotalNotional = state.currentNotional + Math.mulDiv(fillSize, cachedPrice, BazaarTypes.BAZAAR_SCALE);
            effectiveBp = marginReqs.imrBp;
        } else if (fillSize <= bucket.size) {
            // Partial / full close: the closed share realizes at the execution price, and the
            // remainder keeps its share of the held loss.
            uint256 closedEntryValue = Math.mulDiv(state.entryValue, fillSize, bucket.size);
            uint256 closedNotional = Math.mulDiv(fillSize, executionPrice, BazaarTypes.BAZAAR_SCALE);
            int256 realizedPnl = bucket.isLong
                ? int256(closedNotional) - int256(closedEntryValue)
                : int256(closedEntryValue) - int256(closedNotional);
            // Funding settles on the closed shares (mirrors _applyFillCore) — gate on the
            // combined sum so the gate and settlement agree.
            int256 closedFunding =
                BazaarMathLib.signedMulDiv(state.fundingPnl, int256(fillSize), int256(uint256(bucket.size)));
            uint256 remaining = bucket.size - fillSize;

            // Nonnegative margin also means the realized loss fits the collateral, which the
            // settlement in _applyFillCore relies on: the remainder's share of the held loss only
            // lowers the figure.
            int256 marginAfter = int256(collateralAfterFee) + realizedPnl + closedFunding
                - int256(Math.mulDiv(heldLoss, remaining, bucket.size));
            if (marginAfter < 0) return false; // bad debt — must liquidate instead

            // A remainder that still meets IMR at the pair's current rate passes outright. IMR is
            // the level the withdrawal gates hold an open position to, so margin above it is the
            // account's to release, by withdrawal or through the price of a reduction. With no
            // remainder, as on a full close, any nonnegative margin clears it.
            uint256 remainingNotional = Math.mulDiv(remaining, cachedPrice, BazaarTypes.BAZAAR_SCALE);
            if (marginAfter >= int256(Math.mulDiv(marginReqs.imrBp, remainingNotional, BazaarTypes.BP_SCALE))) {
                return true;
            }

            // Below IMR the fill must keep at least the margin-to-MMR ratio the account held before,
            // whether the remainder ends above maintenance or under it. Closing at the mark qualifies
            // (fee aside), as does a close through a thin book whose price gap per unit stays within
            // the account's own margin per unit.
            // - Above maintenance: were any fill that leaves MMR covered admitted, a reduction sold
            //   at a deep discount to the owner's own second account could carry the band between
            //   IMR and MMR out of a position that stays open. That is margin the withdrawal gates
            //   would have kept, and the remainder would survive one stress move instead of two,
            //   leaving the loss beyond it to the insurance fund.
            // - Under maintenance: liquidation seizes the account and leaves the fund to unload the
            //   remainder, so the fund's exposure is the remainder's unload cost less the margin
            //   behind it. Holding the ratio leaves no less margin per unit of remainder, so that
            //   exposure can only shrink, whatever the unload costs. Requiring full MMR instead
            //   would strand the account at its first partial fill, so a close walking several
            //   makers could never start; requiring only that the shortfall not grow would let it
            //   spend up to the whole MMR rate on execution against a colluding counterparty.
            // The remainder's MMR is the pair's 24h-lagged effective rate, as liquidation reads it.
            uint256 mmrBp = BucketLib.effectiveMmrBp(marginReqs);
            int256 requiredAfter = int256(Math.mulDiv(mmrBp, remainingNotional, BazaarTypes.BP_SCALE));
            int256 marginBefore = int256(state.effectiveCollateral) - int256(heldLoss);
            int256 requiredBefore = int256(Math.mulDiv(mmrBp, state.currentNotional, BazaarTypes.BP_SCALE));
            return marginAfter * requiredBefore >= marginBefore * requiredAfter;
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
                _cancelTpSlOverSize(bucket, keep, orders, book, ctx.pairId, ctx.currentBlock);
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
                OrderBookLib.emitOrderUpdated(
                    pairId,
                    bucket.takeProfitOrderId,
                    tpOrder,
                    BazaarTypes.OrderAction.Canceled,
                    BazaarTypes.CancelReason.PositionClosed
                );
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
                OrderBookLib.emitOrderUpdated(
                    pairId,
                    bucket.stopLossOrderId,
                    slOrder,
                    BazaarTypes.OrderAction.Canceled,
                    BazaarTypes.CancelReason.PositionClosed
                );
            }
            bucket.stopLossOrderId = 0;
        }
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
        sum.totalFillSize = res.totalFillSize;
        // The weighted sums were accumulated as notional × weight and size × weight
        // (_accrueMarkPrint); one division per walk puts them on the fill scale.
        sum.markNotional = res.markNotional / FundingLib.MAKER_EXPOSURE_BLOCKS;
        sum.markSize = res.markSize / FundingLib.MAKER_EXPOSURE_BLOCKS;
        sum.sumLiqSlipTimesSize = res.sumLiqSlipTimesSize;
        sum.sumLiqDriftTimesSize = res.sumLiqDriftTimesSize;
        sum.totalLiqFillSize = res.totalLiqFillSize;
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
            // profits would false-trigger the reason-3 shortfall termination. What the ledger
            // cannot pay is carried as its arrears to the fund.
            RiskParamsLib.collectFromLedger(pairVault, uint256(res.totalVaultPnl));
        } else if (res.totalVaultPnl < 0) {
            // A vault loss is value flowing from insurance to the trader pot: it is the backing
            // for the surviving counterparties' offsetting gains, which they will realize into
            // bucket collateral and withdraw FROM the deposits ledger. Book it as an I → D
            // TRANSFER (mirroring AdlLib._settleInventorySlice), not a bare insurance debit — otherwise
            // the deposits ledger drifts below Σ bucket.collateral and the last withdrawers
            // underflow it despite their claims being fully cash-backed. I + D is invariant
            // under the transfer, so the books-vs-USDC health check's expected balance is
            // unmoved. Paid out of the earmark the walk released first, then net of the ledger's
            // arrears (RiskParamsLib.fundLedgerFrom), so the fund's outlay is the loss beyond the
            // estates' collateral, and the inventory left keeps its share of the arrears on every
            // fill taken at or beyond the neutral price. The uncovered overrun is unbacked bad
            // debt (claims stay intact, backing is gone): recorded as realized deficit so the
            // post-walk isVaultHealthy terminates the pair.
            uint256 uncovered = RiskParamsLib.fundLedgerFrom(
                pairVault, uint256(-res.totalVaultPnl), res.vaultEarmarkReleased, pairVault.insuranceFundBalance
            );
            if (uncovered > 0) {
                pairVault.deficit += uncovered;
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
