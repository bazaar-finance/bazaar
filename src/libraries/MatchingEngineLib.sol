// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";
import {BucketLib} from "./BucketLib.sol";
import {OrderBookLib} from "./OrderBookLib.sol";

/// @title MatchingEngineLib
/// @notice Arrival-matching engine over the on-chain sorted book: an incoming order walks the
///         opposing list from its head while it crosses, fills at each resting maker's limit
///         price, and then either rests its remainder in the book (GTC limits, via insertion
///         hints) or cancels it (Market/StopLoss execution, IOC, post-only violation,
///         self-match, step-cap, dust). Also executes triggered stops and unloads vault
///         liquidation inventory through the same fill machinery.
///         Runs via DELEGATECALL from BazaarPair — has direct storage access.
///
/// Key invariants:
///  • Fills price at the MAKER's limitPrice: the resting side is always the maker, because only
///    a resting order carries a book position for the arriving side to trade against. (For a
///    just-created order that is also the older-id side; a stop fired later by a keeper takes
///    against makers that may be newer than itself.)
///  • The book never rests crossed: every disposition that could leave a still-crossing
///    remainder (step-cap, stale band, self-match, margin failure) cancels the incoming order.
///  • The walk re-reads its side's head from storage every iteration and never carries a next
///    pointer across a settlement: a fill can cancel-and-unlink resting TP/SL orders anywhere
///    in the book through the oversize fence, so any cached pointer would go stale mid-walk.
///  • Margin checks always use normal IMR against the tx's cached price. Failure → auto-cancel.
///    During the stale fallback, a maker priced outside MAX_STALE_DEVIATION_BP of the cached
///    price cancels the INCOMING order's remainder; the resting maker stays.
library MatchingEngineLib {
    using EnumerableSet for EnumerableSet.UintSet;

    // -------------------- Errors --------------------
    // Do not trim these error args (or PositionModified's duplicate fields) to save code size:
    // under via_ir it shifts inlining decisions and makes the library BIGGER, not smaller.
    // Re-measure with `forge build --sizes` before any such change.
    error MatchingEngineLib__InvalidTriggerBatch(uint256 count);
    error MatchingEngineLib__BlockedOracleStale(); // oracle-priced execution needs a fresh price

    // -------------------- Memory state --------------------

    /// @dev Memory-cached node: one maker (rebuilt from storage every walk iteration) or the
    ///      taker (built once — its immutable fields cannot change mid-walk, and filledSize is
    ///      only advanced by this walk itself).
    struct Head {
        uint256 orderId;
        uint256 remaining;
        BazaarTypes.Order order;
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

    // ================================================================
    // EXTERNAL ENTRY POINTS
    // ================================================================

    /// @notice Match a just-created order against the book and dispose of its remainder.
    /// @dev Untriggered stops (StopLimit/StopLoss whose trigger the fresh price does not meet,
    ///      or any stop created under the stale fallback) do not walk: they rest outside the
    ///      book until executeTriggers fires them. A stop whose trigger a fresh price already
    ///      meets arms immediately here, with no keeper and no tip.
    /// @return sum Compact fill totals for the pair's post-walk hooks.
    function executeArrival(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
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
            if (ot == BazaarTypes.OrderType.StopLimit || ot == BazaarTypes.OrderType.StopLoss) {
                if (
                    ctx.isOracleStale
                        || !BazaarMathLib.stopTriggerReached(t.isLong, t.triggerPrice, ctx.cachedPrice)
                ) {
                    return sum;
                }
            }
        }
        uint256 cap = _resolveCap(hints.maxSteps);
        BazaarTypes.ArrivalResult memory res = _initResult(pairVault, cap);
        _walkTaker(orders, positionBuckets, userActiveLimitOrders, book, takerId, hints, cap, ctx, res);
        _finalizeTx(pairVault, ctx, res);
        sum = _summarize(res);
    }

    /// @notice Execute triggered StopLimit/StopLoss orders against a fresh oracle price.
    /// @dev Per order, every disqualifier is a silent skip — racing keepers must not revert each
    ///      other's batches: wrong type, terminal state, already in the book (an armed
    ///      StopLimit), expiry, or an unmet trigger. The keeper tip is charged from the owner's
    ///      bucket collateral before the walk (so the fill margin checks see post-tip
    ///      collateral); an owner who cannot cover it has the stop auto-canceled instead,
    ///      mirroring the fee-coverage rule in _checkMargin. A failed tip transfer restores the
    ///      tip to the owner and the execution stands. Each exec settles its own fees/ledger so
    ///      one owner's outcome never couples to another's.
    /// @return executedCount Number of stops that actually fired (fills or armed insertions).
    /// @return sum Aggregate fill totals across all execs for the pair's post-walk hooks.
    function executeTriggers(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
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
        for (uint256 i; i < execs.length; ++i) {
            uint256 orderId = execs[i].orderId;
            BazaarTypes.Order storage o = orders[orderId];
            BazaarTypes.OrderType ot = o.orderType;
            if (ot != BazaarTypes.OrderType.StopLimit && ot != BazaarTypes.OrderType.StopLoss) continue;
            if (o.creator == address(0) || o.canceledBlock != 0 || o.filledBlock != 0 || o.inBook) continue;
            if (o.expiryBlock < ctx.currentBlock) continue;
            if (!BazaarMathLib.stopTriggerReached(o.isLong, o.triggerPrice, ctx.cachedPrice)) continue;

            {
                BazaarTypes.PositionBucket storage bucket = positionBuckets[o.creator];
                // The tip debits the deposits ledger too, and D can legitimately sit below an
                // individual bucket's collateral (realized-but-unwithdrawn PnL). Skip rather
                // than underflow: reverting here would take every other owner's stop in the
                // batch down with it, exactly when the vault is most distressed.
                if (pairVault.totalCollateralDeposited < BazaarTypes.TRIGGER_TIP) continue;
                if (bucket.collateral < BazaarTypes.TRIGGER_TIP) {
                    Head memory dead;
                    dead.orderId = orderId;
                    dead.order = o;
                    _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, dead, ctx);
                    continue;
                }
                bucket.collateral -= BazaarTypes.TRIGGER_TIP;
                pairVault.totalCollateralDeposited -= BazaarTypes.TRIGGER_TIP;
                if (!_sendUsdcFromContract(ctx.usdc, msg.sender, BazaarTypes.TRIGGER_TIP)) {
                    bucket.collateral += BazaarTypes.TRIGGER_TIP;
                    pairVault.totalCollateralDeposited += BazaarTypes.TRIGGER_TIP;
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
            uint256 cap = _resolveCap(hints.maxSteps);
            BazaarTypes.ArrivalResult memory res = _initResult(pairVault, cap);
            _walkTaker(orders, positionBuckets, userActiveLimitOrders, book, orderId, hints, cap, ctx, res);
            _finalizeTx(pairVault, ctx, res);
            unchecked {
                sum.totalMatchedVolume += res.totalMatchedVolume;
                sum.totalFillSize += res.totalFillSize;
                ++executedCount;
            }
        }
    }

    /// @notice Cross the vault's pending liquidation inventory into the book, inside the
    ///         liquidation price band, until the inventory, the crossing book, or the node
    ///         budget runs out. Shared by liquidate()'s inline unload and unloadVault.
    /// @param payReward When true (the permissionless unloadVault path), the caller earns
    ///        max(UNLOAD_BOUNTY_MIN, LIQUIDATION_FEE_EBP of unloaded notional) from insurance —
    ///        gated by UNLOAD_BOUNTY_MIN_NOTIONAL so dust-sized unloads can't farm the flat
    ///        floor, paid all-or-nothing on insurance coverage, and soft-fail restored so a
    ///        failed transfer never reverts the unload. liquidate()'s inline unload passes
    ///        false: the liquidator is already paid per position.
    /// @return sum Fill totals for the pair's post-walk hooks.
    function unloadBook(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
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
        bool vaultIsLong = pairVault.pendingLiqIsLong;

        while (pairVault.pendingLiqSize > 0) {
            uint64 headId = vaultIsLong ? book.bidHead : book.askHead;
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
            // Sorted list: the first maker outside the band means everything deeper is too.
            if (!_passAOk(m.order.limitPrice, ctx.cachedPrice, ctx.marginReqs.mmrBp, vaultIsLong)) break;
            m.remaining = m.order.size - m.order.filledSize;
            _fillVault(orders, positionBuckets, userActiveLimitOrders, pairVault, book, m, ctx, res);
        }

        _finalizeTx(pairVault, ctx, res);

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
            uint256 reward =
                Math.mulDiv(res.totalMatchedVolume, BazaarTypes.LIQUIDATION_FEE_EBP, BazaarTypes.EBP_SCALE);
            if (
                res.totalMatchedVolume >= BazaarTypes.UNLOAD_BOUNTY_MIN_NOTIONAL
                    || pairVault.pendingLiqSize == 0
            ) {
                if (reward < BazaarTypes.UNLOAD_BOUNTY_MIN) reward = BazaarTypes.UNLOAD_BOUNTY_MIN;
            }
            // A walk that filled nothing earns nothing: no fills means totalMatchedVolume is 0,
            // and the floor is unreachable because pendingLiqSize can only reach 0 through a fill.
            if (reward > 0 && pairVault.insuranceFundBalance >= reward) {
                pairVault.insuranceFundBalance -= reward;
                if (!_sendUsdcFromContract(ctx.usdc, msg.sender, reward)) {
                    pairVault.insuranceFundBalance += reward;
                }
            }
        }

        sum = _summarize(res);
    }

    // ================================================================
    // THE TAKER WALK
    // ================================================================

    /// @dev Walk the opposing list from its head while the taker crosses, then dispose of the
    ///      remainder. `cap` counts NODES VISITED (skips included), so expired dust in the
    ///      crossing region cannot push the caller past their gas budget.
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
        bool takerIsLong = t.order.isLong;
        uint256 takerBound = BazaarMathLib.effectivePrice(
            t.order.orderType, t.order.limitPrice, takerIsLong, t.order.maxSlippageBp, ctx.cachedPrice
        );
        bool takerDead;

        while (t.remaining > 0) {
            uint64 headId = takerIsLong ? book.askHead : book.bidHead;
            if (headId == 0) break;
            Head memory m;
            m.orderId = headId;
            m.order = orders[headId];
            uint256 mPrice = m.order.limitPrice;
            if (takerIsLong ? mPrice > takerBound : mPrice < takerBound) break; // best price no longer crosses
            unchecked {
                ++res.nodesVisited;
            }
            if (res.nodesVisited > cap) {
                // Still crossing at the cap: the remainder must die — resting it would leave a
                // crossed book.
                takerDead = true;
                break;
            }
            if (m.order.expiryBlock < ctx.currentBlock) {
                _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, m, ctx);
                continue;
            }
            if (t.order.isPostOnly) {
                // Crossing a live maker at all is the violation; cancel before any fill.
                takerDead = true;
                break;
            }
            if (ctx.isOracleStale) {
                // Under the stale fallback, fills are confined to ±MAX_STALE_DEVIATION_BP of the
                // last stored price. An out-of-band maker is not at fault — resting far from the
                // last print is legitimate gap positioning — so the INCOMING order is the one
                // canceled, and since the list is price-sorted nothing deeper could fill either.
                uint256 hi = ctx.cachedPrice * (BazaarTypes.BP_SCALE + BazaarTypes.MAX_STALE_DEVIATION_BP)
                    / BazaarTypes.BP_SCALE;
                uint256 lo = ctx.cachedPrice * (BazaarTypes.BP_SCALE - BazaarTypes.MAX_STALE_DEVIATION_BP)
                    / BazaarTypes.BP_SCALE;
                if (mPrice > hi || mPrice < lo) {
                    takerDead = true;
                    break;
                }
            }
            if (m.order.creator == t.order.creator) {
                // Self-match cancels the newer order, and the arriving side is always newer.
                takerDead = true;
                break;
            }
            m.remaining = m.order.size - m.order.filledSize;
            uint8 outcome =
                _fillCrossed(orders, positionBuckets, userActiveLimitOrders, book, m, t, takerIsLong, ctx, res);
            if (outcome == TAKER_DEAD) {
                takerDead = true;
                break;
            }
            // A fill can terminate the TAKER's own order through the oversize fence (a close-only
            // order that just closed its position out). The taker is held in memory across the
            // loop, so re-read its terminal stamps from storage rather than trusting the copy —
            // continuing here would let a canceled order keep trading.
            if (outcome == FILLED && orders[takerId].canceledBlock != 0) return;
            // FILLED or MAKER_DEAD: loop re-reads the head, which the fill/cancel just advanced.
        }

        if (takerDead) {
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, t, ctx);
            return;
        }
        if (t.remaining == 0) return; // fully filled; _persistFill stamped it terminal

        // Remainder disposition. Market/StopLoss executions and IOC limits never rest. A
        // sub-minimum remainder rests only under the live full-close exemption (mirroring
        // creation), so partial fills cannot mint resting dust.
        if (_isOracleDerivedPrice(t.order.orderType) || t.order.isIoc) {
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, t, ctx);
            return;
        }
        uint256 remNotional = Math.mulDiv(t.remaining, t.order.limitPrice, BazaarTypes.BAZAAR_SCALE);
        if (remNotional < BazaarTypes.MIN_ORDER_AMOUNT) {
            BazaarTypes.PositionBucket storage bucket = positionBuckets[t.order.creator];
            bool isFullClose = bucket.size > 0 && bucket.isLong != takerIsLong && t.remaining == bucket.size;
            if (!isFullClose) {
                _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, t, ctx);
                return;
            }
        }
        OrderBookLib.insert(orders, book, takerId, hints);
    }

    /// @dev One crossed maker/taker fill: fees, margin gates, then settlement. Mapped into the
    ///      long/short frame so the settlement tail and events are side-symmetric.
    function _fillCrossed(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.OrderBook storage book,
        Head memory makerH,
        Head memory takerH,
        bool takerIsLong,
        BazaarTypes.ArrivalContext memory ctx,
        BazaarTypes.ArrivalResult memory res
    ) private returns (uint8) {
        Head memory longH = takerIsLong ? takerH : makerH;
        Head memory shortH = takerIsLong ? makerH : takerH;

        FillParams memory p;
        p.makerIsLong = !takerIsLong;
        p.fillPrice = makerH.order.limitPrice;
        p.fillSize = takerH.remaining < makerH.remaining ? takerH.remaining : makerH.remaining;
        uint256 fillNotional = Math.mulDiv(p.fillSize, p.fillPrice, BazaarTypes.BAZAAR_SCALE);

        BazaarTypes.PositionBucket memory longBucketMem = positionBuckets[longH.order.creator];
        p.longState = BucketLib.calculateState(longBucketMem, ctx.cachedPrice, ctx.cachedFundingIdx, ctx.marginReqs);
        BazaarTypes.PositionBucket memory shortBucketMem = positionBuckets[shortH.order.creator];
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
            if (
                !_checkMargin(
                    mkBucket,
                    mkState,
                    p.makerIsLong,
                    p.fillSize,
                    p.fillPrice,
                    mkFee,
                    ctx.cachedPrice,
                    ctx.marginReqs.imrBp,
                    ctx.marginReqs.mmrBp,
                    ctx.marginReqs.laggedMmrBp
                )
            ) {
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
            if (
                !_checkMargin(
                    tkBucket,
                    tkState,
                    !p.makerIsLong,
                    p.fillSize,
                    p.fillPrice,
                    tkFee,
                    ctx.cachedPrice,
                    ctx.marginReqs.imrBp,
                    ctx.marginReqs.mmrBp,
                    ctx.marginReqs.laggedMmrBp
                )
            ) {
                unchecked {
                    res.feeBudget += p.fees.longTotalFee + p.fees.shortTotalFee; // nothing settled
                }
                // The taker's cancel happens in _walkTaker so the remainder rule stays in one place.
                return TAKER_DEAD;
            }
        }

        _settleFill(orders, positionBuckets, userActiveLimitOrders, book, longH, shortH, p, ctx, res);
        return FILLED;
    }

    /// @dev Persist + apply a crossed fill and fold it into the walk aggregates. Split from
    ///      _fillCrossed so the fill path's frame stays shallow enough for the Yul stack
    ///      scheduler: the settle tail keeps every struct alive at once, so it reads the
    ///      fee/state products through `p` rather than holding each as its own stack slot.
    function _settleFill(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.OrderBook storage book,
        Head memory longH,
        Head memory shortH,
        FillParams memory p,
        BazaarTypes.ArrivalContext memory ctx,
        BazaarTypes.ArrivalResult memory res
    ) private {
        uint256 fillNotional = Math.mulDiv(p.fillSize, p.fillPrice, BazaarTypes.BAZAAR_SCALE);
        _persistFill(orders, positionBuckets, userActiveLimitOrders, book, longH, p.fillSize, ctx.currentBlock);
        _persistFill(orders, positionBuckets, userActiveLimitOrders, book, shortH, p.fillSize, ctx.currentBlock);

        BazaarTypes.FillResult memory longResult = _applyFillWithState(
            longH.order.creator,
            p.longState,
            true,
            p.fillSize,
            p.fillPrice,
            p.fees.longTotalFee,
            ctx,
            orders,
            positionBuckets,
            book
        );
        BazaarTypes.FillResult memory shortResult = _applyFillWithState(
            shortH.order.creator,
            p.shortState,
            false,
            p.fillSize,
            p.fillPrice,
            p.fees.shortTotalFee,
            ctx,
            orders,
            positionBuckets,
            book
        );

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
            longH.order.filledSize += fillSize;
            shortH.order.filledSize += fillSize;
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
        emit BazaarTypes.PositionModified(
            ctx.pairId,
            longH.order.creator,
            longResult.newIsLong,
            longResult.sizeDelta,
            longResult.newSize,
            longResult.newEntryValue,
            longResult.newCollateral,
            p.fillPrice,
            p.fees.longTotalFee,
            longResult.realizedPnl
        );
        emit BazaarTypes.PositionModified(
            ctx.pairId,
            shortH.order.creator,
            shortResult.newIsLong,
            shortResult.sizeDelta,
            shortResult.newSize,
            shortResult.newEntryValue,
            shortResult.newCollateral,
            p.fillPrice,
            p.fees.shortTotalFee,
            shortResult.realizedPnl
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
                    // base (closing) fee, but keeps the surplus discount when the risk-adding
                    // rate is lower. The deficit stress multiplier still applies only to the
                    // risk-adding portion.
                    uint256 closingEbp =
                        ctx.closingFeeEbp < ctx.insuranceFeeEbp ? ctx.closingFeeEbp : ctx.insuranceFeeEbp;
                    uint256 closingSize = fillSize > takerState.adjustedSize ? takerState.adjustedSize : fillSize;
                    uint256 closingNotional = Math.mulDiv(closingSize, fillPrice, BazaarTypes.BAZAAR_SCALE);
                    uint256 riskAddingNotional = fillNotional - closingNotional;
                    takerInsFee = (closingNotional * closingEbp) / BazaarTypes.EBP_SCALE
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

    /// @dev One fill of vault inventory against the resting maker at the head. The maker's leg
    ///      settles into its own bucket; the vault's PnL accumulates in `res` and settles
    ///      through insurance in finalize.
    function _fillVault(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.OrderBook storage book,
        Head memory makerH,
        BazaarTypes.ArrivalContext memory ctx,
        BazaarTypes.ArrivalResult memory res
    ) private {
        VaultFillData memory data;
        data.fillSize = makerH.remaining;
        if (data.fillSize > pairVault.pendingLiqSize) data.fillSize = pairVault.pendingLiqSize;
        if (data.fillSize == 0) return;

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

        if (
            !_checkMargin(
                makerBucket,
                makerState,
                makerH.order.isLong,
                data.fillSize,
                data.execPrice,
                data.makerTotalFee,
                ctx.cachedPrice,
                ctx.marginReqs.imrBp,
                ctx.marginReqs.mmrBp,
                ctx.marginReqs.laggedMmrBp
            )
        ) {
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, book, makerH, ctx);
            return; // head advanced; the unload loop retries the next maker
        }

        _persistFill(orders, positionBuckets, userActiveLimitOrders, book, makerH, data.fillSize, ctx.currentBlock);
        BazaarTypes.FillResult memory mr = _applyFillWithState(
            makerH.order.creator,
            makerState,
            makerH.order.isLong,
            data.fillSize,
            data.execPrice,
            data.makerTotalFee,
            ctx,
            orders,
            positionBuckets,
            book
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
            makerH.order.filledSize += data.fillSize;
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
    }

    /// @dev Liquidation-fill price band — protects the vault from unwinding at adverse prices.
    ///      userIsLong = true  → vault sells inherited longs, won't sell below oracle*(1-band).
    ///      userIsLong = false → vault buys inherited shorts, won't buy above oracle*(1+band).
    ///      Band = min(LIQ_MAX_SLIPPAGE_BP, current MMR): with band ≤ MMR, a band-edge fill lands
    ///      at roughly the bankruptcy price at liquidation time, so the unwind can't realize
    ///      losses meaningfully past bankruptcy in calm regimes; when MMR floats above the cap
    ///      (volatile markets, where bids are scarce and bankruptcy sits far below the floor)
    ///      the full LIQ_MAX_SLIPPAGE_BP width applies.
    function _passAOk(uint256 makerPrice, uint256 oraclePrice, uint256 mmrBp, bool userIsLong)
        private
        pure
        returns (bool)
    {
        uint256 bandBp = mmrBp < BazaarTypes.LIQ_MAX_SLIPPAGE_BP ? mmrBp : BazaarTypes.LIQ_MAX_SLIPPAGE_BP;
        if (userIsLong) {
            // Vault is selling — refuse fills below the floor
            uint256 minPrice = oraclePrice * (BazaarTypes.BP_SCALE - bandBp) / BazaarTypes.BP_SCALE;
            return makerPrice >= minPrice;
        } else {
            // Vault is buying — refuse fills above the ceiling
            uint256 maxPrice = oraclePrice * (BazaarTypes.BP_SCALE + bandBp) / BazaarTypes.BP_SCALE;
            return makerPrice <= maxPrice;
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
            // inside its fill via _applyFillWithState into its OWN bucket — its side never routes
            // through insurance, which is why the vault's side needs this explicit entry. (ADL is
            // the opposite: the winner's settlement is insurance-funded, so the tab netting there
            // IS insurance's entry and no explicit term may exist — see _closeAdlWinners.) The
            // index is a size-weighted average, so it's unchanged on a proportional partial close.
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
            pairVault.pendingLiqSize = existingSize - fillSize;
            pairVault.pendingLiqEntryNotional -= entryPortion;
            pairVault.pendingLiqBankruptcyNotional -= bkPortion;
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
            newFilled = h.order.filledSize + fillSize;
        }
        stored.filledSize = newFilled;
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
    /// @dev The caller passes the effective imrBp — there is no stale branch inside. Risk-reducing
    ///      fills are judged against MMR rather than IMR.
    function _checkMargin(
        BazaarTypes.PositionBucket memory bucket,
        BazaarTypes.BucketState memory state,
        bool isLong,
        uint256 fillSize,
        uint256 executionPrice,
        uint256 fee,
        uint256 cachedPrice,
        uint256 imrBp,
        uint256 mmrBp,
        uint256 laggedMmrBp
    ) internal view returns (bool) {
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
            effectiveBp = imrBp;
        } else if (bucket.isLong == isLong) {
            // Same-side add
            newExposureSize = fillSize;
            newTotalNotional = state.currentNotional + Math.mulDiv(fillSize, cachedPrice, BazaarTypes.BAZAAR_SCALE);
            effectiveBp = imrBp;
        } else if (fillSize <= bucket.size) {
            // Partial / full close — apply realized PnL up front, reject if it underwaters collateral
            newExposureSize = 0;

            uint256 closedEntryValue = Math.mulDiv(state.entryValue, fillSize, bucket.size);
            uint256 closedNotional = Math.mulDiv(fillSize, executionPrice, BazaarTypes.BAZAAR_SCALE);
            int256 realizedPnl = bucket.isLong
                ? int256(closedNotional) - int256(closedEntryValue)
                : int256(closedEntryValue) - int256(closedNotional);
            // Funding settles on the closed shares (mirrors _applyFillWithState) — gate on the
            // combined sum so the gate and settlement agree.
            int256 closedFunding = BazaarMathLib.signedMulDiv(state.fundingPnl, int256(fillSize), int256(bucket.size));

            int256 postFillCol = int256(collateralAfterFee) + realizedPnl + closedFunding;
            if (postFillCol < 0) return false; // bad debt — must liquidate instead
            collateralAfterFee = uint256(postFillCol);

            uint256 remaining = bucket.size - fillSize;
            newTotalNotional = Math.mulDiv(remaining, cachedPrice, BazaarTypes.BAZAAR_SCALE);
            // 24h-lagged effective MMR for the surviving remainder (consistent with BucketLib).
            effectiveBp = BucketLib.effectiveMmr(state.mmrUpdateTs, state.entryMmrBp, laggedMmrBp, mmrBp);
        } else {
            // Flip — close existing fully, residual = fillSize − bucket.size on the new side
            uint256 closedNotional = Math.mulDiv(bucket.size, executionPrice, BazaarTypes.BAZAAR_SCALE);
            int256 realizedPnl = bucket.isLong
                ? int256(closedNotional) - int256(state.entryValue)
                : int256(state.entryValue) - int256(closedNotional);

            // Flip closes the whole position — its entire fundingPnl settles (mirrors _applyFillWithState).
            int256 postCloseCol = int256(collateralAfterFee) + realizedPnl + state.fundingPnl;
            if (postCloseCol < 0) return false; // bad debt on closed portion — must liquidate
            collateralAfterFee = uint256(postCloseCol);

            newExposureSize = fillSize - bucket.size;
            newTotalNotional = Math.mulDiv(newExposureSize, cachedPrice, BazaarTypes.BAZAAR_SCALE);
            effectiveBp = imrBp;
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

    function _applyFillWithState(
        address user,
        BazaarTypes.BucketState memory state,
        bool orderIsLong,
        uint256 fillSize,
        uint256 executionPrice,
        uint256 fee,
        BazaarTypes.ArrivalContext memory ctx,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.OrderBook storage book
    ) internal returns (BazaarTypes.FillResult memory result) {
        BazaarTypes.PositionBucket storage bucket = positionBuckets[user];

        uint256 fillNotional = Math.mulDiv(fillSize, executionPrice, BazaarTypes.BAZAAR_SCALE);
        uint256 originalSize = state.adjustedSize;
        bool originalIsLong = bucket.isLong;

        // _checkMargin guarantees effectiveCollateral >= fee for every fill that reaches here, so
        // this never floors a shortfall away. Kept as a checked subtraction (not unchecked/floored):
        // if the coverage invariant were ever violated it reverts the transaction rather than
        // silently under-collecting.
        state.effectiveCollateral = state.effectiveCollateral - fee;

        if (originalSize == 0) {
            state.adjustedSize = fillSize;
            state.entryValue = fillNotional;
            bucket.isLong = orderIsLong;
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
                    bucket.isLong = orderIsLong;
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

        BucketLib.updateFromState(bucket, state);
        BucketLib.emitBucketUpdate(user, bucket, ctx.cachedFundingIdx, ctx.marginReqs, ctx.pairId);

        // TP/SL fence: shrink-or-flip → cancel oversized TP/SL.
        {
            uint256 keep = (state.adjustedSize > 0 && bucket.isLong != originalIsLong) ? 0 : state.adjustedSize;
            if (keep < originalSize) {
                _cancelOversizedTpSl(user, bucket, keep, orders, book, ctx.pairId, ctx.currentBlock);
            }
        }

        result.newSize = state.adjustedSize;
        result.newEntryValue = state.entryValue;
        result.newCollateral = state.effectiveCollateral;
        result.newIsLong = bucket.isLong;
    }

    /// @dev Cancel any TP/SL whose remaining size exceeds the position left after a fill that
    ///      shrank or flipped it. Unlinking here is load-bearing for the walk's head-re-read
    ///      discipline: a resting TakeProfit canceled by this fence leaves the book in the same
    ///      transaction, so no later iteration (or any other walk) can fill it.
    function _cancelOversizedTpSl(
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
            uint256 tpRemaining = tpOrder.size - tpOrder.filledSize;
            if (tpOrder.canceledBlock == 0 && tpOrder.filledBlock == 0 && tpRemaining > currentSize) {
                tpOrder.canceledBlock = currentBlock;
                OrderBookLib.unlink(orders, book, bucket.takeProfitOrderId);
                _emitOrderCanceled(pairId, bucket.takeProfitOrderId, user, tpOrder);
                bucket.takeProfitOrderId = 0;
            }
        }
        if (bucket.stopLossOrderId != 0) {
            BazaarTypes.Order storage slOrder = orders[bucket.stopLossOrderId];
            uint256 slRemaining = slOrder.size - slOrder.filledSize;
            if (slOrder.canceledBlock == 0 && slOrder.filledBlock == 0 && slRemaining > currentSize) {
                slOrder.canceledBlock = currentBlock;
                OrderBookLib.unlink(orders, book, bucket.stopLossOrderId);
                _emitOrderCanceled(pairId, bucket.stopLossOrderId, user, slOrder);
                bucket.stopLossOrderId = 0;
            }
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
    ///      the vault-PnL insurance transfer, the bug-bounty skim, and the integrator payouts.
    ///      Runs once per walk so storage is touched a bounded number of times regardless of
    ///      fill count.
    function _finalizeTx(
        BazaarTypes.Vault storage pairVault,
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
            // TRANSFER (mirroring AdlLib._fundWinnerPnl), not a bare insurance debit — otherwise
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
        uint256 bbFromIntegrator = Math.mulDiv(res.totalIntegratorFees, BazaarTypes.BUG_BOUNTY_TAX_BP, BazaarTypes.BP_SCALE);
        uint256 bbFromInsurance = Math.mulDiv(res.totalInsuranceFees, BazaarTypes.BUG_BOUNTY_TAX_BP, BazaarTypes.BP_SCALE);
        uint256 totalBugBounty = bbFromIntegrator + bbFromInsurance;

        uint256 netInsuranceFees = res.totalInsuranceFees - bbFromInsurance;
        if (netInsuranceFees > 0) {
            unchecked {
                pairVault.insuranceFundBalance += netInsuranceFees;
            }
        }

        if (totalBugBounty > 0) {
            if (
                ctx.bugBountyAddress == address(0)
                    || !_sendUsdcFromContract(ctx.usdc, ctx.bugBountyAddress, totalBugBounty)
            ) {
                unchecked {
                    pairVault.insuranceFundBalance += totalBugBounty;
                }
            }
        }

        _finalizeIntegratorFees(
            pairVault, ctx.usdc, res.integratorAccums, res.integratorCount, BazaarTypes.BUG_BOUNTY_TAX_BP
        );
    }

    // ================================================================
    // SHARED SMALL HELPERS
    // ================================================================

    function _isOracleDerivedPrice(BazaarTypes.OrderType ot) internal pure returns (bool) {
        return ot == BazaarTypes.OrderType.Market || ot == BazaarTypes.OrderType.StopLoss;
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

    /// @dev Soft-fail USDC transfer for fee payouts. Returns true only when the transfer
    ///      truly succeeded; callers credit unsent amounts to insurance on false.
    function _sendUsdcFromContract(address usdc, address to, uint256 amountBazaarPrecision) internal returns (bool) {
        if (to == address(0)) return false;
        uint256 usdcAmount = uint256(
            BazaarMathLib.convertExponent(
                int256(amountBazaarPrecision), BazaarTypes.BAZAAR_EXPONENT, BazaarTypes.USDC_EXPONENT
            )
        );
        if (usdcAmount == 0) return false;
        (bool callOk, bytes memory data) = usdc.call(abi.encodeWithSelector(0xa9059cbb, to, usdcAmount));
        if (!callOk) return false;
        if (data.length == 0) return true; // non-compliant token that doesn't return bool
        return abi.decode(data, (bool));
    }

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

    function _finalizeIntegratorFees(
        BazaarTypes.Vault storage pairVault,
        address usdc,
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
                if (integrator == address(0) || !_sendUsdcFromContract(usdc, integrator, netAmount)) {
                    unchecked {
                        pairVault.insuranceFundBalance += netAmount;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }
    }
}
