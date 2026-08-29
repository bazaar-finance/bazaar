// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BucketLib} from "./BucketLib.sol";
import {OrderBookLib} from "./OrderBookLib.sol";

/// @title OrderManagementLib
/// @notice External library for order creation, cancellation, and expiry cleanup.
///         Runs via DELEGATECALL from BazaarPair — has direct storage access.
library OrderManagementLib {
    using EnumerableSet for EnumerableSet.UintSet;

    // -------------------- Constants --------------------

    uint256 internal constant MIN_ORDER_AMOUNT = BazaarTypes.MIN_ORDER_AMOUNT;
    uint256 internal constant MAX_SLIPPAGE_BP = BazaarTypes.MAX_SLIPPAGE_BP;
    uint64 internal constant MIN_ORDER_LIFETIME_BLOCKS = BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS;
    uint64 internal constant MAX_ORDER_LIFETIME_BLOCKS = BazaarTypes.MAX_ORDER_LIFETIME_BLOCKS;
    uint64 internal constant NEVER_EXPIRE_BLOCK = BazaarTypes.NEVER_EXPIRE_BLOCK;

    // -------------------- Errors --------------------

    error OrderManagementLib__InvalidOrderExpiration(uint64 expirationBlock);
    error OrderManagementLib__OrderNotFound(uint256 orderId);
    error OrderManagementLib__OrderIsNotActive(uint256 orderId);
    error OrderManagementLib__OrderAlreadyExpired(uint256 orderId);
    error OrderManagementLib__InsufficientMarginAfterOrder(uint256 marginRatio, uint256 required);
    error OrderManagementLib__RequestorIsNotOrderOwner(uint256 orderId, address requestor);
    error OrderManagementLib__ZeroSize();
    error OrderManagementLib__ZeroLimitPrice();
    error OrderManagementLib__PostOnlyNotAllowed();
    error OrderManagementLib__InvalidTimeInForce();
    error OrderManagementLib__InvalidSlippage(uint256 maxSlippageBp);
    error OrderManagementLib__ZeroTriggerPrice();
    error OrderManagementLib__StopLimitPriceOnWrongSide();
    error OrderManagementLib__InvalidOrderType();
    error OrderManagementLib__NotionalBelowMinimum(uint256 notional, uint256 minimum);
    error OrderManagementLib__NoPositionForTpSl();
    error OrderManagementLib__TpSlMustBeOppositeDirection();
    error OrderManagementLib__TpSlSizeExceedsPosition(uint256 orderSize, uint256 positionSize);
    error OrderManagementLib__TpSlOrderAlreadyExists();
    error OrderManagementLib__TooManyActiveLimitOrders();

    // -------------------- External Functions --------------------

    /// @notice Creates a new order and stores it in the orders mapping. Matching against the
    ///         book happens afterwards in MatchingEngineLib.executeArrival — this function only
    ///         validates and records.
    /// @dev Expiry is absolute-block based. The caller supplies `spec.expirationBlock`, which
    ///      must satisfy: currentBlock + MIN_ORDER_LIFETIME_BLOCKS <= exp <= currentBlock +
    ///      MAX_ORDER_LIFETIME_BLOCKS. TP/SL orders use the NEVER_EXPIRE_BLOCK sentinel. Market
    ///      orders are terminal within their own transaction (the arrival walk fills them and
    ///      cancels any remainder), so they are stamped expired-at-creation for every later
    ///      observer.
    function createOrder(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.CreateOrderParams memory params,
        address caller
    ) external returns (uint256 newNextOrderId) {
        BazaarTypes.OrderSpec memory spec = params.spec;
        if (spec.size == 0) revert OrderManagementLib__ZeroSize();

        // Per-user caps: Limit + StopLimit share the userActiveLimitOrders set with cap = 100,
        // bounding both the exposure-tally iteration and a user's worst-case book footprint.
        // TP/SL are bounded to 1 each per position via takeProfitOrderId/stopLossOrderId.
        // Market orders need no cap: they never rest and are terminal within their own tx.
        BazaarTypes.OrderType ot = spec.orderType;
        if (ot == BazaarTypes.OrderType.Limit || ot == BazaarTypes.OrderType.StopLimit) {
            if (userActiveLimitOrders[caller].length() >= BazaarTypes.MAX_ACTIVE_LIMIT_ORDERS_PER_USER) {
                revert OrderManagementLib__TooManyActiveLimitOrders();
            }
        }

        // IOC is a Limit-only time-in-force and contradicts post-only (one demands an immediate
        // taking fill, the other forbids taking at all). Market/StopLoss are IOC by construction
        // and stops/TP have their own lifecycle, so the flag is meaningless elsewhere.
        if (spec.isIoc && (ot != BazaarTypes.OrderType.Limit || spec.isPostOnly)) {
            revert OrderManagementLib__InvalidTimeInForce();
        }

        uint256 currentPrice = params.currentPrice;
        uint256 orderTriggerPrice = spec.triggerPrice;
        uint256 orderLimitPrice = spec.limitPrice;
        uint256 orderMaxSlippageBp = spec.maxSlippageBp;

        if (ot == BazaarTypes.OrderType.Limit) {
            if (spec.limitPrice == 0) revert OrderManagementLib__ZeroLimitPrice();
            orderMaxSlippageBp = 0;
            orderTriggerPrice = 0;
        } else if (ot == BazaarTypes.OrderType.Market) {
            if (spec.isPostOnly) revert OrderManagementLib__PostOnlyNotAllowed();
            if (spec.maxSlippageBp == 0 || spec.maxSlippageBp > MAX_SLIPPAGE_BP) {
                revert OrderManagementLib__InvalidSlippage(spec.maxSlippageBp);
            }
            orderTriggerPrice = currentPrice;
            orderLimitPrice = 0;
        } else if (ot == BazaarTypes.OrderType.StopLimit) {
            if (spec.isPostOnly) revert OrderManagementLib__PostOnlyNotAllowed();
            if (spec.triggerPrice == 0) revert OrderManagementLib__ZeroTriggerPrice();
            if (spec.limitPrice == 0) revert OrderManagementLib__ZeroLimitPrice();
            // The limit must be on the fillable side of the trigger. The trigger is evaluated
            // against a fresh oracle price (immediately at creation, or by executeTriggeredOrders
            // later; buy fires at price >= trigger, sell at price <= trigger), so a buy with
            // limit < trigger (or a sell with limit > trigger) can never fill: whenever it is
            // triggered the limit is on the wrong side of the market, and whenever the limit
            // would be marketable the trigger is no longer met. Reject these dead configs at
            // creation rather than let them sit consuming exposure.
            if (spec.isLong && spec.limitPrice < spec.triggerPrice) {
                revert OrderManagementLib__StopLimitPriceOnWrongSide();
            }
            if (!spec.isLong && spec.limitPrice > spec.triggerPrice) {
                revert OrderManagementLib__StopLimitPriceOnWrongSide();
            }
            orderMaxSlippageBp = 0;
        } else if (ot == BazaarTypes.OrderType.TakeProfit) {
            // Mirror of StopLoss: a profit target is a trigger order that executes at market once
            // the oracle reaches it, so it carries a trigger and a slippage bound and no limit
            // price. A profit target that must fill at an exact price is a plain Limit order.
            if (spec.isPostOnly) revert OrderManagementLib__PostOnlyNotAllowed();
            if (spec.triggerPrice == 0) revert OrderManagementLib__ZeroTriggerPrice();
            if (spec.maxSlippageBp == 0 || spec.maxSlippageBp > MAX_SLIPPAGE_BP) {
                revert OrderManagementLib__InvalidSlippage(spec.maxSlippageBp);
            }
            orderLimitPrice = 0;
        } else if (ot == BazaarTypes.OrderType.StopLoss) {
            if (spec.isPostOnly) revert OrderManagementLib__PostOnlyNotAllowed();
            if (spec.triggerPrice == 0) revert OrderManagementLib__ZeroTriggerPrice();
            if (spec.maxSlippageBp == 0 || spec.maxSlippageBp > MAX_SLIPPAGE_BP) {
                revert OrderManagementLib__InvalidSlippage(spec.maxSlippageBp);
            }
            orderLimitPrice = 0;
        } else {
            revert OrderManagementLib__InvalidOrderType();
        }

        // Validate minimum order notional (size * price >= MIN_ORDER_AMOUNT)
        // Use limitPrice for Limit orders, triggerPrice for others, fallback to currentPrice for Market orders
        uint256 refPriceForMinCheck =
            orderLimitPrice > 0 ? orderLimitPrice : (orderTriggerPrice > 0 ? orderTriggerPrice : currentPrice);
        uint256 orderNotionalValue = Math.mulDiv(spec.size, refPriceForMinCheck, BazaarTypes.BAZAAR_SCALE);
        if (orderNotionalValue < MIN_ORDER_AMOUNT) {
            // Full-close exemption: an opposite-direction order for exactly the whole position is
            // always creatable, even under the floor — otherwise a position whose notional drifted
            // below MIN_ORDER_AMOUNT could not be closed at market until price recovered. Partial
            // reduces stay floored so sub-minimum residuals can't be minted deliberately.
            BazaarTypes.PositionBucket storage closeBucket = positionBuckets[caller];
            bool isFullClose =
                closeBucket.size > 0 && closeBucket.isLong != spec.isLong && spec.size == closeBucket.size;
            if (!isFullClose) revert OrderManagementLib__NotionalBelowMinimum(orderNotionalValue, MIN_ORDER_AMOUNT);
        }

        // TP/SL orders require an existing position and opposite direction (to close)
        if (ot == BazaarTypes.OrderType.TakeProfit || ot == BazaarTypes.OrderType.StopLoss) {
            BazaarTypes.PositionBucket memory bucket = positionBuckets[caller];
            if (bucket.size == 0) revert OrderManagementLib__NoPositionForTpSl();
            if (bucket.isLong == spec.isLong) revert OrderManagementLib__TpSlMustBeOppositeDirection();
            if (spec.size > bucket.size) {
                revert OrderManagementLib__TpSlSizeExceedsPosition(spec.size, bucket.size);
            }
        }

        BazaarTypes.BucketState memory currentState = BucketLib.calculateState(
            positionBuckets[caller], currentPrice, params.currentFundingIndex, params.marginReqs
        );

        if (ot != BazaarTypes.OrderType.TakeProfit && ot != BazaarTypes.OrderType.StopLoss) {
            BazaarTypes.PositionBucket memory bucket = positionBuckets[caller];

            uint256 executionPrice;
            if (ot == BazaarTypes.OrderType.Limit) {
                executionPrice = orderLimitPrice;
            } else if (ot == BazaarTypes.OrderType.Market) {
                // Both sides margin at the upper slippage bound. The fill price is the maker's,
                // so it isn't known here — maxSlippageBp only states how far from currentPrice
                // the walk may execute. Margining the worst-case notional on both sides keeps a
                // wider tolerance strictly more expensive than a tight one.
                executionPrice = currentPrice * (BazaarTypes.BP_SCALE + orderMaxSlippageBp) / BazaarTypes.BP_SCALE;
            } else {
                executionPrice = orderTriggerPrice > orderLimitPrice ? orderTriggerPrice : orderLimitPrice;
            }

            uint256 orderNotional = Math.mulDiv(spec.size, executionPrice, BazaarTypes.BAZAAR_SCALE);

            uint256 newTotalNotional;
            if (bucket.size == 0) {
                newTotalNotional = orderNotional;
            } else if (bucket.isLong == spec.isLong) {
                newTotalNotional = currentState.currentNotional + orderNotional;
            } else {
                if (orderNotional > currentState.currentNotional) {
                    newTotalNotional = orderNotional - currentState.currentNotional;
                } else {
                    newTotalNotional = currentState.currentNotional - orderNotional;
                }
            }

            {
                uint256 posNotional = newTotalNotional;
                bool posIsLong = bucket.size == 0 ? spec.isLong : bucket.isLong;
                if (bucket.size > 0 && bucket.isLong != spec.isLong && orderNotional > currentState.currentNotional) {
                    posIsLong = spec.isLong;
                }

                uint256 sameDirectionExposure =
                    posIsLong ? params.outstandingLongOrderExposure : params.outstandingShortOrderExposure;
                uint256 oppositeDirectionExposure =
                    posIsLong ? params.outstandingShortOrderExposure : params.outstandingLongOrderExposure;

                uint256 worstCaseExposure = posNotional + sameDirectionExposure;
                uint256 worstCaseFlip =
                    oppositeDirectionExposure > posNotional ? oppositeDirectionExposure - posNotional : 0;
                newTotalNotional = worstCaseExposure > worstCaseFlip ? worstCaseExposure : worstCaseFlip;
            }

            if (newTotalNotional > currentState.currentNotional || bucket.size == 0) {
                uint256 requiredMargin = Math.mulDiv(params.marginReqs.imrBp, newTotalNotional, BazaarTypes.BP_SCALE);

                if (currentState.effectiveCollateral < requiredMargin) {
                    revert OrderManagementLib__InsufficientMarginAfterOrder(
                        currentState.effectiveCollateral, requiredMargin
                    );
                }
            }
        }

        // Block-based expiration.
        // TP/SL never expire; market orders are terminal in their own tx; user-supplied expiry
        // for Limit/StopLimit must fall within [min, max] window.
        uint64 expiryBlock;
        uint64 cb = params.currentBlock;
        if (ot == BazaarTypes.OrderType.TakeProfit || ot == BazaarTypes.OrderType.StopLoss) {
            expiryBlock = NEVER_EXPIRE_BLOCK;
        } else if (ot == BazaarTypes.OrderType.Market) {
            expiryBlock = cb;
        } else {
            uint64 minExp = cb + MIN_ORDER_LIFETIME_BLOCKS;
            uint64 maxExp = cb + MAX_ORDER_LIFETIME_BLOCKS;
            if (spec.expirationBlock < minExp) {
                revert OrderManagementLib__InvalidOrderExpiration(spec.expirationBlock);
            }
            expiryBlock = spec.expirationBlock > maxExp ? maxExp : spec.expirationBlock;
        }

        // create order
        uint256 orderId = params.nextOrderId;
        newNextOrderId = orderId + 1;

        orders[orderId] = BazaarTypes.Order({
            creator: caller,
            integrator: spec.integrator,
            triggerPrice: orderTriggerPrice,
            limitPrice: orderLimitPrice,
            maxSlippageBp: orderMaxSlippageBp,
            size: spec.size,
            filledSize: 0,
            orderType: ot,
            isLong: spec.isLong,
            isPostOnly: spec.isPostOnly,
            isIoc: spec.isIoc,
            inBook: false,
            creationBlock: cb,
            expiryBlock: expiryBlock,
            canceledBlock: 0,
            filledBlock: 0,
            prevInBook: 0,
            nextInBook: 0
        });

        if (ot == BazaarTypes.OrderType.TakeProfit) {
            if (positionBuckets[caller].takeProfitOrderId != 0) revert OrderManagementLib__TpSlOrderAlreadyExists();
            positionBuckets[caller].takeProfitOrderId = orderId;
        } else if (ot == BazaarTypes.OrderType.StopLoss) {
            if (positionBuckets[caller].stopLossOrderId != 0) revert OrderManagementLib__TpSlOrderAlreadyExists();
            positionBuckets[caller].stopLossOrderId = orderId;
        }

        // Limit + StopLimit are tracked together in userActiveLimitOrders for the 100-order cap
        // and for exposure tally during deposit/withdraw margin checks.
        if (ot == BazaarTypes.OrderType.Limit || ot == BazaarTypes.OrderType.StopLimit) {
            userActiveLimitOrders[caller].add(orderId);
        }

        emit BazaarTypes.OrderUpdated(
            params.pairId,
            orderId,
            caller,
            BazaarTypes.OrderUpdatePayload({
                action: BazaarTypes.OrderAction.Created,
                orderType: ot,
                isLong: spec.isLong,
                isPostOnly: spec.isPostOnly,
                size: spec.size,
                filledSize: 0,
                triggerPrice: orderTriggerPrice,
                limitPrice: orderLimitPrice,
                maxSlippageBp: orderMaxSlippageBp,
                canceledBlock: 0,
                filledBlock: 0,
                expiryBlock: expiryBlock,
                creationBlock: cb
            })
        );
    }

    /// @notice Cancel an order — callable by order creator via BazaarPair. Unlinks it from the
    ///         book in the same write, so a canceled order is out of the matching walk's reach
    ///         within its own transaction.
    function cancelOrder(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.OrderBook storage book,
        uint256 orderId,
        bytes32 pairId,
        uint64 currentBlock
    ) external {
        BazaarTypes.Order storage order = orders[orderId];

        if (order.creator == address(0)) revert OrderManagementLib__OrderNotFound(orderId);
        if (order.canceledBlock != 0) revert OrderManagementLib__OrderIsNotActive(orderId);
        if (order.filledBlock != 0) revert OrderManagementLib__OrderIsNotActive(orderId);
        if (currentBlock > order.expiryBlock) revert OrderManagementLib__OrderAlreadyExpired(orderId);

        order.canceledBlock = currentBlock;
        OrderBookLib.unlink(orders, book, orderId);

        // Clear position-bucket order-slot pointer for slot-bound types
        BazaarTypes.OrderType ot = order.orderType;
        if (ot == BazaarTypes.OrderType.TakeProfit) {
            positionBuckets[order.creator].takeProfitOrderId = 0;
        } else if (ot == BazaarTypes.OrderType.StopLoss) {
            positionBuckets[order.creator].stopLossOrderId = 0;
        }

        // Remove from active limit orders set (Limit + StopLimit share this set)
        if (ot == BazaarTypes.OrderType.Limit || ot == BazaarTypes.OrderType.StopLimit) {
            userActiveLimitOrders[order.creator].remove(orderId);
        }

        emit BazaarTypes.OrderUpdated(
            pairId,
            orderId,
            order.creator,
            BazaarTypes.OrderUpdatePayload({
                action: BazaarTypes.OrderAction.Canceled,
                orderType: order.orderType,
                isLong: order.isLong,
                isPostOnly: order.isPostOnly,
                size: order.size,
                filledSize: order.filledSize,
                triggerPrice: order.triggerPrice,
                limitPrice: order.limitPrice,
                maxSlippageBp: order.maxSlippageBp,
                canceledBlock: currentBlock,
                filledBlock: order.filledBlock,
                expiryBlock: order.expiryBlock,
                creationBlock: order.creationBlock
            })
        );
    }

    /// @notice Sweeps a user's active-limit-order set: drops expired/canceled/filled entries
    ///         (cancel-emitting and unlinking expired ones) and totals the remaining directional
    ///         exposure.
    /// @dev Called via BazaarPair's _cleanupExpiredLimitOrders wrapper. Canceled/filled entries
    ///      were already unlinked at their terminal write; only the expired-but-live case still
    ///      holds a book position here.
    function cleanupExpiredLimitOrders(
        EnumerableSet.UintSet storage orderSet,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        bytes32 pairId,
        address user,
        uint64 currentBlock
    ) external returns (uint256 longExposure, uint256 shortExposure) {
        uint256 len = orderSet.length();
        uint256 i;
        while (i < len) {
            uint256 orderId = orderSet.at(i);
            BazaarTypes.Order storage order = orders[orderId];

            bool isExpired = currentBlock > order.expiryBlock;
            bool isCanceled = order.canceledBlock != 0;
            bool isFilled = order.filledBlock != 0;

            if (isExpired || isCanceled || isFilled) {
                if (isExpired && !isCanceled && !isFilled) {
                    order.canceledBlock = currentBlock;
                    OrderBookLib.unlink(orders, book, orderId);
                    emit BazaarTypes.OrderUpdated(
                        pairId,
                        orderId,
                        user,
                        BazaarTypes.OrderUpdatePayload({
                            action: BazaarTypes.OrderAction.Canceled,
                            orderType: order.orderType,
                            isLong: order.isLong,
                            isPostOnly: order.isPostOnly,
                            size: order.size,
                            filledSize: order.filledSize,
                            triggerPrice: order.triggerPrice,
                            limitPrice: order.limitPrice,
                            maxSlippageBp: order.maxSlippageBp,
                            canceledBlock: currentBlock,
                            filledBlock: order.filledBlock,
                            expiryBlock: order.expiryBlock,
                            creationBlock: order.creationBlock
                        })
                    );
                }
                orderSet.remove(orderId);
                len--;
                // don't increment i — the last element was swapped into this index
            } else {
                uint256 remaining = order.size - order.filledSize;
                uint256 notional = Math.mulDiv(remaining, order.limitPrice, BazaarTypes.BAZAAR_SCALE);
                if (order.isLong) {
                    longExposure += notional;
                } else {
                    shortExposure += notional;
                }
                i++;
            }
        }
    }

    /// @notice Permissionless expiry janitor: cancels + unlinks any of the given orders that
    ///         have expired without reaching a terminal state. Non-expired, already-terminal,
    ///         and unknown ids are skipped silently so racing keepers never revert each other.
    /// @dev Expired orders are otherwise removed lazily — by the matching walk on contact or by
    ///      the owner's sweeps during create/withdraw — so this exists to let anyone clear dead
    ///      nodes from the book front proactively. Only Limit/StopLimit can expire (TP/SL carry
    ///      the never-expire sentinel; Market orders are terminal in their creation tx), so the
    ///      set removal below covers every sweepable type.
    function sweepExpired(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.OrderBook storage book,
        uint256[] calldata orderIds,
        bytes32 pairId,
        uint64 currentBlock
    ) external {
        for (uint256 i; i < orderIds.length; ++i) {
            uint256 orderId = orderIds[i];
            BazaarTypes.Order storage order = orders[orderId];
            if (order.creator == address(0)) continue;
            if (order.canceledBlock != 0 || order.filledBlock != 0) continue;
            if (currentBlock <= order.expiryBlock) continue;

            order.canceledBlock = currentBlock;
            OrderBookLib.unlink(orders, book, orderId);
            userActiveLimitOrders[order.creator].remove(orderId);

            emit BazaarTypes.OrderUpdated(
                pairId,
                orderId,
                order.creator,
                BazaarTypes.OrderUpdatePayload({
                    action: BazaarTypes.OrderAction.Canceled,
                    orderType: order.orderType,
                    isLong: order.isLong,
                    isPostOnly: order.isPostOnly,
                    size: order.size,
                    filledSize: order.filledSize,
                    triggerPrice: order.triggerPrice,
                    limitPrice: order.limitPrice,
                    maxSlippageBp: order.maxSlippageBp,
                    canceledBlock: currentBlock,
                    filledBlock: order.filledBlock,
                    expiryBlock: order.expiryBlock,
                    creationBlock: order.creationBlock
                })
            );
        }
    }

    /// @notice Read-only twin of cleanupExpiredLimitOrders: totals the remaining directional
    ///         exposure of a user's active-limit-order set, SKIPPING expired/canceled/filled
    ///         entries instead of pruning them. The liveness test and the summed notional are
    ///         identical, so both functions always report the same totals — the pruning is
    ///         purely lazy hygiene, not semantics.
    /// @dev Reached via BazaarPair.outstandingOrderExposure so off-chain withdrawal previews
    ///      (BazaarPairLens.getMaxWithdrawable) can margin-check against live order exposure
    ///      from an eth_call.
    function outstandingOrderExposure(
        EnumerableSet.UintSet storage orderSet,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        uint64 currentBlock
    ) external view returns (uint256 longExposure, uint256 shortExposure) {
        uint256 len = orderSet.length();
        for (uint256 i = 0; i < len; i++) {
            BazaarTypes.Order storage order = orders[orderSet.at(i)];
            if (currentBlock > order.expiryBlock || order.canceledBlock != 0 || order.filledBlock != 0) {
                continue;
            }
            uint256 notional = Math.mulDiv(order.size - order.filledSize, order.limitPrice, BazaarTypes.BAZAAR_SCALE);
            if (order.isLong) {
                longExposure += notional;
            } else {
                shortExposure += notional;
            }
        }
    }
}
