// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {OrderView} from "../OrderView.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BucketStore} from "../BucketStore.sol";

/// @title ArrivalMatchTest
/// @notice Behavioral coverage of arrival matching: an incoming order walks the opposing side of
///         the book inside its own createOrder, fills at each resting maker's limit price in
///         price-time order, and disposes of its remainder (rest, or cancel for IOC/market/
///         post-only/self-match/step-cap/dust). The book must never rest crossed.
contract ArrivalMatchTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BTC = 1e18;

    function _fund(address u) internal {
        _deposit(u, 50_000 * BAZAAR_SCALE);
    }

    /// @dev Book heads reader.
    function _book() internal view returns (uint64 bidHead, uint64 askHead, uint64 bidCount, uint64 askCount) {
        return pair.book();
    }

    function _limitPriceOf(uint256 orderId) internal view returns (uint256 p) {
        return OrderView.order(pair, orderId).limitPrice;
    }

    // ============================================================
    // Price-time priority + fill-at-maker-price
    // ============================================================

    function test_arrival_fillsBestPriceFirst_atMakerPrices() public {
        _fund(alice);
        _fund(bob);
        _fund(carol);

        // Ask ladder: bob 0.1 @ 50_200, carol 0.1 @ 50_400.
        uint256 a1 = _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);
        uint256 a2 = _placeLimit(carol, false, BTC / 10, 50_400 * BAZAAR_SCALE);
        (, uint64 askHead,, uint64 askCount) = _book();
        assertEq(uint256(askHead), a1, "best ask is the lower price");
        assertEq(uint256(askCount), 2);

        // Alice arrives with a marketable limit covering both levels.
        uint256 taker = _placeLimit(alice, true, BTC / 5, 50_500 * BAZAAR_SCALE);
        assertEq(_filledSize(taker), BTC / 5, "taker fully filled across two levels");
        assertEq(_filledSize(a1), BTC / 10, "best level consumed first");
        assertEq(_filledSize(a2), BTC / 10, "second level consumed");

        // Fills settled at the MAKERS' prices: alice's entry value is 0.1×50200 + 0.1×50400.
        (, uint256 sz, uint256 entryValue,,,,) = pair.positionBuckets(alice);
        assertEq(sz, BTC / 5);
        assertEq(entryValue, (50_200 * BAZAAR_SCALE + 50_400 * BAZAAR_SCALE) / 10, "entry at maker prices");

        (, uint64 askHeadAfter,, uint64 askCountAfter) = _book();
        assertEq(askHeadAfter, 0, "ask side emptied");
        assertEq(askCountAfter, 0);
        _assertBooks("after two-level sweep");
    }

    function test_arrival_equalPrice_fifoWithinLevel() public {
        _fund(alice);
        _fund(bob);
        _fund(carol);

        // Two asks at the SAME price; bob's is older.
        uint256 first = _placeLimit(bob, false, BTC / 10, 50_300 * BAZAAR_SCALE);
        uint256 second = _placeLimit(carol, false, BTC / 10, 50_300 * BAZAAR_SCALE);

        // A taker for half the level's size must consume the OLDER order only.
        _placeLimit(alice, true, BTC / 10, 50_300 * BAZAAR_SCALE);
        assertEq(_filledSize(first), BTC / 10, "older same-price maker fills first");
        assertEq(_filledSize(second), 0, "newer same-price maker untouched");

        (, uint64 askHead,,) = _book();
        assertEq(uint256(askHead), second, "newer order now heads the level");
    }

    function test_arrival_nonCrossing_restsInBook() public {
        _fund(alice);
        _fund(bob);

        uint256 bid = _placeLimit(alice, true, BTC / 10, 49_500 * BAZAAR_SCALE);
        uint256 ask = _placeLimit(bob, false, BTC / 10, 50_500 * BAZAAR_SCALE);

        assertTrue(_inBook(bid), "bid rests");
        assertTrue(_inBook(ask), "ask rests");
        (uint64 bidHead, uint64 askHead,,) = _book();
        assertEq(uint256(bidHead), bid);
        assertEq(uint256(askHead), ask);
        assertEq(_filledSize(bid), 0);
        assertEq(_filledSize(ask), 0);
    }

    function test_arrival_partialFill_restsRemainderUncrossed() public {
        _fund(alice);
        _fund(bob);

        _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);
        // Taker wants 0.3 but only 0.1 is on offer within its limit.
        uint256 taker = _placeLimit(alice, true, 3 * BTC / 10, 50_200 * BAZAAR_SCALE);

        assertEq(_filledSize(taker), BTC / 10, "filled what crossed");
        assertTrue(_inBook(taker), "remainder rests as the new best bid");
        (uint64 bidHead, uint64 askHead,,) = _book();
        assertEq(uint256(bidHead), taker);
        assertEq(askHead, 0, "no crossed book: the consumed ask is gone");
        _assertBooks("after partial fill");
    }

    // ============================================================
    // IOC / post-only / self-match / dust / step-cap dispositions
    // ============================================================

    function test_arrival_ioc_fillsThenCancelsRemainder() public {
        _fund(alice);
        _fund(bob);

        _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);

        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(true, 3 * BTC / 10, 50_200 * BAZAAR_SCALE);
        s.tif = BazaarTypes.TimeInForce.IOC;
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 taker = _lastCreatedOrderId(pair);

        assertEq(_filledSize(taker), BTC / 10, "IOC filled the crossing portion");
        assertFalse(_inBook(taker), "IOC remainder never rests");
        assertGt(_canceledBlock(taker), 0, "IOC remainder canceled in the same tx");
    }

    function test_arrival_postOnly_nonCrossing_rests() public {
        _fund(alice);
        _fund(bob);
        _placeLimit(bob, false, BTC / 10, 50_500 * BAZAAR_SCALE);

        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(true, BTC / 10, 49_500 * BAZAAR_SCALE);
        s.isPostOnly = true;
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 id = _lastCreatedOrderId(pair);

        assertTrue(_inBook(id), "non-crossing post-only rests");
        assertEq(_canceledBlock(id), 0);
    }

    function test_arrival_postOnly_crossing_cancelsBeforeAnyFill() public {
        _fund(alice);
        _fund(bob);
        uint256 ask = _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);

        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(true, BTC / 10, 50_300 * BAZAAR_SCALE);
        s.isPostOnly = true;
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 id = _lastCreatedOrderId(pair);

        assertEq(_filledSize(id), 0, "post-only never takes");
        assertGt(_canceledBlock(id), 0, "crossing post-only cancels");
        assertEq(_filledSize(ask), 0, "maker untouched");
        assertTrue(_inBook(ask), "maker still resting");
    }

    function test_arrival_selfMatch_cancelsIncomingRemainder() public {
        _fund(alice);
        _fund(bob);

        // Bob's ask is the best; alice's ask sits behind it. Alice's crossing bid fills bob's
        // level, then meets her own resting ask — the incoming remainder cancels; her resting
        // ask stays.
        uint256 bobAsk = _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);
        uint256 aliceAsk = _placeLimit(alice, false, BTC / 10, 50_300 * BAZAAR_SCALE);

        uint256 taker = _placeLimit(alice, true, 3 * BTC / 10, 50_400 * BAZAAR_SCALE);
        assertEq(_filledSize(taker), BTC / 10, "filled the other maker only");
        assertGt(_canceledBlock(taker), 0, "incoming remainder canceled on self-match");
        assertFalse(_inBook(taker));
        assertEq(_filledSize(bobAsk), BTC / 10);
        assertTrue(_inBook(aliceAsk), "own resting order untouched");
        assertEq(_filledSize(aliceAsk), 0);
    }

    function test_arrival_dustRemainder_cancels() public {
        _fund(alice);
        _fund(bob);

        // Ask for 0.0999 BTC; taker wants 0.1. The 0.0001 BTC remainder (~$5.02 at the $50.2k
        // limit... use a smaller residual) — construct a residual below $5: taker 0.10002 vs
        // maker 0.1 leaves 0.00002 BTC ≈ $1 — below MIN_ORDER_AMOUNT, not a full close → cancel.
        _placeLimit(bob, false, BTC / 10, 50_200 * BAZAAR_SCALE);
        uint256 taker = _placeLimit(alice, true, BTC / 10 + 2e13, 50_200 * BAZAAR_SCALE);

        assertEq(_filledSize(taker), BTC / 10, "crossing portion filled");
        assertFalse(_inBook(taker), "sub-minimum remainder does not rest");
        assertGt(_canceledBlock(taker), 0, "dust remainder canceled");
    }

    function test_arrival_dustRemainder_fullCloseExemption_rests() public {
        // A position whose notional sits below the $5 floor at in-band prices: 0.00009 BTC is
        // ~$4.4 near a $50k mark. Un-openable through the book (the open would fail the floor),
        // so it is written directly — the state a position reaches by drifting or by partial
        // closes. Offering EXACTLY the whole position is admitted under the full-close
        // exemption, and the walk's remainder disposition re-applies the same exemption — the
        // order rests instead of being canceled as dust.
        _fund(alice);
        uint256 tiny = 9 * BTC / 100_000; // 0.00009 BTC
        BucketStore.setIsLong(address(pair), alice, true);
        BucketStore.setSize(address(pair), alice, tiny);
        BucketStore.setEntryValue(address(pair), alice, tiny * 50_000); // entry at $50k
        uint256 closeAsk = _placeLimit(alice, false, tiny, 49_000 * BAZAAR_SCALE); // ~$4.4 notional

        assertTrue(_inBook(closeAsk), "full-close remainder rests despite sub-$5 notional");
        assertEq(_canceledBlock(closeAsk), 0);
    }

    function test_arrival_stepCap_cancelsStillCrossingRemainder() public {
        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(dave);

        // Three crossing asks; the taker's cap allows visiting only two nodes.
        uint256 a1 = _placeLimit(bob, false, BTC / 10, 50_100 * BAZAAR_SCALE);
        uint256 a2 = _placeLimit(carol, false, BTC / 10, 50_200 * BAZAAR_SCALE);
        uint256 a3 = _placeLimit(dave, false, BTC / 10, 50_300 * BAZAAR_SCALE);

        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(true, 3 * BTC / 10, 50_400 * BAZAAR_SCALE);
        BazaarTypes.MatchHints memory hints;
        hints.maxSteps = 2;
        vm.prank(alice);
        pair.createOrder(s, hints, pu, 0, 0, 0, "", "");
        uint256 taker = _lastCreatedOrderId(pair);

        assertEq(_filledSize(taker), 2 * BTC / 10, "two fills inside the cap");
        assertEq(_filledSize(a1), BTC / 10);
        assertEq(_filledSize(a2), BTC / 10);
        assertEq(_filledSize(a3), 0, "third maker beyond the cap");
        assertGt(_canceledBlock(taker), 0, "still-crossing remainder canceled at the cap");
        assertFalse(_inBook(taker), "the book never rests crossed");
        (uint64 bidHead,,,) = _book();
        assertEq(bidHead, 0, "no crossed bid left behind");
    }

    // ============================================================
    // Maker liveness on contact: expiry + margin failure
    // ============================================================

    function test_arrival_expiredMaker_removedOnContact_thenNextFills() public {
        _fund(alice);
        _fund(bob);
        _fund(carol);

        // Bob's ask expires quickly; carol's sits behind it.
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(false, BTC / 10, 50_100 * BAZAAR_SCALE);
        s.expirationBlock = uint64(vm.getBlockNumber()) + BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS;
        vm.prank(bob);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 expiring = _lastCreatedOrderId(pair);
        uint256 live = _placeLimit(carol, false, BTC / 10, 50_200 * BAZAAR_SCALE);

        _roll(BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 1); // bob's ask is now expired but still linked

        uint256 taker = _placeLimit(alice, true, BTC / 10, 50_300 * BAZAAR_SCALE);
        assertEq(_filledSize(expiring), 0, "expired maker never fills");
        assertGt(_canceledBlock(expiring), 0, "expired maker canceled on contact");
        assertFalse(_inBook(expiring), "expired maker unlinked");
        assertEq(_filledSize(live), BTC / 10, "walk continued to the live maker");
        assertEq(_filledSize(taker), BTC / 10);
    }

    function test_arrival_makerMarginFail_autoCanceled_thenNextFills() public {
        _fund(alice);
        _fund(carol);
        _deposit(bob, 2_000 * BAZAAR_SCALE);

        uint256 weak = _placeLimit(bob, false, BTC / 10, 50_100 * BAZAAR_SCALE);
        uint256 strong = _placeLimit(carol, false, BTC / 10, 50_200 * BAZAAR_SCALE);

        // Strip bob's collateral after placement so his fill-time margin check fails.
        BucketStore.setCollateral(address(pair), bob, uint256(1e15));

        uint256 taker = _placeLimit(alice, true, BTC / 10, 50_300 * BAZAAR_SCALE);
        assertGt(_canceledBlock(weak), 0, "margin-failing maker auto-canceled");
        assertFalse(_inBook(weak));
        assertEq(_filledSize(weak), 0);
        assertEq(_filledSize(strong), BTC / 10, "walk retried the next maker");
        assertEq(_filledSize(taker), BTC / 10);
    }

    // ============================================================
    // TP/SL fence mid-fill: canceled resting orders can never fill
    // ============================================================

    function test_fence_cancelsTakeProfitMidFill_soItCanNeverFire() public {
        // Bob holds a long with a TakeProfit covering all of it, plus a plain closing ask near
        // the market. A buyer consumes the near ask, taking bob flat — the fence must cancel the
        // now-oversized TP in that same fill, so a keeper cannot later fire a close-only order
        // against a position that no longer exists.
        _openPosition(bob, carol, true, BTC / 10); // bob long 0.1 at 51k entry
        _fund(alice);
        _fund(dave);

        uint256 tp = _placeTakeProfit(bob, false, BTC / 10, 52_000 * BAZAAR_SCALE, 500);
        assertFalse(_inBook(tp), "TakeProfit waits outside the book");
        assertEq(_takeProfitOrderId(bob), tp, "TP slot anchored");

        uint256 closeAsk = _placeLimit(bob, false, BTC / 10, 50_100 * BAZAAR_SCALE);

        // Alice buys the near ask → bob flat → fence cancels the TP.
        _placeLimit(alice, true, BTC / 10, 50_150 * BAZAAR_SCALE);
        assertEq(_filledSize(closeAsk), BTC / 10, "near ask filled");
        assertEq(_posSize(bob), 0, "bob flat");
        assertGt(_canceledBlock(tp), 0, "fence canceled the oversized TP");
        assertEq(_takeProfitOrderId(bob), 0, "TP slot cleared");

        // Liquidity exists at the target, and the price reaches it — the canceled TP still must
        // not fire.
        _placeLimitAt(dave, true, BTC / 10, 52_000 * BAZAAR_SCALE, 52_000);
        assertEq(_executeTriggerAt(tp, 52_000), 0, "canceled TP is skipped by the keeper");
        assertEq(_filledSize(tp), 0, "canceled TP can never fill");
        _assertBooks("after fence scenario");
    }

    // ============================================================
    // Market orders
    // ============================================================

    function test_market_fillsAtRestingPrices_remainderCancels() public {
        _fund(alice);
        _fund(bob);

        _placeLimit(bob, false, BTC / 10, 50_100 * BAZAAR_SCALE);
        uint256 taker = _placeMarket(alice, true, 3 * BTC / 10, 300); // 3% slippage cap

        assertEq(_filledSize(taker), BTC / 10, "market filled available liquidity");
        assertGt(_canceledBlock(taker), 0, "market remainder canceled in the same tx");
        assertFalse(_inBook(taker), "market orders never rest");

        (, uint256 sz, uint256 entryValue,,,,) = pair.positionBuckets(alice);
        assertEq(sz, BTC / 10);
        assertEq(entryValue, 50_100 * BAZAAR_SCALE / 10, "market filled at the maker's price");
    }

    function test_market_emptyBook_terminalImmediately() public {
        _fund(alice);
        uint256 taker = _placeMarket(alice, true, BTC / 10, 300);

        assertEq(_filledSize(taker), 0);
        assertGt(_canceledBlock(taker), 0, "unfillable market order is terminal at creation");
        assertEq(_posSize(alice), 0);
    }

    function test_market_respectsSlippageBound() public {
        _fund(alice);
        _fund(bob);

        // Ask at 4% above oracle; market order tolerates only 1%.
        uint256 farAsk = _placeLimit(bob, false, BTC / 10, 52_000 * BAZAAR_SCALE);
        uint256 taker = _placeMarket(alice, true, BTC / 10, 100); // 1% → bound $50,500

        assertEq(_filledSize(taker), 0, "no fill past the slippage bound");
        assertGt(_canceledBlock(taker), 0);
        assertTrue(_inBook(farAsk), "out-of-bound maker untouched");
    }

    // ============================================================
    // Hinted insertion through the pair
    // ============================================================

    function test_hintedInsert_landsMidBook() public {
        _fund(alice);
        _fund(bob);
        _fund(carol);
        _fund(dave);

        uint256 a1 = _placeLimit(bob, false, BTC / 10, 50_100 * BAZAAR_SCALE);
        uint256 a3 = _placeLimit(carol, false, BTC / 10, 50_300 * BAZAAR_SCALE);

        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(false, BTC / 10, 50_200 * BAZAAR_SCALE);
        BazaarTypes.MatchHints memory hints;
        hints.pred = uint64(a1);
        vm.prank(dave);
        pair.createOrder(s, hints, pu, 0, 0, 0, "", "");
        uint256 mid = _lastCreatedOrderId(pair);

        // Traverse: a1 → mid → a3.
        uint64 nextOfA1 = OrderView.order(pair, a1).nextInBook;
        assertEq(uint256(nextOfA1), mid, "hinted insert landed after its predecessor");
        uint64 nextOfMid = OrderView.order(pair, mid).nextInBook;
        assertEq(uint256(nextOfMid), a3, "and before its successor");
    }
}
