// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @dev Storage host exposing the three STATEFUL RiskParamsLib functions that had zero direct
///      coverage: `calculateVariance` (the volatility EMA), `updateLiquidationGapEmaBatch`
///      (the liquidation-gap EMA), and `calculateIMRandMMR` (the composed margin curve). Together
///      these are the volatility/liquidation → leverage-limit feedback loop.
contract RiskParamsStatefulHarness {
    BazaarTypes.MarginRequirements internal marginRequirements;
    BazaarTypes.PairPrice internal lastPairPrice;
    BazaarTypes.LiquidationGapEma internal liquidationGapEma;
    BazaarTypes.Vault internal pairVault;

    // ---- setters ----
    function setPairPrice(uint256 spotPrice, uint256 updateTs, uint256 emaVarianceBp) external {
        lastPairPrice.spotPrice = spotPrice;
        lastPairPrice.updateTs = updateTs;
        lastPairPrice.emaVarianceBp = emaVarianceBp;
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

    // ---- callers ----
    function calcVariance(uint256 price) external view returns (uint256) {
        return RiskParamsLib.calculateVariance(lastPairPrice, price);
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
            currentPrice,
            isContinuouslyTraded,
            pairCreatedTs,
            priceUpdateCount
        );
    }

    // ---- getters ----
    function gapEma() external view returns (int256, uint256, uint256) {
        return (liquidationGapEma.emaGapBp, liquidationGapEma.lastLiquidationTs, liquidationGapEma.decayedSize);
    }

    function marginReqs() external view returns (uint256, uint256, uint256) {
        return (marginRequirements.imrBp, marginRequirements.mmrBp, marginRequirements.lastUpdateTs);
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

    /// @notice First-ever price (no prior spot) returns 0 — no return to compute variance from.
    function test_variance_firstPrice_returnsZero() public {
        h.setPairPrice({spotPrice: 0, updateTs: BASE_TS, emaVarianceBp: 777});
        assertEq(h.calcVariance(100e18), 0, "no prior price -> 0");
    }

    /// @notice Within the 1-minute cooldown the previous EMA is returned verbatim (strict `<`).
    function test_variance_withinCooldown_returnsPrevious() public {
        // updateTs 59s ago: elapsed 59 < 60 -> return prior emaVarianceBp untouched.
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS - 59, emaVarianceBp: 7777});
        assertEq(h.calcVariance(110e18), 7777, "cooldown holds prior EMA");
    }

    /// @notice At exactly 60s elapsed the cooldown has passed and the EMA recomputes.
    ///         Pins the strict-`<` boundary and the exact first-step math (prior EMA = 0):
    ///         returnBp=1000, squared=1e6, effElapsed=60, annualized=1e6*365d/60=525_600_000_000,
    ///         alpha=60*1e4/(60+5d)=1, ema=525_600_000_000*1/1e4=52_560_000.
    function test_variance_cooldownBoundary_recomputes() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS - 60, emaVarianceBp: 0});
        assertEq(h.calcVariance(110e18), 52_560_000, "recomputes at exactly 60s");
    }

    /// @notice Up-move and down-move of the same magnitude yield identical variance
    ///         (the return is |Δ|/spot, sign-agnostic).
    function test_variance_upDownSymmetry() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS - 5 days, emaVarianceBp: 0});
        uint256 up = h.calcVariance(110e18); // +10%
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS - 5 days, emaVarianceBp: 0});
        uint256 down = h.calcVariance(90e18); // -10%
        assertEq(up, down, "symmetric in price direction");
        assertGt(up, 0, "non-trivial variance");
    }

    /// @notice Exact EMA after a +10% step over 5 days from a zero seed.
    ///         returnBp=1000, squared=1e6, effElapsed capped at 1 day -> annualized=1e6*365=365_000_000,
    ///         alpha=5d*1e4/(5d+5d)=5000, ema=365_000_000*5000/1e4=182_500_000.
    function test_variance_exactValue_fiveDayStep() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS - 5 days, emaVarianceBp: 0});
        assertEq(h.calcVariance(110e18), 182_500_000, "exact EMA after 5-day 10% step");
    }

    /// @notice The effective-elapsed (1-day) and alpha (5000) caps both saturate beyond 5 days,
    ///         so a 5-day step and a 15-day step of identical magnitude produce the SAME variance.
    ///         Proves both clamps at once.
    function test_variance_effElapsedAndAlphaCaps_saturate() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS - 5 days, emaVarianceBp: 0});
        uint256 fiveDay = h.calcVariance(110e18);
        vm.warp(BASE_TS + 10 days); // so a 15-day-old updateTs is reachable
        h.setPairPrice({spotPrice: 100e18, updateTs: (BASE_TS + 10 days) - 15 days, emaVarianceBp: 0});
        uint256 fifteenDay = h.calcVariance(110e18);
        assertEq(fiveDay, fifteenDay, "effElapsed & alpha caps saturate identically");
        assertEq(fiveDay, 182_500_000, "and equal the pinned value");
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

    /// @notice Low vol / healthy fund / continuous / past warmup: all multipliers = 1x, base IMR
    ///         300bp floored to MIN_IMR_BP = 400. MMR = IMR/2.
    function test_imr_minClamp_continuousPastWarmup() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 0}); // 300bp ratio >= 200bp target
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr, uint256 mmr, uint256 ts) = h.marginReqs();
        assertEq(imr, 400, "floored at MIN_IMR_BP");
        assertEq(mmr, 200, "MMR = IMR/2");
        assertEq(ts, BASE_TS, "lastUpdateTs stamped");
    }

    /// @notice Non-continuous applies the 1.5x multiplier: 300bp -> 450bp (above the 400 floor).
    function test_imr_nonContinuousMultiplier() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 0});
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: false, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr, uint256 mmr,) = h.marginReqs();
        assertEq(imr, 450, "1.5x non-continuous multiplier");
        assertEq(mmr, 225, "MMR = IMR/2");
    }

    /// @notice Extreme vol + extreme gap + empty fund: combined 3x*3x*3x -> 8100bp, clamped to
    ///         MAX_IMR_BP = 8000. MMR = 4000.
    function test_imr_maxClamp() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: BazaarTypes.VARIANCE_EXTREME});
        h.setGapEma({emaGapBp: 300, lastLiquidationTs: BASE_TS, decayedSize: 1e18});
        h.setVault({insuranceFundBalance: 0, totalLongOI: 1_000_000e18, totalShortOI: 0}); // 0bp ratio -> 3x
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr, uint256 mmr,) = h.marginReqs();
        assertEq(imr, 8000, "clamped at MAX_IMR_BP");
        assertEq(mmr, 4000, "MMR = IMR/2");
    }

    /// @notice Continuous pair during warmup: 400bp computed value floored to WARMUP_MIN_IMR_BP = 2000.
    function test_imr_warmupFloor_continuous() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 0});
        // pairCreatedTs = now (elapsed 0 < 5 days) AND priceUpdateCount 0 < 50k -> warmup active
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: BASE_TS, priceUpdateCount: 0});
        (uint256 imr, uint256 mmr,) = h.marginReqs();
        assertEq(imr, 2000, "warmup floor 20% IMR = 5x");
        assertEq(mmr, 1000, "MMR = IMR/2");
    }

    /// @notice Non-continuous during warmup: floor is 2000 * 1.5 = 3000bp — the value
    ///         StaleLiquidationExploitTest relies on for AAPL-style pairs.
    function test_imr_warmupFloor_nonContinuous() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 0});
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: false, pairCreatedTs: BASE_TS, priceUpdateCount: 0});
        (uint256 imr, uint256 mmr,) = h.marginReqs();
        assertEq(imr, 3000, "non-continuous warmup floor = 30% IMR");
        assertEq(mmr, 1500, "MMR = IMR/2");
    }

    /// @notice Within the 1-minute IMR cooldown the call early-returns and leaves margins untouched;
    ///         at exactly +60s it recomputes. Pins the strict-`<` cooldown boundary.
    function test_imr_cooldownBoundary() public {
        h.setPairPrice({spotPrice: 100e18, updateTs: BASE_TS, emaVarianceBp: 0});
        h.setVault({insuranceFundBalance: 30_000e18, totalLongOI: 1_000_000e18, totalShortOI: 0});
        h.setMarginReqs({imrBp: 1234, mmrBp: 617, lastUpdateTs: BASE_TS});

        // Same timestamp: block.timestamp < lastUpdateTs + 60 -> early return, sentinel preserved.
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr0,, uint256 ts0) = h.marginReqs();
        assertEq(imr0, 1234, "cooldown blocks recompute");
        assertEq(ts0, BASE_TS, "lastUpdateTs unchanged during cooldown");

        // Exactly +60s: no longer < cooldown -> recomputes to the floored 400.
        vm.warp(BASE_TS + 60);
        h.calcIMRandMMR({currentPrice: 1e18, isContinuouslyTraded: true, pairCreatedTs: 0, priceUpdateCount: 50_000});
        (uint256 imr1,, uint256 ts1) = h.marginReqs();
        assertEq(imr1, 400, "recomputes exactly at cooldown boundary");
        assertEq(ts1, BASE_TS + 60, "lastUpdateTs advanced");
    }
}
