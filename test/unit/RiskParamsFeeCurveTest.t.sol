// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @dev Harness for the insurance-fee curve entrypoints RiskParamsLibTest didn't reach:
///      `getClosingFeeEbp` (the external closing-fee entry, never called), the taker-fee
///      partial-surplus discount, and `getInsuranceFundToOIRatio`'s zero-price / zero-OI triples.
contract FeeCurveHarness {
    BazaarTypes.Vault internal pairVault;
    BazaarTypes.PairPrice internal lastPairPrice;
    BazaarTypes.LiquidationGapEma internal liquidationGapEma;

    function setVariance(uint256 v) external {
        lastPairPrice.emaVarianceBp = v;
    }

    function setGap(int256 g) external {
        liquidationGapEma.emaGapBp = g;
    }

    function setOI(uint256 l, uint256 s) external {
        pairVault.totalLongOI = l;
        pairVault.totalShortOI = s;
    }

    function setInsurance(uint256 b) external {
        pairVault.insuranceFundBalance = b;
    }

    function closingFeeEbp() external view returns (uint256) {
        return RiskParamsLib.getClosingFeeEbp(lastPairPrice, liquidationGapEma);
    }

    function takerFeeEbp(uint256 p) external view returns (uint256) {
        return RiskParamsLib.getTakerInsuranceFeeEbp(pairVault, lastPairPrice, liquidationGapEma, p);
    }

    function oiRatio(uint256 p) external view returns (uint256, uint256, uint256) {
        return RiskParamsLib.getInsuranceFundToOIRatio(pairVault, p);
    }
}

contract RiskParamsFeeCurveTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant PRICE = 1e18; // 1:1 so OI size == OI notional

    FeeCurveHarness internal h;

    function setUp() public {
        h = new FeeCurveHarness();
        h.setOI(1_000_000 * SCALE, 0); // $1M OI notional at PRICE
    }

    // ==================== getClosingFeeEbp (the external entry, never called before) ====================

    /// @notice Low variance, zero gap → target 2% → base closing fee 50 EBP (0.5 bp).
    function test_closingFee_lowVol_zeroGap() public {
        h.setVariance(0);
        h.setGap(0);
        assertEq(h.closingFeeEbp(), 50, "target 2% -> 0.5 bp base");
    }

    /// @notice Extreme variance → target 10% → base closing fee 200 EBP (2 bp).
    function test_closingFee_extremeVol() public {
        h.setVariance(BazaarTypes.VARIANCE_EXTREME);
        h.setGap(0);
        assertEq(h.closingFeeEbp(), 200, "target 10% -> 2 bp base");
    }

    /// @notice A NEGATIVE liquidation gap contributes no gap-target (gapBp > 0 arm is false), so the
    ///         target falls back to the volatility target — here 2% → 50 EBP. Pins the negative-gap branch.
    function test_closingFee_negativeGap_usesVolTarget() public {
        h.setVariance(0);
        h.setGap(-500);
        assertEq(h.closingFeeEbp(), 50, "negative gap -> gapTarget 0 -> vol target");
    }

    /// @notice A positive gap can raise the target above the volatility target: gap 100bp → gapTarget
    ///         300bp → interpolated base fee 68 EBP (50 + (300-200)*150/800).
    function test_closingFee_gapRaisesTarget() public {
        h.setVariance(0); // vol target 200
        h.setGap(100); // gap target 300 dominates
        assertEq(h.closingFeeEbp(), 68, "gap-driven target 3% -> interpolated base");
    }

    /// @notice A large gap drives the target to the 10% ceiling (gap 400 → gapTarget 1200, clamped
    ///         to INSURANCE_TARGET_MAX) → base fee 200 EBP.
    function test_closingFee_gapClampsAtMax() public {
        h.setVariance(0);
        h.setGap(400);
        assertEq(h.closingFeeEbp(), 200, "gap target clamps at 10% -> 2 bp");
    }

    // ==================== taker fee: partial-surplus discount midpoint ====================

    /// @notice Fund at 1.5x the target sits in the partial-surplus band: surplus δ = 0.5, so the fee
    ///         is fBase·(1 − δ) = 50·0.5 = 25 EBP. Between the at-target (50) and 2x (0) endpoints.
    function test_takerFee_partialSurplus_midpoint() public {
        h.setVariance(0); // target 2% (200bp), fBase = 50
        h.setInsurance(30_000 * SCALE); // 3% ratio = 1.5x target
        assertEq(h.takerFeeEbp(PRICE), 25, "half-surplus halves the base fee");
    }

    // ==================== getInsuranceFundToOIRatio triples ====================

    /// @notice Zero price yields the (0, fund, 0) triple — no meaningful ratio computable.
    function test_oiRatio_zeroPrice_triple() public {
        h.setInsurance(500 * SCALE);
        (uint256 ratioBp, uint256 fund, uint256 notional) = h.oiRatio(0);
        assertEq(ratioBp, 0, "no ratio at price 0");
        assertEq(fund, 500 * SCALE, "fund passed through");
        assertEq(notional, 0, "no notional at price 0");
    }

    /// @notice Zero open interest yields infinite coverage: (type(uint256).max, fund, 0).
    function test_oiRatio_zeroOI_infinite() public {
        h.setOI(0, 0);
        h.setInsurance(1 * SCALE);
        (uint256 ratioBp, uint256 fund, uint256 notional) = h.oiRatio(PRICE);
        assertEq(ratioBp, type(uint256).max, "infinite coverage with no OI");
        assertEq(fund, 1 * SCALE, "fund passed through");
        assertEq(notional, 0, "no OI notional");
    }

    /// @notice Normal case: $20k fund over $1M OI notional = 200 bp coverage.
    function test_oiRatio_normal() public {
        h.setInsurance(20_000 * SCALE);
        (uint256 ratioBp,, uint256 notional) = h.oiRatio(PRICE);
        assertEq(ratioBp, 200, "2% coverage");
        assertEq(notional, 1_000_000 * SCALE, "OI notional at PRICE");
    }
}
