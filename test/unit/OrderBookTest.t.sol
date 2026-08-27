// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {OrderBookLib} from "../../src/libraries/OrderBookLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @notice Drives OrderBookLib over real storage: an orders mapping and an OrderBook struct,
///         mirroring how BazaarPair hosts them.
contract OrderBookHarness {
    mapping(uint256 => BazaarTypes.Order) internal orders;
    BazaarTypes.OrderBook internal book;
    uint256 internal nextOrderId = 1;

    function create(bool isLong, uint256 limitPrice) external returns (uint256 orderId) {
        orderId = nextOrderId++;
        BazaarTypes.Order storage o = orders[orderId];
        o.creator = msg.sender;
        o.orderType = BazaarTypes.OrderType.Limit;
        o.isLong = isLong;
        o.limitPrice = limitPrice;
        o.size = 1e18;
    }

    function insert(uint256 orderId, BazaarTypes.MatchHints calldata hints) external {
        OrderBookLib.insert(orders, book, orderId, hints);
    }

    function unlink(uint256 orderId) external {
        OrderBookLib.unlink(orders, book, orderId);
    }

    function heads() external view returns (uint64 bidHead, uint64 askHead, uint64 bidCount, uint64 askCount) {
        return (book.bidHead, book.askHead, book.bidCount, book.askCount);
    }

    function node(uint256 orderId)
        external
        view
        returns (bool inBook, uint64 prev, uint64 next, uint256 price, bool isLong)
    {
        BazaarTypes.Order storage o = orders[orderId];
        return (o.inBook, o.prevInBook, o.nextInBook, o.limitPrice, o.isLong);
    }

    /// @notice Head-to-tail traversal of one side, length taken from the side's count.
    function traverse(bool isLong) external view returns (uint256[] memory ids) {
        uint64 count = isLong ? book.bidCount : book.askCount;
        ids = new uint256[](count);
        uint64 cur = isLong ? book.bidHead : book.askHead;
        for (uint256 i; i < count; ++i) {
            require(cur != 0, "list shorter than count");
            ids[i] = cur;
            cur = orders[cur].nextInBook;
        }
        require(cur == 0, "list longer than count");
    }
}

contract OrderBookTest is Test {
    OrderBookHarness internal h;

    uint256 internal constant P = 1e18;

    function setUp() public {
        h = new OrderBookHarness();
    }

    // -------------------- helpers --------------------

    function _hints(uint64 pred) internal pure returns (BazaarTypes.MatchHints memory m) {
        m.pred = pred;
    }

    function _hints4(uint64 a, uint64 b, uint64 c, uint64 d) internal pure returns (BazaarTypes.MatchHints memory m) {
        m.pred = a;
        m.pred2 = b;
        m.pred3 = c;
        m.pred4 = d;
    }

    function _mk(bool isLong, uint256 price, uint64 pred) internal returns (uint256 id) {
        id = h.create(isLong, price);
        h.insert(id, _hints(pred));
    }

    /// @dev Full structural check of one side: exact traversal, ordering predicate between
    ///      neighbors, prev/next reciprocity, head/tail terminators, count.
    function _assertList(bool side, uint256[] memory expected) internal view {
        uint256[] memory got = h.traverse(side);
        assertEq(got.length, expected.length, "list length");
        (uint64 bidHead, uint64 askHead,,) = h.heads();
        uint64 head = side ? bidHead : askHead;
        assertEq(uint256(head), expected.length == 0 ? 0 : expected[0], "head");

        uint64 prevId = 0;
        uint256 prevPrice;
        for (uint256 i; i < got.length; ++i) {
            assertEq(got[i], expected[i], "traversal order");
            (bool inBook, uint64 prev, uint64 next, uint256 price, bool isLong) = h.node(got[i]);
            assertTrue(inBook, "member flag");
            assertEq(isLong, side, "side");
            assertEq(prev, prevId, "prev reciprocity");
            if (i + 1 < got.length) {
                assertEq(uint256(next), got[i + 1], "next link");
            } else {
                assertEq(next, 0, "tail terminator");
            }
            if (i > 0) {
                // Strict ordering: better price first; equal price → older (lower) id first.
                if (price == prevPrice) {
                    assertLt(uint256(prevId), got[i], "fifo tiebreak");
                } else if (side) {
                    assertLt(price, prevPrice, "bid price ordering");
                } else {
                    assertGt(price, prevPrice, "ask price ordering");
                }
            }
            prevId = uint64(got[i]);
            prevPrice = price;
        }
    }

    function _arr1(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _arr2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _arr3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _arr4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory r) {
        r = new uint256[](4);
        r[0] = a;
        r[1] = b;
        r[2] = c;
        r[3] = d;
    }

    // -------------------- deterministic cases --------------------

    function test_insert_emptyBook_becomesHead() public {
        uint256 bid = _mk(true, 100 * P, 0);
        uint256 ask = _mk(false, 101 * P, 0);
        _assertList(true, _arr1(bid));
        _assertList(false, _arr1(ask));
    }

    function test_insert_betterPrice_takesHead() public {
        uint256 b1 = _mk(true, 100 * P, 0);
        uint256 b2 = _mk(true, 101 * P, 0); // better bid → new head
        _assertList(true, _arr2(b2, b1));

        uint256 a1 = _mk(false, 200 * P, 0);
        uint256 a2 = _mk(false, 199 * P, 0); // better ask → new head
        _assertList(false, _arr2(a2, a1));
    }

    function test_insert_equalPrice_queuesBehind() public {
        uint256 b1 = _mk(true, 100 * P, 0);
        uint256 b2 = _mk(true, 100 * P, uint64(b1)); // same price, newer id → behind
        uint256 b3 = _mk(true, 100 * P, uint64(b2));
        _assertList(true, _arr3(b1, b2, b3));
    }

    function test_insert_midAndTail_withExactHints() public {
        uint256 a1 = _mk(false, 100 * P, 0);
        uint256 a3 = _mk(false, 300 * P, uint64(a1));
        uint256 a2 = _mk(false, 200 * P, uint64(a1)); // between a1 and a3
        uint256 a4 = _mk(false, 400 * P, uint64(a3)); // tail
        _assertList(false, _arr4(a1, a2, a3, a4));
    }

    function test_insert_deadHint_fallbackUsed() public {
        uint256 a1 = _mk(false, 100 * P, 0);
        uint256 a2 = _mk(false, 200 * P, uint64(a1));
        uint256 dead = _mk(false, 150 * P, uint64(a1));
        h.unlink(dead);

        // pred is dead; pred2 is the true predecessor.
        uint256 aNew = h.create(false, 180 * P);
        h.insert(aNew, _hints4(uint64(dead), uint64(a1), 0, 0));
        _assertList(false, _arr3(a1, aNew, a2));
    }

    function test_insert_wrongSideHint_skipped() public {
        uint256 b1 = _mk(true, 100 * P, 0);
        uint256 a1 = _mk(false, 200 * P, 0);
        uint256 a2 = _mk(false, 300 * P, uint64(a1));

        // Hint points at a live BID; insert is an ask. The wrong-side candidate is skipped and
        // the head anchor resolves the position.
        uint256 aNew = h.create(false, 250 * P);
        h.insert(aNew, _hints(uint64(b1)));
        _assertList(false, _arr3(a1, aNew, a2));
        _assertList(true, _arr1(b1));
    }

    function test_insert_staleHint_forwardRepair() public {
        uint256 a1 = _mk(false, 100 * P, 0);
        uint256 a2 = _mk(false, 200 * P, uint64(a1));
        uint256 a3 = _mk(false, 300 * P, uint64(a2));
        uint256 a4 = _mk(false, 400 * P, uint64(a3));

        // Hint a1 sorts before the new order but is not the true predecessor — walk forward.
        uint256 aNew = h.create(false, 350 * P);
        h.insert(aNew, _hints(uint64(a1)));
        uint256[] memory expect = new uint256[](5);
        expect[0] = a1;
        expect[1] = a2;
        expect[2] = a3;
        expect[3] = aNew;
        expect[4] = a4;
        _assertList(false, expect);
    }

    function test_insert_staleHint_backwardRepair() public {
        uint256 a1 = _mk(false, 100 * P, 0);
        uint256 a2 = _mk(false, 200 * P, uint64(a1));
        uint256 a3 = _mk(false, 300 * P, uint64(a2));
        uint256 a4 = _mk(false, 400 * P, uint64(a3));

        // Hint a4 sorts after the new order — walk backward to the true slot.
        uint256 aNew = h.create(false, 150 * P);
        h.insert(aNew, _hints(uint64(a4)));
        uint256[] memory expect = new uint256[](5);
        expect[0] = a1;
        expect[1] = aNew;
        expect[2] = a2;
        expect[3] = a3;
        expect[4] = a4;
        _assertList(false, expect);
    }

    function test_insert_zeroHints_walksFromHead() public {
        uint256 a1 = _mk(false, 100 * P, 0);
        uint256 a2 = _mk(false, 200 * P, uint64(a1));
        uint256 a3 = _mk(false, 300 * P, uint64(a2));

        uint256 aNew = h.create(false, 250 * P);
        h.insert(aNew, _hints(0));
        _assertList(false, _arr4(a1, a2, aNew, a3));
    }

    function test_insert_repairCapBoundary() public {
        // Build an ascending ask ladder with exact hints (each insert is O(1)).
        uint256 n = BazaarTypes.MAX_WALK_STEPS + 1; // 65 nodes: tail insert needs exactly 64 advances
        uint256 prev = _mk(false, 1 * P, 0);
        for (uint256 i = 2; i <= n; ++i) {
            prev = _mk(false, i * P, uint64(prev));
        }

        // From the head anchor, linking after node 65 takes 64 advances — at the cap, succeeds.
        uint256 okId = h.create(false, (n + 1) * P);
        h.insert(okId, _hints(0));
        (,,, uint64 askCount) = h.heads();
        assertEq(uint256(askCount), n + 1, "cap-edge insert landed");

        // Now the list is 66 nodes: a fresh tail insert from the head needs 65 advances — reverts.
        uint256 failId = h.create(false, (n + 2) * P);
        vm.expectRevert(abi.encodeWithSelector(OrderBookLib.OrderBookLib__HintRepairExhausted.selector, failId));
        h.insert(failId, _hints(0));

        // The same insert with a fresh exact hint succeeds.
        h.insert(failId, _hints(uint64(okId)));
        (,,, askCount) = h.heads();
        assertEq(uint256(askCount), n + 2, "hinted insert landed");
    }

    function test_insert_alreadyInBook_reverts() public {
        uint256 a1 = _mk(false, 100 * P, 0);
        vm.expectRevert(abi.encodeWithSelector(OrderBookLib.OrderBookLib__AlreadyInBook.selector, a1));
        h.insert(a1, _hints(0));
    }

    function test_unlink_headMidTailSole() public {
        uint256 a1 = _mk(false, 100 * P, 0);
        uint256 a2 = _mk(false, 200 * P, uint64(a1));
        uint256 a3 = _mk(false, 300 * P, uint64(a2));
        uint256 a4 = _mk(false, 400 * P, uint64(a3));

        h.unlink(a3); // mid
        _assertList(false, _arr3(a1, a2, a4));
        h.unlink(a1); // head
        _assertList(false, _arr2(a2, a4));
        h.unlink(a4); // tail
        _assertList(false, _arr1(a2));
        h.unlink(a2); // sole
        _assertList(false, new uint256[](0));

        (bool inBook, uint64 prev, uint64 next,,) = h.node(a3);
        assertFalse(inBook, "unlinked flag cleared");
        assertEq(prev, 0, "unlinked prev cleared");
        assertEq(next, 0, "unlinked next cleared");
    }

    function test_unlink_notInBook_noop() public {
        uint256 a1 = _mk(false, 100 * P, 0);
        uint256 never = h.create(false, 200 * P); // created, never inserted
        h.unlink(never);
        h.unlink(12345); // nonexistent id
        _assertList(false, _arr1(a1));
    }

    function test_reinsert_afterUnlink() public {
        uint256 a1 = _mk(false, 100 * P, 0);
        uint256 a2 = _mk(false, 200 * P, uint64(a1));
        uint256 a3 = _mk(false, 300 * P, uint64(a2));

        h.unlink(a2);
        _assertList(false, _arr2(a1, a3));
        h.insert(a2, _hints(uint64(a1)));
        _assertList(false, _arr3(a1, a2, a3));
    }

    function test_sidesAreIndependent() public {
        uint256 b1 = _mk(true, 100 * P, 0);
        uint256 b2 = _mk(true, 99 * P, uint64(b1));
        uint256 a1 = _mk(false, 101 * P, 0);
        uint256 a2 = _mk(false, 102 * P, uint64(a1));

        _assertList(true, _arr2(b1, b2));
        _assertList(false, _arr2(a1, a2));

        h.unlink(b1);
        _assertList(true, _arr1(b2));
        _assertList(false, _arr2(a1, a2));
    }

    // -------------------- fuzz: random ops vs a reference model --------------------

    /// @dev Applies a bounded random op sequence (inserts with exact/zero/garbage hints,
    ///      unlinks of members and non-members) and after every op checks both sides against an
    ///      in-test sorted reference. Small price set forces equal-price tiebreak coverage; op
    ///      count stays under the repair cap so zero-hint inserts can never exhaust it.
    function testFuzz_randomOpsPreserveInvariants(uint256 seed) public {
        uint256[] memory refBids = new uint256[](0);
        uint256[] memory refAsks = new uint256[](0);

        for (uint256 op; op < 48; ++op) {
            seed = uint256(keccak256(abi.encode(seed, op)));
            bool side = seed % 2 == 0;
            uint256[] memory ref = side ? refBids : refAsks;
            uint256 action = (seed / 2) % 4; // 0..2 insert variants, 3 unlink

            if (action == 3 && ref.length > 0) {
                uint256 victim = ref[(seed / 8) % ref.length];
                h.unlink(victim);
                ref = _refRemove(ref, victim);
            } else if (action == 3) {
                h.unlink(1_000_000 + op); // non-member: must be a no-op
            } else {
                uint256 price = (((seed / 8) % 6) + 1) * P;
                uint256 id = h.create(side, price);
                BazaarTypes.MatchHints memory hints;
                if (action == 1 && ref.length > 0) {
                    // Garbage hint: random id — dead, wrong-side, or arbitrary member.
                    hints.pred = uint64((seed / 64) % (id + 4));
                } else if (action == 2) {
                    hints.pred = uint64(_refPredecessor(ref, side, id, price));
                }
                h.insert(id, hints);
                ref = _refInsert(ref, side, id, price);
            }

            if (side) {
                refBids = ref;
            } else {
                refAsks = ref;
            }
            _assertList(true, refBids);
            _assertList(false, refAsks);
        }
    }

    /// @dev Reference-model insert position: mirrors OrderBookLib's predicate over the
    ///      harness's stored prices.
    function _refPos(uint256[] memory ref, bool side, uint256 id, uint256 price) internal view returns (uint256) {
        for (uint256 i; i < ref.length; ++i) {
            (,,, uint256 pi,) = h.node(ref[i]);
            bool existingFirst = pi != price ? (side ? pi > price : pi < price) : ref[i] < id;
            if (!existingFirst) return i;
        }
        return ref.length;
    }

    function _refPredecessor(uint256[] memory ref, bool side, uint256 id, uint256 price)
        internal
        view
        returns (uint256)
    {
        uint256 pos = _refPos(ref, side, id, price);
        return pos == 0 ? 0 : ref[pos - 1];
    }

    function _refInsert(uint256[] memory ref, bool side, uint256 id, uint256 price)
        internal
        view
        returns (uint256[] memory out)
    {
        uint256 pos = _refPos(ref, side, id, price);
        out = new uint256[](ref.length + 1);
        for (uint256 i; i < pos; ++i) {
            out[i] = ref[i];
        }
        out[pos] = id;
        for (uint256 i = pos; i < ref.length; ++i) {
            out[i + 1] = ref[i];
        }
    }

    function _refRemove(uint256[] memory ref, uint256 id) internal pure returns (uint256[] memory out) {
        out = new uint256[](ref.length - 1);
        uint256 j;
        for (uint256 i; i < ref.length; ++i) {
            if (ref[i] == id) continue;
            out[j++] = ref[i];
        }
    }
}
