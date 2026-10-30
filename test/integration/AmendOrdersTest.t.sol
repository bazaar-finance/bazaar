// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";
import {OrderBookLib} from "../../src/libraries/OrderBookLib.sol";
import {OrderView} from "../OrderView.sol";

/// @title AmendOrdersTest
/// @notice amendOrders rewrites resting limit orders in place. An order keeps its id, its expiry
///         and its place in the owner's set, and takes a new price and size. A new price or a
///         larger size sends it to the back of its new level under a fresh queue position; a
///         smaller size at the same price keeps its place. Up to two predecessor hints ride in
///         the id word, with the order's old neighbours as the fallback anchor. The batch never
///         crosses the book and is all or nothing, and margin is judged once on the set the batch
///         leaves.
contract AmendOrdersTest is IntegrationBase {
    uint256 constant BTC = 1e18;
    uint256 constant SIZE = BTC / 10;

    /// @dev One batch: the flat word triples the entry point takes.
    struct Batch {
        uint256[] words;
    }

    // ---------------------------- helpers ----------------------------

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

    function _bidHead() internal view returns (uint64 head) {
        (head,,,) = pair.book();
    }

    function _askHead() internal view returns (uint64 head) {
        (, head,,) = pair.book();
    }

    function _next(uint256 orderId) internal view returns (uint64) {
        return OrderView.order(pair, orderId).nextInBook;
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

    function _crossErr(uint256 orderId, uint256 price, uint256 best) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                OrderManagementLib.OrderManagementLib__AmendWouldCross.selector, orderId, price, best
            );
    }

    /// @dev The refusal of a move with less than the minimum lifetime left, judged at this block.
    function _lifetimeErr(uint256 orderId, uint64 expiry) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            OrderManagementLib.OrderManagementLib__AmendTooCloseToExpiry.selector,
            orderId,
            expiry,
            uint64(vm.getBlockNumber()) + BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS
        );
    }

    /// @dev `user` rests a bid of `size` at `priceUsd` that expires `life` blocks from now.
    function _bidExpiringIn(address user, uint256 size, uint256 priceUsd, uint64 life) internal returns (uint256) {
        BazaarTypes.OrderSpec memory s = _limitSpec(true, size, priceUsd * BAZAAR_SCALE);
        s.expirationBlock = uint64(vm.getBlockNumber()) + life;
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        return _lastCreatedOrderId(pair);
    }

    /// @dev `n` of alice's 0.001 BTC bids at 26k, all expiring `life` blocks from now, below
    ///      bob's 0.1 BTC bid at 49,900 (returned as `honest`).
    function _deepWallBehindAnHonestBid(uint256 n, uint64 life)
        internal
        returns (uint256 honest, uint256[] memory ids)
    {
        _deposit(bob, 10_000 * BAZAAR_SCALE);
        honest = _placeLimit(bob, true, SIZE, 49_900 * BAZAAR_SCALE);
        _deposit(alice, 10_000 * BAZAAR_SCALE);
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = _bidExpiringIn(alice, BTC / 1000, 26_000, life);
        }
    }

    /// @dev One batch moving every order in `ids` to 49,901, one dollar above the honest bid, each
    ///      hinted to rest behind the one before it.
    function _wallToTheFront(uint256[] memory ids) internal pure returns (Batch memory b) {
        b = _batch(ids.length);
        for (uint256 i; i < ids.length; ++i) {
            _set(b, i, ids[i], 49_901 * BAZAAR_SCALE, BTC / 1000);
            b.words[3 * i] = _word(ids[i], i == 0 ? 0 : uint64(ids[i - 1]), 0);
        }
    }

    // ---------------------------- queue position ----------------------------

    /// @notice A repriced order joins its new level at the back, behind the order that was
    ///         already resting there, under a queue position drawn from the id counter; a taker
    ///         at that level fills the incumbent first.
    function test_reprice_goesToTheBackOfTheNewLevel() public {
        (uint256 a, uint256 b) = _twoBids();
        uint256 counter = lens.nextOrderId(address(pair));

        _amendAs(alice, _single(a, 48_000 * BAZAAR_SCALE, SIZE));

        assertEq(_bidHead(), uint64(b), "bob's older order at 48k keeps the front");
        assertEq(_next(b), uint64(a), "alice queues behind it");
        assertEq(_seq(a), uint64(counter), "the queue position is the counter value the amend drew");
        assertEq(lens.nextOrderId(address(pair)), counter + 1, "and the counter moved past it");
        assertEq(OrderView.order(pair, a).limitPrice, 48_000 * BAZAAR_SCALE, "new price stored");
        assertTrue(OrderView.order(pair, a).inBook, "still resting");

        _sell(SIZE, 48_000);
        assertEq(_posSize(bob), SIZE, "the incumbent filled");
        assertEq(_posSize(alice), 0, "the repriced order waited its turn");
    }

    /// @notice Shrinking an order at its price keeps its place: nothing is taken from anyone
    ///         behind it, and the queue position stays the id.
    function test_shrink_keepsItsPlace() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 a = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);
        _roll(1);
        uint256 b = _placeLimit(bob, true, SIZE, 49_000 * BAZAAR_SCALE);
        uint256 counter = lens.nextOrderId(address(pair));

        _amendAs(alice, _single(a, 49_000 * BAZAAR_SCALE, SIZE / 2));

        assertEq(_bidHead(), uint64(a), "alice keeps the front");
        assertEq(_next(a), uint64(b));
        assertEq(_seq(a), uint64(a), "the queue position is untouched");
        assertEq(lens.nextOrderId(address(pair)), counter, "no counter value was drawn");
        assertEq(OrderView.order(pair, a).size, SIZE / 2, "new size stored");

        _sell(SIZE / 2, 49_000);
        assertEq(_posSize(alice), SIZE / 2, "alice fills first");
        assertEq(_posSize(bob), 0);
    }

    /// @notice Growing an order is a new claim on its level: it goes to the back even at the same
    ///         price.
    function test_grow_goesToTheBack() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 a = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);
        _roll(1);
        uint256 b = _placeLimit(bob, true, SIZE, 49_000 * BAZAAR_SCALE);
        uint256 counter = lens.nextOrderId(address(pair));

        _amendAs(alice, _single(a, 49_000 * BAZAAR_SCALE, 2 * SIZE));

        assertEq(_bidHead(), uint64(b), "bob moves to the front");
        assertEq(_next(b), uint64(a));
        assertEq(_seq(a), uint64(counter));
        assertEq(OrderView.order(pair, a).size, 2 * SIZE);
    }

    /// @notice An amendment that changes nothing changes nothing: no queue position is drawn and
    ///         no event is emitted for it.
    function test_noChange_isANoOp() public {
        (uint256 a,) = _twoBids();
        uint256 counter = lens.nextOrderId(address(pair));

        vm.recordLogs();
        _amendAs(alice, _single(a, 49_000 * BAZAAR_SCALE, SIZE));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256(
            "OrderUpdated(bytes32,uint256,address,(uint8,uint8,bool,bool,uint256,uint256,uint256,uint256,uint256,uint64,uint64,uint64,uint64,uint8,address,uint8))"
        );
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != topic, "no OrderUpdated for an unchanged order");
        }
        assertEq(_seq(a), uint64(a));
        assertEq(lens.nextOrderId(address(pair)), counter);
    }

    /// @notice The same order amended twice in one batch ends at the last amendment, having drawn
    ///         a queue position for each move.
    function test_sameOrderTwiceInABatch() public {
        (uint256 a,) = _twoBids();
        uint256 counter = lens.nextOrderId(address(pair));
        Batch memory b = _batch(2);
        _set(b, 0, a, 48_500 * BAZAAR_SCALE, SIZE);
        _set(b, 1, a, 47_000 * BAZAAR_SCALE, SIZE);

        _amendAs(alice, b);

        assertEq(OrderView.order(pair, a).limitPrice, 47_000 * BAZAAR_SCALE);
        assertEq(_seq(a), uint64(counter + 1), "the second move drew the second value");
        assertEq(lens.nextOrderId(address(pair)), counter + 2);
        uint256[] memory bids = _bids();
        assertEq(bids.length, 2);
        assertEq(bids[1], a, "now the lowest bid");
    }

    /// @notice The event reports the order as stored after the amendment, under the Amended action.
    function test_emitsAmendedWithTheNewState() public {
        (uint256 a,) = _twoBids();
        uint64 expiry = OrderView.order(pair, a).expiryBlock;
        uint64 seq = uint64(lens.nextOrderId(address(pair)));

        vm.expectEmit(true, true, true, true, address(pair));
        emit BazaarTypes.OrderUpdated(
            pair.pairId(),
            a,
            alice,
            BazaarTypes.OrderUpdatePayload({
                action: BazaarTypes.OrderAction.Amended,
                orderType: BazaarTypes.OrderType.Limit,
                isLong: true,
                isPostOnly: false,
                size: 2 * SIZE,
                filledSize: 0,
                triggerPrice: 0,
                limitPrice: 48_500 * BAZAAR_SCALE,
                maxSlippageBp: 0,
                canceledBlock: 0,
                filledBlock: 0,
                expiryBlock: expiry,
                prioritySeq: seq,
                tif: BazaarTypes.TimeInForce.GTC,
                integrator: address(0),
                cancelReason: BazaarTypes.CancelReason.None
            })
        );
        _amendAs(alice, _single(a, 48_500 * BAZAAR_SCALE, 2 * SIZE));
    }

    /// @notice A relinked order finds its slot from its old neighbours, in either direction: down
    ///         past bob from the head, then back up past him to the head.
    function test_relink_anchoredOnOldNeighbours() public {
        (uint256 a, uint256 b) = _twoBids();
        _amendAs(alice, _single(a, 48_000 * BAZAAR_SCALE, SIZE));
        assertEq(_bidHead(), uint64(b));
        assertEq(_next(b), uint64(a), "behind bob");

        _amendAs(alice, _single(a, 49_500 * BAZAAR_SCALE, SIZE));
        assertEq(_bidHead(), uint64(a), "back at the head");
        assertEq(_next(a), uint64(b));
    }

    /// @dev alice bids 49k; forty bids from bob (his cap of 32) and carol rest below her, ten
    ///      dollars apart from 48,990 down, each hinted at the one before it since an unhinted
    ///      walk from the head cannot reach that deep either. Returns alice's id and the ladder,
    ///      head first.
    function _ladderBelowAlice() internal returns (uint256 a, uint256[] memory ids) {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 80_000 * BAZAAR_SCALE);
        _deposit(carol, 40_000 * BAZAAR_SCALE);
        a = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);
        ids = new uint256[](BazaarTypes.MAX_WALK_STEPS + 8);
        for (uint256 i; i < ids.length; ++i) {
            address who = i < BazaarTypes.MAX_ACTIVE_LIMIT_ORDERS_PER_USER ? bob : carol;
            BazaarTypes.MatchHints memory h;
            h.pred = i == 0 ? 0 : uint64(ids[i - 1]);
            bytes[] memory pu = _freshPrice();
            vm.prank(who);
            pair.createOrder(_limitSpec(true, SIZE, (48_990 - 10 * i) * BAZAAR_SCALE), h, pu, 0, 0, 0, "", "");
            ids[i] = _lastCreatedOrderId(pair);
        }
        assertEq(_bids().length, ids.length + 1);
    }

    /// @dev Every bid is strictly behind the one before it: a lower price, or the same price and
    ///      a later queue position.
    function _assertBidsSorted() internal view {
        uint256[] memory bids = _bids();
        for (uint256 i = 1; i < bids.length; ++i) {
            uint256 prevPrice = OrderView.order(pair, bids[i - 1]).limitPrice;
            uint256 price = OrderView.order(pair, bids[i]).limitPrice;
            assertTrue(
                price < prevPrice || (price == prevPrice && _seq(bids[i]) > _seq(bids[i - 1])), "bids out of order"
            );
        }
    }

    /// @notice A move further than MAX_WALK_STEPS nodes from the order's old slot, with no hint, is
    ///         refused: the walk from the old neighbours gives up, and the move takes a hint or is
    ///         a cancel and a new order.
    function test_relink_farMove_refused() public {
        (uint256 a,) = _ladderBelowAlice();
        _amendExpect(
            alice,
            _single(a, 48_000 * BAZAAR_SCALE, SIZE),
            abi.encodeWithSelector(OrderBookLib.OrderBookLib__HintRepairExhausted.selector, a)
        );
        assertEq(OrderView.order(pair, a).limitPrice, 49_000 * BAZAAR_SCALE, "untouched");
        assertEq(_bidHead(), uint64(a), "still resting at the head");

        // Within the walk's reach the same order moves without a hint.
        _amendAs(alice, _single(a, 48_800 * BAZAAR_SCALE, SIZE));
        assertEq(OrderView.order(pair, a).limitPrice, 48_800 * BAZAAR_SCALE);
        assertEq(_bids()[20], a, "behind the 19 bids priced above 48,800 and the one already resting at it");
        _assertBidsSorted();
    }

    /// @notice An exact hint carries the same far move: the order rests behind the hinted order,
    ///         however far that is from its old slot. The lens packs the word the test packs.
    function test_hint_exactReachesAFarSlot() public {
        (uint256 a, uint256[] memory ids) = _ladderBelowAlice();
        uint256 last = ids[ids.length - 1];
        assertEq(lens.amendIdWord(uint64(a), uint64(last), 0), _word(a, uint64(last), 0));
        _amendAs(alice, _singleHinted(a, uint64(last), 0, 48_000 * BAZAAR_SCALE, SIZE));
        assertEq(_next(last), uint64(a), "behind the hinted order");
        assertEq(_next(a), 0, "at the tail");
        _assertBidsSorted();
    }

    /// @notice A hint a few nodes short of the slot — the book moved between the caller's view and
    ///         inclusion — anchors the repair walk near the slot and still lands the order.
    function test_hint_nearlyRight_repairedByWalk() public {
        (uint256 a, uint256[] memory ids) = _ladderBelowAlice();
        _amendAs(alice, _singleHinted(a, uint64(ids[30]), 0, 48_000 * BAZAAR_SCALE, SIZE));
        assertEq(_next(ids[ids.length - 1]), uint64(a), "walked the last nine rungs from the hint");
        _assertBidsSorted();
    }

    /// @notice The second hint is tried when the first is unusable, so a caller can name two
    ///         candidates at the target level in case one fills or cancels before inclusion.
    function test_hint_secondUsedWhenFirstIsDead() public {
        (uint256 a, uint256[] memory ids) = _ladderBelowAlice();
        uint256 last = ids[ids.length - 1];
        _amendAs(alice, _singleHinted(a, uint64(999_999), uint64(last), 48_000 * BAZAAR_SCALE, SIZE));
        assertEq(_next(last), uint64(a));
        _assertBidsSorted();
    }

    /// @notice Hints that are not live bids — an unknown id, an order on the other side, the
    ///         amended order itself — are skipped, and the old neighbours place a nearby requote.
    function test_hint_unusableOnesIgnored_oldNeighboursPlace() public {
        (uint256 a, uint256[] memory ids) = _ladderBelowAlice();
        uint256 ask = _placeLimit(carol, false, SIZE, 60_000 * BAZAAR_SCALE);
        _amendAs(alice, _singleHinted(a, uint64(999_999), uint64(ask), 48_985 * BAZAAR_SCALE, SIZE));
        assertEq(_bids()[1], a, "between the first two rungs");
        _amendAs(alice, _singleHinted(a, uint64(a), uint64(a), 49_000 * BAZAAR_SCALE, SIZE));
        assertEq(_bidHead(), uint64(a), "back at the head");
        assertEq(_bids()[1], ids[0]);
        _assertBidsSorted();
    }

    /// @notice A live hint far from the real slot can only fail the placement: when the old
    ///         neighbours do not bracket the slot either, a wrong anchor exhausts the walk and the
    ///         call reverts, while one within reach walks to the right slot. Nothing is ever
    ///         linked out of order.
    function test_hint_liveButWrong_cannotMisplace() public {
        (uint256 a, uint256[] memory ids) = _ladderBelowAlice();
        // Four rungs down, hinted at the bottom of the ladder: the walk back up is too long.
        _amendExpect(
            alice,
            _singleHinted(a, uint64(ids[39]), 0, 48_955 * BAZAAR_SCALE, SIZE),
            abi.encodeWithSelector(OrderBookLib.OrderBookLib__HintRepairExhausted.selector, a)
        );
        assertEq(_bidHead(), uint64(a), "untouched");
        // Hinted twenty rungs down instead: the walk back up reaches the slot.
        _amendAs(alice, _singleHinted(a, uint64(ids[20]), 0, 48_955 * BAZAAR_SCALE, SIZE));
        assertEq(_bids()[4], a, "behind the four rungs priced above 48,955");
        _assertBidsSorted();
    }

    /// @notice The id word has one encoding: bits above the two hint fields must be zero.
    function test_idWord_nonCanonical_refused() public {
        (uint256 a,) = _twoBids();
        bytes memory err = abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__InvalidAmendBatch.selector);
        Batch memory b = _single(a, 48_500 * BAZAAR_SCALE, SIZE);
        b.words[0] = a | (uint256(1) << 192);
        _amendExpect(alice, b, err);
        b.words[0] = a | (uint256(1) << 255);
        _amendExpect(alice, b, err);
        assertEq(OrderView.order(pair, a).limitPrice, 49_000 * BAZAAR_SCALE, "untouched");
    }

    // ---------------------------- refusals ----------------------------

    /// @notice A price at or through the best resting order on the other side is refused: the
    ///         order would be a taker, and that is a cancel and a new order.
    function test_crossing_refused() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 bid = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);
        _roll(1);
        uint256 ask = _placeLimit(bob, false, SIZE, 51_000 * BAZAAR_SCALE);

        _amendExpect(
            alice,
            _single(bid, 51_000 * BAZAAR_SCALE, SIZE),
            _crossErr(bid, 51_000 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE)
        );
        _amendExpect(
            alice,
            _single(bid, 52_000 * BAZAAR_SCALE, SIZE),
            _crossErr(bid, 52_000 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE)
        );
        _amendExpect(
            bob, _single(ask, 49_000 * BAZAAR_SCALE, SIZE), _crossErr(ask, 49_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE)
        );

        // One tick inside the spread is fine on both sides.
        _amendAs(alice, _single(bid, 50_999 * BAZAAR_SCALE, SIZE));
        _amendAs(bob, _single(ask, 51_000 * BAZAAR_SCALE, SIZE));
        assertEq(_bidHead(), uint64(bid));
        assertEq(_askHead(), uint64(ask));
    }

    /// @notice The order's own opposite-side order counts as the book's best: an amendment onto
    ///         it is a cross, so no self-match can arise.
    function test_crossingOwnOrder_refused() public {
        _deposit(alice, 40_000 * BAZAAR_SCALE);
        uint256 bid = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);
        _roll(1);
        _placeLimit(alice, false, SIZE, 51_000 * BAZAAR_SCALE);
        _amendExpect(
            alice,
            _single(bid, 51_000 * BAZAAR_SCALE, SIZE),
            _crossErr(bid, 51_000 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE)
        );
    }

    /// @notice The placement band holds for an amended price as it does for a new order.
    function test_outsidePlacementBand_refused() public {
        (uint256 a,) = _twoBids();
        uint256 lo = 50_000 * BAZAAR_SCALE * (10_000 - BazaarTypes.MAX_PLACEMENT_DEVIATION_BP) / 10_000;
        uint256 hi = 50_000 * BAZAAR_SCALE * (10_000 + BazaarTypes.MAX_PLACEMENT_DEVIATION_BP) / 10_000;
        _amendExpect(
            alice,
            _single(a, 20_000 * BAZAAR_SCALE, SIZE),
            abi.encodeWithSelector(
                OrderManagementLib.OrderManagementLib__LimitPriceOutsidePlacementBand.selector,
                20_000 * BAZAAR_SCALE,
                lo,
                hi
            )
        );
        _amendExpect(
            alice,
            _single(a, 0, SIZE),
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__ZeroLimitPrice.selector)
        );
    }

    /// @notice The new size must leave something to fill: at or below the filled size the order
    ///         would be complete, which is a cancel.
    function test_sizeNotAboveFilled_refused() public {
        (uint256 a,) = _twoBids();
        _sell(SIZE / 2, 49_000); // half of alice's bid fills
        assertEq(OrderView.order(pair, a).filledSize, SIZE / 2);

        bytes memory err =
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__AmendSizeNotAboveFilled.selector, a);
        _amendExpect(alice, _single(a, 49_000 * BAZAAR_SCALE, SIZE / 2), err);
        _amendExpect(alice, _single(a, 49_000 * BAZAAR_SCALE, 0), err);
        // Shrinking the remainder is fine; the filled size stays.
        _amendAs(alice, _single(a, 49_000 * BAZAAR_SCALE, SIZE / 2 + SIZE / 4));
        assertEq(OrderView.order(pair, a).size, SIZE / 2 + SIZE / 4);
        assertEq(OrderView.order(pair, a).filledSize, SIZE / 2);
    }

    /// @notice The remainder is held to the $5 notional floor like a new order.
    function test_belowMinimumNotional_refused() public {
        (uint256 a,) = _twoBids();
        uint256 dust = BTC / 20_000; // $2.45 at $49k
        _amendExpect(
            alice,
            _single(a, 49_000 * BAZAAR_SCALE, dust),
            abi.encodeWithSelector(
                OrderManagementLib.OrderManagementLib__NotionalBelowMinimum.selector,
                dust * 49_000,
                BazaarTypes.MIN_ORDER_AMOUNT
            )
        );
    }

    /// @notice Only the owner can amend, and only a resting good-till-cancelled limit order.
    function test_ownerAndTypeGates() public {
        (uint256 a,) = _twoBids();
        _amendExpect(
            bob,
            _single(a, 48_500 * BAZAAR_SCALE, SIZE),
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__RequestorIsNotOrderOwner.selector, a, bob)
        );
        _amendExpect(
            alice,
            _single(999, 48_500 * BAZAAR_SCALE, SIZE),
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__OrderNotFound.selector, 999)
        );

        // A stop-limit waits outside the book: not amendable, whatever its state.
        BazaarTypes.OrderSpec memory s = _limitSpec(true, SIZE, 52_500 * BAZAAR_SCALE);
        s.orderType = BazaarTypes.OrderType.StopLimit;
        s.triggerPrice = 52_000 * BAZAAR_SCALE;
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 stop = _lastCreatedOrderId(pair);
        _amendExpect(
            alice,
            _single(stop, 52_500 * BAZAAR_SCALE, SIZE),
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__NotAmendable.selector, stop)
        );
    }

    /// @notice A canceled, filled or expired order cannot be amended.
    function test_terminalOrExpired_refused() public {
        (uint256 a, uint256 b) = _twoBids();

        uint256[] memory ids = new uint256[](1);
        ids[0] = a;
        vm.prank(alice);
        pair.cancelOrders(ids, 0, 0, 0, "", "");
        _amendExpect(
            alice,
            _single(a, 48_500 * BAZAAR_SCALE, SIZE),
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__OrderIsNotActive.selector, a)
        );

        _sell(SIZE, 48_000); // fills bob's bid whole
        assertGt(OrderView.order(pair, b).filledBlock, 0);
        _amendExpect(
            bob,
            _single(b, 47_500 * BAZAAR_SCALE, SIZE),
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__OrderIsNotActive.selector, b)
        );

        // An order past its expiry block is refused rather than relinked.
        BazaarTypes.OrderSpec memory s = _limitSpec(true, SIZE, 47_000 * BAZAAR_SCALE);
        s.expirationBlock = uint64(vm.getBlockNumber()) + BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS;
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 shortLived = _lastCreatedOrderId(pair);
        _roll(BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 1);
        _amendExpect(
            alice,
            _single(shortLived, 46_000 * BAZAAR_SCALE, SIZE),
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__OrderAlreadyExpired.selector, shortLived)
        );
    }

    // ---------------------------- minimum lifetime ----------------------------

    /// @notice A move needs the lifetime a new order is created with. With exactly
    ///         MIN_ORDER_LIFETIME_BLOCKS left a reprice goes through; one block later a reprice or
    ///         a larger size is refused, while a smaller size at the same price, which keeps the
    ///         order where it has stood, and an amendment that changes nothing still go through
    ///         until the order expires. No amendment touches the expiry.
    function test_move_needsTheMinimumLifetimeLeft() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 a = _bidExpiringIn(alice, SIZE, 49_000, BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 10);
        uint64 expiry = OrderView.order(pair, a).expiryBlock;

        vm.roll(expiry - BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS);
        _amendAs(alice, _single(a, 48_900 * BAZAAR_SCALE, SIZE));
        assertEq(OrderView.order(pair, a).limitPrice, 48_900 * BAZAAR_SCALE, "a reprice with the floor left moves");

        _roll(1);
        _amendExpect(alice, _single(a, 48_800 * BAZAAR_SCALE, SIZE), _lifetimeErr(a, expiry));
        _amendExpect(alice, _single(a, 48_900 * BAZAAR_SCALE, 2 * SIZE), _lifetimeErr(a, expiry));
        assertEq(OrderView.order(pair, a).limitPrice, 48_900 * BAZAAR_SCALE, "the refused reprice left the price");
        assertEq(OrderView.order(pair, a).size, SIZE, "and the refused grow the size");

        uint64 seqBefore = _seq(a);
        _amendAs(alice, _single(a, 48_900 * BAZAAR_SCALE, SIZE / 2));
        assertEq(OrderView.order(pair, a).size, SIZE / 2, "a shrink in place goes through");
        assertEq(_seq(a), seqBefore, "and keeps its queue position");
        _amendAs(alice, _single(a, 48_900 * BAZAAR_SCALE, SIZE / 2));

        vm.roll(expiry); // the order's last live block
        _amendAs(alice, _single(a, 48_900 * BAZAAR_SCALE, SIZE / 4));
        assertEq(OrderView.order(pair, a).size, SIZE / 4, "shrinks go through until the order expires");
        assertEq(OrderView.order(pair, a).expiryBlock, expiry, "no amendment moved the expiry");
    }

    /// @notice Orders resting deep in the book cannot move to its front in their last live block,
    ///         where one block later they would be dead nodes at the head that a seller's walk
    ///         spends its whole step budget removing before it reaches a real bid. The batch is
    ///         refused, and the next seller fills the honest bid.
    function test_lastBlockMoveToTheFront_refused_sellerReachesTheRealBid() public {
        (uint256 honest, uint256[] memory ids) =
            _deepWallBehindAnHonestBid(BazaarTypes.MAX_WALK_STEPS, BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS);
        uint64 expiry = OrderView.order(pair, ids[0]).expiryBlock;

        vm.roll(expiry);
        _amendExpect(alice, _wallToTheFront(ids), _lifetimeErr(ids[0], expiry));
        assertEq(_bidHead(), uint64(honest), "the honest bid still leads");

        _roll(1);
        _deposit(carol, 10_000 * BAZAAR_SCALE);
        uint256 sell = _placeMarket(carol, false, SIZE, 100);
        assertEq(_filledSize(sell), SIZE, "the seller fills in full");
        assertEq(_filledSize(honest), SIZE, "against the honest bid");
    }

    /// @notice The same orders can move to the front while they still have the floor left, and
    ///         then they lead as live quotes for at least that long: a seller who reaches them
    ///         fills against them rather than spending steps on dead nodes.
    function test_moveToTheFrontWithTheFloorLeft_leadsAsLiveQuotes() public {
        uint256 n = BazaarTypes.MAX_WALK_STEPS;
        (, uint256[] memory ids) = _deepWallBehindAnHonestBid(n, BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 60);
        uint64 expiry = OrderView.order(pair, ids[0]).expiryBlock;

        vm.roll(expiry - BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS);
        _amendAs(alice, _wallToTheFront(ids));
        assertEq(_bidHead(), uint64(ids[0]), "the moved orders lead");

        vm.roll(expiry); // the last block a seller can reach them in
        _deposit(carol, 10_000 * BAZAAR_SCALE);
        uint256 sell = _placeMarket(carol, false, SIZE, 100);
        assertEq(_filledSize(sell), n * (BTC / 1000), "the seller filled every one of them");
        assertEq(_posSize(alice), n * (BTC / 1000), "and their owner bought it");
    }

    /// @notice The batch is all or nothing: a refused item leaves every earlier one unapplied.
    function test_batch_allOrNothing() public {
        (uint256 a, uint256 b) = _twoBids();
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _roll(1);
        _placeLimit(carol, false, SIZE, 51_000 * BAZAAR_SCALE);

        Batch memory mixed = _batch(2);
        _set(mixed, 0, a, 48_500 * BAZAAR_SCALE, SIZE);
        _set(mixed, 1, b, 51_000 * BAZAAR_SCALE, SIZE); // bob's order
        _amendExpect(
            alice,
            mixed,
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__RequestorIsNotOrderOwner.selector, b, alice)
        );
        Batch memory bobs = _batch(2);
        _set(bobs, 0, b, 47_500 * BAZAAR_SCALE, SIZE);
        _set(bobs, 1, b, 51_000 * BAZAAR_SCALE, SIZE); // crosses
        _amendExpect(bob, bobs, _crossErr(b, 51_000 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE));
        assertEq(OrderView.order(pair, b).limitPrice, 48_000 * BAZAAR_SCALE, "the first item did not land either");
        assertEq(OrderView.order(pair, a).limitPrice, 49_000 * BAZAAR_SCALE);
    }

    /// @notice Batch shape: never empty, whole triples only, never above the per-user order cap.
    function test_batchShape_refused() public {
        (uint256 a,) = _twoBids();
        bytes memory err = abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__InvalidAmendBatch.selector);

        _amendExpect(alice, _batch(0), err);

        Batch memory tooMany = _batch(BazaarTypes.MAX_AMENDS_PER_CALL + 1);
        for (uint256 i; i < tooMany.words.length / 3; ++i) {
            _set(tooMany, i, a, 48_500 * BAZAAR_SCALE, SIZE);
        }
        _amendExpect(alice, tooMany, err);

        Batch memory ragged;
        ragged.words = new uint256[](4); // not whole triples
        _amendExpect(alice, ragged, err);
    }

    // ---------------------------- margin ----------------------------

    /// @notice The set the batch leaves must clear initial margin as a new order would: a size the
    ///         collateral cannot carry is refused, and a size it can is accepted.
    function test_marginGate_onTheSetTheBatchLeaves() public {
        // 20% warmup IMR: 0.1 BTC at $49k needs $1,000 at the $50k mark plus the maker fee. Fund
        // for about twice that, a dollar over so the accepted size clears its fee as well.
        _deposit(alice, 2_001 * BAZAAR_SCALE);
        uint256 a = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);

        _amendExpect(
            alice,
            _single(a, 49_000 * BAZAAR_SCALE, 3 * SIZE),
            abi.encodeWithSelector(
                OrderManagementLib.OrderManagementLib__InsufficientMarginAfterOrder.selector,
                2_001 * BAZAAR_SCALE,
                // IMR on the size at the mark, the larger leg, plus the maker fee on the limit notional
                3 * SIZE * 50_000 * 2_000 / 10_000 + 3 * SIZE * 49_000 * BazaarTypes.MAKER_INSURANCE_FEE_EBP
                    / BazaarTypes.EBP_SCALE
            )
        );
        _amendAs(alice, _single(a, 49_000 * BAZAAR_SCALE, 2 * SIZE));
        assertEq(OrderView.order(pair, a).size, 2 * SIZE);
    }

    /// @notice Shrinking frees the reservation: an account whose resting exposure is at the limit
    ///         can still shrink, which only ever reduces what is reserved.
    function test_shrink_alwaysAffordable() public {
        _deposit(alice, 1_001 * BAZAAR_SCALE); // $1,000 reserved at the mark plus the maker fee, a dollar over
        uint256 a = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);
        _amendAs(alice, _single(a, 49_000 * BAZAAR_SCALE, SIZE / 2));
        assertEq(OrderView.order(pair, a).size, SIZE / 2);
    }

    // ---------------------------- relayed ----------------------------

    /// @dev EIP-712 struct hash of an AmendOrders request, built here independently of the pair.
    function _structHash(Batch memory b, uint256 nonce, uint256 deadline, uint256 fee) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(MetaTxLib.AMEND_ORDERS_TYPEHASH, keccak256(abi.encodePacked(b.words)), nonce, deadline, fee)
        );
    }

    /// @notice A relayer carries the signer's amendments: the orders move for the signer, the fee
    ///         comes from the signer's wallet into the relayer's claimable balance, the nonce is
    ///         consumed, and the signature cannot be replayed.
    function test_relayed_amendsForTheSignerAndPaysTheRelayer() public {
        (address signer, uint256 pk) = makeAddrAndKey("maker");
        usdc.mint(signer, 100_000 * USDC_SCALE);
        _deposit(signer, 20_000 * BAZAAR_SCALE);
        uint256 a = _placeLimit(signer, true, SIZE, 49_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _roll(1);
        uint256 b = _placeLimit(bob, true, SIZE, 48_000 * BAZAAR_SCALE);

        Batch memory batch = _single(a, 48_000 * BAZAAR_SCALE, SIZE);
        uint256 nonce = pair.metaTxNonces(signer);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        uint256 fee = BAZAAR_SCALE / 2;
        bytes32 digest =
            MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), _structHash(batch, nonce, deadline, fee));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(signer);
        usdc.approve(address(pair), fee * USDC_SCALE / BAZAAR_SCALE);
        uint256 walletBefore = usdc.balanceOf(signer);

        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        pair.amendOrders(batch.words, pu, nonce, deadline, fee, sig, "");

        assertEq(_next(b), uint64(a), "the signer's order moved");
        assertEq(OrderView.order(pair, a).creator, signer, "and is still theirs");
        assertEq(walletBefore - usdc.balanceOf(signer), fee * USDC_SCALE / BAZAAR_SCALE, "fee pulled from the wallet");
        assertEq(_escrowOwed(seq), fee, "and owed to the relayer");
        assertEq(pair.metaTxNonces(signer), nonce + 1, "nonce consumed");

        pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert(abi.encodeWithSelector(MetaTxLib.MetaTx__InvalidNonce.selector, nonce + 1, nonce));
        pair.amendOrders(batch.words, pu, nonce, deadline, fee, sig, "");
    }

    /// @notice A relayer cannot change what was signed: altered amendments recover a different
    ///         signer, who owns none of the orders.
    function test_relayed_tamperedBatchIsRefused() public {
        (address signer, uint256 pk) = makeAddrAndKey("maker");
        usdc.mint(signer, 100_000 * USDC_SCALE);
        _deposit(signer, 20_000 * BAZAAR_SCALE);
        uint256 a = _placeLimit(signer, true, SIZE, 49_000 * BAZAAR_SCALE);

        Batch memory batch = _single(a, 48_000 * BAZAAR_SCALE, SIZE);
        uint256 nonce = pair.metaTxNonces(signer);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        bytes32 digest =
            MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), _structHash(batch, nonce, deadline, 0));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        batch.words[2] = 2 * SIZE; // the relayer edits the batch after signing
        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert();
        pair.amendOrders(batch.words, pu, nonce, deadline, 0, sig, "");
        assertEq(OrderView.order(pair, a).size, SIZE, "nothing moved");
    }

    /// @notice The hints are part of the signed words: a relayer that drops or swaps them recovers
    ///         a different signer, who owns none of the orders; the words as signed go through.
    function test_relayed_hintsAreSigned() public {
        (address signer, uint256 pk) = makeAddrAndKey("maker");
        usdc.mint(signer, 100_000 * USDC_SCALE);
        _deposit(signer, 20_000 * BAZAAR_SCALE);
        uint256 a = _placeLimit(signer, true, SIZE, 49_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 b = _placeLimit(bob, true, SIZE, 48_000 * BAZAAR_SCALE);

        Batch memory batch = _singleHinted(a, uint64(b), 0, 47_500 * BAZAAR_SCALE, SIZE);
        uint256 nonce = pair.metaTxNonces(signer);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        bytes32 digest =
            MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), _structHash(batch, nonce, deadline, 0));
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s_, v);

        batch.words[0] = _word(a, 0, 0); // the relayer drops the hint after signing
        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert();
        pair.amendOrders(batch.words, pu, nonce, deadline, 0, sig, "");
        assertEq(OrderView.order(pair, a).limitPrice, 49_000 * BAZAAR_SCALE, "nothing moved");

        batch.words[0] = _word(a, uint64(b), 0); // as signed
        pu = _freshPrice();
        vm.prank(seq);
        pair.amendOrders(batch.words, pu, nonce, deadline, 0, sig, "");
        assertEq(_next(b), uint64(a), "placed behind the hinted order");
    }

    // ---------------------------- lifecycle gates ----------------------------

    /// @notice Amendments are matching activity: refused while trading is halted by a pending ADL
    ///         window, like a new order.
    function test_haltedWhileAdlPending() public {
        (uint256 a,) = _twoBids();
        _stageHeldInventory(60_000 * BAZAAR_SCALE, _insuranceBal() / 2);
        vm.warp(vm.getBlockTimestamp() + 30);
        bytes[] memory pu = _priceAt(30_000);
        vm.prank(seq);
        pair.refreshPrice(pu);
        assertTrue(pair.isAdlPending(), "fixture: a window is open");

        Batch memory b = _single(a, 29_000 * BAZAAR_SCALE, SIZE);
        pu = _priceAt(30_000);
        vm.prank(alice);
        vm.expectRevert();
        pair.amendOrders(b.words, pu, 0, 0, 0, "", "");
    }

    // ---------------------------- book shape under random amendments ----------------------------

    /// @notice Whatever sequence of in-band, non-crossing amendments is applied, the bid list stays
    ///         sorted by price then queue position, its links stay reciprocal, and its count stays
    ///         true.
    function testFuzz_randomAmendments_keepTheBookWellFormed(uint256 seed) public {
        _deposit(alice, 200_000 * BAZAAR_SCALE);
        uint256[6] memory ids;
        for (uint256 i; i < 6; ++i) {
            ids[i] = _placeLimit(alice, true, SIZE, (45_000 + 500 * i) * BAZAAR_SCALE);
            _roll(1);
        }
        for (uint256 step; step < 10; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 orderId = ids[seed % 6];
            uint256 price = (40_000 + 500 * ((seed >> 8) % 20)) * BAZAAR_SCALE; // 40k..49.5k, no asks to cross
            uint256 size = SIZE / 4 + (SIZE / 4) * ((seed >> 16) % 8); // 0.025..0.2 BTC
            _amendAs(alice, _single(orderId, price, size));
            _assertBidsWellFormed();
        }
    }

    function _assertBidsWellFormed() internal view {
        uint256[] memory bids = _bids();
        assertEq(bids.length, 6, "every order still rests");
        uint64 prev;
        for (uint256 i; i < bids.length; ++i) {
            BazaarTypes.Order memory o = OrderView.order(pair, bids[i]);
            assertEq(o.prevInBook, prev, "links are reciprocal");
            assertTrue(o.inBook);
            if (i > 0) {
                BazaarTypes.Order memory before = OrderView.order(pair, bids[i - 1]);
                bool ordered = before.limitPrice > o.limitPrice
                    || (before.limitPrice == o.limitPrice && before.prioritySeq < o.prioritySeq);
                assertTrue(ordered, "sorted by price, then by queue position");
            }
            prev = uint64(bids[i]);
        }
    }
}
