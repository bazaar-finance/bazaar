// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @dev Harness for the insurance-fee curve entrypoints RiskParamsLibTest didn't reach: the
///      closing (base) rate across the target curve's legs, the taker rate's above-target arm,
///      and `getInsuranceFundToOIRatio`'s zero-price / zero-OI triples.
contract FeeCurveHarness {
    BazaarTypes.Vault internal pairVault;
    BazaarTypes.PairPrice internal lastPairPrice;
    BazaarTypes.LiquidationGapEma internal liquidationGapEma;
    BazaarTypes.ReopenGapEma internal reopenGapEma;
    int256 internal fundingIndex;

    function setVariance(uint256 v) external {
        lastPairPrice.emaVarianceBp = v;
    }

    /// @dev In whole basis points; the stored line is unsigned, so a negative value stores as zero.
    function setGap(int256 slip) external {
        liquidationGapEma.slippage = slip > 0 ? uint256(slip) * RiskParamsLib.GAP_EMA_SCALE : 0;
    }

    function setDrift(int256 drift) external {
        liquidationGapEma.drift = drift > 0 ? uint256(drift) * RiskParamsLib.GAP_EMA_SCALE : 0;
    }

    function setReopenGap(uint192 g) external {
        reopenGapEma.gapEmaBp = uint128(g);
    }

    function setOI(uint256 l, uint256 s) external {
        pairVault.totalLongOI = l;
        pairVault.totalShortOI = s;
    }

    function setInsurance(uint256 b) external {
        pairVault.insuranceFundBalance = b;
    }

    /// @dev Seeds inherited inventory so the coverage numerator's committed-loss leg is reachable.
    function setPendingLiq(uint256 size, uint256 entryNotional, bool isLong, int256 entryFundingIndex) external {
        pairVault.pendingLiqSize = size;
        pairVault.pendingLiqEntryNotional = entryNotional;
        pairVault.pendingLiqIsLong = isLong;
        pairVault.pendingLiqEntryFundingIndex = entryFundingIndex;
    }

    function setFundingIndex(int256 i) external {
        fundingIndex = i;
    }

    function closingFeeEbp() external view returns (uint256 c) {
        (, c) = RiskParamsLib.getInsuranceFeeRates(
            pairVault, lastPairPrice, liquidationGapEma, reopenGapEma, 1, true, fundingIndex
        );
    }

    /// @dev The same call on a session-bound pair, the only kind that consumes the reopen-gap
    ///      peak-hold seeded by setReopenGap.
    function closingFeeEbpNonContinuous() external view returns (uint256 c) {
        (, c) = RiskParamsLib.getInsuranceFeeRates(
            pairVault, lastPairPrice, liquidationGapEma, reopenGapEma, 1, false, fundingIndex
        );
    }

    function takerFeeEbp(uint256 p) external view returns (uint256 f) {
        (f,) = RiskParamsLib.getInsuranceFeeRates(
            pairVault, lastPairPrice, liquidationGapEma, reopenGapEma, p, true, fundingIndex
        );
    }

    function takerFeeEbpNonContinuous(uint256 p) external view returns (uint256 f) {
        (f,) = RiskParamsLib.getInsuranceFeeRates(
            pairVault, lastPairPrice, liquidationGapEma, reopenGapEma, p, false, fundingIndex
        );
    }

    function oiRatio(uint256 p) external view returns (uint256, uint256, uint256) {
        return RiskParamsLib.getInsuranceFundToOIRatio(pairVault, p, fundingIndex);
    }
}

contract RiskParamsFeeCurveTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant PRICE = 1e18; // 1:1 so OI size == OI notional

    FeeCurveHarness internal h;

    function setUp() public {
        h = new FeeCurveHarness();
        h.setOI(1_000_000 * SCALE, 1_000_000 * SCALE); // matched book, $1M OI notional per side at PRICE
    }

    // ==================== getClosingFeeEbp (the external entry, never called before) ====================

    /// @notice Low variance, zero gap → target 2% → base closing fee 50 EBP (0.5 bp).
    function test_closingFee_lowVol_zeroGap() public {
        h.setVariance(0);
        h.setGap(0);
        assertEq(h.closingFeeEbp(), 50, "target 2% -> 0.5 bp base");
    }

    /// @notice Extreme variance on a 24/7 pair → stress move 450bp → target 4.5% → interpolated
    ///         base closing fee 159 EBP: half the 9% IMR the same reading produces.
    function test_closingFee_extremeVol() public {
        h.setVariance(BazaarTypes.VARIANCE_EXTREME);
        h.setGap(0);
        assertEq(h.closingFeeEbp(), 159, "target 4.5% -> interpolated base");
    }

    /// @notice A NEGATIVE liquidation gap adds nothing to the stress move — fills landing better
    ///         than bankruptcy are evidence the level holds, not licence to lower it, and the
    ///         stored line records them as zero — so the target is the vol leg's alone, here
    ///         floored at 2% → 50 EBP.
    function test_closingFee_negativeGap_usesVolLegAlone() public {
        h.setVariance(0);
        h.setGap(-500);
        assertEq(h.closingFeeEbp(), 50, "negative gap adds nothing -> vol leg alone");
    }

    /// @notice A positive gap ADDS to the stress move and so raises the target: calm vol gives
    ///         150bp, a 100bp realized gap makes it 250bp → target 250 → base fee
    ///         50 + (250-200)*350/800 = 71 EBP.
    function test_closingFee_gapRaisesTarget() public {
        h.setVariance(0); // vol leg 150bp
        h.setGap(100);
        assertEq(h.closingFeeEbp(), 71, "gap-driven target 2.5% -> interpolated base");
    }

    /// @notice A large gap drives the target to the 10% ceiling: 150 + 900 = 1050bp of stress
    ///         move, clamped to INSURANCE_TARGET_MAX → base fee 400 EBP.
    function test_closingFee_gapClampsAtMax() public {
        h.setVariance(0);
        h.setGap(900);
        assertEq(h.closingFeeEbp(), 400, "target clamps at 10% -> 4 bp");
    }

    // ==================== taker fee: the above-target arm is flat at the base ====================

    /// @notice The rate is flat at fBase everywhere above target — 1.5x and 5x the target price
    ///         the same 50 EBP. Coverage the fund already holds does not make the next fill's
    ///         marginal risk free.
    function test_takerFee_aboveTarget_flatAtBase() public {
        h.setVariance(0); // target 2% (200bp), fBase = 50
        h.setInsurance(30_000 * SCALE); // 3% ratio = 1.5x target
        assertEq(h.takerFeeEbp(PRICE), 50, "1.5x target pays the base rate");
        h.setInsurance(100_000 * SCALE); // 10% ratio = 5x target
        assertEq(h.takerFeeEbp(PRICE), 50, "5x target pays the same base rate");
    }

    // ==================== reopen-gap leg: the fund target tracks the demonstrated tail ====================

    /// @notice A learned reopen gap reaches the target at FULL size, the same number the
    ///         maintenance level is set to survive: reopen 900 -> stress move 900 -> target
    ///         900bp -> base fee 50 + 700x350/800 = 356 EBP. A continuously traded pair never
    ///         consumes the peak-hold, so the 50 EBP baseline is untouched by the same state.
    function test_closingFee_reopenGapRaisesTarget() public {
        h.setVariance(0);
        h.setGap(0);
        h.setReopenGap(900);
        assertEq(h.closingFeeEbpNonContinuous(), 356, "reopen-driven target 9% -> interpolated base");
        assertEq(h.closingFeeEbp(), 50, "a 24/7 pair ignores the peak-hold");
    }

    /// @notice The same fund flips from above-target to deficit once the pair demonstrates a
    ///         tail: at 300bp coverage the calm 200bp target reads as over-covered (base fee
    ///         50 EBP), but a 900bp learned reopen lifts the target to 900bp -> 66% deficit ->
    ///         the quadratic surcharge on the 356 EBP base (8,107 EBP uncapped) reaches the
    ///         50 bp cap. Entry flow starts pre-funding the tail before any losses realize.
    function test_takerFee_reopenGapFlipsAboveTargetToDeficit() public {
        h.setVariance(0);
        h.setInsurance(30_000 * SCALE); // 300bp coverage
        assertEq(h.takerFeeEbp(PRICE), 50, "baseline: above the calm target, so the base rate");
        h.setReopenGap(900);
        assertEq(h.takerFeeEbpNonContinuous(PRICE), 5_000, "deficit vs the reopen-raised target, at the cap");
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

    // ==================== coverage numerator: committed loss on inherited inventory ====================

    /// @notice A liquidation moves size out of the OI aggregates and into the vault's
    ///         inventory. Measured OI must not fall with it — otherwise coverage reads higher
    ///         precisely when the vault takes on risk.
    function test_oiRatio_liquidationDoesNotShrinkOI() public {
        h.setInsurance(20_000 * SCALE);
        (,, uint256 before) = h.oiRatio(PRICE);

        // 200k of longs liquidated: off the long leg, onto the vault's book at entry.
        h.setOI(800_000 * SCALE, 1_000_000 * SCALE);
        h.setPendingLiq(200_000 * SCALE, 200_000 * SCALE, true, 0);

        (,, uint256 afterLiq) = h.oiRatio(PRICE);
        assertEq(afterLiq, before, "OI notional unchanged across a liquidation");
    }

    /// @notice The unrealized loss on inherited inventory is netted out of the numerator: it
    ///         is realized into insurance the moment the inventory unloads.
    function test_oiRatio_committedLossReducesNumerator() public {
        h.setInsurance(20_000 * SCALE);
        h.setOI(800_000 * SCALE, 1_000_000 * SCALE);
        // Vault holds 2,000 units of longs entered at $100 = $200k basis.
        h.setPendingLiq(2_000 * SCALE, 200_000 * SCALE, true, 0);

        // Price at entry: nothing owed, full fund is free.
        (, uint256 freeAtEntry,) = h.oiRatio(100 * SCALE);
        assertEq(freeAtEntry, 20_000 * SCALE, "no loss at entry price");

        // Price down 5%: the inventory is $10k underwater.
        (, uint256 freeAfterDrop,) = h.oiRatio(95 * SCALE);
        assertEq(freeAfterDrop, 10_000 * SCALE, "loss netted out of free capital");
    }

    /// @notice Gains are not credited — inventory the vault still has to exit is not capital.
    function test_oiRatio_gainsNotCredited() public {
        h.setInsurance(20_000 * SCALE);
        h.setOI(800_000 * SCALE, 1_000_000 * SCALE);
        h.setPendingLiq(2_000 * SCALE, 200_000 * SCALE, true, 0);

        (, uint256 free,) = h.oiRatio(105 * SCALE);
        assertEq(free, 20_000 * SCALE, "unrealized gain does not raise free capital");
    }

    /// @notice Funding accrued on the inventory is a claim on insurance too: a vault holding
    ///         longs while the index rises owes that leg on unload.
    function test_oiRatio_fundingLegCounted() public {
        h.setInsurance(20_000 * SCALE);
        h.setOI(800_000 * SCALE, 1_000_000 * SCALE);
        h.setPendingLiq(2_000 * SCALE, 200_000 * SCALE, true, 0);
        h.setFundingIndex(2 * int256(SCALE)); // $2/unit of funding owed on 2,000 units

        (, uint256 free,) = h.oiRatio(100 * SCALE);
        assertEq(free, 16_000 * SCALE, "funding leg netted at a flat price");
    }

    /// @notice The floor holds when the claim exceeds the fund rather than underflowing.
    function test_oiRatio_committedExceedsFund_floorsAtZero() public {
        h.setInsurance(1_000 * SCALE);
        h.setOI(800_000 * SCALE, 1_000_000 * SCALE);
        h.setPendingLiq(2_000 * SCALE, 200_000 * SCALE, true, 0);

        (uint256 ratioBp, uint256 free,) = h.oiRatio(90 * SCALE); // $20k underwater vs a $1k fund
        assertEq(free, 0, "free capital floors at zero");
        assertEq(ratioBp, 0, "zero coverage reads as maximum stress");
    }
}
