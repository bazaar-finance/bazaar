// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {OrderView} from "../OrderView.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MatchingEngineLib} from "../../src/libraries/MatchingEngineLib.sol";

/// @title StaleArrivalTest
/// @notice Arrival matching under the stale-oracle fallback (session-bound pairs overnight):
///         non-crossing arrivals insert; crossings against makers priced within
///         ±MAX_STALE_DEVIATION_BP of the last stored price fill; a maker priced beyond the
///         band away from the taker cancels the INCOMING order and stays; one priced beyond it
///         toward the taker is itself canceled and the walk continues; market orders and
///         trigger execution are rejected outright.
contract StaleArrivalTest is IntegrationBase {
    uint256 constant SHARE = 1e18;
    uint256 constant PX = 200; // AAPL reference price in whole USD

    function _aaplDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev Store a fresh AAPL price so the pair has a stale-fallback reference, then step past
    ///      MAX_PRICE_STALENESS so subsequent empty-update calls run on the fallback.
    function _seedPriceThenGoStale(uint256 priceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, priceUsd, uint64(vm.getBlockTimestamp()));
        aaplPair.refreshPrice{value: 0}(pu);
        vm.warp(vm.getBlockTimestamp() + 60); // well past the 2s freshness bound
    }

    /// @dev Place an AAPL limit with NO price update — consumes the stale fallback.
    function _stalePlace(address user, bool isLong, uint256 size, uint256 limitPrice, bool ioc)
        internal
        returns (uint256)
    {
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Limit;
        s.isLong = isLong;
        s.tif = ioc ? BazaarTypes.TimeInForce.IOC : BazaarTypes.TimeInForce.GTC;
        s.size = size;
        s.limitPrice = limitPrice;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        vm.prank(user);
        aaplPair.createOrder(s, _hintsNone(), new bytes[](0), 0, 0, 0, "", "");
        return _lastCreatedOrderId(aaplPair);
    }

    function _aaplFilled(uint256 orderId) internal view returns (uint256 f) {
        return OrderView.order(aaplPair, orderId).filledSize;
    }

    function _aaplCanceled(uint256 orderId) internal view returns (uint64 cb) {
        return OrderView.order(aaplPair, orderId).canceledBlock;
    }

    function _aaplInBook(uint256 orderId) internal view returns (bool b) {
        return OrderView.order(aaplPair, orderId).inBook;
    }

    function setUp() public override {
        super.setUp();
        _aaplDeposit(alice, 5_000 * BAZAAR_SCALE);
        _aaplDeposit(bob, 5_000 * BAZAAR_SCALE);
        _seedPriceThenGoStale(PX);
    }

    function test_stale_nonCrossing_inserts() public {
        uint256 bid = _stalePlace(alice, true, 2 * SHARE, 195 * BAZAAR_SCALE, false);
        assertTrue(_aaplInBook(bid), "non-crossing arrival rests under the stale fallback");
        assertEq(_aaplCanceled(bid), 0);
    }

    function test_stale_inBandCross_fillsAtMakerPrice() public {
        // Maker within ±10% of the $200 reference ($180..$220).
        uint256 ask = _stalePlace(bob, false, 2 * SHARE, 202 * BAZAAR_SCALE, false);
        uint256 bid = _stalePlace(alice, true, 2 * SHARE, 205 * BAZAAR_SCALE, false);

        assertEq(_aaplFilled(bid), 2 * SHARE, "in-band crossing fills while stale");
        assertEq(_aaplFilled(ask), 2 * SHARE);
        (, uint256 sz, uint256 entry,,,,,,) = aaplPair.positionBuckets(alice);
        assertEq(sz, 2 * SHARE);
        assertEq(entry, 2 * 202 * BAZAAR_SCALE, "filled at the maker's price");
    }

    function test_stale_farSideCross_cancelsIncoming_makerStays() public {
        // A maker resting 12.5% above the reference is legitimate gap positioning; it inserts
        // (only fills are banded)...
        uint256 farAsk = _stalePlace(bob, false, 2 * SHARE, 225 * BAZAAR_SCALE, false);
        assertTrue(_aaplInBook(farAsk), "out-of-band placement is allowed to rest");

        // ...but an arrival demanding execution out there is canceled outright: filling at $225
        // over a $200 reference breaches the band away from the taker, and the ask list is
        // price-sorted so nothing deeper could fill either.
        uint256 bid = _stalePlace(alice, true, 2 * SHARE, 230 * BAZAAR_SCALE, false);
        assertEq(_aaplFilled(bid), 0, "no out-of-band fill");
        assertGt(_aaplCanceled(bid), 0, "incoming order canceled");
        assertFalse(_aaplInBook(bid), "canceled arrival does not rest");
        assertTrue(_aaplInBook(farAsk), "resting maker stays");
        assertEq(_aaplFilled(farAsk), 0);
    }

    function test_stale_nearSideMaker_canceled_arrivalRests() public {
        // An ask resting below the band offers out-of-band execution to every arriving buyer.
        // On contact the MAKER is the one canceled — canceling takers here instead would let
        // this single order at the head execute every buy-side arrival for the whole closed
        // session.
        uint256 nearAsk = _stalePlace(bob, false, 2 * SHARE, 178 * BAZAAR_SCALE, false);
        assertTrue(_aaplInBook(nearAsk), "rests until contact");

        uint256 bid = _stalePlace(alice, true, 2 * SHARE, 185 * BAZAAR_SCALE, false);
        assertGt(_aaplCanceled(nearAsk), 0, "near-side maker canceled on contact");
        assertFalse(_aaplInBook(nearAsk));
        assertEq(_aaplFilled(bid), 0, "no fill printed outside the band");
        assertEq(_aaplCanceled(bid), 0, "arrival survives");
        assertTrue(_aaplInBook(bid), "arrival rests once the book is clear");
    }

    function test_stale_marketOrder_reverts() public {
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Market;
        s.isLong = true;
        s.size = 2 * SHARE;
        s.maxSlippageBp = 100;
        vm.prank(alice);
        vm.expectRevert(MatchingEngineLib.MatchingEngineLib__BlockedOracleStale.selector);
        aaplPair.createOrder(s, _hintsNone(), new bytes[](0), 0, 0, 0, "", "");
    }

    function test_stale_triggerExecution_reverts() public {
        // Create an untriggered stop while stale (stops never arm under the fallback), then try
        // to fire it with no fresh price.
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.StopLimit;
        s.isLong = true;
        s.size = 2 * SHARE;
        s.triggerPrice = 210 * BAZAAR_SCALE;
        s.limitPrice = 212 * BAZAAR_SCALE;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        vm.prank(alice);
        aaplPair.createOrder(s, _hintsNone(), new bytes[](0), 0, 0, 0, "", "");
        uint256 stop = _lastCreatedOrderId(aaplPair);
        assertFalse(_aaplInBook(stop), "stop rests untriggered while stale");

        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](1);
        execs[0].orderId = uint64(stop);
        vm.prank(seq);
        vm.expectRevert(MatchingEngineLib.MatchingEngineLib__BlockedOracleStale.selector);
        aaplPair.executeTriggeredOrders(execs, new bytes[](0));
    }

    function test_stale_ioc_inBandFill_thenCancel() public {
        _stalePlace(bob, false, 1 * SHARE, 202 * BAZAAR_SCALE, false);
        uint256 ioc = _stalePlace(alice, true, 3 * SHARE, 205 * BAZAAR_SCALE, true);

        assertEq(_aaplFilled(ioc), 1 * SHARE, "IOC filled the in-band liquidity");
        assertGt(_aaplCanceled(ioc), 0, "IOC remainder canceled, not rested");
        assertFalse(_aaplInBook(ioc));
    }

    function test_freshResume_noBand() public {
        // A maker 15% below the stale reference rests during the stale window...
        uint256 farAsk = _stalePlace(bob, false, 2 * SHARE, 170 * BAZAAR_SCALE, false);

        // ...and once a fresh print arrives, the band is gone: an arrival crosses it normally
        // (margin is checked at the fresh price; the fill stays at the maker's price).
        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, 175, uint64(vm.getBlockTimestamp()));
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Limit;
        s.isLong = true;
        s.size = 2 * SHARE;
        s.limitPrice = 176 * BAZAAR_SCALE;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        vm.prank(alice);
        aaplPair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 bid = _lastCreatedOrderId(aaplPair);

        assertEq(_aaplFilled(bid), 2 * SHARE, "fresh-price crossing fills without the stale band");
        assertEq(_aaplFilled(farAsk), 2 * SHARE);
    }
}
