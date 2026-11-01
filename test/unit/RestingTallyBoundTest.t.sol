// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";

/// @notice One account's active-order set and its tally, driven through the same library
///         functions the pair's gates use. Fills, expiry and arming leave the tally alone, as
///         the matching engine does; creation, amendment and cancellation update it.
contract TallyHarness {
    using EnumerableSet for EnumerableSet.UintSet;

    uint64 public constant CURRENT_BLOCK = 1_000;

    mapping(uint256 => BazaarTypes.Order) internal orders;
    EnumerableSet.UintSet internal set;
    BazaarTypes.RestingTally public tally;
    uint256 public nextId = 1;

    struct LiveSums {
        uint256 bidSize;
        uint256 askSize;
        uint256 bidLimitNotional;
        uint256 askLimitNotional;
        uint256 highestBid;
        uint256 lowestAsk;
        uint256 stops;
        uint256 liveBids;
        uint256 liveAsks;
    }

    function add(bool isLong, bool waitingStop, uint128 size, uint128 limit, uint128 trigger)
        external
        returns (uint256 id)
    {
        id = nextId++;
        BazaarTypes.Order storage o = orders[id];
        o.creator = address(this);
        o.orderType = waitingStop ? BazaarTypes.OrderType.StopLimit : BazaarTypes.OrderType.Limit;
        o.isLong = isLong;
        o.tif = BazaarTypes.TimeInForce.GTC;
        o.inBook = !waitingStop;
        o.size = size;
        o.limitPrice = limit;
        o.triggerPrice = trigger;
        o.expiryBlock = type(uint64).max;
        set.add(id);
        CollateralLib._tallyAdd(tally, isLong, waitingStop, size, limit);
    }

    /// @dev A fill the matching engine books: the tally is not told. A full fill leaves the set.
    function fill(uint256 id, uint128 amount) external {
        BazaarTypes.Order storage o = orders[id];
        uint128 remaining = o.size - o.filledSize;
        if (amount > remaining) amount = remaining;
        o.filledSize += amount;
        if (o.filledSize == o.size) {
            o.filledBlock = CURRENT_BLOCK;
            set.remove(id);
        }
    }

    function expire(uint256 id) external {
        orders[id].expiryBlock = CURRENT_BLOCK - 1;
    }

    /// @dev A keeper arming a waiting StopLimit: it rests as a Limit; the tally is not told.
    function arm(uint256 id) external {
        orders[id].inBook = true;
    }

    function cancel(uint256 id) external {
        BazaarTypes.Order storage o = orders[id];
        bool waitingStop = o.orderType == BazaarTypes.OrderType.StopLimit && !o.inBook;
        o.canceledBlock = CURRENT_BLOCK;
        set.remove(id);
        CollateralLib._tallySub(tally, o.isLong, waitingStop, o.size - o.filledSize, o.limitPrice);
    }

    /// @dev The pair refuses a size at or below what has filled; the harness clamps instead.
    function amend(uint256 id, uint128 newLimit, uint128 newSize) external {
        BazaarTypes.Order storage o = orders[id];
        uint128 filled = o.filledSize;
        if (newSize <= filled) newSize = filled + 1e15;
        CollateralLib._tallySub(tally, o.isLong, false, o.size - filled, o.limitPrice);
        o.limitPrice = newLimit;
        o.size = newSize;
        CollateralLib._tallyAdd(tally, o.isLong, false, newSize - filled, newLimit);
    }

    function rawSub(bool isLong, bool waitingStop, uint256 remaining, uint256 limit) external {
        CollateralLib._tallySub(tally, isLong, waitingStop, remaining, limit);
    }

    function sweep(uint256 mark) external returns (uint256, uint256, uint256) {
        return CollateralLib._sweepRestingReserve(set, orders, tally, CURRENT_BLOCK, mark);
    }

    function bound(uint256 mark) external view returns (bool, uint256, uint256, uint256) {
        return CollateralLib._restingBound(tally, mark);
    }

    /// @dev What the sweep would report, without writing the tally.
    function exact(uint256 mark) external view returns (uint256 longExposure, uint256 shortExposure, uint256 debit) {
        uint256 len = set.length();
        for (uint256 i; i < len; ++i) {
            BazaarTypes.Order storage o = orders[set.at(i)];
            if (o.canceledBlock != 0 || o.filledBlock != 0 || CURRENT_BLOCK > o.expiryBlock) continue;
            (uint256 notional, uint256 d) = CollateralLib._orderReserve(o, o.size - o.filledSize, mark);
            if (o.isLong) longExposure += notional;
            else shortExposure += notional;
            debit += d;
        }
    }

    function liveSums() external view returns (LiveSums memory s) {
        uint256 len = set.length();
        for (uint256 i; i < len; ++i) {
            BazaarTypes.Order storage o = orders[set.at(i)];
            if (o.canceledBlock != 0 || o.filledBlock != 0 || CURRENT_BLOCK > o.expiryBlock) continue;
            uint256 remaining = o.size - o.filledSize;
            uint256 limitNotional = Math.mulDiv(remaining, o.limitPrice, BazaarTypes.BAZAAR_SCALE);
            if (o.isLong) {
                s.bidSize += remaining;
                s.bidLimitNotional += limitNotional;
                if (o.limitPrice > s.highestBid) s.highestBid = o.limitPrice;
                ++s.liveBids;
            } else {
                s.askSize += remaining;
                s.askLimitNotional += limitNotional;
                if (s.lowestAsk == 0 || o.limitPrice < s.lowestAsk) s.lowestAsk = o.limitPrice;
                ++s.liveAsks;
            }
            if (!o.inBook && o.orderType == BazaarTypes.OrderType.StopLimit) ++s.stops;
        }
    }

    function isLive(uint256 id) external view returns (bool) {
        BazaarTypes.Order storage o = orders[id];
        return set.contains(id) && o.canceledBlock == 0 && o.filledBlock == 0 && CURRENT_BLOCK <= o.expiryBlock;
    }

    function isWaitingStop(uint256 id) external view returns (bool) {
        BazaarTypes.Order storage o = orders[id];
        return o.orderType == BazaarTypes.OrderType.StopLimit && !o.inBook;
    }
}

/// @title RestingTallyBoundTest
/// @notice The resting-order tally never understates the live set, and the bound it yields
///         never falls below what the exact sweep reports, through any sequence of creations,
///         fills, expiries, cancels, amendments, armings and sweeps, at any mark.
contract RestingTallyBoundTest is Test {
    uint256 constant SCALE = 1e18;
    uint256 constant MARK = 50_000e18;
    uint32 constant INVALID = type(uint32).max;

    TallyHarness h;

    function setUp() public {
        h = new TallyHarness();
    }

    function _rand(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// @dev A limit between half and one-and-a-half times the mark, on a $1 grid.
    function _limit(uint256 r) internal pure returns (uint128) {
        return uint128((25_000 + (r % 50_001)) * SCALE);
    }

    function _size(uint256 r) internal pure returns (uint128) {
        return uint128(1e15 + (r % 5e18));
    }

    function _assertTallyCoversSet() internal view {
        TallyHarness.LiveSums memory s = h.liveSums();
        (
            uint96 bidSize,
            uint96 askSize,
            uint32 stopCount,
            uint128 bidLimitNotional,
            uint128 askLimitNotional,
            uint128 highestBid,
            uint128 lowestAsk
        ) = h.tally();
        assertTrue(bidSize == type(uint96).max || bidSize >= s.bidSize, "bid size understated");
        assertTrue(askSize == type(uint96).max || askSize >= s.askSize, "ask size understated");
        assertTrue(
            bidLimitNotional == type(uint128).max || bidLimitNotional >= s.bidLimitNotional, "bid notional understated"
        );
        assertTrue(
            askLimitNotional == type(uint128).max || askLimitNotional >= s.askLimitNotional, "ask notional understated"
        );
        if (s.liveBids > 0) assertGe(highestBid, s.highestBid, "a live bid above the recorded highest");
        if (s.liveAsks > 0) assertLe(lowestAsk, s.lowestAsk, "a live ask below the recorded lowest");
        if (stopCount != INVALID) assertGe(stopCount, s.stops, "waiting stops understated");
    }

    function _assertBoundCoversExact(uint256 mark) internal view {
        (bool bounded, uint256 bl, uint256 bs, uint256 bd) = h.bound(mark);
        if (!bounded) return;
        (uint256 el, uint256 es, uint256 ed) = h.exact(mark);
        assertGe(bl, el, "long exposure bound below the sweep");
        assertGe(bs, es, "short exposure bound below the sweep");
        assertGe(bd, ed, "fill debit bound below the sweep");
    }

    /// @notice Random scripts of every operation the tally sees, checked after each step at the
    ///         mark and at two others.
    function testFuzz_tallyAndBoundNeverUnderstate(uint256 seed) public {
        uint256[] memory ids = new uint256[](0);
        for (uint256 step; step < 40; ++step) {
            uint256 r = _rand(seed, step);
            uint256 op = r % 100;
            if (op < 35 || ids.length == 0) {
                bool isLong = (r >> 8) % 2 == 0;
                bool waitingStop = (r >> 16) % 13 == 0;
                uint128 limit = _limit(r >> 24);
                uint128 trigger = waitingStop ? _limit(r >> 64) : 0;
                uint256 id = h.add(isLong, waitingStop, _size(r >> 96), limit, trigger);
                ids = _push(ids, id);
            } else {
                uint256 id = ids[(r >> 8) % ids.length];
                if (!h.isLive(id)) {
                    if (op < 50) h.sweep(MARK);
                    continue;
                }
                if (op < 55) {
                    h.fill(id, uint128((r >> 32) % 6e18));
                } else if (op < 65) {
                    h.cancel(id);
                } else if (op < 78) {
                    if (!h.isWaitingStop(id)) h.amend(id, _limit(r >> 40), _size(r >> 80) + 6e18);
                } else if (op < 84) {
                    h.expire(id);
                } else if (op < 90) {
                    if (h.isWaitingStop(id)) h.arm(id);
                } else {
                    h.sweep(_limit(r >> 48));
                }
            }
            _assertTallyCoversSet();
            _assertBoundCoversExact(MARK);
            _assertBoundCoversExact(_limit(r >> 128));
            _assertBoundCoversExact(_limit(r >> 160));
        }
    }

    /// @notice Right after a sweep, with no waiting stop, every bid at or below the mark and every
    ///         ask at or above it, the bound is the sweep's figures to within the slack and the
    ///         fee rate it assumes.
    function testFuzz_boundIsTightInsideTheSpread(uint256 seed) public {
        uint256 bidNotional;
        uint256 askNotional;
        for (uint256 i; i < 12; ++i) {
            uint256 r = _rand(seed, i);
            bool isLong = r % 2 == 0;
            uint128 size = _size(r >> 8);
            uint128 limit = isLong ? uint128(MARK - (r >> 64) % 10_000e18) : uint128(MARK + (r >> 64) % 10_000e18);
            h.add(isLong, false, size, limit, 0);
            uint256 n = Math.mulDiv(size, limit, SCALE);
            if (isLong) bidNotional += n;
            else askNotional += n;
        }
        h.sweep(MARK);
        (bool bounded, uint256 bl, uint256 bs, uint256 bd) = h.bound(MARK);
        (uint256 el, uint256 es, uint256 ed) = h.exact(MARK);
        assertTrue(bounded, "bounded");
        assertEq(bl, el, "bids are valued at the mark on both paths");
        assertEq(bs, es + BazaarTypes.RESTING_BOUND_SLACK, "asks at or above the mark reserve their limit notional");
        // The bound charges the integrator rate on every order; these carry none.
        uint256 feeGap =
            Math.mulDiv(bidNotional + askNotional, BazaarTypes.MAKER_INTEGRATOR_FEE_EBP, BazaarTypes.EBP_SCALE);
        assertGe(bd, ed, "debit bound");
        assertLe(bd - ed, BazaarTypes.RESTING_BOUND_SLACK + feeGap + 12, "debit bound no looser than its slack");
    }

    /// @notice A waiting StopLimit keeps the gates on the exact path, through its arming, until
    ///         a sweep rewrites the count.
    function test_waitingStopForcesExactPath_untilSwept() public {
        uint256 id = h.add(true, true, 1e18, 52_500e18, 52_000e18);
        (bool bounded,,,) = h.bound(MARK);
        assertFalse(bounded, "a waiting stop cannot be bounded");
        h.arm(id);
        (bounded,,,) = h.bound(MARK);
        assertFalse(bounded, "arming is not reported to the tally");
        h.sweep(MARK);
        (,, uint32 stops,,,,) = h.tally();
        assertEq(stops, 0, "the sweep counts no waiting stop");
        (bounded,,,) = h.bound(MARK);
        assertTrue(bounded, "an armed stop is a bid the tally bounds");
        _assertBoundCoversExact(MARK);
    }

    /// @notice A subtraction the tally cannot cover marks it invalid rather than understating,
    ///         and the next sweep restores it.
    function test_underflowMarksInvalid_sweepRestores() public {
        h.add(true, false, 1e18, 49_000e18, 0);
        h.rawSub(true, false, 2e18, 49_000e18);
        (uint96 bidSize,, uint32 stops,,,,) = h.tally();
        assertEq(stops, INVALID, "marked invalid");
        assertEq(bidSize, 1e18, "nothing was written");
        (bool bounded,,,) = h.bound(MARK);
        assertFalse(bounded, "an invalid tally is not used");
        h.sweep(MARK);
        (bidSize,, stops,,,,) = h.tally();
        assertEq(stops, 0, "the sweep clears the marker");
        assertEq(bidSize, 1e18, "the sweep rewrites the set");
        (bounded,,,) = h.bound(MARK);
        assertTrue(bounded, "bounded again");
    }

    /// @notice A side whose size overflows its field is pinned at the maximum, which the bound
    ///         refuses to use, and a sweep over the same set pins it again.
    function test_saturationIsNotABound() public {
        h.add(false, false, type(uint128).max, 51_000e18, 0);
        (, uint96 askSize,,,,,) = h.tally();
        assertEq(askSize, type(uint96).max, "pinned");
        (bool bounded,,,) = h.bound(MARK);
        assertFalse(bounded, "a pinned field is not a bound");
        h.sweep(MARK);
        (, askSize,,,,,) = h.tally();
        assertEq(askSize, type(uint96).max, "still pinned after the sweep");
        (bounded,,,) = h.bound(MARK);
        assertFalse(bounded, "still not a bound");
        h.cancel(1);
        (, askSize,,,,,) = h.tally();
        assertEq(askSize, type(uint96).max, "a pinned field stays pinned through a subtraction");
    }

    /// @notice An empty tally bounds an empty set exactly, so an account with nothing resting
    ///         pays no sweep and no slack.
    function test_emptyTallyBoundsExactly() public view {
        (bool bounded, uint256 l, uint256 s, uint256 d) = h.bound(MARK);
        assertTrue(bounded);
        assertEq(l + s + d, 0, "zero reservation");
    }

    function _push(uint256[] memory a, uint256 v) internal pure returns (uint256[] memory out) {
        out = new uint256[](a.length + 1);
        for (uint256 i; i < a.length; ++i) {
            out[i] = a[i];
        }
        out[a.length] = v;
    }
}
