// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {OrderBookLib} from "../../src/libraries/OrderBookLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";

/// @notice Drives OrderBookLib over real storage: an orders mapping and an OrderBook struct,
///         mirroring how BazaarPair hosts them.
contract OrderBookHarness {
    mapping(uint256 => BazaarTypes.Order) internal orders;
    BazaarTypes.OrderBook internal book;
    uint256 internal nextOrderId = 1;
    /// @dev The index every insert stamps the far-side premium against; 0 (no index) by default.
    uint256 internal indexPrice;

    function create(bool isLong, uint256 limitPrice) external returns (uint256 orderId) {
        orderId = nextOrderId++;
        BazaarTypes.Order storage o = orders[orderId];
        o.creator = msg.sender;
        o.orderType = BazaarTypes.OrderType.Limit;
        o.isLong = isLong;
        o.limitPrice = uint128(limitPrice);
        o.size = 1e18;
        o.prioritySeq = uint48(orderId);
    }

    /// @dev Give a resting candidate the queue position an amendment would: a counter value past
    ///      every id so far.
    function setPrioritySeq(uint256 orderId, uint48 seq) external {
        orders[orderId].prioritySeq = seq;
    }

    function setIndex(uint256 index) external {
        indexPrice = index;
    }

    /// @dev A fresh queue position: the next counter value, as an amendment draws one.
    function drawSeq() external returns (uint48) {
        return uint48(nextOrderId++);
    }

    function prioritySeq(uint256 orderId) external view returns (uint48) {
        return orders[orderId].prioritySeq;
    }

    function staysInPlace(uint256 orderId, uint256 newPrice, uint64 newSeq) external view returns (bool) {
        return OrderBookLib.staysInPlace(orders, orders[orderId], newPrice, newSeq);
    }

    /// @dev A member takes a new price and queue position where it stands and is restamped, as an
    ///      amendment whose slot survives the new key writes it.
    function rewriteInPlace(uint256 orderId, uint256 newPrice, uint48 newSeq) external {
        BazaarTypes.Order storage o = orders[orderId];
        o.limitPrice = uint128(newPrice);
        o.prioritySeq = newSeq;
        OrderBookLib.restamp(o, uint64(block.number), indexPrice);
    }

    /// @dev The same change done as an unlink and an insert anchored on the old neighbours.
    function relink(uint256 orderId, uint256 newPrice, uint48 newSeq) external {
        BazaarTypes.Order storage o = orders[orderId];
        BazaarTypes.MatchHints memory hints;
        hints.pred3 = o.prevInBook;
        hints.pred4 = o.nextInBook;
        OrderBookLib.unlink(orders, book, orderId);
        o.limitPrice = uint128(newPrice);
        o.prioritySeq = newSeq;
        OrderBookLib.insert(orders, book, orderId, hints, uint64(block.number), indexPrice);
    }

    function insert(uint256 orderId, BazaarTypes.MatchHints calldata hints) external {
        OrderBookLib.insert(orders, book, orderId, hints, uint64(block.number), indexPrice);
    }

    function restedBlock(uint256 orderId) external view returns (uint32) {
        return orders[orderId].restedBlock;
    }

    function restedPremiumPpm(uint256 orderId) external view returns (uint16) {
        return orders[orderId].restedPremiumPpm;
    }

    function locate(uint256 orderId, BazaarTypes.MatchHints calldata hints)
        external
        view
        returns (bool found, uint64 pred)
    {
        return OrderBookLib.locate(orders, book, orderId, orders[orderId].prioritySeq, hints);
    }

    /// @dev locate under a queue position the order does not carry yet, as executeTriggers
    ///      resolves an arming StopLimit's slot before writing its new prioritySeq.
    function locateAt(uint256 orderId, uint64 seq, BazaarTypes.MatchHints calldata hints)
        external
        view
        returns (bool found, uint64 pred)
    {
        return OrderBookLib.locate(orders, book, orderId, seq, hints);
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
                // Strict ordering: better price first; equal price → earlier queue position first.
                if (price == prevPrice) {
                    assertLt(h.prioritySeq(prevId), h.prioritySeq(got[i]), "fifo tiebreak");
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

    /// @notice Linking stamps the order with the block it joined the book in, and a relink
    ///         restamps it: the stamp is the start of the order's exposure at its current slot,
    ///         not the order's age.
    function test_insert_stampsTheJoiningBlock_relinkRestamps() public {
        vm.roll(1_000_000);
        uint256 a = _mk(true, 100 * P, 0);
        assertEq(h.restedBlock(a), 1_000_000, "stamped with the linking block");

        vm.roll(1_000_300);
        h.unlink(a);
        assertEq(h.restedBlock(a), 1_000_000, "unlink leaves the stamp; it is read only for members");
        h.insert(a, _hints(0));
        assertEq(h.restedBlock(a), 1_000_300, "relinking restamps");
    }

    /// @notice Linking stamps how far on the far side of the index the order stood — a bid above
    ///         it, an ask below it — in millionths of the index, rounded up; the near side, the
    ///         index itself and a link with no index stamp zero.
    function test_insert_stampsTheFarSidePremium() public {
        h.setIndex(100 * P);
        assertEq(h.restedPremiumPpm(_mk(true, 101 * P, 0)), 10_000, "bid 1% above the index");
        assertEq(h.restedPremiumPpm(_mk(false, 99 * P, 0)), 10_000, "ask 1% below the index");
        assertEq(h.restedPremiumPpm(_mk(true, 99 * P, 0)), 0, "bid below the index: near side");
        assertEq(h.restedPremiumPpm(_mk(false, 101 * P, 0)), 0, "ask above the index: near side");
        assertEq(h.restedPremiumPpm(_mk(true, 100 * P, 0)), 0, "at the index");
        assertEq(h.restedPremiumPpm(_mk(false, 100 * P, 0)), 0, "at the index, ask side");
        // 0.0333...% above: 333.33 ppm, rounded up.
        assertEq(h.restedPremiumPpm(_mk(true, 100 * P + P / 30, 0)), 334, "rounded up");

        h.setIndex(0);
        assertEq(h.restedPremiumPpm(_mk(true, 150 * P, 0)), 0, "no index: nothing stamped");
    }

    /// @notice The stamp is capped at the mark's band: the mark never reads past it, so a farther
    ///         quote proves no more.
    function test_insert_farSidePremiumCappedAtTheBand() public {
        h.setIndex(100 * P);
        uint256 cap = FundingLib.MAX_MARK_DEVIATION_BP * FundingLib.RESTED_PREMIUM_SCALE / 10_000;
        assertEq(h.restedPremiumPpm(_mk(true, 110 * P, 0)), cap, "bid 10% above: the band");
        assertEq(h.restedPremiumPpm(_mk(false, 60 * P, 0)), cap, "ask 40% below: the band");
        assertEq(h.restedPremiumPpm(_mk(true, 104 * P, 0)), cap, "exactly the band");
    }

    /// @notice A relink re-measures the stamp against the index of its own moment, and an unlink
    ///         leaves it in place, read only for members.
    function test_insert_relinkRemeasuresThePremium() public {
        h.setIndex(100 * P);
        uint256 a = _mk(true, 101 * P, 0);
        assertEq(h.restedPremiumPpm(a), 10_000, "linked 1% over the index");

        h.setIndex(102 * P);
        h.unlink(a);
        assertEq(h.restedPremiumPpm(a), 10_000, "unlink leaves the stamp");
        h.insert(a, _hints(0));
        assertEq(h.restedPremiumPpm(a), 0, "relinked on the near side of the new index");

        h.setIndex(98 * P);
        h.unlink(a);
        h.insert(a, _hints(0));
        // (101 - 98) / 98 = 3.0612%: 30612.24 ppm, rounded up.
        assertEq(h.restedPremiumPpm(a), 30_613, "relinked on the far side of the next one");
    }

    /// @notice Within a price level the queue is ordered by prioritySeq, not by id: an older order
    ///         that re-enters the level under a later queue position rests behind a younger one
    ///         that was already there.
    function test_insert_equalPrice_queuesByPrioritySeq() public {
        uint256 a = h.create(true, 100 * P); // id 1
        uint256 b = h.create(true, 100 * P); // id 2
        h.insert(b, _hints(0));
        h.setPrioritySeq(a, 3); // a is repriced onto the level after b rested there
        h.insert(a, _hints(0));
        uint256[] memory ids = h.traverse(true);
        assertEq(ids.length, 2);
        assertEq(ids[0], b, "the order already resting keeps the front");
        assertEq(ids[1], a, "the lower id queues behind under its later queue position");
        (bool found, uint64 pred) = h.locate(h.create(true, 100 * P), _hints(0));
        assertTrue(found);
        assertEq(pred, uint64(a), "a fresh order at the level queues behind both");
    }

    /// @notice locate resolves the slot under the queue position it is handed, not the one the
    ///         order carries — how executeTriggers places an arming StopLimit before writing its
    ///         new prioritySeq. An old id handed a later position lands behind the level, and the
    ///         insert that follows under that stored value links at the slot locate reported.
    function test_locate_atGivenSeq_resolvesUnderThatSeq() public {
        uint256 s = h.create(true, 100 * P); // id 1, waiting outside the book like a dormant stop
        uint256 m1 = _mk(true, 100 * P, 0); // id 2
        uint256 m2 = _mk(true, 100 * P, uint64(m1)); // id 3
        (bool found, uint64 pred) = h.locate(s, _hints(0));
        assertTrue(found);
        assertEq(pred, 0, "under its creation id the older order would take the front of the level");
        (found, pred) = h.locateAt(s, 4, _hints(0));
        assertTrue(found);
        assertEq(pred, uint64(m2), "under a later queue position it rests behind the whole level");
        h.setPrioritySeq(s, 4);
        h.insert(s, _hints(pred));
        uint256[] memory ids = h.traverse(true);
        assertEq(ids.length, 3);
        assertEq(ids[0], m1);
        assertEq(ids[1], m2);
        assertEq(ids[2], s, "linked where locate reported");
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
        // One node past the cap, so a tail insert from the head anchor needs exactly
        // MAX_WALK_STEPS advances.
        uint256 n = BazaarTypes.MAX_WALK_STEPS + 1;
        uint256 prev = _mk(false, 1 * P, 0);
        for (uint256 i = 2; i <= n; ++i) {
            prev = _mk(false, i * P, uint64(prev));
        }

        // From the head anchor, linking after the last node takes exactly MAX_WALK_STEPS advances —
        // at the cap, succeeds.
        uint256 okId = h.create(false, (n + 1) * P);
        h.insert(okId, _hints(0));
        (,,, uint64 askCount) = h.heads();
        assertEq(uint256(askCount), n + 1, "cap-edge insert landed");

        // The list is one node longer now: a fresh tail insert from the head needs
        // MAX_WALK_STEPS + 1 advances — past the cap, reverts.
        uint256 failId = h.create(false, (n + 2) * P);
        vm.expectRevert(abi.encodeWithSelector(OrderBookLib.OrderBookLib__HintRepairExhausted.selector, failId));
        h.insert(failId, _hints(0));

        // The same insert with a fresh exact hint succeeds.
        h.insert(failId, _hints(uint64(okId)));
        (,,, askCount) = h.heads();
        assertEq(uint256(askCount), n + 2, "hinted insert landed");
    }

    function test_locate_headWhenEmptyOrAheadOfHead() public {
        uint256 a = h.create(false, 5 * P);
        (bool found, uint64 pred) = h.locate(a, _hints(0));
        assertTrue(found, "empty side: found");
        assertEq(uint256(pred), 0, "empty side: head slot");
        h.insert(a, _hints(0));

        uint256 b = h.create(false, 3 * P); // sorts ahead of the ask head
        (found, pred) = h.locate(b, _hints(uint64(a)));
        assertTrue(found, "ahead of head: found");
        assertEq(uint256(pred), 0, "ahead of head: head slot, hint irrelevant");
    }

    function test_locate_matchesInsertPlacement() public {
        uint256 a = _mk(false, 1 * P, 0);
        uint256 c = _mk(false, 3 * P, uint64(a));
        uint256 e = _mk(false, 5 * P, uint64(c));
        uint256 d = h.create(false, 4 * P);

        // Anchor two nodes short of the slot: the bounded walk names the same predecessor insert
        // links behind.
        (bool found, uint64 pred) = h.locate(d, _hints(uint64(a)));
        assertTrue(found, "found");
        assertEq(pred, uint64(c), "rests behind the 3P ask");
        h.insert(d, _hints(pred));
        (, uint64 prv, uint64 nxt,,) = h.node(d);
        assertEq(uint256(prv), c, "prev");
        assertEq(uint256(nxt), e, "next");
    }

    function test_locate_reportsNotFoundPastCap_neverReverts() public {
        // One node past the length at which a tail insert from the head is exactly at the cap.
        uint256 n = BazaarTypes.MAX_WALK_STEPS + 2;
        uint256 prev = _mk(false, 1 * P, 0);
        for (uint256 i = 2; i <= n; ++i) {
            prev = _mk(false, i * P, uint64(prev));
        }
        uint256 id = h.create(false, (n + 1) * P);

        (bool found, uint64 pred) = h.locate(id, _hints(0));
        assertFalse(found, "tail slot is past the cap from the head anchor");
        assertEq(uint256(pred), 0, "no predecessor reported");

        // The same query with a live hint at the tail resolves without a walk.
        (found, pred) = h.locate(id, _hints(uint64(prev)));
        assertTrue(found, "exact hint resolves");
        assertEq(pred, uint64(prev), "predecessor is the tail");

        // locate mutated nothing either way.
        (,,, uint64 askCount) = h.heads();
        assertEq(uint256(askCount), n, "book untouched");
        (bool inBook,,,,) = h.node(id);
        assertFalse(inBook, "order not linked");
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

    // -------------------- in-place rewrite --------------------

    /// @notice A member keeps its slot under a new key exactly when its predecessor still sorts
    ///         ahead of the key and its successor still behind it. The predecessor's own price
    ///         keeps the slot — under the later queue position the order belongs behind it, where
    ///         it already is — while the successor's price does not: there it belongs behind the
    ///         successor too.
    function test_staysInPlace_middleOrder() public {
        uint256 b1 = _mk(true, 100 * P, 0);
        uint256 b2 = _mk(true, 90 * P, uint64(b1));
        uint256 b3 = _mk(true, 80 * P, uint64(b2));
        uint64 seq = uint64(h.drawSeq());
        assertTrue(h.staysInPlace(b2, 95 * P, seq), "between its neighbours' prices");
        assertTrue(h.staysInPlace(b2, 85 * P, seq));
        assertTrue(h.staysInPlace(b2, 100 * P, seq), "at the predecessor's price, behind it");
        assertFalse(h.staysInPlace(b2, 80 * P, seq), "at the successor's price it belongs behind it");
        assertFalse(h.staysInPlace(b2, 105 * P, seq), "ahead of the predecessor");
        assertFalse(h.staysInPlace(b2, 75 * P, seq), "behind the successor");
        assertFalse(h.staysInPlace(b3, 95 * P, seq), "the tail moved up past its predecessor");
    }

    /// @notice A missing neighbour never fails the test: the head keeps its slot under any better
    ///         price, the tail under any worse one, and an order alone on its side under every
    ///         price.
    function test_staysInPlace_headTailAndSole() public {
        uint256 b1 = _mk(true, 100 * P, 0);
        uint256 b2 = _mk(true, 90 * P, uint64(b1));
        uint256 a1 = _mk(false, 110 * P, 0);
        uint64 seq = uint64(h.drawSeq());
        assertTrue(h.staysInPlace(b1, 1_000 * P, seq), "the head improves in place");
        assertTrue(h.staysInPlace(b1, 91 * P, seq));
        assertFalse(h.staysInPlace(b1, 90 * P, seq), "onto the successor's level");
        assertFalse(h.staysInPlace(b1, 1, seq), "past the successor");
        assertTrue(h.staysInPlace(b2, 1, seq), "the tail worsens in place");
        assertTrue(h.staysInPlace(b2, 100 * P, seq), "onto the predecessor's level, behind it");
        assertFalse(h.staysInPlace(b2, 101 * P, seq), "ahead of the predecessor");
        assertTrue(h.staysInPlace(a1, 1, seq), "alone on its side");
        assertTrue(h.staysInPlace(a1, 1_000 * P, seq));
    }

    /// @notice Asks mirror bids: the lower price leads.
    function test_staysInPlace_asksMirror() public {
        uint256 a1 = _mk(false, 100 * P, 0);
        uint256 a2 = _mk(false, 110 * P, uint64(a1));
        uint256 a3 = _mk(false, 120 * P, uint64(a2));
        uint64 seq = uint64(h.drawSeq());
        assertTrue(h.staysInPlace(a2, 105 * P, seq));
        assertTrue(h.staysInPlace(a2, 115 * P, seq));
        assertTrue(h.staysInPlace(a2, 100 * P, seq), "at the predecessor's price, behind it");
        assertFalse(h.staysInPlace(a2, 120 * P, seq), "at the successor's price");
        assertFalse(h.staysInPlace(a2, 95 * P, seq));
        assertFalse(h.staysInPlace(a2, 125 * P, seq));
        assertFalse(h.staysInPlace(a3, 105 * P, seq));
    }

    /// @notice An in-place rewrite stamps what a link stamps: the current block, and the far-side
    ///         premium of the new price against the index — the same values a fresh order linked
    ///         at that price receives.
    function test_rewriteInPlace_restampsLikeALink() public {
        h.setIndex(100 * P);
        uint256 b1 = _mk(true, 100 * P, 0);
        assertEq(h.restedPremiumPpm(b1), 0, "at the index: no premium");
        uint32 linkedAt = h.restedBlock(b1);
        vm.roll(vm.getBlockNumber() + 7);

        h.rewriteInPlace(b1, 101 * P, h.drawSeq());

        assertEq(h.restedBlock(b1), uint32(vm.getBlockNumber()), "rests from the rewrite's block");
        assertGt(h.restedBlock(b1), linkedAt);
        assertEq(h.restedPremiumPpm(b1), FundingLib.restedPremiumOf(true, 101 * P, 100 * P), "the new price's premium");
        uint256 fresh = _mk(true, 101 * P, 0);
        assertEq(h.restedPremiumPpm(fresh), h.restedPremiumPpm(b1), "what a link stamps at that price");
        assertEq(h.restedBlock(fresh), h.restedBlock(b1));
        _assertList(true, _arr2(b1, fresh));
    }

    /// @notice Written in place, a member whose slot survives leaves every stored field of every
    ///         order, both heads and both counts exactly as an unlink and an insert would: the
    ///         middle, head and tail of the bids and the tail of the asks, and a move onto the
    ///         predecessor's level.
    function test_rewriteInPlace_leavesTheBookAsARelinkWould() public {
        OrderBookHarness a = new OrderBookHarness();
        OrderBookHarness b = new OrderBookHarness();
        _ladder(a);
        _ladder(b);
        assertTrue(_moveBoth(a, b, 2, 95 * P, 5), "between its neighbours");
        assertTrue(_moveBoth(a, b, 1, 105 * P, 5), "the head improves");
        assertTrue(_moveBoth(a, b, 3, 70 * P, 5), "the tail worsens");
        assertTrue(_moveBoth(a, b, 5, 130 * P, 5), "the ask tail worsens");
        assertTrue(_moveBoth(a, b, 2, 105 * P, 5), "onto the predecessor's level, behind it");
        assertFalse(_moveBoth(a, b, 1, 90 * P, 5), "past its successor: relinked");
        uint256[] memory bids = b.traverse(true);
        assertEq(bids.length, 3);
        assertEq(bids[0], 2);
        assertEq(bids[1], 1);
        assertEq(bids[2], 3);
        _assertSorted(b, true);
        _assertSorted(b, false);
    }

    /// @notice Under random ladders and random moves, writing in place whenever the slot survives
    ///         leaves the book identical to relinking every time.
    function testFuzz_rewriteInPlace_equalsRelink(uint256 seed) public {
        OrderBookHarness a = new OrderBookHarness();
        OrderBookHarness b = new OrderBookHarness();
        a.setIndex(4 * P);
        b.setIndex(4 * P);
        uint256 n = 3 + seed % 8;
        for (uint256 i; i < n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            bool side = seed % 2 == 0;
            uint256 price = ((seed / 2) % 6 + 1) * P;
            uint256 id = a.create(side, price);
            assertEq(b.create(side, price), id, "the harnesses number in step");
            a.insert(id, _hints(0));
            b.insert(id, _hints(0));
        }
        for (uint256 m; m < 4; ++m) {
            seed = uint256(keccak256(abi.encode(seed, "move", m)));
            _moveBoth(a, b, 1 + seed % n, ((seed / 8) % 8 + 1) * P, n);
        }
        _assertSorted(b, true);
        _assertSorted(b, false);
    }

    /// @dev Three bids at 100, 90 and 80 (ids 1-3) and two asks at 110 and 120 (ids 4-5), with the
    ///      index at 95 so the stamps carry premiums.
    function _ladder(OrderBookHarness hh) internal {
        hh.setIndex(95 * P);
        uint256 b1 = hh.create(true, 100 * P);
        hh.insert(b1, _hints(0));
        uint256 b2 = hh.create(true, 90 * P);
        hh.insert(b2, _hints(uint64(b1)));
        uint256 b3 = hh.create(true, 80 * P);
        hh.insert(b3, _hints(uint64(b2)));
        uint256 a1 = hh.create(false, 110 * P);
        hh.insert(a1, _hints(0));
        uint256 a2 = hh.create(false, 120 * P);
        hh.insert(a2, _hints(uint64(a1)));
    }

    /// @dev Apply one move to both harnesses under the same fresh queue position — `a` always by
    ///      relink, `b` in place when its slot survives — a block later than the last, and compare
    ///      their whole state over orders 1..n. Returns whether the move was written in place.
    function _moveBoth(OrderBookHarness a, OrderBookHarness b, uint256 id, uint256 price, uint256 n)
        internal
        returns (bool inPlace)
    {
        vm.roll(vm.getBlockNumber() + 1);
        uint48 seq = a.drawSeq();
        assertEq(b.drawSeq(), seq, "the harnesses draw in step");
        inPlace = b.staysInPlace(id, price, seq);
        a.relink(id, price, seq);
        if (inPlace) {
            b.rewriteInPlace(id, price, seq);
        } else {
            b.relink(id, price, seq);
        }
        assertEq(_bookState(b, n), _bookState(a, n), "the book reads the same either way");
    }

    /// @dev Every field the book writes on an order, in one word.
    function _nodeState(OrderBookHarness hh, uint256 id) internal view returns (bytes32) {
        (bool inBook, uint64 prev, uint64 next, uint256 price, bool isLong) = hh.node(id);
        return keccak256(
            abi.encode(
                inBook, prev, next, price, isLong, hh.prioritySeq(id), hh.restedBlock(id), hh.restedPremiumPpm(id)
            )
        );
    }

    /// @dev Both heads, both counts and every order 1..n, in one word.
    function _bookState(OrderBookHarness hh, uint256 n) internal view returns (bytes32 acc) {
        (uint64 bidHead, uint64 askHead, uint64 bidCount, uint64 askCount) = hh.heads();
        acc = keccak256(abi.encode(bidHead, askHead, bidCount, askCount));
        for (uint256 id = 1; id <= n; ++id) {
            acc = keccak256(abi.encode(acc, _nodeState(hh, id)));
        }
    }

    /// @dev One side of `hh` traverses to its count with reciprocal links, strictly sorted by price
    ///      and then by queue position.
    function _assertSorted(OrderBookHarness hh, bool side) internal view {
        uint256[] memory got = hh.traverse(side);
        uint64 prevId;
        for (uint256 i; i < got.length; ++i) {
            (bool inBook, uint64 prev,, uint256 price, bool isLong) = hh.node(got[i]);
            assertTrue(inBook && isLong == side, "a member of this side");
            assertEq(prev, prevId, "prev reciprocity");
            if (i > 0) {
                (,,, uint256 prevPrice,) = hh.node(prevId);
                bool ordered = price == prevPrice
                    ? hh.prioritySeq(prevId) < hh.prioritySeq(got[i])
                    : (side ? price < prevPrice : price > prevPrice);
                assertTrue(ordered, "strictly sorted");
            }
            prevId = uint64(got[i]);
        }
    }

    // -------------------- fuzz: random ops vs a reference model --------------------

    /// @dev Applies a bounded random op sequence (inserts with exact/zero/garbage hints,
    ///      unlinks of members and non-members) and after every op checks both sides against an
    ///      in-test sorted reference. Small price set forces equal-price tiebreak coverage; op
    ///      count stays under the repair cap so zero-hint inserts can never exhaust it.
    /// @dev The fuzz reference model, held in STORAGE rather than as loop locals. Two array
    ///      pointers plus the op's own locals plus the two inlined per-op list assertions
    ///      overflow via-IR's stack scheduler; keeping the model in storage leaves the loop
    ///      frame holding little more than the seed.
    uint256[] private fzBids;
    uint256[] private fzAsks;

    function testFuzz_randomOpsPreserveInvariants(uint256 seed) public {
        delete fzBids;
        delete fzAsks;

        for (uint256 op; op < 48; ++op) {
            seed = uint256(keccak256(abi.encode(seed, op)));
            _fuzzStep(seed, op);
            _assertList(true, fzBids);
            _assertList(false, fzAsks);
        }
    }

    /// @dev One op of the fuzz sequence: an insert (exact, garbage, or zero hint) or an unlink
    ///      of a member or a non-member, applied to both the book and the reference model.
    function _fuzzStep(uint256 seed, uint256 op) internal {
        bool side = seed % 2 == 0;
        uint256[] memory ref = side ? fzBids : fzAsks;
        uint256 action = (seed / 2) % 4; // 0..2 insert variants, 3 unlink

        if (action == 3) {
            if (ref.length == 0) {
                h.unlink(1_000_000 + op); // non-member: must be a no-op
                return;
            }
            uint256 victim = ref[(seed / 8) % ref.length];
            h.unlink(victim);
            ref = _refRemove(ref, victim);
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
            fzBids = ref;
        } else {
            fzAsks = ref;
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
