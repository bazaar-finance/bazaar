// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";

/// @notice Direct unit tests for FundingLib's mark-price EMA internals — the single-batch
///         manipulation bound (10% alpha cap), the no-floor dust behavior, the exec-price
///         deviation band, decay-to-index — and the funding-index age-cap middle branch. None of
///         this had direct assertions before the EIP-170 extraction made the library testable.
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

    // ---------------- mark price ----------------

    /// @notice First fill ever: the mark seeds from the index and a volume-dominant fill is capped
    ///         at the 10% blend — the single-batch manipulation bound.
    function test_mark_firstFill_dominantFillCappedAt10Percent() public view {
        FundingLib.MarkState memory s =
            FundingLib.updateMarkPrice(_state(0, 0, 0), 210 * SCALE, 1_000 * SCALE, 200 * SCALE);
        // decayedMark = index (fresh state); alpha clamps to 1000/10000:
        // mark = 210 x 10% + 200 x 90% = 201.
        assertEq(s.markPrice, 201 * SCALE, "dominant fill moves the mark at most 10% toward exec");
        assertEq(s.rollingVolume, 1_000 * SCALE, "fill volume recorded");
        assertEq(s.lastMarkUpdateTs, block.timestamp, "stamped");
    }

    /// @notice A dust fill against deep rolling volume gets ~0 weight (no MIN_ALPHA floor): the mark
    ///         does not move, so a tiny wash trade can't nudge it. (Was 200.05 with the old floor.)
    function test_mark_dustFill_noFloorLeavesMarkUnmoved() public view {
        FundingLib.MarkState memory s = FundingLib.updateMarkPrice(
            _state(200 * SCALE, block.timestamp, 1_000_000 * SCALE), 210 * SCALE, 1 * SCALE, 200 * SCALE
        );
        // alpha = 1/1_000_001 expressed in bp truncates to 0: mark stays at the (undecayed) 200.
        assertEq(s.markPrice, 200 * SCALE, "dust fill gets ~0 weight, mark unmoved");
        assertEq(s.rollingVolume, 1_000_001 * SCALE, "dust volume still recorded");
    }

    /// @notice An execution print far from the index is clamped to the ±5% band before it enters
    ///         the EMA, so a self-crossed wash trade at an arbitrary price can't push the mark past
    ///         the band even on a quiet pair where alpha hits the 10% cap.
    function test_mark_execPriceClampedToDeviationBand() public view {
        // Volume-dominant fill (alpha caps at 10%) printing at 300 vs index 200 (+50%, well past 5%).
        FundingLib.MarkState memory s =
            FundingLib.updateMarkPrice(_state(0, 0, 0), 300 * SCALE, 1_000 * SCALE, 200 * SCALE);
        // Print clamps to 200 x 1.05 = 210; mark = 210 x 10% + 200 x 90% = 201 (NOT 210, which is
        // what an unclamped 300 print would give: 300 x 10% + 200 x 90%).
        assertEq(s.markPrice, 201 * SCALE, "print clamped to +5% band before the 10% blend");
    }

    /// @notice With no fill, the mark decays linearly toward the index: half-way after 30 minutes.
    function test_mark_zeroFill_halfDecayAfter30Minutes() public view {
        FundingLib.MarkState memory s =
            FundingLib.updateMarkPrice(_state(220 * SCALE, block.timestamp - 30 minutes, 0), 0, 0, 200 * SCALE);
        assertEq(s.markPrice, 210 * SCALE, "linear decay halfway to index");
        assertEq(s.rollingVolume, 0, "no volume");
    }

    /// @notice After a full decay period the mark IS the index.
    function test_mark_zeroFill_fullDecayAfterOneHour() public view {
        FundingLib.MarkState memory s =
            FundingLib.updateMarkPrice(_state(220 * SCALE, block.timestamp - 61 minutes, 0), 0, 0, 200 * SCALE);
        assertEq(s.markPrice, 200 * SCALE, "fully decayed to index");
    }

    // ---------------- funding index ----------------

    /// @notice The 30-minute age cap (middle branch): a 2-hour quiet gap with a fresh oracle tick
    ///         accrues EXACTLY 30 minutes of funding, not 2 hours.
    function test_funding_ageCap_accruesExactly30MinutesAfterQuietGap() public {
        uint256 lastFunding = T0;
        vm.warp(T0 + 2 hours);
        // Mark $202 stamped now (no decay), index $200: premium 1%, rate = 1%/8 = 0.125%/h.
        (int256 idx, uint256 ts) =
            FundingLib.updateFundingIndex(202 * SCALE, block.timestamp, 0, lastFunding, 200 * SCALE, block.timestamp);
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
        (int256 idx,) =
            FundingLib.updateFundingIndex(180 * SCALE, block.timestamp, 0, lastFunding, 200 * SCALE, block.timestamp);
        // delta = -0.005 x $200 x 0.5h = -0.5 price units.
        assertEq(idx, -int256(SCALE / 2), "clamped at -MAX_FUNDING_RATE");
    }

    /// @notice Zero index price is a no-accrue guard: the clock advances, the index does not move.
    function test_funding_zeroIndexPriceGuard() public {
        vm.warp(T0 + 10 minutes);
        (int256 idx, uint256 ts) =
            FundingLib.updateFundingIndex(200 * SCALE, block.timestamp, 7e18, T0, 0, block.timestamp);
        assertEq(idx, 7e18, "index unchanged");
        assertEq(ts, block.timestamp, "clock advanced");
    }

    /// @notice A >12h stale gap skips the window entirely (validStart jumps to the oracle ts).
    function test_funding_staleGapSkipsAccrual() public {
        vm.warp(T0 + 13 hours);
        (int256 idx, uint256 ts) =
            FundingLib.updateFundingIndex(210 * SCALE, block.timestamp, 3e18, T0, 200 * SCALE, block.timestamp);
        assertEq(idx, 3e18, "no back-charging across the outage");
        assertEq(ts, block.timestamp, "clock advanced");
    }
}
