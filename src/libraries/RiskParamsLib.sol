// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";
import {BucketLib} from "./BucketLib.sol";
import {MmrSampleLib} from "./MmrSampleLib.sol";

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
    /// @notice Time constant of both liquidation-outcome EMAs. A slippage or drift reading from
    ///         one episode halves this long after it and keeps falling harmonically
    ///         (fadedLiquidationGapsBp), and evidence a later batch merges into an older reading
    ///         takes on part of its age; the same constant sets how fast the prior's accumulated
    ///         weight is discounted. One constant serves both readings because the same batches
    ///         advance them and both answer the same question — whether there is RECENT
    ///         evidence — about different halves of a liquidation's outcome. Shorter than the
    ///         variance EMA's because liquidations are rarer events, and a shortfall reading should
    ///         not outlive the episode that produced it.
    ///
    ///         Measured on a clock that advances only with stored prices and, on a session pair,
    ///         skips market closures (FADE_SUSPEND_MIN_GAP), so it is three days of time in which
    ///         a liquidation could actually have arrived.
    uint256 internal constant LIQUIDATION_GAP_EMA_TAU = 3 days;

    /// @notice Units per basis point of the stored liquidation-outcome lines
    ///         (BazaarTypes.LiquidationGapEma). Every batch rounds the fade of the prior and the
    ///         blend, so whole basis points would let each batch round a reading down by a point
    ///         or two whatever it carried, and enough dust batches would erase any reading.
    uint256 internal constant GAP_EMA_SCALE = BAZAAR_SCALE;

    /// @notice The least weight the prior carries when a liquidation batch is folded into the
    ///         outcome EMAs, as a share of per-side open interest. A batch enters at its own
    ///         size against max(accumulated weight, this floor), so it moves the estimates by
    ///         its share of the book: a dust unload by a fraction of a basis point, and no single
    ///         estate can replace a pair's history. The unload is a forced taker filling at
    ///         maker-chosen prices, and whoever liquidates an account can also be the maker it
    ///         sells to — buying the inventory back at the band edge costs that party only fees
    ///         while recording the band as the pair's slippage. Weighed against earlier batches
    ///         alone, the first batch on a pair would be copied in whole and a dust estate could
    ///         raise every account's margin for days. The cost is that a genuine wave of
    ///         liquidations worth x% of the book reads x/(1+x) of its slippage on a pair with no
    ///         history; the volatility leg of the stress move rises in the same episode.
    uint256 internal constant LIQ_GAP_PRIOR_FLOOR_BP = 100; // 1% of per-side open-interest size

    /// @notice Time without a stored price that the fade clock refuses to count on a
    ///         non-continuously traded pair. A liquidation either stores the fresh price it runs
    ///         on or needs one stored no more than MAX_LIQUIDATION_PRICE_AGE before it, so a
    ///         stretch this long with nothing stored is one in which no liquidation happened. On a
    ///         session pair whose vault holds inventory it is also one in which none could have —
    ///         the refresh bounty stores a price every REFRESH_BOUNTY_MIN_GAP there whenever the
    ///         feed publishes — so twelve silent hours mean a shut venue. Where that cadence is off
    ///         (no inventory held, or REFRESH_BOUNTY_MIN_INSURANCE unmet) an open market can go
    ///         this long with nothing stored, so a quiet stretch
    ///         around a closure is skipped whole, trading hours included, which errs toward
    ///         holding a reading up rather than releasing it early.
    ///
    ///         A continuously traded pair never skips a gap. Its feed publishes around the clock
    ///         and any liquidator can bring a fresh price to the call, so a silence in the pair's
    ///         own store is inactivity rather than closure: liquidations could have arrived and
    ///         none did, which is exactly the evidence the fade reads. The case this gives up is a
    ///         dark feed on a 24/7 pair, which ages the readings as though the market had traded.
    ///         A threshold on store silence cannot tell that outage from a quiet book, and treating
    ///         every quiet stretch as an outage would freeze the fade on quiet books and make a
    ///         silence just past the threshold age them less than one just short of it.
    ///
    ///         That matters because the fade reads absence of liquidations as evidence the
    ///         maintenance level is holding, and absence of evidence is only informative where
    ///         evidence could have arrived. On a wall clock a session pair spends most of its
    ///         life closed: a weekend alone is 65.5h against a 3-day time constant, which nearly
    ///         halves a shortfall reading while the book is shut and nothing can be learned.
    ///         Left uncorrected the legs decay roughly five times too fast per tradeable hour,
    ///         and they do it worst on exactly the pairs that cannot be liquidated across the
    ///         gap — so the anchors are pushed forward across such a gap instead.
    ///
    ///         Sits above the longest session and below the shortest closure: a US equity venue
    ///         trades 6.5h, its overnight is 17.5h and its weekend 65.5h, so every real closure
    ///         is caught and an open market cannot manufacture a false one. Far above
    ///         REOPEN_GAP_MIN_STALENESS deliberately — that threshold admits lunch breaks and
    ///         halts because it is learning jump SIZES, where crediting an hour of ordinary call
    ///         sparsity as closure here would hold readings up on a live book.
    uint256 internal constant FADE_SUSPEND_MIN_GAP = 12 hours;

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
    ///         call sparsity: trades store prices on an active pair, and while the vault holds
    ///         inventory the refresh bounty holds the pair to a REFRESH_BOUNTY_MIN_GAP cadence,
    ///         so an hour without a stored price on such a pair is a genuine market
    ///         discontinuity, not keeper latency — while returns across shorter gaps are
    ///         diffusion the variance EMA already prices. On a pair with no inventory and no
    ///         trades, stores can be as far apart as REFRESH_BOUNTY_HEARTBEAT, so a gap there is
    ///         not a clean closure: its return spans trading hours as well as any closure inside
    ///         it, which can read above the closure's own jump, or below it where the session
    ///         reversed the jump before the next store. The |return| across
    ///         an eligible gap feeds a peak-hold estimator — max of the new observation and the
    ///         harmonically decayed prior — which is the reopen leg of a non-continuously traded
    ///         pair's stress move (see stressMoveBp), so both margin and the fund target cover
    ///         the pair's demonstrated jump risk.
    ///
    ///         The cap bounds how far one demonstrated gap can suppress a pair on its own. The
    ///         peak enters margin at full size, so the cap is equally the ceiling on the
    ///         maintenance level this leg alone can impose and on how long the decay takes to
    ///         release it. Sitting below MAX_STRESS_MOVE_BP is deliberate: a cap-sized gap
    ///         doubles to an IMR the fund-health multiplier can still lift, where a cap at the
    ///         stress-move ceiling would arrive already saturated and leave a depleted fund no
    ///         margin response at all. Past the cap the leg stops buying coverage and the
    ///         backstop takes over — a repeat beyond it settles through ADL at the estates'
    ///         average bankruptcy price, which leaves the fund whole, rather than being
    ///         pre-funded by every position carrying the whole gap in margin for months.
    ///
    ///         The decay constant is set against the recurrence interval it has to remember
    ///         rather than against any single event: a pair that gaps once a quarter still holds
    ///         half its peak when the next one lands, so a repeating pattern survives its own
    ///         cycle while a one-off keeps fading.
    uint256 internal constant REOPEN_GAP_MIN_STALENESS = 1 hours;
    uint256 internal constant REOPEN_GAP_EMA_TAU = 130 days;
    uint256 internal constant REOPEN_GAP_EMA_CAP_BP = 2_500;

    /// @notice Leverage cap held over a pair's opening stretch, until its risk estimators have
    ///         something to say. Every leg of the stress move is backward-looking and starts at
    ///         zero, and zero variance reads as a calm market rather than an unknown one — so
    ///         without this a freshly listed pair would sit at MIN_IMR_BP whatever asset it
    ///         tracks, at exactly the moment least is known about it.
    /// @dev Applied as a FLOOR on IMR, never an override: a pair that earns more margin during
    ///      warmup, from measured volatility or realized slippage, keeps the curve's number.
    ///
    ///      Both gates must clear, because each is blind alone. Elapsed time buys nothing on a
    ///      dormant pair, whose variance EMA cannot advance without stored prices; a store count
    ///      alone can be run up in a burst, and prices sampled over minutes say nothing about an
    ///      asset's regime. Together they demand real calendar time AND real data density.
    ///
    ///      WARMUP_DURATION is three time constants of the variance EMA it waits on (tau = 5 days
    ///      in calculateVariance). Because that EMA starts from zero it approaches the pair's
    ///      true variance from below, so releasing the floor after a single time constant would
    ///      hand over a vol leg still understating by better than a third — in the same window
    ///      where the slippage, drift and reopen legs are all still empty.
    ///
    ///      The store threshold is calibrated against what the estimator can actually consume:
    ///      VARIANCE_UPDATE_COOLDOWN lets the variance EMA advance at most once a minute, so
    ///      WARMUP_DURATION admits at most 21,600 samples. A threshold far above that would gate
    ///      on transaction count rather than on price history, and could be cleared by spamming
    ///      the permissionless refresh path without teaching the curve anything.
    uint256 internal constant WARMUP_DURATION = 15 days;
    uint256 internal constant WARMUP_PRICE_UPDATE_THRESHOLD = 25_000;
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
    ///         both the margin curve and the fund target are anchored on. They are exactly half
    ///         the IMR clamps, because IMR is twice the stress move: flooring at MIN_IMR_BP / 2
    ///         makes the IMR floor bind through the same number the target reads rather than
    ///         beside it, and the ceiling holds the composed legs to a level positions can still
    ///         be opened against.
    uint256 internal constant MIN_STRESS_MOVE_BP = MIN_IMR_BP / 2; // 2%
    uint256 internal constant MAX_STRESS_MOVE_BP = MAX_IMR_BP / 2; // 40%

    /// @notice Clamps on the fund target ratio (in bp)
    uint256 internal constant INSURANCE_TARGET_BASE = BazaarTypes.INSURANCE_TARGET_BASE;
    uint256 internal constant INSURANCE_TARGET_MAX = BazaarTypes.INSURANCE_TARGET_MAX;

    /// @notice The fund target's forecast leg, as a share of the stress move, in bp. The fund
    ///         pays what a liquidation loses BEYOND maintenance margin, and for a fat-tailed
    ///         return that shortfall scales with the quantile it is measured past — so the
    ///         forecast is proportional to the move maintenance margin is set to survive rather
    ///         than reasoned about on a curve of its own. Two curves over the same estimators
    ///         drift apart at every clamp and slope: coverage per unit of maintenance margin
    ///         then swings with the regime, and the same demonstrated tail buys a session-bound
    ///         pair and a 24/7 pair very different backstops. At 1x the fund is sized to absorb
    ///         one further stress move beyond the maintenance level traders already hold, which
    ///         puts MIN_STRESS_MOVE_BP exactly on INSURANCE_TARGET_BASE.
    uint256 internal constant INSURANCE_TARGET_KAPPA_BP = 10_000;

    // -------------------- Taker insurance fee constants --------------------
    // EBP convention: 100 EBP = 1 bp (EBP_SCALE = 1e6), matching MAKER_INSURANCE_FEE_EBP et al.
    uint256 internal constant TAKER_INSURANCE_FEE_MIN_EBP = 50; // 0.5 bps at INSURANCE_TARGET_BASE (2%)
    uint256 internal constant TAKER_INSURANCE_FEE_MAX_EBP = 400; // 4 bps at INSURANCE_TARGET_MAX (10%)
    uint256 internal constant TAKER_INSURANCE_FEE_MULTIPLIER = 49; // f_base × (1 + MULTIPLIER × δ²)
    uint256 internal constant TAKER_INSURANCE_FEE_CAP_EBP = 5_000; // 50 bps hard cap

    // -------------------- Price-refresh bounty constants --------------------
    uint256 internal constant REFRESH_BOUNTY = BAZAAR_SCALE / 10; // $0.10
    // The cadence the bounty buys while the vault holds inventory worth at least
    // UNLOAD_BOUNTY_MIN_NOTIONAL, and the heartbeat it keeps otherwise (see payRefreshBounty).
    uint256 internal constant REFRESH_BOUNTY_MIN_GAP = 5 minutes;
    uint256 internal constant REFRESH_BOUNTY_HEARTBEAT = 1 days;
    uint256 internal constant REFRESH_BOUNTY_MIN_INSURANCE = 5_000 * BAZAAR_SCALE; // $5,000

    // -------------------- IMR/MMR --------------------

    /// @notice Recomputes the pair's IMR/MMR and caches the insurance target both are sized
    ///         against.
    /// @dev Both outputs are anchored on ONE risk estimate, the stress move M (stressMoveBp):
    ///      margin is 2 x M before the fund-health leg, and the forecast leg of the target is
    ///      INSURANCE_TARGET_KAPPA_BP of M. A pair whose modelled risk rises therefore raises
    ///      both together and in proportion.
    ///
    ///      The two halves of a liquidation's realized outcome are split between the outputs
    ///      rather than pooled, so neither episode is charged twice: execution slippage enters M,
    ///      because it sets what a position must hold to be closable at all, while the drift past
    ///      the estates' bankruptcy price enters the target, because it is the loss the fund
    ///      exists to absorb once a close has overrun that level. Drift still reaches margin, but
    ///      only through the fund-health multiplier below and only while the fund is actually
    ///      short of the target it raised — which bounds its effect at MULTIPLIER_MAX instead of
    ///      letting one bad close add itself to the maintenance level without limit.
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
    ///
    ///      Every call also advances the sample ring (_sampleCurve), whether or not the cooldown
    ///      let the curve move, so the ring sees the rate and the open interest each entry point
    ///      found in force.
    ///
    ///      The arithmetic lives in _cacheTarget and _curveImrBp, and the cooldown test in
    ///      _inCooldown, all shared with liquidationImrBp, so the rate a liquidation judges by and
    ///      every rate stored here come from the same code.
    /// @param marginRequirements The pair's stored margin requirements, rewritten here
    /// @param lastPairPrice The pair's stored mark and variance EMA
    /// @param liquidationGapEma The pair's liquidation-outcome EMAs
    /// @param pairVault The pair's vault aggregates; receives the cached target and the trailing
    ///        open interest
    /// @param reopenGapEma The pair's reopen-gap EMA
    /// @param mmrBuffer The pair's sample ring
    /// @param currentPrice Price the coverage ratio is valued at (BAZAAR_SCALE precision)
    /// @param isContinuouslyTraded False adds the reopen-gap leg and the session margin multiplier
    /// @param pairCreatedTs When the pair was created, for the warmup floor
    /// @param priceUpdateCount Prices stored so far, for the warmup floor
    /// @param currentFundingIndex The pair's live cumulative funding index
    function calculateIMRandMMR(
        BazaarTypes.MarginRequirements storage marginRequirements,
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.ReopenGapEma storage reopenGapEma,
        BazaarTypes.MmrSampleBuffer storage mmrBuffer,
        uint256 currentPrice,
        bool isContinuouslyTraded,
        uint256 pairCreatedTs,
        uint256 priceUpdateCount,
        int256 currentFundingIndex
    ) external {
        (uint256 stressBp, uint256 targetInsuranceRatioBp) = _cacheTarget(
            lastPairPrice, liquidationGapEma, pairVault, reopenGapEma, isContinuouslyTraded
        );

        if (_inCooldown(marginRequirements)) {
            _sampleCurve(mmrBuffer, pairVault, marginRequirements.mmrBp);
            return;
        }

        uint256 newImrBp = _curveImrBp(
            pairVault,
            stressBp,
            targetInsuranceRatioBp,
            currentPrice,
            isContinuouslyTraded,
            pairCreatedTs,
            priceUpdateCount,
            currentFundingIndex
        );
        marginRequirements.imrBp = newImrBp;
        marginRequirements.mmrBp = newImrBp / 2;
        marginRequirements.lastUpdateTs = block.timestamp;
        _sampleCurve(mmrBuffer, pairVault, newImrBp / 2);
    }

    /// @notice The IMR liquidate judges by, from the pair's state now. Nothing about the margin is
    ///         stored: no rate, no cooldown stamp, no ring sample.
    /// @dev The same arithmetic calculateIMRandMMR stores, from the same helpers. Past the
    ///      cooldown it is the rate a write now would store: every fill refreshes the curve
    ///      before it fills, and past the cooldown that refresh stamps it, so nothing can have
    ///      filled at this timestamp and the rate holds no open interest the caller's own
    ///      transaction opened. Inside the cooldown that no longer holds, since a wash opened
    ///      earlier in the transaction reaches the live curve, so the stored rate caps it: a fall
    ///      since the last store applies at once and a rise waits for the next write.
    ///
    ///      Computing instead of writing leaves the cooldown unstamped, so the write liquidate
    ///      makes after its walk can still store the state the walk leaves; a stamp written before
    ///      the walk would hold it off until the next caller. The target is cached as on every
    ///      curve call: no open interest moves it, and the unload walk's reserve reads it.
    /// @param marginRequirements The pair's stored margin requirements, read only
    /// @param lastPairPrice The pair's stored mark and variance EMA
    /// @param liquidationGapEma The pair's liquidation-outcome EMAs
    /// @param pairVault The pair's vault aggregates; receives the cached target
    /// @param reopenGapEma The pair's reopen-gap EMA
    /// @param currentPrice Price the coverage ratio is valued at (BAZAAR_SCALE precision)
    /// @param isContinuouslyTraded False adds the reopen-gap leg and the session margin multiplier
    /// @param pairCreatedTs When the pair was created, for the warmup floor
    /// @param priceUpdateCount Prices stored so far, for the warmup floor
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return imrBp The IMR in basis points
    function liquidationImrBp(
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
    ) external returns (uint256 imrBp) {
        (uint256 stressBp, uint256 targetInsuranceRatioBp) = _cacheTarget(
            lastPairPrice, liquidationGapEma, pairVault, reopenGapEma, isContinuouslyTraded
        );
        imrBp = _curveImrBp(
            pairVault,
            stressBp,
            targetInsuranceRatioBp,
            currentPrice,
            isContinuouslyTraded,
            pairCreatedTs,
            priceUpdateCount,
            currentFundingIndex
        );
        uint256 storedImrBp = marginRequirements.imrBp;
        if (storedImrBp < imrBp && _inCooldown(marginRequirements)) imrBp = storedImrBp;
    }

    /// @dev Whether IMR_UPDATE_COOLDOWN still holds the stored curve.
    function _inCooldown(BazaarTypes.MarginRequirements storage marginRequirements) private view returns (bool) {
        return block.timestamp < marginRequirements.lastUpdateTs + IMR_UPDATE_COOLDOWN;
    }

    /// @dev The stress move M and the fund target it sizes, with the target cached on the vault.
    function _cacheTarget(
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.ReopenGapEma storage reopenGapEma,
        bool isContinuouslyTraded
    ) private returns (uint256 stressBp, uint256 targetInsuranceRatioBp) {
        (int256 slippageBp, int256 driftBp) = fadedLiquidationGapsBp(liquidationGapEma, lastPairPrice);
        stressBp = stressMoveBp(lastPairPrice.emaVarianceBp, slippageBp, reopenGapEma.gapEmaBp, isContinuouslyTraded);
        targetInsuranceRatioBp = getTargetInsuranceRatio(stressBp, driftBp);
        pairVault.targetInsuranceRatioBp = targetInsuranceRatioBp;
    }

    /// @dev The IMR from M and the fund's coverage against its target: 2 x M scaled by the
    ///      fund-health multiplier, clamped, and floored during warmup.
    function _curveImrBp(
        BazaarTypes.Vault storage pairVault,
        uint256 stressBp,
        uint256 targetInsuranceRatioBp,
        uint256 currentPrice,
        bool isContinuouslyTraded,
        uint256 pairCreatedTs,
        uint256 priceUpdateCount,
        int256 currentFundingIndex
    ) private view returns (uint256 imrBp) {
        (uint256 insuranceRatioBp,,) = getInsuranceFundToOIRatio(pairVault, currentPrice, currentFundingIndex);

        // IMR = 2 x M, so MMR lands on the stress move itself: a position held at the
        // maintenance level survives exactly one M, and initial margin survives two. The
        // fund-health leg then scales what traders are charged, never what the fund is sized to.
        imrBp = 2 * stressBp * getInsuranceMultiplier(insuranceRatioBp, targetInsuranceRatioBp) / BP_SCALE;

        if (imrBp < MIN_IMR_BP) imrBp = MIN_IMR_BP;
        if (imrBp > MAX_IMR_BP) imrBp = MAX_IMR_BP;

        // During warmup, enforce 5x max leverage (20% IMR floor)
        if (block.timestamp - pairCreatedTs < WARMUP_DURATION || priceUpdateCount < WARMUP_PRICE_UPDATE_THRESHOLD) {
            uint256 minWarmupImrBp = isContinuouslyTraded
                ? WARMUP_MIN_IMR_BP
                : WARMUP_MIN_IMR_BP * NON_CONTINUOUSLY_TRADED_IMR_MULTIPLIER_BP / BP_SCALE;
            if (imrBp < minWarmupImrBp) imrBp = minWarmupImrBp;
        }
    }

    /// @dev Advances the sample ring with the maintenance rate in force and the vault's live
    ///      open interest, and keeps Vault.trailingOiSize, the trailing minimum the reserve is
    ///      sized on, in step with it.
    ///
    ///      The ring is walked only when an interval closes, once per MMR_SAMPLE_INTERVAL: that
    ///      is when a sample joins the window and the oldest may leave it. Between closes the
    ///      minimum can only fall, and only when this call lowered the open interval's own
    ///      minimum, which needs no walk; a call that did neither leaves the cache unread. A
    ///      sample that ages out of the window between closes therefore stays in the cached
    ///      figure until the next one, so the cache can sit below the true minimum by up to one
    ///      interval's worth of history and never above it: a rise reaches the reserve late,
    ///      never early.
    ///
    ///      A found minimum of zero is stored as 1, the smallest size, because zero in the cache
    ///      means no sampled interval is a full MMR_GRACE_PERIOD old.
    /// @param mmrBuffer The pair's sample ring
    /// @param pairVault The pair's vault aggregates
    /// @param mmrBp The maintenance rate now in force
    function _sampleCurve(
        BazaarTypes.MmrSampleBuffer storage mmrBuffer,
        BazaarTypes.Vault storage pairVault,
        uint256 mmrBp
    ) private {
        uint256 oiSize = openInterestSize(pairVault);
        (bool closed, bool oiLowered) = MmrSampleLib.record(mmrBuffer, mmrBp, oiSize);
        if (closed) {
            (uint256 trailing, bool found) = MmrSampleLib.trailingOi(mmrBuffer);
            if (found && trailing == 0) trailing = 1;
            // The ring holds sizes in the same narrow field, so the cast cannot truncate.
            if (trailing != pairVault.trailingOiSize) pairVault.trailingOiSize = uint128(trailing);
        } else if (oiLowered) {
            uint256 cached = pairVault.trailingOiSize;
            // Below the cached figure, so inside its field.
            if (cached != 0 && oiSize < cached) pairVault.trailingOiSize = uint128(oiSize == 0 ? 1 : oiSize);
        }
    }

    /// @notice Pays a refreshPrice caller REFRESH_BOUNTY ($0.10) from the insurance fund for
    ///         ending a price-staleness gap. The fund buys freshness at the rate it needs it:
    ///         every REFRESH_BOUNTY_MIN_GAP while the vault holds inventory, because the health
    ///         check a refresh runs at the price it stores is what opens an ADL window when that
    ///         inventory drifts past the trigger on a book too thin to trade; otherwise once per
    ///         REFRESH_BOUNTY_HEARTBEAT, which keeps the pair's stored price well inside
    ///         BazaarPairTerminator.ORACLE_DEAD_THRESHOLD, past which terminateStalePair could
    ///         settle the whole book at it. No fee-earning flow (fills, liquidations) has a reason
    ///         to post Pyth updates to a quiet pair, so nothing else is paid to do either.
    /// @dev Runs via DELEGATECALL in the pair's context, so msg.sender is the keeper. Only
    ///      BazaarPair.refreshPrice calls it, and only when the pair is not terminated (the
    ///      insurance fund backs settlement claims then). Every gate is a silent return, never
    ///      a revert — the price refresh must stand regardless of bounty eligibility. Gates:
    ///      - `lastPrice.updateTs` must have advanced past `prevUpdateTs`: a stored update is
    ///        the service being bought. Reads served from cached or frozen data (e.g. the price
    ///        freeze at a scheduled termination) store nothing — paying them would let callers
    ///        collect against the same stale timestamp repeatedly.
    ///      - The pre-refresh stored price must be older than the cadence the vault's state
    ///        earns: REFRESH_BOUNTY_MIN_GAP while the inventory the vault holds is worth at
    ///        least UNLOAD_BOUNTY_MIN_NOTIONAL at the fresh spot (the same line below which the
    ///        unload reward treats inventory as dust), REFRESH_BOUNTY_HEARTBEAT otherwise. The
    ///        gap hard-caps insurance spend at REFRESH_BOUNTY x (1 day / gap) per pair per day no
    ///        matter how aggressively keepers race the gate. Inventory is the gate because it is
    ///        what a fresh mark protects and because it costs something to create: open
    ///        interest alone would not do, since a long and a short held in two wallets meet any
    ///        open-interest floor at no cost beyond the margin they lock, which would let one
    ///        party draw the fast cadence from a dormant pair indefinitely.
    ///      - The fund's free capital must exceed REFRESH_BOUNTY_MIN_INSURANCE ($5,000), so a
    ///        small fund is not drained for freshness. Free capital rather than the balance,
    ///        because the seizure earmarked against inventory the vault still holds settles that
    ///        inventory and never pays a keeper. There is no open-interest floor: the heartbeat
    ///        is what keeps a pair with positions but no trades from reaching
    ///        BazaarPairTerminator.ORACLE_DEAD_THRESHOLD, and an open-interest floor would
    ///        switch it off on exactly the quiet pairs that need it, while open interest itself
    ///        is the figure a parked long and short can meet for nothing.
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
        uint256 inventoryNotional = Math.mulDiv(vault.pendingLiqSize, lastPrice.spotPrice, BAZAAR_SCALE);
        uint256 minGap = inventoryNotional >= BazaarTypes.UNLOAD_BOUNTY_MIN_NOTIONAL
            ? REFRESH_BOUNTY_MIN_GAP
            : REFRESH_BOUNTY_HEARTBEAT;
        if (block.timestamp <= prevUpdateTs + minGap) return;
        if (insuranceFreeCapital(vault) <= REFRESH_BOUNTY_MIN_INSURANCE) return;

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
    ///        eligible storage gap (see _observeReopenGap), and its `lastJumpTs` stamped when this
    ///        price jumps from the variance sample
    /// @param liquidationGapEma The slippage/drift EMAs; on a session pair their anchors and
    ///        batch clock are pushed forward when this price ends a closure (see
    ///        _suspendFadeAcrossClosure)
    /// @param price The newly resolved spot price (BAZAAR_SCALE)
    /// @param publishTime Oracle publish time of `price`; the sample clock for both endpoints
    /// @param isContinuouslyTraded Whether the pair's venue trades around the clock; such a pair
    ///        never has a closure to skip
    /// @return emaVarianceBp The variance EMA to store with the new price
    function calculateVariance(
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.VarianceSample storage varianceSample,
        BazaarTypes.ReopenGapEma storage reopenGapEma,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        uint256 price,
        uint256 publishTime,
        bool isContinuouslyTraded
    ) external returns (uint256 emaVarianceBp) {
        if (!isContinuouslyTraded) {
            _suspendFadeAcrossClosure(liquidationGapEma, lastPairPrice, publishTime);
        }
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

        uint256 returnBp = price > lastSpotPrice
            ? (price - lastSpotPrice) * BP_SCALE / lastSpotPrice
            : (lastSpotPrice - price) * BP_SCALE / lastSpotPrice;

        // A jump of at least the smallest maintenance rate any position carries can take one from
        // its maintenance line past bankruptcy before a keeper acts, so its loss may not be in the
        // books yet; insurance redemptions wait out the time keepers need to seize it. Measured
        // against the sample, which moves at most once per VARIANCE_UPDATE_COOLDOWN, so a move
        // cannot be stored in small steps under the threshold unless it is slow enough for keepers
        // to follow.
        if (returnBp >= MIN_STRESS_MOVE_BP) reopenGapEma.lastJumpTs = uint64(publishTime);

        // Callers store strictly increasing publish times, and this sample is always one of
        // those already-stored times, so the interval is positive.
        uint256 elapsed = publishTime - varianceSample.publishTs;
        if (elapsed < VARIANCE_UPDATE_COOLDOWN) return emaVarianceBp;

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

    /// @dev Pushes the liquidation lines' anchors forward by a market closure, so the harmonic
    ///      fades in fadedLiquidationGapsBp and the weight discount measure only time in which a
    ///      liquidation could have arrived. Readers stop the fade clock at the last stored price,
    ///      which makes this the one place the time between two stores is judged: a gap short of
    ///      FADE_SUSPEND_MIN_GAP is counted as trading time, a longer one is skipped.
    ///
    ///      Runs on every stored price of a non-continuously traded pair, before the store
    ///      overwrites `lastPairPrice.updateTs`. A continuously traded pair never reaches it:
    ///      every gap it has is counted (see FADE_SUSPEND_MIN_GAP for why its silences are
    ///      evidence rather than closures).
    ///
    ///      Advancing the timestamps, rather than accumulating closed time separately, is what
    ///      keeps the value fades and the write-side weight discount on one tradeable clock: each
    ///      takes its age from its own timestamp, and all three move by the same gap.
    ///
    ///      Clamped to the block: callers store Pyth publish times, which may sit slightly ahead
    ///      of `block.timestamp`, and updateLiquidationGapEmaBatch ages the lines and the weight
    ///      by the block minus their timestamps, so one past the block would underflow there. A
    ///      pair with no liquidation history has nothing to move and is left alone; the first
    ///      batch sets all three.
    /// @param g The pair's liquidation-outcome EMAs
    /// @param lastPairPrice The stored price this call is about to supersede; its `updateTs` is
    ///        the near end of the gap
    /// @param publishTime Oracle publish time of the incoming price; the far end of the gap
    function _suspendFadeAcrossClosure(
        BazaarTypes.LiquidationGapEma storage g,
        BazaarTypes.PairPrice storage lastPairPrice,
        uint256 publishTime
    ) private {
        uint256 prevTs = lastPairPrice.updateTs;
        if (prevTs == 0 || g.lastLiquidationTs == 0) return;

        // Callers store strictly increasing publish times, so the subtraction cannot underflow.
        uint256 gap = publishTime - prevTs;
        if (gap < FADE_SUSPEND_MIN_GAP) return;

        g.slippageAnchorTs = _pushedAnchor(g.slippageAnchorTs, gap);
        g.driftAnchorTs = _pushedAnchor(g.driftAnchorTs, gap);
        g.lastLiquidationTs = _pushedAnchor(g.lastLiquidationTs, gap);
    }

    /// @dev `anchorTs` moved forward by `gap`, clamped to the block (_suspendFadeAcrossClosure).
    function _pushedAnchor(uint64 anchorTs, uint256 gap) private view returns (uint64) {
        uint256 pushed = uint256(anchorTs) + gap;
        return uint64(pushed > block.timestamp ? block.timestamp : pushed);
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

        reopenGapEma.gapEmaBp = uint128(held);
        reopenGapEma.lastObsTs = uint64(publishTime);
    }

    /// @notice Folds one transaction's liquidation fills into both liquidation-outcome EMAs.
    /// @dev One update per walk rather than per fill. Within the batch, fills are size-weighted
    ///      into a single slippage and a single drift. Across batches, the new batch enters at
    ///      its own fill size against the accumulated size of every prior batch, discounted by
    ///      the time since the last one and never weighing less than LIQ_GAP_PRIOR_FLOOR_BP of
    ///      per-side open interest, so larger liquidations move the estimates proportionally
    ///      more, old evidence loses weight as it ages, and no batch moves them by more than its
    ///      share of the book. The priors they blend against are the FADED values — the fade
    ///      fadedLiquidationGapsBp reads, taken at full precision — not the raw store: readers see
    ///      the faded values, and a blend against the raw ones would let a batch resurrect evidence
    ///      that had already faded out of the curves, since the weight discount never takes more
    ///      than half.
    ///
    ///      The value clocks. Each half is a line with its own anchor
    ///      (BazaarTypes.LiquidationGapEma). What a blend leaves on it has two parts: what
    ///      survives of the prior, which has aged since the anchor, and what this batch adds,
    ///      which has not aged at all. The new anchor sits back from this block by the line's age
    ///      weighted by the survivor's share of the reading, rounded up, so no batch moves an
    ///      anchor further than its share and a share under a second moves it not at all. The
    ///      line is then stored as of that anchor, scaled so that at this block it reads exactly
    ///      the blend, at GAP_EMA_SCALE units per basis point so the rounding is a negligible
    ///      fraction of a point. A batch that adds nothing to a half leaves its fade where it was,
    ///      and a dust batch leaves both halves where they were to within its own weight.
    ///      Restarting each fade from its faded value at every batch would instead compound it,
    ///      and frequent weightless batches could fade a reading far faster than
    ///      LIQUIDATION_GAP_EMA_TAU. A prior that has faded out, or a pair with no history, gives
    ///      the batch a fresh line. Each half keeps its own anchor because a batch can add to one
    ///      half and nothing to the other.
    ///
    ///      The weight is discounted at every batch by the time since the one before, and the
    ///      batch's own size added, so old batches fade out of it. Carrying it on a backdated
    ///      anchor too would not work with the discount's cap at half: past one time constant the
    ///      discount and its inverse cancel, so a stream of batches would accumulate weight without
    ///      bound and freeze the readings.
    ///
    ///      A pair with no history blends its first batch against a zero prior of the floor's
    ///      weight: its stored values are zero and its anchors unset, so the faded prior reads
    ///      zero whatever the clock says.
    ///
    ///      Both halves share the accumulated weight because they come from the same fills. A
    ///      batch that records one records the other, so there is no state in which the two
    ///      weightings could diverge.
    /// @param g The pair's liquidation-outcome EMAs
    /// @param v The pair's vault aggregates, for the per-side open interest the floor is scaled
    ///        from
    /// @param sumSlipTimesSize Σ (slippage bp x fill size) over the batch; the measurement floors
    ///        every fill at zero, and a negative sum would count as zero
    /// @param sumDriftTimesSize Σ (drift bp x fill size) over the batch, floored the same way
    /// @param totalFillSize Σ fill size over the batch, the weighting denominator. Zero means the
    ///        walk recorded no eligible liquidation fill, which is also the only way the two sums
    ///        can both be empty.
    function updateLiquidationGapEmaBatch(
        BazaarTypes.LiquidationGapEma storage g,
        BazaarTypes.Vault storage v,
        int256 sumSlipTimesSize,
        int256 sumDriftTimesSize,
        uint256 totalFillSize
    ) external {
        if (totalFillSize == 0) return;

        // The weight of every earlier batch, discounted by the time since the last one:
        // alpha = elapsed / (elapsed + tau), capped at 50%, so old weight never loses more than
        // half at once. The timestamps skip market closures (_suspendFadeAcrossClosure), so the
        // discount ages old evidence on the same tradeable clock the value fades use. A pair with
        // no history has nothing to age from and carries no weight.
        uint256 decayedOldSize;
        if (g.decayedSize != 0) {
            uint256 elapsed = block.timestamp - g.lastLiquidationTs;
            uint256 alpha = elapsed * BP_SCALE / (elapsed + LIQUIDATION_GAP_EMA_TAU);
            if (alpha > 5000) alpha = 5000;
            decayedOldSize = g.decayedSize * (BP_SCALE - alpha) / BP_SCALE;
        }

        // The prior weighs at least LIQ_GAP_PRIOR_FLOOR_BP of per-side open interest, so the
        // batch moves the estimates by its share of the book rather than by its share of what
        // earlier batches happened to record.
        uint256 floorSize = openInterestSize(v) * LIQ_GAP_PRIOR_FLOOR_BP / BP_SCALE;
        uint256 priorSize = decayedOldSize > floorSize ? decayedOldSize : floorSize;
        uint256 newSize = priorSize + totalFillSize;

        (g.slippage, g.slippageAnchorTs) =
            _foldLine(g.slippage, g.slippageAnchorTs, priorSize, sumSlipTimesSize, newSize);
        (g.drift, g.driftAnchorTs) = _foldLine(g.drift, g.driftAnchorTs, priorSize, sumDriftTimesSize, newSize);

        g.decayedSize = newSize;
        g.lastLiquidationTs = uint64(block.timestamp);
    }

    /// @dev One value line of updateLiquidationGapEmaBatch: the prior's reading, faded to this
    ///      block, blended by weight with the batch's own reading, and stored as of an anchor
    ///      moved toward the present by the batch's share of the blend. A batch only records off a
    ///      fresh price, stored within MAX_PRICE_STALENESS of the block, so the fade runs to the
    ///      block.
    /// @param stored The line's stored value, GAP_EMA_SCALE units per bp, as of `anchorTs`
    /// @param anchorTs The line's anchor; 0 before any batch
    /// @param priorSize The prior's weight in the blend
    /// @param sumTimesSize Σ (reading bp x fill size) over the batch
    /// @param newSize The blend's whole weight: the prior's and the batch's fill size
    /// @return newStored The line's value as of its new anchor
    /// @return newAnchorTs The line's new anchor
    function _foldLine(uint256 stored, uint64 anchorTs, uint256 priorSize, int256 sumTimesSize, uint256 newSize)
        private
        view
        returns (uint256 newStored, uint64 newAnchorTs)
    {
        uint256 age = anchorTs == 0 ? 0 : block.timestamp - anchorTs;
        uint256 survivor = Math.mulDiv(
            Math.mulDiv(stored, LIQUIDATION_GAP_EMA_TAU, LIQUIDATION_GAP_EMA_TAU + age), priorSize, newSize
        );
        uint256 added = sumTimesSize > 0 ? Math.mulDiv(uint256(sumTimesSize), GAP_EMA_SCALE, newSize) : 0;
        uint256 blend = survivor + added;
        uint256 keptAge = survivor == 0 ? 0 : Math.mulDiv(age, survivor, blend, Math.Rounding.Ceil);
        // Rounded up so that read back at this block the line gives the blend, not a unit below
        // it.
        newStored = Math.mulDiv(blend, LIQUIDATION_GAP_EMA_TAU + keptAge, LIQUIDATION_GAP_EMA_TAU, Math.Rounding.Ceil);
        newAnchorTs = uint64(block.timestamp - keptAge);
    }

    /// @notice The liquidation-outcome EMAs as the margin curve and the fund target consume
    ///         them: each stored line faded toward zero by the tradeable time between its anchor
    ///         and the last stored price, in basis points.
    /// @dev The stored EMAs are weighted averages of what past liquidations realized, and as
    ///      averages they are invariant to time passing with no new observation. Their readers
    ///      ask a different question — whether there is RECENT evidence that the maintenance
    ///      level is too thin, or that closes are overrunning it — and a stretch with no
    ///      liquidations at all is itself evidence that there is not. So the values the curves
    ///      read halve LIQUIDATION_GAP_EMA_TAU after the episode behind them and keep falling
    ///      harmonically, the shape the reopen peak-hold decays with; each line's anchor carries
    ///      the age of what it holds, so evidence merged into an older line takes on part of that
    ///      line's age (updateLiquidationGapEmaBatch). Without the fade, one
    ///      crash would hold a pair's margin and fund target until the next liquidation happened
    ///      to arrive, however long that took, and a pair whose liquidations stopped would never
    ///      return to its volatility curve.
    ///
    ///      The fade clock stops at the last stored price, not at the block. Time between two
    ///      stores is judged only when the second one lands — counted as trading time, or on a
    ///      session pair past FADE_SUSPEND_MIN_GAP skipped as a closure by
    ///      _suspendFadeAcrossClosure — and a read taken inside the gap must not pre-empt that
    ///      judgement. Running the clock to
    ///      the block would fade both legs through a closure that has not ended yet: margin
    ///      recomputed off the stale fallback in that window would come out below what the
    ///      reopen restores, and the lagged-MMR ring would carry the understated rate into the
    ///      next day's liquidation checks. Every estimator in the stress move ages this way — the
    ///      variance EMA and the reopen peak-hold also move only when a price is stored — and
    ///      while the vault holds inventory the lag is at most the refresh bounty's
    ///      REFRESH_BOUNTY_MIN_GAP; otherwise it runs to the next store, which on a pair nobody
    ///      trades can be REFRESH_BOUNTY_HEARTBEAT away.
    ///
    ///      Every reader takes these values, and updateLiquidationGapEmaBatch blends the next
    ///      batch against the same fade at full precision, so the store and the curves never
    ///      disagree. A pair with no liquidation history reads the store as is: there is no anchor
    ///      to fade from.
    /// @param g The pair's liquidation-outcome EMAs
    /// @param lastPairPrice The pair's last stored price, whose updateTs ends the fade clock
    /// @return slippageBp The faded execution-slippage EMA in bp, never negative
    /// @return driftBp The faded past-bankruptcy drift EMA in bp, never negative
    function fadedLiquidationGapsBp(
        BazaarTypes.LiquidationGapEma storage g,
        BazaarTypes.PairPrice storage lastPairPrice
    ) internal view returns (int256 slippageBp, int256 driftBp) {
        return fadedLiquidationGapsOf(g.slippage, g.slippageAnchorTs, g.drift, g.driftAnchorTs, lastPairPrice.updateTs);
    }

    /// @notice Value form of fadedLiquidationGapsBp, for readers that hold the stored fields
    ///         rather than the pair's storage — BazaarPairLens rebuilds the live fund target from
    ///         raw slots with it, so the view and the contract share one fade formula.
    /// @dev The clock ends at the earlier of the last stored price and the block, since a Pyth
    ///      publish time can sit slightly ahead of the block. An anchor can also sit a moment
    ///      past the last stored price — a batch anchors its lines no later than its own block,
    ///      which trails the publish time of the fresh price it ran on — so the elapsed time
    ///      floors at zero instead of underflowing.
    /// @param slippage The stored slippage line, GAP_EMA_SCALE units per bp
    /// @param slippageAnchorTs Its anchor (0 = no liquidation history, nothing to fade)
    /// @param drift The stored drift line, GAP_EMA_SCALE units per bp
    /// @param driftAnchorTs Its anchor (0 = no liquidation history, nothing to fade)
    /// @param lastPriceTs The pair's last stored price time, where the fade clock stops
    /// @return The faded slippage EMA in bp
    /// @return The faded drift EMA in bp
    function fadedLiquidationGapsOf(
        uint256 slippage,
        uint256 slippageAnchorTs,
        uint256 drift,
        uint256 driftAnchorTs,
        uint256 lastPriceTs
    ) internal view returns (int256, int256) {
        uint256 end = lastPriceTs < block.timestamp ? lastPriceTs : block.timestamp;
        return (_fadedLineBp(slippage, slippageAnchorTs, end), _fadedLineBp(drift, driftAnchorTs, end));
    }

    /// @dev One stored line read at `end` in whole basis points (fadedLiquidationGapsOf).
    function _fadedLineBp(uint256 stored, uint256 anchorTs, uint256 end) private pure returns (int256) {
        uint256 elapsed = anchorTs != 0 && end > anchorTs ? end - anchorTs : 0;
        return int256(Math.mulDiv(stored, LIQUIDATION_GAP_EMA_TAU, (LIQUIDATION_GAP_EMA_TAU + elapsed) * GAP_EMA_SCALE));
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
    ///      the per-side open interest reserveOiSizeOf admits: live open interest, capped at its
    ///      trailing minimum. The reserve is a dollar amount at any moment rather than
    ///      a share of the fund, which is what keeps repeated walks from each re-deriving a
    ///      fresh share of a shrinking balance: unloads move `base` one for one and leave the
    ///      reserve for the realizations no bound can refuse. An unload never grows per-side
    ///      open interest — the inventory moves to a maker on the vault's own side, or shrinks
    ///      both sides when the maker is closing the opposite one — so the reserve a walk was
    ///      planned against can only fall or hold during it.
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
    ///         collateral taken in and the ledger's arrears to the fund; 0 when the episode is
    ///         whole
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

    /// @notice What an insurance redemption may pay while the vault holds inventory: free capital
    ///         less the reserve and what finishing the inventory would cost, valued together at
    ///         whichever edge of the unload band makes their sum larger, or 0 when that takes all
    ///         of it (InsuranceVaultLib.executeInsuranceWithdrawal).
    /// @dev The band is the one vaultAdlExposure values the ADL gate's release at, min(mmrBp,
    ///      LIQ_MAX_SLIPPAGE_BP) of the mark, taken here either side of it. The caller passes the
    ///      stored maintenance rate, which is never below the one the gate's band comes from
    ///      (BucketLib.effectiveMmrBp takes the lagged rate only where it is recorded and lower),
    ///      so this band is at least as wide as the gate's.
    ///
    ///      The gate opens at a mark once the inventory's loss there passes free capital above the
    ///      reserve there, so a mark is clear while free capital covers the two together. The
    ///      reserve, the cached fund target's share of open interest valued at the mark, rises
    ///      linearly with the mark; the loss is nil while the inventory is above water and rises
    ///      linearly as the mark moves past its break-even toward the band's edge against the
    ///      vault. Their sum is convex in the mark, so across the band it peaks at one of the two
    ///      edges, and after a payout of at most this, free capital covers it at every mark inside
    ///      the band, up to a unit of rounding in each term, while open interest and the cached
    ///      target hold: no such move opens a window, and the fund sits at or inside the gate's
    ///      release line. On an inventory of shorts both rise toward the upper edge, which always
    ///      decides; on longs the loss falls as the reserve rises, and the upper edge decides only
    ///      where the reserve gains more across the band than the loss sheds. The slack this leaves
    ///      above the gate at the mark itself is the larger edge sum less the sum there, which on
    ///      longs shrinks toward nothing where the reserve and the inventory are about the same
    ///      size: there the refresh bounty or the inventory's funding can open a window right after
    ///      a payout at the cap. The store that carries a move can also cache a higher target, from
    ///      the variance the move adds or a reopen gap, and the reserve then rises with it; nothing
    ///      here holds back for that. A payout lowers free capital by exactly its amount and moves
    ///      neither the reserve, which reads open interest, its trailing minimum and the cached
    ///      target, nor the loss, which reads the inventory, its seizure and the ledger's arrears.
    /// @param v The pair's vault aggregates
    /// @param price The mark the caller resolved (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param mmrBp The stored maintenance rate the unload band is derived from
    /// @return The headroom in BAZAAR_SCALE precision
    function redemptionHeadroom(BazaarTypes.Vault storage v, uint256 price, int256 currentFundingIndex, uint256 mmrBp)
        public
        view
        returns (uint256)
    {
        uint256 bandBp = mmrBp < BazaarTypes.LIQ_MAX_SLIPPAGE_BP ? mmrBp : BazaarTypes.LIQ_MAX_SLIPPAGE_BP;
        uint256 lowerEdge = price * (BP_SCALE - bandBp) / BP_SCALE;
        uint256 upperEdge = price * (BP_SCALE + bandBp) / BP_SCALE;
        uint256 held = adlReserve(v, upperEdge) + lossAt(v, upperEdge, currentFundingIndex);
        uint256 atLower = adlReserve(v, lowerEdge) + lossAt(v, lowerEdge, currentFundingIndex);
        if (atLower > held) held = atLower;
        uint256 free = insuranceFreeCapital(v);
        return free > held ? free - held : 0;
    }

    /// @notice The unload walk's plan: which side the vault sells, the deepest price it takes,
    ///         the reference price a fill is measured against, and how much the fund may spend
    ///         on fills inside that reference (MatchingEngineLib.unloadBook).
    /// @dev Computed once from start-of-walk state, and declared here rather than in
    ///      MatchingEngineLib so that library's EIP-170 budget stays free of it: a plan is
    ///      drawn once per unload walk, so the library hop is paid once, not per fill. Three
    ///      quantities anchor the walk.
    ///
    ///      The fund-neutral price: the price at which closing the inventory pays back exactly
    ///      what backs it — the collateral seized with it plus the ledger's arrears to the fund,
    ///      which settlement nets off the fund's payment — net of the funding accrued since the
    ///      estates entered: the entry basis less that backing, carried forward by that funding,
    ///      valued per unit. A fill at it costs the fund nothing; each unit sold away from it
    ///      costs the distance. With the arrears counted this is the estates' own bankruptcy
    ///      price, funding aside, however much of their collateral the ledger could pay. The
    ///      arrears are one pair-wide balance, though, so the neutral price is also held from
    ///      crossing that bankruptcy price (pendingLiqBankruptcyNotional per unit): a balance
    ///      left behind by inventory already closed would otherwise count as this inventory's
    ///      cushion.
    ///
    ///      The bound starts at the band edge, the oracle moved min(LIQ_MAX_SLIPPAGE_BP, MMR)
    ///      against the vault, and where the fund-neutral price lies beyond that edge it opens
    ///      linearly toward it over UNLOAD_FLOOR_DECAY from the inventory's size-weighted seizure
    ///      time. A maker inside the band is taken at once. One between the edge and the neutral
    ///      price is taken only once the floor has reached it: that region is the estates'
    ///      residual equity, and a floor that sat at bankruptcy from the first instant would hand
    ///      it to whoever bids in the seizing transaction, the liquidator included, instead of to
    ///      the best bid a few minutes of competition produce. One under the neutral price that
    ///      stays inside the band goes through as before. Neither anchor moves during the walk:
    ///      every fill releases a proportional slice of the aggregate, so the neutral price and
    ///      the seizure time are invariant, and the oracle is fixed within the transaction.
    ///
    ///      The headroom is what the fund may spend on fills inside the bound: free capital above
    ///      its reserve (RiskParamsLib.vaultAdlExposure), less the loss the inventory already
    ///      carries at the mark, less the caller's reward when one is paid, set aside so that,
    ///      while the base covers the loss, it need not come out of the reserve. A fill is measured against
    ///      the reference price: beyond it a fill lowers the loss the remainder carries by at
    ///      least what it costs, so it is always taken; inside it a fill costs the difference per
    ///      unit, and the walk takes only what the headroom covers. While the base covers the
    ///      loss at the mark — the gate's own healthy condition — the reference is the nearer of
    ///      the neutral price and the oracle, because the headroom has already set that loss
    ///      aside: spending it to zero leaves the fund above its reserve by exactly the remaining
    ///      inventory's loss at the mark, the pair ends the walk healthy, and the post-walk
    ///      verdict opens the auction only if the price has moved since. Past the trigger nothing
    ///      was set aside, so a fill at the mark would draw cash the fund does not hold above its
    ///      reserve: the reference is the neutral price and the walk takes only fills that cost
    ///      the fund nothing, leaving the rest to the auction. An unload's fills can therefore
    ///      never take the fund below its reserve, nor carry a pair over the ADL trigger it did not
    ///      start past. The second rests on how the walk's loss is paid (fundLedgerFrom): out of
    ///      the earmark the walk released first, and only then net of the arrears. A fill at the
    ///      neutral price, the reference whenever the fund sits at or below its reserve or the
    ///      inventory is above water at the mark, loses no more than that earmark and its share
    ///      of the arrears, so the inventory left keeps at least its own share of them; a fill at
    ///      an oracle reference inside the neutral price loses more, by what the headroom already
    ///      set aside for it. Netted from the arrears first, a fill at the neutral price would
    ///      leave the rest reading worse per unit while the earmark sat in free capital, which
    ///      below the reserve the gate does not count, and the post-walk verdict could open the
    ///      auction on a walk that cost the fund nothing. The caller's reward is set aside in the
    ///      headroom, but a fill at or beyond the reference is taken whatever the headroom, so the
    ///      walk can end with the base covering the loss at the mark by less than the reward; the
    ///      reward is therefore capped at that cover when it is paid (unloadRewardPayable).
    ///
    ///      Rounded toward the vault: the neutral price rounds up as a floor and down as a
    ///      ceiling, and sizes round down.
    /// @param pairVault The pair's vault aggregates
    /// @param oracle The walk's oracle price (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param mr The margin requirements the unload band is derived from
    /// @param prepaid How the caller is paid, as MatchingEngineLib.unloadBook takes it
    /// @return plan The side, bound, reference price and headroom for the walk
    function planUnload(
        BazaarTypes.Vault storage pairVault,
        uint256 oracle,
        int256 currentFundingIndex,
        BazaarTypes.MarginRequirements memory mr,
        uint256 prepaid
    ) external view returns (BazaarTypes.UnloadPlan memory plan) {
        plan.vaultIsLong = pairVault.pendingLiqIsLong;
        uint256 bandBp;
        // The headroom pre-charges the inventory's loss at the mark, so a fill at the mark is
        // free only while the base actually covers that loss. Past the trigger it does not, and
        // the reference moves to the neutral price: the only fills left are the ones that cost
        // the fund nothing.
        bool funded;
        {
            uint256 mmrBp = BucketLib.effectiveMmrBp(mr);
            (uint256 expectedLoss, uint256 base,,) = vaultAdlExposure(pairVault, oracle, currentFundingIndex, mmrBp);
            plan.headroom = int256(base) - int256(expectedLoss);
            funded = base >= expectedLoss;
            bandBp = mmrBp < BazaarTypes.LIQ_MAX_SLIPPAGE_BP ? mmrBp : BazaarTypes.LIQ_MAX_SLIPPAGE_BP;
        }

        uint256 neutral;
        {
            // Positive when the index rose since the estates' entry: paid by inherited longs,
            // received by inherited shorts — the term
            // MatchingEngineLib._settleVaultLiquidation realizes on a fill.
            // Either way it raises the fund-neutral price: a long that has paid must sell that
            // much higher to break even, a short that has received can buy back that much higher.
            int256 rawFunding = BazaarMathLib.signedMulDiv(
                currentFundingIndex - pairVault.pendingLiqEntryFundingIndex,
                int256(pairVault.pendingLiqSize),
                int256(BazaarTypes.BAZAAR_SCALE)
            );
            // The backing sits on the sale side of the ledger for longs (the vault sells and must
            // recover it) and on the purchase side for shorts (the vault buys and may spend it).
            int256 backing = int256(pairVault.pendingLiqSeized + pairVault.ledgerArrears);
            int256 neutralNotional = plan.vaultIsLong
                ? int256(pairVault.pendingLiqEntryNotional) - backing + rawFunding
                : int256(pairVault.pendingLiqEntryNotional) + backing + rawFunding;
            if (neutralNotional > 0) {
                neutral = Math.mulDiv(
                    uint256(neutralNotional),
                    BazaarTypes.BAZAAR_SCALE,
                    pairVault.pendingLiqSize,
                    plan.vaultIsLong ? Math.Rounding.Ceil : Math.Rounding.Floor
                );
            }
        }
        // Held from crossing the estates' own zero-equity price. ledgerArrears is one pair-wide
        // balance: an inventory that closes without a loss large enough to consume the arrears
        // it created leaves them behind, and the backing above would then count that leftover as
        // the next inventory's cushion, placing the neutral price past the estates' bankruptcy
        // and so inside the region where every fill is taken as free. A sale past the estates'
        // collateral loses the fund the difference whether it is paid in cash or by netting a
        // receivable it was owed, so the bankruptcy notional, an aggregate seeded fresh for this
        // inventory, bounds it. The hold forgoes funding the inventory has received since
        // seizure, which the frozen bankruptcy figure does not carry; funding paid since then
        // moves the neutral price the other way and is untouched. A zero notional is skipped: for
        // a long it is a floor of zero, which changes nothing, and inventory staged outside absorb
        // carries none.
        if (pairVault.pendingLiqBankruptcyNotional != 0) {
            uint256 bankruptcy = Math.mulDiv(
                pairVault.pendingLiqBankruptcyNotional,
                BazaarTypes.BAZAAR_SCALE,
                pairVault.pendingLiqSize,
                plan.vaultIsLong ? Math.Rounding.Ceil : Math.Rounding.Floor
            );
            if (plan.vaultIsLong ? neutral < bankruptcy : neutral > bankruptcy) neutral = bankruptcy;
        }
        // The nearer of the neutral price and the oracle while the base covers the loss at the
        // mark, the neutral price alone past the trigger.
        plan.referencePrice = funded && (plan.vaultIsLong ? oracle < neutral : oracle > neutral) ? oracle : neutral;
        // How far the floor has opened beyond the band edge toward the neutral price: the part of
        // UNLOAD_FLOOR_DECAY elapsed since the inventory's size-weighted seizure. A zero stamp is
        // inventory staged outside absorb and reads as fully open.
        uint256 opened = BazaarTypes.UNLOAD_FLOOR_DECAY;
        {
            uint256 seizedTs = pairVault.pendingLiqSeizedTs;
            if (seizedTs != 0 && block.timestamp < seizedTs + opened) {
                opened = block.timestamp > seizedTs ? block.timestamp - seizedTs : 0;
            }
        }
        // Rounded toward the vault: the opened distance rounds down, so a selling vault's floor
        // rounds up and a buying vault's ceiling rounds down.
        if (plan.vaultIsLong) {
            uint256 bandEdge = oracle * (BazaarTypes.BP_SCALE - bandBp) / BazaarTypes.BP_SCALE;
            plan.bound = neutral < bandEdge
                ? bandEdge - Math.mulDiv(bandEdge - neutral, opened, BazaarTypes.UNLOAD_FLOOR_DECAY)
                : bandEdge;
        } else {
            uint256 bandEdge = oracle * (BazaarTypes.BP_SCALE + bandBp) / BazaarTypes.BP_SCALE;
            plan.bound = neutral > bandEdge
                ? bandEdge + Math.mulDiv(neutral - bandEdge, opened, BazaarTypes.UNLOAD_FLOOR_DECAY)
                : bandEdge;
        }

        // The caller's reward is paid after the walk on the notional actually filled, so it is
        // reserved on the notional the walk could fill at most: the whole inventory at the
        // price furthest from the oracle the bound admits. A liquidation's walk reserves only
        // the part above the credit its liquidations left (LiquidateResult.unloadPrepaid), which
        // has already left the fund.
        {
            uint256 dearest = plan.vaultIsLong ? oracle : (plan.bound > oracle ? plan.bound : oracle);
            uint256 reward = Math.mulDiv(
                Math.mulDiv(pairVault.pendingLiqSize, dearest, BazaarTypes.BAZAAR_SCALE),
                BazaarTypes.LIQUIDATION_FEE_EBP,
                BazaarTypes.EBP_SCALE
            );
            if (prepaid == BazaarTypes.UNLOAD_BY_KEEPER) {
                if (reward < BazaarTypes.UNLOAD_BOUNTY_MIN) reward = BazaarTypes.UNLOAD_BOUNTY_MIN;
            } else {
                reward = reward > prepaid ? reward - prepaid : 0;
            }
            plan.headroom -= int256(reward);
        }
    }

    /// @notice Whether the inventory's loss at `price` exceeds free capital above the reserve:
    ///         vaultAdlExposure's `expectedLoss > base`, the inventory condition the ADL gate
    ///         opens a window on.
    /// @param v The pair's vault aggregates
    /// @param price Price to value the inventory at (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return True when the loss is past that headroom
    function lossPastHeadroom(BazaarTypes.Vault storage v, uint256 price, int256 currentFundingIndex)
        internal
        view
        returns (bool)
    {
        uint256 free = insuranceFreeCapital(v);
        uint256 reserve = adlReserve(v, price);
        return lossAt(v, price, currentFundingIndex) > (free > reserve ? free - reserve : 0);
    }

    /// @notice The most of `reward` an unload walk may pay its caller once its fills are booked:
    ///         free capital, and where the inventory left carries a loss at `price` that free
    ///         capital above the reserve covers, no more than what it covers the loss by.
    /// @dev The walk sets the reward aside in its headroom, but a fill at or beyond the reference
    ///      price is taken whatever the headroom (MatchingEngineLib.unloadBook), so a walk can end
    ///      with the base covering the loss at the mark by less than the reward. Paid in full, the
    ///      reward would take the base under the loss and the post-walk verdict would open the
    ///      auction on a walk that cost the fund nothing. Capped here, the reward leaves the
    ///      verdict where the fills left it. The reserve may still pay a reward where the
    ///      inventory carries no loss at the mark; where the base already fails to cover the loss,
    ///      the walk started past the trigger and the verdict is its own.
    /// @param v The pair's vault aggregates
    /// @param price The walk's oracle price (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param reward The reward the walk earned, in BAZAAR_SCALE precision
    /// @return The part of it the fund pays
    function unloadRewardPayable(
        BazaarTypes.Vault storage v,
        uint256 price,
        int256 currentFundingIndex,
        uint256 reward
    ) public view returns (uint256) {
        uint256 free = insuranceFreeCapital(v);
        if (reward > free) reward = free;
        uint256 loss = lossAt(v, price, currentFundingIndex);
        if (loss == 0) return reward;
        uint256 reserve = adlReserve(v, price);
        uint256 base = free > reserve ? free - reserve : 0;
        if (base >= loss && reward > base - loss) reward = base - loss;
        return reward;
    }

    /// @notice The reserve the unload walk never spends: ADL_RESERVE_BP of the insurance target
    ///         on `oiSize` valued at `price`.
    /// @param oiSize Per-side open interest, the vault's inventory included: what
    ///        reserveOiSizeOf admits when sizing the pair's reserve
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

    /// @notice The open interest the reserve is sized on: the lower of live per-side open
    ///         interest and its trailing minimum (Vault.trailingOiSize), or live open interest
    ///         alone while no sampled interval is a full MMR_GRACE_PERIOD old.
    /// @dev Live open interest counts matched positions of one owner, and it can be raised
    ///      within a transaction. Sized on it alone, the reserve would rise with it, the fund's
    ///      capital above the reserve would fall to zero, and a loss the fund can carry would
    ///      open an ADL window that charges it to winners instead. The trailing minimum admits
    ///      open interest only once it has been held for the whole lookback; a fall takes effect
    ///      at once, through the live leg.
    /// @param liveOiSize Live per-side open interest (openInterestSize)
    /// @param trailingOiSize The cached trailing minimum; 0 when there is none
    /// @return Open-interest size in BAZAAR_SCALE precision
    function reserveOiSizeOf(uint256 liveOiSize, uint256 trailingOiSize) internal pure returns (uint256) {
        return trailingOiSize != 0 && trailingOiSize < liveOiSize ? trailingOiSize : liveOiSize;
    }

    /// @notice adlReserveOf on the pair's vault aggregates, on the open interest reserveOiSizeOf
    ///         admits.
    /// @param v The pair's vault aggregates
    /// @param price Price to value the open interest at (BAZAAR_SCALE precision)
    /// @return The reserve in BAZAAR_SCALE precision
    function adlReserve(BazaarTypes.Vault storage v, uint256 price) internal view returns (uint256) {
        return adlReserveOf(reserveOiSizeOf(openInterestSize(v), v.trailingOiSize), price, v.targetInsuranceRatioBp);
    }

    /// @notice The inventory's net position at `price`: what backs it in the fund's hands — the
    ///         collateral seized alongside it plus the ledger's arrears to the fund — plus its
    ///         PnL from the estates' entry. Positive when closing there returns more than that
    ///         backing, negative by the loss the backing does not cover.
    /// @dev The arrears count as backing because settlement collects them: a loss is paid into
    ///      the ledger net of what the ledger owes (fundLedger), so the fund's outlay on a close
    ///      at `price` beyond the seizure is only what the loss exceeds the seizure and the
    ///      arrears by. Counting the seizure alone would read the estate as bankrupt by the
    ///      amount its winners had already withdrawn, and trip the ADL gate on a pair the fund
    ///      can settle whole.
    /// @param v The pair's vault aggregates
    /// @param price Price to value the inventory at (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return Signed net position in BAZAAR_SCALE precision
    function inventoryNet(BazaarTypes.Vault storage v, uint256 price, int256 currentFundingIndex)
        internal
        view
        returns (int256)
    {
        return int256(pendingLiqSeizedCollateral(v) + v.ledgerArrears) + vaultPnl(v, price, currentFundingIndex);
    }

    /// @notice What closing the inventory at `price` would cost the fund beyond the seizure and
    ///         the arrears backing it; 0 when the close pays that backing back in full.
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

    /// @notice What closing the whole inventory at the estates' average bankruptcy price costs
    ///         the fund beyond the seizure earmarked against it: the collateral the deposits
    ///         ledger could not hand over at seizure plus the funding accrued while the vault held
    ///         the inventory, net of funding it received over that stretch. 0 with no inventory.
    /// @dev The bankruptcy price is the entry basis displaced by the estates' full collateral and
    ///      their pre-liquidation funding, so against a settlement measured from the estates'
    ///      entry (vaultPnl) only the holding window's funding survives, and against the cash
    ///      earmark only the collateral the ledger did not pay. A close at that price is paid from
    ///      the slice's earmark first, then net of the arrears and from free capital
    ///      (AdlLib._settleInventorySlice, fundLedgerFrom), so this is what the arrears and free
    ///      capital together must hold for it to book no deficit — the backing an opposite-side
    ///      netting must leave the surviving inventory (LiquidationLib.nettingAffordable). The
    ///      price rounds toward the vault, as the ADL settlement price does.
    /// @param v The pair's vault aggregates
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return The uncovered cost in BAZAAR_SCALE precision
    function bankruptcyCloseCost(BazaarTypes.Vault storage v, int256 currentFundingIndex)
        internal
        view
        returns (uint256)
    {
        uint256 size = v.pendingLiqSize;
        if (size == 0) return 0;
        uint256 bankruptcy = Math.mulDiv(
            v.pendingLiqBankruptcyNotional,
            BAZAAR_SCALE,
            size,
            v.pendingLiqIsLong ? Math.Rounding.Ceil : Math.Rounding.Floor
        );
        int256 net = vaultPnl(v, bankruptcy, currentFundingIndex) + int256(v.pendingLiqSeized);
        return net < 0 ? uint256(-net) : 0;
    }

    /// @notice Collateral the insurance fund received alongside inventory the vault still holds.
    /// @dev Tracked as its own aggregate rather than recovered from the two notionals. The
    ///      bankruptcy price folds in the funding the estate had accrued before liquidation, and
    ///      vaultPnl realizes that stretch again from the estate's entry, so entry − bankruptcy
    ///      overstates or understates the seizure by exactly that term and misplaces the price
    ///      at which the inventory is whole. Cash only: an estate the deposits ledger could not
    ///      fully back leaves a smaller earmark here and the rest in `ledgerArrears`, so the
    ///      balance less this figure is exactly the cash the fund may spend.
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

    /// @notice What a position owes beyond its collateral at the state it was valued at: the
    ///         part of its loss the collateral does not cover, 0 while any equity remains.
    /// @param state The position's bucket state at the price and funding index in question
    /// @return The uncovered loss in BAZAAR_SCALE precision
    function accountExcess(BazaarTypes.BucketState memory state) internal pure returns (uint256) {
        if (state.totalPnl >= 0) return 0;
        uint256 loss = uint256(-state.totalPnl);
        return loss > state.effectiveCollateral ? loss - state.effectiveCollateral : 0;
    }

    /// @notice The loss beyond collateral across the deferred liquidations opposite the vault's
    ///         inventory, valued at `price`.
    /// @dev Exposure no earmark backs: each of these positions sits opposite the vault's
    ///      inventory and could not be netted against it without taking the fund below its
    ///      reserve, so its shortfall is resolved only by closing its own counterparties against
    ///      it. The ADL gate holds a window open while any is positive. Read from the buckets
    ///      every time, so an account that turned solvent again through a reversal or a deposit
    ///      contributes nothing without any bookkeeping.
    ///
    ///      A listed account on the inventory's own side is skipped. It was deferred while the
    ///      inventory sat opposite it, and a netting that flipped the inventory's side left it
    ///      listed; nothing resolves it through the window, since no cohort closes an account on
    ///      the side the window targets, and the inventory leg sizes its batch without it. It is
    ///      an unliquidated position like any other on its side: the next liquidation that names
    ///      it seizes it into the inventory, which realizes nothing. Counting it would hold a
    ///      window open that no batch can clear.
    /// @param positionBuckets Storage mapping of position buckets
    /// @param deferred The deferred liquidations
    /// @param inventoryIsLong Side the vault's inventory sits on
    /// @param price Price to value the positions at (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @return total The summed uncovered loss in BAZAAR_SCALE precision
    function deferredExcess(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        address[] storage deferred,
        bool inventoryIsLong,
        uint256 price,
        int256 currentFundingIndex
    ) public view returns (uint256 total) {
        BazaarTypes.MarginRequirements memory zeroReqs;
        for (uint256 i = 0; i < deferred.length; i++) {
            BazaarTypes.PositionBucket storage bucket = positionBuckets[deferred[i]];
            if (bucket.size == 0 || bucket.isLong == inventoryIsLong) continue;
            total += accountExcess(BucketLib.calculateState(bucket, price, currentFundingIndex, zeroReqs));
        }
    }

    // -------------------- Insurance <-> deposits ledger transfers --------------------
    //
    // Every value movement between the fund and the trader pot is a transfer between the two
    // ledgers, never a one-sided entry: I + D stays equal to the USDC held, so the books-vs-cash
    // health check is unmoved, and the deposits ledger keeps tracking the buckets that draw on
    // it. The ledger holds deposits only. Inter-user PnL is credited bucket to bucket, so a
    // winner who realizes against a position and withdraws takes cash out of the ledger while
    // the loss stays open in the loser's bucket. A collection the ledger cannot pay is therefore
    // the normal shape of a late liquidation, not a corrupted state, and the two helpers below
    // carry the unpaid part as `ledgerArrears` instead of dropping it.

    /// @notice Collect `amount` from the deposits ledger into the insurance fund. What the
    ///         ledger cannot pay is added to its arrears.
    /// @dev Never reverts and never drops value: an uncapped debit would panic on exactly the
    ///      deepest-underwater estate, and a dropped remainder would leave the fund fronting
    ///      the same cash again when the estate settles.
    /// @param v The pair's vault aggregates
    /// @param amount The collection due to the fund, in BAZAAR_SCALE precision
    /// @return collected The cash actually moved, in BAZAAR_SCALE precision
    function collectFromLedger(BazaarTypes.Vault storage v, uint256 amount) internal returns (uint256 collected) {
        uint256 ledger = v.totalCollateralDeposited;
        collected = amount < ledger ? amount : ledger;
        v.totalCollateralDeposited = ledger - collected;
        v.insuranceFundBalance += collected;
        if (amount > collected) v.ledgerArrears += amount - collected;
    }

    /// @notice Pay `amount` from the insurance fund into the deposits ledger, net of the
    ///         ledger's arrears, drawing at most `fundable` in cash.
    /// @dev Arrears are settled first because they are the same money: the ledger is being
    ///      credited with the loss so the surviving counterparties can withdraw the gains they
    ///      already hold, and the cash it still owes the fund is cash those same counterparties'
    ///      predecessors already withdrew. Paying gross would leave the difference in the ledger,
    ///      where no bucket can claim it, for as long as the arrears stay outstanding; a
    ///      settlement pays gross only out of the collateral it releases (fundLedgerFrom).
    ///      Whatever `fundable` does not cover is returned for the caller to book: deficit on an
    ///      unload fill or a netting, a withholding from the deleveraged winner on an ADL close.
    /// @param v The pair's vault aggregates
    /// @param amount The loss to credit to the ledger, in BAZAAR_SCALE precision
    /// @param fundable The most cash the fund may pay, at most its balance
    /// @return unfunded The part of the net amount the fund did not pay
    function fundLedger(BazaarTypes.Vault storage v, uint256 amount, uint256 fundable)
        internal
        returns (uint256 unfunded)
    {
        uint256 arrears = v.ledgerArrears;
        uint256 netted = amount < arrears ? amount : arrears;
        if (netted > 0) v.ledgerArrears = arrears - netted;
        uint256 due = amount - netted;
        uint256 fund = v.insuranceFundBalance;
        if (fundable > fund) fundable = fund;
        uint256 paid = due < fundable ? due : fundable;
        v.insuranceFundBalance = fund - paid;
        v.totalCollateralDeposited += paid;
        unfunded = due - paid;
    }

    /// @notice fundLedger for a settlement that releases collateral of its own: pays `amount` in
    ///         cash out of `ownCash` first, and only then net of the ledger's arrears and in cash
    ///         up to the rest of `fundable`.
    /// @dev The arrears are one pair-wide balance that backs every inventory still open, and the
    ///      netting gate and the ADL gate count them in full while they count free capital only
    ///      above the reserve. Netted ahead of the settlement's own collateral, as fundLedger
    ///      nets them, a loss that collateral covers would cancel arrears other inventory relies
    ///      on and release the collateral into free capital, where below the reserve neither
    ///      gate counts it: the inventory left would read short by what was netted although the
    ///      fund held the same value. Paid in this order, a settlement reaches the arrears only
    ///      once its own collateral is spent. One whose loss that collateral covers leaves every
    ///      arrear and free capital as it found them, and one that loses more nets the arrears,
    ///      and then spends free capital, by exactly the excess: the cost every gate charged it.
    ///      Arrears that no open inventory relies on stay owed until a later loss nets them or
    ///      finalize collects them; the cash paid ahead of them stands in the ledger behind that
    ///      receivable meanwhile.
    /// @param v The pair's vault aggregates
    /// @param amount The loss to credit to the ledger, in BAZAAR_SCALE precision
    /// @param ownCash The collateral the settlement releases, in BAZAAR_SCALE precision
    /// @param fundable The most cash the fund may pay, `ownCash` included, at most its balance
    /// @return unfunded The part of the amount the fund did not pay
    function fundLedgerFrom(BazaarTypes.Vault storage v, uint256 amount, uint256 ownCash, uint256 fundable)
        internal
        returns (uint256 unfunded)
    {
        if (ownCash > fundable) ownCash = fundable;
        uint256 paid = amount < ownCash ? amount : ownCash;
        uint256 fund = v.insuranceFundBalance;
        if (paid > fund) paid = fund;
        v.insuranceFundBalance = fund - paid;
        v.totalCollateralDeposited += paid;
        unfunded = fundLedger(v, amount - paid, fundable - paid);
    }

    // -------------------- Insurance share pricing --------------------
    //
    // Shares are minted and redeemed against the fund's value at the mark, not its balance. The
    // balance overstates that value while the vault holds inventory: it includes the collateral
    // seized alongside the inventory, which leaves again when the inventory unloads, and it says
    // nothing about what the unload itself will realize. Both bases start from free capital (the
    // balance less the seizure) and add the inventory's net position at the mark, which counts
    // the ledger's arrears to the fund as backing alongside the seizure, with two asymmetries:
    //
    //   * A loss counts only as far as the fund itself will bear it: up to free capital above
    //     the reserve. Beyond that the unload walk stops and the ADL closes the remainder at the
    //     estates' bankruptcy price, where the seizure covers the loss exactly, so the excess is
    //     taken from the winners, not the fund. No share is priced past that point, since it is
    //     where the ADL gate opens a window: a redemption's own health check refuses there, and a
    //     deposit is refused (InsuranceVaultLib.depositToInsurance) because its capital would
    //     change the auction the cap relies on. The cap still shapes quotes taken at such a mark.
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
    ///         against. Free capital plus the ledger's arrears when the vault holds no inventory,
    ///         in which case the mark is not read at all.
    /// @dev Arrears outstanding with no inventory left are a gain the fund has not collected
    ///      yet: finalize pays them into the residual. A deposit pays for them the way it pays
    ///      for an inventory gain, so a newcomer cannot buy that receivable at a discount from
    ///      the incumbents; a redemption, like any unrealized gain, does not collect them.
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
        if (v.pendingLiqSize == 0) return free + v.ledgerArrears;
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
    ///      The loss is taken net of the ledger's arrears, which settlement nets off the fund's
    ///      payment before any cash leaves it. Gains are not credited: an unrealized mark on
    ///      inventory the vault still has to exit is not capital it can spend.
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
        if (currentPrice == 0) {
            // No price provided - can't calculate meaningful ratio
            return (0, pairVault.insuranceFundBalance, 0);
        }

        totalOINotional = Math.mulDiv(openInterestSize(pairVault), currentPrice, BAZAAR_SCALE);
        int256 pnl = vaultPnl(pairVault, currentPrice, currentFundingIndex);
        // Arrears only offset a loss, so a flat or profitable vault never reads the slot.
        (ratioBp, freeCapital) = insuranceFundToOIRatioOf(
            pairVault.insuranceFundBalance, pnl, pnl < 0 ? pairVault.ledgerArrears : 0, totalOINotional
        );
    }

    /// @notice Value form of getInsuranceFundToOIRatio's coverage arithmetic, for readers that hold
    ///         the vault's fields rather than its storage — BazaarPairLens rebuilds the coverage
    ///         the withdrawal rate limit is judged by with it, so the view and the contract
    ///         cannot disagree about which regime a pair is in.
    /// @param fund The insurance fund balance
    /// @param inventoryPnl_ The vault's unrealized PnL on inherited inventory at the valuation
    ///        price (vaultPnl / inventoryPnl); only a loss is netted, a gain is not capital
    /// @param arrears The ledger's arrears, which settlement nets off the fund's payment
    /// @param oiNotional The open interest in notional value
    /// @return ratioBp Free capital over OI notional in bp; type(uint256).max at zero OI
    /// @return freeCapital The fund less the arrears-netted inventory loss
    function insuranceFundToOIRatioOf(uint256 fund, int256 inventoryPnl_, uint256 arrears, uint256 oiNotional)
        internal
        pure
        returns (uint256 ratioBp, uint256 freeCapital)
    {
        freeCapital = fund;
        if (inventoryPnl_ < 0) {
            uint256 committed = uint256(-inventoryPnl_);
            committed = committed > arrears ? committed - arrears : 0;
            freeCapital = freeCapital > committed ? freeCapital - committed : 0;
        }

        if (oiNotional == 0) {
            // No open interest - insurance fund provides infinite coverage
            return (type(uint256).max, freeCapital);
        }

        // Calculate ratio in basis points: (freeCapital / oiNotional) * BP_SCALE
        ratioBp = (freeCapital * BP_SCALE) / oiNotional;
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
        (int256 slippageBp, int256 driftBp) = fadedLiquidationGapsBp(liquidationGapEma, lastPairPrice);
        uint256 targetRatioBp = getTargetInsuranceRatio(
            stressMoveBp(lastPairPrice.emaVarianceBp, slippageBp, reopenGapEma.gapEmaBp, isContinuouslyTraded), driftBp
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
    ///      The SLIPPAGE leg ADDS. It is the execution cost of closing inherited inventory,
    ///      measured fill-against-oracle, and a position liquidated at the maintenance level is
    ///      only actually closable if that level pays for both the move and the distance the
    ///      fill lands past the mark. So it is a cost in the same units as the level, not a
    ///      second opinion about the move — which is why it sums where the reopen leg maxes.
    ///      Adding it at gain 1 self-limits two ways: once the level covers the observed
    ///      slippage, liquidations stop realizing more of it and the next batch blends the
    ///      estimate down; and the value fades with the age of the liquidations behind it
    ///      (fadedLiquidationGapsBp), so a book that has recovered returns the pair to its
    ///      volatility curve. A multiplicative form has neither property — it scales whatever
    ///      the vol leg already says, so the same thin book costs a calm pair and a volatile one
    ///      wildly different margin. The reading is floored at zero and capped at
    ///      LIQ_MAX_SLIPPAGE_BP fill by fill where it is measured
    ///      (MatchingEngineLib._settleVaultLiquidation) and stored unsigned, so it never lowers M
    ///      below what the vol leg asks; the positivity guard here covers a caller passing a
    ///      negative value.
    ///
    ///      What the market did while the vault held the inventory is deliberately NOT here. It
    ///      is a price move, which the vol and reopen legs already forecast, and it is the loss
    ///      the fund is sized for rather than the level a trader must hold — so it enters
    ///      through getTargetInsuranceRatio instead.
    /// @param variance The pair's annualized variance EMA (bp²)
    /// @param slippageBp The pair's execution-slippage EMA (bp), already faded by the age of the
    ///        liquidations behind it (fadedLiquidationGapsBp)
    /// @param reopenGapBp The pair's peak-hold reopen-gap floor (bp); ignored on continuously
    ///        traded pairs, which never consume it
    /// @param isContinuouslyTraded Whether the pair's venue trades around the clock
    /// @return The stress move in bp, clamped to [MIN_STRESS_MOVE_BP, MAX_STRESS_MOVE_BP]
    function stressMoveBp(uint256 variance, int256 slippageBp, uint256 reopenGapBp, bool isContinuouslyTraded)
        internal
        pure
        returns (uint256)
    {
        uint256 volBp = BASE_IMR_BP * getVolatilityMultiplier(variance) / BP_SCALE;
        uint256 m = isContinuouslyTraded ? volBp / 2 : (volBp > reopenGapBp ? volBp : reopenGapBp);
        if (slippageBp > 0) m += uint256(slippageBp);
        if (m < MIN_STRESS_MOVE_BP) return MIN_STRESS_MOVE_BP;
        if (m > MAX_STRESS_MOVE_BP) return MAX_STRESS_MOVE_BP;
        return m;
    }

    /// @notice The fund's target coverage ratio: the worse of what the stress move forecasts a
    ///         liquidation will lose beyond maintenance margin and what liquidations have
    ///         actually lost. Single source of truth — also consumed by InsuranceVaultLib's
    ///         withdrawal rate-limit check; keep any curve change here only.
    /// @dev The two legs are competing ESTIMATORS of one quantity, so the target takes the
    ///      larger rather than summing them. One is forward-looking, INSURANCE_TARGET_KAPPA_BP
    ///      of the stress move; the other is that same loss measured directly, as the distance
    ///      the mark travelled past the estates' bankruptcy price before the vault could clear
    ///      the inventory. Realized drift is a draw from the very distribution the stress move
    ///      estimates, so adding them would size the fund for one tail twice — the reason the
    ///      vol and reopen legs compose by max in stressMoveBp for the same relationship.
    ///
    ///      Drift is floored at zero fill by fill where it is measured
    ///      (MatchingEngineLib._settleVaultLiquidation): an oracle still short of the estates'
    ///      bankruptcy price is value the unload has already paid into the fund, and counting it
    ///      again here would size the fund below the forecast. The stored line is unsigned, so the
    ///      positivity guard covers a caller passing a negative value.
    ///
    ///      The clamps are the only place the target stops tracking its inputs: below
    ///      INSURANCE_TARGET_BASE a fund small enough not to matter still has to exist, and
    ///      above INSURANCE_TARGET_MAX a pair too risky to back is held to a fixed ceiling and
    ///      left to give on leverage instead — the margin curve keeps climbing past the point
    ///      the fund stops.
    /// @param stressMove The pair's stress move in bp (stressMoveBp)
    /// @param driftBp The pair's past-bankruptcy drift EMA (bp), already faded by the age of the
    ///        liquidations behind it (fadedLiquidationGapsBp)
    /// @return The target coverage ratio in bp
    function getTargetInsuranceRatio(uint256 stressMove, int256 driftBp) internal pure returns (uint256) {
        uint256 target = stressMove * INSURANCE_TARGET_KAPPA_BP / BP_SCALE;
        if (driftBp > 0 && uint256(driftBp) > target) target = uint256(driftBp);
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
