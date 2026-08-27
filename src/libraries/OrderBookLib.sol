// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BazaarTypes} from "./BazaarTypes.sol";

/// @title OrderBookLib
/// @notice The pair's resting order book: two sorted doubly-linked lists threaded through the
///         orders mapping via Order.prevInBook/nextInBook, with heads in BazaarTypes.OrderBook.
///         Bids sort by limitPrice DESC, asks by limitPrice ASC, ties by orderId ASC — an order
///         at an occupied price always queues behind the orders already resting there.
/// @dev Internal library (inlined into callers, no DELEGATECALL hop). Every mutation preserves:
///       • strict (limitPrice, orderId) ordering along nextInBook on both sides;
///       • link reciprocity — orders[x].nextInBook == y iff orders[y].prevInBook == x, the head's
///         prevInBook is 0 and the tail's nextInBook is 0;
///       • inBook is true exactly for orders reachable from their side's head, and
///         bidCount/askCount equal the traversal lengths.
///      insert never links at an unverified position: every candidate placement — hinted or
///      found by the repair walk — is checked against the actual neighbors, so a wrong hint can
///      only fail placement, never mis-place an order. unlink is an unconditional no-op on
///      non-members, so terminal-state writers (cancel, fill, expiry sweep, liquidation, ADL)
///      can call it without knowing whether the order ever rested.
library OrderBookLib {
    error OrderBookLib__AlreadyInBook(uint256 orderId);
    error OrderBookLib__HintRepairExhausted(uint256 orderId);

    /// @notice Link a resting order into its side's list at the position determined by
    ///         (limitPrice, orderId), using the caller-supplied predecessor hints.
    /// @dev Placement resolution, in order:
    ///       1. Head insert when the book side is empty or the order sorts before the head.
    ///       2. Each non-zero hint in sequence: accepted only if it is live, on the right side,
    ///          sorts before the new order, and its successor (if any) sorts after it.
    ///       3. A repair walk from the first live hint (or the head when none is live), in
    ///          whichever direction the ordering predicate points, capped at MAX_WALK_STEPS —
    ///          drift between off-chain simulation and inclusion is a few nodes, and past the
    ///          cap a stale book view should be recomputed off-chain, not searched for on-chain.
    /// @param orders The pair's order storage.
    /// @param book The pair's book heads/counts.
    /// @param orderId The order to rest. Must carry a non-zero limitPrice and not be in the book.
    /// @param hints Predecessor candidates (see BazaarTypes.MatchHints).
    function insert(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        uint256 orderId,
        BazaarTypes.MatchHints memory hints
    ) internal {
        BazaarTypes.Order storage o = orders[orderId];
        if (o.inBook) revert OrderBookLib__AlreadyInBook(orderId);
        bool side = o.isLong;
        // orderIds come from the pair's monotonic counter starting at 1; 2^64 is unreachable.
        uint64 id = uint64(orderId);
        uint256 price = o.limitPrice;

        uint64 head = side ? book.bidHead : book.askHead;
        if (head == 0 || _precedes(side, price, id, orders[head].limitPrice, head)) {
            _link(orders, book, o, side, id, 0, head);
            return;
        }

        uint64 anchor = 0;
        uint64[4] memory cands = [hints.pred, hints.pred2, hints.pred3, hints.pred4];
        for (uint256 i; i < 4; ++i) {
            uint64 cand = cands[i];
            if (cand == 0) continue;
            BazaarTypes.Order storage p = orders[cand];
            if (!p.inBook || p.isLong != side) continue;
            if (anchor == 0) anchor = cand;
            if (_precedes(side, p.limitPrice, cand, price, id)) {
                uint64 nxt = p.nextInBook;
                if (nxt == 0 || _precedes(side, price, id, orders[nxt].limitPrice, nxt)) {
                    _link(orders, book, o, side, id, cand, nxt);
                    return;
                }
            }
        }
        if (anchor == 0) anchor = head;

        _repairInsert(orders, book, o, side, id, price, anchor);
    }

    /// @notice Remove an order from its side's list; no-op when the order is not in the book.
    function unlink(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        uint256 orderId
    ) internal {
        BazaarTypes.Order storage o = orders[orderId];
        if (!o.inBook) return;
        uint64 prv = o.prevInBook;
        uint64 nxt = o.nextInBook;
        bool side = o.isLong;
        if (prv == 0) {
            if (side) {
                book.bidHead = nxt;
            } else {
                book.askHead = nxt;
            }
        } else {
            orders[prv].nextInBook = nxt;
        }
        if (nxt != 0) orders[nxt].prevInBook = prv;
        o.inBook = false;
        o.prevInBook = 0;
        o.nextInBook = 0;
        unchecked {
            // A member always has a non-zero side count (count == traversal length).
            if (side) {
                --book.bidCount;
            } else {
                --book.askCount;
            }
        }
    }

    /// @dev Strict ordering predicate: does (priceA, idA) rest ahead of (priceB, idB) on this
    ///      side? Bids put the higher price first, asks the lower; equal prices put the lower
    ///      (older) orderId first, which is what enforces time priority within a price level.
    function _precedes(bool isLongSide, uint256 priceA, uint64 idA, uint256 priceB, uint64 idB)
        internal
        pure
        returns (bool)
    {
        if (priceA != priceB) return isLongSide ? priceA > priceB : priceA < priceB;
        return idA < idB;
    }

    /// @dev Walk from `anchor` toward the true slot and link there. Direction follows the
    ///      ordering predicate: forward via nextInBook when the anchor sorts before the new
    ///      order, backward via prevInBook otherwise (reaching the head links at the front).
    ///      Capped at MAX_WALK_STEPS node advances; past it the whole transaction reverts and
    ///      the submitter retries with freshly computed hints.
    function _repairInsert(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.Order storage o,
        bool side,
        uint64 id,
        uint256 price,
        uint64 anchor
    ) private {
        uint256 steps;
        uint64 cur = anchor;
        if (_precedes(side, orders[anchor].limitPrice, anchor, price, id)) {
            while (true) {
                uint64 nxt = orders[cur].nextInBook;
                if (nxt == 0 || _precedes(side, price, id, orders[nxt].limitPrice, nxt)) {
                    _link(orders, book, o, side, id, cur, nxt);
                    return;
                }
                cur = nxt;
                unchecked {
                    ++steps;
                }
                if (steps > BazaarTypes.MAX_WALK_STEPS) revert OrderBookLib__HintRepairExhausted(uint256(id));
            }
        } else {
            while (true) {
                uint64 prv = orders[cur].prevInBook;
                if (prv == 0) {
                    _link(orders, book, o, side, id, 0, cur);
                    return;
                }
                if (_precedes(side, orders[prv].limitPrice, prv, price, id)) {
                    _link(orders, book, o, side, id, prv, cur);
                    return;
                }
                cur = prv;
                unchecked {
                    ++steps;
                }
                if (steps > BazaarTypes.MAX_WALK_STEPS) revert OrderBookLib__HintRepairExhausted(uint256(id));
            }
        }
    }

    /// @dev Splice the order in between `prev` and `next` (either may be 0 for head/tail) and
    ///      update the side's head and count.
    function _link(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.Order storage o,
        bool side,
        uint64 id,
        uint64 prev,
        uint64 next
    ) private {
        o.prevInBook = prev;
        o.nextInBook = next;
        o.inBook = true;
        if (prev == 0) {
            if (side) {
                book.bidHead = id;
            } else {
                book.askHead = id;
            }
        } else {
            orders[prev].nextInBook = id;
        }
        if (next != 0) orders[next].prevInBook = id;
        unchecked {
            if (side) {
                ++book.bidCount;
            } else {
                ++book.askCount;
            }
        }
    }
}
