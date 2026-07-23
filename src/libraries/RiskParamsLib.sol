// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";

/// @title RiskParamsLib
/// @notice Risk-parameter math extracted from BazaarPair: the IMR/MMR curve, variance EMA,
///         liquidation-gap EMA, insurance-fund targets and the taker insurance fee curves.
/// @dev Deployed as an EXTERNAL library (DELEGATECALL, like MatchingEngineLib et al.) so its
///      bytecode does not count toward BazaarPair's EIP-170 limit. Storage struct params run
///      in the calling pair's storage context.
library RiskParamsLib {
    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 internal constant BP_SCALE = BazaarTypes.BP_SCALE;

    // -------------------- IMR/MMR constants --------------------
    uint256 internal constant IMR_UPDATE_COOLDOWN = 1 minutes; // minimum time between IMR updates
    uint256 internal constant VARIANCE_UPDATE_COOLDOWN = 1 minutes; // minimum time between variance updates
    /// @notice Half-life for liquidation gap EMA decay (shorter than volatility since liquidations are rarer events)
    uint256 internal constant LIQUIDATION_GAP_EMA_TAU = 3 days;

    /// @notice Minimum and maximum IMR bounds
    uint256 internal constant BASE_IMR_BP = 300; // used for scaling
    uint256 internal constant MIN_IMR_BP = 400; // 4% min IMR (25x leverage)
    uint256 internal constant MAX_IMR_BP = 8_000; // 80% max IMR (1.25x leverage)
    uint256 internal constant NON_CONTINUOUSLY_TRADED_IMR_MULTIPLIER_BP = 15_000; // 1.5x IMR for non-continuously traded assets

    /// @notice Warmup period: cap leverage at 5x (20% IMR) until pair has enough price history
    uint256 internal constant WARMUP_DURATION = 5 days;
    uint256 internal constant WARMUP_PRICE_UPDATE_THRESHOLD = 50_000;
    uint256 internal constant WARMUP_MIN_IMR_BP = 2_000; // 20% IMR = 5x max leverage

    /// @notice Annualized variance thresholds (in bp²) for volatility multiplier
    uint256 internal constant VARIANCE_LOW = BazaarTypes.VARIANCE_LOW;
    uint256 internal constant VARIANCE_EXTREME = BazaarTypes.VARIANCE_EXTREME;
    uint256 internal constant MULTIPLIER_MAX = 30_000; // 3x for all multipliers

    /// @notice Gap thresholds for liquidation gap multiplier
    uint256 internal constant LIQUIDATION_GAP_EXTREME = 300; // 3% gap
    uint256 internal constant LIQUIDATION_GAP_LOW_ = 0; // 0% gap

    /// @notice Base insurance targets by volatility tier (in bp)
    uint256 internal constant INSURANCE_TARGET_BASE = BazaarTypes.INSURANCE_TARGET_BASE;
    uint256 internal constant INSURANCE_TARGET_MAX = BazaarTypes.INSURANCE_TARGET_MAX;

    // -------------------- Taker insurance fee constants --------------------
    // EBP convention: 100 EBP = 1 bp (EBP_SCALE = 1e6), matching MAKER_INSURANCE_FEE_EBP et al.
    uint256 internal constant TAKER_INSURANCE_FEE_MIN_EBP = 50; // 0.5 bps at INSURANCE_TARGET_BASE (2%)
    uint256 internal constant TAKER_INSURANCE_FEE_MAX_EBP = 200; // 2 bps at INSURANCE_TARGET_MAX (10%)
    uint256 internal constant TAKER_INSURANCE_FEE_MULTIPLIER = 49; // f_base × (1 + MULTIPLIER × δ²)
    uint256 internal constant TAKER_INSURANCE_FEE_CAP_EBP = 4_500; // 45 bps hard cap

    // -------------------- IMR/MMR --------------------

    /// @notice Updates IMR/MMR
    function calculateIMRandMMR(
        BazaarTypes.MarginRequirements storage marginRequirements,
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        BazaarTypes.Vault storage pairVault,
        uint256 currentPrice,
        bool isContinuouslyTraded,
        uint256 pairCreatedTs,
        uint256 priceUpdateCount
    ) external {
        if (block.timestamp < marginRequirements.lastUpdateTs + IMR_UPDATE_COOLDOWN) return;

        (uint256 insuranceRatioBp,,) = getInsuranceFundToOIRatio(pairVault, currentPrice);

        uint256 volatilityMultiplier = getVolatilityMultiplier(lastPairPrice.emaVarianceBp);
        uint256 liquidationGapMultiplier = getLiquidationGapMultiplier(liquidationGapEma.emaGapBp);
        uint256 targetInsuranceRatioBp =
            getTargetInsuranceRatio(lastPairPrice.emaVarianceBp, liquidationGapEma.emaGapBp);
        uint256 insuranceMultiplier = getInsuranceMultiplier(insuranceRatioBp, targetInsuranceRatioBp);

        uint256 combinedMultiplier =
            volatilityMultiplier * liquidationGapMultiplier * insuranceMultiplier / BP_SCALE / BP_SCALE;
        uint256 newImrBp = BASE_IMR_BP * combinedMultiplier / BP_SCALE;

        if (!isContinuouslyTraded) {
            newImrBp = newImrBp * NON_CONTINUOUSLY_TRADED_IMR_MULTIPLIER_BP / BP_SCALE;
        }
        if (newImrBp < MIN_IMR_BP) newImrBp = MIN_IMR_BP;
        if (newImrBp > MAX_IMR_BP) newImrBp = MAX_IMR_BP;

        // During warmup, enforce 5x max leverage (20% IMR floor)
        if (block.timestamp - pairCreatedTs < WARMUP_DURATION || priceUpdateCount < WARMUP_PRICE_UPDATE_THRESHOLD) {
            uint256 minWarmupImrBp = isContinuouslyTraded
                ? WARMUP_MIN_IMR_BP
                : WARMUP_MIN_IMR_BP * NON_CONTINUOUSLY_TRADED_IMR_MULTIPLIER_BP / BP_SCALE;
            if (newImrBp < minWarmupImrBp) newImrBp = minWarmupImrBp;
        }

        marginRequirements.imrBp = newImrBp;
        marginRequirements.mmrBp = newImrBp / 2;
        marginRequirements.lastUpdateTs = block.timestamp;
    }

    function calculateVariance(BazaarTypes.PairPrice storage lastPairPrice, uint256 price)
        external
        view
        returns (uint256 emaVarianceBp)
    {
        uint256 lastSpotPrice = lastPairPrice.spotPrice;
        if (lastSpotPrice == 0) return 0; // First price update — no prior price to compute variance

        uint256 elapsed = block.timestamp - lastPairPrice.updateTs;
        if (elapsed < VARIANCE_UPDATE_COOLDOWN) return lastPairPrice.emaVarianceBp;
        uint256 returnBp = price > lastSpotPrice
            ? (price - lastSpotPrice) * BP_SCALE / lastSpotPrice
            : (lastSpotPrice - price) * BP_SCALE / lastSpotPrice;

        uint256 returnSquaredBp = returnBp * returnBp;
        uint256 effectiveElapsed = elapsed > 1 days ? 1 days : elapsed;
        uint256 annualizedReturnSquaredBp = returnSquaredBp * 365 days / effectiveElapsed;

        uint256 tau = 5 days;
        uint256 alpha = elapsed * BP_SCALE / (elapsed + tau);
        alpha = alpha > 5000 ? 5000 : alpha;

        emaVarianceBp =
            (annualizedReturnSquaredBp * alpha + lastPairPrice.emaVarianceBp * (BP_SCALE - alpha)) / BP_SCALE;
    }

    /// @notice Batch updates the liquidation gap EMA after multiple liquidations in one call
    /// @dev More gas efficient than updating EMA after each individual match.
    ///      Uses size-weighted average gap within batch and time-decayed size weighting across batches.
    ///      This ensures larger liquidations have proportionally more impact, with decay over time.
    function updateLiquidationGapEmaBatch(
        BazaarTypes.LiquidationGapEma storage g,
        int256 sumGapTimesSize,
        uint256 totalFillSize,
        uint256 count
    ) external {
        if (totalFillSize == 0 || count == 0) return;

        // Calculate size-weighted average gap in basis points for this batch
        int256 batchGapBp = sumGapTimesSize / int256(totalFillSize);

        if (g.decayedSize == 0) {
            // First batch - seed the EMA and decayed size
            g.emaGapBp = batchGapBp;
            g.decayedSize = totalFillSize;
        } else {
            // Calculate time-based decay factor
            uint256 elapsed = block.timestamp - g.lastLiquidationTs;

            // alpha = elapsed / (elapsed + tau), capped at 50%
            // Higher alpha = more weight to new data (old data decays more)
            uint256 alpha = elapsed * BP_SCALE / (elapsed + LIQUIDATION_GAP_EMA_TAU);
            alpha = alpha > 5000 ? 5000 : alpha;

            // Decay the old accumulated size
            // decayedOldSize = oldSize * (1 - alpha)
            uint256 decayedOldSize = g.decayedSize * (BP_SCALE - alpha) / BP_SCALE;

            // New total decayed size = decayed old + new batch
            uint256 newDecayedSize = decayedOldSize + totalFillSize;

            // Size-weighted EMA update:
            // new_ema = (newBatchSize * batchGap + decayedOldSize * oldEma) / newDecayedSize
            g.emaGapBp =
                (int256(totalFillSize) * batchGapBp + int256(decayedOldSize) * g.emaGapBp) / int256(newDecayedSize);

            // Update decayed size
            g.decayedSize = newDecayedSize;
        }

        g.lastLiquidationTs = block.timestamp;
    }

    // -------------------- Insurance fund ratio & fees --------------------

    /// @notice Calculates the insurance fund to total open interest ratio
    /// @dev Returns the ratio in basis points (e.g., 500 = 5% coverage).
    ///      Total OI is converted to notional (USDC) using the provided price.
    ///      Returns type(uint256).max if total OI is zero (fully covered).
    /// @param pairVault The pair's vault aggregates (storage)
    /// @param currentPrice The current price to use for OI notional calculation (BAZAAR_SCALE precision)
    /// @return ratioBp The insurance fund / total OI notional ratio in basis points
    /// @return insuranceFund The current insurance fund balance (USDC)
    /// @return totalOINotional The total open interest in notional value (USDC)
    function getInsuranceFundToOIRatio(BazaarTypes.Vault storage pairVault, uint256 currentPrice)
        public
        view
        returns (uint256 ratioBp, uint256 insuranceFund, uint256 totalOINotional)
    {
        insuranceFund = pairVault.insuranceFundBalance;
        uint256 totalOISize = pairVault.totalLongOI + pairVault.totalShortOI;

        if (currentPrice == 0) {
            // No price provided - can't calculate meaningful ratio
            return (0, insuranceFund, 0);
        }

        totalOINotional = Math.mulDiv(totalOISize, currentPrice, BAZAAR_SCALE);

        if (totalOINotional == 0) {
            // No open interest - insurance fund provides infinite coverage
            return (type(uint256).max, insuranceFund, 0);
        }

        // Calculate ratio in basis points: (insuranceFund / totalOINotional) * BP_SCALE
        ratioBp = (insuranceFund * BP_SCALE) / totalOINotional;
    }

    /// @notice Calculates taker insurance fee
    function getTakerInsuranceFeeEbp(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        uint256 currentPrice
    ) external view returns (uint256 feeEbp) {
        (uint256 currentRatioBp,,) = getInsuranceFundToOIRatio(pairVault, currentPrice);
        uint256 targetRatioBp = getTargetInsuranceRatio(lastPairPrice.emaVarianceBp, liquidationGapEma.emaGapBp);
        uint256 fBase = getTakerInsuranceFeeBase(targetRatioBp);

        if (currentRatioBp == type(uint256).max) return 0;

        if (currentRatioBp >= targetRatioBp) {
            uint256 surplus = ((currentRatioBp - targetRatioBp) * BP_SCALE) / targetRatioBp;
            if (surplus >= BP_SCALE) return 0;
            return fBase * (BP_SCALE - surplus) / BP_SCALE;
        }

        uint256 deficit = ((targetRatioBp - currentRatioBp) * BP_SCALE) / targetRatioBp;
        uint256 deficitSquared = deficit * deficit;
        uint256 bpScaleSquared = BP_SCALE * BP_SCALE;
        feeEbp = fBase * (bpScaleSquared + TAKER_INSURANCE_FEE_MULTIPLIER * deficitSquared) / bpScaleSquared;
        if (feeEbp > TAKER_INSURANCE_FEE_CAP_EBP) feeEbp = TAKER_INSURANCE_FEE_CAP_EBP;
    }

    /// @notice The closing (base) taker insurance fee at the current target ratio — combines the
    ///         target-ratio and base-fee curves in one call so the pair pays a single delegatecall.
    function getClosingFeeEbp(
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma
    ) external view returns (uint256) {
        return getTakerInsuranceFeeBase(
            getTargetInsuranceRatio(lastPairPrice.emaVarianceBp, liquidationGapEma.emaGapBp)
        );
    }

    /// @notice Returns taker insurance base fee
    function getTakerInsuranceFeeBase(uint256 targetRatioBp) public pure returns (uint256) {
        if (targetRatioBp <= INSURANCE_TARGET_BASE) return TAKER_INSURANCE_FEE_MIN_EBP;
        if (targetRatioBp >= INSURANCE_TARGET_MAX) return TAKER_INSURANCE_FEE_MAX_EBP;
        return TAKER_INSURANCE_FEE_MIN_EBP + (targetRatioBp - INSURANCE_TARGET_BASE)
            * (TAKER_INSURANCE_FEE_MAX_EBP - TAKER_INSURANCE_FEE_MIN_EBP)
            / (INSURANCE_TARGET_MAX - INSURANCE_TARGET_BASE);
    }

    /// @notice Returns target insurance ratio. Single source of truth — also consumed by
    ///         InsuranceVaultLib's withdrawal rate-limit check; keep any curve change here only.
    function getTargetInsuranceRatio(uint256 variance, int256 liquidationGapBp) internal pure returns (uint256) {
        uint256 volTarget;
        if (variance <= VARIANCE_LOW) {
            volTarget = INSURANCE_TARGET_BASE;
        } else if (variance >= VARIANCE_EXTREME) {
            volTarget = INSURANCE_TARGET_MAX;
        } else {
            volTarget = INSURANCE_TARGET_BASE + (variance - VARIANCE_LOW)
                * (INSURANCE_TARGET_MAX - INSURANCE_TARGET_BASE) / (VARIANCE_EXTREME - VARIANCE_LOW);
        }
        uint256 gapTarget = liquidationGapBp > 0 ? uint256(liquidationGapBp) * 3 : 0;
        uint256 target = volTarget > gapTarget ? volTarget : gapTarget;
        if (target < INSURANCE_TARGET_BASE) return INSURANCE_TARGET_BASE;
        if (target > INSURANCE_TARGET_MAX) return INSURANCE_TARGET_MAX;
        return target;
    }

    function getVolatilityMultiplier(uint256 variance) public pure returns (uint256) {
        if (variance <= VARIANCE_LOW) return BP_SCALE;
        if (variance >= VARIANCE_EXTREME) return MULTIPLIER_MAX;
        return BP_SCALE + (variance - VARIANCE_LOW) * (MULTIPLIER_MAX - BP_SCALE) / (VARIANCE_EXTREME - VARIANCE_LOW);
    }

    function getLiquidationGapMultiplier(int256 gapBp) public pure returns (uint256) {
        if (gapBp <= int256(LIQUIDATION_GAP_LOW_)) return BP_SCALE;
        if (gapBp >= int256(LIQUIDATION_GAP_EXTREME)) return MULTIPLIER_MAX;
        return BP_SCALE + uint256(gapBp) * (MULTIPLIER_MAX - BP_SCALE) / LIQUIDATION_GAP_EXTREME;
    }

    function getInsuranceMultiplier(uint256 currentRatioBp, uint256 targetRatioBp) public pure returns (uint256) {
        if (currentRatioBp >= targetRatioBp) return BP_SCALE;
        if (currentRatioBp == 0) return MULTIPLIER_MAX;
        return BP_SCALE + (targetRatioBp - currentRatioBp) * (MULTIPLIER_MAX - BP_SCALE) / targetRatioBp;
    }
}
