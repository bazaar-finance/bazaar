// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {OrderView} from "../OrderView.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MatchingEngineLib} from "../../src/libraries/MatchingEngineLib.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";

/// @title FillOrKillTest
/// @notice The all-or-none time-in-force: a Limit or Market order carrying TimeInForce.FOK fills
///         its whole size against the book on arrival or reverts the transaction. Covers which
///         order types creation accepts it on, the two outcomes the walk can produce, the
///         unwinding of fills already settled when the kill fires, and the lifecycle consequences
///         of an order that cannot outlive its own transaction.
contract FillOrKillTest is IntegrationBase {
    uint256 constant BTC = 1e18;

    function _fund(address u) internal {
        _deposit(u, 50_000 * BAZAAR_SCALE);
    }

    /// @dev A fill-or-kill limit. Expiry is stamped at the creation block whatever the spec says,
    ///      so the inherited 500k-block lifetime is inert here.
    function _fokLimitSpec(bool isLong, uint256 size, uint256 limitPrice)
        internal
        view
        returns (BazaarTypes.OrderSpec memory s)
    {
        s = _limitSpec(isLong, size, limitPrice);
        s.tif = BazaarTypes.TimeInForce.FOK;
    }

    function _fokMarketSpec(bool isLong, uint256 size, uint256 maxSlippageBp)
        internal
        pure
        returns (BazaarTypes.OrderSpec memory s)
    {
        s.orderType = BazaarTypes.OrderType.Market;
        s.isLong = isLong;
        s.size = size;
        s.maxSlippageBp = maxSlippageBp;
        s.tif = BazaarTypes.TimeInForce.FOK;
    }

    function _submit(address user, BazaarTypes.OrderSpec memory s) internal returns (uint256) {
        bytes[] memory pu = _freshPrice(); // built before the prank: the mockPyth call would consume it
        vm.prank(user);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        return _lastCreatedOrderId(pair);
    }

    /// @dev The kill error carries (orderId, remaining), so the selector-only form is the partial
    ///      one. Tests that care about the shortfall itself assert the encoded args instead.
    function _expectKill(address user, BazaarTypes.OrderSpec memory s) internal {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        vm.expectPartialRevert(MatchingEngineLib.MatchingEngineLib__FillOrKillUnfilled.selector);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
    }

    function _expectTifRevert(address user, BazaarTypes.OrderSpec memory s) internal {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__InvalidTimeInForce.selector);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
    }

    // ============================================================
    // Creation: which types accept TimeInForce.FOK
    // ============================================================

    function test_fok_rejectedOnStopLimit() public {
        _fund(alice);
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.StopLimit;
        s.isLong = true;
        s.size = BTC / 10;
        s.triggerPrice = 55_000 * BAZAAR_SCALE;
        s.limitPrice = 56_000 * BAZAAR_SCALE;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        s.tif = BazaarTypes.TimeInForce.FOK;
        _expectTifRevert(alice, s);
    }

    function test_fok_rejectedOnTakeProfit() public {
        _openPosition(alice, bob, true, BTC / 10);
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.TakeProfit;
        s.isLong = false;
        s.size = BTC / 10;
        s.triggerPrice = 55_000 * BAZAAR_SCALE;
        s.maxSlippageBp = 500;
        s.tif = BazaarTypes.TimeInForce.FOK;
        _expectTifRevert(alice, s);
    }

    function test_fok_rejectedOnStopLoss() public {
        _openPosition(alice, bob, true, BTC / 10);
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.StopLoss;
        s.isLong = false;
        s.size = BTC / 10;
        s.triggerPrice = 45_000 * BAZAAR_SCALE;
        s.maxSlippageBp = 500;
        s.tif = BazaarTypes.TimeInForce.FOK;
        _expectTifRevert(alice, s);
    }

    /// @notice Post-only forbids taking; fill-or-kill demands a complete immediate take.
    function test_fok_rejectedAlongsidePostOnly() public {
        _fund(alice);
        BazaarTypes.OrderSpec memory s = _fokLimitSpec(true, BTC / 10, 49_000 * BAZAAR_SCALE);
        s.isPostOnly = true;
        _expectTifRevert(alice, s);
    }

    /// @notice The one type where the two non-default values diverge. A Bazaar market order is
    ///         slippage-bounded, so "all of it, within my tolerance" is a real instruction —
    ///         while "cancel the remainder" is already what every market order does, which is why
    ///         IOC is refused there and FOK is not.
    function test_fok_acceptedOnMarket_whereIocIsNot() public {
        _fund(alice);
        _fund(bob);
        _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);

        BazaarTypes.OrderSpec memory asIoc = _fokMarketSpec(true, BTC / 10, 300);
        asIoc.tif = BazaarTypes.TimeInForce.IOC;
        _expectTifRevert(alice, asIoc);

        uint256 taker = _submit(alice, _fokMarketSpec(true, BTC / 10, 300));
        assertEq(_filledSize(taker), BTC / 10, "the same order as fill-or-kill is accepted");
    }

    // ============================================================
    // The fill outcome
    // ============================================================

    function test_fok_limit_fillsWholeSizeAcrossLevels() public {
        _fund(alice);
        _fund(bob);
        _fund(carol);

        uint256 a1 = _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);
        uint256 a2 = _placeLimit(carol, false, BTC / 10, 50_400 * BAZAAR_SCALE);

        uint256 taker = _submit(alice, _fokLimitSpec(true, BTC / 5, 50_500 * BAZAAR_SCALE));

        assertEq(_filledSize(taker), BTC / 5, "whole size filled");
        assertEq(_filledSize(a1), BTC / 10, "best level consumed");
        assertEq(_filledSize(a2), BTC / 10, "second level consumed");
        assertFalse(_inBook(taker), "a fill-or-kill order never rests");
        assertEq(_canceledBlock(taker), 0, "a completed fill-or-kill order is filled, not canceled");
        assertGt(OrderView.order(pair, taker).filledBlock, 0, "stamped terminal by the completing fill");

        (, uint256 sz,,,,,,,) = pair.positionBuckets(alice);
        assertEq(sz, BTC / 5, "position opened for the full size");
        _assertBooks("after a complete fill-or-kill");
    }

    function test_fok_market_fillsWholeSize() public {
        _fund(alice);
        _fund(bob);

        uint256 ask = _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);
        uint256 taker = _submit(alice, _fokMarketSpec(true, BTC / 10, 300));

        assertEq(_filledSize(taker), BTC / 10, "whole size filled");
        assertEq(_filledSize(ask), BTC / 10, "maker consumed");
        assertFalse(_inBook(taker), "market orders never rest");
        _assertBooks("after a complete fill-or-kill market order");
    }

    // ============================================================
    // The kill outcome
    // ============================================================

    function test_fok_limit_killedWhenBookIsEmpty() public {
        _fund(alice);
        _expectKill(alice, _fokLimitSpec(true, BTC / 10, 50_500 * BAZAAR_SCALE));

        (uint64 bidHead, uint64 askHead,,) = pair.book();
        assertEq(bidHead, 0, "nothing rested");
        assertEq(askHead, 0);
        assertEq(_posSize(alice), 0, "no position opened");
    }

    /// @notice The case an ordinary limit would rest through: a non-crossing price. Resting is
    ///         exactly what fill-or-kill forbids, so it kills instead.
    function test_fok_limit_killedWhenNonCrossing() public {
        _fund(alice);
        _fund(bob);
        uint256 ask = _placeLimit(bob, false, BTC / 10, 50_500 * BAZAAR_SCALE);

        _expectKill(alice, _fokLimitSpec(true, BTC / 10, 49_500 * BAZAAR_SCALE));

        assertEq(_filledSize(ask), 0, "the resting ask was never touched");
        assertTrue(_inBook(ask), "and still rests");
        (uint64 bidHead,,,) = pair.book();
        assertEq(bidHead, 0, "the killed order left no bid behind");
    }

    /// @notice Depth exists but not enough of it. The partial that an ordinary limit would keep is
    ///         the whole point of the flag.
    function test_fok_limit_killedWhenDepthIsShort() public {
        _fund(alice);
        _fund(bob);
        uint256 ask = _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);

        // Asserted with its arguments: the error reports the shortfall the walk could not cover,
        // which is the whole size less the 0.1 on offer. Ids are a gapless counter, so the killed
        // order would have taken the one after the ask.
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(MatchingEngineLib.MatchingEngineLib__FillOrKillUnfilled.selector, ask + 1, BTC / 5)
        );
        pair.createOrder(_fokLimitSpec(true, 3 * BTC / 10, 50_500 * BAZAAR_SCALE), _hintsNone(), pu, 0, 0, 0, "", "");

        assertEq(_filledSize(ask), 0, "the fill the walk settled was unwound");
        assertTrue(_inBook(ask), "maker still resting");
        assertEq(_posSize(alice), 0, "no position opened");
    }

    /// @notice The kill unwinds every fill the walk had already settled, not just the last one:
    ///         two makers are consumed before the shortfall is discovered, and both come back.
    function test_fok_kill_unwindsAllEarlierFills() public {
        _fund(alice);
        _fund(bob);
        _fund(carol);

        uint256 a1 = _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);
        uint256 a2 = _placeLimit(carol, false, BTC / 10, 50_400 * BAZAAR_SCALE);
        uint256 collateralBefore = _posCollateral(bob);

        // 0.3 wanted, 0.2 available within the limit.
        _expectKill(alice, _fokLimitSpec(true, 3 * BTC / 10, 50_500 * BAZAAR_SCALE));

        assertEq(_filledSize(a1), 0, "first maker's fill unwound");
        assertEq(_filledSize(a2), 0, "second maker's fill unwound");
        assertTrue(_inBook(a1), "first maker still resting");
        assertTrue(_inBook(a2), "second maker still resting");
        assertEq(_posSize(bob), 0, "no counterparty position survived");
        assertEq(_posSize(carol), 0);
        assertEq(_posCollateral(bob), collateralBefore, "maker collateral untouched by the unwound fill");
        _assertBooks("after a kill");
    }

    /// @notice A market fill-or-kill is bounded by its slippage tolerance, so it can be killed by
    ///         depth that exists but sits outside the bound rather than by an empty book.
    function test_fok_market_killedWhenDepthIsOutsideSlippageBound() public {
        _fund(alice);
        _fund(bob);
        _fund(carol);

        // Mark is $50k; a 1% tolerance bounds the walk at $50,500.
        uint256 inside = _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);
        uint256 outside = _placeLimit(carol, false, BTC / 10, 50_900 * BAZAAR_SCALE);

        _expectKill(alice, _fokMarketSpec(true, BTC / 5, 100));

        assertEq(_filledSize(inside), 0, "the in-bound fill was unwound");
        assertEq(_filledSize(outside), 0, "the out-of-bound maker was never reachable");
        assertTrue(_inBook(inside), "both makers still rest");
        assertTrue(_inBook(outside));

        // The same order with a tolerance wide enough to reach the second level completes.
        uint256 taker = _submit(alice, _fokMarketSpec(true, BTC / 5, 300));
        assertEq(_filledSize(taker), BTC / 5, "reachable depth fills the whole size");
    }

    /// @notice Self-match kills the arriving order, which for fill-or-kill means the transaction.
    function test_fok_killedBySelfMatch() public {
        _fund(alice);
        uint256 bid = _placeLimit(alice, true, BTC / 10, 50_200 * BAZAAR_SCALE);

        _expectKill(alice, _fokLimitSpec(false, BTC / 10, 49_800 * BAZAAR_SCALE));

        assertEq(_filledSize(bid), 0, "own resting order untouched");
        assertTrue(_inBook(bid), "and still resting");
    }

    // ============================================================
    // Lifecycle: an order that cannot outlive its own transaction
    // ============================================================

    /// @notice A completed fill-or-kill limit leaves nothing behind for a later transaction to
    ///         read: it is stamped expired at creation and never joins the owner's active set.
    function test_fok_limit_isTerminalAtCreation_andNeverJoinsActiveSet() public {
        _fund(alice);
        _fund(bob);
        _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);

        (, uint256 countBefore,,) = pair.getUserActiveLimitOrders(alice);
        assertEq(countBefore, 0, "alice starts with no active limit orders");

        uint256 taker = _submit(alice, _fokLimitSpec(true, BTC / 10, 50_500 * BAZAAR_SCALE));

        BazaarTypes.Order memory o = OrderView.order(pair, taker);
        assertEq(uint256(o.expiryBlock), vm.getBlockNumber(), "stamped expired at the creation block");
        assertEq(o.filledSize, o.size, "and completely filled");

        (, uint256 countAfter,,) = pair.getUserActiveLimitOrders(alice);
        assertEq(countAfter, 0, "a fill-or-kill limit never registers as an active limit order");

        (uint256 longExp,, uint256 longSz,) = pair.outstandingOrderExposure(alice);
        assertEq(longExp, 0, "and contributes no outstanding order exposure");
        assertEq(longSz, 0);
    }
}
