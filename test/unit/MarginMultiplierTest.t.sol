// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";

/// @notice Exposes RiskParamsLib's (pure) IMR/MMR multiplier + insurance-target curves.
///         The curves moved from BazaarPair to the external RiskParamsLib (EIP-170 extraction).
contract MultiplierHarness {
    function volMult(uint256 v) external pure returns (uint256) {
        return RiskParamsLib.getVolatilityMultiplier(v);
    }

    function gapMult(int256 g) external pure returns (uint256) {
        return RiskParamsLib.getLiquidationGapMultiplier(g);
    }

    function insMult(uint256 c, uint256 t) external pure returns (uint256) {
        return RiskParamsLib.getInsuranceMultiplier(c, t);
    }

    function targetRatio(uint256 v, int256 g, uint256 rg) external pure returns (uint256) {
        return RiskParamsLib.getTargetInsuranceRatio(v, g, rg);
    }

    function volCap() external pure returns (uint256) {
        return RiskParamsLib.VOL_MULTIPLIER_MAX;
    }

    function consts()
        external
        pure
        returns (uint256 bp, uint256 mmax, uint256 vLow, uint256 vHigh, uint256 iBase, uint256 iMax, uint256 gapHigh)
    {
        return (
            RiskParamsLib.BP_SCALE,
            RiskParamsLib.MULTIPLIER_MAX,
            RiskParamsLib.VARIANCE_LOW,
            RiskParamsLib.VARIANCE_EXTREME,
            RiskParamsLib.INSURANCE_TARGET_BASE,
            RiskParamsLib.INSURANCE_TARGET_MAX,
            RiskParamsLib.LIQUIDATION_GAP_EXTREME
        );
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
    uint256 GAPHIGH;

    function setUp() public {
        h = new MultiplierHarness();
        (BP, MMAX, VLOW, VHIGH, IBASE, IMAX, GAPHIGH) = h.consts();
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

    // ---------------- liquidation-gap multiplier ----------------

    function test_gapMultiplier_boundaries() public view {
        assertEq(h.gapMult(-5), BP, "negative gap => 1x");
        assertEq(h.gapMult(0), BP, "zero gap => 1x");
        assertEq(h.gapMult(int256(GAPHIGH)), MMAX, "at EXTREME gap => 3x");
        assertEq(h.gapMult(int256(GAPHIGH) + 100), MMAX, "above EXTREME clamps");
    }

    function test_gapMultiplier_midpointLinear() public view {
        int256 mid = int256(GAPHIGH / 2);
        uint256 expected = BP + uint256(mid) * (MMAX - BP) / GAPHIGH;
        assertEq(h.gapMult(mid), expected);
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

    // ---------------- target insurance ratio ----------------

    function test_targetRatio_volatilityDriven() public view {
        assertEq(h.targetRatio(0, 0, 0), IBASE, "low variance => base target");
        assertEq(h.targetRatio(VLOW, 0, 0), IBASE);
        assertEq(h.targetRatio(VHIGH, 0, 0), IMAX, "extreme variance => max target");
    }

    function test_targetRatio_gapCanRaiseTarget() public view {
        // gapTarget = gap*3; a large gap should push the target above the low-variance base
        uint256 withGap = h.targetRatio(0, int256(IBASE), 0); // gapTarget = IBASE*3 -> dominates, clamps to IMAX
        assertGe(withGap, IBASE, "gap raises target at/above base");
        assertLe(withGap, IMAX, "clamped to max");
    }

    function test_targetRatio_clampedToMax() public view {
        // huge variance AND huge gap -> still clamped to IMAX
        assertEq(h.targetRatio(VHIGH * 2, int256(IMAX), 0), IMAX);
    }

    /// @notice The reopen-gap leg floors the target at gap/2 — a demonstrated reopen of size g
    ///         against one side of a balanced book creates bad debt of at most g/2 of total OI.
    ///         Zero (the continuous-pair input) is inert, and both clamps still apply.
    function test_targetRatio_reopenGapFloorsAtHalf() public view {
        assertEq(h.targetRatio(0, 0, 900), 450, "gap/2 binds over the calm-vol base");
        assertEq(h.targetRatio(0, 0, 300), IBASE, "sub-base gap/2 falls back to the base floor");
        assertEq(h.targetRatio(0, 0, 4000), IMAX, "a cap-sized reopen (40%) pins the max target");
        assertEq(h.targetRatio(VHIGH, 0, 900), IMAX, "extreme vol still dominates a smaller reopen leg");
    }
}
