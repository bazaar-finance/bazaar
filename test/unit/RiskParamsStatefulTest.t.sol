// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @dev Storage host for the three STATEFUL RiskParamsLib functions: `calculateVariance` (the
///      volatility EMA), `updateLiquidationGapEmaBatch` (the liquidation-gap EMA), and
///      `calculateIMRandMMR` (the margin curve and the cached fund target, both composed off
///      the stress move). Together these are the volatility/liquidation → leverage-limit
///      feedback loop.
contract RiskParamsStatefulHarness {
    BazaarTypes.MarginRequirements internal marginRequirements;
    BazaarTypes.PairPrice internal lastPairPrice;
    BazaarTypes.VarianceSample internal varianceSample;
    BazaarTypes.LiquidationGapEma internal liquidationGapEma;
    BazaarTypes.Vault internal pairVault;
    BazaarTypes.ReopenGapEma internal reopenGapEma;

    // ---- setters ----
    function setPairPrice(uint256 spotPrice, uint256 updateTs, uint256 emaVarianceBp) external {
        lastPairPrice.spotPrice = spotPrice;
        lastPairPrice.updateTs = updateTs;
        lastPairPrice.emaVarianceBp = emaVarianceBp;
    }

    function setVarianceSample(uint256 spotPrice, uint256 publishTs) external {
        varianceSample.spotPrice = uint192(spotPrice);
        varianceSample.publishTs = uint64(publishTs);
    }

    function setGapEma(int256 emaGapBp, uint256 lastLiquidationTs, uint256 decayedSize) external {
        liquidationGapEma.emaGapBp = emaGapBp;
        liquidationGapEma.lastLiquidationTs = lastLiquidationTs;
        liquidationGapEma.decayedSize = decayedSize;
    }

    function setVault(uint256 insuranceFundBalance, uint256 totalLongOI, uint256 totalShortOI) external {
        pairVault.insuranceFundBalance = insuranceFundBalance;
        pairVault.totalLongOI = totalLongOI;
        pairVault.totalShortOI = totalShortOI;
    }

    function setMarginReqs(uint256 imrBp, uint256 mmrBp, uint256 lastUpdateTs) external {
        marginRequirements.imrBp = imrBp;
        marginRequirements.mmrBp = mmrBp;
        marginRequirements.lastUpdateTs = lastUpdateTs;
    }

    function setReopenGap(uint192 gapEmaBp, uint64 lastObsTs) external {
        reopenGapEma.gapEmaBp = gapEmaBp;
        reopenGapEma.lastObsTs = lastObsTs;
    }

    // ---- callers ----
    function calcVariance(uint256 price, uint256 publishTime) external returns (uint256) {
        return RiskParamsLib.calculateVariance(lastPairPrice, varianceSample, reopenGapEma, price, publishTime);
    }

    function updateGapBatch(int256 sumGapTimesSize, uint256 totalFillSize, uint256 count) external {
        RiskParamsLib.updateLiquidationGapEmaBatch(liquidationGapEma, sumGapTimesSize, totalFillSize, count);
    }

    function calcIMRandMMR(
        uint256 currentPrice,
        bool isContinuouslyTraded,
        uint256 pairCreatedTs,
        uint256 priceUpdateCount
    ) external {
        RiskParamsLib.calculateIMRandMMR(
            marginRequirements,
            lastPairPrice,
            liquidationGapEma,
            pairVault,
            reopenGapEma,
            currentPrice,
            isContinuouslyTraded,
            pairCreatedTs,
            priceUpdateCount,
            0
        );
    }

    // ---- getters ----
    function sample() external view returns (uint256, uint256) {
        return (varianceSample.spotPrice, varianceSample.publishTs);
    }

    function gapEma() external view returns (int256, uint256, uint256) {
        return (liquidationGapEma.emaGapBp, liquidationGapEma.lastLiquidationTs, liquidationGapEma.decayedSize);
    }

    function reopenGap() external view returns (uint256, uint256) {
        return (reopenGapEma.gapEmaBp, reopenGapEma.lastObsTs);
    }

    function marginReqs() external view returns (uint256, uint256, uint256) {
        return (marginRequirements.imrBp, marginRequirements.mmrBp, marginRequirements.lastUpdateTs);
    }

    function cachedTargetBp() external view returns (uint256) {
        return pairVault.targetInsuranceRatioBp;
    }
}

contract RiskParamsStatefulTest is Test {
    uint256 internal constant SCALE = 1e18; // BAZAAR_SCALE
    uint256 internal constant BASE_TS = 10 days; // comfortable base so pairCreatedTs=0 sits past warmup

    RiskParamsStatefulHarness internal h;

    function setUp() public {
        h = new RiskParamsStatefulHarness();
        vm.warp(BASE_TS);
    }

    // =====================================================================
    // calculateVariance
    // =====================================================================

    /// @notice With no baseline observation there is no return to measure, so the first stored
    ///         price only seeds the sample and leaves the EMA at its prior value.
    function test_variance_noBaseline_seedsAndHoldsEma() public {
        h.setPairPrice({spotPrice: 0, updateTs: BASE_TS, emaVarianceBp: 777});
        assertEq(h.calcVariance(100e18, BASE_TS), 777, "no baseline -> EMA held");
        (uint256 sp, uint256 ts) = h.sample();
        assertEq(sp, 100e18, "baseline price seeded");
        assertEq(ts, BASE_TS, "baseline clock seeded");
    }

    /// @notice Under the 1-minute cooldown the EMA is returned verbatim (strict `<`) AND the
    ///         baseline is left in place, so the sampling interval keeps accumulating. Holding
    ///         the baseline is what makes a fast cadence defer a sample rather than drop it.
    function test_variance_withinCooldown_holdsEmaAndBaseline() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 7777});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS - 59});
        assertEq(h.calcVariance(110e18, BASE_TS), 7777, "cooldown holds prior EMA");
        (uint256 sp, uint256 ts) = h.sample();
        assertEq(sp, 100e18, "baseline price unchanged");
        assertEq(ts, BASE_TS - 59, "baseline clock unchanged");
    }

    /// @notice At exactly 60s elapsed the cooldown has passed and the EMA recomputes.
    ///         Pins the strict-`<` boundary and the exact first-step math (prior EMA = 0):
    ///         returnBp=1000, squared=1e6, effElapsed=60, annualized=1e6*365d/60=525_600_000_000,
    ///         alpha=60*1e4/(60+5d)=1, ema=525_600_000_000*1/1e4=52_560_000.
    function test_variance_cooldownBoundary_recomputes() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS - 60});
        assertEq(h.calcVariance(110e18, BASE_TS), 52_560_000, "recomputes at exactly 60s");
        (uint256 sp, uint256 ts) = h.sample();
        assertEq(sp, 110e18, "baseline advanced to the consumed price");
        assertEq(ts, BASE_TS, "baseline clock advanced");
    }

    /// @notice A sub-cooldown cadence defers the sample instead of discarding it: the baseline
    ///         survives the fast update, so the next update that clears the cooldown measures the
    ///         accumulated interval from the ORIGINAL baseline (100 -> 110 over 60s), not from the
    ///         intermediate 105 print.
    function test_variance_subCooldownCadence_defersRatherThanDiscards() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});

        assertEq(h.calcVariance(105e18, BASE_TS + 30), 0, "30s sample deferred");
        (uint256 sp, uint256 ts) = h.sample();
        assertEq(sp, 100e18, "baseline price survives the deferral");
        assertEq(ts, BASE_TS, "baseline clock survives the deferral");

        assertEq(h.calcVariance(110e18, BASE_TS + 60), 52_560_000, "deferred interval advances the EMA");
    }

    /// @notice The EMA cannot be pinned at 0 by update cadence. Every update here lands 30s after
    ///         the last one — under the cooldown — yet the EMA still advances, because deferral
    ///         lets every second update carry an accumulated 60s interval.
    function test_variance_fastCadence_cannotPinEmaAtZero() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});

        uint256 ema;
        for (uint256 i = 1; i <= 40; ++i) {
            // Period-4 ±10% path. Deferral consumes every second update, so the price must have
            // period 4 in `i` for consecutive CONSUMED samples to differ; a period-2 path would
            // alias onto a single price and measure a genuine zero return every time.
            uint256 price = i % 4 < 2 ? 100e18 : 110e18;
            uint256 pubTs = BASE_TS + i * 30;
            ema = h.calcVariance(price, pubTs);
            // Mirror the pair storing the returned EMA alongside the new price.
            h.setPairPrice({spotPrice: price, updateTs: pubTs, emaVarianceBp: ema});
        }
        assertGt(ema, 0, "fast cadence still advances the EMA");
    }

    /// @notice Up-move and down-move of the same magnitude yield identical variance
    ///         (the return is |Δ|/spot, sign-agnostic).
    function test_variance_upDownSymmetry() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS - 5 days});
        uint256 up = h.calcVariance(110e18, BASE_TS); // +10%
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS - 5 days});
        uint256 down = h.calcVariance(90e18, BASE_TS); // -10%
        assertEq(up, down, "symmetric in price direction");
        assertGt(up, 0, "non-trivial variance");
    }

    /// @notice Exact EMA after a +10% step over 5 days from a zero seed.
    ///         returnBp=1000, squared=1e6, effElapsed capped at 1 day -> annualized=1e6*365=365_000_000,
    ///         alpha=5d*1e4/(5d+5d)=5000, ema=365_000_000*5000/1e4=182_500_000.
    function test_variance_exactValue_fiveDayStep() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS - 5 days});
        assertEq(h.calcVariance(110e18, BASE_TS), 182_500_000, "exact EMA after 5-day 10% step");
    }

    /// @notice The effective-elapsed (1-day) and alpha (5000) caps both saturate beyond 5 days,
    ///         so a 5-day step and a 15-day step of identical magnitude produce the SAME variance.
    ///         Proves both clamps at once.
    function test_variance_effElapsedAndAlphaCaps_saturate() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS - 5 days});
        uint256 fiveDay = h.calcVariance(110e18, BASE_TS);

        uint256 later = BASE_TS + 10 days; // headroom for a 15-day-old baseline
        h.setVarianceSample({spotPrice: 100e18, publishTs: later - 15 days});
        uint256 fifteenDay = h.calcVariance(110e18, later);
        assertEq(fiveDay, fifteenDay, "effElapsed & alpha caps saturate identically");
        assertEq(fiveDay, 182_500_000, "and equal the pinned value");
    }

    // =====================================================================
    // reopen-gap observation (piggybacks on calculateVariance)
    // =====================================================================

    /// @notice A storage gap below REOPEN_GAP_MIN_STALENESS (1h) is on-chain call sparsity, not
    ///         a market discontinuity: its return feeds only the variance EMA and never the
    ///         reopen-gap floor.
    function test_reopenGap_below1h_ignored() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});
        h.calcVariance(110e18, BASE_TS + 1 hours - 1);
        (uint256 gap, uint256 obsTs) = h.reopenGap();
        assertEq(gap, 0, "sub-1h gap not observed");
        assertEq(obsTs, 0, "observation clock untouched");
    }

    /// @notice At exactly 1h the gap is eligible (>= boundary): |110-100|/100 = 1000bp, and the
    ///         observation clock stamps the reopen's publish time.
    function test_reopenGap_at1hBoundary_records() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});
        h.calcVariance(110e18, BASE_TS + 1 hours);
        (uint256 gap, uint256 obsTs) = h.reopenGap();
        assertEq(gap, 1000, "10% reopen gap recorded");
        assertEq(obsTs, BASE_TS + 1 hours, "observation clock stamped");
    }

    /// @notice Peak-hold: a quiet reopen decays the held value instead of averaging it down.
    ///         Nightly cadence — held 2000 observed at T0, close stored at T0+6.5h, reopen one
    ///         day after T0 with a 1% gap: decayed = 2000 x 180d/(180d+1d) = 1988, and the 100bp
    ///         observation loses the max.
    function test_reopenGap_quietReopen_decaysNotAverages() public {
        h.setReopenGap({gapEmaBp: 2000, lastObsTs: uint64(BASE_TS)});
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS + 6.5 hours, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS + 6.5 hours});
        h.calcVariance(101e18, BASE_TS + 1 days);
        (uint256 gap, uint256 obsTs) = h.reopenGap();
        assertEq(gap, 1988, "harmonic decay of the held peak, not a mean");
        assertEq(obsTs, BASE_TS + 1 days, "clock advances on every accepted observation");
    }

    /// @notice A reopen worse than the (decayed) held value ratchets the floor up to the new
    ///         observation.
    function test_reopenGap_severeReopen_ratchets() public {
        h.setReopenGap({gapEmaBp: 500, lastObsTs: uint64(BASE_TS)});
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS + 6.5 hours, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS + 6.5 hours});
        h.calcVariance(88e18, BASE_TS + 1 days); // -12% reopen
        (uint256 gap,) = h.reopenGap();
        assertEq(gap, 1200, "held value ratchets to the worse observation");
    }

    /// @notice The floor is capped at REOPEN_GAP_EMA_CAP_BP: a catastrophic 45% reopen stores
    ///         4000bp, not 4500.
    function test_reopenGap_capAt4000() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});
        h.calcVariance(145e18, BASE_TS + 9 hours);
        (uint256 gap,) = h.reopenGap();
        assertEq(gap, 4000, "capped at REOPEN_GAP_EMA_CAP_BP");
    }

    /// @notice The first-ever stored price has no baseline (spot 0): nothing to measure a reopen
    ///         against, so no observation is taken however long the gap.
    function test_reopenGap_noBaseline_skipped() public {
        h.setPairPrice({spotPrice: 0, updateTs: BASE_TS, emaVarianceBp: 0});
        h.calcVariance(100e18, BASE_TS + 3 days);
        (uint256 gap, uint256 obsTs) = h.reopenGap();
        assertEq(gap, 0, "no baseline, no observation");
        assertEq(obsTs, 0, "clock untouched");
    }

    // =====================================================================
    // updateLiquidationGapEmaBatch
    // =====================================================================

    /// @notice Zero fill size is a no-op (nothing seeded, timestamp untouched).
    function test_gapBatch_zeroSize_noOp() public {
        h.updateGapBatch(1_500e18, 0, 1);
        (int256 ema, uint256 ts, uint256 decayed) = h.gapEma();
        assertEq(ema, 0, "ema untouched");
        assertEq(ts, 0, "ts untouched");
        assertEq(decayed, 0, "decayedSize untouched");
    }

    /// @notice Zero count is a no-op.
    function test_gapBatch_zeroCount_noOp() public {
        h.updateGapBatch(1_500e18, 5e18, 0);
        (int256 ema,, uint256 decayed) = h.gapEma();
        assertEq(ema, 0, "ema untouched");
        assertEq(decayed, 0, "decayedSize untouched");
    }

    /// @notice First batch seeds EMA = size-weighted avg gap, decayedSize = totalFillSize.
    ///         sumGapTimesSize = 300bp * 5e18 -> batchGap = 300; decayedSize = 5e18.
    function test_gapBatch_firstBatch_seeds() public {
        h.updateGapBatch(int256(300) * 5e18, 5e18, 1);
        (int256 ema, uint256 ts, uint256 decayed) = h.gapEma();
        assertEq(ema, 300, "seeded to size-weighted avg gap");
        assertEq(decayed, 5e18, "decayedSize seeded to fill size");
        assertEq(ts, BASE_TS, "timestamp stamped");
    }

    /// @notice Second batch after exactly tau (3 days): alpha=5000, old size decays 50%.
    ///         decayedOld = 5e18*5000/1e4 = 2.5e18; new size 5e18; newDecayed = 7.5e18;
    ///         ema = (5e18*900 + 2.5e18*300)/7.5e18 = 5250e18/7.5e18 = 700.
    function test_gapBatch_secondBatch_timeDecayWeighted() public {
        h.setGapEma({emaGapBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 5e18});
        vm.warp(BASE_TS + 3 days);
        h.updateGapBatch(int256(900) * 5e18, 5e18, 1);
        (int256 ema,, uint256 decayed) = h.gapEma();
        assertEq(ema, 700, "size+time weighted EMA");
        assertEq(decayed, 7.5e18, "decayed old + new");
    }

    /// @notice Negative gap (liquidation filled through the mark against the vault) flows through
    ///         the signed path; a first batch seeds a negative EMA.
    function test_gapBatch_negativeGap_seedsNegative() public {
        h.updateGapBatch(int256(-300) * 4e18, 4e18, 1);
        (int256 ema,,) = h.gapEma();
        assertEq(ema, -300, "negative size-weighted gap");
    }

    /// @notice Signed batch-gap division truncates toward zero: -7 / 2 == -3 (not -4).
    function test_gapBatch_signedTruncationTowardZero() public {
        h.updateGapBatch(-7, 2, 1);
        (int256 ema,,) = h.gapEma();
        assertEq(ema, -3, "int division truncates toward zero");
    }

    /// @notice Alpha is capped at 5000 (50%): a batch 30 days later decays old size by exactly
    ///         50%, identical to the 3-day (uncapped-at-boundary) case. decayedOld = 8e18*0.5 = 4e18,
    ///         newDecayed = 4e18 + 2e18 = 6e18. Uncapped alpha (~9090) would leave far less.
    function test_gapBatch_alphaCap_at50pct() public {
        h.setGapEma({emaGapBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 8e18});
        vm.warp(BASE_TS + 30 days);
        h.updateGapBatch(0, 2e18, 1); // gap 0, size 2e18
        (,, uint256 decayed) = h.gapEma();
        assertEq(decayed, 6e18, "alpha capped at 50% -> old size halved");
    }

    // =====================================================================
    // calculateIMRandMMR
    // =====================================================================

    /// @notice Low vol / healthy fund / continuous / past warmup: the vol leg reads 150bp,
    ///         floored to MIN_STRESS_MOVE_BP = 200, so IMR = 2 x 200 = MIN_IMR_BP and the target
    ///         lands on INSURANCE_TARGET_BASE. The floor of the one reading carries both.
    function test_imr_minClamp_continuousPastWarmup() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18}); // 300bp ratio >= 200bp target
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr, uint256 mmr, uint256 ts) = h.marginReqs();
        assertEq(imr, 400, "floored at MIN_IMR_BP");
        assertEq(mmr, 200, "MMR = IMR/2 = the stress move");
        assertEq(ts, BASE_TS, "lastUpdateTs stamped");
        assertEq(h.cachedTargetBp(), 200, "target = the same stress move");
    }

    /// @notice A session-bound pair takes the WHOLE vol curve as its stress move where a 24/7
    ///         pair takes half: 300bp of stress move, IMR 600, target 300. That is the closure
    ///         prior, and it now reaches the fund target as well as margin.
    function test_imr_nonContinuousMultiplier() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18});
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: false, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr, uint256 mmr,) = h.marginReqs();
        assertEq(imr, 600, "the whole vol curve, doubled into IMR");
        assertEq(mmr, 300, "MMR = IMR/2");
        assertEq(h.cachedTargetBp(), 300, "target tracks the same 300bp");
    }

    /// @notice The reopen leg binds when the peak-hold exceeds the vol curve: calm vol reads
    ///         300bp, a learned 15% reopen gives a 1500bp stress move, so IMR = 3000bp and MMR
    ///         covers a full repeat of the demonstrated reopen. The fund sits at the (capped)
    ///         target here so the health leg reads 1x and the margin claim is exact.
    function test_imr_reopenGapBinds_doubled() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 100_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18}); // 1000bp ratio = the capped target
        h.setReopenGap({gapEmaBp: 1500, lastObsTs: uint64(BASE_TS)});
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: false, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr, uint256 mmr,) = h.marginReqs();
        assertEq(imr, 3000, "IMR = 2 x max(vol 300, reopen 1500)");
        assertEq(mmr, 1500, "MMR = the full demonstrated reopen");
        assertEq(h.cachedTargetBp(), 1_000, "a 15% stress move pins the 10% target cap");
    }

    /// @notice An underfunded pair raises MARGIN but never the target: the same 1500bp stress
    ///         move with the fund at 300bp against its 1000bp target reads a 2.4x health
    ///         multiplier on IMR, while the cached target is unmoved. Were the target taken from
    ///         the multiplied figure it would chase its own shortfall upward.
    function test_imr_fundHealthLiftsMarginNotTarget() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18}); // 300bp vs a 1000bp target
        h.setReopenGap({gapEmaBp: 1500, lastObsTs: uint64(BASE_TS)});
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: false, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr,,) = h.marginReqs();
        assertEq(imr, 7200, "2 x 1500 x 2.4 health multiplier");
        assertEq(h.cachedTargetBp(), 1_000, "the target reads the pair's risk, not the fund's level");
    }

    /// @notice A reopen gap below the (pre-doubling) vol estimate is inert: the estimators
    ///         compose by max BEFORE the closure prior doubles the winner, so the same event
    ///         is never charged through both.
    function test_imr_reopenGapBelowVolEstimate_noEffect() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18});
        h.setReopenGap({gapEmaBp: 250, lastObsTs: uint64(BASE_TS)});
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: false, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr,,) = h.marginReqs();
        assertEq(imr, 600, "reopen below the vol curve is inert: 2 x max(300, 250)");
        assertEq(h.cachedTargetBp(), 300, "and inert in the target for the same reason");
    }

    /// @notice A cap-sized reopen gap (40%) doubles to exactly MAX_IMR_BP: a catastrophic
    ///         reopen pins the pair at the 80% clamp (1.25x max leverage) until the peak-hold
    ///         decays, with MMR at the full 40% cap.
    function test_imr_cappedGapDoublesToMaxClamp() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 100_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18}); // at the capped target, so the health leg is 1x
        h.setReopenGap({gapEmaBp: 4000, lastObsTs: uint64(BASE_TS)});
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: false, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr, uint256 mmr,) = h.marginReqs();
        assertEq(imr, 8000, "the reopen cap is MAX_STRESS_MOVE_BP, so 2x it is exactly MAX_IMR_BP");
        assertEq(mmr, 4000, "MMR = the 40% gap cap");
        assertEq(h.cachedTargetBp(), 1_000, "the target stops at its own 10% ceiling");
    }

    /// @notice Continuously traded pairs never consume the reopen-gap floor, whatever is stored.
    function test_imr_reopenGapIgnoredForContinuous() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18});
        h.setReopenGap({gapEmaBp: 4000, lastObsTs: uint64(BASE_TS)});
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr,,) = h.marginReqs();
        assertEq(imr, 400, "continuous pair sticks to the vol curve");
    }

    /// @notice The volatility leg alone can exceed 3x: at its 6x saturation variance the
    ///         composed IMR is 300 x 6 = 1800bp for a continuous pair. The other legs read 1x —
    ///         which at extreme variance requires the fund to sit at the vol-RAISED max target
    ///         (10% of OI), not merely above the calm-market one.
    function test_imr_volCapAt6x_flowsThroughCurve() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 247_000_000});
        h.setVault({insuranceFundBalance: 100_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18}); // 10% ratio = max target
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr, uint256 mmr,) = h.marginReqs();
        assertEq(imr, 1800, "vol leg saturates at 6x: 300 x 6");
        assertEq(mmr, 900, "MMR = IMR/2");
    }

    /// @notice Saturating vol (6x -> a 900bp stress move) plus a 500bp realized gap gives
    ///         1400bp; an empty fund's 3x health multiplier takes 2 x 1400 x 3 = 8400bp, clamped
    ///         to MAX_IMR_BP. The target, which never sees the health leg, stops at its own 10%
    ///         ceiling.
    function test_imr_maxClamp() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 247_000_000});
        h.setGapEma({emaGapBp: 500, lastLiquidationTs: BASE_TS, decayedSize: 1e18});
        h.setVault({insuranceFundBalance: 0, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18}); // 0bp ratio -> 3x
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr, uint256 mmr,) = h.marginReqs();
        assertEq(imr, 8000, "clamped at MAX_IMR_BP");
        assertEq(mmr, 4000, "MMR = IMR/2");
        assertEq(h.cachedTargetBp(), 1_000, "target capped at INSURANCE_TARGET_MAX");
    }

    /// @notice A realized liquidation gap ADDS to the stress move at its own size rather than
    ///         multiplying it, so the same 300bp of bad fills costs the same 300bp of
    ///         maintenance margin whatever the volatility regime. Fund at the target throughout,
    ///         so the health leg reads 1x.
    function test_imr_liquidationGapAddsFlatAcrossVolRegimes() public {
        // Calm pair: stress move 150 + 300 = 450 -> IMR 900, target 450.
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setGapEma({emaGapBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 1e18});
        h.setVault({insuranceFundBalance: 100_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18});
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 calmImr,,) = h.marginReqs();
        assertEq(calmImr, 900, "calm: 2 x (150 + 300)");
        assertEq(h.cachedTargetBp(), 450, "target tracks the same reading");

        // Volatile pair, same gap: stress move 450 + 300 = 750 -> IMR 1500. The gap contributed
        // exactly 300bp of stress move in both regimes.
        vm.warp(BASE_TS + 60);
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: BazaarTypes.VARIANCE_EXTREME});
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 wildImr,,) = h.marginReqs();
        assertEq(wildImr, 1500, "volatile: 2 x (450 + 300)");
        assertEq(wildImr - calmImr, 600, "the vol leg moved 600; the gap's 600 is unchanged");
        assertEq(h.cachedTargetBp(), 750, "target still one-for-one with the stress move");
    }

    /// @notice Continuous pair during warmup: 400bp computed value floored to WARMUP_MIN_IMR_BP = 2000.
    function test_imr_warmupFloor_continuous() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18});
        // pairCreatedTs = now (elapsed 0 < 5 days) AND priceUpdateCount 0 < 50k -> warmup active
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: BASE_TS, priceUpdateCount: 0});
        (uint256 imr, uint256 mmr,) = h.marginReqs();
        assertEq(imr, 2000, "warmup floor 20% IMR = 5x");
        assertEq(mmr, 1000, "MMR = IMR/2");
    }

    /// @notice Non-continuous during warmup: floor is 2000 * 2 = 4000bp (2.5x max leverage; a
    ///         freshly listed pair has no reopen-gap history, so the warmup floor carries the
    ///         cold-start gap risk).
    function test_imr_warmupFloor_nonContinuous() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18});
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: false, pairCreatedTs: BASE_TS, priceUpdateCount: 0});
        (uint256 imr, uint256 mmr,) = h.marginReqs();
        assertEq(imr, 4000, "non-continuous warmup floor = 40% IMR");
        assertEq(mmr, 2000, "MMR = IMR/2");
        assertEq(h.cachedTargetBp(), 300, "the warmup floor lifts margin only, never the target");
    }

    /// @notice Within the 1-minute IMR cooldown the call early-returns and leaves margins untouched;
    ///         at exactly +60s it recomputes. Pins the strict-`<` cooldown boundary.
    function test_imr_cooldownBoundary() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18});
        h.setMarginReqs({imrBp: 1234, mmrBp: 617, lastUpdateTs: BASE_TS});

        // Same timestamp: block.timestamp < lastUpdateTs + 60 -> early return, sentinel preserved.
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr0,, uint256 ts0) = h.marginReqs();
        assertEq(imr0, 1234, "cooldown blocks recompute");
        assertEq(ts0, BASE_TS, "lastUpdateTs unchanged during cooldown");
        // The target is cached BEFORE the cooldown gate, so the ADL reserve tracks it even on a
        // call that leaves margin alone.
        assertEq(h.cachedTargetBp(), 200, "target refreshed despite the cooldown");

        // Exactly +60s: no longer < cooldown -> recomputes to the floored 400.
        vm.warp(BASE_TS + 60);
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr1,, uint256 ts1) = h.marginReqs();
        assertEq(imr1, 400, "recomputes exactly at cooldown boundary");
        assertEq(ts1, BASE_TS + 60, "lastUpdateTs advanced");
    }
}
