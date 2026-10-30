// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {OrderView} from "../OrderView.sol";

/// @title ArmedStopLimitPriorityTest
/// @notice A StopLimit joins the book only when it arms, so it queues by when it rested rather
///         than when it was created: a keeper arming it takes a fresh queue position from the id
///         counter and rests behind every order already at its limit price. A skip leaves the
///         order and the counter as they were, and the counter the pair stores back keeps every
///         later id and queue position unique.
contract ArmedStopLimitPriorityTest is IntegrationBase {
    uint256 constant BTC = 1e18;
    uint256 constant SIZE = BTC / 10;
    // A buy stop that fires at or above 51_500 and rests at 52_000; the market starts at 50_000.
    uint256 constant TRIGGER = 51_500 * BAZAAR_SCALE;
    uint256 constant LIMIT = 52_000 * BAZAAR_SCALE;
    uint256 constant ABOVE_TRIGGER_USD = 52_500;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
    }

    // ---------------------------- helpers ----------------------------

    function _seq(uint256 orderId) internal view returns (uint64) {
        return OrderView.order(pair, orderId).prioritySeq;
    }

    function _counter() internal view returns (uint256) {
        return lens.nextOrderId(address(pair));
    }

    /// @dev Bids from the head down, as the book links them.
    function _bids() internal view returns (uint256[] memory ids) {
        (uint64 cur,, uint64 count,) = pair.book();
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = cur;
            cur = OrderView.order(pair, cur).nextInBook;
        }
        assertEq(cur, 0, "bid list longer than its count");
    }

    function _exec(uint256 orderId, uint64 pred) internal pure returns (BazaarTypes.TriggerExec memory e) {
        e.orderId = uint64(orderId);
        e.hints.pred = pred;
    }

    /// @dev Fire a keeper batch at a custom oracle price (warps +3s so the update is strictly newer).
    function _executeBatchAt(BazaarTypes.TriggerExec[] memory execs, uint256 priceUsd)
        internal
        returns (uint256 executedCount)
    {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(priceUsd, uint64(vm.getBlockTimestamp()));
        vm.prank(seq);
        executedCount = pair.executeTriggeredOrders(execs, pu);
    }

    /// @dev Rest `count` bids at consecutive whole-dollar prices just above `floorUsd`, placed in
    ///      ascending price order so each becomes the new bid head and needs no hint. Split across
    ///      two fresh padders to stay under MAX_ACTIVE_LIMIT_ORDERS_PER_USER. Returns the ids in
    ///      placement order, so ids[0] is the lowest-priced bid — the side's tail, and the
    ///      predecessor of any bid at `floorUsd`.
    function _padBidsAbove(uint256 floorUsd, uint256 count) internal returns (uint256[] memory ids) {
        address padA = makeAddr("padA");
        address padB = makeAddr("padB");
        usdc.mint(padA, INITIAL_USER_BALANCE);
        usdc.mint(padB, INITIAL_USER_BALANCE);
        _deposit(padA, 20_000 * BAZAAR_SCALE);
        _deposit(padB, 20_000 * BAZAAR_SCALE);
        ids = new uint256[](count);
        for (uint256 k = 1; k <= count; ++k) {
            address who = k <= count / 2 ? padA : padB;
            ids[k - 1] = _placeLimit(who, true, BTC / 1000, (floorUsd + k) * BAZAAR_SCALE);
        }
    }

    // ---------------------------- queue position ----------------------------

    /// @notice The audit scenario. An older StopLimit that arms after another order is already
    ///         resting at its limit price queues behind that order, so the next seller at that
    ///         price fills the order that was there first.
    function test_armedStopLimit_queuesBehindOrdersAlreadyRestingAtItsPrice() public {
        uint256 stop = _placeStopLimit(alice, true, SIZE, TRIGGER, LIMIT);
        // The market passes the trigger and bob bids at the stop's limit before any keeper fires it.
        uint256 bid = _placeLimitAt(bob, true, SIZE, LIMIT, ABOVE_TRIGGER_USD);
        assertLt(stop, bid, "the stop is the older order");

        assertEq(_executeTriggerAt(stop, ABOVE_TRIGGER_USD), 1, "fired");
        assertTrue(_inBook(stop), "armed into the book");
        uint256[] memory bids = _bids();
        assertEq(bids.length, 2);
        assertEq(bids[0], bid, "bob's bid was resting first and keeps the front of the level");
        assertEq(bids[1], stop, "the stop queues behind it");

        _placeLimitAt(carol, false, SIZE, LIMIT, ABOVE_TRIGGER_USD);
        assertEq(_filledSize(bid), SIZE, "the next seller at that price fills bob");
        assertEq(_filledSize(stop), 0, "the stop waits its turn");
        assertTrue(_inBook(stop), "and still rests");
        _assertBooks("after the level traded");
    }

    /// @notice Arming draws the counter's next value as the stop's queue position and the pair
    ///         stores the counter past it, so the next order's id and queue position are the
    ///         value after it and no two resting orders can tie.
    function test_arming_drawsTheNextCounterValue_laterOrdersStayUnique() public {
        uint256 stop = _placeStopLimit(alice, true, SIZE, TRIGGER, LIMIT);
        uint256 bid = _placeLimitAt(bob, true, SIZE, LIMIT, ABOVE_TRIGGER_USD);
        assertEq(_seq(stop), uint64(stop), "dormant, the stop carries its creation id");
        uint256 counter = _counter();

        _executeTriggerAt(stop, ABOVE_TRIGGER_USD);
        assertEq(_seq(stop), uint64(counter), "arming drew the counter's next value");
        assertEq(_counter(), counter + 1, "the pair stored the counter past it");

        uint256 later = _placeLimitAt(carol, true, SIZE, LIMIT, ABOVE_TRIGGER_USD);
        assertEq(later, counter + 1, "the next id skips the value the stop drew");
        assertEq(_seq(later), uint64(later), "and queues under its own id");
        uint256[] memory bids = _bids();
        assertEq(bids.length, 3);
        assertEq(bids[0], bid);
        assertEq(bids[1], stop);
        assertEq(bids[2], later, "a later order queues behind the armed stop");
    }

    /// @notice A stop whose trigger is not met is skipped with its queue position and the counter
    ///         untouched; it draws one when it does arm.
    function test_unmetTrigger_skip_drawsNothing() public {
        uint256 stop = _placeStopLimit(alice, true, SIZE, TRIGGER, LIMIT);
        uint256 counter = _counter();

        assertEq(_executeTriggerAt(stop, 51_000), 0, "unmet trigger is skipped");
        assertEq(_seq(stop), uint64(stop), "queue position untouched");
        assertEq(_counter(), counter, "no counter value drawn");

        assertEq(_executeTriggerAt(stop, ABOVE_TRIGGER_USD), 1, "fired once the trigger is met");
        assertEq(_seq(stop), uint64(counter));
        assertEq(_counter(), counter + 1);
    }

    /// @notice A stop whose resting slot the keeper's hints cannot reach is skipped before
    ///         anything is written: its queue position and the counter are unchanged, and a
    ///         keeper with a reaching hint arms it under the next counter value. The tail hint a
    ///         keeper computes for an entrant (the lens's findPredecessor rule) is exact for it.
    function test_unreachableSlot_skip_drawsNothing_reachingHintArms() public {
        uint256 stop = _placeStopLimit(alice, true, SIZE, TRIGGER, LIMIT);
        // MAX_WALK_STEPS + 2 bids between the head and the stop's slot: from the head anchor the
        // slot is one advance past the cap.
        uint256[] memory pad = _padBidsAbove(52_000, BazaarTypes.MAX_WALK_STEPS + 2);
        uint256 counter = _counter();

        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](1);
        execs[0] = _exec(stop, 0);
        assertEq(_executeBatchAt(execs, ABOVE_TRIGGER_USD), 0, "skipped: the slot is out of reach");
        assertFalse(_inBook(stop), "not armed");
        assertEq(_seq(stop), uint64(stop), "queue position untouched by the skip");
        assertEq(_counter(), counter, "no counter value drawn by the skip");

        execs[0] = _exec(stop, uint64(pad[0]));
        assertEq(_executeBatchAt(execs, ABOVE_TRIGGER_USD), 1, "armed with a reaching hint");
        assertTrue(_inBook(stop));
        assertEq(uint256(OrderView.order(pair, stop).prevInBook), pad[0], "behind the lowest padding bid");
        assertEq(uint256(OrderView.order(pair, stop).nextInBook), 0, "at the tail");
        assertEq(_seq(stop), uint64(counter));
        assertEq(_counter(), counter + 1);
    }

    /// @notice A stop the walk fills completely never rests; the counter value it drew is simply
    ///         unused, and the book and ledger are intact.
    function test_stopFilledOnArming_leavesAnUnusedCounterValue() public {
        uint256 stop = _placeStopLimit(alice, true, SIZE, TRIGGER, LIMIT);
        uint256 ask = _placeLimitAt(carol, false, SIZE, 51_900 * BAZAAR_SCALE, ABOVE_TRIGGER_USD);
        uint256 counter = _counter();

        assertEq(_executeTriggerAt(stop, ABOVE_TRIGGER_USD), 1, "fired");
        assertEq(_filledSize(stop), SIZE, "filled against carol's ask");
        assertEq(_filledSize(ask), SIZE);
        assertFalse(_inBook(stop), "never rested");
        assertEq(_counter(), counter + 1, "the drawn value stays drawn");

        uint256 later = _placeLimitAt(bob, true, SIZE, LIMIT, ABOVE_TRIGGER_USD);
        assertEq(later, counter + 1, "the next id is past the unused value");
        assertEq(_lastCreatedOrderId(pair), later, "the newest order is found across the gap");
        _assertBooks("after a stop filled on arming");
    }

    /// @notice Stops armed in one batch take queue positions in the order the batch arms them,
    ///         each behind every order that was resting before the call.
    function test_stopsArmedInOneBatch_queueInTheOrderTheyArm() public {
        uint256 s1 = _placeStopLimit(alice, true, SIZE, TRIGGER, LIMIT);
        uint256 s2 = _placeStopLimit(dave, true, SIZE, TRIGGER, LIMIT);
        uint256 bid = _placeLimitAt(bob, true, SIZE, LIMIT, ABOVE_TRIGGER_USD);
        uint256 counter = _counter();

        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](2);
        execs[0] = _exec(s2, 0);
        execs[1] = _exec(s1, 0);
        assertEq(_executeBatchAt(execs, ABOVE_TRIGGER_USD), 2, "both fired");

        assertEq(_seq(s2), uint64(counter), "first armed, first value");
        assertEq(_seq(s1), uint64(counter + 1));
        assertEq(_counter(), counter + 2);
        uint256[] memory bids = _bids();
        assertEq(bids.length, 3);
        assertEq(bids[0], bid, "the order resting before the call keeps the front");
        assertEq(bids[1], s2);
        assertEq(bids[2], s1, "the older stop armed second queues last");
    }

    /// @notice A stop whose trigger a fresh price already meets at creation arms in its own
    ///         transaction and rests under its creation id, which is already the newest queue
    ///         position: nothing is drawn beyond the id itself.
    function test_stopArmedOnArrival_restsUnderItsCreationId() public {
        uint256 bid = _placeLimitAt(bob, true, SIZE, LIMIT, ABOVE_TRIGGER_USD);
        uint256 counter = _counter();

        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.StopLimit;
        s.isLong = true;
        s.size = SIZE;
        s.triggerPrice = TRIGGER;
        s.limitPrice = LIMIT;
        s.expirationBlock = uint64(block.number + 500_000);
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(ABOVE_TRIGGER_USD, uint64(vm.getBlockTimestamp()));
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 stop = _lastCreatedOrderId(pair);

        assertEq(stop, counter, "the stop took the counter's next value as its id");
        assertTrue(_inBook(stop), "armed on arrival");
        assertEq(_seq(stop), uint64(stop), "and rests under that id");
        assertEq(_counter(), counter + 1, "nothing drawn beyond the id");
        uint256[] memory bids = _bids();
        assertEq(bids[0], bid);
        assertEq(bids[1], stop);
    }

    /// @notice The Triggered event of a keeper-armed StopLimit reports the queue position it drew,
    ///         which is the one it rests under when its remainder rests.
    function test_triggeredEvent_reportsTheNewQueuePosition() public {
        uint256 stop = _placeStopLimit(alice, true, SIZE, TRIGGER, LIMIT);
        uint256 counter = _counter();

        vm.recordLogs();
        _executeTriggerAt(stop, ABOVE_TRIGGER_USD);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != BazaarTypes.OrderUpdated.selector || uint256(logs[i].topics[2]) != stop) {
                continue;
            }
            BazaarTypes.OrderUpdatePayload memory p = abi.decode(logs[i].data, (BazaarTypes.OrderUpdatePayload));
            if (p.action != BazaarTypes.OrderAction.Triggered) continue;
            assertEq(p.prioritySeq, uint64(counter), "the payload carries the drawn queue position");
            seen = true;
        }
        assertTrue(seen, "Triggered was emitted for the stop");
    }
}
