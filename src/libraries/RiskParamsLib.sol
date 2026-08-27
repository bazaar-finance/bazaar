// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";

/// @title RiskParamsLib
/// @notice Risk-parameter math for BazaarPair: the IMR/MMR curve, variance EMA, liquidation-gap
///         EMA, insurance-fund targets and the taker insurance fee curves.
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
    uint256 internal constant NON_CONTINUOUSLY_TRADED_IMR_MULTIPLIER_BP = 20_000; // 2x IMR for non-continuously traded assets

    /// @notice Reopen-gap floor parameters (non-continuously traded pairs only). A price-storage
    ///         gap of at least REOPEN_GAP_MIN_STALENESS marks a discontinuity worth learning:
    ///         full closures (overnight ≈ 17.5h, weekend ≈ 65h), trading-halt reopens, and
    ///         lunch/maintenance breaks. The threshold's only job is to exclude routine on-chain
    ///         call sparsity: the refresh bounty holds economically live pairs to a ~10-minute
    ///         cadence (REFRESH_BOUNTY_MIN_GAP), so an hour without a stored price on such a
    ///         pair is a genuine market discontinuity, not keeper latency — while returns across
    ///         shorter gaps are diffusion the variance EMA already prices. The |return| across
    ///         an eligible gap feeds a peak-hold estimator — max of the new observation and the
    ///         harmonically decayed prior — whose value is the gap leg of the non-continuous
    ///         IMR (2 x max(vol curve, gapEmaBp)), so margin covers the pair's demonstrated
    ///         jump risk. The cap bounds a single catastrophic reopen's effect: doubled by the
    ///         closure prior, a cap-sized gap lands exactly on MAX_IMR_BP.
    uint256 internal constant REOPEN_GAP_MIN_STALENESS = 1 hours;
    uint256 internal constant REOPEN_GAP_EMA_TAU = 180 days;
    uint256 internal constant REOPEN_GAP_EMA_CAP_BP = 4_000;

    /// @notice Warmup period: cap leverage at 5x (20% IMR) until pair has enough price history
    uint256 internal constant WARMUP_DURATION = 5 days;
    uint256 internal constant WARMUP_PRICE_UPDATE_THRESHOLD = 50_000;
    uint256 internal constant WARMUP_MIN_IMR_BP = 2_000; // 20% IMR = 5x max leverage

    /// @notice Annualized variance thresholds (in bp²) for volatility multiplier
    uint256 internal constant VARIANCE_LOW = BazaarTypes.VARIANCE_LOW;
    uint256 internal constant VARIANCE_EXTREME = BazaarTypes.VARIANCE_EXTREME;
    uint256 internal constant MULTIPLIER_MAX = 30_000; // 3x cap for the liquidation-gap and insurance multipliers

    /// @notice Ceiling for the volatility multiplier alone. The vol curve is linear in VARIANCE
    ///         (not vol), which holds IMR-per-daily-sigma roughly constant as vol rises — a low
    ///         cap breaks exactly that property in the regimes that need it most, pricing 100%
    ///         and 230% annualized vol identically. So the same line continues past the 3x the
    ///         other legs stop at, saturating at 6x near 157% annualized vol. The vol leg earns
    ///         the higher ceiling because it is the only EX-ANTE leg: the liquidation-gap and
    ///         insurance multipliers price damage already realized (bad fills, a depleted fund),
    ///         while variance rises before losses land.
    uint256 internal constant VOL_MULTIPLIER_MAX = 60_000;

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

    // -------------------- Price-refresh bounty constants --------------------
    uint256 internal constant REFRESH_BOUNTY = BAZAAR_SCALE / 4; // $0.25
    uint256 internal constant REFRESH_BOUNTY_MIN_GAP = 10 minutes;
    uint256 internal constant REFRESH_BOUNTY_MIN_OI_NOTIONAL = 10_000 * BAZAAR_SCALE; // $10,000
    uint256 internal constant REFRESH_BOUNTY_MIN_INSURANCE = 10_000 * BAZAAR_SCALE; // $10,000

    /// @notice A refreshPrice caller earned the staleness-ending bounty from the insurance fund.
    ///         Emitted from the pair's address (DELEGATECALL). `amount` is BAZAAR (1e18) precision.
    event RefreshBountyPaid(address indexed keeper, uint256 amount);

    // -------------------- IMR/MMR --------------------

    /// @notice Updates IMR/MMR
    function calculateIMRandMMR(
        BazaarTypes.MarginRequirements storage marginRequirements,
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.ReopenGapEma storage reopenGapEma,
        uint256 currentPrice,
        bool isContinuouslyTraded,
        uint256 pairCreatedTs,
        uint256 priceUpdateCount
    ) external {
        if (block.timestamp < marginRequirements.lastUpdateTs + IMR_UPDATE_COOLDOWN) return;

        (uint256 insuranceRatioBp,,) = getInsuranceFundToOIRatio(pairVault, currentPrice);

        uint256 volatilityMultiplier = getVolatilityMultiplier(lastPairPrice.emaVarianceBp);
        uint256 liquidationGapMultiplier = getLiquidationGapMultiplier(liquidationGapEma.emaGapBp);
        uint256 targetInsuranceRatioBp = getTargetInsuranceRatio(
            lastPairPrice.emaVarianceBp,
            liquidationGapEma.emaGapBp,
            isContinuouslyTraded ? 0 : uint256(reopenGapEma.gapEmaBp)
        );
        uint256 insuranceMultiplier = getInsuranceMultiplier(insuranceRatioBp, targetInsuranceRatioBp);

        uint256 combinedMultiplier =
            volatilityMultiplier * liquidationGapMultiplier * insuranceMultiplier / BP_SCALE / BP_SCALE;
        uint256 newImrBp = BASE_IMR_BP * combinedMultiplier / BP_SCALE;

        if (!isContinuouslyTraded) {
            // IMR = 2 x max(vol curve, observed reopen gap). The two ESTIMATORS still compose by
            // max — the same reopen feeds both the variance EMA and the gap EMA, and max counts
            // it once — but the closure prior (the 2x) multiplies whichever estimate wins: the
            // multipliers above scale intraday variance, which says little about how far the
            // price jumps across a closure, and a floor at only 1x the demonstrated gap would
            // leave MMR (= IMR/2) covering just half a repeat of it. Doubling the winning leg
            // makes the maintenance level itself survive the demonstrated reopen, and initial
            // margin survive twice it.
            uint256 gapFloorBp = reopenGapEma.gapEmaBp;
            if (gapFloorBp > newImrBp) newImrBp = gapFloorBp;
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

    /// @notice Pays a refreshPrice caller REFRESH_BOUNTY ($0.25) from the insurance fund for
    ///         ending a price-staleness gap. This makes off-peak oracle upkeep self-funding:
    ///         no fee-earning flow (fills, liquidations) has a reason to post Pyth updates to a
    ///         quiet pair, so without the bounty its lagged-MMR ring and funding index freeze
    ///         and its liquidations drift onto arbitrarily old prices.
    /// @dev Runs via DELEGATECALL in the pair's context, so msg.sender is the keeper. Only
    ///      BazaarPair.refreshPrice calls it, and only when the pair is not terminated (the
    ///      insurance fund backs settlement claims then). Every gate is a silent return, never
    ///      a revert — the price refresh must stand regardless of bounty eligibility. Gates:
    ///      - `lastPrice.updateTs` must have advanced past `prevUpdateTs`: a stored update is
    ///        the service being bought. Reads served from cached or frozen data (e.g. the price
    ///        freeze at a scheduled termination) store nothing — paying them would let callers
    ///        collect against the same stale timestamp repeatedly.
    ///      - The pre-refresh stored price must be older than REFRESH_BOUNTY_MIN_GAP, which
    ///        hard-caps insurance spend at REFRESH_BOUNTY x (1 day / REFRESH_BOUNTY_MIN_GAP)
    ///        per pair per day no matter how aggressively keepers race the gate.
    ///      - OI notional and the insurance fund must each exceed their $10,000 floors
    ///        (REFRESH_BOUNTY_MIN_OI_NOTIONAL / REFRESH_BOUNTY_MIN_INSURANCE): a pair with no
    ///        meaningful exposure does not need paid freshness, and a small fund is not
    ///        drained for it.
    ///      The insurance deduction and the USDC transfer happen together, so the fund's claim
    ///      on the pair's USDC stays exact. The transfer soft-fails like
    ///      InsuranceVaultLib.payUmaProposerReward: a keeper that USDC cannot pay (e.g.
    ///      blacklisted) earns nothing and the deduction is restored, but the refresh is not
    ///      reverted.
    /// @param vault The pair vault (insurance fund source, OI totals)
    /// @param lastPrice The pair's stored price, read after the refresh
    /// @param usdc USDC token address
    /// @param prevUpdateTs The stored price's updateTs captured before the refresh
    function payRefreshBounty(
        BazaarTypes.Vault storage vault,
        BazaarTypes.PairPrice storage lastPrice,
        address usdc,
        uint256 prevUpdateTs
    ) external {
        if (lastPrice.updateTs <= prevUpdateTs) return;
        if (block.timestamp <= prevUpdateTs + REFRESH_BOUNTY_MIN_GAP) return;
        if (vault.insuranceFundBalance <= REFRESH_BOUNTY_MIN_INSURANCE) return;
        // Same floored-notional shape as the insurance withdrawal rate limit: OI at fresh spot.
        uint256 oiNotional =
            Math.mulDiv(vault.totalLongOI + vault.totalShortOI, lastPrice.spotPrice, BAZAAR_SCALE);
        if (oiNotional <= REFRESH_BOUNTY_MIN_OI_NOTIONAL) return;

        vault.insuranceFundBalance -= REFRESH_BOUNTY;
        uint256 usdcAmount = REFRESH_BOUNTY / (BAZAAR_SCALE / BazaarTypes.USDC_SCALE);
        (bool callOk, bytes memory data) = usdc.call(
            abi.encodeWithSelector(0xa9059cbb, msg.sender, usdcAmount) // transfer(address,uint256)
        );
        if (callOk && (data.length == 0 || abi.decode(data, (bool)))) {
            emit RefreshBountyPaid(msg.sender, REFRESH_BOUNTY);
        } else {
            vault.insuranceFundBalance += REFRESH_BOUNTY;
        }
    }

    /// @notice Advances the annualized-variance EMA from the last consumed sample to `price`,
    ///         returning the EMA to store alongside the new price.
    /// @dev Both the return and the interval it is annualized over are measured from
    ///      `varianceSample`, which advances only when the EMA itself advances. A sampling
    ///      interval shorter than VARIANCE_UPDATE_COOLDOWN therefore DEFERS the sample — the
    ///      next call measures from the same baseline over a correspondingly longer interval —
    ///      instead of discarding it, so no update cadence can starve the EMA.
    ///
    ///      The cooldown is what keeps the estimator usable, at both ends. It floors `elapsed`,
    ///      which bounds the `365 days / effectiveElapsed` annualization factor: at sub-minute
    ///      intervals that factor exceeds 500,000, so oracle jitter of a fraction of a percent
    ///      would annualize past VARIANCE_EXTREME and saturate the margin curve on noise. It
    ///      also keeps `alpha` off its integer-truncation floor — `alpha` is
    ///      `elapsed * BP_SCALE / (elapsed + tau)`, which rounds to 0 below `tau / (BP_SCALE - 1)`
    ///      (~44s at tau = 5 days), where the blend is a no-op regardless of the sample.
    /// @param lastPairPrice The pair's stored price; read for the prior EMA, which must still be
    ///        the pre-update value, so this runs before lastPairPrice is overwritten
    /// @param varianceSample The observation the EMA was last advanced from; updated in place
    /// @param reopenGapEma Peak-hold reopen-gap floor state; advanced when this price ends an
    ///        eligible storage gap (see _observeReopenGap)
    /// @param price The newly resolved spot price (BAZAAR_SCALE)
    /// @param publishTime Oracle publish time of `price`; the sample clock for both endpoints
    /// @return emaVarianceBp The variance EMA to store with the new price
    function calculateVariance(
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.VarianceSample storage varianceSample,
        BazaarTypes.ReopenGapEma storage reopenGapEma,
        uint256 price,
        uint256 publishTime
    ) external returns (uint256 emaVarianceBp) {
        _observeReopenGap(reopenGapEma, lastPairPrice, price, publishTime);

        emaVarianceBp = lastPairPrice.emaVarianceBp;

        // No baseline yet: seed one and hold the EMA. There is no prior observation to measure
        // a return against, so the first stored price only establishes the starting point.
        uint256 lastSpotPrice = varianceSample.spotPrice;
        if (lastSpotPrice == 0) {
            varianceSample.spotPrice = uint192(price);
            varianceSample.publishTs = uint64(publishTime);
            return emaVarianceBp;
        }

        // Callers store strictly increasing publish times, and this sample is always one of
        // those already-stored times, so the interval is positive.
        uint256 elapsed = publishTime - varianceSample.publishTs;
        if (elapsed < VARIANCE_UPDATE_COOLDOWN) return emaVarianceBp;

        uint256 returnBp = price > lastSpotPrice
            ? (price - lastSpotPrice) * BP_SCALE / lastSpotPrice
            : (lastSpotPrice - price) * BP_SCALE / lastSpotPrice;

        uint256 returnSquaredBp = returnBp * returnBp;
        uint256 effectiveElapsed = elapsed > 1 days ? 1 days : elapsed;
        uint256 annualizedReturnSquaredBp = returnSquaredBp * 365 days / effectiveElapsed;

        uint256 tau = 5 days;
        uint256 alpha = elapsed * BP_SCALE / (elapsed + tau);
        alpha = alpha > 5000 ? 5000 : alpha;

        emaVarianceBp = (annualizedReturnSquaredBp * alpha + emaVarianceBp * (BP_SCALE - alpha)) / BP_SCALE;

        varianceSample.spotPrice = uint192(price);
        varianceSample.publishTs = uint64(publishTime);
    }

    /// @notice Records the price jump across a market discontinuity (closure, halt, or trading
    ///         break) into the peak-hold reopen-gap floor. Runs on every price store, before
    ///         lastPairPrice is overwritten; only a storage gap of at least
    ///         REOPEN_GAP_MIN_STALENESS is eligible — anything shorter is on-chain call
    ///         sparsity whose return belongs to the variance EMA, and feeding it here would
    ///         both double-charge diffusion risk and let one noisy intraday observation pin the
    ///         floor for the whole decay horizon.
    /// @dev Peak-hold: the held value decays harmonically with the time since the previous
    ///      accepted observation (at the ~daily observation cadence of a nightly-closing market,
    ///      REOPEN_GAP_EMA_TAU behaves as an exponential time constant), then takes the max with
    ///      the new observation, capped at REOPEN_GAP_EMA_CAP_BP. A mean-tracking EMA would
    ///      average one severe reopen against dozens of quiet ones and learn almost nothing;
    ///      max-then-decay keeps the severe observation load-bearing for months. Decay applies
    ///      only at observation time, deliberately: a pair whose market stops producing reopens
    ///      keeps its last learned floor rather than relaxing unobserved. Continuously traded
    ///      pairs may write here in principle (a dead-quiet pair crossing the threshold) but
    ///      never consume it — calculateIMRandMMR reads the floor only when !isContinuouslyTraded.
    function _observeReopenGap(
        BazaarTypes.ReopenGapEma storage reopenGapEma,
        BazaarTypes.PairPrice storage lastPairPrice,
        uint256 price,
        uint256 publishTime
    ) private {
        uint256 prevTs = lastPairPrice.updateTs;
        uint256 prevSpot = lastPairPrice.spotPrice;
        // Callers store strictly increasing publish times, so the subtraction cannot underflow.
        if (prevTs == 0 || prevSpot == 0 || publishTime - prevTs < REOPEN_GAP_MIN_STALENESS) {
            return;
        }

        uint256 obsGapBp = price > prevSpot
            ? (price - prevSpot) * BP_SCALE / prevSpot
            : (prevSpot - price) * BP_SCALE / prevSpot;

        uint256 held = reopenGapEma.gapEmaBp;
        uint256 lastObsTs = reopenGapEma.lastObsTs;
        if (held != 0 && lastObsTs != 0) {
            uint256 sinceLast = publishTime - lastObsTs;
            held = held * REOPEN_GAP_EMA_TAU / (REOPEN_GAP_EMA_TAU + sinceLast);
        }
        if (obsGapBp > held) held = obsGapBp;
        if (held > REOPEN_GAP_EMA_CAP_BP) held = REOPEN_GAP_EMA_CAP_BP;

        reopenGapEma.gapEmaBp = uint192(held);
        reopenGapEma.lastObsTs = uint64(publishTime);
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

    /// @notice Calculates taker insurance fee. `reopenGapBp` = ReopenGapEma.gapEmaBp for
    ///         non-continuously traded pairs, 0 otherwise (see getTargetInsuranceRatio).
    function getTakerInsuranceFeeEbp(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        uint256 currentPrice,
        uint256 reopenGapBp
    ) external view returns (uint256 feeEbp) {
        (uint256 currentRatioBp,,) = getInsuranceFundToOIRatio(pairVault, currentPrice);
        uint256 targetRatioBp =
            getTargetInsuranceRatio(lastPairPrice.emaVarianceBp, liquidationGapEma.emaGapBp, reopenGapBp);
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
    ///         `reopenGapBp` = ReopenGapEma.gapEmaBp for non-continuously traded pairs, 0 otherwise.
    function getClosingFeeEbp(
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        uint256 reopenGapBp
    ) external view returns (uint256) {
        return getTakerInsuranceFeeBase(
            getTargetInsuranceRatio(lastPairPrice.emaVarianceBp, liquidationGapEma.emaGapBp, reopenGapBp)
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
    /// @dev `reopenGapBp` is the pair's learned reopen-gap floor (ReopenGapEma.gapEmaBp) for
    ///      non-continuously traded pairs and 0 otherwise — zero is inert in the max, so
    ///      continuously traded pairs are unaffected. Half of it floors the target: a reopen of
    ///      that size against one side of a balanced book creates bad debt of at most gap/2 of
    ///      total OI, so the fund target tracks the same demonstrated tail the IMR floor prices.
    ///      Without this leg the target reads only the variance and liquidation-gap EMAs, both
    ///      of which learn a closure jump ex-post — leaving the backstop thinnest exactly when a
    ///      quiet-before-the-event pair is carrying its largest known tail.
    function getTargetInsuranceRatio(uint256 variance, int256 liquidationGapBp, uint256 reopenGapBp)
        internal
        pure
        returns (uint256)
    {
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
        uint256 reopenTarget = reopenGapBp / 2;
        if (reopenTarget > target) target = reopenTarget;
        if (target < INSURANCE_TARGET_BASE) return INSURANCE_TARGET_BASE;
        if (target > INSURANCE_TARGET_MAX) return INSURANCE_TARGET_MAX;
        return target;
    }

    function getVolatilityMultiplier(uint256 variance) public pure returns (uint256) {
        if (variance <= VARIANCE_LOW) return BP_SCALE;
        // Slope fixed by (VARIANCE_LOW, 1x) -> (VARIANCE_EXTREME, MULTIPLIER_MAX); the line
        // continues past VARIANCE_EXTREME until the vol-specific ceiling.
        uint256 multiplier =
            BP_SCALE + (variance - VARIANCE_LOW) * (MULTIPLIER_MAX - BP_SCALE) / (VARIANCE_EXTREME - VARIANCE_LOW);
        return multiplier > VOL_MULTIPLIER_MAX ? VOL_MULTIPLIER_MAX : multiplier;
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
