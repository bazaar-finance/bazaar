// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";

/// @notice Direct unit tests for FundingLib's mark-price EMA internals — the single-update
///         manipulation bound (10% alpha cap), the open-interest weighting floor, the absence of
///         an alpha floor, the exec-price deviation band, decay-to-index — and, on the funding
///         side, the age-cap middle branch and the per-pair-type ceiling/dampener pairings that
///         keep the rate clamp outside the band.
contract FundingLibTest is Test {
    uint256 constant SCALE = 1e18;
    uint256 constant T0 = 1_700_000_000;

    function setUp() public {
        vm.warp(T0);
    }

    function _state(uint256 mark, uint256 ts, uint256 vol) internal pure returns (FundingLib.MarkState memory s) {
        s.markPrice = mark;
        s.lastMarkUpdateTs = ts;
        s.rollingVolume = vol;
    }

    /// @dev updateMarkPrice takes the walk's notional and size and derives the VWAP itself, so the
    ///      tests state a target print price and the notional it implies at a chosen size.
    function _notional(uint256 size, uint256 price) internal pure returns (uint256) {
        return size * price / SCALE;
    }

    // ---------------- mark price ----------------

    /// @notice First fill ever on a pair with no open interest: the mark seeds from the index and a
    ///         volume-dominant fill is capped at the 10% blend — the single-update manipulation bound.
    ///         The print sits inside the deviation band, so only the alpha cap is under test.
    function test_mark_firstFill_dominantFillCappedAt10Percent() public view {
        FundingLib.MarkState memory s = FundingLib.updateMarkPrice(
            _state(0, 0, 0), _notional(1_000 * SCALE, 205 * SCALE), 1_000 * SCALE, 200 * SCALE, 0
        );
        // decayedMark = index (fresh state); alpha clamps to 1000/10000:
        // mark = 205 x 10% + 200 x 90% = 200.5.
        assertEq(s.markPrice, 2005 * SCALE / 10, "dominant fill moves the mark at most 10% toward exec");
        assertEq(s.rollingVolume, 205_000 * SCALE, "fill notional recorded");
        assertEq(s.lastMarkUpdateTs, block.timestamp, "stamped");
    }

    /// @notice A dust fill against deep rolling volume gets ~0 weight: alpha has no lower floor, so
    ///         the mark does not move and a tiny wash trade can't nudge it. An alpha floor would hand
    ///         the dust fill a minimum weight regardless of size and drag the mark off the index.
    function test_mark_dustFill_noAlphaFloorLeavesMarkUnmoved() public view {
        FundingLib.MarkState memory s = FundingLib.updateMarkPrice(
            _state(200 * SCALE, block.timestamp, 10_000_000 * SCALE),
            _notional(1 * SCALE, 205 * SCALE),
            1 * SCALE,
            200 * SCALE,
            0
        );
        // alpha = 205/10_000_205 expressed in bp truncates to 0: mark stays at the (undecayed) 200.
        assertEq(s.markPrice, 200 * SCALE, "dust fill gets ~0 weight, mark unmoved");
        assertEq(s.rollingVolume, 10_000_205 * SCALE, "dust notional still recorded");
    }

    /// @notice The weighting floor is what closes the quiet-pair hole: with zero rolling volume a
    ///         dust print would otherwise supply its own denominator and read as volume-dominant,
    ///         taking the full 10% weight. Open interest of 1,040,000 at $200 is $208M of notional,
    ///         so the floor is $2.08M — against which a single unit printing at $205 is $205 of
    ///         notional, truncates to alpha 0, and does not move the mark at all.
    function test_mark_openInterestFloorKillsDustOnQuietPair() public view {
        FundingLib.MarkState memory s = FundingLib.updateMarkPrice(
            _state(200 * SCALE, block.timestamp, 0),
            _notional(1 * SCALE, 205 * SCALE),
            1 * SCALE,
            200 * SCALE,
            1_040_000 * SCALE
        );
        assertEq(s.markPrice, 200 * SCALE, "dust cannot move the mark against an open-interest floor");
        assertEq(s.rollingVolume, 205 * SCALE, "true traded notional recorded, not the floor");
    }

    /// @notice The floor suppresses noise, not price discovery: $20.5M of fill against the same
    ///         $2.08M floor still saturates alpha and moves the mark the full 10%.
    function test_mark_openInterestFloorLetsRealSizeThrough() public view {
        FundingLib.MarkState memory s = FundingLib.updateMarkPrice(
            _state(200 * SCALE, block.timestamp, 0),
            _notional(100_000 * SCALE, 205 * SCALE),
            100_000 * SCALE,
            200 * SCALE,
            1_040_000 * SCALE
        );
        // mark = 205 x 10% + 200 x 90% = 200.5.
        assertEq(s.markPrice, 2005 * SCALE / 10, "size well past the floor still gets the full 10% weight");
    }

    /// @notice Real rolling volume above the floor governs on its own — the floor is a backstop for
    ///         quiet pairs, not an override. $1B of rolling volume beats the same $2.08M floor, and a
    ///         $20,500 print that the floor alone would have weighted at 97bp gets none.
    function test_mark_rollingVolumeAboveFloorGoverns() public view {
        FundingLib.MarkState memory s = FundingLib.updateMarkPrice(
            _state(200 * SCALE, block.timestamp, 1_000_000_000 * SCALE),
            _notional(100 * SCALE, 205 * SCALE),
            100 * SCALE,
            200 * SCALE,
            1_040_000 * SCALE
        );
        assertEq(s.markPrice, 200 * SCALE, "max(volume, floor) picks the volume leg");
        assertEq(s.rollingVolume, 1_000_020_500 * SCALE, "volume record unaffected by the floor");
    }

    /// @notice An execution print far from the index is clamped to the deviation band before it
    ///         enters the EMA, so a self-crossed wash trade at an arbitrary price can't push the mark
    ///         past the band even on a quiet pair where alpha hits the 10% cap.
    function test_mark_execPriceClampedToDeviationBand() public view {
        // Volume-dominant fill (alpha caps at 10%) printing at 300 vs index 200 (+50%, far past the band).
        FundingLib.MarkState memory s = FundingLib.updateMarkPrice(
            _state(0, 0, 0), _notional(1_000 * SCALE, 300 * SCALE), 1_000 * SCALE, 200 * SCALE, 0
        );
        // Print clamps to 200 x 1.04 = 208; mark = 208 x 10% + 200 x 90% = 200.8 (NOT 210, which is
        // what an unclamped 300 print would give: 300 x 10% + 200 x 90%).
        assertEq(s.markPrice, 2008 * SCALE / 10, "print clamped to the band before the 10% blend");
    }

    /// @notice Each pair type's dampener is derived from its own rate ceiling against the shared
    ///         band, so a mark sitting exactly at the band edge produces exactly that ceiling and
    ///         the clamp is unreachable from strictly inside the band. Pinning both pairings guards
    ///         the invariant that actually matters: declaring band, rate and dampener independently
    ///         leaves a saturated stretch of band where funding stops responding to mark movement.
    ///         The age cap trims each window to 30 minutes, so the accrual is rate x $200 x 0.5h.
    function test_funding_bandEdgeYieldsExactlyTheClamp_bothPairTypes() public {
        uint256 index = 200 * SCALE;
        uint256 edge = index * (10_000 + FundingLib.MAX_MARK_DEVIATION_BP) / 10_000;
        vm.warp(T0 + 1 hours);

        // Session: premium 4% over a dampener of 8 is exactly 0.5%/h. 0.005 x 200 x 0.5 = 0.5.
        (int256 session,) = FundingLib.updateFundingIndex(edge, block.timestamp, 0, T0, index, block.timestamp, false);
        assertEq(session, int256(SCALE / 2), "session band edge accrues exactly its ceiling, no more");

        // Continuous: the same 4% over a dampener of 40 is exactly 0.1%/h. 0.001 x 200 x 0.5 = 0.1.
        (int256 continuous,) = FundingLib.updateFundingIndex(edge, block.timestamp, 0, T0, index, block.timestamp, true);
        assertEq(continuous, int256(SCALE / 10), "continuous band edge accrues exactly its ceiling, no more");

        // A hair inside the band accrues strictly less on both — no saturated dead zone below the edge.
        (int256 sessionInside,) =
            FundingLib.updateFundingIndex(edge - SCALE, block.timestamp, 0, T0, index, block.timestamp, false);
        (int256 continuousInside,) =
            FundingLib.updateFundingIndex(edge - SCALE, block.timestamp, 0, T0, index, block.timestamp, true);
        assertLt(sessionInside, session, "session: inside the band the rate is strictly below the clamp");
        assertLt(continuousInside, continuous, "continuous: inside the band the rate is strictly below the clamp");
    }

    /// @notice The pair types share one band, so the mark may sit equally far from the index on
    ///         either — only the strength of the resulting pull differs, by the ratio of the two
    ///         ceilings. A continuous pair's deeper clamp is what its 24/7 accrual pays for.
    function test_funding_continuousClampIsOneFifthOfSession() public {
        uint256 index = 200 * SCALE;
        vm.warp(T0 + 30 minutes);

        // Mark $180 vs index $200: premium -10%, past the band on both, so both clamp.
        (int256 session,) =
            FundingLib.updateFundingIndex(180 * SCALE, block.timestamp, 0, T0, index, block.timestamp, false);
        (int256 continuous,) =
            FundingLib.updateFundingIndex(180 * SCALE, block.timestamp, 0, T0, index, block.timestamp, true);

        assertEq(session, -int256(SCALE / 2), "session clamps at -0.5%/h");
        assertEq(continuous, -int256(SCALE / 10), "continuous clamps at -0.1%/h");
        assertEq(session, continuous * 5, "the ceilings differ by exactly the 5x duty-cycle ratio");
    }

    /// @dev Premium, in bp, at which a pairing's rate ceiling is first reached.
    function _bandAtCeiling(uint256 rate, uint256 dampener) internal pure returns (uint256) {
        return rate * dampener * FundingLib.BP_SCALE / FundingLib.BAZAAR_SCALE;
    }

    /// @notice Each dampener is derived by integer division of the band by its ceiling, which is
    ///         exact only while the band is a whole multiple of that ceiling in bp per hour. This
    ///         asserts the round trip on the constants themselves rather than probing near the band
    ///         edge, where a dead zone narrower than the probe step would slip through unnoticed.
    ///         The load-bearing direction is >=: a dampener that truncated low would put the
    ///         ceiling BELOW the band edge, so the clamp would bind from inside the band and leave
    ///         a stretch over which funding no longer responds to mark movement — the precise shape
    ///         the derivation exists to prevent. Equality additionally says no band is wasted: the
    ///         ceiling sits exactly at the edge rather than above everything the band permits.
    function test_funding_everyCeilingReachesExactlyTheBandEdge() public view {
        assertEq(
            _bandAtCeiling(FundingLib.MAX_FUNDING_RATE_SESSION, FundingLib.FUNDING_DAMPENER_SESSION),
            FundingLib.MAX_MARK_DEVIATION_BP,
            "session ceiling must be reached exactly at the band edge, not inside it"
        );
        assertEq(
            _bandAtCeiling(FundingLib.MAX_FUNDING_RATE_CONTINUOUS, FundingLib.FUNDING_DAMPENER_CONTINUOUS),
            FundingLib.MAX_MARK_DEVIATION_BP,
            "continuous ceiling must be reached exactly at the band edge, not inside it"
        );
    }

    /// @notice With no fill, the mark decays linearly toward the index: half-way after 30 minutes.
    function test_mark_zeroFill_halfDecayAfter30Minutes() public view {
        FundingLib.MarkState memory s =
            FundingLib.updateMarkPrice(_state(220 * SCALE, block.timestamp - 30 minutes, 0), 0, 0, 200 * SCALE, 0);
        assertEq(s.markPrice, 210 * SCALE, "linear decay halfway to index");
        assertEq(s.rollingVolume, 0, "no volume");
    }

    /// @notice After a full decay period the mark IS the index.
    function test_mark_zeroFill_fullDecayAfterOneHour() public view {
        FundingLib.MarkState memory s =
            FundingLib.updateMarkPrice(_state(220 * SCALE, block.timestamp - 61 minutes, 0), 0, 0, 200 * SCALE, 0);
        assertEq(s.markPrice, 200 * SCALE, "fully decayed to index");
    }

    // ---------------- funding index ----------------

    /// @notice The 30-minute age cap (middle branch): a 2-hour quiet gap with a fresh oracle tick
    ///         accrues EXACTLY 30 minutes of funding, not 2 hours.
    function test_funding_ageCap_accruesExactly30MinutesAfterQuietGap() public {
        uint256 lastFunding = T0;
        vm.warp(T0 + 2 hours);
        // Mark $202 stamped now (no decay), index $200: premium 1%, rate = 1%/8 = 0.125%/h.
        (int256 idx, uint256 ts) = FundingLib.updateFundingIndex(
            202 * SCALE, block.timestamp, 0, lastFunding, 200 * SCALE, block.timestamp, false
        );
        // delta = 0.00125 x $200 x (30min/1h) = 0.125 in price units.
        assertEq(idx, int256(SCALE / 8), "exactly 30 minutes of accrual");
        assertEq(ts, block.timestamp, "clock advanced");
    }

    /// @notice The funding rate clamps at -0.5%/h for deep negative premiums (mirror of the
    ///         tested positive clamp).
    function test_funding_negativeClamp() public {
        uint256 lastFunding = T0;
        vm.warp(T0 + 30 minutes);
        // Mark $180 vs index $200: premium -10%, dampened -1.25% -> clamped to -0.5%/h.
        (int256 idx,) = FundingLib.updateFundingIndex(
            180 * SCALE, block.timestamp, 0, lastFunding, 200 * SCALE, block.timestamp, false
        );
        // delta = -0.005 x $200 x 0.5h = -0.5 price units.
        assertEq(idx, -int256(SCALE / 2), "clamped at -MAX_FUNDING_RATE");
    }

    /// @notice Zero index price is a no-accrue guard: the clock advances, the index does not move.
    function test_funding_zeroIndexPriceGuard() public {
        vm.warp(T0 + 10 minutes);
        (int256 idx, uint256 ts) =
            FundingLib.updateFundingIndex(200 * SCALE, block.timestamp, 7e18, T0, 0, block.timestamp, false);
        assertEq(idx, 7e18, "index unchanged");
        assertEq(ts, block.timestamp, "clock advanced");
    }

    /// @notice A >12h stale gap skips the window entirely (validStart jumps to the oracle ts).
    function test_funding_staleGapSkipsAccrual() public {
        vm.warp(T0 + 13 hours);
        (int256 idx, uint256 ts) =
            FundingLib.updateFundingIndex(210 * SCALE, block.timestamp, 3e18, T0, 200 * SCALE, block.timestamp, false);
        assertEq(idx, 3e18, "no back-charging across the outage");
        assertEq(ts, block.timestamp, "clock advanced");
    }
}
