// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BazaarTypes} from "./BazaarTypes.sol";
import {FundingLib} from "./FundingLib.sol";

/// @title OrderBookLib
/// @notice The pair's resting order book: two sorted doubly-linked lists threaded through the
///         orders mapping via Order.prevInBook/nextInBook, with heads in BazaarTypes.OrderBook.
///         Bids sort by limitPrice DESC, asks by limitPrice ASC, ties by prioritySeq ASC — an
///         order at an occupied price always queues behind the orders already resting there.
///         prioritySeq is the order's id until the order joins its level late — an amend sends
///         it to the back, or a keeper arms a StopLimit — when it takes a fresh value from the
///         same counter (BazaarTypes.Order). Every link also stamps the order with the block it
///         entered the book in (Order.restedBlock) and how far on the far side of the index it
///         entered (Order.restedPremiumPpm): how long and where it has stood at its current
///         price and queue position, which bound what its fills carry into the mark. A member
///         whose price and queue position are rewritten where it stands (staysInPlace, restamp)
///         is stamped afresh the same way.
/// @dev Internal library (inlined into callers, no DELEGATECALL hop). Every mutation preserves:
///       • strict (limitPrice, prioritySeq) ordering along nextInBook on both sides;
///       • link reciprocity — orders[x].nextInBook == y iff orders[y].prevInBook == x, the head's
///         prevInBook is 0 and the tail's nextInBook is 0;
///       • inBook is true exactly for orders reachable from their side's head, and
///         bidCount/askCount equal the traversal lengths;
///       • a member's restedBlock is the block of the link, or of the in-place rewrite, that
///         gave it its current price and queue position, and its restedPremiumPpm the far-side
///         premium it stood at against that moment's index.
///      insert never links at an unverified position: every candidate placement — hinted or
///      found by the repair walk — is checked against the actual neighbors, so a wrong hint can
///      only fail placement, never mis-place an order. locate is the read-only half of insert,
///      for callers that must learn whether a slot is reachable before committing any state.
///      unlink is an unconditional no-op on non-members, so terminal-state writers (cancel,
///      fill, expiry sweep, liquidation, ADL) can call it without knowing whether the order
///      ever rested. staysInPlace tells a caller about to give a member a new price and queue
///      position whether its slot survives the change; when it does, the caller writes the key
///      where the order stands and calls restamp, and the book is left exactly as an unlink and
///      an insert would leave it.
library OrderBookLib {
    error OrderBookLib__AlreadyInBook(uint256 orderId);
    error OrderBookLib__HintRepairExhausted(uint256 orderId);

    /// @notice Link a resting order into its side's list at the position determined by
    ///         (limitPrice, prioritySeq), using the caller-supplied predecessor hints.
    /// @dev Resolves the slot with locate and links there. Reverts when locate gives up, so a
    ///      caller placing its own order (createOrder) fails loudly and retries with hints
    ///      recomputed off-chain — past the cap a stale book view should be recomputed, not
    ///      searched for on-chain. A caller placing someone else's order in a batch of unrelated
    ///      owners (executeTriggers) must instead call locate first and skip the order when it
    ///      cannot be placed, since a revert here would unwind the whole batch.
    /// @param orders The pair's order storage.
    /// @param book The pair's book heads/counts.
    /// @param orderId The order to rest. Must carry a non-zero limitPrice and not be in the book.
    /// @param hints Predecessor candidates (see BazaarTypes.MatchHints).
    /// @param restedBlock The current L2 block, stamped on the order as the start of its exposure
    ///        (BazaarTypes.Order.restedBlock); the low 32 bits are what the stamp holds.
    /// @param indexPrice The index the order's far-side premium is stamped against
    ///        (BazaarTypes.Order.restedPremiumPpm): the caller's fresh oracle price, or 0 when it
    ///        holds none, which stamps zero.
    function insert(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        uint256 orderId,
        BazaarTypes.MatchHints memory hints,
        uint64 restedBlock,
        uint256 indexPrice
    ) internal {
        BazaarTypes.Order storage o = orders[orderId];
        if (o.inBook) revert OrderBookLib__AlreadyInBook(orderId);
        (bool found, uint64 pred) = locate(orders, book, orderId, o.prioritySeq, hints);
        if (!found) revert OrderBookLib__HintRepairExhausted(orderId);
        bool side = o.isLong;
        uint64 next = pred == 0 ? (side ? book.bidHead : book.askHead) : uint64(orders[pred].nextInBook);
        uint16 restedPremiumPpm = FundingLib.restedPremiumOf(side, o.limitPrice, indexPrice);
        // orderIds come from the pair's monotonic counter starting at 1; 2^48 is unreachable.
        _link(orders, book, o, side, uint48(orderId), uint48(pred), uint48(next), uint32(restedBlock), restedPremiumPpm);
    }

    /// @notice Find the predecessor an order would rest behind, without touching the book.
    /// @dev Placement resolution, in order:
    ///       1. The head when the side is empty or the order sorts before the current head.
    ///       2. Each non-zero hint in sequence: accepted only if it is live, on the right side,
    ///          sorts before the new order, and its successor (if any) sorts after it.
    ///       3. A repair walk from the first live hint (or the head when none is live), in
    ///          whichever direction the ordering predicate points, capped at MAX_WALK_STEPS —
    ///          drift between off-chain simulation and inclusion is a few nodes.
    ///      Never reverts: past the cap it reports not found, which lets a caller choose between
    ///      reverting (its own order) and skipping (someone else's) before any state has changed.
    ///      The answer holds for as long as the side's list is unchanged, and an exact hint of
    ///      `pred` then resolves in step 2 without a walk.
    /// @param orders The pair's order storage.
    /// @param book The pair's book heads/counts.
    /// @param orderId The order to place. Must carry a non-zero limitPrice and not be in the book.
    /// @param seq The queue position to place it at. insert passes the stored prioritySeq; a
    ///        caller about to give the order a new one (a StopLimit being armed) passes that
    ///        value, so the slot is resolved before anything is written and the order must then
    ///        carry it when insert runs.
    /// @param hints Predecessor candidates (see BazaarTypes.MatchHints).
    /// @return found False when no live hint brackets the order and the slot lies more than
    ///         MAX_WALK_STEPS from the anchor.
    /// @return pred The orderId to rest directly behind; 0 means the head of the side (and is
    ///         also what a not-found result carries).
    function locate(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        uint256 orderId,
        uint64 seq,
        BazaarTypes.MatchHints memory hints
    ) internal view returns (bool found, uint64 pred) {
        BazaarTypes.Order storage o = orders[orderId];
        bool side = o.isLong;
        uint256 price = o.limitPrice;

        uint64 head = side ? book.bidHead : book.askHead;
        if (head == 0 || _precedesNode(side, price, seq, orders[head])) {
            return (true, 0);
        }

        uint64 anchor = 0;
        uint64[4] memory cands = [hints.pred, hints.pred2, hints.pred3, hints.pred4];
        for (uint256 i; i < 4; ++i) {
            uint64 cand = cands[i];
            if (cand == 0) continue;
            BazaarTypes.Order storage p = orders[cand];
            if (!p.inBook || p.isLong != side) continue;
            if (anchor == 0) anchor = cand;
            if (_nodePrecedes(side, p, price, seq)) {
                uint64 nxt = p.nextInBook;
                if (nxt == 0 || _precedesNode(side, price, seq, orders[nxt])) {
                    return (true, cand);
                }
            }
        }
        if (anchor == 0) anchor = head;

        return _walkToSlot(orders, side, seq, price, anchor);
    }

    /// @notice Remove an order from its side's list; no-op when the order is not in the book.
    function unlink(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        uint256 orderId
    ) internal {
        BazaarTypes.Order storage o = orders[orderId];
        if (!o.inBook) return;
        uint48 prv = o.prevInBook;
        uint48 nxt = o.nextInBook;
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

    /// @notice Whether a member keeps its slot under a new price and queue position: its
    ///         predecessor still sorts ahead of (newPrice, newSeq) and its successor still behind
    ///         it, a missing neighbour counting as satisfied.
    /// @dev The slot is unique. A side is strictly sorted by (limitPrice, prioritySeq) and no two
    ///      orders share a prioritySeq, so exactly one position in the list takes the new key, and
    ///      when both neighbours still bracket it that position is the one the order occupies.
    ///      Unlinking the order and inserting it under the new key would therefore resolve to the
    ///      same predecessor and successor, restore the same two links, the same head and the same
    ///      count, and stamp the order as restamp stamps it: writing the key in place leaves the
    ///      book and the order in exactly the state the relink would, and skips only the work of
    ///      taking the links apart and putting them back. The equivalence rests on `newSeq` being
    ///      later than every queue position in the book — the value a caller is about to draw
    ///      from the counter — so a successor at the new price is never kept: under a later
    ///      position the order belongs behind it, and the caller must relink.
    /// @param orders The pair's order storage.
    /// @param o The order, which must be in the book.
    /// @param newPrice The limit price the order is about to take.
    /// @param newSeq The queue position it is about to take; later than every one in the book.
    /// @return True when the order's slot survives the new key.
    function staysInPlace(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.Order storage o,
        uint256 newPrice,
        uint64 newSeq
    ) internal view returns (bool) {
        bool side = o.isLong;
        uint48 prev = o.prevInBook;
        uint48 next = o.nextInBook;
        return (prev == 0 || _nodePrecedes(side, orders[prev], newPrice, newSeq))
            && (next == 0 || _precedesNode(side, newPrice, newSeq, orders[next]));
    }

    /// @notice Stamp a member as a link stamps it — the block it rests from and its far-side
    ///         premium against `indexPrice` — without moving it, for a caller that has rewritten
    ///         the order's price and queue position where it stands (staysInPlace). The stamps
    ///         measure how long and where the order has stood at its current price and size, so a
    ///         new price restarts them exactly as a relink would.
    /// @dev The stamps share a slot with the queue position and the links, so they land in a slot
    ///      the caller's prioritySeq write has already dirtied.
    /// @param o The order, in the book, with its new limitPrice already written.
    /// @param restedBlock The current L2 block; the low 32 bits are what the stamp holds.
    /// @param indexPrice The index the premium is measured against; 0 stamps zero.
    function restamp(BazaarTypes.Order storage o, uint64 restedBlock, uint256 indexPrice) internal {
        o.restedBlock = uint32(restedBlock);
        o.restedPremiumPpm = FundingLib.restedPremiumOf(o.isLong, o.limitPrice, indexPrice);
    }

    /// @notice Emit OrderUpdated for an order, reporting its stored state.
    /// @dev Every payload field is read from storage, so a caller writes the change it reports
    ///      (a cancel stamp, a capped size) before calling. The one place the payload is
    ///      assembled, so every library that creates, triggers or cancels orders reports the
    ///      same fields.
    /// @param pairId The pair, for the event
    /// @param orderId The order
    /// @param o The order's storage
    /// @param action The lifecycle step being reported
    /// @param reason Why the order was canceled; None unless action is Canceled
    function emitOrderUpdated(
        bytes32 pairId,
        uint256 orderId,
        BazaarTypes.Order storage o,
        BazaarTypes.OrderAction action,
        BazaarTypes.CancelReason reason
    ) internal {
        emit BazaarTypes.OrderUpdated(
            pairId,
            orderId,
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

    /// @dev Strict ordering predicate: does an order at (price, seq) rest ahead of the resting
    ///      node `n` on this side? Bids put the higher price first, asks the lower; equal prices
    ///      put the lower prioritySeq first, which is what enforces time priority within a price
    ///      level. The node's prioritySeq is read only on a price tie: it shares a slot with the
    ///      links, so a walk that moves on to the node pays for it anyway, while one that stops
    ///      at a different price never does.
    function _precedesNode(bool isLongSide, uint256 price, uint64 seq, BazaarTypes.Order storage n)
        private
        view
        returns (bool)
    {
        uint256 nPrice = n.limitPrice;
        if (price != nPrice) return isLongSide ? price > nPrice : price < nPrice;
        return seq < n.prioritySeq;
    }

    /// @dev The mirror of _precedesNode: does the resting node `n` rest ahead of an order at
    ///      (price, seq)? Two distinct orders never share a prioritySeq, so exactly one of the
    ///      two predicates holds for any pair.
    function _nodePrecedes(bool isLongSide, BazaarTypes.Order storage n, uint256 price, uint64 seq)
        private
        view
        returns (bool)
    {
        uint256 nPrice = n.limitPrice;
        if (price != nPrice) return isLongSide ? nPrice > price : nPrice < price;
        return n.prioritySeq < seq;
    }

    /// @dev Walk from `anchor` toward the true slot and report the predecessor found there.
    ///      Direction follows the ordering predicate: forward via nextInBook when the anchor
    ///      sorts before the new order, backward via prevInBook otherwise (reaching the head
    ///      reports a predecessor of 0). Capped at MAX_WALK_STEPS node advances; past it the walk
    ///      reports not found rather than reverting, so the caller chooses the disposition.
    function _walkToSlot(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        bool side,
        uint64 seq,
        uint256 price,
        uint64 anchor
    ) private view returns (bool found, uint64 pred) {
        uint256 steps;
        uint64 cur = anchor;
        if (_nodePrecedes(side, orders[anchor], price, seq)) {
            while (true) {
                uint64 nxt = orders[cur].nextInBook;
                if (nxt == 0 || _precedesNode(side, price, seq, orders[nxt])) return (true, cur);
                cur = nxt;
                unchecked {
                    ++steps;
                }
                if (steps > BazaarTypes.MAX_WALK_STEPS) return (false, 0);
            }
        } else {
            while (true) {
                uint64 prv = orders[cur].prevInBook;
                if (prv == 0) return (true, 0);
                if (_nodePrecedes(side, orders[prv], price, seq)) return (true, prv);
                cur = prv;
                unchecked {
                    ++steps;
                }
                if (steps > BazaarTypes.MAX_WALK_STEPS) return (false, 0);
            }
        }
    }

    /// @dev Splice the order in between `prev` and `next` (either may be 0 for head/tail), stamp
    ///      the block it joined in and the far-side premium it joined at, and update the side's
    ///      head and count. The stamps land in the slot the links share, so they cost no write of
    ///      their own.
    function _link(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.Order storage o,
        bool side,
        uint48 id,
        uint48 prev,
        uint48 next,
        uint32 restedBlock,
        uint16 restedPremiumPpm
    ) private {
        o.prevInBook = prev;
        o.nextInBook = next;
        o.restedBlock = restedBlock;
        o.restedPremiumPpm = restedPremiumPpm;
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
