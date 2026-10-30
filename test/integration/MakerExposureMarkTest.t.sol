// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";
import {OrderView} from "../OrderView.sol";

/// @title MakerExposureMarkTest
/// @notice The mark price is built from fills against standing offers on the far side of the
///         oracle — a bid above it or an ask below it — weighted by how long the offer stood
///         there, and counted at no more premium than the offer stood at when it linked into the
///         book. A fill against a maker on the near side, against one placed in the same block,
///         or against one that linked on the near side and was reached only by the oracle's move,
///         neither moves the mark nor stamps its clock nor feeds its rolling volume. The expected
///         mark after a counting fill is recomputed here through FundingLib's own update, fed the
///         fill's notional at its print price and size scaled by age / MAKER_EXPOSURE_BLOCKS and
///         the open interest the pair holds once the fill has settled.
contract MakerExposureMarkTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BTC = 1e18;
    uint256 constant ORACLE = 50_000 * BAZAAR_SCALE;
    uint256 constant BASE = BTC / 2; // the open interest every test starts from
    // $25 at the oracle: above the order minimum, and under the $125 one call may add against the
    // $500 floor BASE sets, so a full-weight print enters whole.
    uint256 constant PRINT = BTC / 2000;
    uint256 constant W = FundingLib.MAKER_EXPOSURE_BLOCKS;

    /// @dev A copy of the pair's open-interest aggregates, so FundingLib.updateMarkPrice can size
    ///      the floor from storage the way the pair's call does.
    BazaarTypes.Vault internal vaultMirror;

    struct MarkSnap {
        uint256 mark;
        uint256 ts;
        uint256 vol;
    }

    // ---------------------------- helpers ----------------------------

    function _snap() internal view returns (MarkSnap memory s) {
        s.mark = lens.markPrice(address(pair));
        BazaarTypes.AuxState memory a = pair.auxState();
        s.ts = a.lastMarkUpdateTs;
        s.vol = a.rollingVolume;
    }

    /// @dev The open interest the mark's volume floor is scaled by: the larger side, counting the
    ///      vault's inherited inventory on its side (RiskParamsLib.openInterestSize).
    function _oiSize() internal view returns (uint256) {
        (uint256 l, uint256 s,,,,, uint256 pend,,,, bool pendLong,,,,,,) = pair.pairVault();
        if (pendLong) l += pend;
        else s += pend;
        return l > s ? l : s;
    }

    /// @dev The line FundingLib's update leaves from `before` for one fill of `size` at `price`
    ///      entering at `weight` / MAKER_EXPOSURE_BLOCKS, judged against `index`, with the floor
    ///      scaled by the pair's open interest as it stands now (after the fill). `before` must
    ///      be an unformed mark: the lens gives the line's reading rather than its stored values,
    ///      and only before any mark has formed are those known from it.
    function _predict(MarkSnap memory before, uint256 size, uint256 price, uint256 weight, uint256 index)
        internal
        returns (FundingLib.MarkState memory)
    {
        assertEq(before.ts, 0, "fixture: predicted from an unformed mark");
        (uint256 l, uint256 s,,,,, uint256 pend,,,, bool pendLong,,,,,,) = pair.pairVault();
        vaultMirror.totalLongOI = l;
        vaultMirror.totalShortOI = s;
        vaultMirror.pendingLiqSize = pend;
        vaultMirror.pendingLiqIsLong = pendLong;
        uint256 notional = size * price / BAZAAR_SCALE;
        return FundingLib.updateMarkPrice(
            FundingLib.MarkState({premiumNotional: 0, lastMarkUpdateTs: 0, rollingVolume: before.vol}),
            notional * weight / W,
            size * weight / W,
            index,
            vaultMirror
        );
    }

    /// @dev The mark that line reads in the block of the fill, carried on `index`, over the floor
    ///      the pair's open interest sets.
    function _expected(MarkSnap memory before, uint256 size, uint256 price, uint256 weight, uint256 index)
        internal
        returns (uint256)
    {
        FundingLib.MarkState memory s = _predict(before, size, price, weight, index);
        return FundingLib.currentMark(
            s.premiumNotional, s.rollingVolume, s.lastMarkUpdateTs, FundingLib.floorVolumeOf(_oiSize(), index), index
        );
    }

    function _assertUntouched(MarkSnap memory before, string memory why) internal view {
        MarkSnap memory now_ = _snap();
        assertEq(now_.mark, before.mark, string.concat(why, ": mark"));
        assertEq(now_.ts, before.ts, string.concat(why, ": clock"));
        assertEq(now_.vol, before.vol, string.concat(why, ": rolling volume"));
    }

    function _amend(address user, uint256 orderId, uint256 price, uint256 size) internal {
        _amendWith(user, orderId, price, size, _freshPrice());
    }

    /// @dev Amend while the oracle prints `oraclePriceUsd` (warps +4 s so the update is strictly
    ///      newer than the stored price).
    function _amendAt(address user, uint256 orderId, uint256 price, uint256 size, uint256 oraclePriceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + 4);
        _amendWith(user, orderId, price, size, _priceUpdate(oraclePriceUsd, uint64(vm.getBlockTimestamp())));
    }

    function _amendWith(address user, uint256 orderId, uint256 price, uint256 size, bytes[] memory pu) internal {
        uint256[] memory words = new uint256[](3);
        words[0] = orderId;
        words[1] = price;
        words[2] = size;
        vm.prank(user);
        pair.amendOrders(words, pu, 0, 0, 0, "", "");
    }

    function _stamp(uint256 orderId) internal view returns (uint256) {
        return OrderView.order(pair, orderId).restedPremiumPpm;
    }

    /// @dev Stage `size` of long inventory in the vault at a $50k entry and a $48k bankruptcy
    ///      price (Vault depths as _stageHeldInventory documents them).
    function _stageLongInventory(uint256 size) internal {
        _stdstore.target(address(pair)).sig("pairVault()").depth(6).checked_write(size);
        _stdstore.target(address(pair)).sig("pairVault()").depth(7).checked_write(size * 50_000);
        _stdstore.target(address(pair)).sig("pairVault()").depth(8).checked_write(size * 48_000);
        _stdstore.target(address(pair)).sig("pairVault()").depth(10).checked_write(true);
        _stdstore.target(address(pair)).sig("pairVault()").depth(13).checked_write(size * 2_000);
    }

    /// @dev Every test starts from BASE of open interest opened by a print exactly at the oracle,
    ///      which is a near-side print: the mark has never been formed when a test begins.
    function setUp() public override {
        super.setUp();
        _deposit(alice, 100_000 * BAZAAR_SCALE);
        _deposit(bob, 100_000 * BAZAAR_SCALE);
        _deposit(carol, 100_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, BASE, ORACLE);
        _roll(W);
        _placeLimit(bob, false, BASE, ORACLE);
        assertEq(_posSize(alice), BASE, "setup: alice long");
        assertEq(_posSize(bob), BASE, "setup: bob short");
    }

    // ---------------------------- near side ----------------------------

    /// @notice A print at the oracle itself is not a far-side print: the setup fill, against a
    ///         bid resting at the oracle for a full window, formed no mark.
    function test_printAtTheOracle_formsNoMark() public view {
        MarkSnap memory s = _snap();
        assertEq(s.mark, 0, "no mark formed");
        assertEq(s.ts, 0, "clock never stamped");
        assertEq(s.vol, 0, "no rolling volume");
    }

    /// @notice An ask above the oracle can rest at no risk — nobody wants to buy above fair — so
    ///         lifting it proves nothing, however long it stood. The mark stays untouched.
    function test_nearSide_askAboveOracleLifted_leavesMarkAlone_evenAged() public {
        _placeLimit(bob, false, PRINT, 51_000 * BAZAAR_SCALE);
        _roll(W + 60);
        MarkSnap memory before = _snap();
        _placeLimit(alice, true, PRINT, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), BASE + PRINT, "the fill went through at the ask");
        _assertUntouched(before, "ask above the oracle lifted");
    }

    /// @notice The mirror image: a bid below the oracle is a safe quote, and a seller hitting it
    ///         shows no discount the two could not have arranged between themselves.
    function test_nearSide_bidBelowOracleHit_leavesMarkAlone_evenAged() public {
        _placeLimit(alice, true, PRINT, 49_000 * BAZAAR_SCALE);
        _roll(W + 60);
        MarkSnap memory before = _snap();
        _placeLimit(bob, false, PRINT, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(bob), BASE + PRINT, "the fill went through at the bid");
        _assertUntouched(before, "bid below the oracle hit");
    }

    // ---------------------------- far side, by exposure ----------------------------

    /// @notice A bid above the oracle taken in the block it was placed was never on offer to
    ///         anyone else: zero weight, nothing moves.
    function test_farSide_sameBlock_noWeight() public {
        _placeLimit(alice, true, PRINT, 51_000 * BAZAAR_SCALE);
        MarkSnap memory before = _snap();
        _placeLimit(bob, false, PRINT, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(bob), BASE + PRINT, "the fill went through");
        _assertUntouched(before, "far-side bid taken in its own block");
    }

    /// @notice A bid above the oracle that stood for the whole window enters at full weight: the
    ///         mark lands exactly where the EMA puts a print of the fill's full notional.
    function test_farSide_fullyExposed_fullWeight() public {
        _placeLimit(alice, true, PRINT, 51_000 * BAZAAR_SCALE);
        _roll(W);
        MarkSnap memory before = _snap();
        _placeLimit(bob, false, PRINT, 51_000 * BAZAAR_SCALE);

        uint256 expected = _expected(before, PRINT, 51_000 * BAZAAR_SCALE, W, ORACLE);
        assertGt(expected, ORACLE, "sanity: the print pulls the mark above the index");
        assertEq(lens.markPrice(address(pair)), expected, "full-weight print");
        assertEq(pair.auxState().lastMarkUpdateTs, vm.getBlockTimestamp(), "clock stamped");
        assertEq(pair.auxState().rollingVolume, PRINT * 51_000, "its whole notional counts as volume");
    }

    /// @notice Half a window of exposure, half the weight: the mark moves less than a full-weight
    ///         print would move it, by exactly the EMA's reading of half the notional.
    function test_farSide_halfExposed_halfWeight() public {
        _placeLimit(alice, true, PRINT, 51_000 * BAZAAR_SCALE);
        _roll(W / 2);
        MarkSnap memory before = _snap();
        _placeLimit(bob, false, PRINT, 51_000 * BAZAAR_SCALE);

        uint256 expectedHalf = _expected(before, PRINT, 51_000 * BAZAAR_SCALE, W / 2, ORACLE);
        uint256 expectedFull = _expected(before, PRINT, 51_000 * BAZAAR_SCALE, W, ORACLE);
        assertGt(expectedHalf, ORACLE, "sanity: still moves the mark");
        assertLt(expectedHalf, expectedFull, "sanity: the floor keeps half the notional below full weight");
        assertEq(lens.markPrice(address(pair)), expectedHalf, "half-weight print");
        assertEq(pair.auxState().rollingVolume, PRINT * 51_000 / 2, "half its notional counts as volume");
    }

    /// @notice Standing longer than the window buys nothing more: the weight caps at full.
    function test_farSide_exposurePastTheWindow_capsAtFull() public {
        _placeLimit(alice, true, PRINT, 51_000 * BAZAAR_SCALE);
        _roll(10 * W);
        MarkSnap memory before = _snap();
        _placeLimit(bob, false, PRINT, 51_000 * BAZAAR_SCALE);
        assertEq(
            lens.markPrice(address(pair)),
            _expected(before, PRINT, 51_000 * BAZAAR_SCALE, W, ORACLE),
            "capped at the full-weight print"
        );
    }

    /// @notice The downward direction: an ask below the oracle is the exposed quote, and lifting
    ///         it after a full window pulls the mark under the index.
    function test_farSide_askBelowOracleLifted_movesMarkDown() public {
        _placeLimit(bob, false, PRINT, 49_000 * BAZAAR_SCALE);
        _roll(W);
        MarkSnap memory before = _snap();
        _placeLimit(alice, true, PRINT, 49_000 * BAZAAR_SCALE);

        uint256 expected = _expected(before, PRINT, 49_000 * BAZAAR_SCALE, W, ORACLE);
        assertLt(expected, ORACLE, "sanity: the print pulls the mark below the index");
        assertEq(lens.markPrice(address(pair)), expected, "full-weight discount print");
    }

    // ---------------------------- the stamp ----------------------------

    /// @notice Repricing an order restarts its exposure: an aged bid moved to a new price and
    ///         taken in the same block carries no weight, and the stamp reads the amending block.
    function test_amend_repriceRestartsExposure() public {
        uint256 id = _placeLimit(alice, true, PRINT, 50_500 * BAZAAR_SCALE);
        uint32 restedAt = OrderView.order(pair, id).restedBlock;
        _roll(W + 60);
        _amend(alice, id, 51_000 * BAZAAR_SCALE, PRINT);
        assertEq(OrderView.order(pair, id).restedBlock, uint32(vm.getBlockNumber()), "restamped by the reprice");
        assertGt(OrderView.order(pair, id).restedBlock, restedAt, "later than the original stamp");

        MarkSnap memory before = _snap();
        _placeLimit(bob, false, PRINT, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(bob), BASE + PRINT, "the fill went through at the new price");
        _assertUntouched(before, "repriced bid taken in the amending block");
    }

    /// @notice Growing an order restarts its exposure: the added size has not stood anywhere.
    function test_amend_growRestartsExposure() public {
        uint256 id = _placeLimit(alice, true, PRINT, 51_000 * BAZAAR_SCALE);
        _roll(W + 60);
        _amend(alice, id, 51_000 * BAZAAR_SCALE, 2 * PRINT);
        assertEq(OrderView.order(pair, id).restedBlock, uint32(vm.getBlockNumber()), "restamped by the growth");

        MarkSnap memory before = _snap();
        _placeLimit(bob, false, 2 * PRINT, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(bob), BASE + 2 * PRINT, "the whole grown order filled");
        _assertUntouched(before, "grown bid taken in the amending block");
    }

    /// @notice Shrinking an order keeps its exposure: what remains stood there all along, so a
    ///         fill against it right after the shrink enters at full weight.
    function test_amend_shrinkKeepsExposure() public {
        uint256 id = _placeLimit(alice, true, 2 * PRINT, 51_000 * BAZAAR_SCALE);
        uint32 restedAt = OrderView.order(pair, id).restedBlock;
        _roll(W + 60);
        _amend(alice, id, 51_000 * BAZAAR_SCALE, PRINT);
        assertEq(OrderView.order(pair, id).restedBlock, restedAt, "a shrink keeps the stamp");

        MarkSnap memory before = _snap();
        _placeLimit(bob, false, PRINT, 51_000 * BAZAAR_SCALE);
        assertEq(
            lens.markPrice(address(pair)),
            _expected(before, PRINT, 51_000 * BAZAAR_SCALE, W, ORACLE),
            "full weight: the remaining size was exposed the whole time"
        );
    }

    /// @notice A StopLimit's exposure starts when it arms and rests, not when it was created: an
    ///         order that waited outside the book for a window and then rested is a fresh quote.
    ///         Once it has rested for a window, its remaining size counts in full.
    function test_stopLimit_exposureStartsWhenItArms() public {
        // A buy stop just above the oracle waits outside the book until a fresh tick reaches its
        // trigger, then rests its limit above the new index. Every later fill reads that index:
        // the pair serves a fresh Pyth cache ahead of any update a caller attaches.
        uint256 index = 50_200 * BAZAAR_SCALE;
        uint256 id = _placeStopLimit(alice, true, 2 * PRINT, 50_100 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE);
        uint64 createdAt = uint64(vm.getBlockNumber());
        assertFalse(_inBook(id), "sanity: not yet armed");
        _roll(W + 60);
        assertEq(_executeTriggerAt(id, 50_200), 1, "the stop armed");
        assertTrue(_inBook(id), "and rests as a bid");
        assertEq(OrderView.order(pair, id).restedBlock, uint32(vm.getBlockNumber()), "stamped at arming");
        assertEq(
            _stamp(id),
            FundingLib.restedPremiumOf(true, 51_000 * BAZAAR_SCALE, index),
            "its far-side premium measured against the arming index"
        );
        assertGt(vm.getBlockNumber(), createdAt, "sanity: arming happened well after creation");

        MarkSnap memory before = _snap();
        _placeLimit(bob, false, PRINT, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(bob), BASE + PRINT, "half the stop filled in the arming block");
        _assertUntouched(before, "a stop taken in the block it armed");

        _roll(W);
        before = _snap();
        _placeLimit(carol, false, PRINT, 51_000 * BAZAAR_SCALE);
        assertEq(
            lens.markPrice(address(pair)),
            _expected(before, PRINT, 51_000 * BAZAAR_SCALE, W, index),
            "the remainder, rested for a window, enters at full weight"
        );
    }

    // ---------------------------- the rested premium ----------------------------

    /// @notice A bid that rested its whole window below the oracle, where nobody could take it
    ///         at a profit, counts for nothing when the oracle later prints below it and a second
    ///         account hits it in the transaction that stores the print: the bid was never on
    ///         offer on the far side to anyone else.
    function test_nearSideRest_oracleMovesThrough_countsNothing() public {
        uint256 id = _placeLimit(alice, true, PRINT, 49_900 * BAZAAR_SCALE);
        assertEq(_stamp(id), 0, "linked on the near side");
        _roll(W);
        MarkSnap memory before = _snap();
        _placeLimitAt(carol, false, PRINT, 49_900 * BAZAAR_SCALE, 49_500);
        assertEq(_posSize(carol), PRINT, "carol hit the bid, now above the oracle");
        _assertUntouched(before, "a near-side rest the oracle moved through");
    }

    /// @notice The same with enough near-side bids to carry the volume over the open-interest
    ///         floor, taken in separate same-block calls: still nothing reaches the mark.
    function test_nearSideRest_manyCallsOverTheFloor_countNothing() public {
        uint256 lot = 5 * PRINT; // about a quarter of the floor BASE sets
        uint256 calls = 6;
        for (uint256 i; i < calls; ++i) {
            _placeLimit(alice, true, lot, 49_900 * BAZAAR_SCALE);
        }
        _roll(W);
        MarkSnap memory before = _snap();
        _placeLimitAt(carol, false, lot, 49_900 * BAZAAR_SCALE, 49_500);
        bytes[] memory pu = _priceUpdate(49_500, uint64(vm.getBlockTimestamp()));
        for (uint256 i = 1; i < calls; ++i) {
            vm.prank(carol);
            pair.createOrder(_limitSpec(false, lot, 49_900 * BAZAAR_SCALE), _hintsNone(), pu, 0, 0, 0, "", "");
        }
        assertEq(_posSize(carol), calls * lot, "carol hit every bid");
        _assertUntouched(before, "near-side rests the oracle moved through");
    }

    /// @notice A bid that rested 0.2% over the oracle and is hit after the oracle falls a further
    ///         1% counts at 0.2%: the premium it stood at where anyone could take it, not the one
    ///         the oracle's move handed it.
    function test_farSideRest_oracleMovesFurther_countsOnlyItsStamp() public {
        uint256 bid = 50_100 * BAZAAR_SCALE;
        uint256 id = _placeLimit(alice, true, PRINT, bid);
        assertEq(_stamp(id), 2_000, "stamped 0.2% over the $50k oracle");
        _roll(W);
        MarkSnap memory before = _snap();
        _placeLimitAt(carol, false, PRINT, bid, 49_500);

        uint256 index = 49_500 * BAZAAR_SCALE;
        uint256 counted = FundingLib.printPriceOf(true, bid, _stamp(id), index);
        assertEq(counted, 49_599 * BAZAAR_SCALE, "0.2% over the new index");
        uint256 expected = _expected(before, PRINT, counted, W, index);
        assertEq(lens.markPrice(address(pair)), expected, "the print entered at its stamp");
        assertLt(expected, _expected(before, PRINT, bid, W, index), "below the fill's own 1.2% premium");
        assertEq(pair.auxState().rollingVolume, PRINT * 49_599, "its volume at the counted price");
    }

    /// @notice When the oracle has moved toward the bid instead, the fill's own, smaller premium
    ///         is what counts.
    function test_farSideRest_oracleMovesToward_countsTheFill() public {
        uint256 bid = 51_000 * BAZAAR_SCALE;
        uint256 id = _placeLimit(alice, true, PRINT, bid);
        assertEq(_stamp(id), 20_000, "stamped 2% over the $50k oracle");
        _roll(W);
        MarkSnap memory before = _snap();
        _placeLimitAt(carol, false, PRINT, bid, 50_500);
        assertEq(
            lens.markPrice(address(pair)),
            _expected(before, PRINT, bid, W, 50_500 * BAZAAR_SCALE),
            "the fill's own 0.99% premium"
        );
    }

    /// @notice An ask, mirrored: rested 1% under the oracle and lifted after it rises 2% more, it
    ///         counts its 1% discount.
    function test_farSideRest_askCountsOnlyItsStamp() public {
        uint256 ask = 49_500 * BAZAAR_SCALE;
        uint256 id = _placeLimit(bob, false, PRINT, ask);
        assertEq(_stamp(id), 10_000, "stamped 1% under the $50k oracle");
        _roll(W);
        MarkSnap memory before = _snap();
        _placeLimitAt(alice, true, PRINT, ask, 51_000);
        uint256 index = 51_000 * BAZAAR_SCALE;
        assertEq(
            lens.markPrice(address(pair)),
            _expected(before, PRINT, 50_490 * BAZAAR_SCALE, W, index),
            "1% under the new index"
        );
    }

    /// @notice Repricing re-measures the stamp against the amendment's index: a bid moved from the
    ///         near side to the far side counts once it has stood its window there.
    function test_amend_repriceRestampsAgainstTheAmendIndex() public {
        uint256 id = _placeLimit(alice, true, PRINT, 49_900 * BAZAAR_SCALE);
        assertEq(_stamp(id), 0, "linked on the near side");
        _roll(W);
        _amend(alice, id, 50_100 * BAZAAR_SCALE, PRINT);
        assertEq(_stamp(id), 2_000, "restamped 0.2% over the oracle");
        _roll(W);
        MarkSnap memory before = _snap();
        _placeLimit(bob, false, PRINT, 50_100 * BAZAAR_SCALE);
        assertEq(
            lens.markPrice(address(pair)),
            _expected(before, PRINT, 50_100 * BAZAAR_SCALE, W, ORACLE),
            "counted in full at the stamp it relinked with"
        );
    }

    /// @notice Shrinking relinks nothing, so it re-measures nothing: a bid that rested below the
    ///         oracle and is shrunk after the oracle falls through it keeps its zero stamp, and
    ///         its fills still count for nothing.
    function test_amend_shrinkKeepsTheStamp() public {
        uint256 id = _placeLimit(alice, true, 2 * PRINT, 49_900 * BAZAAR_SCALE);
        _roll(W);
        _amendAt(alice, id, 49_900 * BAZAAR_SCALE, PRINT, 49_500);
        assertEq(_stamp(id), 0, "a shrink keeps the stamp");
        MarkSnap memory before = _snap();
        _placeLimitAt(carol, false, PRINT, 49_900 * BAZAAR_SCALE, 49_500);
        assertEq(_posSize(carol), PRINT, "carol hit the shrunk bid");
        _assertUntouched(before, "a shrunk near-side rest");
    }

    // ---------------------------- composition ----------------------------

    /// @notice One walk through a far-side ask and a near-side ask: only the far-side fill feeds
    ///         the mark, at its own price and size, although both fills settle.
    function test_mixedWalk_onlyFarSideFillsFeedTheMark() public {
        _placeLimit(carol, false, PRINT, 49_500 * BAZAAR_SCALE); // below the oracle: exposed
        _placeLimit(bob, false, PRINT, 50_500 * BAZAAR_SCALE); // above it: free to rest
        _roll(W);
        MarkSnap memory before = _snap();
        _placeLimit(alice, true, 2 * PRINT, 50_500 * BAZAAR_SCALE);
        assertEq(_posSize(alice), BASE + 2 * PRINT, "both asks filled");

        assertEq(
            lens.markPrice(address(pair)),
            _expected(before, PRINT, 49_500 * BAZAAR_SCALE, W, ORACLE),
            "the mark saw only the far-side fill"
        );
        assertEq(pair.auxState().rollingVolume, PRINT * 49_500, "only its notional entered the volume");
    }

    /// @notice Near-side prints add nothing to the rolling volume, so a large one cannot shrink
    ///         the weight the next far-side print gets: the far-side print lands where it would
    ///         have landed on a quiet pair.
    function test_nearSidePrints_feedNoRollingVolume() public {
        // A print at the oracle of 400x the far-side print's size.
        _placeLimit(bob, false, 400 * PRINT, ORACLE);
        _roll(W);
        _placeLimit(alice, true, 400 * PRINT, ORACLE);
        assertEq(_posSize(alice), BASE + 400 * PRINT, "the large near-side print settled");
        assertEq(pair.auxState().rollingVolume, 0, "and left the rolling volume at zero");

        _placeLimit(carol, true, PRINT, 51_000 * BAZAAR_SCALE);
        _roll(W);
        MarkSnap memory before = _snap();
        assertEq(before.vol, 0, "sanity: nothing to dilute with");
        _placeLimit(bob, false, PRINT, 51_000 * BAZAAR_SCALE);
        assertEq(
            lens.markPrice(address(pair)),
            _expected(before, PRINT, 51_000 * BAZAAR_SCALE, W, ORACLE),
            "weighed against the floor alone"
        );
        assertEq(pair.auxState().rollingVolume, PRINT * 51_000, "only the far-side notional is volume");
    }

    // ---------------------------- vault unloads ----------------------------

    /// @notice The vault selling inherited inventory into a bid above the oracle is a fill
    ///         against an exposed quote like any other: aged for a window, it moves the mark.
    function test_unload_intoBidAboveOracle_counts() public {
        _placeLimit(carol, true, PRINT, 50_100 * BAZAAR_SCALE);
        _roll(W);
        _stageLongInventory(PRINT);
        MarkSnap memory before = _snap();
        assertEq(_unloadVault(), PRINT, "the inventory sold into the bid");
        assertEq(
            lens.markPrice(address(pair)),
            _expected(before, PRINT, 50_100 * BAZAAR_SCALE, W, ORACLE),
            "an unload fill against an exposed bid enters the mark"
        );
    }

    /// @notice The vault selling into a bid below the oracle leaves the mark alone: a bid under
    ///         fair value is a safe quote whoever takes it.
    function test_unload_intoBidBelowOracle_doesNotCount() public {
        _placeLimit(carol, true, PRINT, 49_900 * BAZAAR_SCALE);
        _roll(W);
        _stageLongInventory(PRINT);
        MarkSnap memory before = _snap();
        assertEq(_unloadVault(), PRINT, "the inventory sold into the bid");
        _assertUntouched(before, "an unload into a near-side bid");
    }
}
