// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {OrderView} from "../OrderView.sol";

/// @title AmendTestBase
/// @notice Shared fixture of the amendOrders tests: batch construction, amending as a user, resting
///         hinted orders, and readings of the book's heads, counts, links and order.
/// @dev The amendOrders tests span several contracts so that none grows past the code size solc's
///      assembler can address; each of them inherits this.
abstract contract AmendTestBase is IntegrationBase {
    uint256 constant BTC = 1e18;
    uint256 constant SIZE = BTC / 10;

    /// @dev One batch: the flat word triples the entry point takes.
    struct Batch {
        uint256[] words;
    }

    // ---------------------------- batches ----------------------------

    function _batch(uint256 n) internal pure returns (Batch memory b) {
        b.words = new uint256[](3 * n);
    }

    function _set(Batch memory b, uint256 i, uint256 orderId, uint256 price, uint256 size) internal pure {
        b.words[3 * i] = orderId;
        b.words[3 * i + 1] = price;
        b.words[3 * i + 2] = size;
    }

    function _single(uint256 orderId, uint256 price, uint256 size) internal pure returns (Batch memory b) {
        b = _batch(1);
        _set(b, 0, orderId, price, size);
    }

    /// @dev The id word: the order id with up to two predecessor hints packed above it.
    function _word(uint256 orderId, uint64 pred, uint64 pred2) internal pure returns (uint256) {
        return orderId | (uint256(pred) << 64) | (uint256(pred2) << 128);
    }

    function _singleHinted(uint256 orderId, uint64 pred, uint64 pred2, uint256 price, uint256 size)
        internal
        pure
        returns (Batch memory b)
    {
        b = _single(orderId, price, size);
        b.words[0] = _word(orderId, pred, pred2);
    }

    /// @dev `user` amends, carrying a fresh $50k update.
    function _amendAs(address user, Batch memory b) internal {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        pair.amendOrders(b.words, pu, 0, 0, 0, "", "");
    }

    function _amendExpect(address user, Batch memory b, bytes memory err) internal {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        vm.expectRevert(err);
        pair.amendOrders(b.words, pu, 0, 0, 0, "", "");
    }

    // ---------------------------- fixtures ----------------------------

    /// @dev Two bids from alice (49k) and bob (48k), both funded well past the margin they need.
    function _twoBids() internal returns (uint256 a, uint256 b) {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        a = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);
        _roll(1);
        b = _placeLimit(bob, true, SIZE, 48_000 * BAZAAR_SCALE);
    }

    /// @dev carol sells `size` at `priceUsd`, crossing whatever rests at or above it.
    function _sell(uint256 size, uint256 priceUsd) internal {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _roll(1);
        _placeLimit(carol, false, size, priceUsd * BAZAAR_SCALE);
    }

    /// @dev `user` rests a limit order of SIZE at `price`, hinted to rest behind `pred` (0: none).
    function _placeHinted(address user, bool isLong, uint256 price, uint64 pred) internal returns (uint256) {
        BazaarTypes.MatchHints memory hints;
        hints.pred = pred;
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        pair.createOrder(_limitSpec(isLong, SIZE, price), hints, pu, 0, 0, 0, "", "");
        return _lastCreatedOrderId(pair);
    }

    // ---------------------------- book readings ----------------------------

    function _bidHead() internal view returns (uint64 head) {
        (head,,,) = pair.book();
    }

    function _askHead() internal view returns (uint64 head) {
        (, head,,) = pair.book();
    }

    function _next(uint256 orderId) internal view returns (uint64) {
        return OrderView.order(pair, orderId).nextInBook;
    }

    function _prev(uint256 orderId) internal view returns (uint64) {
        return OrderView.order(pair, orderId).prevInBook;
    }

    function _seq(uint256 orderId) internal view returns (uint64) {
        return OrderView.order(pair, orderId).prioritySeq;
    }

    /// @dev Bids from the head down, as the book links them.
    function _bids() internal view returns (uint256[] memory ids) {
        (uint64 cur,, uint64 count,) = pair.book();
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            require(cur != 0, "bid list shorter than its count");
            ids[i] = cur;
            cur = _next(cur);
        }
        require(cur == 0, "bid list longer than its count");
    }

    /// @dev Asks from the head up, as the book links them.
    function _asks() internal view returns (uint256[] memory ids) {
        (, uint64 cur,, uint64 count) = pair.book();
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            require(cur != 0, "ask list shorter than its count");
            ids[i] = cur;
            cur = _next(cur);
        }
        require(cur == 0, "ask list longer than its count");
    }

    /// @dev Both heads, both counts and every member's prev and next, in one word, so two readings
    ///      of the book's links compare at once.
    function _links() internal view returns (bytes32 acc) {
        (uint64 bidHead, uint64 askHead, uint64 bidCount, uint64 askCount) = pair.book();
        acc = keccak256(abi.encode(bidHead, askHead, bidCount, askCount));
        uint256[] memory ids = _bids();
        for (uint256 i; i < ids.length; ++i) {
            acc = keccak256(abi.encode(acc, ids[i], _prev(ids[i]), _next(ids[i])));
        }
        ids = _asks();
        for (uint256 i; i < ids.length; ++i) {
            acc = keccak256(abi.encode(acc, ids[i], _prev(ids[i]), _next(ids[i])));
        }
    }

    /// @dev One side traverses to its count, every member on that side with reciprocal links, in
    ///      strict order: better price first, then the earlier queue position.
    function _assertSideWellFormed(bool isLong, uint256 expectedCount) internal view {
        uint256[] memory ids = isLong ? _bids() : _asks();
        assertEq(ids.length, expectedCount, "every order still rests");
        uint64 prev;
        for (uint256 i; i < ids.length; ++i) {
            BazaarTypes.Order memory o = OrderView.order(pair, ids[i]);
            assertEq(o.prevInBook, prev, "links are reciprocal");
            assertTrue(o.inBook);
            assertEq(o.isLong, isLong, "on its side");
            if (i > 0) {
                BazaarTypes.Order memory before = OrderView.order(pair, ids[i - 1]);
                bool ordered = (isLong ? before.limitPrice > o.limitPrice : before.limitPrice < o.limitPrice)
                    || (before.limitPrice == o.limitPrice && before.prioritySeq < o.prioritySeq);
                assertTrue(ordered, "sorted by price, then by queue position");
            }
            prev = uint64(ids[i]);
        }
    }
}
