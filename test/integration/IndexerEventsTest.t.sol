// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {PythSeed} from "../PythSeed.sol";

/// @title IndexerEventsTest
/// @notice The events an indexer rebuilds a pair from: one Trade per fill carrying both sides, an
///         OrderUpdated at every order lifecycle step with the reason for each cancellation (an
///         amendment is the one step reported by its own event, OrderAmended), the
///         stored oracle prices with the funding index they advanced, the pair fixing its own
///         settlement price on insolvency, and the listing metadata at deployment.
contract IndexerEventsTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BTC = 1e18;
    bytes32 constant ETH_USD_FEED_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    /// @dev Trade's non-indexed fields in order. A struct of static members decodes exactly like
    ///      the flat list and keeps the decode off the stack.
    struct TradeData {
        uint256 makerOrderId;
        uint256 takerOrderId;
        bool takerIsLong;
        uint256 fillSize;
        uint256 price;
        uint256 makerFee;
        uint256 takerFee;
        uint256 makerRemaining;
        uint256 takerRemaining;
    }

    /// @dev PositionModified's non-indexed fields in order.
    struct PositionModifiedData {
        bool isLong;
        int256 sizeDelta;
        uint256 newSize;
        uint256 newEntryValue;
        uint256 newCollateral;
        uint256 executionPrice;
        uint256 fee;
        int256 realizedPnl;
    }

    // ---------------------------- log readers ----------------------------

    /// @dev The pair's logs with topic0 `sig`, in emission order.
    function _logs(Vm.Log[] memory all, bytes32 sig) internal view returns (Vm.Log[] memory out) {
        uint256 n;
        for (uint256 i; i < all.length; ++i) {
            if (all[i].emitter == address(pair) && all[i].topics[0] == sig) ++n;
        }
        out = new Vm.Log[](n);
        n = 0;
        for (uint256 i; i < all.length; ++i) {
            if (all[i].emitter == address(pair) && all[i].topics[0] == sig) out[n++] = all[i];
        }
    }

    /// @dev The OrderUpdated payloads reported for `orderId`, in emission order.
    function _orderUpdates(Vm.Log[] memory all, uint256 orderId)
        internal
        view
        returns (BazaarTypes.OrderUpdatePayload[] memory out)
    {
        Vm.Log[] memory ups = _logs(all, BazaarTypes.OrderUpdated.selector);
        uint256 n;
        for (uint256 i; i < ups.length; ++i) {
            if (uint256(ups[i].topics[2]) == orderId) ++n;
        }
        out = new BazaarTypes.OrderUpdatePayload[](n);
        n = 0;
        for (uint256 i; i < ups.length; ++i) {
            if (uint256(ups[i].topics[2]) == orderId) {
                out[n++] = abi.decode(ups[i].data, (BazaarTypes.OrderUpdatePayload));
            }
        }
    }

    /// @dev The reason on the one cancellation reported for `orderId`.
    function _cancelReason(Vm.Log[] memory all, uint256 orderId) internal view returns (BazaarTypes.CancelReason) {
        BazaarTypes.OrderUpdatePayload[] memory ups = _orderUpdates(all, orderId);
        uint256 n;
        BazaarTypes.CancelReason reason;
        for (uint256 i; i < ups.length; ++i) {
            if (ups[i].action == BazaarTypes.OrderAction.Canceled) {
                ++n;
                reason = ups[i].cancelReason;
            }
        }
        assertEq(n, 1, "exactly one cancellation reported");
        return reason;
    }

    function _topicAddress(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }

    // ---------------------------- Trade ----------------------------

    /// @notice A book fill is one event naming both sides, and each side's fee matches the one
    ///         its position event charged.
    function test_trade_bookFill_oneEventCarriesBothSides() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 ask = _placeLimit(alice, false, BTC / 10, 50_000 * BAZAAR_SCALE);
        _roll(2);

        // bob bids for more than rests: the fill takes all of alice's ask and his remainder rests.
        bytes[] memory pu = _freshPrice();
        vm.recordLogs();
        vm.prank(bob);
        pair.createOrder(_limitSpec(true, BTC / 4, 50_000 * BAZAAR_SCALE), _hintsNone(), pu, 0, 0, 0, "", "");
        Vm.Log[] memory all = vm.getRecordedLogs();
        uint256 bid = _lastCreatedOrderId(pair);

        Vm.Log[] memory trades = _logs(all, BazaarTypes.Trade.selector);
        assertEq(trades.length, 1, "one event for the one fill");
        assertEq(trades[0].topics[1], pair.pairId(), "pairId");
        assertEq(_topicAddress(trades[0].topics[2]), alice, "maker: the resting ask");
        assertEq(_topicAddress(trades[0].topics[3]), bob, "taker: the arriving bid");
        TradeData memory t = abi.decode(trades[0].data, (TradeData));
        assertEq(t.makerOrderId, ask, "maker order");
        assertEq(t.takerOrderId, bid, "taker order");
        assertTrue(t.takerIsLong, "the taker bought");
        assertEq(t.fillSize, BTC / 10, "fill size");
        assertEq(t.price, 50_000 * BAZAAR_SCALE, "priced at the maker's limit");
        assertEq(t.makerRemaining, 0, "ask filled in full");
        assertEq(t.takerRemaining, BTC / 4 - BTC / 10, "bid's remainder");
        assertTrue(_inBook(bid), "the remainder rests");

        // The maker's position event is per fill, the taker's per walk: with one fill, each
        // side's fee on it is exactly the fee the Trade reports for that side.
        Vm.Log[] memory mods = _logs(all, BazaarTypes.PositionModified.selector);
        assertEq(mods.length, 2, "one position event per side");
        assertEq(_topicAddress(mods[0].topics[2]), alice, "maker settles first");
        assertEq(_topicAddress(mods[1].topics[2]), bob, "taker settles at walk end");
        assertEq(abi.decode(mods[0].data, (PositionModifiedData)).fee, t.makerFee, "maker fee");
        assertEq(abi.decode(mods[1].data, (PositionModifiedData)).fee, t.takerFee, "taker fee");
    }

    /// @notice A vault unload fill has no taker order: the pair itself is the taker and pays no
    ///         fee, so the tape and candles need no second event to see it.
    function test_trade_vaultFill_reportsThePairAsTaker() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 bid = _placeLimit(carol, true, BTC / 10, 49_900 * BAZAAR_SCALE);

        // The vault holds a 0.1 BTC long at a $50k basis, $200 of it seized collateral.
        _stdstore.target(address(pair)).sig("pairVault()").depth(6).checked_write(BTC / 10);
        _stdstore.target(address(pair)).sig("pairVault()").depth(7).checked_write(5_000 * BAZAAR_SCALE);
        _stdstore.target(address(pair)).sig("pairVault()").depth(8).checked_write(4_800 * BAZAAR_SCALE);
        _stdstore.target(address(pair)).sig("pairVault()").depth(10).checked_write(true);
        _stdstore.target(address(pair)).sig("pairVault()").depth(13).checked_write(200 * BAZAAR_SCALE);

        bytes[] memory pu = _freshPrice();
        vm.recordLogs();
        vm.prank(seq);
        assertEq(pair.unloadVault(0, pu), BTC / 10, "inventory unloaded");

        Vm.Log[] memory trades = _logs(vm.getRecordedLogs(), BazaarTypes.Trade.selector);
        assertEq(trades.length, 1, "one event for the one fill");
        assertEq(_topicAddress(trades[0].topics[2]), carol, "maker: the resting bid");
        assertEq(_topicAddress(trades[0].topics[3]), address(pair), "taker: the pair's vault");
        TradeData memory t = abi.decode(trades[0].data, (TradeData));
        assertEq(t.makerOrderId, bid, "maker order");
        assertEq(t.takerOrderId, 0, "the vault has no order");
        assertFalse(t.takerIsLong, "the vault sold its inherited long");
        assertEq(t.fillSize, BTC / 10, "fill size");
        assertEq(t.price, 49_900 * BAZAAR_SCALE, "priced at the maker's limit");
        assertEq(t.takerFee, 0, "the vault pays no fee");
        assertEq(t.makerRemaining, 0, "bid filled in full");
        assertEq(t.takerRemaining, 0, "no taker order to report");
    }

    // ---------------------------- OrderUpdated: Created / Triggered ----------------------------

    /// @notice The payload carries the time-in-force and integrator the order was created with,
    ///         and an IOC remainder the book could not fill cancels as Unfilled.
    function test_orderUpdated_iocWithIntegrator_createdThenUnfilled() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        BazaarTypes.OrderSpec memory s = _limitSpec(true, BTC / 10, 50_000 * BAZAAR_SCALE);
        s.tif = BazaarTypes.TimeInForce.IOC;
        s.integrator = dave;

        bytes[] memory pu = _freshPrice();
        vm.recordLogs();
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        Vm.Log[] memory all = vm.getRecordedLogs();
        uint256 id = _lastCreatedOrderId(pair);

        BazaarTypes.OrderUpdatePayload[] memory ups = _orderUpdates(all, id);
        assertEq(ups.length, 2, "created, then canceled on an empty book");
        assertEq(uint8(ups[0].action), uint8(BazaarTypes.OrderAction.Created), "created");
        assertEq(uint8(ups[0].tif), uint8(BazaarTypes.TimeInForce.IOC), "time-in-force");
        assertEq(ups[0].integrator, dave, "integrator");
        assertEq(uint8(ups[0].cancelReason), uint8(BazaarTypes.CancelReason.None), "no reason on a create");
        assertEq(uint8(ups[1].action), uint8(BazaarTypes.OrderAction.Canceled), "canceled");
        assertEq(uint8(ups[1].cancelReason), uint8(BazaarTypes.CancelReason.Unfilled), "unfilled remainder");
        assertEq(ups[1].integrator, dave, "integrator on every update");
    }

    /// @notice A keeper firing a StopLimit reports the fire itself, which is the only event when
    ///         the book has nothing to fill it against and it goes to rest.
    function test_orderUpdated_keeperFiredStopLimit_reportsTriggered() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 id = _placeStopLimit(alice, true, BTC / 10, 51_500 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);

        vm.recordLogs();
        assertEq(_executeTriggerAt(id, 51_600), 1, "stop fired");
        BazaarTypes.OrderUpdatePayload[] memory ups = _orderUpdates(vm.getRecordedLogs(), id);

        assertEq(ups.length, 1, "the fire is the only update: nothing filled or canceled");
        assertEq(uint8(ups[0].action), uint8(BazaarTypes.OrderAction.Triggered), "triggered");
        assertEq(uint8(ups[0].cancelReason), uint8(BazaarTypes.CancelReason.None), "no reason");
        assertEq(ups[0].size, BTC / 10, "size");
        assertEq(ups[0].limitPrice, 52_000 * BAZAAR_SCALE, "limit it rests at");
        assertTrue(_inBook(id), "the armed stop rests");
    }

    /// @notice A stop whose trigger the creation price already meets fires in the creation
    ///         transaction, so its Created is followed by a Triggered with no keeper involved.
    function test_orderUpdated_stopArmedAtCreation_reportsCreatedThenTriggered() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        vm.recordLogs();
        uint256 id = _placeStopLimit(alice, true, BTC / 10, 49_000 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);
        BazaarTypes.OrderUpdatePayload[] memory ups = _orderUpdates(vm.getRecordedLogs(), id);

        assertEq(ups.length, 2, "created and triggered");
        assertEq(uint8(ups[0].action), uint8(BazaarTypes.OrderAction.Created), "created first");
        assertEq(uint8(ups[1].action), uint8(BazaarTypes.OrderAction.Triggered), "then triggered");
        assertTrue(_inBook(id), "armed at creation");
    }

    // ---------------------------- OrderAmended ----------------------------

    /// @notice An amendment is the one lifecycle step OrderUpdated does not report: it emits exactly
    ///         one OrderAmended, naming the owner and carrying the new price, the new total size and
    ///         the queue position the order now holds.
    function test_orderAmended_reportsTheMoveAndNothingElse() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 id = _placeLimit(alice, true, BTC / 10, 49_000 * BAZAAR_SCALE);
        uint256 seq = lens.nextOrderId(address(pair));

        uint256[] memory words = new uint256[](3);
        (words[0], words[1], words[2]) = (id, 48_500 * BAZAAR_SCALE, BTC / 5);
        bytes[] memory pu = _freshPrice();
        vm.recordLogs();
        vm.prank(alice);
        pair.amendOrders(words, pu, 0, 0, 0, "", "");
        Vm.Log[] memory all = vm.getRecordedLogs();

        assertEq(_orderUpdates(all, id).length, 0, "no OrderUpdated for an amendment");
        Vm.Log[] memory am = _logs(all, BazaarTypes.OrderAmended.selector);
        assertEq(am.length, 1, "one OrderAmended");
        assertEq(am[0].topics[1], pair.pairId(), "pair");
        assertEq(uint256(am[0].topics[2]), id, "order");
        assertEq(_topicAddress(am[0].topics[3]), alice, "owner");
        (uint256 price, uint256 size, uint256 prioritySeq) = abi.decode(am[0].data, (uint256, uint256, uint256));
        assertEq(price, 48_500 * BAZAAR_SCALE, "new price");
        assertEq(size, BTC / 5, "new total size");
        assertEq(prioritySeq, seq, "the queue position the move drew");
    }

    // ---------------------------- OrderUpdated: cancel reasons ----------------------------

    function test_cancelReason_postOnlyWouldTake() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, false, BTC / 10, 50_000 * BAZAAR_SCALE);
        _roll(2);

        BazaarTypes.OrderSpec memory s = _limitSpec(true, BTC / 10, 50_000 * BAZAAR_SCALE);
        s.isPostOnly = true;
        bytes[] memory pu = _freshPrice();
        vm.recordLogs();
        vm.prank(bob);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        Vm.Log[] memory all = vm.getRecordedLogs();

        assertEq(
            uint8(_cancelReason(all, _lastCreatedOrderId(pair))),
            uint8(BazaarTypes.CancelReason.PostOnly),
            "post-only order that would take"
        );
    }

    function test_cancelReason_selfMatch() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, false, BTC / 10, 50_000 * BAZAAR_SCALE);
        _roll(2);

        bytes[] memory pu = _freshPrice();
        vm.recordLogs();
        vm.prank(alice);
        pair.createOrder(_limitSpec(true, BTC / 10, 50_000 * BAZAAR_SCALE), _hintsNone(), pu, 0, 0, 0, "", "");
        Vm.Log[] memory all = vm.getRecordedLogs();

        assertEq(
            uint8(_cancelReason(all, _lastCreatedOrderId(pair))),
            uint8(BazaarTypes.CancelReason.SelfMatch),
            "arrival against the owner's own ask"
        );
    }

    function test_cancelReason_expiredOrderSwept() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        BazaarTypes.OrderSpec memory s = _limitSpec(true, BTC / 10, 49_000 * BAZAAR_SCALE);
        s.expirationBlock = uint64(vm.getBlockNumber()) + BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS;
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 id = _lastCreatedOrderId(pair);

        _roll(BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 1);
        vm.recordLogs();
        pair.sweepExpired(_one(id));

        assertEq(
            uint8(_cancelReason(vm.getRecordedLogs(), id)), uint8(BazaarTypes.CancelReason.Expired), "swept at expiry"
        );
    }

    /// @notice A fired stop with nothing to fill against reports only the fire: it is not
    ///         canceled, so an indexer keeps showing it live and armed.
    function test_orderUpdated_firedStopLossWithNoLiquidity_staysLive() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 sl = _placeStopLoss(bob, false, BTC / 10, 48_000 * BAZAAR_SCALE, 100);

        vm.recordLogs();
        assertEq(_executeTriggerAt(sl, 47_500), 1, "stop fired");
        BazaarTypes.OrderUpdatePayload[] memory ups = _orderUpdates(vm.getRecordedLogs(), sl);

        assertEq(ups.length, 1, "fired, nothing else");
        assertEq(uint8(ups[0].action), uint8(BazaarTypes.OrderAction.Triggered), "triggered");
        assertEq(uint8(ups[0].cancelReason), uint8(BazaarTypes.CancelReason.None), "not a cancel");
        assertEq(ups[0].canceledBlock, 0, "still live");
    }

    function test_cancelReason_stopStrandedWhenPositionCloses() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 sl = _placeStopLoss(bob, false, BTC / 10, 49_000 * BAZAAR_SCALE, 500);
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        _placeLimit(bob, false, BTC / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);

        // dave's bid takes bob's resting ask and closes bob's position.
        vm.recordLogs();
        _placeLimit(dave, true, BTC / 10, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(bob), 0, "flat");

        assertEq(
            uint8(_cancelReason(vm.getRecordedLogs(), sl)),
            uint8(BazaarTypes.CancelReason.PositionClosed),
            "stop stranded by the close"
        );
    }

    function test_cancelReason_liquidationCancelsTakeProfit() public {
        _setupInsolventAlice();
        uint256 tp = _placeTakeProfit(alice, false, BTC / 10, 55_000 * BAZAAR_SCALE, 500);

        bytes[] memory pu = _freshPrice();
        vm.recordLogs();
        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "alice liquidated");

        assertEq(
            uint8(_cancelReason(vm.getRecordedLogs(), tp)),
            uint8(BazaarTypes.CancelReason.Liquidated),
            "take-profit of a liquidated position"
        );
    }

    // ---------------------------- NewPriceUpdateAdded ----------------------------

    /// @notice The event reports only prices the pair stored, each with the funding index it
    ///         accrued to, so consecutive events bracket every move of the index.
    function test_newPriceUpdateAdded_storedPricesOnly_carriesFundingIndex() public {
        // A fill above the index lifts the mark, so the next stored price accrues funding.
        _openPosition(alice, bob, true, BTC / 10);
        vm.warp(vm.getBlockTimestamp() + 60);
        int256 indexBefore = pair.currentFundingIndex();

        uint64 ts = uint64(vm.getBlockTimestamp());
        bytes[] memory pu = _priceUpdate(50_000, ts);
        vm.recordLogs();
        pair.refreshPrice(pu);
        Vm.Log[] memory prices = _logs(vm.getRecordedLogs(), BazaarPair.NewPriceUpdateAdded.selector);

        assertEq(prices.length, 1, "the stored price is reported");
        assertEq(uint256(prices[0].topics[2]), ts, "its publish time");
        (uint256 spot, int32 exponent, int256 fundingIndex) = abi.decode(prices[0].data, (uint256, int32, int256));
        assertEq(spot, 50_000 * BAZAAR_SCALE, "spot");
        assertEq(int256(exponent), -18, "exponent");
        assertEq(fundingIndex, pair.currentFundingIndex(), "the index after accruing to this price");
        assertTrue(fundingIndex != indexBefore, "the stored price moved the index");

        // The same tick again is not newer than the stored one: nothing is stored or reported.
        bytes[] memory again = _priceUpdate(50_000, ts);
        vm.recordLogs();
        pair.refreshPrice(again);
        assertEq(
            _logs(vm.getRecordedLogs(), BazaarPair.NewPriceUpdateAdded.selector).length,
            0,
            "a price the pair did not store is not reported"
        );
    }

    // ---------------------------- InsolvencySettlementFixed ----------------------------

    /// @notice A recorded deficit makes the next health check fix the settlement price, and the
    ///         pair announces it itself, since no governed path is involved.
    function test_insolvencySettlementFixed_deficit() public {
        _stdstore.target(address(pair)).sig("pairVault()").depth(11).checked_write(100 * BAZAAR_SCALE);
        bytes32 pid = pair.pairId();
        bytes[] memory pu = _freshPrice();

        vm.expectEmit(true, false, false, true, address(pair));
        emit BazaarPair.InsolvencySettlementFixed(pid, 50_000 * BAZAAR_SCALE, 4);
        pair.refreshPrice(pu);

        assertGt(pair.settlementPriceFixedTs(), 0, "settlement window open");
        assertEq(pair.auxState().settlementPrice, 50_000 * BAZAAR_SCALE, "at the price the event reports");
    }

    // ---------------------------- PairDeployed ----------------------------

    /// @notice The deployment event carries the listing, including the seed the pair mints to the
    ///         deployer as genesis insurance shares.
    function test_pairDeployed_carriesTheListing() public {
        PythSeed.seed(address(mockPyth), ETH_USD_FEED_ID);
        vm.startPrank(carol);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 aid = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();
        (,,, uint256 seedAmount,,, bytes32 pairId,,,) = factory.deploymentProposals(aid);
        vm.warp(vm.getBlockTimestamp() + factory.DEPLOYMENT_LIVENESS() + 1);

        // The clone's address is only known once it exists; every other field is checked.
        vm.expectEmit(true, false, true, true, address(factory));
        emit BazaarFactory.PairDeployed(pairId, address(0), carol, ETH_USD_FEED_ID, true, seedAmount, "ETH/USD");
        factory.settleDeploymentProposal(aid);

        BazaarPair eth = BazaarPair(payable(factory.getPairAddress(pairId)));
        assertEq(eth.insuranceShares(carol), seedAmount, "the reported seed is the deployer's genesis shares");
    }
}
