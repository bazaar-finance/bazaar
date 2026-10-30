// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @dev Storage host for the STATEFUL RiskParamsLib functions: `calculateVariance` (the
///      volatility EMA), `updateLiquidationGapEmaBatch` (the slippage and drift EMAs),
///      `calculateIMRandMMR` (the margin curve and the cached fund target) and
///      `liquidationImrBp` (the rate liquidate judges by, from the same curve). Together these are
///      the volatility/liquidation → leverage-limit feedback loop.
contract RiskParamsStatefulHarness {
    BazaarTypes.MarginRequirements internal marginRequirements;
    BazaarTypes.PairPrice internal lastPairPrice;
    BazaarTypes.VarianceSample internal varianceSample;
    BazaarTypes.LiquidationGapEma internal liquidationGapEma;
    BazaarTypes.Vault internal pairVault;
    BazaarTypes.ReopenGapEma internal reopenGapEma;
    BazaarTypes.MmrSampleBuffer internal mmrBuffer;
    bool internal isContinuouslyTraded; // false by default: stores behave as on a session pair

    // ---- setters ----
    function setContinuouslyTraded(bool continuous) external {
        isContinuouslyTraded = continuous;
    }

    function setPairPrice(uint256 spotPrice, uint256 updateTs, uint256 emaVarianceBp) external {
        lastPairPrice.spotPrice = spotPrice;
        lastPairPrice.updateTs = updateTs;
        lastPairPrice.emaVarianceBp = emaVarianceBp;
    }

    function setVarianceSample(uint256 spotPrice, uint256 publishTs) external {
        varianceSample.spotPrice = uint192(spotPrice);
        varianceSample.publishTs = uint64(publishTs);
    }

    /// @dev Seeds the slippage line in whole basis points, and every timestamp at
    ///      `lastLiquidationTs`, as one batch at that instant would leave them.
    function setGapEma(uint256 emaSlippageBp, uint256 lastLiquidationTs, uint256 decayedSize) external {
        liquidationGapEma.slippage = emaSlippageBp * RiskParamsLib.GAP_EMA_SCALE;
        liquidationGapEma.slippageAnchorTs = uint64(lastLiquidationTs);
        liquidationGapEma.driftAnchorTs = uint64(lastLiquidationTs);
        liquidationGapEma.lastLiquidationTs = uint64(lastLiquidationTs);
        liquidationGapEma.decayedSize = decayedSize;
    }

    function setDriftEma(uint256 emaDriftBp) external {
        liquidationGapEma.drift = emaDriftBp * RiskParamsLib.GAP_EMA_SCALE;
    }

    /// @dev Moves the two value lines' anchors and the batch clock apart.
    function setGapClocks(uint256 slippageAnchorTs, uint256 driftAnchorTs, uint256 batchTs) external {
        liquidationGapEma.slippageAnchorTs = uint64(slippageAnchorTs);
        liquidationGapEma.driftAnchorTs = uint64(driftAnchorTs);
        liquidationGapEma.lastLiquidationTs = uint64(batchTs);
    }

    /// @dev The stored drift line at full precision, GAP_EMA_SCALE units per basis point.
    function rawDrift() external view returns (uint256) {
        return liquidationGapEma.drift;
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
        reopenGapEma.gapEmaBp = uint128(gapEmaBp);
        reopenGapEma.lastObsTs = lastObsTs;
    }

    /// @dev Stands in for a live market's latest stored price, where the fade clock stops.
    function setLastPriceTs(uint256 updateTs) external {
        lastPairPrice.updateTs = updateTs;
    }

    // ---- callers ----
    function calcVariance(uint256 price, uint256 publishTime) external returns (uint256) {
        return RiskParamsLib.calculateVariance(
            lastPairPrice, varianceSample, reopenGapEma, liquidationGapEma, price, publishTime, isContinuouslyTraded
        );
    }

    /// @dev What BazaarPair._buildAndStorePairPrice does with a newer price: advance the
    ///      estimators off the outgoing record, then overwrite it. calcVariance above stops short
    ///      of the overwrite, so a test that reads the fade after it would see a stale record.
    function storePrice(uint256 price, uint256 publishTime) external {
        uint256 emaVarianceBp = RiskParamsLib.calculateVariance(
            lastPairPrice, varianceSample, reopenGapEma, liquidationGapEma, price, publishTime, isContinuouslyTraded
        );
        lastPairPrice.spotPrice = price;
        lastPairPrice.emaVarianceBp = emaVarianceBp;
        lastPairPrice.updateTs = publishTime;
    }

    /// @dev Slippage-only batch: the drift accumulator is left at zero.
    function updateGapBatch(int256 sumSlipTimesSize, uint256 totalFillSize, uint256 count) external {
        _updateBatch(sumSlipTimesSize, 0, totalFillSize, count);
    }

    function updateGapBatchBoth(
        int256 sumSlipTimesSize,
        int256 sumDriftTimesSize,
        uint256 totalFillSize,
        uint256 count
    ) external {
        _updateBatch(sumSlipTimesSize, sumDriftTimesSize, totalFillSize, count);
    }

    /// @dev `count` is accepted so call sites read as a batch, but the library weights purely by
    ///      size: a batch with fills always carries a positive total size. The prior's weight
    ///      floor reads the vault's open interest, zero unless a test sets it.
    function _updateBatch(int256 sumSlip, int256 sumDrift, uint256 totalFillSize, uint256) private {
        RiskParamsLib.updateLiquidationGapEmaBatch(liquidationGapEma, pairVault, sumSlip, sumDrift, totalFillSize);
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
            mmrBuffer,
            currentPrice,
            isContinuouslyTraded,
            pairCreatedTs,
            priceUpdateCount,
            0
        );
    }

    function liquidationImrBp(
        uint256 currentPrice,
        bool isContinuouslyTraded,
        uint256 pairCreatedTs,
        uint256 priceUpdateCount
    ) external returns (uint256) {
        return RiskParamsLib.liquidationImrBp(
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
    function ring() external view returns (uint256 count, uint256 lastSampleTs, uint256 intervalMinBp) {
        return (mmrBuffer.count, mmrBuffer.lastSampleTs, mmrBuffer.intervalMinBp);
    }

    function trailingOiSize() external view returns (uint256) {
        return pairVault.trailingOiSize;
    }

    function reserveAt(uint256 price) external view returns (uint256) {
        return RiskParamsLib.adlReserve(pairVault, price);
    }

    function sample() external view returns (uint256, uint256) {
        return (varianceSample.spotPrice, varianceSample.publishTs);
    }

    /// @dev The stored slippage line in whole basis points, its anchor, and the accumulated size.
    ///      The stored line equals the reading only at its anchor.
    function gapEma() external view returns (int256, uint256, uint256) {
        return (
            int256(liquidationGapEma.slippage / RiskParamsLib.GAP_EMA_SCALE),
            liquidationGapEma.slippageAnchorTs,
            liquidationGapEma.decayedSize
        );
    }

    function driftEma() external view returns (int256) {
        return int256(liquidationGapEma.drift / RiskParamsLib.GAP_EMA_SCALE);
    }

    /// @dev The two value lines' anchors and the batch clock that ages the weight.
    function gapClocks() external view returns (uint256 slippageAnchorTs, uint256 driftAnchorTs, uint256 batchTs) {
        return
            (liquidationGapEma.slippageAnchorTs, liquidationGapEma.driftAnchorTs, liquidationGapEma.lastLiquidationTs);
    }

    /// @dev The stored slippage line at full precision, GAP_EMA_SCALE units per basis point.
    function rawSlippage() external view returns (uint256) {
        return liquidationGapEma.slippage;
    }

    function reopenGap() external view returns (uint256, uint256) {
        return (reopenGapEma.gapEmaBp, reopenGapEma.lastObsTs);
    }

    function lastJumpTs() external view returns (uint256) {
        return reopenGapEma.lastJumpTs;
    }

    function marginReqs() external view returns (uint256, uint256, uint256) {
        return (marginRequirements.imrBp, marginRequirements.mmrBp, marginRequirements.lastUpdateTs);
    }

    function cachedTargetBp() external view returns (uint256) {
        return pairVault.targetInsuranceRatioBp;
    }

    function fadedGap() external view returns (int256 slippageBp) {
        (slippageBp,) = RiskParamsLib.fadedLiquidationGapsBp(liquidationGapEma, lastPairPrice);
    }

    function fadedDrift() external view returns (int256 driftBp) {
        (, driftBp) = RiskParamsLib.fadedLiquidationGapsBp(liquidationGapEma, lastPairPrice);
    }
}

contract RiskParamsStatefulTest is Test {
    uint256 internal constant SCALE = 1e18; // BAZAAR_SCALE
    uint256 internal constant BASE_TS = 30 days; // comfortable base so pairCreatedTs=0 sits past warmup

    RiskParamsStatefulHarness internal h;

    function setUp() public {
        h = new RiskParamsStatefulHarness();
        vm.warp(BASE_TS);
    }

    /// @dev Moves the clock the way a live market does: its latest stored price lands with it, so
    ///      the fade clock, which stops at the last stored price, runs all the way to `ts`.
    function _liveAt(uint256 ts) internal {
        vm.warp(ts);
        h.setLastPriceTs(ts);
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

    // =====================================================================
    // price-jump stamp (piggybacks on calculateVariance)
    // =====================================================================

    /// @notice A stored price MIN_STRESS_MOVE_BP (2%) from the variance sample stamps its publish
    ///         time as the last jump, even inside the sampling cooldown, where the sample itself
    ///         does not move.
    function test_priceJump_atThreshold_stampsEvenInsideTheCooldown() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});
        h.calcVariance(98e18, BASE_TS + 10);
        assertEq(h.lastJumpTs(), BASE_TS + 10, "a 2% move is a jump");
    }

    /// @notice A move just under the threshold is not a jump, and the next store inside the same
    ///         cooldown is judged against the unchanged sample: a move cannot be stored in
    ///         sub-threshold steps any faster than the sample follows.
    function test_priceJump_underThresholdIgnored_butStepsAreJudgedAgainstTheSample() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});
        h.storePrice(98.01e18, BASE_TS + 10); // 1.99% under the sample
        assertEq(h.lastJumpTs(), 0, "a 1.99% move is not a jump");
        h.storePrice(96.5e18, BASE_TS + 20); // a second step: 3.5% under the same sample
        assertEq(h.lastJumpTs(), BASE_TS + 20, "the second step is judged against the old sample");
    }

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
    ///         day after T0 with a 1% gap: decayed = 2000 x 130d/(130d+1d) = 1984, and the 100bp
    ///         observation loses the max.
    function test_reopenGap_quietReopen_decaysNotAverages() public {
        h.setReopenGap({gapEmaBp: 2000, lastObsTs: uint64(BASE_TS)});
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS + 6.5 hours, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS + 6.5 hours});
        h.calcVariance(101e18, BASE_TS + 1 days);
        (uint256 gap, uint256 obsTs) = h.reopenGap();
        assertEq(gap, 1984, "harmonic decay of the held peak, not a mean");
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
    ///         the cap, not the whole 4500bp it printed. Severity past the cap buys neither a
    ///         higher maintenance level nor a longer time under one.
    function test_reopenGap_capsCatastrophicReopen() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});
        h.calcVariance(145e18, BASE_TS + 9 hours);
        (uint256 gap,) = h.reopenGap();
        assertEq(gap, RiskParamsLib.REOPEN_GAP_EMA_CAP_BP, "capped at REOPEN_GAP_EMA_CAP_BP");
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

    /// @notice Zero fill size is a no-op (nothing seeded, timestamp untouched). Fill size is the
    ///         sole gate: a walk accumulates both sums and the size together on every eligible
    ///         fill, so an empty size is exactly the case where there is nothing to weight — and
    ///         it is also what protects the batch averages from dividing by zero.
    function test_gapBatch_zeroSize_noOp() public {
        h.updateGapBatch(1_500e18, 0, 1);
        (int256 ema,, uint256 decayed) = h.gapEma();
        assertEq(ema, 0, "ema untouched");
        assertEq(decayed, 0, "decayedSize untouched");
        (uint256 slipAnchor, uint256 driftAnchor, uint256 batchTs) = h.gapClocks();
        assertEq(slipAnchor + driftAnchor + batchTs, 0, "no clock stamped");
    }

    /// @notice With no open interest the prior's weight floor is zero, so the first batch is
    ///         copied in: EMA = size-weighted avg gap, decayedSize = totalFillSize.
    ///         sumGapTimesSize = 300bp * 5e18 -> batchGap = 300; decayedSize = 5e18.
    function test_gapBatch_firstBatch_seeds() public {
        h.updateGapBatch(int256(300) * 5e18, 5e18, 1);
        (int256 ema, uint256 ts, uint256 decayed) = h.gapEma();
        assertEq(ema, 300, "seeded to size-weighted avg gap");
        assertEq(decayed, 5e18, "decayedSize seeded to fill size");
        assertEq(ts, BASE_TS, "timestamp stamped");
    }

    /// @notice One batch advances BOTH legs off the same fills, so the slippage the margin curve
    ///         reads and the drift the fund target reads always describe the same liquidations.
    ///         Their magnitudes are independent — a thin book can meet a market still short of
    ///         bankruptcy, and a deep one a market that has overrun it — which is why they are
    ///         measured apart and share only the weighting. No open interest, so no floor.
    function test_gapBatch_oneBatchSeedsBothLegs() public {
        h.updateGapBatchBoth({
            sumSlipTimesSize: int256(300) * 2e18, sumDriftTimesSize: int256(150) * 2e18, totalFillSize: 2e18, count: 2
        });

        (int256 slip,, uint256 decayed) = h.gapEma();
        assertEq(slip, 300, "slippage seeded to the size-weighted average");
        assertEq(h.driftEma(), 150, "drift seeded to its own size-weighted average");
        assertEq(decayed, 2e18, "one accumulated size serves both legs");
        (uint256 slipAnchor, uint256 driftAnchor, uint256 batchTs) = h.gapClocks();
        assertEq(slipAnchor, BASE_TS, "a first batch anchors the slippage line at its block");
        assertEq(driftAnchor, BASE_TS, "and the drift line");
        assertEq(batchTs, BASE_TS, "and stamps the batch clock");
    }

    /// @notice Both legs fade with the same constant from the batch that recorded them, so the
    ///         margin curve and the fund target agree about how old the same episode is.
    function test_gapEma_bothLegsFadeOnOneClock() public {
        h.updateGapBatchBoth({
            sumSlipTimesSize: int256(400) * 1e18, sumDriftTimesSize: int256(800) * 1e18, totalFillSize: 1e18, count: 1
        });

        _liveAt(BASE_TS + RiskParamsLib.LIQUIDATION_GAP_EMA_TAU);
        assertEq(h.fadedGap(), 200, "slippage halves one tau after the batch");
        assertEq(h.fadedDrift(), 400, "drift halves on the same clock");
    }

    /// @notice Second batch after exactly tau (3 days). The prior loses half its WEIGHT
    ///         (alpha = 5000: decayedOld = 2.5e18, newDecayed = 7.5e18) and half its VALUE (the
    ///         read fade at tau: 300 -> 150), so the line reads
    ///         (5e18*900 + 2.5e18*150)/7.5e18 = 4875e18/7.5e18 = 650.
    ///         Of that, 50 is the prior's survivor, three days old, and 600 is new, so the anchor
    ///         keeps 50/650 of the three days: it moves to 19,939 s before the batch (rounded up).
    function test_gapBatch_secondBatch_timeDecayWeighted() public {
        h.setGapEma({emaSlippageBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 5e18});
        _liveAt(BASE_TS + 3 days);
        h.updateGapBatch(int256(900) * 5e18, 5e18, 1);
        assertEq(h.fadedGap(), 650, "size+time weighted EMA against the faded prior");
        (,, uint256 decayed) = h.gapEma();
        assertEq(decayed, 7.5e18, "decayed old + new");
        (uint256 slipAnchor,, uint256 batchTs) = h.gapClocks();
        assertEq(slipAnchor, BASE_TS + 3 days - 19_939, "the survivor keeps its share of the age");
        assertEq(batchTs, BASE_TS + 3 days, "the weight's clock is the batch");
    }

    // -------- the prior's weight floor --------

    /// @dev Per-side open interest the floor tests run against: 1% of it is 10,000 units.
    uint256 internal constant FLOOR_OI = 1_000_000e18;
    uint256 internal constant FLOOR_SIZE = FLOOR_OI * RiskParamsLib.LIQ_GAP_PRIOR_FLOOR_BP / 10_000;

    /// @notice A batch is weighed against at least 1% of per-side open interest, so on a pair with
    ///         no history the first batch does not become the whole reading: a batch the size of
    ///         the floor moves both legs exactly halfway from zero.
    ///         slippage = (10,000 x 500 + 10,000 x 0) / 20,000 = 250; drift likewise 300 -> 150.
    function test_gapBatch_priorFloor_firstBatchMovesByItsShareOfTheBook() public {
        h.setVault(0, FLOOR_OI, FLOOR_OI);
        h.updateGapBatchBoth({
            sumSlipTimesSize: int256(500) * int256(FLOOR_SIZE),
            sumDriftTimesSize: int256(300) * int256(FLOOR_SIZE),
            totalFillSize: FLOOR_SIZE,
            count: 1
        });
        (int256 slip, uint256 ts, uint256 decayed) = h.gapEma();
        assertEq(slip, 250, "half of 500: the floor weighs as much as the batch");
        assertEq(h.driftEma(), 150, "drift is weighed against the same floor");
        assertEq(decayed, 2 * FLOOR_SIZE, "floor + batch");
        assertEq(ts, BASE_TS, "clock stamped");
    }

    /// @notice A dust batch on a fresh pair moves the reading by its share of the book, which
    ///         reads as zero: 0.001 units at the band cap against a 10,000-unit floor is
    ///         500 x 1e15 / (1e22 + 1e15), about 0.00005bp. This is the self-dealt unload — a
    ///         liquidator buying its own dust estate back from the vault at the band edge —
    ///         recording only that share.
    function test_gapBatch_priorFloor_dustBatchReadsAsZeroOnAFreshPair() public {
        h.setVault(0, FLOOR_OI, FLOOR_OI);
        h.updateGapBatch(int256(500) * 1e15, 1e15, 1);
        assertEq(h.fadedGap(), 0, "a dust batch cannot seed the reading");
        assertEq(h.rawSlippage(), uint256(500e15) * 1e18 / (FLOOR_SIZE + 1e15), "it records its share, unrounded");
        (,, uint256 decayed) = h.gapEma();
        assertEq(decayed, FLOOR_SIZE + 1e15, "the floor carries the weight");
    }

    /// @notice One large batch cannot take the reading over either: 5% of the book at the band cap
    ///         moves it 5/6 of the way, 50,000 x 500 / (10,000 + 50,000) = 416.
    function test_gapBatch_priorFloor_largeBatchMovesByItsShareNotWholly() public {
        h.setVault(0, FLOOR_OI, FLOOR_OI);
        h.updateGapBatch(int256(500) * 50_000e18, 50_000e18, 1);
        (int256 slip,,) = h.gapEma();
        assertEq(slip, 416, "50,000 x 500 / 60,000");
    }

    /// @notice The floor also holds up a prior whose accumulated weight sits below it: 1 unit of
    ///         prior at 300bp meets a 10,000-unit batch at 900bp in the same block (no discount,
    ///         no fade). Against the floor: (10,000 x 900 + 10,000 x 300) / 20,000 = 600. Against
    ///         the single unit alone it would have landed at 899.
    function test_gapBatch_priorFloor_holdsUpAPriorBelowIt() public {
        h.setVault(0, FLOOR_OI, FLOOR_OI);
        h.setGapEma({emaSlippageBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 1e18});
        h.updateGapBatch(int256(900) * int256(FLOOR_SIZE), FLOOR_SIZE, 1);
        (int256 slip,, uint256 decayed) = h.gapEma();
        assertEq(slip, 600, "the prior weighs the floor, not its single unit");
        assertEq(decayed, 2 * FLOOR_SIZE, "floor + batch");
    }

    /// @notice Accumulated weight above the floor is used as it is — the floor is a minimum, not a
    ///         replacement. 50,000 units of prior at 300bp meet a 10,000-unit batch at 900bp in
    ///         the same block: (10,000 x 900 + 50,000 x 300) / 60,000 = 400.
    function test_gapBatch_priorFloor_accumulatedWeightAboveItIsKept() public {
        h.setVault(0, FLOOR_OI, FLOOR_OI);
        h.setGapEma({emaSlippageBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 50_000e18});
        h.updateGapBatch(int256(900) * int256(FLOOR_SIZE), FLOOR_SIZE, 1);
        (int256 slip,, uint256 decayed) = h.gapEma();
        assertEq(slip, 400, "the larger of the two weights");
        assertEq(decayed, 60_000e18, "prior + batch");
    }

    /// @notice The floor reads per-side open interest, the larger side: a one-sided book of
    ///         1,000,000 long against nothing short floors at the same 10,000 units.
    function test_gapBatch_priorFloor_readsTheLargerSide() public {
        h.setVault(0, FLOOR_OI, 0);
        h.updateGapBatch(int256(500) * int256(FLOOR_SIZE), FLOOR_SIZE, 1);
        (int256 slip,, uint256 decayed) = h.gapEma();
        assertEq(slip, 250, "halfway: the long side alone sets the floor");
        assertEq(decayed, 2 * FLOOR_SIZE, "floor + batch");
    }

    /// @notice The measurement floors every fill at zero, so no unload hands the batch a
    ///         negative sum; this pins that the library neither wraps nor rejects one but records
    ///         it as a zero-cost sample, at full weight.
    function test_gapBatch_negativeSum_recordsZero() public {
        h.updateGapBatchBoth({
            sumSlipTimesSize: int256(-300) * 4e18, sumDriftTimesSize: -7, totalFillSize: 4e18, count: 1
        });
        (int256 ema,, uint256 decayed) = h.gapEma();
        assertEq(ema, 0, "a negative slippage sum records as zero");
        assertEq(h.driftEma(), 0, "and so does a negative drift sum");
        assertEq(decayed, 4e18, "at its full weight");
    }

    /// @notice Alpha is capped at 5000 (50%): a batch 30 days later decays old size by exactly
    ///         50%, identical to the 3-day (uncapped-at-boundary) case. decayedOld = 8e18*0.5 = 4e18,
    ///         newDecayed = 4e18 + 2e18 = 6e18. Uncapped alpha (~9090) would leave far less.
    function test_gapBatch_alphaCap_at50pct() public {
        h.setGapEma({emaSlippageBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 8e18});
        _liveAt(BASE_TS + 30 days);
        h.updateGapBatch(0, 2e18, 1); // gap 0, size 2e18
        (,, uint256 decayed) = h.gapEma();
        assertEq(decayed, 6e18, "alpha capped at 50% -> old size halved");
        // The weight cap does not cap the VALUE fade: 30 days on, the prior reads
        // 300 x 3d / 33d = 27.3, so the blend lands at 4e18 x 27.3 / 6e18 = 18.2.
        assertEq(h.fadedGap(), 18, "the prior faded to 27 before the blend");
    }

    /// @notice Between batches the value the curves read fades harmonically with the time since
    ///         the last one, on a market storing prices as it goes: half at tau, a quarter at
    ///         3 tau. The store itself is untouched until the next batch; only the read moves.
    function test_gapEma_readFadesBetweenBatches() public {
        h.setGapEma({emaSlippageBp: 2400, lastLiquidationTs: BASE_TS, decayedSize: 1e18});
        _liveAt(BASE_TS);
        assertEq(h.fadedGap(), 2400, "no time elapsed, no fade");
        _liveAt(BASE_TS + 3 days);
        assertEq(h.fadedGap(), 1200, "halved at tau");
        _liveAt(BASE_TS + 9 days);
        assertEq(h.fadedGap(), 600, "a quarter at 3 tau");
        _liveAt(BASE_TS + 30 days);
        assertEq(h.fadedGap(), 218, "2400 x 3d / 33d");
        _liveAt(BASE_TS + 365 days);
        assertEq(h.fadedGap(), 19, "a year on, essentially gone");
        (int256 stored,,) = h.gapEma();
        assertEq(stored, 2400, "the store is only rewritten by a batch");
    }

    // -------- fade suspension across closures --------

    /// @notice A weekend does not age the readings. A liquidation needs a price stored within
    ///         MAX_LIQUIDATION_PRICE_AGE, so a stretch with none stored is one in which no
    ///         liquidation arrived — and on a live pair one in which none could have — and the fade
    ///         would otherwise read that silence as evidence the maintenance level is holding.
    ///         Friday close to Monday open is 65.5h against a 3-day tau, which would nearly halve
    ///         a reading on no information at all.
    function test_fadeSuspend_weekendDoesNotAgeTheReadings() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});
        h.setGapEma({emaSlippageBp: 2400, lastLiquidationTs: BASE_TS, decayedSize: 1e18});
        h.setDriftEma(1200);

        // Reopen 65.5h later: the stored price ends the closure, and the anchor moves with it.
        uint256 reopen = BASE_TS + 65 hours + 30 minutes;
        vm.warp(reopen);
        h.storePrice(101e18, reopen);

        assertEq(h.fadedGap(), 2400, "slippage unfaded across the closure");
        assertEq(h.fadedDrift(), 1200, "drift unfaded on the same anchor");
        (, uint256 anchor,) = h.gapEma();
        assertEq(anchor, reopen, "anchor advanced by the whole gap");
    }

    /// @notice A closure in progress does not age the readings either, and so neither does margin
    ///         recomputed inside it. Nothing is stored while the venue is shut, but the stale
    ///         fallback still lets refreshPrice and the other priced entry points recompute the
    ///         curve. A read that ran to the block would have that Sunday recompute store a
    ///         maintenance level the Monday reopen raises again, and the lagged-MMR ring would
    ///         carry the understated rate into the next day's liquidation checks. Pinned as one
    ///         number from the Friday close, through Sunday, to the Monday reopen.
    function test_fadeSuspend_closureInProgressHoldsMargin() public {
        uint256 close = BASE_TS + 1 hours; // the batch at BASE_TS, the venue shuts an hour later
        h.setGapEma({emaSlippageBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 1e18});
        h.setPairPrice({spotPrice: 100e18, updateTs: close, emaVarianceBp: 0});
        h.setVault(1e26, 1_000_000e18, 1_000_000e18); // 100% coverage: fund-health leg at 1x

        vm.warp(close);
        h.calcIMRandMMR(100e18, false, 0, 25_000);
        (, uint256 mmrAtClose,) = h.marginReqs();
        assertEq(h.fadedGap(), 295, "one hour of trading since the batch: 300 x 72h / 73h");
        assertEq(mmrAtClose, 595, "vol leg 300 + slippage 295");

        vm.warp(BASE_TS + 42 hours); // Sunday: nothing can be stored
        h.calcIMRandMMR(100e18, false, 0, 25_000);
        (, uint256 mmrSunday,) = h.marginReqs();
        assertEq(h.fadedGap(), 295, "the closure has not aged the reading");
        assertEq(mmrSunday, mmrAtClose, "nor the maintenance level recomputed inside it");

        uint256 reopen = BASE_TS + 66 hours + 30 minutes;
        vm.warp(reopen);
        h.storePrice(100e18, reopen);
        h.calcIMRandMMR(100e18, false, 0, 25_000);
        (, uint256 mmrAtReopen,) = h.marginReqs();
        assertEq(h.fadedGap(), 295, "the reopen store skips the whole closure");
        assertEq(mmrAtReopen, mmrAtClose, "so margin reads one number across the weekend");
    }

    /// @notice Only the closure is skipped, not the trading time around it. An overnight followed
    ///         by a tau of stores never more than six hours apart fades exactly as one tau, so
    ///         suspension preserves evidence rather than freezing it.
    function test_fadeSuspend_tradingTimeStillFades() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});
        h.setGapEma({emaSlippageBp: 2400, lastLiquidationTs: BASE_TS, decayedSize: 1e18});

        uint256 reopen = BASE_TS + 17 hours + 30 minutes; // one equity overnight
        vm.warp(reopen);
        h.storePrice(101e18, reopen);
        assertEq(h.fadedGap(), 2400, "the overnight itself is not tradeable time");

        for (uint256 i = 1; i <= 12; ++i) {
            uint256 t = reopen + i * 6 hours;
            vm.warp(t);
            h.storePrice(101e18, t);
        }
        (, uint256 anchor,) = h.gapEma();
        assertEq(anchor, reopen, "no store gap reached the threshold");
        assertEq(h.fadedGap(), 1200, "a tau of open market still halves it");
    }

    /// @notice A gap under the threshold is ordinary call sparsity on a live book, not a closure.
    ///         While it is open the reading holds, since only the next store can tell a pause from
    ///         a closure; when that store lands below the threshold the whole gap is counted and
    ///         the reading catches up. Crediting it instead would hold margin up on a market that
    ///         was open the whole time.
    function test_fadeSuspend_shortGapHoldsThenCatchesUp() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});
        h.setGapEma({emaSlippageBp: 2400, lastLiquidationTs: BASE_TS, decayedSize: 1e18});

        uint256 next = BASE_TS + RiskParamsLib.FADE_SUSPEND_MIN_GAP - 1;
        vm.warp(next);
        assertEq(h.fadedGap(), 2400, "held while the gap is still open");

        h.storePrice(101e18, next);
        (, uint256 anchor,) = h.gapEma();
        assertEq(anchor, BASE_TS, "anchor untouched below the threshold");
        assertEq(h.fadedGap(), 2057, "the whole gap counted: 2400 x 72h / (72h + 12h - 1s)");
    }

    /// @notice A continuously traded pair never skips a gap. Its feed publishes around the clock
    ///         and any liquidator can bring a fresh price to the call, so a silence in its own store
    ///         is a quiet book rather than a closure: liquidations could have arrived and none did,
    ///         which is the evidence the fade reads. The 13h a session pair would skip whole is
    ///         counted in full here, so a 24/7 pair has no threshold at all.
    function test_fadeSuspend_continuousPairCountsEveryGap() public {
        h.setContinuouslyTraded(true);
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});
        h.setGapEma({emaSlippageBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 1e18});
        h.setDriftEma(600);

        uint256 next = BASE_TS + 13 hours;
        vm.warp(next);
        assertEq(h.fadedGap(), 300, "held while nothing is stored, as on any pair");

        h.storePrice(101e18, next);
        (, uint256 anchor,) = h.gapEma();
        assertEq(anchor, BASE_TS, "anchor untouched: the gap is not a closure");
        assertEq(h.fadedGap(), 254, "the whole 13h counted: 300 x 72h / 85h");
        assertEq(h.fadedDrift(), 508, "drift on the same clock: 600 x 72h / 85h");
    }

    /// @notice A pair with no liquidation history has no anchor to move, so a closure leaves the
    ///         zero state alone rather than stamping a clock onto it.
    function test_fadeSuspend_noHistoryLeavesAnchorAtZero() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});

        uint256 reopen = BASE_TS + 3 days;
        vm.warp(reopen);
        h.storePrice(101e18, reopen);

        (uint256 slipAnchor, uint256 driftAnchor, uint256 batchTs) = h.gapClocks();
        assertEq(slipAnchor + driftAnchor + batchTs, 0, "no batch on record, no clock");
    }

    /// @notice The anchor is clamped to the block. Publish times can sit ahead of `block.timestamp`,
    ///         and the batch update ages old weight by the block minus the anchor, so an unclamped
    ///         advance would make the next batch underflow.
    function test_fadeSuspend_anchorClampedToBlock() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVarianceSample({spotPrice: 100e18, publishTs: BASE_TS});
        h.setGapEma({emaSlippageBp: 2400, lastLiquidationTs: BASE_TS, decayedSize: 1e18});

        // A publish time a minute ahead of the block, across a closure.
        uint256 blockTs = BASE_TS + 20 hours;
        vm.warp(blockTs);
        h.storePrice(101e18, blockTs + 1 minutes);

        (, uint256 anchor,) = h.gapEma();
        assertEq(anchor, blockTs, "anchor clamped to the block, not the publish time");
        assertEq(h.fadedGap(), 2400, "the read clock stops at the block, not the publish time");

        // An equal-size zero-slippage batch in the same block: no weight discount, no fade.
        h.updateGapBatch(0, 1e18, 1);
        (int256 ema,,) = h.gapEma();
        assertEq(ema, 1200, "the batch ages from the clamped anchor without underflowing");
    }

    /// @notice A batch blends against the FADED prior, so stale evidence cannot be resurrected.
    ///         A year-old 24% reading met by an equal-size zero-gap batch reads 6bp; against the
    ///         raw store the weight cap would have kept half of it and read 800. The batch adds
    ///         nothing, so the line keeps its year-old anchor and goes on fading from there.
    function test_gapBatch_blendsAgainstFadedPrior_noSnapBack() public {
        h.setGapEma({emaSlippageBp: 2400, lastLiquidationTs: BASE_TS, decayedSize: 1e18});
        _liveAt(BASE_TS + 365 days);
        h.updateGapBatch(0, 1e18, 1);
        assertEq(h.fadedGap(), 6, "(0.5e18 x 19.6) / 1.5e18: the faded prior, not the raw one");
        (uint256 slipAnchor,,) = h.gapClocks();
        assertEq(slipAnchor, BASE_TS, "a batch that adds nothing keeps the line's anchor");
    }

    /// @notice With no batch ever recorded there is no last-batch clock to fade from, so the
    ///         store is read as is.
    function test_gapEma_noHistoryReadsRaw() public {
        h.setGapEma({emaSlippageBp: 500, lastLiquidationTs: 0, decayedSize: 0});
        vm.warp(BASE_TS + 365 days);
        assertEq(h.fadedGap(), 500, "no history, no fade");
    }

    // -------- the value lines' clocks --------

    /// @dev Per-side open interest the clock tests run against: 1% of it, the prior's floor, is
    ///      10 units, and a 0.001-unit unload at the oracle is a dust batch against it.
    uint256 internal constant CLOCK_OI = 1_000e18;
    uint256 internal constant DUST_FILL = 1e15;

    /// @notice Dust batches leave the fade where it was. A 300bp reading recorded at BASE_TS reads
    ///         100 six days on. With a 0.001-unit batch at zero slippage every six hours in between,
    ///         it reads 99: each batch dilutes the line by its own weight, 0.001 against the 10-unit
    ///         floor, and none restarts the fade, which keeps its anchor.
    function test_gapBatch_dustBatchesLeaveTheFadeAlone() public {
        h.setVault(0, CLOCK_OI, CLOCK_OI);
        h.setGapEma({emaSlippageBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 10e18});
        for (uint256 k = 1; k <= 24; k++) {
            _liveAt(BASE_TS + k * 6 hours);
            h.updateGapBatch(0, DUST_FILL, 1);
        }
        assertEq(h.fadedGap(), 99, "100 without the batches, less their own weight");
        (uint256 slipAnchor,,) = h.gapClocks();
        assertEq(slipAnchor, BASE_TS, "the anchor never moved");
    }

    /// @notice A burst of dust batches cannot erase a reading either. Five hundred 0.0001-unit
    ///         batches at zero slippage in one block take a 500bp reading to 497: together they
    ///         weigh 0.05 against the 10-unit floor, and each rounds at a fraction of a basis point.
    function test_gapBatch_dustBurstCannotEraseTheReading() public {
        h.setVault(0, CLOCK_OI, CLOCK_OI);
        h.setGapEma({emaSlippageBp: 500, lastLiquidationTs: BASE_TS, decayedSize: 10e18});
        _liveAt(BASE_TS);
        for (uint256 k; k < 500; k++) {
            h.updateGapBatch(0, DUST_FILL / 10, 1);
        }
        assertEq(h.fadedGap(), 497, "500 x 10 / 10.05");
    }

    /// @notice A batch that outweighs the prior starts the line close to afresh. Three days after a
    ///         300bp reading, 1,000 units at 400bp meet the 10-unit floor: the line reads 397, and
    ///         the prior's 1.5bp share of it keeps about a quarter of an hour of the three days.
    function test_gapBatch_heavyBatchStartsAFreshLine() public {
        h.setVault(0, CLOCK_OI, CLOCK_OI);
        h.setGapEma({emaSlippageBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 10e18});
        _liveAt(BASE_TS + 3 days);
        h.updateGapBatch(int256(400) * 1_000e18, 1_000e18, 1);
        assertEq(h.fadedGap(), 397, "(10 x 150 + 1,000 x 400) / 1,010");
        (uint256 slipAnchor,,) = h.gapClocks();
        assertEq(slipAnchor, BASE_TS + 3 days - 969, "the anchor keeps 1.485/397.5 of the three days");
    }

    /// @notice Each half keeps its own anchor. A day after a 300bp slippage and 600bp drift
    ///         reading, a floor-sized batch at 300bp slippage and no drift moves the slippage
    ///         line's anchor by the batch's share of it and leaves the drift line's alone: drift
    ///         reads half of 450, and three days later half of what its line alone would read.
    function test_gapBatch_eachHalfKeepsItsOwnAnchor() public {
        h.setVault(0, CLOCK_OI, CLOCK_OI);
        h.setGapEma({emaSlippageBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 10e18});
        h.setDriftEma(600);
        _liveAt(BASE_TS + 1 days);
        h.updateGapBatchBoth({
            sumSlipTimesSize: int256(300) * 10e18, sumDriftTimesSize: 0, totalFillSize: 10e18, count: 1
        });
        assertEq(h.fadedGap(), 262, "(10 x 225 + 10 x 300) / 20");
        assertEq(h.fadedDrift(), 225, "(10 x 450 + 10 x 0) / 20");
        (uint256 slipAnchor, uint256 driftAnchor, uint256 batchTs) = h.gapClocks();
        assertEq(slipAnchor, BASE_TS + 1 days - 37_029, "slippage keeps 112.5/262.5 of the day");
        assertEq(driftAnchor, BASE_TS, "drift got nothing new and keeps its anchor");
        assertEq(batchTs, BASE_TS + 1 days, "the weight's clock is the batch");

        _liveAt(BASE_TS + 4 days);
        assertEq(h.fadedDrift(), 128, "600 x 3d / 7d, halved by the batch's weight");
        assertApproxEqAbs(h.fadedGap(), 140, 1, "the slippage line fades from its own anchor");
    }

    /// @dev The prior weight a batch at `sinceBatch` after the last one blends against, restated:
    ///      the accumulated size discounted by at most half, never below 1% of open interest.
    function _priorOf(uint256 weight, uint256 sinceBatch, uint256 oi) internal pure returns (uint256 prior) {
        uint256 alpha = sinceBatch * 10_000 / (sinceBatch + RiskParamsLib.LIQUIDATION_GAP_EMA_TAU);
        if (alpha > 5000) alpha = 5000;
        prior = weight * (10_000 - alpha) / 10_000;
        uint256 floorSize = oi * RiskParamsLib.LIQ_GAP_PRIOR_FLOOR_BP / 10_000;
        if (prior < floorSize) prior = floorSize;
    }

    /// @dev One line as the batch leaves it, restated: `stored` (GAP_EMA_SCALE per bp) `age` past
    ///      its anchor, blended with a batch summing `sum` (bp x size) over `fill` against `prior`.
    function _foldExpected(uint256 stored, uint256 age, uint256 prior, uint256 fill, uint256 sum)
        internal
        pure
        returns (uint256 newStored, uint256 keptAge, uint256 blend, uint256 survivor)
    {
        uint256 tau = RiskParamsLib.LIQUIDATION_GAP_EMA_TAU;
        survivor = Math.mulDiv(Math.mulDiv(stored, tau, tau + age), prior, prior + fill);
        blend = survivor + Math.mulDiv(sum, 1e18, prior + fill);
        keptAge = survivor == 0 ? 0 : Math.mulDiv(age, survivor, blend, Math.Rounding.Ceil);
        newStored = Math.mulDiv(blend, tau + keptAge, tau, Math.Rounding.Ceil);
    }

    /// @notice Whatever the stored lines, their anchors (each line's own, at or before the last
    ///         batch), the prior's weight, the open interest and the batch, with the drift leg
    ///         uncapped: each line reads exactly the blend at the batch, is stored as of an anchor
    ///         kept back by the survivor's share of its age, never moves its anchor backward or
    ///         past the block, and keeps its anchor when the batch adds nothing to it.
    function testFuzz_gapBatch_readsTheBlendAndKeepsItsClock(
        uint256 slipSeed,
        uint256 driftSeed,
        uint256 sinceBatchSeed,
        uint256 slipLagSeed,
        uint256 driftLagSeed,
        uint256 weightSeed,
        uint256 oiSeed,
        uint256 fillSeed,
        uint256 batchSlipSeed,
        uint256 batchDriftSeed
    ) public {
        uint256 t1 = BASE_TS + 800 days;
        uint256 sinceBatch = bound(sinceBatchSeed, 0, 365 days);
        uint256 slipAge = sinceBatch + bound(slipLagSeed, 0, 365 days);
        uint256 driftAge = sinceBatch + bound(driftLagSeed, 0, 365 days);
        uint256 oi = bound(oiSeed, 0, 1e30);
        uint256 fill = bound(fillSeed, 1, 1e30);
        uint256 batchSlip = bound(batchSlipSeed, 0, 500);
        uint256 batchDrift = bound(batchDriftSeed, 0, 1_000_000);
        uint256 weight = bound(weightSeed, 1, 1e30);
        h.setVault(0, oi, oi);
        h.setGapEma({emaSlippageBp: bound(slipSeed, 0, 500), lastLiquidationTs: t1, decayedSize: weight});
        h.setDriftEma(bound(driftSeed, 0, 1_000_000));
        h.setGapClocks(t1 - slipAge, t1 - driftAge, t1 - sinceBatch);
        _liveAt(t1);

        uint256 prior = _priorOf(weight, sinceBatch, oi);
        (uint256 slipStored, uint256 slipKept, uint256 slipBlend, uint256 slipSurvivor) =
            _foldExpected(h.rawSlippage(), slipAge, prior, fill, batchSlip * fill);
        (uint256 driftStored, uint256 driftKept, uint256 driftBlend,) =
            _foldExpected(h.rawDrift(), driftAge, prior, fill, batchDrift * fill);

        h.updateGapBatchBoth(int256(batchSlip * fill), int256(batchDrift * fill), fill, 1);
        assertEq(h.rawSlippage(), slipStored, "the slippage line is stored as of its anchor");
        assertEq(h.rawDrift(), driftStored, "and so is the drift line");
        assertEq(uint256(h.fadedGap()), slipBlend / 1e18, "the slippage line reads the blend at the batch");
        assertEq(uint256(h.fadedDrift()), driftBlend / 1e18, "and so does the drift line");
        (uint256 slipAnchor, uint256 driftAnchor, uint256 batchTs) = h.gapClocks();
        assertEq(slipAnchor, t1 - slipKept, "the slippage anchor keeps the survivor's share of its age");
        assertEq(driftAnchor, t1 - driftKept, "and the drift anchor its own");
        assertGe(slipAnchor, t1 - slipAge, "no anchor moves backward");
        assertGe(driftAnchor, t1 - driftAge, "no anchor moves backward");
        assertEq(batchTs, t1, "the batch clock is stamped");
        (,, uint256 decayed) = h.gapEma();
        assertEq(decayed, prior + fill, "the weight is the prior's plus the batch's");
        if (batchSlip == 0 && slipSurvivor != 0) {
            assertEq(slipAnchor, t1 - slipAge, "a batch that adds nothing keeps the anchor");
        }
    }

    /// @notice A stream of batches that add nothing only dilutes: whatever their sizes and the
    ///         gaps between them, the reading at the last one is the line's own fade from its
    ///         anchor times the product of each batch's dilution, and the anchor never moves.
    function testFuzz_gapBatch_zeroSlippageStreamOnlyDilutes(
        uint256 nSeed,
        uint256 gapSeed,
        uint256 fillSeed,
        uint256 weightSeed,
        uint256 oiSeed
    ) public {
        uint256 n = bound(nSeed, 1, 12);
        uint256 oi = bound(oiSeed, 1e20, 1e30);
        uint256 floorSize = oi * RiskParamsLib.LIQ_GAP_PRIOR_FLOOR_BP / 10_000;
        uint256 weight = bound(weightSeed, 1, 1e30);
        h.setVault(0, oi, oi);
        h.setGapEma({emaSlippageBp: 500, lastLiquidationTs: BASE_TS, decayedSize: weight});

        uint256 t = BASE_TS;
        uint256 last = BASE_TS;
        uint256 dilutionE18 = 1e18;
        for (uint256 i; i < n; i++) {
            t += bound(uint256(keccak256(abi.encode(gapSeed, i))), 0, 2 days);
            uint256 fill = bound(uint256(keccak256(abi.encode(fillSeed, i))), 1, floorSize);
            uint256 prior = _priorOf(weight, t - last, oi);
            dilutionE18 = Math.mulDiv(dilutionE18, prior, prior + fill);
            weight = prior + fill;
            last = t;
            _liveAt(t);
            h.updateGapBatch(0, fill, 1);
        }
        uint256 tau = RiskParamsLib.LIQUIDATION_GAP_EMA_TAU;
        uint256 expectedE18 = Math.mulDiv(Math.mulDiv(500e18, tau, tau + t - BASE_TS), dilutionE18, 1e18);
        assertApproxEqAbs(uint256(h.fadedGap()), expectedE18 / 1e18, 1, "the fade from the anchor, diluted");
        (uint256 slipAnchor,,) = h.gapClocks();
        assertEq(slipAnchor, BASE_TS, "the anchor never moved");
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
        h.setGapEma({emaSlippageBp: 500, lastLiquidationTs: BASE_TS, decayedSize: 1e18});
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
        h.setGapEma({emaSlippageBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 1e18});
        h.setVault({insuranceFundBalance: 100_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18});
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 calmImr,,) = h.marginReqs();
        assertEq(calmImr, 900, "calm: 2 x (150 + 300)");
        assertEq(h.cachedTargetBp(), 450, "target tracks the same reading");

        // Volatile pair, same gap: stress move 450 + 300 = 750 -> IMR 1500. The gap contributed
        // exactly 300bp of stress move in both regimes. The cooldown is cleared without moving
        // the clock so the gap reads at full value both times.
        h.setMarginReqs({imrBp: 0, mmrBp: 0, lastUpdateTs: 0});
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
        // pairCreatedTs = now, so elapsed 0 < WARMUP_DURATION and priceUpdateCount 0 is below the
        // store threshold: both gates hold, warmup active
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

    /// @dev The curve at 2 x 1500bp x a 2.4 health multiplier, 7200bp and clear of both clamps,
    ///      over stored margins stamped now.
    function _unclampedCurveWithStoredImr(uint256 storedImrBp) internal {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 1_000_000e18});
        h.setReopenGap({gapEmaBp: 1500, lastObsTs: uint64(BASE_TS)});
        h.setMarginReqs({imrBp: storedImrBp, mmrBp: storedImrBp / 2, lastUpdateTs: BASE_TS});
    }

    function _liquidationImr() internal returns (uint256) {
        return h.liquidationImrBp({
            currentPrice: 1e18, isContinuouslyTraded: false, pairCreatedTs: 0, priceUpdateCount: 50_000
        });
    }

    /// @dev Nothing about the margin moved: the stored rates, the cooldown stamp and the ring.
    function _assertNothingStored(uint256 storedImrBp) internal view {
        (uint256 imr, uint256 mmr, uint256 ts) = h.marginReqs();
        assertEq(imr, storedImrBp, "the stored IMR is untouched");
        assertEq(mmr, storedImrBp / 2, "and the MMR");
        assertEq(ts, BASE_TS, "and the cooldown stamp");
        (uint256 count, uint256 lastSampleTs, uint256 intervalMinBp) = h.ring();
        assertEq(count + lastSampleTs + intervalMinBp, 0, "nothing reaches the sample ring");
    }

    /// @notice Inside the cooldown the stored rate caps the live one: a rise waits for the next
    ///         write, and nothing is stored. The target is cached, as on every curve call.
    function test_liquidationImr_insideTheCooldownTheStoredRateCapsARise() public {
        _unclampedCurveWithStoredImr(1234);
        assertEq(_liquidationImr(), 1234, "the stored rate, not the live 7200");
        _assertNothingStored(1234);
        assertEq(h.cachedTargetBp(), 1_000, "the target is cached");
    }

    /// @notice Inside the cooldown a fall below the stored rate applies at once.
    function test_liquidationImr_insideTheCooldownAFallAppliesAtOnce() public {
        _unclampedCurveWithStoredImr(8000);
        assertEq(_liquidationImr(), 7200, "the live rate, below the stored 8000");
        _assertNothingStored(8000);
    }

    /// @notice Past the cooldown the live rate stands, above the stored one too, and it is
    ///         exactly what a write at the same moment stores: one arithmetic for both.
    function test_liquidationImr_pastTheCooldownTheLiveRateStandsAndAWriteStoresIt() public {
        _unclampedCurveWithStoredImr(1234);
        vm.warp(BASE_TS + 60);
        uint256 judged = _liquidationImr();
        assertEq(judged, 7200, "the live rate, above the stored 1234");
        _assertNothingStored(1234);

        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: false, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr,,) = h.marginReqs();
        assertEq(imr, judged, "the write stores the rate liquidate judged by");
    }

    // =====================================================================
    // The trailing open interest the reserve is sized on
    // =====================================================================

    uint256 internal constant OI = 1_000e18;
    uint256 internal constant PRICE = 100e18;
    uint256 internal constant FUND = 30_000e18;

    function _setOi(uint256 oi) internal {
        h.setVault({insuranceFundBalance: FUND, totalLongOI: oi, totalShortOI: oi});
    }

    /// @dev One curve refresh at `ts` on a live market, with `oi` open on both sides.
    function _refreshWithOi(uint256 ts, uint256 oi) internal {
        _liveAt(ts);
        _setOi(oi);
        h.calcIMRandMMR({currentPrice: PRICE, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
    }

    /// @dev Hourly refreshes at hours [from, to) past BASE_TS.
    function _hourly(uint256 from, uint256 to, uint256 oi) internal {
        for (uint256 i = from; i < to; i++) {
            _refreshWithOi(BASE_TS + i * 1 hours, oi);
        }
    }

    /// @dev The reserve on `oi` at the cached target.
    function _reserveOn(uint256 oi) internal view returns (uint256) {
        return RiskParamsLib.adlReserveOf(oi, PRICE, h.cachedTargetBp());
    }

    /// @notice Until the ring holds an interval that opened a full day ago there is no trailing
    ///         figure, and live open interest sizes the reserve alone. The refresh that closes
    ///         the first such interval caches it.
    function test_trailingOi_unsetUntilTheRingHoldsADayOldInterval() public {
        _hourly(0, 24, OI);
        assertEq(h.trailingOiSize(), 0, "no sampled interval is a day old yet");
        assertEq(h.reserveAt(PRICE), _reserveOn(OI), "sized on live open interest");
        assertGt(_reserveOn(OI), 0, "sanity: the fixture has a reserve");
        _setOi(10 * OI);
        assertEq(h.reserveAt(PRICE), _reserveOn(10 * OI), "and it follows live open interest up");

        _refreshWithOi(BASE_TS + 24 hours, OI);
        assertEq(h.trailingOiSize(), OI, "the interval that opened a day ago is now in the window");
    }

    /// @notice Open interest raised between two refreshes, or seen by one refresh, does not raise
    ///         the reserve: it is sized on the day's lowest reading.
    function test_trailingOi_openInterestRaisedAtOnceDoesNotRaiseTheReserve() public {
        _hourly(0, 25, OI);
        uint256 reserve = h.reserveAt(PRICE);
        assertEq(reserve, _reserveOn(OI));

        _setOi(10 * OI);
        assertEq(h.reserveAt(PRICE), reserve, "raised within the transaction: no effect");
        _refreshWithOi(BASE_TS + 24 hours + 10 minutes, 10 * OI);
        assertEq(h.trailingOiSize(), OI, "a refresh that sees it does not adopt it");
        assertEq(h.reserveAt(PRICE), reserve);
    }

    /// @notice Open interest held for a full day does raise the reserve: once every interval in
    ///         the window carries it, the trailing figure moves up to it.
    function test_trailingOi_heldOpenInterestRaisesTheReserveAfterAFullDay() public {
        _hourly(0, 25, OI);
        _hourly(25, 49, 10 * OI);
        assertEq(h.reserveAt(PRICE), _reserveOn(OI), "an interval that saw the lower reading is still in the window");
        _refreshWithOi(BASE_TS + 49 hours, 10 * OI);
        assertEq(h.trailingOiSize(), 10 * OI);
        assertEq(h.reserveAt(PRICE), _reserveOn(10 * OI), "held for the whole lookback");
    }

    /// @notice A fall takes effect at once through the live leg, and the next refresh takes the
    ///         cached figure down with it without waiting for an interval to close. The dip then
    ///         holds the reserve down after open interest recovers.
    function test_trailingOi_fallTakesEffectAtOnce() public {
        _hourly(0, 25, OI);
        _setOi(OI / 4);
        assertEq(h.reserveAt(PRICE), _reserveOn(OI / 4), "live open interest below the trailing figure");
        assertEq(h.trailingOiSize(), OI, "no refresh has seen the fall yet");

        _refreshWithOi(BASE_TS + 24 hours + 10 minutes, OI / 4);
        assertEq(h.trailingOiSize(), OI / 4, "lowered inside the open interval");
        _setOi(OI);
        assertEq(h.reserveAt(PRICE), _reserveOn(OI / 4), "the day's low sizes the reserve after the recovery");
    }

    /// @notice A window in which open interest touched zero stores the smallest size rather than
    ///         zero, which would read as no trailing figure at all, and sizes no reserve.
    function test_trailingOi_flatWindowStoresOneAndSizesNoReserve() public {
        _hourly(0, 25, OI);
        _refreshWithOi(BASE_TS + 24 hours + 10 minutes, 0);
        assertEq(h.trailingOiSize(), 1, "a found minimum of zero");
        _setOi(OI);
        assertEq(h.reserveAt(PRICE), 0, "open interest opened since then does not count yet");
    }

    /// @notice The ring is advanced on a call the margin cooldown turns away, so a refresh inside
    ///         the cooldown still records the open interest it found.
    function test_trailingOi_sampledWhileTheCurveIsInCooldown() public {
        _hourly(0, 25, OI);
        (,, uint256 lastUpdate) = h.marginReqs();
        _refreshWithOi(BASE_TS + 24 hours + 10, OI / 2);
        (,, uint256 afterCall) = h.marginReqs();
        assertEq(afterCall, lastUpdate, "the curve itself did not move");
        assertEq(h.trailingOiSize(), OI / 2, "the open interest was sampled all the same");
    }
}
