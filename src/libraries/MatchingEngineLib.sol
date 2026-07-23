// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";
import {BucketLib} from "./BucketLib.sol";

/// @title MatchingEngineLib
/// @notice Three-pass matching engine driven by sequencer-supplied sorted lists.
///         Pass A: vault liquidation vs limits (one direction).
///         Pass B: markets vs limits (two sub-walks; limits always maker).
///         Pass C: limits vs limits (older orderId is maker).
///         Runs via DELEGATECALL from BazaarPair — has direct storage access.
///
/// Key invariants:
///  • Limits are sorted by limitPrice (DESC longs, ASC shorts), tiebreak orderId ASC.
///  • Markets are sorted by maxSlippageBp DESC, tiebreak orderId ASC.
///  • Margin checks always use normal IMR (against fresh-oracle price). Failure → auto-cancel.
///    During stale, additionally check 2× IMR; failure-only-under-stale → skip + push to staleSkippedIds.
///  • maxMatches caps total successful matches across all passes (gas-safety circuit breaker).
library MatchingEngineLib {
    using EnumerableSet for EnumerableSet.UintSet;

    // -------------------- Errors --------------------
    // NOTE (measured 2026-07-21): trimming this error's args, like trimming PositionModified's
    // duplicate fields, made the library BIGGER under via_ir (inlining-decision shift): args
    // dropped at 4 sites = +26B, event fields = +83B. Don't "simplify" these for size.
    error MatchingEngineLib__OrderCreatedAfterObservation(
        uint256 orderId, uint64 creationBlock, uint64 observationBlock
    );
    error MatchingEngineLib__StaleFilledOrder(uint256 orderId);
    error MatchingEngineLib__SortViolation(uint256 orderId);
    error MatchingEngineLib__WrongOrderTypeInList(
        uint256 orderId, BazaarTypes.OrderType expected, BazaarTypes.OrderType got
    );
    error MatchingEngineLib__WrongOrderSideInList(uint256 orderId, bool expectedIsLong, bool got);

    // -------------------- Memory state --------------------

    /// @dev Memory-cached head order — lifted out of the hot loop to avoid repeat SLOADs on partial fills.
    struct Head {
        bool loaded;
        uint256 orderId;
        uint256 effectivePrice;
        uint256 remaining;
        BazaarTypes.Order order;
    }

    /// @dev Walk state across all three passes — pointers, sort watermarks, and limit-side heads
    ///      that carry across passes.
    struct WalkState {
        // Pointers
        uint256 iLimitLong;
        uint256 jLimitShort;
        uint256 iMarketLong;
        uint256 jMarketShort;
        // Lengths cached from calldata
        uint256 lenLimitLong;
        uint256 lenLimitShort;
        uint256 lenMarketLong;
        uint256 lenMarketShort;
        // Sort watermarks (last-seen values for inline sort verification)
        uint256 lastLimitLongPrice;
        uint256 lastLimitShortPrice;
        uint256 lastLimitLongOrderId;
        uint256 lastLimitShortOrderId;
        uint256 lastMarketLongSlip;
        uint256 lastMarketShortSlip;
        uint256 lastMarketLongOrderId;
        uint256 lastMarketShortOrderId;
        // Heads that carry across passes
        Head longLimitHead;
        Head shortLimitHead;
    }

    /// @dev Per-integrator accumulator with running count, allocated in _initBuffers to
    ///      2 x min(maxMatches, totalIds + slack) — two appends per match are possible.
    struct IntegratorBag {
        BazaarTypes.IntegratorAccum[] accums;
        uint256 count;
    }

    /// @dev Per-side fee breakdown for a user-pair match.
    struct PairFees {
        uint256 longSeqFee;
        uint256 shortSeqFee;
        uint256 longIntegratorFee;
        uint256 shortIntegratorFee;
        uint256 longInsuranceFee;
        uint256 shortInsuranceFee;
        uint256 longTotalFee;
        uint256 shortTotalFee;
    }

    // -------------------- External entrypoint --------------------

    function executeBatch(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(uint256 => bytes32) storage batchHashes,
        BazaarTypes.MatchingState storage matchingState,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.OrderLists calldata lists,
        BazaarTypes.MatchContext memory ctx
    ) external returns (BazaarTypes.BatchResult memory result) {
        _runWalk(orders, positionBuckets, userActiveLimitOrders, pairVault, lists, ctx, result);
        _finalize(pairVault, batchHashes, matchingState, ctx, result);
    }

    /// @dev Worker that owns the WalkState and Heads. Splits responsibility from executeBatch
    ///      to keep stack pressure manageable under via_ir.
    function _runWalk(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.OrderLists calldata lists,
        BazaarTypes.MatchContext memory ctx,
        BazaarTypes.BatchResult memory result
    ) private {
        _initBuffers(ctx, lists, result);
        WalkState memory ws = _initWalkState(lists);

        if (pairVault.pendingLiqSize != 0) {
            _passA(
                orders,
                positionBuckets,
                userActiveLimitOrders,
                pairVault,
                lists.longLimits,
                lists.shortLimits,
                ctx,
                ws,
                result
            );
        }

        if (!ctx.isOracleStale) {
            _passB(orders, positionBuckets, userActiveLimitOrders, lists, ctx, ws, result);
        }

        _passC(orders, positionBuckets, userActiveLimitOrders, lists.longLimits, lists.shortLimits, ctx, ws, result);
    }

    function _initBuffers(
        BazaarTypes.MatchContext memory ctx,
        BazaarTypes.OrderLists calldata lists,
        BazaarTypes.BatchResult memory result
    ) private pure {
        result.lowestLongLimitPrice = type(uint256).max;
        result.lowestLongMarketPrice = type(uint256).max;
        result.lowestShortLimitPriceC = type(uint256).max;
        // Each successful match appends at most TWO integrator accums (the long and short
        // sides can carry distinct integrators), so the buffer must hold 2x the fill bound —
        // sizing it to maxMatches alone under-allocates, and a book seeded with unique
        // integrators would overflow it and revert the batch. Fills are additionally bounded
        // by the supplied order count (every fill fully consumes at least one order, except
        // a few capacity-truncated boundary fills — hence the slack), which keeps the
        // allocation proportional to real work even for an enormous maxMatches.
        unchecked {
            uint256 totalIds = lists.longLimits.length + lists.shortLimits.length + lists.longMarkets.length
                + lists.shortMarkets.length;
            uint256 fillBound = ctx.maxMatches < totalIds + 8 ? ctx.maxMatches : totalIds + 8;
            result.integratorAccums = new BazaarTypes.IntegratorAccum[](2 * fillBound);
        }
        if (ctx.isOracleStale) {
            unchecked {
                result.staleSkippedIds = new uint256[](
                    lists.longLimits.length + lists.shortLimits.length + lists.longMarkets.length
                        + lists.shortMarkets.length
                );
            }
        }
    }

    function _initWalkState(BazaarTypes.OrderLists calldata lists) private pure returns (WalkState memory ws) {
        unchecked {
            ws.lenLimitLong = lists.longLimits.length;
            ws.lenLimitShort = lists.shortLimits.length;
            ws.lenMarketLong = lists.longMarkets.length;
            ws.lenMarketShort = lists.shortMarkets.length;
            ws.lastLimitLongPrice = type(uint256).max;
            ws.lastMarketLongSlip = type(uint256).max;
            ws.lastMarketShortSlip = type(uint256).max;
        }
    }

    // ================================================================
    // PASS A — vault liquidation vs limits
    // ================================================================

    /// @dev Conventional CLOB direction:
    ///      pendingLiqIsLong = true  → vault inherited a long, walks longLimits  (long-side buyers).
    ///      pendingLiqIsLong = false → vault inherited a short, walks shortLimits (short-side sellers).
    function _passA(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
        uint256[] calldata longLimits,
        uint256[] calldata shortLimits,
        BazaarTypes.MatchContext memory ctx,
        WalkState memory ws,
        BazaarTypes.BatchResult memory result
    ) private {
        if (pairVault.pendingLiqIsLong) {
            while (pairVault.pendingLiqSize != 0 && ws.iLimitLong < ws.lenLimitLong) {
                if (result.successCount >= ctx.maxMatches) return;
                if (result.totalMatchedVolume >= ctx.remainingCapacity) return;
                if (!_loadHeadLongLimit(ws.longLimitHead, orders, longLimits, ws, ctx)) continue;
                if (!_passAOk(ws.longLimitHead.effectivePrice, ctx.cachedPrice, ctx.marginReqs.mmrBp, true)) break;
                if (!_matchVault(
                        orders, positionBuckets, userActiveLimitOrders, pairVault, ws.longLimitHead, ctx, result
                    )) return; // no-progress signal: exit pass
                if (ws.longLimitHead.remaining == 0) {
                    ws.longLimitHead.loaded = false;
                    unchecked {
                        ++ws.iLimitLong;
                    }
                }
            }
        } else {
            while (pairVault.pendingLiqSize != 0 && ws.jLimitShort < ws.lenLimitShort) {
                if (result.successCount >= ctx.maxMatches) return;
                if (result.totalMatchedVolume >= ctx.remainingCapacity) return;
                if (!_loadHeadShortLimit(ws.shortLimitHead, orders, shortLimits, ws, ctx)) continue;
                if (!_passAOk(ws.shortLimitHead.effectivePrice, ctx.cachedPrice, ctx.marginReqs.mmrBp, false)) break;
                if (!_matchVault(
                        orders, positionBuckets, userActiveLimitOrders, pairVault, ws.shortLimitHead, ctx, result
                    )) return;
                if (ws.shortLimitHead.remaining == 0) {
                    ws.shortLimitHead.loaded = false;
                    unchecked {
                        ++ws.jLimitShort;
                    }
                }
            }
        }
    }

    /// @dev Pass A price band — protects the vault from liquidation matches at adverse prices.
    ///      userIsLong = true  → vault sells inherited long, won't sell below oracle*(1-band).
    ///      userIsLong = false → vault buys inherited short, won't buy above oracle*(1+band).
    ///      Band = min(LIQ_MAX_SLIPPAGE_BP, current MMR): with band ≤ MMR, a band-edge fill lands
    ///      at roughly the bankruptcy price at liquidation time, so Pass A can't realize losses
    ///      meaningfully past bankruptcy in calm regimes; when MMR floats above the cap (volatile
    ///      markets, where bids are scarce and bankruptcy sits far below the floor) the full
    ///      LIQ_MAX_SLIPPAGE_BP width applies.
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

    // ================================================================
    // PASS B — markets vs limits (two sub-walks)
    // ================================================================

    function _passB(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.OrderLists calldata lists,
        BazaarTypes.MatchContext memory ctx,
        WalkState memory ws,
        BazaarTypes.BatchResult memory result
    ) private {
        Head memory longMarketHead;
        Head memory shortMarketHead;
        // Sub-walk 1: longMarkets × shortLimits  (deterministic ordering: longs first)
        while (ws.iMarketLong < ws.lenMarketLong && ws.jLimitShort < ws.lenLimitShort) {
            if (result.successCount >= ctx.maxMatches) return;
            if (result.totalMatchedVolume >= ctx.remainingCapacity) return;
            if (!_loadHeadLongMarket(longMarketHead, orders, lists.longMarkets, ws, ctx)) continue;
            if (!_loadHeadShortLimit(ws.shortLimitHead, orders, lists.shortLimits, ws, ctx)) continue;

            if (longMarketHead.effectivePrice < ws.shortLimitHead.effectivePrice) break;

            if (longMarketHead.order.creator == ws.shortLimitHead.order.creator) {
                if (longMarketHead.orderId > ws.shortLimitHead.orderId) {
                    _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, longMarketHead, ctx);
                    longMarketHead.loaded = false;
                    unchecked {
                        ++ws.iMarketLong;
                    }
                } else {
                    _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, ws.shortLimitHead, ctx);
                    ws.shortLimitHead.loaded = false;
                    unchecked {
                        ++ws.jLimitShort;
                    }
                }
                continue;
            }

            if (!_matchMarketLimit(
                    orders,
                    positionBuckets,
                    userActiveLimitOrders,
                    longMarketHead,
                    ws.shortLimitHead,
                    /* longIsMarket */
                    true,
                    ctx,
                    result
                )) return; // no-progress signal: exit pass

            if (longMarketHead.remaining == 0) {
                longMarketHead.loaded = false;
                unchecked {
                    ++ws.iMarketLong;
                }
            }
            if (ws.shortLimitHead.remaining == 0) {
                ws.shortLimitHead.loaded = false;
                unchecked {
                    ++ws.jLimitShort;
                }
            }
        }

        // Sub-walk 2: shortMarkets × longLimits
        while (ws.jMarketShort < ws.lenMarketShort && ws.iLimitLong < ws.lenLimitLong) {
            if (result.successCount >= ctx.maxMatches) return;
            if (result.totalMatchedVolume >= ctx.remainingCapacity) return;
            if (!_loadHeadShortMarket(shortMarketHead, orders, lists.shortMarkets, ws, ctx)) continue;
            if (!_loadHeadLongLimit(ws.longLimitHead, orders, lists.longLimits, ws, ctx)) continue;

            if (ws.longLimitHead.effectivePrice < shortMarketHead.effectivePrice) break;

            if (shortMarketHead.order.creator == ws.longLimitHead.order.creator) {
                if (shortMarketHead.orderId > ws.longLimitHead.orderId) {
                    _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, shortMarketHead, ctx);
                    shortMarketHead.loaded = false;
                    unchecked {
                        ++ws.jMarketShort;
                    }
                } else {
                    _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, ws.longLimitHead, ctx);
                    ws.longLimitHead.loaded = false;
                    unchecked {
                        ++ws.iLimitLong;
                    }
                }
                continue;
            }

            if (!_matchMarketLimit(
                    orders,
                    positionBuckets,
                    userActiveLimitOrders,
                    ws.longLimitHead,
                    shortMarketHead,
                    /* longIsMarket */
                    false,
                    ctx,
                    result
                )) return; // no-progress signal: exit pass

            if (shortMarketHead.remaining == 0) {
                shortMarketHead.loaded = false;
                unchecked {
                    ++ws.jMarketShort;
                }
            }
            if (ws.longLimitHead.remaining == 0) {
                ws.longLimitHead.loaded = false;
                unchecked {
                    ++ws.iLimitLong;
                }
            }
        }
    }

    // ================================================================
    // PASS C — limits vs limits
    // ================================================================

    function _passC(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        uint256[] calldata longLimits,
        uint256[] calldata shortLimits,
        BazaarTypes.MatchContext memory ctx,
        WalkState memory ws,
        BazaarTypes.BatchResult memory result
    ) private {
        while (ws.iLimitLong < ws.lenLimitLong && ws.jLimitShort < ws.lenLimitShort) {
            if (result.successCount >= ctx.maxMatches) return;
            if (result.totalMatchedVolume >= ctx.remainingCapacity) return;
            if (!_loadHeadLongLimit(ws.longLimitHead, orders, longLimits, ws, ctx)) continue;
            if (!_loadHeadShortLimit(ws.shortLimitHead, orders, shortLimits, ws, ctx)) continue;

            if (ws.longLimitHead.effectivePrice < ws.shortLimitHead.effectivePrice) break;

            // Post-only autocancel: a newer post-only that finds an older crossing counterparty
            // is canceled rather than filled.
            if (ws.longLimitHead.order.isPostOnly && ws.longLimitHead.orderId > ws.shortLimitHead.orderId) {
                _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, ws.longLimitHead, ctx);
                ws.longLimitHead.loaded = false;
                unchecked {
                    ++ws.iLimitLong;
                }
                continue;
            }
            if (ws.shortLimitHead.order.isPostOnly && ws.shortLimitHead.orderId > ws.longLimitHead.orderId) {
                _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, ws.shortLimitHead, ctx);
                ws.shortLimitHead.loaded = false;
                unchecked {
                    ++ws.jLimitShort;
                }
                continue;
            }

            // Self-match: auto-cancel the newer side
            if (ws.longLimitHead.order.creator == ws.shortLimitHead.order.creator) {
                if (ws.longLimitHead.orderId > ws.shortLimitHead.orderId) {
                    _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, ws.longLimitHead, ctx);
                    ws.longLimitHead.loaded = false;
                    unchecked {
                        ++ws.iLimitLong;
                    }
                } else {
                    _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, ws.shortLimitHead, ctx);
                    ws.shortLimitHead.loaded = false;
                    unchecked {
                        ++ws.jLimitShort;
                    }
                }
                continue;
            }

            if (!_matchLimitPair(
                    orders, positionBuckets, userActiveLimitOrders, ws.longLimitHead, ws.shortLimitHead, ctx, result
                )) return; // no-progress signal: exit pass

            if (ws.longLimitHead.remaining == 0) {
                ws.longLimitHead.loaded = false;
                unchecked {
                    ++ws.iLimitLong;
                }
            }
            if (ws.shortLimitHead.remaining == 0) {
                ws.shortLimitHead.loaded = false;
                unchecked {
                    ++ws.jLimitShort;
                }
            }
        }
    }

    // ================================================================
    // HEAD LOADERS — per-list with type assertion + sort verification
    // ================================================================

    /// @dev Returns true when head is loaded and matchable; false when pointer was advanced
    ///      (race-skip / stale-skip) and the caller must `continue` the loop.
    function _loadHeadLongLimit(
        Head memory h,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        uint256[] calldata ids,
        WalkState memory ws,
        BazaarTypes.MatchContext memory ctx
    ) private view returns (bool) {
        if (h.loaded) return true;

        uint256 id = ids[ws.iLimitLong];
        BazaarTypes.Order memory o = orders[id];

        if (o.filledBlock != 0 && o.filledBlock <= ctx.observationBlock) {
            revert MatchingEngineLib__StaleFilledOrder(id);
        }
        if (o.creationBlock > ctx.observationBlock) {
            revert MatchingEngineLib__OrderCreatedAfterObservation(id, o.creationBlock, ctx.observationBlock);
        }

        // Type assertion: only Limit / StopLimit (post-trigger) / TakeProfit allowed
        if (_isOracleDerivedPrice(o.orderType)) {
            revert MatchingEngineLib__WrongOrderTypeInList(id, BazaarTypes.OrderType.Limit, o.orderType);
        }
        // Side assertion: fill direction is taken from the list, so the order's own side must match
        // it — otherwise the sequencer could fill a long resting order as a short (and vice versa).
        if (!o.isLong) revert MatchingEngineLib__WrongOrderSideInList(id, true, o.isLong);

        uint256 ep = _effectivePrice(o, ctx.cachedPrice);

        // Sort: longs DESC by price, ASC by orderId on ties
        if (!(ep < ws.lastLimitLongPrice || (ep == ws.lastLimitLongPrice && id >= ws.lastLimitLongOrderId))) {
            revert MatchingEngineLib__SortViolation(id);
        }

        // Race-skip — also skip an untriggered StopLimit (its trigger must be reached by the batch
        // oracle price). limitPrice still bounds any fill, but this stops the sequencer arming it early.
        if (
            o.canceledBlock != 0 || o.expiryBlock < ctx.currentBlock || o.filledBlock != 0
                || _isUntriggeredStop(o, ctx.cachedPrice)
        ) {
            unchecked {
                ++ws.iLimitLong;
            }
            return false;
        }

        ws.lastLimitLongPrice = ep;
        ws.lastLimitLongOrderId = id;

        h.loaded = true;
        h.orderId = id;
        h.effectivePrice = ep;
        unchecked {
            h.remaining = o.size - o.filledSize;
        }
        h.order = o;
        return true;
    }

    function _loadHeadShortLimit(
        Head memory h,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        uint256[] calldata ids,
        WalkState memory ws,
        BazaarTypes.MatchContext memory ctx
    ) private view returns (bool) {
        if (h.loaded) return true;

        uint256 id = ids[ws.jLimitShort];
        BazaarTypes.Order memory o = orders[id];

        if (o.filledBlock != 0 && o.filledBlock <= ctx.observationBlock) {
            revert MatchingEngineLib__StaleFilledOrder(id);
        }
        if (o.creationBlock > ctx.observationBlock) {
            revert MatchingEngineLib__OrderCreatedAfterObservation(id, o.creationBlock, ctx.observationBlock);
        }
        if (_isOracleDerivedPrice(o.orderType)) {
            revert MatchingEngineLib__WrongOrderTypeInList(id, BazaarTypes.OrderType.Limit, o.orderType);
        }
        // Side assertion (see _loadHeadLongLimit): the order's own side must match the list.
        if (o.isLong) revert MatchingEngineLib__WrongOrderSideInList(id, false, o.isLong);

        uint256 ep = _effectivePrice(o, ctx.cachedPrice);

        // Sort: shorts ASC by price, ASC by orderId on ties
        if (!(ep > ws.lastLimitShortPrice || (ep == ws.lastLimitShortPrice && id >= ws.lastLimitShortOrderId))) {
            revert MatchingEngineLib__SortViolation(id);
        }

        // Race-skip — also skip an untriggered StopLimit (see _loadHeadLongLimit).
        if (
            o.canceledBlock != 0 || o.expiryBlock < ctx.currentBlock || o.filledBlock != 0
                || _isUntriggeredStop(o, ctx.cachedPrice)
        ) {
            unchecked {
                ++ws.jLimitShort;
            }
            return false;
        }

        ws.lastLimitShortPrice = ep;
        ws.lastLimitShortOrderId = id;

        h.loaded = true;
        h.orderId = id;
        h.effectivePrice = ep;
        unchecked {
            h.remaining = o.size - o.filledSize;
        }
        h.order = o;
        return true;
    }

    function _loadHeadLongMarket(
        Head memory h,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        uint256[] calldata ids,
        WalkState memory ws,
        BazaarTypes.MatchContext memory ctx
    ) private view returns (bool) {
        if (h.loaded) return true;

        uint256 id = ids[ws.iMarketLong];
        BazaarTypes.Order memory o = orders[id];

        if (o.filledBlock != 0 && o.filledBlock <= ctx.observationBlock) {
            revert MatchingEngineLib__StaleFilledOrder(id);
        }
        if (o.creationBlock > ctx.observationBlock) {
            revert MatchingEngineLib__OrderCreatedAfterObservation(id, o.creationBlock, ctx.observationBlock);
        }
        if (!_isOracleDerivedPrice(o.orderType)) {
            revert MatchingEngineLib__WrongOrderTypeInList(id, BazaarTypes.OrderType.Market, o.orderType);
        }
        // Side assertion (see _loadHeadLongLimit): the order's own side must match the list.
        if (!o.isLong) revert MatchingEngineLib__WrongOrderSideInList(id, true, o.isLong);

        // Sort: maxSlippageBp DESC, orderId ASC on ties
        if (!(o.maxSlippageBp < ws.lastMarketLongSlip
                    || (o.maxSlippageBp == ws.lastMarketLongSlip && id >= ws.lastMarketLongOrderId))) {
            revert MatchingEngineLib__SortViolation(id);
        }

        // Race-skip — also skip an untriggered StopLoss: the batch oracle price must have reached
        // its trigger or it must not match, blocking a sequencer from force-closing a stop early.
        if (
            o.canceledBlock != 0 || o.expiryBlock < ctx.currentBlock || o.filledBlock != 0
                || _isUntriggeredStop(o, ctx.cachedPrice)
        ) {
            unchecked {
                ++ws.iMarketLong;
            }
            return false;
        }

        ws.lastMarketLongSlip = o.maxSlippageBp;
        ws.lastMarketLongOrderId = id;

        h.loaded = true;
        h.orderId = id;
        h.effectivePrice = _effectivePrice(o, ctx.cachedPrice);
        unchecked {
            h.remaining = o.size - o.filledSize;
        }
        h.order = o;
        return true;
    }

    function _loadHeadShortMarket(
        Head memory h,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        uint256[] calldata ids,
        WalkState memory ws,
        BazaarTypes.MatchContext memory ctx
    ) private view returns (bool) {
        if (h.loaded) return true;

        uint256 id = ids[ws.jMarketShort];
        BazaarTypes.Order memory o = orders[id];

        if (o.filledBlock != 0 && o.filledBlock <= ctx.observationBlock) {
            revert MatchingEngineLib__StaleFilledOrder(id);
        }
        if (o.creationBlock > ctx.observationBlock) {
            revert MatchingEngineLib__OrderCreatedAfterObservation(id, o.creationBlock, ctx.observationBlock);
        }
        if (!_isOracleDerivedPrice(o.orderType)) {
            revert MatchingEngineLib__WrongOrderTypeInList(id, BazaarTypes.OrderType.Market, o.orderType);
        }
        // Side assertion (see _loadHeadLongLimit): the order's own side must match the list.
        if (o.isLong) revert MatchingEngineLib__WrongOrderSideInList(id, false, o.isLong);

        if (!(o.maxSlippageBp < ws.lastMarketShortSlip
                    || (o.maxSlippageBp == ws.lastMarketShortSlip && id >= ws.lastMarketShortOrderId))) {
            revert MatchingEngineLib__SortViolation(id);
        }

        // Race-skip — also skip an untriggered StopLoss (see _loadHeadLongMarket).
        if (
            o.canceledBlock != 0 || o.expiryBlock < ctx.currentBlock || o.filledBlock != 0
                || _isUntriggeredStop(o, ctx.cachedPrice)
        ) {
            unchecked {
                ++ws.jMarketShort;
            }
            return false;
        }

        ws.lastMarketShortSlip = o.maxSlippageBp;
        ws.lastMarketShortOrderId = id;

        h.loaded = true;
        h.orderId = id;
        h.effectivePrice = _effectivePrice(o, ctx.cachedPrice);
        unchecked {
            h.remaining = o.size - o.filledSize;
        }
        h.order = o;
        return true;
    }

    /// @dev Worst-case effective price. Limit-priced types use limitPrice; oracle-derived
    ///      (Market/StopLoss) use oracle ± slippage.
    function _effectivePrice(BazaarTypes.Order memory o, uint256 oraclePrice) internal pure returns (uint256) {
        return BazaarMathLib.effectivePrice(o.orderType, o.limitPrice, o.isLong, o.maxSlippageBp, oraclePrice);
    }

    function _isOracleDerivedPrice(BazaarTypes.OrderType ot) internal pure returns (bool) {
        return ot == BazaarTypes.OrderType.Market || ot == BazaarTypes.OrderType.StopLoss;
    }

    /// @dev True when `o` is a trigger-gated stop (StopLoss or StopLimit) whose trigger has NOT been
    ///      reached by the settlement oracle price, so it must not match this batch. Buy stops
    ///      (isLong) require price >= trigger; sell stops require price <= trigger. Non-stop types
    ///      (Limit/Market/TakeProfit) are never gated. Shared by all four head-loaders — the per-list
    ///      type assertions guarantee only the relevant stop type can appear in each list (StopLoss in
    ///      the market lists, StopLimit in the limit lists). Uses the settlement price, so a stop
    ///      touched intra-window but back across the line at settlement is treated as not triggered.
    function _isUntriggeredStop(BazaarTypes.Order memory o, uint256 oraclePrice) private pure returns (bool) {
        if (o.orderType != BazaarTypes.OrderType.StopLoss && o.orderType != BazaarTypes.OrderType.StopLimit) {
            return false;
        }
        return !BazaarMathLib.stopTriggerReached(o.isLong, o.triggerPrice, oraclePrice);
    }

    // ================================================================
    // MATCH FUNCTIONS
    // ================================================================

    /// @notice Pass A: vault liquidation matches a limit maker.
    /// @dev Returns false only when the call made no progress (capacity-truncated
    ///      fillSize=0); callers must exit in that case to avoid spinning on the same head.
    function _matchVault(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.Vault storage pairVault,
        Head memory makerHead,
        BazaarTypes.MatchContext memory ctx,
        BazaarTypes.BatchResult memory result
    ) private returns (bool) {
        VaultMatchData memory data;
        data.fillSize = makerHead.remaining;
        if (data.fillSize > pairVault.pendingLiqSize) data.fillSize = pairVault.pendingLiqSize;
        if (data.fillSize == 0) return true;

        data.execPrice = makerHead.effectivePrice;
        data.fillNotional = Math.mulDiv(data.fillSize, data.execPrice, BazaarTypes.BAZAAR_SCALE);

        // Partial-fill at sequencer-volume-cap boundary: fill as much as fits, defer the rest.
        if (result.totalMatchedVolume + data.fillNotional > ctx.remainingCapacity) {
            uint256 capRoom = ctx.remainingCapacity > result.totalMatchedVolume
                ? ctx.remainingCapacity - result.totalMatchedVolume
                : 0;
            data.fillSize = Math.mulDiv(capRoom, BazaarTypes.BAZAAR_SCALE, data.execPrice);
            if (data.fillSize == 0) return false; // capacity rounding pinned to 0 — no progress, signal caller to exit
            data.fillNotional = Math.mulDiv(data.fillSize, data.execPrice, BazaarTypes.BAZAAR_SCALE);
        }

        unchecked {
            data.makerSeqFee = (data.fillNotional * BazaarTypes.MAKER_SEQUENCER_FEE_EBP) / BazaarTypes.EBP_SCALE
                + BazaarTypes.SEQUENCER_FLAT_FEE_PER_SIDE;
            // No integrator on the order → no integrator fee (direct-to-contract traders
            // aren't charged for a front-end they didn't use).
            data.makerIntFee = makerHead.order.integrator == address(0)
                ? 0
                : (data.fillNotional * BazaarTypes.MAKER_INTEGRATOR_FEE_EBP) / BazaarTypes.EBP_SCALE;
            data.makerInsFee = (data.fillNotional * BazaarTypes.MAKER_INSURANCE_FEE_EBP) / BazaarTypes.EBP_SCALE;
            data.makerTotalFee = data.makerSeqFee + data.makerIntFee + data.makerInsFee;
        }

        if (!_vaultMarginCheck(orders, positionBuckets, userActiveLimitOrders, makerHead, ctx, result, data)) {
            return true; // margin-fail consumed the head; outer loop will advance
        }

        BazaarTypes.PositionBucket memory makerBucket = positionBuckets[makerHead.order.creator];
        // Existing-portion valuation at the bracket: long bucket → low, short bucket → high.
        // New fill notional still uses fillPrice inside _checkMargin.
        BazaarTypes.BucketState memory makerState = BucketLib.calculateState(
            makerBucket, makerBucket.isLong ? ctx.cachedLow : ctx.cachedHigh, ctx.cachedFundingIdx, ctx.marginReqs
        );

        _persistFill(orders, positionBuckets, userActiveLimitOrders, makerHead, data.fillSize, ctx.currentBlock);
        BazaarTypes.FillResult memory mr = _applyFillWithState(
            makerHead.order.creator,
            makerState,
            makerHead.order.isLong,
            data.fillSize,
            data.execPrice,
            data.makerTotalFee,
            ctx,
            orders,
            positionBuckets
        );

        int256 vaultPnl = _settleVaultLiquidation(
            pairVault, result, data.fillSize, data.execPrice, data.fillNotional, ctx.cachedFundingIdx
        );

        _aggregateVaultMatch(result, mr, data, vaultPnl, makerHead);

        _updateLimitAggregate(result, makerHead.order.isLong, makerHead.effectivePrice, makerHead.orderId);
        result.integratorCount = _accumulateIntegratorFee(
            result.integratorAccums, result.integratorCount, makerHead.order.integrator, data.makerIntFee
        );

        _emitVaultMatchEvents(ctx, makerHead, mr, data);
        return true;
    }

    /// @dev Bundle of all vault-match locals — keeps function call sites within stack depth.
    struct VaultMatchData {
        uint256 fillSize;
        uint256 execPrice;
        uint256 fillNotional;
        uint256 makerSeqFee;
        uint256 makerIntFee;
        uint256 makerInsFee;
        uint256 makerTotalFee;
    }

    /// @dev Returns false if margin check failed (head consumed, walk should advance).
    function _vaultMarginCheck(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        Head memory makerHead,
        BazaarTypes.MatchContext memory ctx,
        BazaarTypes.BatchResult memory result,
        VaultMatchData memory data
    ) private returns (bool) {
        BazaarTypes.PositionBucket memory makerBucket = positionBuckets[makerHead.order.creator];
        BazaarTypes.BucketState memory makerState = BucketLib.calculateState(
            makerBucket, makerBucket.isLong ? ctx.cachedLow : ctx.cachedHigh, ctx.cachedFundingIdx, ctx.marginReqs
        );

        if (!_checkMargin(
                makerBucket,
                makerState,
                makerHead.order.isLong,
                data.fillSize,
                data.execPrice,
                data.makerTotalFee,
                ctx.cachedPrice,
                ctx.marginReqs.imrBp,
                ctx.marginReqs.mmrBp,
                ctx.marginReqs.laggedMmrBp
            )) {
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, makerHead, ctx);
            makerHead.remaining = 0;
            return false;
        }
        if (ctx.isOracleStale) {
            uint256 staleImrBp = ctx.marginReqs.imrBp * BazaarTypes.STALE_MARGIN_MULTIPLIER;
            if (!_checkMargin(
                    makerBucket,
                    makerState,
                    makerHead.order.isLong,
                    data.fillSize,
                    data.execPrice,
                    data.makerTotalFee,
                    ctx.cachedPrice,
                    staleImrBp,
                    ctx.marginReqs.mmrBp,
                    ctx.marginReqs.laggedMmrBp
                )) {
                _pushStaleSkipped(result, makerHead.orderId);
                makerHead.remaining = 0;
                return false;
            }
        }
        return true;
    }

    function _aggregateVaultMatch(
        BazaarTypes.BatchResult memory result,
        BazaarTypes.FillResult memory mr,
        VaultMatchData memory data,
        int256 vaultPnl,
        Head memory makerHead
    ) private pure {
        unchecked {
            result.deltaLongOI += mr.longOIDelta;
            result.deltaShortOI += mr.shortOIDelta;
            result.deltaLongWeightedEntry += mr.longWeightedDelta;
            result.deltaShortWeightedEntry += mr.shortWeightedDelta;
            result.totalUserSeqFees += data.makerSeqFee;
            result.totalIntegratorFees += data.makerIntFee;
            result.totalInsuranceFees += data.makerInsFee;
            result.totalVaultPnl += vaultPnl;

            ++result.successCount;
            result.totalMatchedVolume += data.fillNotional; // = Σ fillNotional: VWAP numerator + BatchInfo notional too
            result.totalFillSize += data.fillSize;
            makerHead.remaining -= data.fillSize;
            makerHead.order.filledSize += data.fillSize;
        }
    }

    function _emitVaultMatchEvents(
        BazaarTypes.MatchContext memory ctx,
        Head memory makerHead,
        BazaarTypes.FillResult memory mr,
        VaultMatchData memory data
    ) private {
        emit BazaarTypes.OrderFilled(
            ctx.pairId,
            makerHead.orderId,
            makerHead.order.creator,
            makerHead.order.isLong,
            data.fillSize,
            makerHead.order.filledSize,
            makerHead.remaining,
            data.execPrice,
            data.makerTotalFee,
            makerHead.remaining == 0,
            true
        );
        emit BazaarTypes.PositionModified(
            ctx.pairId,
            makerHead.order.creator,
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

    /// @dev Settle one vault-liquidation match: compute vault PnL (price + funding accrued on the
    ///      inventory from the liquidatees' entries through this close), update gap-EMA
    ///      accumulators, and decrement the pending-liq aggregates proportionally.
    function _settleVaultLiquidation(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.BatchResult memory result,
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
            result.sumLiqGapTimesSize += gapBp * int256(fillSize);
            result.totalLiqFillSize += fillSize;
            ++result.liqCount;

            // Decrement vault aggregate proportionally (entryPortion shared with the PnL above)
            uint256 bkPortion = Math.mulDiv(pairVault.pendingLiqBankruptcyNotional, fillSize, existingSize);
            pairVault.pendingLiqSize = existingSize - fillSize;
            pairVault.pendingLiqEntryNotional -= entryPortion;
            pairVault.pendingLiqBankruptcyNotional -= bkPortion;
        }
    }

    /// @notice Pass B: market vs limit. Limit is ALWAYS maker; market is taker.
    ///         fillPrice = limit's effective price.
    function _matchMarketLimit(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        Head memory longHead,
        Head memory shortHead,
        bool longIsMarket,
        BazaarTypes.MatchContext memory ctx,
        BazaarTypes.BatchResult memory result
    ) private returns (bool) {
        // Maker is the limit side. fillPrice = maker's eff (limit price).
        UserMatchParams memory p;
        p.fillPrice = longIsMarket ? shortHead.effectivePrice : longHead.effectivePrice;
        p.fillSize = longHead.remaining < shortHead.remaining ? longHead.remaining : shortHead.remaining;
        p.makerIsLong = !longIsMarket;
        return _matchUserPair(orders, positionBuckets, userActiveLimitOrders, longHead, shortHead, p, ctx, result);
    }

    /// @notice Pass C: limit vs limit. Maker = older orderId. fillPrice = maker's eff.
    function _matchLimitPair(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        Head memory longHead,
        Head memory shortHead,
        BazaarTypes.MatchContext memory ctx,
        BazaarTypes.BatchResult memory result
    ) private returns (bool) {
        UserMatchParams memory p;
        p.makerIsLong = longHead.orderId <= shortHead.orderId;
        p.fillPrice = p.makerIsLong ? longHead.effectivePrice : shortHead.effectivePrice;
        p.fillSize = longHead.remaining < shortHead.remaining ? longHead.remaining : shortHead.remaining;

        // Capture pre-match aggregate snapshot to detect Pass-C-only updates
        uint256 successBefore = result.successCount;

        bool madeProgress =
            _matchUserPair(orders, positionBuckets, userActiveLimitOrders, longHead, shortHead, p, ctx, result);

        // Pass C-only cross-side update (witness for market-omission challenges)
        if (result.successCount > successBefore) {
            _updatePassCCrossSide(result, longHead.effectivePrice, shortHead.effectivePrice);
        }
        return madeProgress;
    }

    /// @dev Bundle of per-match parameters to keep _matchUserPair's call sites within stack depth.
    struct UserMatchParams {
        uint256 fillSize;
        uint256 fillPrice;
        bool makerIsLong;
    }

    /// @dev Core user-vs-user match (used by Pass B and Pass C). Both heads must be loaded.
    ///      Returns false only when the call made no progress (capacity-truncated fillSize=0).
    function _matchUserPair(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        Head memory longHead,
        Head memory shortHead,
        UserMatchParams memory p,
        BazaarTypes.MatchContext memory ctx,
        BazaarTypes.BatchResult memory result
    ) private returns (bool) {
        uint256 fillSize = p.fillSize;
        uint256 fillPrice = p.fillPrice;
        uint256 fillNotional = Math.mulDiv(fillSize, fillPrice, BazaarTypes.BAZAAR_SCALE);
        // Partial-fill at sequencer-volume-cap boundary: fill as much as fits, defer the rest.
        if (result.totalMatchedVolume + fillNotional > ctx.remainingCapacity) {
            uint256 capRoom = ctx.remainingCapacity > result.totalMatchedVolume
                ? ctx.remainingCapacity - result.totalMatchedVolume
                : 0;
            fillSize = Math.mulDiv(capRoom, BazaarTypes.BAZAAR_SCALE, fillPrice);
            if (fillSize == 0) return false; // capacity rounding pinned to 0 — no progress, signal caller to exit
            fillNotional = Math.mulDiv(fillSize, fillPrice, BazaarTypes.BAZAAR_SCALE);
        }
        if (ctx.isOracleStale) {
            uint256 maxPrice =
                ctx.cachedPrice * (BazaarTypes.BP_SCALE + BazaarTypes.MAX_STALE_DEVIATION_BP) / BazaarTypes.BP_SCALE;
            uint256 minPrice =
                ctx.cachedPrice * (BazaarTypes.BP_SCALE - BazaarTypes.MAX_STALE_DEVIATION_BP) / BazaarTypes.BP_SCALE;
            if (fillPrice > maxPrice || fillPrice < minPrice) {
                // Both orders are legitimately skipped for this batch because executing them
                // would breach the stale price band. Record both in staleSkippedIds so the
                // omission challenge sees a legitimate skip and rejects (symmetric with the
                // stale-IMR skip path below) — otherwise a band-voided order looks like an
                // un-recorded omission and a self-challenge can slash the honest sequencer.
                _pushStaleSkipped(result, longHead.orderId);
                _pushStaleSkipped(result, shortHead.orderId);
                longHead.remaining = 0;
                shortHead.remaining = 0;
                return true;
            }
        }

        BazaarTypes.PositionBucket memory longBucketMem = positionBuckets[longHead.order.creator];
        // Long bucket valued at low (worst-case mark for the long); short bucket at high.
        BazaarTypes.BucketState memory longState =
            BucketLib.calculateState(longBucketMem, ctx.cachedLow, ctx.cachedFundingIdx, ctx.marginReqs);
        BazaarTypes.PositionBucket memory shortBucketMem = positionBuckets[shortHead.order.creator];
        BazaarTypes.BucketState memory shortState =
            BucketLib.calculateState(shortBucketMem, ctx.cachedHigh, ctx.cachedFundingIdx, ctx.marginReqs);

        // Fees
        PairFees memory fees = _computePairFees(
            fillSize,
            fillNotional,
            fillPrice,
            p.makerIsLong,
            longState,
            shortState,
            longBucketMem,
            shortBucketMem,
            longHead.order.integrator != address(0),
            shortHead.order.integrator != address(0),
            ctx
        );

        // === Margin check both sides — fail under normal → auto-cancel that side, return ===
        if (!_checkMargin(
                longBucketMem,
                longState,
                true,
                fillSize,
                fillPrice,
                fees.longTotalFee,
                ctx.cachedPrice,
                ctx.marginReqs.imrBp,
                ctx.marginReqs.mmrBp,
                ctx.marginReqs.laggedMmrBp
            )) {
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, longHead, ctx);
            longHead.remaining = 0;
            return true;
        }
        if (!_checkMargin(
                shortBucketMem,
                shortState,
                false,
                fillSize,
                fillPrice,
                fees.shortTotalFee,
                ctx.cachedPrice,
                ctx.marginReqs.imrBp,
                ctx.marginReqs.mmrBp,
                ctx.marginReqs.laggedMmrBp
            )) {
            _autoCancelOrder(orders, positionBuckets, userActiveLimitOrders, shortHead, ctx);
            shortHead.remaining = 0;
            return true;
        }
        // === Stale-only failure → skip + push to staleSkippedIds ===
        if (ctx.isOracleStale) {
            uint256 staleImrBp = ctx.marginReqs.imrBp * BazaarTypes.STALE_MARGIN_MULTIPLIER;
            if (!_checkMargin(
                    longBucketMem,
                    longState,
                    true,
                    fillSize,
                    fillPrice,
                    fees.longTotalFee,
                    ctx.cachedPrice,
                    staleImrBp,
                    ctx.marginReqs.mmrBp,
                    ctx.marginReqs.laggedMmrBp
                )) {
                _pushStaleSkipped(result, longHead.orderId);
                longHead.remaining = 0;
                return true;
            }
            if (!_checkMargin(
                    shortBucketMem,
                    shortState,
                    false,
                    fillSize,
                    fillPrice,
                    fees.shortTotalFee,
                    ctx.cachedPrice,
                    staleImrBp,
                    ctx.marginReqs.mmrBp,
                    ctx.marginReqs.laggedMmrBp
                )) {
                _pushStaleSkipped(result, shortHead.orderId);
                shortHead.remaining = 0;
                return true;
            }
        }

        // Persist + apply fills
        _persistFill(orders, positionBuckets, userActiveLimitOrders, longHead, fillSize, ctx.currentBlock);
        _persistFill(orders, positionBuckets, userActiveLimitOrders, shortHead, fillSize, ctx.currentBlock);

        BazaarTypes.FillResult memory longResult = _applyFillWithState(
            longHead.order.creator,
            longState,
            true,
            fillSize,
            fillPrice,
            fees.longTotalFee,
            ctx,
            orders,
            positionBuckets
        );
        BazaarTypes.FillResult memory shortResult = _applyFillWithState(
            shortHead.order.creator,
            shortState,
            false,
            fillSize,
            fillPrice,
            fees.shortTotalFee,
            ctx,
            orders,
            positionBuckets
        );

        _aggregateUserMatch(result, longResult, shortResult, fees, fillSize, fillNotional, longHead, shortHead);

        _updateAggregateForOrder(result, longHead.order.orderType, true, longHead.effectivePrice, longHead.orderId);
        _updateAggregateForOrder(result, shortHead.order.orderType, false, shortHead.effectivePrice, shortHead.orderId);

        _accumulateUserPairIntegratorFees(result, longHead, shortHead, fees);

        _emitUserPairEvents(ctx, longHead, shortHead, p, fees, longResult, shortResult, fillSize, fillPrice);
        return true;
    }

    function _aggregateUserMatch(
        BazaarTypes.BatchResult memory result,
        BazaarTypes.FillResult memory longResult,
        BazaarTypes.FillResult memory shortResult,
        PairFees memory fees,
        uint256 fillSize,
        uint256 fillNotional,
        Head memory longHead,
        Head memory shortHead
    ) private pure {
        unchecked {
            result.deltaLongOI += longResult.longOIDelta + shortResult.longOIDelta;
            result.deltaShortOI += longResult.shortOIDelta + shortResult.shortOIDelta;
            result.deltaLongWeightedEntry += longResult.longWeightedDelta + shortResult.longWeightedDelta;
            result.deltaShortWeightedEntry += longResult.shortWeightedDelta + shortResult.shortWeightedDelta;
            result.totalUserSeqFees += fees.longSeqFee + fees.shortSeqFee;
            result.totalIntegratorFees += fees.longIntegratorFee + fees.shortIntegratorFee;
            result.totalInsuranceFees += fees.longInsuranceFee + fees.shortInsuranceFee;

            ++result.successCount;
            result.totalMatchedVolume += fillNotional; // = Σ fillNotional: VWAP numerator + BatchInfo notional too
            result.totalFillSize += fillSize;

            longHead.remaining -= fillSize;
            shortHead.remaining -= fillSize;
            longHead.order.filledSize += fillSize;
            shortHead.order.filledSize += fillSize;
        }
    }

    function _accumulateUserPairIntegratorFees(
        BazaarTypes.BatchResult memory result,
        Head memory longHead,
        Head memory shortHead,
        PairFees memory fees
    ) private pure {
        address longInt = longHead.order.integrator;
        address shortInt = shortHead.order.integrator;
        if (longInt == shortInt) {
            result.integratorCount = _accumulateIntegratorFee(
                result.integratorAccums,
                result.integratorCount,
                longInt,
                fees.longIntegratorFee + fees.shortIntegratorFee
            );
        } else {
            result.integratorCount = _accumulateIntegratorFee(
                result.integratorAccums, result.integratorCount, longInt, fees.longIntegratorFee
            );
            result.integratorCount = _accumulateIntegratorFee(
                result.integratorAccums, result.integratorCount, shortInt, fees.shortIntegratorFee
            );
        }
    }

    function _emitUserPairEvents(
        BazaarTypes.MatchContext memory ctx,
        Head memory longHead,
        Head memory shortHead,
        UserMatchParams memory p,
        PairFees memory fees,
        BazaarTypes.FillResult memory longResult,
        BazaarTypes.FillResult memory shortResult,
        uint256 fillSize,
        uint256 fillPrice
    ) private {
        // (No separate OrdersMatched event: the two OrderFilled emits carry every field it did,
        //  with the maker/taker labeling in isMaker — EIP-170 headroom for this library.)
        emit BazaarTypes.OrderFilled(
            ctx.pairId,
            longHead.orderId,
            longHead.order.creator,
            true,
            fillSize,
            longHead.order.filledSize,
            longHead.remaining,
            fillPrice,
            fees.longTotalFee,
            longHead.remaining == 0,
            p.makerIsLong
        );
        emit BazaarTypes.OrderFilled(
            ctx.pairId,
            shortHead.orderId,
            shortHead.order.creator,
            false,
            fillSize,
            shortHead.order.filledSize,
            shortHead.remaining,
            fillPrice,
            fees.shortTotalFee,
            shortHead.remaining == 0,
            !p.makerIsLong
        );
        emit BazaarTypes.PositionModified(
            ctx.pairId,
            longHead.order.creator,
            longResult.newIsLong,
            longResult.sizeDelta,
            longResult.newSize,
            longResult.newEntryValue,
            longResult.newCollateral,
            fillPrice,
            fees.longTotalFee,
            longResult.realizedPnl
        );
        emit BazaarTypes.PositionModified(
            ctx.pairId,
            shortHead.order.creator,
            shortResult.newIsLong,
            shortResult.sizeDelta,
            shortResult.newSize,
            shortResult.newEntryValue,
            shortResult.newCollateral,
            fillPrice,
            fees.shortTotalFee,
            shortResult.realizedPnl
        );
    }

    /// @dev Compute maker/taker fees for a user-pair match. Maker side gets the rebate-tier
    ///      sequencer fee; taker pays the dynamic taker rate. Insurance fee on taker is
    ///      split between risk-adding and risk-reducing notionals. Integrator fees are
    ///      charged only on orders that carry an integrator address — direct-to-contract
    ///      traders pay no integrator fee.
    function _computePairFees(
        uint256 fillSize,
        uint256 fillNotional,
        uint256 fillPrice,
        bool makerIsLong,
        BazaarTypes.BucketState memory longState,
        BazaarTypes.BucketState memory shortState,
        BazaarTypes.PositionBucket memory longBucket,
        BazaarTypes.PositionBucket memory shortBucket,
        bool longHasIntegrator,
        bool shortHasIntegrator,
        BazaarTypes.MatchContext memory ctx
    ) private pure returns (PairFees memory fees) {
        unchecked {
            uint256 makerSeqFee = (fillNotional * BazaarTypes.MAKER_SEQUENCER_FEE_EBP) / BazaarTypes.EBP_SCALE
                + BazaarTypes.SEQUENCER_FLAT_FEE_PER_SIDE;
            uint256 takerSeqFee = (fillNotional * ctx.takerSequencerFeeEbp) / BazaarTypes.EBP_SCALE
                + BazaarTypes.SEQUENCER_FLAT_FEE_PER_SIDE;
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
                fees.longSeqFee = makerSeqFee;
                fees.longIntegratorFee = makerIntFee;
                fees.longInsuranceFee = makerInsFee;
                fees.shortSeqFee = takerSeqFee;
                fees.shortIntegratorFee = takerIntFee;
                fees.shortInsuranceFee = takerInsFee;
            } else {
                fees.shortSeqFee = makerSeqFee;
                fees.shortIntegratorFee = makerIntFee;
                fees.shortInsuranceFee = makerInsFee;
                fees.longSeqFee = takerSeqFee;
                fees.longIntegratorFee = takerIntFee;
                fees.longInsuranceFee = takerInsFee;
            }
            if (!longHasIntegrator) fees.longIntegratorFee = 0;
            if (!shortHasIntegrator) fees.shortIntegratorFee = 0;
            fees.longTotalFee = fees.longSeqFee + fees.longIntegratorFee + fees.longInsuranceFee;
            fees.shortTotalFee = fees.shortSeqFee + fees.shortIntegratorFee + fees.shortInsuranceFee;
        }
    }

    // ================================================================
    // FILL HELPERS
    // ================================================================

    function _persistFill(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
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
            BazaarTypes.OrderType ot = h.order.orderType;
            if (ot == BazaarTypes.OrderType.Limit || ot == BazaarTypes.OrderType.StopLimit) {
                userActiveLimitOrders[h.order.creator].remove(h.orderId);
            } else if (ot == BazaarTypes.OrderType.Market) {
                positionBuckets[h.order.creator].activeMarketOrderId = 0;
            } else if (ot == BazaarTypes.OrderType.TakeProfit) {
                positionBuckets[h.order.creator].takeProfitOrderId = 0;
            } else if (ot == BazaarTypes.OrderType.StopLoss) {
                positionBuckets[h.order.creator].stopLossOrderId = 0;
            }
        }
    }

    /// @dev Auto-cancel an order — used for self-match, post-only violation, and margin failure.
    ///      Sets canceledBlock, clears the appropriate slot pointer, emits OrderUpdated.
    function _autoCancelOrder(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        Head memory h,
        BazaarTypes.MatchContext memory ctx
    ) private {
        BazaarTypes.Order storage stored = orders[h.orderId];
        stored.canceledBlock = ctx.currentBlock;

        BazaarTypes.OrderType ot = h.order.orderType;
        if (ot == BazaarTypes.OrderType.Limit || ot == BazaarTypes.OrderType.StopLimit) {
            userActiveLimitOrders[h.order.creator].remove(h.orderId);
        } else if (ot == BazaarTypes.OrderType.Market) {
            positionBuckets[h.order.creator].activeMarketOrderId = 0;
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

    /// @dev Push an orderId to the staleSkippedIds buffer (preallocated when isOracleStale).
    function _pushStaleSkipped(BazaarTypes.BatchResult memory result, uint256 orderId) private pure {
        // staleSkippedIds is preallocated to totalIds capacity; safe to write at staleSkippedCount
        result.staleSkippedIds[result.staleSkippedCount] = orderId;
        unchecked {
            ++result.staleSkippedCount;
        }
    }

    // ================================================================
    // MARGIN + APPLY FILL
    // ================================================================

    /// @dev Margin check with explicit imrBp (no internal stale branch — caller passes effective imrBp).
    ///      Uses MMR for risk-reducing fills (existing behavior preserved).
    /// @notice Margin gate for a candidate fill. Classifies the trade by SIZE (open / add / close /
    ///         flip), realizes PnL on closing portions, and applies a one-sided incipient-loss debit
    ///         on fresh exposure. Returns false (caller auto-cancels or stale-skips) on any of:
    ///           - open/add: post-debit collateral < required IMR
    ///           - close/flip: realized loss exceeds collateral (would create bad debt)
    ///           - partial close: post-realization collateral < MMR on the remainder
    ///           - flip: post-close collateral < IMR on residual
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
        // deduction at 0 would under-collect the fee while _finalize still decrements D (and pays out)
        // the full nominal amount — draining the shared deposit pool and eventually bricking the last
        // withdrawer. Reject instead: the caller auto-cancels this order and skips it, so only fills
        // whose fee is fully collectable ever proceed (nominal fee == collected fee thereafter).
        if (state.effectiveCollateral < fee) return false;
        uint256 collateralAfterFee = state.effectiveCollateral - fee;

        uint256 newExposureSize; // size of fresh exposure (drives incipient-loss debit)
        uint256 newTotalNotional; // notional driving IMR/MMR requirement
        uint256 effectiveBp;

        if (bucket.size == 0) {
            // Open from flat
            newExposureSize = fillSize;
            newTotalNotional = Math.mulDiv(fillSize, executionPrice, BazaarTypes.BAZAAR_SCALE);
            effectiveBp = imrBp;
        } else if (bucket.isLong == isLong) {
            // Same-side add
            newExposureSize = fillSize;
            newTotalNotional = state.currentNotional + Math.mulDiv(fillSize, executionPrice, BazaarTypes.BAZAAR_SCALE);
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
            newTotalNotional = Math.mulDiv(newExposureSize, executionPrice, BazaarTypes.BAZAAR_SCALE);
            effectiveBp = imrBp;
        }

        // One-sided incipient PnL on fresh exposure: debit losses, ignore gains
        if (newExposureSize > 0) {
            if (isLong && executionPrice > cachedPrice) {
                uint256 loss = Math.mulDiv(newExposureSize, executionPrice - cachedPrice, BazaarTypes.BAZAAR_SCALE);
                collateralAfterFee = collateralAfterFee > loss ? collateralAfterFee - loss : 0;
            } else if (!isLong && cachedPrice > executionPrice) {
                uint256 loss = Math.mulDiv(newExposureSize, cachedPrice - executionPrice, BazaarTypes.BAZAAR_SCALE);
                collateralAfterFee = collateralAfterFee > loss ? collateralAfterFee - loss : 0;
            }
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
        BazaarTypes.MatchContext memory ctx,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets
    ) internal returns (BazaarTypes.FillResult memory result) {
        BazaarTypes.PositionBucket storage bucket = positionBuckets[user];

        uint256 fillNotional = Math.mulDiv(fillSize, executionPrice, BazaarTypes.BAZAAR_SCALE);
        uint256 originalSize = state.adjustedSize;
        bool originalIsLong = bucket.isLong;

        // _checkMargin guarantees effectiveCollateral >= fee for every fill that reaches here, so this
        // never floored a shortfall away. Kept as a checked subtraction (not unchecked/floored): if the
        // coverage invariant were ever violated it reverts the batch rather than silently under-collecting.
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
                _cancelOversizedTpSl(user, bucket, keep, orders, ctx.pairId, ctx.currentBlock);
            }
        }

        result.newSize = state.adjustedSize;
        result.newEntryValue = state.entryValue;
        result.newCollateral = state.effectiveCollateral;
        result.newIsLong = bucket.isLong;
    }

    function _cancelOversizedTpSl(
        address user,
        BazaarTypes.PositionBucket storage bucket,
        uint256 currentSize,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        bytes32 pairId,
        uint64 currentBlock
    ) internal {
        if (bucket.takeProfitOrderId != 0) {
            BazaarTypes.Order storage tpOrder = orders[bucket.takeProfitOrderId];
            uint256 tpRemaining = tpOrder.size - tpOrder.filledSize;
            if (tpOrder.canceledBlock == 0 && tpOrder.filledBlock == 0 && tpRemaining > currentSize) {
                tpOrder.canceledBlock = currentBlock;
                _emitOrderCanceled(pairId, bucket.takeProfitOrderId, user, tpOrder);
                bucket.takeProfitOrderId = 0;
            }
        }
        if (bucket.stopLossOrderId != 0) {
            BazaarTypes.Order storage slOrder = orders[bucket.stopLossOrderId];
            uint256 slRemaining = slOrder.size - slOrder.filledSize;
            if (slOrder.canceledBlock == 0 && slOrder.filledBlock == 0 && slRemaining > currentSize) {
                slOrder.canceledBlock = currentBlock;
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
    // AGGREGATE UPDATES
    // ================================================================

    /// @dev Update the same-side aggregate for a matched order based on its type.
    function _updateAggregateForOrder(
        BazaarTypes.BatchResult memory result,
        BazaarTypes.OrderType ot,
        bool isLong,
        uint256 effectivePrice,
        uint256 orderId
    ) private pure {
        if (_isOracleDerivedPrice(ot)) {
            _updateMarketAggregate(result, isLong, effectivePrice, orderId);
        } else {
            _updateLimitAggregate(result, isLong, effectivePrice, orderId);
        }
    }

    /// @dev Update worst-priority limit aggregate. For longs: lowest price (or highest id at tie);
    ///      for shorts: highest price (or highest id at tie).
    function _updateLimitAggregate(
        BazaarTypes.BatchResult memory result,
        bool isLong,
        uint256 effectivePrice,
        uint256 orderId
    ) private pure {
        if (isLong) {
            if (effectivePrice < result.lowestLongLimitPrice) {
                result.lowestLongLimitPrice = effectivePrice;
                result.lowestLongLimitId = orderId;
            } else if (effectivePrice == result.lowestLongLimitPrice && orderId > result.lowestLongLimitId) {
                result.lowestLongLimitId = orderId;
            }
        } else {
            if (effectivePrice > result.highestShortLimitPrice) {
                result.highestShortLimitPrice = effectivePrice;
                result.highestShortLimitId = orderId;
            } else if (effectivePrice == result.highestShortLimitPrice && orderId > result.highestShortLimitId) {
                result.highestShortLimitId = orderId;
            }
        }
    }

    function _updateMarketAggregate(
        BazaarTypes.BatchResult memory result,
        bool isLong,
        uint256 effectivePrice,
        uint256 orderId
    ) private pure {
        if (isLong) {
            if (effectivePrice < result.lowestLongMarketPrice) {
                result.lowestLongMarketPrice = effectivePrice;
                result.lowestLongMarketId = orderId;
            } else if (effectivePrice == result.lowestLongMarketPrice && orderId > result.lowestLongMarketId) {
                result.lowestLongMarketId = orderId;
            }
        } else {
            if (effectivePrice > result.highestShortMarketPrice) {
                result.highestShortMarketPrice = effectivePrice;
                result.highestShortMarketId = orderId;
            } else if (effectivePrice == result.highestShortMarketPrice && orderId > result.highestShortMarketId) {
                result.highestShortMarketId = orderId;
            }
        }
    }

    /// @dev Pass-C-only cross-side witnesses. Track best (most-aggressive) limit price on each
    ///      side for market-omission cross-side check.
    function _updatePassCCrossSide(BazaarTypes.BatchResult memory result, uint256 longEff, uint256 shortEff)
        private
        pure
    {
        if (longEff > result.highestLongLimitPriceC) {
            result.highestLongLimitPriceC = longEff;
        }
        if (shortEff < result.lowestShortLimitPriceC) {
            result.lowestShortLimitPriceC = shortEff;
        }
    }

    // ================================================================
    // FINALIZE — vault aggregates, fees, BatchInfo
    // ================================================================

    function _finalize(
        BazaarTypes.Vault storage pairVault,
        mapping(uint256 => bytes32) storage batchHashes,
        BazaarTypes.MatchingState storage matchingState,
        BazaarTypes.MatchContext memory ctx,
        BazaarTypes.BatchResult memory result
    ) private {
        if (result.successCount == 0) {
            // No matches → no batch hash written, no challenge possible against this batch.
            return;
        }

        _updateVaultAggregates(
            pairVault,
            result.deltaLongOI,
            result.deltaShortOI,
            result.deltaLongWeightedEntry,
            result.deltaShortWeightedEntry
        );

        unchecked {
            pairVault.totalCollateralDeposited -= result.totalUserSeqFees + result.totalIntegratorFees
            + result.totalInsuranceFees;
        }

        // Apply Pass A vault PnL through insurance
        if (result.totalVaultPnl > 0) {
            // A vault profit is value flowing from the trader pot to insurance: its counterpart
            // is the surviving opposite side's deepening losses, which they will realize into
            // smaller buckets and withdraw LESS from the deposits ledger. Book it as a D → I
            // TRANSFER — a bare insurance credit raises expectedBalance (I + D) above actual
            // USDC with no cash counterpart, permanently, and enough accumulated vault/netting
            // profits would false-trigger the reason-3 shortfall termination. Capped at D
            // defensively; an uncredited excess errs as unclaimable surplus, never as an
            // unbacked claim.
            uint256 gain = uint256(result.totalVaultPnl);
            uint256 take = gain < pairVault.totalCollateralDeposited ? gain : pairVault.totalCollateralDeposited;
            pairVault.totalCollateralDeposited -= take;
            unchecked {
                pairVault.insuranceFundBalance += take;
            }
        } else if (result.totalVaultPnl < 0) {
            // A vault loss is value flowing from insurance to the trader pot: it is the backing
            // for the surviving counterparties' offsetting gains, which they will realize into
            // bucket collateral and withdraw FROM the deposits ledger. Book it as an I → D
            // TRANSFER (mirroring AdlLib._fundWinnerPnl), not a bare insurance debit — otherwise
            // the deposits ledger drifts below Σ bucket.collateral and the last withdrawers
            // underflow it despite their claims being fully cash-backed. I + D is invariant
            // under the transfer, so Check-3's expected balance is unmoved. The uncovered
            // overrun is unbacked bad debt (claims stay intact, backing is gone): recorded as
            // realized deficit so the post-batch isVaultHealthy terminates the pair.
            uint256 loss = uint256(-result.totalVaultPnl);
            uint256 funded = loss < pairVault.insuranceFundBalance ? loss : pairVault.insuranceFundBalance;
            pairVault.insuranceFundBalance -= funded;
            pairVault.totalCollateralDeposited += funded;
            if (loss > funded) {
                pairVault.deficit += loss - funded;
            }
        }

        // Bug bounty tax
        uint256 bbFromUserSeq = Math.mulDiv(result.totalUserSeqFees, ctx.bugBountyTaxBp, BazaarTypes.BP_SCALE);
        uint256 bbFromIntegrator = Math.mulDiv(result.totalIntegratorFees, ctx.bugBountyTaxBp, BazaarTypes.BP_SCALE);
        uint256 bbFromInsurance = Math.mulDiv(result.totalInsuranceFees, ctx.bugBountyTaxBp, BazaarTypes.BP_SCALE);
        uint256 totalBugBounty = bbFromUserSeq + bbFromIntegrator + bbFromInsurance;

        uint256 netUserSeqFees = result.totalUserSeqFees - bbFromUserSeq;
        uint256 netInsuranceFees = result.totalInsuranceFees - bbFromInsurance;

        if (netInsuranceFees > 0) {
            unchecked {
                pairVault.insuranceFundBalance += netInsuranceFees;
            }
        }

        uint256 seqPayout = netUserSeqFees;

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
        if (seqPayout > 0) {
            if (!_sendUsdcFromContract(ctx.usdc, ctx.sequencer, seqPayout)) {
                unchecked {
                    pairVault.insuranceFundBalance += seqPayout;
                }
            }
        }

        _finalizeIntegratorFees(
            pairVault, ctx.usdc, result.integratorAccums, result.integratorCount, ctx.bugBountyTaxBp
        );

        BazaarTypes.BatchInfo memory info = _buildBatchInfo(ctx, result);

        uint256 batchId = matchingState.nextBatchId;
        unchecked {
            matchingState.nextBatchId = batchId + 1;
        }
        batchHashes[batchId] = keccak256(abi.encode(info));

        emit BazaarTypes.BatchRecorded(ctx.pairId, batchId, ctx.sequencer, info);
    }

    /// @dev Build BatchInfo from result + ctx. Truncates staleSkippedIds via assembly.
    ///      Sentinel (type(uint256).max) for "lowest" aggregates is normalized to 0.
    function _buildBatchInfo(BazaarTypes.MatchContext memory ctx, BazaarTypes.BatchResult memory result)
        private
        view
        returns (BazaarTypes.BatchInfo memory info)
    {
        uint256[] memory finalSkipped = result.staleSkippedIds;
        uint256 skippedCount = result.staleSkippedCount;
        assembly {
            if finalSkipped { mstore(finalSkipped, skippedCount) }
        }
        if (skippedCount == 0) {
            finalSkipped = new uint256[](0);
        }

        info.totalMatchNotional = result.totalMatchedVolume; // same sum — BatchResult keeps one accumulator
        info.oraclePrice = ctx.cachedPrice;
        info.executionBlock = ctx.currentBlock;
        info.observationBlock = ctx.observationBlock;
        info.matchTimestamp = uint64(block.timestamp);
        info.sequencer = ctx.sequencer;
        info.isStale = ctx.isOracleStale;

        info.lowestLongLimitPrice = result.lowestLongLimitPrice == type(uint256).max ? 0 : result.lowestLongLimitPrice;
        info.lowestLongLimitId = result.lowestLongLimitId;
        info.highestShortLimitPrice = result.highestShortLimitPrice;
        info.highestShortLimitId = result.highestShortLimitId;
        info.lowestLongMarketPrice =
            result.lowestLongMarketPrice == type(uint256).max ? 0 : result.lowestLongMarketPrice;
        info.lowestLongMarketId = result.lowestLongMarketId;
        info.highestShortMarketPrice = result.highestShortMarketPrice;
        info.highestShortMarketId = result.highestShortMarketId;
        info.lowestShortLimitPriceC =
            result.lowestShortLimitPriceC == type(uint256).max ? 0 : result.lowestShortLimitPriceC;
        info.highestLongLimitPriceC = result.highestLongLimitPriceC;
        info.staleSkippedIds = finalSkipped;
    }

    // ================================================================
    // VAULT AGGREGATE UPDATE (kept internal; reused by callers)
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
