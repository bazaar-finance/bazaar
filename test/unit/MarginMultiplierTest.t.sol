// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";

/// @notice Exposes RiskParamsLib's pure risk curves: the volatility multiplier, the stress move
///         both outputs derive from, the fund target, and the fund-health multiplier.
contract MultiplierHarness {
    function volMult(uint256 v) external pure returns (uint256) {
        return RiskParamsLib.getVolatilityMultiplier(v);
    }

    function insMult(uint256 c, uint256 t) external pure returns (uint256) {
        return RiskParamsLib.getInsuranceMultiplier(c, t);
    }

    function stressMove(uint256 v, int256 slip, uint256 rg, bool cont) external pure returns (uint256) {
        return RiskParamsLib.stressMoveBp(v, slip, rg, cont);
    }

    /// @dev The target with no realized drift on record, i.e. the forecast leg alone.
    function targetRatio(uint256 m) external pure returns (uint256) {
        return RiskParamsLib.getTargetInsuranceRatio(m, 0);
    }

    /// @dev The composed reading both outputs are taken from, as calculateIMRandMMR composes it,
    ///      on a pair with no realized drift.
    function targetFor(uint256 v, int256 slip, uint256 rg, bool cont) external pure returns (uint256) {
        return RiskParamsLib.getTargetInsuranceRatio(RiskParamsLib.stressMoveBp(v, slip, rg, cont), 0);
    }

    /// @dev The same composition with a realized-drift leg competing against the forecast.
    function targetForWithDrift(uint256 v, int256 slip, uint256 rg, bool cont, int256 drift)
        external
        pure
        returns (uint256)
    {
        return RiskParamsLib.getTargetInsuranceRatio(RiskParamsLib.stressMoveBp(v, slip, rg, cont), drift);
    }

    function volCap() external pure returns (uint256) {
        return RiskParamsLib.VOL_MULTIPLIER_MAX;
    }

    function consts()
        external
        pure
        returns (uint256 bp, uint256 mmax, uint256 vLow, uint256 vHigh, uint256 iBase, uint256 iMax)
    {
        return (
            RiskParamsLib.BP_SCALE,
            RiskParamsLib.MULTIPLIER_MAX,
            RiskParamsLib.VARIANCE_LOW,
            RiskParamsLib.VARIANCE_EXTREME,
            RiskParamsLib.INSURANCE_TARGET_BASE,
            RiskParamsLib.INSURANCE_TARGET_MAX
        );
    }

    function stressBounds() external pure returns (uint256 minM, uint256 maxM, uint256 kappa) {
        minM = RiskParamsLib.MIN_STRESS_MOVE_BP;
        maxM = RiskParamsLib.MAX_STRESS_MOVE_BP;
        kappa = RiskParamsLib.INSURANCE_TARGET_KAPPA_BP;
    }
}

contract MarginMultiplierTest is Test {
    MultiplierHarness internal h;
    uint256 BP;
    uint256 MMAX;
    uint256 VLOW;
    uint256 VHIGH;
    uint256 IBASE;
    uint256 IMAX;
    uint256 MINM;
    uint256 MAXM;
    uint256 KAPPA;

    function setUp() public {
        h = new MultiplierHarness();
        (BP, MMAX, VLOW, VHIGH, IBASE, IMAX) = h.consts();
        (MINM, MAXM, KAPPA) = h.stressBounds();
    }

    // ---------------- volatility multiplier: 1x at/below LOW, one line through 3x at EXTREME,
    // ---------------- continuing to the 6x VOL_MULTIPLIER_MAX cap ----------------

    function test_volMultiplier_boundaries() public view {
        assertEq(h.volMult(0), BP, "0 variance => 1x");
        assertEq(h.volMult(VLOW), BP, "at LOW => 1x");
        assertEq(h.volMult(VHIGH), MMAX, "the line passes exactly through 3x at EXTREME");
    }

    function test_volMultiplier_midpointLinear() public view {
        uint256 mid = VLOW + (VHIGH - VLOW) / 2;
        uint256 expected = BP + (mid - VLOW) * (MMAX - BP) / (VHIGH - VLOW);
        assertEq(h.volMult(mid), expected);
    }

    /// @notice VARIANCE_EXTREME is a point on the line, not a ceiling: past it the multiplier
    ///         keeps climbing on the same slope. 150M bp^2 (~122% annualized vol) reads ~4.02x.
    function test_volMultiplier_lineContinuesPastExtreme() public view {
        uint256 v = 150_000_000;
        uint256 expected = BP + (v - VLOW) * (MMAX - BP) / (VHIGH - VLOW);
        assertGt(expected, MMAX, "sanity: past-EXTREME point exceeds 3x");
        assertEq(h.volMult(v), expected, "line continues past EXTREME");
    }

    /// @notice The vol-specific ceiling binds exactly where the line reaches VOL_MULTIPLIER_MAX:
    ///         variance = LOW + (cap-1x)/(3x-1x) x (EXTREME-LOW) = 247M bp^2 (~157% annualized
    ///         vol). One notch below sits under the cap; everything at or beyond pins to 6x.
    function test_volMultiplier_capsAt6x() public view {
        uint256 cap = h.volCap();
        uint256 vSat = VLOW + (cap - BP) * (VHIGH - VLOW) / (MMAX - BP);
        assertEq(vSat, 247_000_000, "saturation variance");
        assertEq(h.volMult(vSat), cap, "line meets the cap exactly at saturation");
        assertLt(h.volMult(vSat - 100_000), cap, "just below saturation is under the cap");
        assertEq(h.volMult(vSat * 2), cap, "beyond saturation pins to the cap");
        assertEq(h.volMult(type(uint128).max), cap, "arbitrarily large variance pins to the cap");
    }

    // ---------------- stress move: the single risk reading both outputs derive from ----------------

    /// @notice A continuously traded pair's maintenance level is half the vol curve, because IMR
    ///         is twice the stress move and the curve is stated at the initial-margin level. At
    ///         calm variance that is 150bp, which the floor lifts to MIN_STRESS_MOVE_BP.
    function test_stressMove_continuous_isHalfTheVolCurve() public view {
        assertEq(h.stressMove(0, 0, 0, true), MINM, "calm vol floors at MIN_STRESS_MOVE_BP");
        assertEq(h.stressMove(VHIGH, 0, 0, true), 450, "100% vol: 300 x 3 / 2");
        assertEq(h.stressMove(247_000_000, 0, 0, true), 900, "vol cap: 300 x 6 / 2");
    }

    /// @notice A session-bound pair takes the WHOLE vol curve — the closure prior — and the max
    ///         with its learned reopen gap. The estimators compose by max so the same reopen,
    ///         which feeds both the variance EMA and the peak-hold, is counted once.
    function test_stressMove_nonContinuous_isVolCurveMaxReopen() public view {
        assertEq(h.stressMove(0, 0, 0, false), 300, "calm vol, no gap history: the whole curve");
        assertEq(h.stressMove(0, 0, 250, false), 300, "a reopen under the vol curve is inert");
        assertEq(h.stressMove(0, 0, 1500, false), 1500, "a reopen above it takes over");
        assertEq(h.stressMove(VHIGH, 0, 500, false), 900, "vol above the reopen takes over");
    }

    /// @notice The liquidation-gap EMA ADDS: it is realized shortfall past the estates'
    ///         bankruptcy price, so it is the amount by which maintenance margin proved too
    ///         thin, in the same units. The same 300bp gap therefore costs the same 300bp on a
    ///         calm pair and a volatile one, rather than scaling whatever the vol leg said.
    function test_stressMove_liquidationGapAddsFlat() public view {
        uint256 calm = h.stressMove(0, 0, 0, true);
        uint256 wild = h.stressMove(VHIGH, 0, 0, true);
        assertEq(h.stressMove(0, 300, 0, true) - calm, 250, "calm: 150 + 300 floored at 200 -> +250 over the floor");
        assertEq(h.stressMove(VHIGH, 300, 0, true) - wild, 300, "volatile: the same flat 300bp");
    }

    /// @notice A negative gap EMA — fills landing better than bankruptcy — adds nothing. It is
    ///         evidence the level holds, not licence to set it below what the vol leg asks.
    function test_stressMove_negativeGapIsInert() public view {
        assertEq(h.stressMove(VHIGH, -500, 0, true), h.stressMove(VHIGH, 0, 0, true), "negative gap adds nothing");
    }

    /// @notice Both clamps. The floor is MIN_IMR_BP/2 so IMR's own floor binds through the same
    ///         number; the ceiling bounds the gap term, whose EMA has no intrinsic upper bound.
    function test_stressMove_clamps() public view {
        assertEq(MINM, 200, "floor is half MIN_IMR_BP");
        assertEq(MAXM, 4000, "ceiling is half MAX_IMR_BP");
        assertEq(h.stressMove(0, 0, 0, true), MINM, "floored");
        assertEq(h.stressMove(type(uint128).max, type(int128).max, 0, true), MAXM, "capped");
        assertEq(h.stressMove(0, 0, 4000, false), MAXM, "a cap-sized reopen lands exactly on the ceiling");
    }

    // ---------------- fund target: a flat share of the stress move ----------------

    /// @notice The target is INSURANCE_TARGET_KAPPA_BP of the stress move, so coverage per unit
    ///         of maintenance margin is the same in every regime. At 1x the floor of the stress
    ///         move lands exactly on INSURANCE_TARGET_BASE.
    function test_targetRatio_tracksStressMove() public view {
        assertEq(KAPPA, BP, "kappa is 1x");
        assertEq(h.targetRatio(MINM), IBASE, "the stress-move floor lands on the target floor");
        assertEq(h.targetRatio(450), 450, "tracks one-for-one inside the band");
        assertEq(h.targetRatio(750), 750);
    }

    function test_targetRatio_clamps() public view {
        assertEq(h.targetRatio(0), IBASE, "below the band floors");
        assertEq(h.targetRatio(IMAX + 1), IMAX, "above the band caps");
        assertEq(h.targetRatio(MAXM), IMAX, "the stress-move ceiling is far past the target cap");
    }

    /// @notice Composed end to end: the target rises with volatility on the same reading margin
    ///         does, and the demonstrated reopen a session pair learned reaches it at FULL size.
    function test_targetRatio_composedFromTheSameReading() public view {
        assertEq(h.targetFor(0, 0, 0, true), IBASE, "calm 24/7 pair sits at the base target");
        assertEq(h.targetFor(VHIGH, 0, 0, true), 450, "100% vol: 4.5% target, half the 9% IMR");
        assertEq(h.targetFor(0, 300, 0, true), 450, "a 3% realized gap on a calm pair: 4.5% target");
        assertEq(h.targetFor(0, 0, 1000, false), IMAX, "a 10% demonstrated reopen pins the 10% cap");
        assertEq(h.targetFor(0, 0, 4000, false), IMAX, "and a cap-sized one cannot go past it");
    }

    /// @notice The target is monotone in variance — the property two independently clamped
    ///         curves over the same estimators do not have. Volatility ALONE saturates a 24/7
    ///         pair's target at 9%, the vol cap's maintenance level: reaching the 10% ceiling
    ///         takes a realized liquidation gap or a demonstrated reopen on top.
    function test_targetRatio_monotoneInVariance() public view {
        uint256 prev;
        for (uint256 v = 0; v <= 300_000_000; v += 10_000_000) {
            uint256 t = h.targetFor(v, 0, 0, true);
            assertGe(t, prev, "target never falls as variance rises");
            prev = t;
        }
        assertEq(prev, 900, "the vol leg alone saturates at 9%");
        assertEq(h.targetFor(300_000_000, 200, 0, true), IMAX, "a 2% realized gap on top reaches the cap");
    }

    // ---------------- insurance multiplier: 1x when well-funded, 3x when empty ----------------

    function test_insMultiplier_wellFundedIsOne() public view {
        assertEq(h.insMult(IBASE, IBASE), BP, "current == target => 1x");
        assertEq(h.insMult(IBASE + 1, IBASE), BP, "current > target => 1x");
    }

    function test_insMultiplier_emptyIsMax() public view {
        assertEq(h.insMult(0, IBASE), MMAX, "empty fund => 3x");
    }

    function test_insMultiplier_halfwayLinear() public view {
        uint256 target = 1000;
        uint256 current = 500; // half
        uint256 expected = BP + (target - current) * (MMAX - BP) / target;
        assertEq(h.insMult(current, target), expected);
    }

    /// @notice The fund-health leg is absent from the stress move, and so from the target. Were
    ///         the target derived from a margin figure already carrying the multiplier, a fund
    ///         below target would raise the target and deepen its own shortfall.
    function test_targetRatio_isIndependentOfFundHealth() public view {
        uint256 target = h.targetFor(VHIGH, 0, 0, true);
        assertEq(target, 450, "target reads the pair's risk only");
        assertGt(h.insMult(0, target), BP, "sanity: an empty fund does move margin");
    }
}
