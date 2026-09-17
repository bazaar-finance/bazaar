// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";

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
    /// @notice Scales the WARMUP floor for a non-continuously traded pair. Past warmup the same
    ///         2x closure prior is structural in stressMoveBp, which gives a session-bound pair
    ///         the whole vol curve as its maintenance level where a 24/7 pair takes half.
    uint256 internal constant NON_CONTINUOUSLY_TRADED_IMR_MULTIPLIER_BP = 20_000;

    /// @notice Reopen-gap floor parameters (non-continuously traded pairs only). A price-storage
    ///         gap of at least REOPEN_GAP_MIN_STALENESS marks a discontinuity worth learning:
    ///         full closures (overnight ≈ 17.5h, weekend ≈ 65h), trading-halt reopens, and
    ///         lunch/maintenance breaks. The threshold's only job is to exclude routine on-chain
    ///         call sparsity: the refresh bounty holds economically live pairs to a ~10-minute
    ///         cadence (REFRESH_BOUNTY_MIN_GAP), so an hour without a stored price on such a
    ///         pair is a genuine market discontinuity, not keeper latency — while returns across
    ///         shorter gaps are diffusion the variance EMA already prices. The |return| across
    ///         an eligible gap feeds a peak-hold estimator — max of the new observation and the
    ///         harmonically decayed prior — which is the reopen leg of a non-continuously traded
    ///         pair's stress move (see stressMoveBp), so both margin and the fund target cover
    ///         the pair's demonstrated jump risk. The cap bounds a single catastrophic reopen's
    ///         effect: it equals MAX_STRESS_MOVE_BP, so a cap-sized gap lands exactly on
    ///         MAX_IMR_BP before the fund-health leg.
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
    uint256 internal constant MULTIPLIER_MAX = 30_000; // 3x ceiling for the insurance multiplier

    /// @notice Ceiling for the volatility multiplier. The vol curve is linear in VARIANCE (not
    ///         vol), which holds margin-per-daily-sigma roughly constant as vol rises — a low
    ///         cap breaks exactly that property in the regimes that need it most, pricing 100%
    ///         and 230% annualized vol identically. So the same line continues past the 3x the
    ///         insurance multiplier stops at, saturating at 6x near 157% annualized vol. The vol
    ///         leg earns the higher ceiling because it is the only EX-ANTE leg: the
    ///         liquidation-gap term and the insurance multiplier both price damage already
    ///         realized (bad fills, a depleted fund), while variance rises before losses land.
    uint256 internal constant VOL_MULTIPLIER_MAX = 60_000;

    /// @notice Bounds on the stress move (see stressMoveBp), the maintenance-level price move
    ///         both the margin curve and the fund target are derived from. They are exactly half
    ///         the IMR clamps, because IMR is twice the stress move: flooring at MIN_IMR_BP / 2
    ///         makes the IMR floor bind through the same number the target reads rather than
    ///         beside it, and the ceiling bounds the liquidation-gap term — whose EMA has no
    ///         intrinsic upper bound, since a fill against an inherited short can print
    ///         arbitrarily far past the estates' bankruptcy price — before it reaches either
    ///         output.
    uint256 internal constant MIN_STRESS_MOVE_BP = MIN_IMR_BP / 2; // 2%
    uint256 internal constant MAX_STRESS_MOVE_BP = MAX_IMR_BP / 2; // 40%

    /// @notice Clamps on the fund target ratio (in bp)
    uint256 internal constant INSURANCE_TARGET_BASE = BazaarTypes.INSURANCE_TARGET_BASE;
    uint256 internal constant INSURANCE_TARGET_MAX = BazaarTypes.INSURANCE_TARGET_MAX;

    /// @notice The fund target as a share of the stress move, in bp. The fund pays what a
    ///         liquidation loses BEYOND maintenance margin, and for a fat-tailed return that
    ///         shortfall scales with the quantile it is measured past — so the target is
    ///         proportional to the move maintenance margin is set to survive rather than
    ///         reasoned about on a curve of its own. Two curves over the same estimators drift
    ///         apart at every clamp and slope: coverage per unit of maintenance margin then
    ///         swings with the regime, and the same demonstrated tail buys a session-bound pair
    ///         and a 24/7 pair very different backstops. At 1x the fund is sized to absorb one
    ///         further stress move beyond the maintenance level traders already hold, which puts
    ///         MIN_STRESS_MOVE_BP exactly on INSURANCE_TARGET_BASE.
    uint256 internal constant INSURANCE_TARGET_KAPPA_BP = 10_000;

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

    // -------------------- IMR/MMR --------------------

    /// @notice Recomputes the pair's IMR/MMR and caches the insurance target both are sized
    ///         against.
    /// @dev Both outputs come off ONE risk estimate, the stress move M (stressMoveBp): margin is
    ///      2 x M before the fund-health leg, and the target is INSURANCE_TARGET_KAPPA_BP of M.
    ///      A pair whose risk rises therefore raises both together and in proportion.
    ///
    ///      The fund-health multiplier is applied LAST, to the enforced margin only, and never
    ///      reaches the target. Deriving the target from a margin figure that already carries
    ///      the multiplier would close a loop: a fund below target would raise the target, which
    ///      deepens the measured shortfall, which raises it again. The loop has no stable
    ///      resting point at full coverage — a fund exactly at target settles instead on a
    ///      phantom shortfall of half the target and twice the margin — so the two must be
    ///      computed in this order.
    ///
    ///      The target is cached on the vault ahead of the cooldown so the reserve the ADL gate
    ///      and the unload walk derive from it tracks the live curve on every entry point, not
    ///      only when margin itself moves.
    function calculateIMRandMMR(
        BazaarTypes.MarginRequirements storage marginRequirements,
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.ReopenGapEma storage reopenGapEma,
        uint256 currentPrice,
        bool isContinuouslyTraded,
        uint256 pairCreatedTs,
        uint256 priceUpdateCount,
        int256 currentFundingIndex
    ) external {
        uint256 stressBp = stressMoveBp(
            lastPairPrice.emaVarianceBp, liquidationGapEma.emaGapBp, reopenGapEma.gapEmaBp, isContinuouslyTraded
        );
        uint256 targetInsuranceRatioBp = getTargetInsuranceRatio(stressBp);
        pairVault.targetInsuranceRatioBp = targetInsuranceRatioBp;

        if (block.timestamp < marginRequirements.lastUpdateTs + IMR_UPDATE_COOLDOWN) return;

        (uint256 insuranceRatioBp,,) = getInsuranceFundToOIRatio(pairVault, currentPrice, currentFundingIndex);

        // IMR = 2 x M, so MMR lands on the stress move itself: a position held at the
        // maintenance level survives exactly one M, and initial margin survives two. The
        // fund-health leg then scales what traders are charged, never what the fund is sized to.
        uint256 newImrBp = 2 * stressBp * getInsuranceMultiplier(insuranceRatioBp, targetInsuranceRatioBp) / BP_SCALE;

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
    ///      - OI notional and the fund's free capital must each exceed their $10,000 floors
    ///        (REFRESH_BOUNTY_MIN_OI_NOTIONAL / REFRESH_BOUNTY_MIN_INSURANCE): a pair with no
    ///        meaningful exposure does not need paid freshness, and a small fund is not
    ///        drained for it. Free capital rather than the balance, because the seizure
    ///        earmarked against inventory the vault still holds settles that inventory and
    ///        never pays a keeper.
    ///      The insurance deduction and the escrow credit happen together, so the fund's claim
    ///      on the pair's USDC and the escrow's move in lockstep. The keeper pulls the bounty
    ///      via BazaarPair.claimFees; no token transfer runs inside the refresh, so nothing a
    ///      keeper's address does can revert it.
    /// @param vault The pair vault (insurance fund source, OI totals)
    /// @param lastPrice The pair's stored price, read after the refresh
    /// @param feeEscrow The pair's fee escrow, credited with the bounty
    /// @param pairId The pair id carried by the accrual event
    /// @param prevUpdateTs The stored price's updateTs captured before the refresh
    function payRefreshBounty(
        BazaarTypes.Vault storage vault,
        BazaarTypes.PairPrice storage lastPrice,
        BazaarTypes.FeeEscrow storage feeEscrow,
        bytes32 pairId,
        uint256 prevUpdateTs
    ) external {
        if (lastPrice.updateTs <= prevUpdateTs) return;
        if (block.timestamp <= prevUpdateTs + REFRESH_BOUNTY_MIN_GAP) return;
        if (insuranceFreeCapital(vault) <= REFRESH_BOUNTY_MIN_INSURANCE) return;
        // Same floored-notional shape as the insurance withdrawal rate limit: OI at fresh spot.
        uint256 oiNotional = Math.mulDiv(openInterestSize(vault), lastPrice.spotPrice, BAZAAR_SCALE);
        if (oiNotional <= REFRESH_BOUNTY_MIN_OI_NOTIONAL) return;

        vault.insuranceFundBalance -= REFRESH_BOUNTY;
        FeeEscrowLib.credit(feeEscrow, pairId, msg.sender, REFRESH_BOUNTY);
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

        uint256 obsGapBp =
            price > prevSpot ? (price - prevSpot) * BP_SCALE / prevSpot : (prevSpot - price) * BP_SCALE / prevSpot;

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

    // -------------------- Open interest --------------------

    /// @notice The exposure one side of the book carries, including inventory the vault
    ///         inherited from liquidations.
    /// @dev Per-side: a position is counted once, not once per counterparty. Every consumer's
    ///      threshold is calibrated against this basis.
    ///
    ///      The vault's inherited inventory is counted on the side it sits. A liquidation moves
    ///      size out of the OI aggregates and into pendingLiqSize without changing the exposure —
    ///      the vault simply stands where the trader stood — so reading the aggregates alone would
    ///      report the book shrinking at the moment the vault takes on risk, inflating every
    ///      coverage ratio measured against it.
    ///
    ///      max of the two sides rather than either leg alone, because a liquidation can drain
    ///      whichever side it lands on. The sides are equal whenever the aggregates are exact, so
    ///      max is also the conservative read should a saturating decrement elsewhere ever floor
    ///      one leg early.
    /// @param v The pair's vault aggregates
    /// @return Per-side open-interest size in BAZAAR_SCALE precision
    function openInterestSize(BazaarTypes.Vault storage v) internal view returns (uint256) {
        uint256 longSide = v.totalLongOI;
        uint256 shortSide = v.totalShortOI;
        uint256 pending = v.pendingLiqSize;
        if (pending != 0) {
            if (v.pendingLiqIsLong) longSide += pending;
            else shortSide += pending;
        }
        return longSide > shortSide ? longSide : shortSide;
    }

    /// @notice openInterestSize for a caller holding a copy of the vault's aggregates rather than
    ///         its storage. Same per-side basis: the vault's inventory counts on the side it sits.
    /// @param longOI Long-side open interest of live positions
    /// @param shortOI Short-side open interest of live positions
    /// @param pendingSize Inventory the vault holds
    /// @param pendingIsLong Side the vault's inventory sits on
    /// @return Per-side open-interest size in BAZAAR_SCALE precision
    function openInterestSizeOf(uint256 longOI, uint256 shortOI, uint256 pendingSize, bool pendingIsLong)
        internal
        pure
        returns (uint256)
    {
        if (pendingIsLong) longOI += pendingSize;
        else shortOI += pendingSize;
        return longOI > shortOI ? longOI : shortOI;
    }

    // -------------------- Vault inventory --------------------

    /// @notice Signed PnL of `size` units of inherited inventory closed at `price`, measured from
    ///         the liquidatees' entry on both legs. The arithmetic behind vaultPnl, on values
    ///         rather than storage.
    /// @param size Inventory size in BAZAAR_SCALE precision
    /// @param entryNotional Σ entryPrice × size of the estates
    /// @param entryFundingIndex Size-weighted entry funding index of the estates
    /// @param isLong Side the inventory sits on
    /// @param price Price to value the inventory at (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return Signed PnL in BAZAAR_SCALE precision; 0 when `size` is 0
    function inventoryPnl(
        uint256 size,
        uint256 entryNotional,
        int256 entryFundingIndex,
        bool isLong,
        uint256 price,
        int256 currentFundingIndex
    ) internal pure returns (int256) {
        if (size == 0) return 0;

        int256 currentNotional = int256(Math.mulDiv(size, price, BAZAAR_SCALE));
        int256 rawFunding =
            BazaarMathLib.signedMulDiv(currentFundingIndex - entryFundingIndex, int256(size), int256(BAZAAR_SCALE));

        return isLong
            ? currentNotional - int256(entryNotional) - rawFunding
            : int256(entryNotional) - currentNotional + rawFunding;
    }

    /// @notice What insurance realizes if the vault's inherited inventory closes at
    ///         `currentPrice`. Negative is a claim the fund has not paid yet.
    /// @dev Measured from the LIQUIDATEES' ENTRY on both legs, matching what MatchingEngineLib
    ///      settles on an unload fill — so this is a forecast of that settlement rather than an
    ///      independent estimate. The seized collateral is deliberately absent: it already sits
    ///      in insuranceFundBalance, so a caller comparing this against the fund picks it up
    ///      from the fund side and must not add it here.
    ///
    ///      The funding leg spans entry → now for the same reason the aggregate carries the
    ///      liquidatees' entry index: the estates have no surviving owner, so their
    ///      pre-liquidation funding and the vault's holding window settle into insurance
    ///      together as one signed term.
    ///
    ///      Public rather than internal so it reaches callers through this library's
    ///      DELEGATECALL instead of being inlined into every consumer; BazaarPair reaches it
    ///      via VaultHealthLib and has no room to carry the arithmetic itself. The size is read
    ///      first so an empty vault costs one storage read.
    /// @param v The pair's vault aggregates
    /// @param currentPrice Price to value the inventory at (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return Signed PnL in BAZAAR_SCALE precision; 0 when the vault holds no inventory
    function vaultPnl(BazaarTypes.Vault storage v, uint256 currentPrice, int256 currentFundingIndex)
        public
        view
        returns (int256)
    {
        uint256 size = v.pendingLiqSize;
        if (size == 0) return 0;
        return inventoryPnl(
            size,
            v.pendingLiqEntryNotional,
            v.pendingLiqEntryFundingIndex,
            v.pendingLiqIsLong,
            currentPrice,
            currentFundingIndex
        );
    }

    /// @notice The three figures the ADL gate and the unload walk share: what the inventory
    ///         costs the fund at the mark, what the fund may spend on it, and what finishing it
    ///         at the edge of the unload band would cost.
    /// @dev All three exclude the collateral seized into the fund alongside the inventory. It
    ///      is earmarked against exactly these estates, so it has to leave both sides of the
    ///      comparison: charge the loss from entry against the raw balance and every fresh
    ///      liquidation trips the gate, because a position liquidated at its margin boundary
    ///      has lost its collateral by construction; charge the loss from the bankruptcy price
    ///      against that same raw balance and the trigger rises by the seizure, so the larger
    ///      the position taken on the harder it becomes to fire.
    ///
    ///      `base` is free capital less a reserve of ADL_RESERVE_BP of the insurance target on
    ///      the per-side open interest. The reserve is a dollar amount at any moment rather than
    ///      a share of the fund, which is what keeps repeated walks from each re-deriving a
    ///      fresh share of a shrinking balance: unloads move `base` one for one and leave the
    ///      reserve for the realizations no bound can refuse. An unload never grows per-side
    ///      open interest — the inventory moves to a maker on the vault's own side, or shrinks
    ///      both sides when the maker is closing the opposite one — so the reserve a walk was
    ///      planned against can only fall during it.
    ///
    ///      `worstFinish` values the inventory at the unload band's edge, min(mmrBp,
    ///      LIQ_MAX_SLIPPAGE_BP) beyond the oracle against the vault. It is the release side of
    ///      the gate's hysteresis and the ADL batch's target: the auction ends once the fund
    ///      above its reserve could sell everything left inside the band, so the walk that
    ///      resumes afterwards can finish the remainder without reopening the window. Zero
    ///      whenever the band edge still sits on the profitable side of the fund-neutral price.
    /// @param v The pair's vault aggregates
    /// @param currentPrice Price to value the inventory at (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param mmrBp The maintenance margin the unload band is derived from
    /// @return expectedLoss What closing the inventory at `currentPrice` costs beyond the
    ///         collateral taken in; 0 when the episode is whole
    /// @return base Free capital above the reserve; 0 when the fund is at or below it
    /// @return worstFinish What closing the inventory at the band edge would cost; 0 when whole
    /// @return shortfall How far free capital sits below the reserve; 0 when at or above it. The
    ///         batch sizing needs the unfloored gap, since a reserve released by the units it
    ///         closes must cover this before any of it reaches the base.
    function vaultAdlExposure(
        BazaarTypes.Vault storage v,
        uint256 currentPrice,
        int256 currentFundingIndex,
        uint256 mmrBp
    ) public view returns (uint256 expectedLoss, uint256 base, uint256 worstFinish, uint256 shortfall) {
        expectedLoss = lossAt(v, currentPrice, currentFundingIndex);
        uint256 bandBp = mmrBp < BazaarTypes.LIQ_MAX_SLIPPAGE_BP ? mmrBp : BazaarTypes.LIQ_MAX_SLIPPAGE_BP;
        uint256 bandEdge = v.pendingLiqIsLong
            ? currentPrice * (BP_SCALE - bandBp) / BP_SCALE
            : currentPrice * (BP_SCALE + bandBp) / BP_SCALE;
        worstFinish = lossAt(v, bandEdge, currentFundingIndex);
        uint256 reserve = adlReserve(v, currentPrice);
        uint256 free = insuranceFreeCapital(v);
        if (free > reserve) base = free - reserve;
        else shortfall = reserve - free;
    }

    /// @notice The reserve the unload walk never spends: ADL_RESERVE_BP of the insurance target
    ///         on `oiSize` valued at `price`.
    /// @param oiSize Per-side open interest, the vault's inventory included (openInterestSize)
    /// @param price Price to value it at (BAZAAR_SCALE precision)
    /// @param targetInsuranceRatioBp The insurance target ratio the margin curve last computed
    /// @return The reserve in BAZAAR_SCALE precision
    function adlReserveOf(uint256 oiSize, uint256 price, uint256 targetInsuranceRatioBp)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(
            Math.mulDiv(oiSize, price, BAZAAR_SCALE),
            targetInsuranceRatioBp * BazaarTypes.ADL_RESERVE_BP,
            BP_SCALE * BP_SCALE
        );
    }

    /// @notice adlReserveOf on the pair's vault aggregates.
    /// @param v The pair's vault aggregates
    /// @param price Price to value the open interest at (BAZAAR_SCALE precision)
    /// @return The reserve in BAZAAR_SCALE precision
    function adlReserve(BazaarTypes.Vault storage v, uint256 price) internal view returns (uint256) {
        return adlReserveOf(openInterestSize(v), price, v.targetInsuranceRatioBp);
    }

    /// @notice The inventory's net position at `price`: the collateral seized alongside it plus
    ///         its PnL from the estates' entry. Positive when closing there returns more than
    ///         the seizure, negative by the loss the seizure does not cover.
    /// @param v The pair's vault aggregates
    /// @param price Price to value the inventory at (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return Signed net position in BAZAAR_SCALE precision
    function inventoryNet(BazaarTypes.Vault storage v, uint256 price, int256 currentFundingIndex)
        internal
        view
        returns (int256)
    {
        return int256(pendingLiqSeizedCollateral(v)) + vaultPnl(v, price, currentFundingIndex);
    }

    /// @notice What closing the inventory at `price` would cost the fund beyond the collateral
    ///         seized alongside it; 0 when the close pays the seizure back in full.
    /// @param v The pair's vault aggregates
    /// @param price Price to value the inventory at (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return The uncovered loss in BAZAAR_SCALE precision
    function lossAt(BazaarTypes.Vault storage v, uint256 price, int256 currentFundingIndex)
        internal
        view
        returns (uint256)
    {
        int256 net = inventoryNet(v, price, currentFundingIndex);
        return net < 0 ? uint256(-net) : 0;
    }

    /// @notice Collateral the insurance fund received alongside inventory the vault still holds.
    /// @dev Tracked as its own aggregate rather than recovered from the two notionals. The
    ///      bankruptcy price folds in the funding the estate had accrued before liquidation, and
    ///      vaultPnl realizes that stretch again from the estate's entry, so entry − bankruptcy
    ///      overstates or understates the seizure by exactly that term and misplaces the price
    ///      at which the inventory is whole. What the fund actually received is what settles the
    ///      inventory, capped-seizure cases included: an estate the deposits ledger could not
    ///      fully back leaves a smaller earmark, so its shortfall shows as loss here rather than
    ///      as a phantom cushion.
    ///
    ///      It takes no price. Free capital, the balance less this figure, is the
    ///      price-independent part of both share-pricing bases: the part no redemption can time.
    /// @param v The pair's vault aggregates
    /// @return The seizure still earmarked against open inventory, in BAZAAR_SCALE precision
    function pendingLiqSeizedCollateral(BazaarTypes.Vault storage v) internal view returns (uint256) {
        return v.pendingLiqSeized;
    }

    /// @notice The insurance fund less the seizure earmarked against inventory the vault holds.
    /// @dev Falls to zero rather than underflowing should the fund ever hold less than it has
    ///      earmarked.
    /// @param v The pair's vault aggregates
    /// @return Capital not spoken for by open inventory, in BAZAAR_SCALE precision
    function insuranceFreeCapital(BazaarTypes.Vault storage v) internal view returns (uint256) {
        uint256 fund = v.insuranceFundBalance;
        uint256 seized = pendingLiqSeizedCollateral(v);
        return fund > seized ? fund - seized : 0;
    }

    // -------------------- Insurance share pricing --------------------
    //
    // Shares are minted and redeemed against the fund's value at the mark, not its balance. The
    // balance overstates that value while the vault holds inventory: it includes the collateral
    // seized alongside the inventory, which leaves again when the inventory unloads, and it says
    // nothing about what the unload itself will realize. Both bases start from free capital (the
    // balance less the seizure) and add the inventory's net position at the mark, with two
    // asymmetries:
    //
    //   * A loss counts only as far as the fund itself will bear it: up to free capital above
    //     the reserve. Beyond that the unload walk stops and the ADL closes the remainder at the
    //     estates' bankruptcy price, where the seizure covers the loss exactly, so the excess is
    //     taken from the winners, not the fund. An uncapped deduction would value the fund below
    //     what the ADL guarantees it keeps, and a deposit priced against that figure would buy the
    //     reserve from the incumbents rather than cover a loss.
    //
    //   * A redemption never collects an unrealized gain. It is not cash yet, paying it hands the
    //     leaver a price-timing option inside the redemption window, and the remaining LPs would
    //     hold the reversal if the unload fills short of the mark. A deposit does pay for it:
    //     otherwise it would buy the pending profit at a discount.
    //
    // Both bases therefore require a mark the caller resolved FRESH, which is why neither side
    // accepts the frozen fallback of a closed venue while the vault holds inventory. The frozen
    // mark cannot see the reopen, and whichever way the inventory moved across the closure, the
    // party who can see the reopen off-chain takes the difference from the other LPs: a redemption
    // priced below the reopen escapes a loss, and a deposit priced below it buys the inventory's
    // recovery cheap. No conservative figure closes the deposit side, because inventory upside has
    // no ceiling — a reopen can print anywhere — so the caller waits for a price instead.

    /// @notice The fund's value at the mark: free capital plus the inventory's unrealized gain, or
    ///         less its unrealized loss as far as the fund bears it. This is the basis a DEPOSIT
    ///         is priced against; a redemption caps it at free capital.
    /// @param free Free capital (insuranceFreeCapital)
    /// @param net The inventory's net position at the mark (inventoryNet)
    /// @param reserve The reserve the unload walk never spends (adlReserve)
    /// @return The fund's value in BAZAAR_SCALE precision
    function insuranceNavOf(uint256 free, int256 net, uint256 reserve) internal pure returns (uint256) {
        if (net >= 0) return free + uint256(net);
        uint256 loss = uint256(-net);
        uint256 base = free > reserve ? free - reserve : 0;
        return free - (loss < base ? loss : base);
    }

    /// @notice The basis a redemption is priced against: the fund's value at the mark, capped at
    ///         free capital so no unrealized gain is paid out.
    /// @param free Free capital (insuranceFreeCapital)
    /// @param net The inventory's net position at the mark (inventoryNet)
    /// @param reserve The reserve the unload walk never spends (adlReserve)
    /// @return The redemption basis in BAZAAR_SCALE precision
    function insuranceRedemptionBasisOf(uint256 free, int256 net, uint256 reserve) internal pure returns (uint256) {
        uint256 nav = insuranceNavOf(free, net, reserve);
        return nav < free ? nav : free;
    }

    /// @notice insuranceNavOf on the pair's vault aggregates: the basis a deposit is priced
    ///         against. Free capital when the vault holds no inventory, in which case the mark is
    ///         not read at all.
    /// @param v The pair's vault aggregates
    /// @param price The mark the inventory is valued at (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return The deposit basis in BAZAAR_SCALE precision
    function insuranceDepositBasis(BazaarTypes.Vault storage v, uint256 price, int256 currentFundingIndex)
        internal
        view
        returns (uint256)
    {
        uint256 free = insuranceFreeCapital(v);
        if (v.pendingLiqSize == 0) return free;
        return insuranceNavOf(free, inventoryNet(v, price, currentFundingIndex), adlReserve(v, price));
    }

    /// @notice insuranceRedemptionBasisOf on the pair's vault aggregates. Free capital when the
    ///         vault holds no inventory, in which case the mark is not read.
    /// @param v The pair's vault aggregates
    /// @param price The mark the inventory is valued at (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return The redemption basis in BAZAAR_SCALE precision
    function insuranceRedemptionBasis(BazaarTypes.Vault storage v, uint256 price, int256 currentFundingIndex)
        internal
        view
        returns (uint256)
    {
        uint256 free = insuranceFreeCapital(v);
        if (v.pendingLiqSize == 0) return free;
        return insuranceRedemptionBasisOf(free, inventoryNet(v, price, currentFundingIndex), adlReserve(v, price));
    }

    // -------------------- Insurance fund ratio & fees --------------------

    /// @notice Coverage ratio: capital free to absorb new losses over the open interest that
    ///         can generate them.
    /// @dev Returns the ratio in basis points (e.g., 500 = 5% coverage). OI is converted to
    ///      notional (USDC) using the provided price. Returns type(uint256).max if OI is zero
    ///      (fully covered).
    ///
    ///      The numerator nets out what the fund already owes on the vault's inherited
    ///      inventory. That loss is realized into insurance the moment the inventory unloads,
    ///      so reporting the raw balance counts capital that is on its way out — and counts it
    ///      highest right after a liquidation, when the seizure has just inflated the balance.
    ///      Gains are not credited: an unrealized mark on inventory the vault still has to
    ///      exit is not capital it can spend.
    ///
    ///      At a zero price the claim cannot be valued, so the raw balance is reported and
    ///      ratioBp is 0 — the reading every consumer treats as maximum stress.
    /// @param pairVault The pair's vault aggregates (storage)
    /// @param currentPrice The current price to use for OI notional calculation (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return ratioBp The free capital / OI notional ratio in basis points
    /// @return freeCapital The insurance fund less the unrealized loss on inherited inventory (USDC)
    /// @return totalOINotional The open interest in notional value (USDC)
    function getInsuranceFundToOIRatio(
        BazaarTypes.Vault storage pairVault,
        uint256 currentPrice,
        int256 currentFundingIndex
    ) public view returns (uint256 ratioBp, uint256 freeCapital, uint256 totalOINotional) {
        freeCapital = pairVault.insuranceFundBalance;
        uint256 totalOISize = openInterestSize(pairVault);

        if (currentPrice == 0) {
            // No price provided - can't calculate meaningful ratio
            return (0, freeCapital, 0);
        }

        int256 pnl = vaultPnl(pairVault, currentPrice, currentFundingIndex);
        if (pnl < 0) {
            uint256 committed = uint256(-pnl);
            freeCapital = freeCapital > committed ? freeCapital - committed : 0;
        }

        totalOINotional = Math.mulDiv(totalOISize, currentPrice, BAZAAR_SCALE);

        if (totalOINotional == 0) {
            // No open interest - insurance fund provides infinite coverage
            return (type(uint256).max, freeCapital, 0);
        }

        // Calculate ratio in basis points: (freeCapital / totalOINotional) * BP_SCALE
        ratioBp = (freeCapital * BP_SCALE) / totalOINotional;
    }

    /// @notice Both taker insurance rates in one call: the dynamic rate risk-adding notional
    ///         pays, and the closing (base) rate risk-reducing notional pays.
    /// @dev One entry point because the two share the target-ratio and base-fee curves —
    ///      asking separately recomputes that chain twice, across two delegatecalls, on the
    ///      matching hot path. The reopen-gap state is read here rather than passed pre-zeroed,
    ///      so the rule that only a non-continuously traded pair consumes it lives in
    ///      stressMoveBp and cannot be got wrong at a call site.
    /// @return feeEbp The dynamic taker insurance rate: the base rate, multiplied up by the
    ///         deficit curve while the fund sits below target.
    /// @return closingEbp The base rate at the current target ratio.
    function getInsuranceFeeRates(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        BazaarTypes.ReopenGapEma storage reopenGapEma,
        uint256 currentPrice,
        bool isContinuouslyTraded,
        int256 currentFundingIndex
    ) external view returns (uint256 feeEbp, uint256 closingEbp) {
        (uint256 currentRatioBp,,) = getInsuranceFundToOIRatio(pairVault, currentPrice, currentFundingIndex);
        uint256 targetRatioBp = getTargetInsuranceRatio(
            stressMoveBp(
                lastPairPrice.emaVarianceBp, liquidationGapEma.emaGapBp, reopenGapEma.gapEmaBp, isContinuouslyTraded
            )
        );
        uint256 fBase = getTakerInsuranceFeeBase(targetRatioBp);
        closingEbp = fBase;

        // The base rate is a floor, not a midpoint: a fund at or above target still charges it.
        // Discounting an overfull fund toward zero would price coverage off the fund's current
        // level rather than the risk each new fill adds — flow arriving into a calm, well-funded
        // book would pay nothing for coverage it is about to consume, and the fee stream would
        // collapse to zero exactly when open interest, and with it the target, grows fastest.
        // Genuine excess is returned to LPs through the wider above-target withdrawal budget.
        // `type(uint256).max` (no open interest) lands here too: the first fill pays the base.
        if (currentRatioBp >= targetRatioBp) return (fBase, closingEbp);

        uint256 deficit = ((targetRatioBp - currentRatioBp) * BP_SCALE) / targetRatioBp;
        uint256 deficitSquared = deficit * deficit;
        uint256 bpScaleSquared = BP_SCALE * BP_SCALE;
        feeEbp = fBase * (bpScaleSquared + TAKER_INSURANCE_FEE_MULTIPLIER * deficitSquared) / bpScaleSquared;
        if (feeEbp > TAKER_INSURANCE_FEE_CAP_EBP) feeEbp = TAKER_INSURANCE_FEE_CAP_EBP;
    }

    /// @notice Returns taker insurance base fee
    function getTakerInsuranceFeeBase(uint256 targetRatioBp) public pure returns (uint256) {
        if (targetRatioBp <= INSURANCE_TARGET_BASE) return TAKER_INSURANCE_FEE_MIN_EBP;
        if (targetRatioBp >= INSURANCE_TARGET_MAX) return TAKER_INSURANCE_FEE_MAX_EBP;
        return TAKER_INSURANCE_FEE_MIN_EBP + (targetRatioBp - INSURANCE_TARGET_BASE)
            * (TAKER_INSURANCE_FEE_MAX_EBP - TAKER_INSURANCE_FEE_MIN_EBP)
            / (INSURANCE_TARGET_MAX - INSURANCE_TARGET_BASE);
    }

    /// @notice The stress move: the price move, in bp of notional, that maintenance margin is
    ///         set to survive. Single source of truth for the pair's risk level — margin and the
    ///         fund target are both functions of this one number, so a riskier pair cannot raise
    ///         one without raising the other.
    /// @dev Three legs, composed by asset class:
    ///
    ///      The VOL leg is the variance curve on BASE_IMR_BP. A continuously traded pair takes
    ///      half of it, because IMR is twice the stress move and the curve is stated at the
    ///      initial-margin level. A session-bound pair takes the WHOLE of it, and that
    ///      asymmetry is the closure prior: on a 24/7 market a keeper can interpose as a
    ///      position deteriorates, so a maintenance level at half the curve is enough, while
    ///      across a reopen no liquidation can interpose at all.
    ///
    ///      The REOPEN leg maxes into that same level, because intraday variance says little
    ///      about how far a price jumps across a closure. Max rather than sum: the two are
    ///      ESTIMATORS of one thing, and the same reopen feeds both the variance EMA and the
    ///      peak-hold, so max counts it once. It enters at full size so a position at MMR
    ///      survives an exact repeat of the demonstrated gap — half of it would leave that
    ///      position insolvent on the repeat.
    ///
    ///      The LIQUIDATION-GAP leg ADDS. A positive gap EMA is realized shortfall past the
    ///      estates' bankruptcy price — that is precisely the amount by which maintenance margin
    ///      proved too thin, in the same units, so it belongs in the level rather than as a
    ///      multiplier on it. Adding it at gain 1 also self-cancels: once margin has grown by
    ///      the gap and fills stop landing past bankruptcy, the EMA decays and the term recedes.
    ///      A multiplicative form has neither property — it scales whatever the vol leg already
    ///      says, so the same bad fill costs a calm pair and a volatile one wildly different
    ///      margin, and it compounds with a leg that is already responding to the same episode.
    ///      A negative EMA (fills landing better than bankruptcy) adds nothing: it is evidence
    ///      the level is sufficient, not a licence to lower it below what the vol leg asks.
    /// @param variance The pair's annualized variance EMA (bp²)
    /// @param liquidationGapBp The pair's signed liquidation-gap EMA (bp)
    /// @param reopenGapBp The pair's peak-hold reopen-gap floor (bp); ignored on continuously
    ///        traded pairs, which never consume it
    /// @param isContinuouslyTraded Whether the pair's venue trades around the clock
    /// @return The stress move in bp, clamped to [MIN_STRESS_MOVE_BP, MAX_STRESS_MOVE_BP]
    function stressMoveBp(uint256 variance, int256 liquidationGapBp, uint256 reopenGapBp, bool isContinuouslyTraded)
        internal
        pure
        returns (uint256)
    {
        uint256 volBp = BASE_IMR_BP * getVolatilityMultiplier(variance) / BP_SCALE;
        uint256 m = isContinuouslyTraded ? volBp / 2 : (volBp > reopenGapBp ? volBp : reopenGapBp);
        if (liquidationGapBp > 0) m += uint256(liquidationGapBp);
        if (m < MIN_STRESS_MOVE_BP) return MIN_STRESS_MOVE_BP;
        if (m > MAX_STRESS_MOVE_BP) return MAX_STRESS_MOVE_BP;
        return m;
    }

    /// @notice The fund's target coverage ratio for a pair at stress move `stressMove`. Single
    ///         source of truth — also consumed by InsuranceVaultLib's withdrawal rate-limit
    ///         check; keep any curve change here only.
    /// @dev A flat share of the stress move (INSURANCE_TARGET_KAPPA_BP), clamped to the
    ///      protocol-wide coverage band. The clamps are the only place the target stops tracking
    ///      margin: below INSURANCE_TARGET_BASE a fund small enough not to matter still has to
    ///      exist, and above INSURANCE_TARGET_MAX a pair too risky to back is held to a fixed
    ///      ceiling and left to give on leverage instead — the margin curve keeps climbing past
    ///      the point the fund stops.
    /// @param stressMove The pair's stress move in bp (stressMoveBp)
    /// @return The target coverage ratio in bp
    function getTargetInsuranceRatio(uint256 stressMove) internal pure returns (uint256) {
        uint256 target = stressMove * INSURANCE_TARGET_KAPPA_BP / BP_SCALE;
        if (target < INSURANCE_TARGET_BASE) return INSURANCE_TARGET_BASE;
        if (target > INSURANCE_TARGET_MAX) return INSURANCE_TARGET_MAX;
        return target;
    }

    /// @notice The volatility leg's multiplier on BASE_IMR_BP: 1x at or below VARIANCE_LOW,
    ///         through 3x at VARIANCE_EXTREME, continuing to VOL_MULTIPLIER_MAX.
    /// @dev Internal so both this library and InsuranceVaultLib reach it by inlining. As a
    ///      public library entry it would cost stressMoveBp an external call, which a `pure`
    ///      function cannot make.
    /// @param variance The pair's annualized variance EMA (bp²)
    /// @return The multiplier in bp
    function getVolatilityMultiplier(uint256 variance) internal pure returns (uint256) {
        if (variance <= VARIANCE_LOW) return BP_SCALE;
        // Slope fixed by (VARIANCE_LOW, 1x) -> (VARIANCE_EXTREME, MULTIPLIER_MAX); the line
        // continues past VARIANCE_EXTREME until the vol-specific ceiling.
        uint256 multiplier =
            BP_SCALE + (variance - VARIANCE_LOW) * (MULTIPLIER_MAX - BP_SCALE) / (VARIANCE_EXTREME - VARIANCE_LOW);
        return multiplier > VOL_MULTIPLIER_MAX ? VOL_MULTIPLIER_MAX : multiplier;
    }

    /// @notice The fund-health multiplier on margin: 1x while coverage is at or above target,
    ///         rising linearly to MULTIPLIER_MAX at an empty fund.
    /// @dev The one leg that is NOT part of the stress move. It reads the fund's current level
    ///      rather than the pair's risk, so it belongs on what traders are charged and not on
    ///      what the fund is sized to hold — see calculateIMRandMMR for why feeding it back into
    ///      the target has no stable resting point.
    /// @param currentRatioBp The fund's coverage ratio (getInsuranceFundToOIRatio)
    /// @param targetRatioBp The target coverage ratio (getTargetInsuranceRatio)
    /// @return The multiplier in bp
    function getInsuranceMultiplier(uint256 currentRatioBp, uint256 targetRatioBp) public pure returns (uint256) {
        if (currentRatioBp >= targetRatioBp) return BP_SCALE;
        if (currentRatioBp == 0) return MULTIPLIER_MAX;
        return BP_SCALE + (targetRatioBp - currentRatioBp) * (MULTIPLIER_MAX - BP_SCALE) / targetRatioBp;
    }
}
