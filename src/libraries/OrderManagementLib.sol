// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BucketLib} from "./BucketLib.sol";
import {CollateralLib} from "./CollateralLib.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";
import {OrderBookLib} from "./OrderBookLib.sol";

/// @title OrderManagementLib
/// @notice External library for order creation, cancellation, and expiry cleanup.
///         Runs via DELEGATECALL from BazaarPair — has direct storage access.
library OrderManagementLib {
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IERC20;

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
    error OrderManagementLib__LimitPriceOutsidePlacementBand(uint256 limitPrice, uint256 minPrice, uint256 maxPrice);
    error OrderManagementLib__NoPositionForTpSl();
    error OrderManagementLib__TpSlMustBeOppositeDirection();
    error OrderManagementLib__TpSlOrderAlreadyExists();
    error OrderManagementLib__TooManyActiveLimitOrders();
    error OrderManagementLib__BountyOnUntriggeredType();
    error OrderManagementLib__BountyNotWholeUsdc(uint256 bounty);
    /// @notice The batch is empty, not whole triples, longer than MAX_AMENDS_PER_CALL, or an id
    ///         word carries bits above its two hint fields.
    error OrderManagementLib__InvalidAmendBatch();
    /// @notice Only a resting good-till-cancelled Limit order can be amended.
    error OrderManagementLib__NotAmendable(uint256 orderId);
    /// @notice The amended size would not exceed what the order has already filled.
    error OrderManagementLib__AmendSizeNotAboveFilled(uint256 orderId);
    /// @notice The amended price would cross the best resting order on the other side.
    error OrderManagementLib__AmendWouldCross(uint256 orderId, uint256 limitPrice, uint256 oppositeBest);
    /// @notice The amendment would move the order (a new price or a larger size) with less than
    ///         MIN_ORDER_LIFETIME_BLOCKS left before its expiry block: `expiryBlock` is below
    ///         `minExpiryBlock`, the current block plus that floor.
    error OrderManagementLib__AmendTooCloseToExpiry(uint256 orderId, uint64 expiryBlock, uint64 minExpiryBlock);

    /// @dev What the creation margin gate judges a new order by (_requireCreationAffordable):
    ///      the order's validated fields and the pair state they are judged against.
    struct CreationGate {
        BazaarTypes.OrderType orderType;
        bool isLong;
        uint256 size;
        uint256 limitPrice;
        uint256 triggerPrice;
        uint256 maxSlippageBp;
        address integrator;
        uint256 currentPrice;
        uint256 imrBp;
        uint64 currentBlock;
    }

    // -------------------- External Functions --------------------

    /// @notice Creates a new order and stores it in the orders mapping. Matching against the
    ///         book happens afterwards in MatchingEngineLib.executeArrival — this function only
    ///         validates and records. A trigger order's keeper bounty (the high 128 bits of
    ///         `spec.triggerPrice`) is pulled from the creator's wallet here and held in the
    ///         escrow against the order.
    /// @dev Expiry is absolute-block based: the caller supplies `spec.expirationBlock`, which for
    ///      an order that can rest must be at least currentBlock + MIN_ORDER_LIFETIME_BLOCKS; a
    ///      block past currentBlock + MAX_ORDER_LIFETIME_BLOCKS is clamped to that ceiling. An
    ///      order that never rests — Market, and a Limit sent IOC or FOK — ignores the field, as
    ///      does a TP/SL, which never expires; _resolveExpiryBlock carries the per-type rule.
    function createOrder(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        mapping(address => BazaarTypes.RestingTally) storage restingTallies,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.FeeEscrow storage feeEscrow,
        BazaarTypes.CreateOrderParams memory params,
        address caller
    ) external returns (uint256 newNextOrderId) {
        BazaarTypes.OrderSpec memory spec = params.spec;
        BazaarTypes.OrderType ot = spec.orderType;

        // Every order states a size. To close a whole position with a TP/SL, pass a size at or
        // above it — type(uint256).max is the idiom — and the fill path caps it at whatever the
        // position holds when the order fires. There is no zero sentinel: 0 is the one value that
        // can never describe an order.
        if (spec.size == 0) revert OrderManagementLib__ZeroSize();

        // The keeper bounty rides in the high half of the trigger price. It is escrowed from the
        // wallet, never from bucket collateral: collateral backs an open position and leaves only
        // through withdrawCollateral's solvency, retained-cash and IMR gates, and a payment
        // debited from it — by an owner acting as their own keeper — would be a second exit that
        // skips all three. A wallet pull touches neither the bucket nor the deposits ledger, so
        // the bounty needs no margin gate and a stop on a thin account still pays its executor.
        // Pulled here, ahead of the validation below, so a later revert unwinds it; every trigger
        // type reaches the escrow, and any other type must leave the field clear so a mistaken
        // amount cannot be pulled for an order that can never pay it out. The pull converts to
        // USDC's six decimals, so the amount must be whole at that resolution or the escrow would
        // record cash that was never received.
        {
            uint256 bounty = spec.triggerPrice >> 128;
            if (bounty != 0) {
                if (
                    ot != BazaarTypes.OrderType.StopLimit && ot != BazaarTypes.OrderType.StopLoss
                        && ot != BazaarTypes.OrderType.TakeProfit
                ) revert OrderManagementLib__BountyOnUntriggeredType();
                if (bounty % 1e12 != 0) revert OrderManagementLib__BountyNotWholeUsdc(bounty);
                IERC20(params.usdc).safeTransferFrom(caller, address(this), bounty / 1e12);
                FeeEscrowLib.escrowBounty(feeEscrow, params.pairId, params.nextOrderId, bounty);
            }
        }

        // Per-user caps: the Limit and StopLimit orders that can rest share the
        // userActiveLimitOrders set, capped at MAX_ACTIVE_LIMIT_ORDERS_PER_USER to bound both the
        // exposure-tally iteration and a user's worst-case book footprint.
        // TP/SL are bounded to 1 each per position via takeProfitOrderId/stopLossOrderId.
        // An order that never rests — Market, and a Limit sent IOC or FOK — is terminal within
        // its own transaction and never joins the set, so gating it on the set's occupancy would
        // deny a user at the cap an order that cannot add to either quantity the cap bounds.
        // A full set is pruned of expired, canceled and filled entries before the cap is judged,
        // the one case a dead entry costs its owner anything. Below the cap the set is left as it
        // is: the margin gate reads it only when the tally's bound does not clear this order, and
        // skips dead entries itself, so an expired order the owner has not canceled is removed by
        // the next walk that reaches it, a sweep, or a withdrawal.
        if (_joinsActiveSet(ot, spec.tif)) {
            EnumerableSet.UintSet storage activeSet = userActiveLimitOrders[caller];
            if (activeSet.length() >= BazaarTypes.MAX_ACTIVE_LIMIT_ORDERS_PER_USER) {
                _pruneExpired(activeSet, orders, book, params.pairId, params.currentBlock);
                if (activeSet.length() >= BazaarTypes.MAX_ACTIVE_LIMIT_ORDERS_PER_USER) {
                    revert OrderManagementLib__TooManyActiveLimitOrders();
                }
            }
        }

        // Both non-default time-in-force values demand an immediate taking fill, which post-only
        // forbids outright, so neither may accompany it.
        //
        // IOC is Limit-only: Market/StopLoss are IOC by construction, and the stop types rest
        // outside the book awaiting a trigger rather than crossing on arrival, so asking them to
        // cancel an arrival remainder describes nothing.
        //
        // FOK additionally admits Market, because a Bazaar market order is bounded by
        // maxSlippageBp rather than unbounded — "all of it, within my tolerance, or none" is a
        // real instruction. It stays off the other three for the same reason IOC does, plus one
        // of its own: a TP/SL caps its size against the live position when it fires, so "the
        // entire amount" names no fixed quantity to be all-or-none about.
        if (spec.tif != BazaarTypes.TimeInForce.GTC) {
            if (spec.isPostOnly) revert OrderManagementLib__InvalidTimeInForce();
            bool typeOk = ot == BazaarTypes.OrderType.Limit
                || (spec.tif == BazaarTypes.TimeInForce.FOK && ot == BazaarTypes.OrderType.Market);
            if (!typeOk) revert OrderManagementLib__InvalidTimeInForce();
        }

        uint256 currentPrice = params.currentPrice;
        uint256 orderTriggerPrice = uint256(uint128(spec.triggerPrice)); // the bounty above it is not a price
        uint256 orderLimitPrice = spec.limitPrice;
        uint256 orderMaxSlippageBp = spec.maxSlippageBp;

        if (ot == BazaarTypes.OrderType.Limit) {
            if (spec.limitPrice == 0) revert OrderManagementLib__ZeroLimitPrice();
            // Placement sanity band (see MAX_PLACEMENT_DEVIATION_BP). StopLimit is exempt: its
            // limit anchors to its trigger, not to the mark at creation, and wrong-side configs
            // are rejected in its own branch.
            {
                uint256 bandLo = currentPrice * (BazaarTypes.BP_SCALE - BazaarTypes.MAX_PLACEMENT_DEVIATION_BP)
                    / BazaarTypes.BP_SCALE;
                uint256 bandHi = currentPrice * (BazaarTypes.BP_SCALE + BazaarTypes.MAX_PLACEMENT_DEVIATION_BP)
                    / BazaarTypes.BP_SCALE;
                if (spec.limitPrice < bandLo || spec.limitPrice > bandHi) {
                    revert OrderManagementLib__LimitPriceOutsidePlacementBand(spec.limitPrice, bandLo, bandHi);
                }
            }
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
            if (orderTriggerPrice == 0) revert OrderManagementLib__ZeroTriggerPrice();
            if (spec.limitPrice == 0) revert OrderManagementLib__ZeroLimitPrice();
            // The limit must be on the fillable side of the trigger. The trigger is evaluated
            // against a fresh oracle price (immediately at creation, or by executeTriggeredOrders
            // later; buy fires at price >= trigger, sell at price <= trigger), so a buy with
            // limit < trigger (or a sell with limit > trigger) can never fill: whenever it is
            // triggered the limit is on the wrong side of the market, and whenever the limit
            // would be marketable the trigger is no longer met. Reject these dead configs at
            // creation rather than let them sit consuming exposure.
            if (spec.isLong && spec.limitPrice < orderTriggerPrice) {
                revert OrderManagementLib__StopLimitPriceOnWrongSide();
            }
            if (!spec.isLong && spec.limitPrice > orderTriggerPrice) {
                revert OrderManagementLib__StopLimitPriceOnWrongSide();
            }
            orderMaxSlippageBp = 0;
        } else if (ot == BazaarTypes.OrderType.TakeProfit) {
            // Mirror of StopLoss: a profit target is a trigger order that executes at market once
            // the oracle reaches it, so it carries a trigger and a slippage bound and no limit
            // price. A profit target that must fill at an exact price is a plain Limit order.
            if (spec.isPostOnly) revert OrderManagementLib__PostOnlyNotAllowed();
            if (orderTriggerPrice == 0) revert OrderManagementLib__ZeroTriggerPrice();
            if (spec.maxSlippageBp == 0 || spec.maxSlippageBp > MAX_SLIPPAGE_BP) {
                revert OrderManagementLib__InvalidSlippage(spec.maxSlippageBp);
            }
            orderLimitPrice = 0;
        } else if (ot == BazaarTypes.OrderType.StopLoss) {
            if (spec.isPostOnly) revert OrderManagementLib__PostOnlyNotAllowed();
            if (orderTriggerPrice == 0) revert OrderManagementLib__ZeroTriggerPrice();
            if (spec.maxSlippageBp == 0 || spec.maxSlippageBp > MAX_SLIPPAGE_BP) {
                revert OrderManagementLib__InvalidSlippage(spec.maxSlippageBp);
            }
            orderLimitPrice = 0;
        } else {
            revert OrderManagementLib__InvalidOrderType();
        }

        // TP/SL require an existing position and the opposite direction, so they can only ever
        // reduce it. The size is deliberately NOT bounded by the position here: it is capped
        // against the live position when the order fires, which is the only moment the cap can
        // be correct. Bounding it at creation would reject an order that is merely sized for a
        // position the owner intends to grow, while still not covering the case that matters —
        // a position that shrinks afterwards.
        //
        // This must stay AHEAD of the notional floor: that check clamps a TP/SL's size to the
        // position, so with no position it computes a zero notional and would report
        // NotionalBelowMinimum for what is really a missing position.
        if (ot == BazaarTypes.OrderType.TakeProfit || ot == BazaarTypes.OrderType.StopLoss) {
            BazaarTypes.PositionBucket memory bucket = positionBuckets[caller];
            if (bucket.size == 0) revert OrderManagementLib__NoPositionForTpSl();
            if (bucket.isLong == spec.isLong) revert OrderManagementLib__TpSlMustBeOppositeDirection();
        }

        // Validate minimum order notional (size * price >= MIN_ORDER_AMOUNT)
        // Use limitPrice for Limit orders, triggerPrice for others, fallback to currentPrice for Market orders
        uint256 refPriceForMinCheck =
            orderLimitPrice > 0 ? orderLimitPrice : (orderTriggerPrice > 0 ? orderTriggerPrice : currentPrice);
        // A TP/SL is judged on what it could actually close, not on the number written: it caps
        // at the position when it fires, and callers are expected to pass type(uint256).max to
        // mean "all of it". Multiplying that raw would overflow the notional and revert, turning
        // the documented close-everything idiom into an uncreatable order.
        uint256 sizeForMinCheck = spec.size;
        if (ot == BazaarTypes.OrderType.TakeProfit || ot == BazaarTypes.OrderType.StopLoss) {
            uint256 tpSlPosSize = positionBuckets[caller].size;
            if (sizeForMinCheck > tpSlPosSize) sizeForMinCheck = tpSlPosSize;
        }
        uint256 orderNotionalValue = Math.mulDiv(sizeForMinCheck, refPriceForMinCheck, BazaarTypes.BAZAAR_SCALE);
        if (orderNotionalValue < MIN_ORDER_AMOUNT) {
            // Full-close exemption: an opposite-direction order for exactly the whole position is
            // always creatable, even under the floor — otherwise a position whose notional drifted
            // below MIN_ORDER_AMOUNT could not be closed at market until price recovered. Partial
            // reduces stay floored like any other order. The floor bounds orders, not positions: a
            // reduce sized just under the position, or a small partial fill of a resting order,
            // still leaves a position below MIN_ORDER_AMOUNT, which is why the flat keeper payouts
            // for such a position are limited to what it holds itself (LiquidationLib.flatReward,
            // CollateralLib._paySettlementTip). The comparison uses the capped size so an
            // oversized TP/SL still reads as a full close.
            BazaarTypes.PositionBucket storage closeBucket = positionBuckets[caller];
            bool isFullClose =
                closeBucket.size > 0 && closeBucket.isLong != spec.isLong && sizeForMinCheck == closeBucket.size;
            if (!isFullClose) revert OrderManagementLib__NotionalBelowMinimum(orderNotionalValue, MIN_ORDER_AMOUNT);
        }

        BazaarTypes.BucketState memory currentState = BucketLib.calculateState(
            positionBuckets[caller], currentPrice, params.currentFundingIndex, params.marginReqs
        );

        if (ot != BazaarTypes.OrderType.TakeProfit && ot != BazaarTypes.OrderType.StopLoss) {
            _requireCreationAffordable(
                userActiveLimitOrders[caller],
                orders,
                restingTallies[caller],
                positionBuckets[caller],
                currentState,
                CreationGate({
                    orderType: ot,
                    isLong: spec.isLong,
                    size: spec.size,
                    limitPrice: orderLimitPrice,
                    triggerPrice: orderTriggerPrice,
                    maxSlippageBp: orderMaxSlippageBp,
                    integrator: spec.integrator,
                    currentPrice: currentPrice,
                    imrBp: params.marginReqs.imrBp,
                    currentBlock: params.currentBlock
                })
            );
        }

        // params.currentBlock is read at each use rather than cached in a local: createOrder's
        // tail runs at the via-IR stack limit, and `params` is live across it regardless.
        uint64 expiryBlock = _resolveExpiryBlock(ot, spec.tif, spec.expirationBlock, params.currentBlock);

        // create order
        uint256 orderId = params.nextOrderId;
        newNextOrderId = orderId + 1;

        // Narrow to the packed field widths. Prices and non-close-only sizes revert on
        // overflow (any value near 2^128 is unusable protocol-wide anyway — the notional math
        // overflows first). A TP/SL size CLAMPS instead: type(uint256).max is the documented
        // close-everything idiom, and the fill path caps the order at the live position when it
        // fires, so any stored size at or above the position means exactly "all of it".
        uint256 storedSize = spec.size;
        if (ot == BazaarTypes.OrderType.TakeProfit || ot == BazaarTypes.OrderType.StopLoss) {
            if (storedSize > type(uint128).max) storedSize = type(uint128).max;
        }

        orders[orderId] = BazaarTypes.Order({
            creator: caller,
            integrator: spec.integrator,
            triggerPrice: SafeCast.toUint128(orderTriggerPrice),
            limitPrice: SafeCast.toUint128(orderLimitPrice),
            maxSlippageBp: SafeCast.toUint24(orderMaxSlippageBp),
            size: SafeCast.toUint128(storedSize),
            filledSize: 0,
            orderType: ot,
            isLong: spec.isLong,
            isPostOnly: spec.isPostOnly,
            tif: spec.tif,
            inBook: false,
            // Queue position: the id itself until an amend moves the order or a keeper arms a
            // StopLimit (BazaarTypes.Order).
            prioritySeq: uint48(orderId),
            expiryBlock: expiryBlock,
            canceledBlock: 0,
            filledBlock: 0,
            restedBlock: 0,
            restedPremiumPpm: 0,
            prevInBook: 0,
            nextInBook: 0
        });

        if (ot == BazaarTypes.OrderType.TakeProfit) {
            if (positionBuckets[caller].takeProfitOrderId != 0) revert OrderManagementLib__TpSlOrderAlreadyExists();
            // orderIds come from the pair's monotonic counter starting at 1; 2^64 is unreachable.
            positionBuckets[caller].takeProfitOrderId = uint64(orderId);
        } else if (ot == BazaarTypes.OrderType.StopLoss) {
            if (positionBuckets[caller].stopLossOrderId != 0) revert OrderManagementLib__TpSlOrderAlreadyExists();
            positionBuckets[caller].stopLossOrderId = uint64(orderId);
        }

        // An order that can rest joins userActiveLimitOrders, which carries the per-user cap and
        // the resting-order reserve that the creation, amendment and withdrawal margin checks
        // tally, and is recorded at its whole size in the set's tally: what fills in the walk
        // that follows leaves the tally above the set, which is the side it must err on
        // (BazaarTypes.RestingTally).
        if (_joinsActiveSet(ot, spec.tif)) {
            userActiveLimitOrders[caller].add(orderId);
            CollateralLib._tallyAdd(
                restingTallies[caller], spec.isLong, ot == BazaarTypes.OrderType.StopLimit, spec.size, orderLimitPrice
            );
        }

        OrderBookLib.emitOrderUpdated(
            params.pairId, orderId, orders[orderId], BazaarTypes.OrderAction.Created, BazaarTypes.CancelReason.None
        );
    }

    /// @notice Cancel an order — callable by order creator via BazaarPair. Unlinks it from the
    ///         book in the same write, so a canceled order is out of the matching walk's reach
    ///         within its own transaction, and returns whatever keeper bounty it still holds to
    ///         the owner's claimable balance.
    /// @dev An order that is already terminal or expired cannot be canceled again, but it may
    ///      still hold a bounty: the walk's auto-cancels, the TP/SL fence, a liquidation or a
    ///      deleverage stamp an order terminal without touching the escrow, and expiry needs no
    ///      write at all. For such an order this call refunds the bounty instead of reverting,
    ///      so the owner always has one route to it — including after the pair terminates, when
    ///      the permissionless sweep is closed.
    function cancelOrder(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        mapping(address => BazaarTypes.RestingTally) storage restingTallies,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.FeeEscrow storage feeEscrow,
        uint256 orderId,
        bytes32 pairId,
        uint64 currentBlock
    ) external {
        BazaarTypes.Order storage order = orders[orderId];

        if (order.creator == address(0)) revert OrderManagementLib__OrderNotFound(orderId);
        if (order.canceledBlock != 0 || order.filledBlock != 0 || currentBlock > order.expiryBlock) {
            if (feeEscrow.bounty[orderId] != 0) {
                FeeEscrowLib.refundBounty(feeEscrow, pairId, orderId, order.creator);
                return;
            }
            if (currentBlock > order.expiryBlock && order.canceledBlock == 0 && order.filledBlock == 0) {
                revert OrderManagementLib__OrderAlreadyExpired(orderId);
            }
            revert OrderManagementLib__OrderIsNotActive(orderId);
        }

        BazaarTypes.OrderType ot = order.orderType;
        // Read ahead of the unlink, which clears inBook: a StopLimit still outside the book is
        // one the set's tally counts as waiting.
        bool waitingStop = ot == BazaarTypes.OrderType.StopLimit && !order.inBook;

        order.canceledBlock = currentBlock;
        OrderBookLib.unlink(orders, book, orderId);
        FeeEscrowLib.refundBounty(feeEscrow, pairId, orderId, order.creator);

        // Clear position-bucket order-slot pointer for slot-bound types
        if (ot == BazaarTypes.OrderType.TakeProfit) {
            positionBuckets[order.creator].takeProfitOrderId = 0;
        } else if (ot == BazaarTypes.OrderType.StopLoss) {
            positionBuckets[order.creator].stopLossOrderId = 0;
        }

        // Remove from active limit orders set (Limit + StopLimit share this set), and take the
        // remaining leg out of the set's tally so an owner who cancels and requotes keeps a
        // tally the next gate can bound from.
        if (ot == BazaarTypes.OrderType.Limit || ot == BazaarTypes.OrderType.StopLimit) {
            userActiveLimitOrders[order.creator].remove(orderId);
            CollateralLib._tallySub(
                restingTallies[order.creator],
                order.isLong,
                waitingStop,
                order.size - order.filledSize,
                order.limitPrice
            );
        }

        OrderBookLib.emitOrderUpdated(
            pairId, orderId, order, BazaarTypes.OrderAction.Canceled, BazaarTypes.CancelReason.Owner
        );
    }

    /// @notice Sweeps a user's active-limit-order set: drops expired/canceled/filled entries,
    ///         cancel-emitting and unlinking expired ones. What survives is reserved by the gate
    ///         that follows (CollateralLib._sweepRestingReserve), never here: the sweep runs
    ///         before the pair resolves a price, since what it leaves decides whether one is
    ///         needed.
    /// @dev Called via BazaarPair's _cleanupExpiredLimitOrders wrapper. Canceled/filled entries
    ///      were already unlinked at their terminal write; only the expired-but-live case still
    ///      holds a book position here.
    function cleanupExpiredLimitOrders(
        EnumerableSet.UintSet storage orderSet,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        bytes32 pairId,
        uint64 currentBlock
    ) external {
        _pruneExpired(orderSet, orders, book, pairId, currentBlock);
    }

    /// @notice Amends the caller's resting limit orders in place. Each amendment gives one order
    ///         a new price and size; the order keeps its id, its expiry, its integrator and its
    ///         place in the owner's order set. A new price, or a larger size, moves the order to
    ///         the back of its new price level; a smaller size at the same price keeps its place.
    ///         The batch is all or nothing: any amendment that fails reverts the call.
    /// @dev Called via DELEGATECALL. The caller resolves the mark, refreshes the margin curve and
    ///      handles the relayer fee; nothing here moves USDC.
    ///
    ///      An amendment never crosses the book. A price at or through the best resting order on
    ///      the other side would make the order a taker — a walk, taker fees and fill gates, the
    ///      arrival path in all but name — so it is refused and the caller sends a taker order
    ///      instead. The same refusal keeps a post-only order post-only and rules out a
    ///      self-match, since an order that crosses nothing can meet nothing, its owner's orders
    ///      included. Only the head of the other side is consulted: it is the best price there,
    ///      and an expired order still linked at the head is removed by the next walk that
    ///      touches it, not here.
    ///
    ///      Margin is judged once, on the set the batch leaves behind: the orders are reserved
    ///      exactly as createOrder reserves them (CollateralLib._orderReserve), and the position
    ///      plus that exposure has to clear initial margin together with the fill gate's debit
    ///      across the set and the position's unrealized loss (_requireAmendedSetAffordable).
    ///      The set's tally bounds that reservation first; the owner's expired orders are pruned
    ///      and every survivor read only when the bound does not clear the owner. Only the final
    ///      set has to pass: intermediate states inside the batch cannot be observed.
    ///
    ///      An amendment that moves an order needs MIN_ORDER_LIFETIME_BLOCKS of the order's life
    ///      left, the floor createOrder holds a new order to, so the order stands open to fills at
    ///      its new place for that long before it can expire into a dead node a later walk spends a
    ///      step removing. A smaller size at the same price needs only that the order has not
    ///      expired: it stays where it has stood.
    ///
    ///      Queue positions are drawn from the pair's id counter in batch order, so two
    ///      amendments landing on one level queue in the order the caller listed them, and no
    ///      value is ever shared between an order's id and another's position.
    ///
    ///      A move whose new price and queue position still sort between the order's current
    ///      neighbours is written where the order stands (OrderBookLib.staysInPlace): a side is
    ///      strictly sorted and no two orders share a queue position, so an unlink and an insert
    ///      would resolve to the same slot and rebuild the same links, head and count, and the
    ///      order's exposure stamps are restarted as a link restarts them. Only a move that
    ///      changes the order's neighbours relinks it; a move onto a level another order rests at
    ///      always does, since the fresh queue position puts the order behind every order there.
    ///
    ///      A relinked order is placed from up to two predecessor hints the caller packs into the
    ///      id word, with its old neighbours as fallback candidates. OrderBookLib.locate verifies
    ///      every candidate against the real neighbours before linking, so a hint can fail a
    ///      placement, never misplace an order; an exact candidate resolves without a walk, and
    ///      otherwise the repair walk starts from the first live one. The caller's hints lead, so
    ///      a jump across the book walks from where the caller says the slot is, and a requote by a
    ///      few ticks needs no hint because the old neighbours sit within a few nodes of the slot.
    ///      A slot further than MAX_WALK_STEPS nodes from that first live candidate is refused
    ///      (OrderBookLib__HintRepairExhausted) and is a cancel and a new order. The hints travel
    ///      inside the signed words, so a relayer cannot refresh them.
    /// @param orders The pair's order storage
    /// @param positionBuckets Storage mapping of position buckets
    /// @param userActiveLimitOrders Per-user active Limit/StopLimit order sets
    /// @param book The pair's book heads/counts
    /// @param marginReqs The pair's stored margin requirements, as createOrder's gate reads them
    /// @param lastPairPrice The pair's stored price, whose age decides whether a relinked order's
    ///        far-side premium is stamped against `params.currentPrice` or not at all
    ///        (BazaarTypes.Order.restedPremiumPpm)
    /// @param amends The batch as triples of words, in order: each amendment's id word — the
    ///        order id in bits 0-63, optional predecessor hints in bits 64-127 and 128-191 (the
    ///        order to rest directly behind at the new price, 0 for none), bits 192-255 zero —
    ///        then its new price and its new total size (the filled size stays, so the size must
    ///        exceed it)
    /// @param params Pair state the amendments are judged against (BazaarTypes.AmendOrdersParams)
    /// @param caller The acting user; every order must be theirs
    /// @return newNextOrderId The id counter after the queue positions drawn here
    function amendOrders(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        mapping(address => BazaarTypes.RestingTally) storage restingTallies,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.MarginRequirements storage marginReqs,
        BazaarTypes.PairPrice storage lastPairPrice,
        uint256[] calldata amends,
        BazaarTypes.AmendOrdersParams memory params,
        address caller
    ) external returns (uint256 newNextOrderId) {
        uint256 n = amends.length / 3;
        if (n == 0 || n > BazaarTypes.MAX_AMENDS_PER_CALL || amends.length % 3 != 0) {
            revert OrderManagementLib__InvalidAmendBatch();
        }
        // A relink stamps its far-side premium only against an index no older than
        // MAX_PRICE_STALENESS, the age test the pair's mark gate keys on: an older stored price
        // (the stale fallback) is from an earlier moment, and the quote was not on offer at the
        // distance it reads from it.
        uint256 stampIndex =
            lastPairPrice.updateTs + BazaarTypes.MAX_PRICE_STALENESS < block.timestamp ? 0 : params.currentPrice;
        newNextOrderId = params.nextOrderId;
        for (uint256 i; i < n; ++i) {
            uint256 at = 3 * i;
            newNextOrderId = _amendOne(
                orders,
                book,
                positionBuckets[caller],
                restingTallies[caller],
                amends[at],
                amends[at + 1],
                amends[at + 2],
                params,
                caller,
                newNextOrderId,
                stampIndex
            );
        }

        // The gate runs on the set as the batch leaves it, each order reserved against the mark
        // as createOrder reserves a new one.
        _requireAmendedSetAffordable(
            userActiveLimitOrders[caller],
            orders,
            book,
            restingTallies[caller],
            positionBuckets[caller],
            marginReqs,
            params
        );
    }

    /// @dev One amendment: validate, then rewrite the order in place and, when its slot does not
    ///      survive the new price and queue position, relink it. A move stamps the order's far-side
    ///      premium against `stampIndex` (0: none) either way. Returns the id counter after any
    ///      queue position drawn.
    function _amendOne(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.PositionBucket storage bucket,
        BazaarTypes.RestingTally storage tally,
        uint256 idWord,
        uint256 newPrice,
        uint256 newSize,
        BazaarTypes.AmendOrdersParams memory params,
        address caller,
        uint256 seqCounter,
        uint256 stampIndex
    ) private returns (uint256) {
        // The id word carries the order id in its low 64 bits and two optional predecessor hints
        // above it; the top 64 bits must be clear so one amendment has exactly one encoding.
        if (idWord >> 192 != 0) revert OrderManagementLib__InvalidAmendBatch();
        uint256 orderId = idWord & type(uint64).max;
        BazaarTypes.Order storage o = orders[orderId];
        if (o.creator == address(0)) revert OrderManagementLib__OrderNotFound(orderId);
        if (o.creator != caller) revert OrderManagementLib__RequestorIsNotOrderOwner(orderId, caller);
        // Only a resting good-till-cancelled Limit order has a price and a queue position to amend.
        // Trigger orders wait outside the book with a bounty and position links of their own, and
        // IOC/FOK orders never rest; each of those is a cancel and a create.
        if (o.orderType != BazaarTypes.OrderType.Limit || o.tif != BazaarTypes.TimeInForce.GTC) {
            revert OrderManagementLib__NotAmendable(orderId);
        }
        if (o.canceledBlock != 0 || o.filledBlock != 0 || !o.inBook) {
            revert OrderManagementLib__OrderIsNotActive(orderId);
        }
        if (params.currentBlock > o.expiryBlock) revert OrderManagementLib__OrderAlreadyExpired(orderId);

        if (newPrice == 0) revert OrderManagementLib__ZeroLimitPrice();
        {
            // The same placement band a new Limit order is held to.
            uint256 bandLo = params.currentPrice * (BazaarTypes.BP_SCALE - BazaarTypes.MAX_PLACEMENT_DEVIATION_BP)
                / BazaarTypes.BP_SCALE;
            uint256 bandHi = params.currentPrice * (BazaarTypes.BP_SCALE + BazaarTypes.MAX_PLACEMENT_DEVIATION_BP)
                / BazaarTypes.BP_SCALE;
            if (newPrice < bandLo || newPrice > bandHi) {
                revert OrderManagementLib__LimitPriceOutsidePlacementBand(newPrice, bandLo, bandHi);
            }
        }
        uint256 filled = o.filledSize;
        if (newSize <= filled) revert OrderManagementLib__AmendSizeNotAboveFilled(orderId);
        {
            // The remainder is held to the notional floor like a new order, with the same
            // full-close exemption.
            uint256 remaining = newSize - filled;
            uint256 notional = Math.mulDiv(remaining, newPrice, BazaarTypes.BAZAAR_SCALE);
            if (notional < MIN_ORDER_AMOUNT) {
                bool isFullClose = bucket.size > 0 && bucket.isLong != o.isLong && remaining == bucket.size;
                if (!isFullClose) revert OrderManagementLib__NotionalBelowMinimum(notional, MIN_ORDER_AMOUNT);
            }
        }
        {
            uint64 best = o.isLong ? book.askHead : book.bidHead;
            if (best != 0) {
                uint256 bestPrice = orders[best].limitPrice;
                if (o.isLong ? newPrice >= bestPrice : newPrice <= bestPrice) {
                    revert OrderManagementLib__AmendWouldCross(orderId, newPrice, bestPrice);
                }
            }
        }

        bool repriced = newPrice != o.limitPrice;
        bool grew = newSize > o.size;
        if (!repriced && newSize == o.size) return seqCounter; // nothing changes, nothing to report
        // The old leg leaves the set's tally before the order is rewritten and the new one joins
        // it after, so the tally never drops below the set (BazaarTypes.RestingTally).
        CollateralLib._tallySub(tally, o.isLong, false, o.size - filled, o.limitPrice);
        if (!repriced && !grew) {
            // A smaller size at the same price keeps its place: it takes nothing from anyone
            // queued behind it. Below the stored size, so inside the field.
            o.size = uint128(newSize);
        } else {
            // A move is a new claim on the book, and every move must leave the order the lifetime
            // a new one is created with. Without the floor an order could rest deep in the book
            // and move to the front in its last live block: one block later it is a dead node at
            // the head, which the next walk spends a step removing, so a wall of them could
            // exhaust a taker's or an unload's step budget at the cost of one block of exposure
            // each. The floor is judged on the amendment, not on where the order lands, so the
            // caller faces one rule.
            uint64 minExpiry = params.currentBlock + MIN_ORDER_LIFETIME_BLOCKS;
            if (o.expiryBlock < minExpiry) {
                revert OrderManagementLib__AmendTooCloseToExpiry(orderId, o.expiryBlock, minExpiry);
            }
            // A new price, or more size at the same one, is a new claim on the level: the order
            // goes to the back behind every order resting there, under a fresh queue position,
            // and the move restarts its exposure and re-measures its far-side premium
            // (Order.restedBlock, Order.restedPremiumPpm) — a quote moved to a new price, or
            // grown, has not stood at that price and size for anyone to take. The reduction
            // above keeps all three: what remains was there all along.
            // Counter values stay far below 2^48 (BazaarTypes.Order).
            uint48 seq = uint48(seqCounter);
            unchecked {
                ++seqCounter;
            }
            if (OrderBookLib.staysInPlace(orders, o, newPrice, seq)) {
                // The new key still sorts between the order's neighbours, so an unlink and an
                // insert would rebuild the links, head and count exactly as they stand: the key
                // and the stamps are written where the order is, and the hints go unused.
                o.limitPrice = SafeCast.toUint128(newPrice);
                o.size = SafeCast.toUint128(newSize);
                o.prioritySeq = seq;
                OrderBookLib.restamp(o, params.currentBlock, stampIndex);
            } else {
                // The caller's hints lead, so a jump across the book walks from where the caller
                // says the slot is; the old neighbours, still resting, follow as the fallback
                // anchor, so a requote by a few ticks with no hint, or a dead one, still walks
                // from close by.
                BazaarTypes.MatchHints memory hints;
                hints.pred = uint64(idWord >> 64);
                hints.pred2 = uint64(idWord >> 128);
                hints.pred3 = o.prevInBook;
                hints.pred4 = o.nextInBook;
                OrderBookLib.unlink(orders, book, orderId);
                o.limitPrice = SafeCast.toUint128(newPrice);
                o.size = SafeCast.toUint128(newSize);
                o.prioritySeq = seq;
                OrderBookLib.insert(orders, book, orderId, hints, params.currentBlock, stampIndex);
            }
        }
        CollateralLib._tallyAdd(tally, o.isLong, false, newSize - filled, newPrice);
        _emitAmended(params.pairId, orderId, caller, o);
        return seqCounter;
    }

    /// @dev Report an amendment from the order's stored state, which the caller has just written.
    function _emitAmended(bytes32 pairId, uint256 orderId, address owner, BazaarTypes.Order storage o) private {
        emit BazaarTypes.OrderAmended(pairId, orderId, owner, o.limitPrice, o.size, o.prioritySeq);
    }

    /// @dev amendOrders' margin gate, on the set as the batch leaves it. The set's tally bounds
    ///      its reservation first (CollateralLib._restingBound); only an owner the bound does not
    ///      clear, or one whose tally cannot bound the set, has the set pruned and read
    ///      (_exactAmendReserve), and only that reading refuses. The bound never understates the
    ///      set, so nothing passes here that the reading would refuse.
    function _requireAmendedSetAffordable(
        EnumerableSet.UintSet storage orderSet,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.RestingTally storage tally,
        BazaarTypes.PositionBucket storage bucket,
        BazaarTypes.MarginRequirements storage marginReqs,
        BazaarTypes.AmendOrdersParams memory params
    ) private {
        (bool bounded, uint256 longExposure, uint256 shortExposure, uint256 fillDebit) =
            CollateralLib._restingBound(tally, params.currentPrice);
        if (!bounded) {
            (longExposure, shortExposure, fillDebit) = _exactAmendReserve(orderSet, orders, book, tally, params);
        }
        (bool ok, uint256 collateral, uint256 required) =
            _restingExposureShortfall(bucket, marginReqs, params, longExposure, shortExposure, fillDebit);
        if (!ok && bounded) {
            (longExposure, shortExposure, fillDebit) = _exactAmendReserve(orderSet, orders, book, tally, params);
            (ok, collateral, required) =
                _restingExposureShortfall(bucket, marginReqs, params, longExposure, shortExposure, fillDebit);
        }
        if (!ok) revert OrderManagementLib__InsufficientMarginAfterOrder(collateral, required);
    }

    /// @dev The amended set read as it is: expired orders pruned, then every survivor reserved
    ///      against the mark and the tally rewritten (CollateralLib._sweepRestingReserve).
    function _exactAmendReserve(
        EnumerableSet.UintSet storage orderSet,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.RestingTally storage tally,
        BazaarTypes.AmendOrdersParams memory params
    ) private returns (uint256 longExposure, uint256 shortExposure, uint256 fillDebit) {
        _pruneExpired(orderSet, orders, book, params.pairId, params.currentBlock);
        return CollateralLib._sweepRestingReserve(orderSet, orders, tally, params.currentBlock, params.currentPrice);
    }

    /// @dev createOrder's margin test for the resting set alone: the position plus its resting
    ///      orders, in whichever direction is worse (CollateralLib._worstCaseNotional, the base the
    ///      withdrawal gate and the lens use), must be covered at initial margin together with the
    ///      fill gate's debit across the set (`fillDebit`, CollateralLib._fillDebitOf) and the
    ///      position's unrealized loss. Judged only when the orders add exposure beyond the
    ///      position, or when there is no position, as createOrder judges a new order. Returns
    ///      the verdict with the figures a refusal reports rather than reverting, so a caller can
    ///      judge a bound first and the set itself only when the bound fails.
    function _restingExposureShortfall(
        BazaarTypes.PositionBucket storage bucket,
        BazaarTypes.MarginRequirements storage marginReqs,
        BazaarTypes.AmendOrdersParams memory params,
        uint256 longExposure,
        uint256 shortExposure,
        uint256 fillDebit
    ) private view returns (bool ok, uint256 collateral, uint256 required) {
        BazaarTypes.BucketState memory state = BucketLib.calculateState(
            bucket, params.currentPrice, params.currentFundingIndex, marginReqs
        );
        bool flat = bucket.size == 0;
        uint256 posNotional = flat ? 0 : state.currentNotional;
        uint256 worst = CollateralLib._worstCaseNotional(bucket.isLong, posNotional, longExposure, shortExposure);
        collateral = state.effectiveCollateral;
        ok = true;
        if (worst > posNotional || flat) {
            required = Math.mulDiv(marginReqs.imrBp, worst, BazaarTypes.BP_SCALE) + fillDebit;
            if (state.totalPnl < 0) required += uint256(-state.totalPnl);
            ok = collateral >= required;
        }
    }

    /// @dev createOrder's margin gate: the order's own exposure and the resting set's, in
    ///      whichever direction is worse, at initial margin, plus everything the fill gate debits
    ///      before its own test (_creationShortfall). The set's tally bounds its reservation
    ///      first (CollateralLib._restingBound); only a caller the bound does not clear, or one
    ///      whose tally cannot bound the set, has the set read (CollateralLib._sweepRestingReserve,
    ///      which also rewrites the tally), and only that reading refuses. The bound never
    ///      understates the set, so nothing passes here that the reading would refuse. The set
    ///      is not pruned here: the reading skips dead entries itself, and a full set was pruned
    ///      ahead of the cap check.
    function _requireCreationAffordable(
        EnumerableSet.UintSet storage orderSet,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.RestingTally storage tally,
        BazaarTypes.PositionBucket storage bucketStorage,
        BazaarTypes.BucketState memory currentState,
        CreationGate memory g
    ) private {
        BazaarTypes.PositionBucket memory bucket = bucketStorage;
        (bool bounded, uint256 longExposure, uint256 shortExposure, uint256 fillDebit) =
            CollateralLib._restingBound(tally, g.currentPrice);
        if (!bounded) {
            (longExposure, shortExposure, fillDebit) =
                CollateralLib._sweepRestingReserve(orderSet, orders, tally, g.currentBlock, g.currentPrice);
        }
        (bool ok, uint256 required) =
            _creationShortfall(bucket, currentState, g, longExposure, shortExposure, fillDebit);
        if (!ok && bounded) {
            (longExposure, shortExposure, fillDebit) =
                CollateralLib._sweepRestingReserve(orderSet, orders, tally, g.currentBlock, g.currentPrice);
            (ok, required) = _creationShortfall(bucket, currentState, g, longExposure, shortExposure, fillDebit);
        }
        if (!ok) revert OrderManagementLib__InsufficientMarginAfterOrder(currentState.effectiveCollateral, required);
    }

    /// @dev The creation gate's verdict for one reading of the resting set, with the requirement
    ///      a refusal reports.
    ///
    ///      Fresh exposure is reserved at no less than the current mark: the fill-time margin
    ///      gate values it at the then-current oracle, never at the fill price, so a bid below
    ///      the mark margined at its own limit would reserve less than any fill of it will
    ///      demand — the order would be creatable but only ever auto-cancelable at the gate. A
    ///      bid is valued at the mark outright: above the mark, its excess over the mark is the
    ///      loss the fill books, charged in full by the fill debit below, so valuing it at the
    ///      limit as well would count that excess twice over. The limit leg of the max keeps asks
    ///      above the mark reserved at their full crossing price. A Market order margins both
    ///      sides at the upper slippage bound: the fill price is the maker's, so it isn't known
    ///      here — maxSlippageBp only states how far from the mark the walk may execute — and
    ///      margining the worst case keeps a wider tolerance strictly more expensive than a tight
    ///      one. A StopLimit is valued at the largest of its trigger, its limit and the mark.
    ///
    ///      The position this order leaves, plus the resting orders in whichever direction is
    ///      worse (CollateralLib._worstCaseNotional), must be covered at initial margin together
    ///      with everything the fill gate debits from the same collateral before it tests that
    ///      margin: for this order and every resting one, the loss a fill at the limit books
    ///      against the mark and the maker fee (CollateralLib._fillDebitOf), and the held
    ///      position's unrealized loss. An order that gate would refuse is refused here rather
    ///      than resting until a fill auto-cancels it. Judged only when the result adds exposure
    ///      beyond the held position, or when there is none.
    function _creationShortfall(
        BazaarTypes.PositionBucket memory bucket,
        BazaarTypes.BucketState memory currentState,
        CreationGate memory g,
        uint256 longExposure,
        uint256 shortExposure,
        uint256 fillDebit
    ) private pure returns (bool ok, uint256 required) {
        uint256 executionPrice;
        if (g.orderType == BazaarTypes.OrderType.Limit) {
            executionPrice = !g.isLong && g.limitPrice > g.currentPrice ? g.limitPrice : g.currentPrice;
        } else if (g.orderType == BazaarTypes.OrderType.Market) {
            executionPrice = g.currentPrice * (BazaarTypes.BP_SCALE + g.maxSlippageBp) / BazaarTypes.BP_SCALE;
        } else {
            executionPrice = g.triggerPrice > g.limitPrice ? g.triggerPrice : g.limitPrice;
            if (g.currentPrice > executionPrice) executionPrice = g.currentPrice;
        }
        uint256 orderNotional = Math.mulDiv(g.size, executionPrice, BazaarTypes.BAZAAR_SCALE);

        bool flat = bucket.size == 0;
        uint256 posNotional;
        if (flat) {
            posNotional = orderNotional;
        } else if (bucket.isLong == g.isLong) {
            posNotional = currentState.currentNotional + orderNotional;
        } else if (orderNotional > currentState.currentNotional) {
            posNotional = orderNotional - currentState.currentNotional;
        } else {
            posNotional = currentState.currentNotional - orderNotional;
        }
        bool posIsLong = flat ? g.isLong : bucket.isLong;
        if (!flat && bucket.isLong != g.isLong && orderNotional > currentState.currentNotional) posIsLong = g.isLong;

        uint256 worst = CollateralLib._worstCaseNotional(posIsLong, posNotional, longExposure, shortExposure);
        ok = true;
        if (worst > currentState.currentNotional || flat) {
            required = Math.mulDiv(g.imrBp, worst, BazaarTypes.BP_SCALE) + fillDebit
                + CollateralLib._fillDebitOf(
                    g.orderType, g.isLong, g.size, g.limitPrice, g.triggerPrice, g.currentPrice, g.integrator
                );
            if (currentState.totalPnl < 0) required += uint256(-currentState.totalPnl);
            ok = currentState.effectiveCollateral >= required;
        }
    }

    /// @dev The body of cleanupExpiredLimitOrders, shared with amendOrders.
    function _pruneExpired(
        EnumerableSet.UintSet storage orderSet,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        bytes32 pairId,
        uint64 currentBlock
    ) private {
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
                    OrderBookLib.emitOrderUpdated(
                        pairId, orderId, order, BazaarTypes.OrderAction.Canceled, BazaarTypes.CancelReason.Expired
                    );
                }
                orderSet.remove(orderId);
                len--;
                // don't increment i — the last element was swapped into this index
            } else {
                i++;
            }
        }
    }

    /// @notice Permissionless janitor: cancels + unlinks any of the given orders that have
    ///         expired without reaching a terminal state, and returns the keeper bounty of any
    ///         order that is terminal or expired to its owner's claimable balance. Live,
    ///         non-expired and unknown ids are skipped silently so racing keepers never revert
    ///         each other.
    /// @dev Expired orders are otherwise removed lazily — by the matching walk on contact, or by
    ///      the owner's sweeps at a withdrawal, a creation at the order cap, or an amendment
    ///      whose gate reads the set in full — so this exists to let anyone clear dead nodes
    ///      from the book front proactively. It pays its caller nothing. Only Limit/StopLimit can expire (TP/SL carry
    ///      the never-expire sentinel; Market orders are terminal in their creation tx), so the
    ///      set removal below covers every sweepable type. The bounty refund covers the terminal
    ///      writes that bypass the escrow (the walk's auto-cancels, the TP/SL fence, liquidation
    ///      and deleverage resets), so a stranded bounty needs no action from its owner.
    function sweepExpired(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => EnumerableSet.UintSet) storage userActiveLimitOrders,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.FeeEscrow storage feeEscrow,
        uint256[] calldata orderIds,
        bytes32 pairId,
        uint64 currentBlock
    ) external {
        for (uint256 i; i < orderIds.length; ++i) {
            uint256 orderId = orderIds[i];
            BazaarTypes.Order storage order = orders[orderId];
            if (order.creator == address(0)) continue;
            if (order.canceledBlock == 0 && order.filledBlock == 0) {
                if (currentBlock <= order.expiryBlock) continue;

                order.canceledBlock = currentBlock;
                OrderBookLib.unlink(orders, book, orderId);
                userActiveLimitOrders[order.creator].remove(orderId);

                OrderBookLib.emitOrderUpdated(
                    pairId, orderId, order, BazaarTypes.OrderAction.Canceled, BazaarTypes.CancelReason.Expired
                );
            }
            FeeEscrowLib.refundBounty(feeEscrow, pairId, orderId, order.creator);
        }
    }

    // -------------------- Internal Functions --------------------

    /// @dev Resolve an order's absolute expiry block. TP/SL never expire and take the
    ///      NEVER_EXPIRE_BLOCK sentinel. An order that never rests — Market, and a Limit sent IOC
    ///      or FOK — is terminal within its own transaction, so its expiry is stamped at the
    ///      creation block: demanding a future block from it would be asking the caller to
    ///      populate a field no later observer can act on. Everything else can rest, so its
    ///      user-supplied expiry must land in [cb + MIN_ORDER_LIFETIME_BLOCKS,
    ///      cb + MAX_ORDER_LIFETIME_BLOCKS] — under-long is rejected, over-long is clamped down to
    ///      the ceiling.
    /// @param ot The order's type.
    /// @param tif The order's time-in-force.
    /// @param specExpirationBlock The caller's requested absolute expiry block.
    /// @param cb The L2 block number this order is created at.
    /// @return The expiry block to store.
    function _resolveExpiryBlock(
        BazaarTypes.OrderType ot,
        BazaarTypes.TimeInForce tif,
        uint64 specExpirationBlock,
        uint64 cb
    ) internal pure returns (uint64) {
        if (ot == BazaarTypes.OrderType.TakeProfit || ot == BazaarTypes.OrderType.StopLoss) {
            return NEVER_EXPIRE_BLOCK;
        }
        if (ot == BazaarTypes.OrderType.Market || tif != BazaarTypes.TimeInForce.GTC) return cb;

        uint64 minExp = cb + MIN_ORDER_LIFETIME_BLOCKS;
        uint64 maxExp = cb + MAX_ORDER_LIFETIME_BLOCKS;
        if (specExpirationBlock < minExp) {
            revert OrderManagementLib__InvalidOrderExpiration(specExpirationBlock);
        }
        return specExpirationBlock > maxExp ? maxExp : specExpirationBlock;
    }

    /// @dev Whether an order belongs in userActiveLimitOrders — the set that carries the per-user
    ///      order cap and the outstanding-exposure tally. Membership means "can still be resting
    ///      when a later transaction reads this set", which is true of a good-till-cancelled Limit
    ///      and of a StopLimit (creation admits no other time-in-force on it), and false of an
    ///      order that never rests — Market, and a Limit sent IOC or FOK — since it is terminal
    ///      within its own transaction. The walk's fill and cancel paths still remove an IOC or
    ///      FOK limit's id on the way out; removing an id the set does not hold is a no-op. One
    ///      predicate rather than the condition written twice, so the cap gate and the
    ///      registration can never disagree about which orders the set holds.
    function _joinsActiveSet(BazaarTypes.OrderType ot, BazaarTypes.TimeInForce tif) internal pure returns (bool) {
        return (ot == BazaarTypes.OrderType.Limit && tif == BazaarTypes.TimeInForce.GTC)
            || ot == BazaarTypes.OrderType.StopLimit;
    }
}
