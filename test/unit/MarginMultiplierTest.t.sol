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

    function targetRatio(uint256 v, int256 g) external pure returns (uint256) {
        return RiskParamsLib.getTargetInsuranceRatio(v, g);
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

    // ---------------- volatility multiplier: 1x at/below LOW, 3x at/above EXTREME, linear between ----------------

    function test_volMultiplier_boundaries() public view {
        assertEq(h.volMult(0), BP, "0 variance => 1x");
        assertEq(h.volMult(VLOW), BP, "at LOW => 1x");
        assertEq(h.volMult(VHIGH), MMAX, "at EXTREME => 3x");
        assertEq(h.volMult(VHIGH + 1), MMAX, "above EXTREME clamps to 3x");
    }

    function test_volMultiplier_midpointLinear() public view {
        uint256 mid = VLOW + (VHIGH - VLOW) / 2;
        uint256 expected = BP + (mid - VLOW) * (MMAX - BP) / (VHIGH - VLOW);
        assertEq(h.volMult(mid), expected);
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
        assertEq(h.targetRatio(0, 0), IBASE, "low variance => base target");
        assertEq(h.targetRatio(VLOW, 0), IBASE);
        assertEq(h.targetRatio(VHIGH, 0), IMAX, "extreme variance => max target");
    }

    function test_targetRatio_gapCanRaiseTarget() public view {
        // gapTarget = gap*3; a large gap should push the target above the low-variance base
        uint256 withGap = h.targetRatio(0, int256(IBASE)); // gapTarget = IBASE*3 -> dominates, clamps to IMAX
        assertGe(withGap, IBASE, "gap raises target at/above base");
        assertLe(withGap, IMAX, "clamped to max");
    }

    function test_targetRatio_clampedToMax() public view {
        // huge variance AND huge gap -> still clamped to IMAX
        assertEq(h.targetRatio(VHIGH * 2, int256(IMAX)), IMAX);
    }
}
