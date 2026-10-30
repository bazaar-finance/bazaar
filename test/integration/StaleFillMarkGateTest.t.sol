// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";
import {OrderView} from "../OrderView.sol";

/// @title StaleFillMarkGateTest
/// @notice On a non-continuously-traded pair a fill against the stale fallback leaves the mark
///         alone: neither the mark price nor its clock moves, so the next stored price finds a
///         mark that has decayed onto the index and accrues no funding. The mark update clamps
///         the print around the index and measures the premium the print adds against it, dated
///         to the fill, so a print judged against an index from an earlier moment would read the
///         index's whole move since then as premium and present it as freshly traded; the next
///         store would then charge it as funding.
///         A fill carrying a fresh price stores its index in the same transaction and enters the
///         mark as usual.
///
///         Both cases share one setup: a fresh fill sets the mark, an hour of quiet decays it onto
///         the index, a keeper stores the unchanged price, and ten minutes later the venue's
///         off-chain price has moved while the on-chain cache is past MAX_PRICE_STALENESS.
///
///         Every fill here is against an ask resting below the index for a full exposure window,
///         the kind of print the mark is built from. In the first the ask linked against a fresh
///         tick, so the reference-age gate is the only thing that keeps its stale fill out; the
///         second is the same fill on the fresh path, which enters. The last two keep a fresh fill
///         out by the ask's own link, since a quote linked against the stale fallback carries no
///         far-side premium (Order.restedPremiumPpm).
contract StaleFillMarkGateTest is IntegrationBase {
    uint256 constant AAPL = 1e18;
    uint256 constant QUIET = 61 minutes; // past MARK_DECAY_PERIOD, so the mark has fully decayed
    uint256 constant LAG = 10 minutes; // the refresh-bounty cadence: how old the stored price gets
    uint256 constant EXPOSED = FundingLib.MAKER_EXPOSURE_BLOCKS; // a maker's full exposure window

    uint256 constant POSITION = 100 * AAPL; // $10,000 a side at $100
    uint256 constant DUST = AAPL / 10; // $9.70 at $97: above MIN_ORDER_AMOUNT, tiny against the OI floor

    // ---- aaplPair helpers (IntegrationBase's are hardwired to the continuous BTC pair) ----

    function _depositAapl(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev An AAPL update at `priceUsd`, stamped now.
    function _aaplPu(uint256 priceUsd) internal view returns (bytes[] memory) {
        return _priceUpdateFor(AAPL_USD_FEED_ID, priceUsd, uint64(vm.getBlockTimestamp()));
    }

    /// @dev Push `priceUsd` into Pyth's cache and store it as the pair's price, stamped now.
    function _storeAapl(uint256 priceUsd) internal {
        bytes[] memory pu = _aaplPu(priceUsd);
        vm.deal(address(this), 1 ether);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(pu)}(pu);
        aaplPair.refreshPrice(new bytes[](0));
    }

    /// @dev Rest or cross a Limit order on the AAPL pair. An empty `pu` runs it against whatever
    ///      the Pyth cache holds: the fresh path while the cache is inside MAX_PRICE_STALENESS,
    ///      the stale fallback once it is older.
    function _placeAapl(address user, bool isLong, uint256 size, uint256 limitPrice, bytes[] memory pu)
        internal
        returns (uint256)
    {
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Limit;
        s.isLong = isLong;
        s.size = size;
        s.limitPrice = limitPrice;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        vm.prank(user);
        aaplPair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        return _lastCreatedOrderId(aaplPair);
    }

    function _lastMarkUpdateTs() internal view returns (uint256) {
        return aaplPair.auxState().lastMarkUpdateTs;
    }

    function _mark() internal view returns (uint256) {
        return lens.markPrice(address(aaplPair));
    }

    /// @dev The shared setup. Returns the timestamp of the fresh fill that formed the mark; on
    ///      return the stored price is $100 and LAG old, the mark has been untouched for
    ///      QUIET + LAG, and the funding index has not moved since the last store.
    function _quietPairWithAgedPrice() internal returns (uint256 markFormedTs) {
        _depositAapl(alice, 20_000 * BAZAAR_SCALE);
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);

        // A fresh fill forms the mark: the cache was stored this second, so an empty update still
        // runs both orders on the fresh path. Bob's ask rests a dollar under the index for a full
        // window before Alice lifts it, so the print enters at full weight; its $9,900 dwarfs the
        // $200 floor its own open interest sets, and the single-call cap admits a quarter of that
        // floor, so the mark moves a quarter of the way to the print.
        _storeAapl(100);
        markFormedTs = vm.getBlockTimestamp();
        _placeAapl(bob, false, POSITION, 99 * BAZAAR_SCALE, new bytes[](0));
        _roll(EXPOSED);
        _placeAapl(alice, true, POSITION, 99 * BAZAAR_SCALE, new bytes[](0));
        assertEq(_lastMarkUpdateTs(), markFormedTs, "setup: the fresh fill stamped the mark");
        assertEq(_mark(), 9_975 * BAZAAR_SCALE / 100, "setup: the mark moved a quarter of the way to the print");

        // An hour of quiet: the mark fades onto the index. A keeper's store then charges the fade
        // that fell inside its window; a second store a minute on finds nothing left to charge,
        // since the line has run out.
        vm.warp(vm.getBlockTimestamp() + QUIET);
        _storeAapl(100);
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        int256 fundingBefore = aaplPair.currentFundingIndex();
        _storeAapl(100);
        assertEq(aaplPair.currentFundingIndex(), fundingBefore, "setup: a spent mark accrues no funding");

        // Ten minutes later the cache is stale; nothing has been stored since.
        vm.warp(vm.getBlockTimestamp() + LAG);
    }

    /// @notice A dust fill on the stale fallback, printed at $97 while the stored price is $100,
    ///         touches neither the mark nor its clock. The store that follows brings $98: the print
    ///         sits about 1% under it, yet measured against the stale $100 it would read as a 3%
    ///         discount dated as freshly traded, and the store would charge shorts ten minutes of
    ///         funding on the index's own fall as well. With the mark untouched, the store accrues
    ///         nothing.
    function test_staleFill_leavesMarkAndClockAlone_nextStoreAccruesNoFunding() public {
        uint256 markFormedTs = _quietPairWithAgedPrice();

        // Bob rests a dust ask at $97 against a fresh $100 tick, so it carries the 3% it stood
        // under the index. The tick then ages for the refresh-bounty cadence with nothing stored,
        // and a window later Alice lifts the ask against the stale fallback ($97 is inside the 10%
        // stale band around $100). Lifted against a fresh index, the print would count in full.
        uint256 askId = _placeAapl(bob, false, DUST, 97 * BAZAAR_SCALE, _aaplPu(100));
        assertEq(OrderView.order(aaplPair, askId).restedPremiumPpm, 30_000, "linked fresh: 3% under the index");
        uint256 markBefore = _mark();
        int256 fundingBefore = aaplPair.currentFundingIndex();
        vm.warp(vm.getBlockTimestamp() + LAG);
        _roll(EXPOSED);
        _placeAapl(alice, true, DUST, 97 * BAZAAR_SCALE, new bytes[](0));
        assertEq(OrderView.order(aaplPair, askId).filledSize, DUST, "the stale fill went through");

        assertEq(_lastMarkUpdateTs(), markFormedTs, "the stale fill did not stamp the mark");
        assertEq(_mark(), markBefore, "the stale fill did not move the mark");

        // The next fresh price is $98. The mark, last formed over an hour ago, has decayed onto
        // the index, so the premium is zero.
        _storeAapl(98);
        assertEq(aaplPair.currentFundingIndex(), fundingBefore, "no funding from a fill the mark never saw");
    }

    /// @notice The same fill carrying a fresh price enters the mark: the stored price is this
    ///         second's, so the gate admits the print and the clock is stamped.
    function test_freshFill_sameMoment_entersTheMark() public {
        _quietPairWithAgedPrice();

        // Bob's ask rests against the fresh $100 tick, which the pair stores before linking it,
        // and stands for a window; Alice's bid runs against the same tick.
        bytes[] memory pu = _aaplPu(100);
        _placeAapl(bob, false, DUST, 97 * BAZAAR_SCALE, pu);
        _roll(EXPOSED);
        _placeAapl(alice, true, DUST, 97 * BAZAAR_SCALE, pu);

        assertEq(_lastMarkUpdateTs(), vm.getBlockTimestamp(), "a fresh-path fill stamps the mark");
    }

    // ---- the far-side premium is stamped only against a fresh index ----

    function _amendAapl(address user, uint256 orderId, uint256 price, uint256 size, bytes[] memory pu) internal {
        uint256[] memory words = new uint256[](3);
        words[0] = orderId;
        words[1] = price;
        words[2] = size;
        vm.prank(user);
        aaplPair.amendOrders(words, pu, 0, 0, 0, "", "");
    }

    function _stamp(uint256 orderId) internal view returns (uint256) {
        return OrderView.order(aaplPair, orderId).restedPremiumPpm;
    }

    /// @notice An ask that rests against the stale fallback carries no far-side premium, so a
    ///         fresh fill against it a window later leaves the mark alone. Measured against the
    ///         stored $100 from ten minutes earlier it would read 3% under the index, but the
    ///         live price could have been anywhere: it was not on offer at that distance.
    function test_staleLink_stampsNothing_freshFillLeavesTheMarkAlone() public {
        uint256 markFormedTs = _quietPairWithAgedPrice();

        uint256 askId = _placeAapl(bob, false, DUST, 97 * BAZAAR_SCALE, new bytes[](0));
        assertEq(_stamp(askId), 0, "linked on the stale fallback: no stamp");
        _roll(EXPOSED);
        _placeAapl(alice, true, DUST, 97 * BAZAAR_SCALE, _aaplPu(100));
        assertEq(OrderView.order(aaplPair, askId).filledSize, DUST, "the fresh fill went through");
        assertEq(_lastMarkUpdateTs(), markFormedTs, "a fill against a stale-linked ask left the mark alone");
    }

    /// @notice An amendment that relinks on the stale fallback re-measures against no index: the
    ///         ask loses the stamp it linked with against a fresh tick, and a fresh fill against
    ///         it leaves the mark alone.
    function test_staleAmend_relinksWithNoStamp() public {
        uint256 markFormedTs = _quietPairWithAgedPrice();

        uint256 askId = _placeAapl(bob, false, 10 * AAPL, 97 * BAZAAR_SCALE, _aaplPu(100));
        assertEq(_stamp(askId), 30_000, "linked against a fresh tick: 3% under it");

        // Past MAX_PRICE_STALENESS with no update attached, the reprice runs on the stale fallback.
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.MAX_PRICE_STALENESS + 1);
        _amendAapl(bob, askId, 96 * BAZAAR_SCALE, 10 * AAPL, new bytes[](0));
        assertEq(_stamp(askId), 0, "relinked on the stale fallback: no stamp");

        _roll(EXPOSED);
        _placeAapl(alice, true, AAPL, 96 * BAZAAR_SCALE, _aaplPu(100));
        assertEq(OrderView.order(aaplPair, askId).filledSize, AAPL, "the fresh fill went through");
        assertEq(_lastMarkUpdateTs(), markFormedTs, "a fill against a stale-relinked ask left the mark alone");
    }
}
