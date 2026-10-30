// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @dev Storage host for the composed risk pipeline: the stress move, the fund target derived
///      from it, and the margin curve derived from both.
contract RiskPipelineHarness {
    BazaarTypes.MarginRequirements internal marginRequirements;
    BazaarTypes.PairPrice internal lastPairPrice;
    BazaarTypes.LiquidationGapEma internal liquidationGapEma;
    BazaarTypes.Vault internal pairVault;
    BazaarTypes.ReopenGapEma internal reopenGapEma;
    BazaarTypes.MmrSampleBuffer internal mmrBuffer;

    /// @dev `slip` in whole basis points; the stored line is unsigned, so a negative one stores as
    ///      zero, the reading the stress move's positivity guard would give it anyway.
    function seed(uint256 variance, int256 slip, uint192 reopen, uint256 fund, uint256 oi) external {
        lastPairPrice.emaVarianceBp = variance;
        liquidationGapEma.slippage = slip > 0 ? uint256(slip) * RiskParamsLib.GAP_EMA_SCALE : 0;
        reopenGapEma.gapEmaBp = uint128(reopen);
        pairVault.insuranceFundBalance = fund;
        pairVault.totalLongOI = oi;
        pairVault.totalShortOI = oi;
    }

    function setDrift(int256 drift) external {
        liquidationGapEma.drift = drift > 0 ? uint256(drift) * RiskParamsLib.GAP_EMA_SCALE : 0;
    }

    function setFund(uint256 fund) external {
        pairVault.insuranceFundBalance = fund;
    }

    /// @dev Anchors both value lines and the batch clock at `ts`, as one batch then would.
    function setGapTs(uint256 ts) external {
        liquidationGapEma.slippageAnchorTs = uint64(ts);
        liquidationGapEma.driftAnchorTs = uint64(ts);
        liquidationGapEma.lastLiquidationTs = uint64(ts);
    }

    /// @dev Stands in for a live market's latest stored price, where the fade clock stops.
    function setLastPriceTs(uint256 ts) external {
        lastPairPrice.updateTs = ts;
    }

    function fadedGap() external view returns (int256 slippageBp) {
        (slippageBp,) = RiskParamsLib.fadedLiquidationGapsBp(liquidationGapEma, lastPairPrice);
    }

    function fadedDrift() external view returns (int256 driftBp) {
        (, driftBp) = RiskParamsLib.fadedLiquidationGapsBp(liquidationGapEma, lastPairPrice);
    }

    function run(uint256 price, bool cont, uint256 createdTs, uint256 updates) external {
        RiskParamsLib.calculateIMRandMMR(
            marginRequirements,
            lastPairPrice,
            liquidationGapEma,
            pairVault,
            reopenGapEma,
            mmrBuffer,
            price,
            cont,
            createdTs,
            updates,
            0
        );
    }

    function imr() external view returns (uint256) {
        return marginRequirements.imrBp;
    }

    function mmr() external view returns (uint256) {
        return marginRequirements.mmrBp;
    }

    function target() external view returns (uint256) {
        return pairVault.targetInsuranceRatioBp;
    }

    // ---- pure curve entry points ----
    function stressMove(uint256 v, int256 slip, uint256 rg, bool cont) external pure returns (uint256) {
        return RiskParamsLib.stressMoveBp(v, slip, rg, cont);
    }

    /// @dev The target with no realized drift on record, i.e. the forecast leg alone.
    function targetOf(uint256 m) external pure returns (uint256) {
        return RiskParamsLib.getTargetInsuranceRatio(m, 0);
    }

    /// @dev The target with both legs competing.
    function targetOfWithDrift(uint256 m, int256 drift) external pure returns (uint256) {
        return RiskParamsLib.getTargetInsuranceRatio(m, drift);
    }

    function insMult(uint256 r, uint256 t) external pure returns (uint256) {
        return RiskParamsLib.getInsuranceMultiplier(r, t);
    }

    function bounds() external pure returns (uint256 minM, uint256 maxM, uint256 minImr, uint256 maxImr) {
        minM = RiskParamsLib.MIN_STRESS_MOVE_BP;
        maxM = RiskParamsLib.MAX_STRESS_MOVE_BP;
        minImr = RiskParamsLib.MIN_IMR_BP;
        maxImr = RiskParamsLib.MAX_IMR_BP;
    }
}

/// @notice Property tests over the composed risk pipeline: stress move -> fund target -> margin.
///         These pin the structural guarantees the consolidated design rests on, rather than
///         individual points on each curve.
contract RiskPipelineInvariantTest is Test {
    uint256 internal constant BASE_TS = 30 days; // past warmup with pairCreatedTs = 0
    uint256 internal constant OI = 1_000_000e18;
    uint256 internal constant PRICE = 1e18; // OI size == OI notional
    uint256 internal constant PAST_WARMUP_UPDATES = 50_000;

    RiskPipelineHarness internal h;
    uint256 internal MINM;
    uint256 internal MAXM;
    uint256 internal MIN_IMR;
    uint256 internal MAX_IMR;

    function setUp() public {
        h = new RiskPipelineHarness();
        (MINM, MAXM, MIN_IMR, MAX_IMR) = h.bounds();
        vm.warp(BASE_TS);
    }

    /// @dev Moves the clock the way a live market does: its latest stored price lands with it, so
    ///      the fade clock, which stops at the last stored price, runs all the way to `ts`.
    function _liveAt(uint256 ts) internal {
        vm.warp(ts);
        h.setLastPriceTs(ts);
    }

    // -------- input shaping --------

    function _variance(uint256 raw) internal pure returns (uint256) {
        return bound(raw, 0, 1e15); // far past the 247M bp^2 vol saturation
    }

    /// @dev The slippage leg. Ranged far past anything the unload bound admits, so the clamps are
    ///      exercised rather than merely the reachable band.
    function _gap(uint256 raw) internal pure returns (int256) {
        return int256(bound(raw, 0, 200_000)) - 20_000; // [-2%, +2000%] of notional
    }

    /// @dev The realized-drift leg. A close against inherited short inventory can print
    ///      arbitrarily far past the estates' bankruptcy price, so this is deliberately unbounded
    ///      above the target's own ceiling.
    function _drift(uint256 raw) internal pure returns (int256) {
        return int256(bound(raw, 0, 200_000)) - 20_000;
    }

    function _reopen(uint256 raw) internal pure returns (uint192) {
        return uint192(bound(raw, 0, RiskParamsLib.REOPEN_GAP_EMA_CAP_BP));
    }

    // ==================== stress move ====================

    /// @notice M is always inside its clamps, for every input the estimators can produce.
    function testFuzz_stressMove_alwaysClamped(uint256 v, uint256 g, uint256 rg, bool cont) public view {
        uint256 m = h.stressMove(_variance(v), _gap(g), _reopen(rg), cont);
        assertGe(m, MINM, "M below floor");
        assertLe(m, MAXM, "M above ceiling");
    }

    /// @notice The slippage leg arrives as a signed reading, so M's ceiling must absorb an
    ///         arbitrarily large one without reverting or wrapping — the clamp, not the
    ///         estimator's own range, is what holds the maintenance level together.
    function testFuzz_stressMove_unboundedGapIsAbsorbed(uint256 v, uint256 rg, bool cont) public view {
        uint256 m = h.stressMove(_variance(v), type(int256).max, _reopen(rg), cont);
        assertEq(m, MAXM, "an unbounded gap pins the ceiling rather than overflowing");
    }

    /// @notice Monotone in each risk input: more measured risk never produces a smaller M.
    function testFuzz_stressMove_monotone(uint256 v, uint256 g, uint256 rg, bool cont, uint256 bumpRaw) public view {
        uint256 var0 = _variance(v);
        int256 gap0 = _gap(g);
        uint192 rg0 = _reopen(rg);
        uint256 bump = bound(bumpRaw, 1, 1000);
        uint256 m0 = h.stressMove(var0, gap0, rg0, cont);

        assertGe(h.stressMove(var0 + bump * 1e6, gap0, rg0, cont), m0, "variance up must not lower M");
        assertGe(h.stressMove(var0, gap0 + int256(bump), rg0, cont), m0, "liquidation gap up must not lower M");
        uint192 rgUp = uint192(
            rg0 + bump > RiskParamsLib.REOPEN_GAP_EMA_CAP_BP ? RiskParamsLib.REOPEN_GAP_EMA_CAP_BP : rg0 + bump
        );
        assertGe(h.stressMove(var0, gap0, rgUp, cont), m0, "reopen gap up must not lower M");
    }

    /// @notice A continuously traded pair never consumes the reopen peak-hold, whatever is stored
    ///         in it, and always sits at or below the session-bound reading of the same state.
    function testFuzz_stressMove_continuousIgnoresReopenGap(uint256 v, uint256 g, uint256 rg) public view {
        uint256 var0 = _variance(v);
        int256 gap0 = _gap(g);
        uint192 rg0 = _reopen(rg);
        uint256 contM = h.stressMove(var0, gap0, rg0, true);
        assertEq(contM, h.stressMove(var0, gap0, 0, true), "reopen state is inert on a 24/7 pair");
        assertLe(contM, h.stressMove(var0, gap0, rg0, false), "the closure prior is never a discount");
    }

    // ==================== fund target ====================

    /// @notice The target is always inside the protocol coverage band, and tracks M one-for-one
    ///         wherever the band is not binding.
    function testFuzz_target_bandAndTracking(uint256 mRaw) public view {
        uint256 m = bound(mRaw, 0, type(uint128).max);
        uint256 t = h.targetOf(m);
        assertGe(t, BazaarTypes.INSURANCE_TARGET_BASE, "target below the floor");
        assertLe(t, BazaarTypes.INSURANCE_TARGET_MAX, "target above the ceiling");
        if (m >= BazaarTypes.INSURANCE_TARGET_BASE && m <= BazaarTypes.INSURANCE_TARGET_MAX) {
            assertEq(t, m, "inside the band the target is the stress move");
        }
    }

    // ==================== composed pipeline ====================

    /// @notice Margin clamps hold, MMR is half IMR, and — on a pair with no realized drift on
    ///         record — the target never exceeds the maintenance margin it backstops. The last is
    ///         the structural property the forecast leg buys: coverage is measured in the same
    ///         units as, and never outruns, the level it sits beyond. Realized drift is allowed
    ///         to break exactly that bound, and is pinned separately.
    function testFuzz_pipeline_clampsAndTargetUnderMmr(uint256 v, uint256 g, uint256 rg, uint256 fundRaw, bool cont)
        public
    {
        h.seed(_variance(v), _gap(g), _reopen(rg), bound(fundRaw, 0, 1e30), OI);
        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);

        uint256 imr = h.imr();
        assertGe(imr, MIN_IMR, "IMR below floor");
        assertLe(imr, MAX_IMR, "IMR above ceiling");
        assertEq(h.mmr(), imr / 2, "MMR is half IMR");
        assertLe(h.target(), h.mmr(), "the target never exceeds the maintenance margin it backstops");
    }

    // ==================== realized drift ====================

    /// @notice The target takes the WORSE of its two legs, never their sum. Realized drift is a
    ///         draw from the very distribution the stress move forecasts, so summing them would
    ///         size the fund for one tail twice.
    function testFuzz_target_takesTheWorseOfForecastAndDrift(uint256 mRaw, uint256 dRaw) public view {
        uint256 m = bound(mRaw, 0, 20_000);
        int256 drift = int256(bound(dRaw, 0, 20_000));

        uint256 forecastOnly = h.targetOf(m);
        uint256 both = h.targetOfWithDrift(m, drift);
        assertGe(both, forecastOnly, "a positive drift leg can never lower the target");

        // KAPPA is 1x, so the forecast leg is the stress move itself before the band.
        uint256 expected = uint256(drift) > m ? uint256(drift) : m;
        if (expected < BazaarTypes.INSURANCE_TARGET_BASE) expected = BazaarTypes.INSURANCE_TARGET_BASE;
        if (expected > BazaarTypes.INSURANCE_TARGET_MAX) expected = BazaarTypes.INSURANCE_TARGET_MAX;
        assertEq(both, expected, "the target is max(forecast, drift), clamped to the coverage band");
    }

    /// @notice A drift reading the forecast already covers is inert — the competition never
    ///         double-counts a tail the stress move has priced.
    function testFuzz_target_driftInsideTheForecastIsInert(uint256 mRaw, uint256 dRaw) public view {
        uint256 m = bound(mRaw, BazaarTypes.INSURANCE_TARGET_BASE, 20_000);
        int256 drift = int256(bound(dRaw, 0, m));
        assertEq(h.targetOfWithDrift(m, drift), h.targetOf(m), "a drift inside the forecast adds nothing");
    }

    /// @notice A negative drift reading — inventory cleared with the mark still short of the
    ///         estates' bankruptcy price, which the stored line records as zero — is evidence the
    ///         forecast leg is sufficient, not a reason to size the fund below it.
    function testFuzz_target_negativeDriftIsInert(uint256 mRaw, uint256 dRaw) public view {
        uint256 m = bound(mRaw, 0, 20_000);
        int256 drift = -int256(bound(dRaw, 0, 20_000));
        assertEq(h.targetOfWithDrift(m, drift), h.targetOf(m), "a negative drift must not lower the target");
    }

    /// @notice Drift never touches the stress move, so it cannot raise the maintenance level
    ///         directly however severe it is. Structural: M is a function of variance, slippage
    ///         and the reopen floor alone.
    function testFuzz_stressMove_isBlindToDrift(uint256 v, uint256 g, uint256 rg, uint256 dRaw, bool cont) public {
        uint256 var0 = _variance(v);
        int256 slip0 = _gap(g);
        uint192 rg0 = _reopen(rg);

        h.seed(var0, slip0, rg0, 0, OI);
        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);
        uint256 mmrWithoutDrift = h.mmr();

        vm.warp(BASE_TS + 60);
        h.setDrift(_drift(dRaw));
        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);

        // The fund is empty in both passes, so the fund-health leg is already at its ceiling and
        // any change here could only have come from the stress move.
        assertEq(h.mmr(), mmrWithoutDrift, "drift must not move the maintenance level on its own");
    }

    /// @notice Realized drift reaches margin only through the fund-health multiplier, and only
    ///         while the fund is short of the target it raised. That is what bounds one
    ///         overrunning close at MULTIPLIER_MAX instead of letting it add itself to the
    ///         maintenance level without limit.
    function test_pipeline_driftLiftsMarginOnlyThroughAShortFund() public {
        // Calm 24/7 pair: vol leg 150 bp, slippage 200 bp -> M = 350, IMR = 700 unmultiplied.
        // Fund at 100% coverage, far above any reachable target.
        h.seed(0, 200, 0, OI, OI);
        h.run(PRICE, true, 0, PAST_WARMUP_UPDATES);
        uint256 fundedImr = h.imr();
        uint256 fundedTarget = h.target();
        assertEq(fundedImr, 700, "M = 150 + 200, IMR = 2M with a healthy fund");
        assertEq(fundedTarget, 350, "target tracks M while no drift is on record");

        // A close that overran the estates' bankruptcy price by 40% of notional.
        vm.warp(BASE_TS + 60);
        h.setDrift(4_000);
        h.run(PRICE, true, 0, PAST_WARMUP_UPDATES);
        assertEq(h.target(), BazaarTypes.INSURANCE_TARGET_MAX, "realized drift drives the target to its ceiling");
        assertEq(h.imr(), fundedImr, "a fund that still meets the raised target leaves margin alone");

        // Same risk, same drift, but a fund that cannot meet the raised target.
        vm.warp(BASE_TS + 120);
        h.setFund(0);
        h.run(PRICE, true, 0, PAST_WARMUP_UPDATES);
        assertGt(h.imr(), fundedImr, "a short fund passes the drift through to margin");
        assertEq(h.imr(), 3 * fundedImr, "and never by more than the fund-health ceiling");
    }

    /// @notice The target may exceed MMR once liquidations have demonstrated losses past the
    ///         maintenance level. Coverage outrunning the level it sits beyond is the fund doing
    ///         its job on a pair with realized shortfall, not an inconsistency — which is why the
    ///         forecast-only bound above is stated without a drift leg.
    function test_target_mayExceedMmrOnceDriftIsRealized() public {
        h.seed(0, 0, 0, 0, OI); // calm, no slippage, empty fund -> M floors at MIN_STRESS_MOVE_BP
        h.setDrift(int256(uint256(BazaarTypes.INSURANCE_TARGET_MAX)) * 5);
        h.run(PRICE, true, 0, PAST_WARMUP_UPDATES);

        assertEq(h.target(), BazaarTypes.INSURANCE_TARGET_MAX, "drift pins the target at the band ceiling");
        assertGt(h.target(), h.mmr(), "demonstrated shortfall sizes the fund past the level it backstops");
    }

    /// @notice THE anti-feedback invariant. The fund's own balance must not move the target it is
    ///         measured against. If it did, a shortfall would deepen its own measure and the
    ///         margin curve would ratchet off a fund level rather than off the pair's risk.
    function testFuzz_target_isIndependentOfFundBalance(uint256 v, uint256 g, uint256 rg, bool cont, uint256 fRaw)
        public
    {
        h.seed(_variance(v), _gap(g), _reopen(rg), 0, OI);

        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);
        uint256 emptyTarget = h.target();
        uint256 emptyImr = h.imr();

        uint256 fund = bound(fRaw, 1, 1e30);
        vm.warp(BASE_TS + 60);
        h.setFund(fund);
        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);

        assertEq(h.target(), emptyTarget, "the target must read the pair's risk, never the fund's level");
        assertLe(h.imr(), emptyImr, "capitalizing the fund must not raise margin");
    }

    /// @notice No ratchet. Repeated evaluations against unchanged risk and an unchanged fund must
    ///         settle, not climb. A target derived from the already-multiplied margin would have
    ///         no stable resting point here and IMR would walk upward on every call.
    function testFuzz_pipeline_isAFixedPoint(uint256 v, uint256 g, uint256 rg, uint256 fundRaw, bool cont) public {
        h.seed(_variance(v), _gap(g), _reopen(rg), bound(fundRaw, 0, 1e26), OI);

        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);
        uint256 firstImr = h.imr();
        uint256 firstTarget = h.target();

        for (uint256 i = 1; i <= 5; ++i) {
            vm.warp(BASE_TS + i * 60);
            h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);
            assertEq(h.imr(), firstImr, "IMR ratcheted on a re-evaluation of unchanged state");
            assertEq(h.target(), firstTarget, "target drifted on a re-evaluation of unchanged state");
        }
    }

    /// @notice A better-funded pair is never charged more margin, holding risk fixed.
    function testFuzz_imr_nonIncreasingInFund(uint256 v, uint256 g, uint256 rg, bool cont, uint256 aRaw, uint256 bRaw)
        public
    {
        uint256 lo = bound(aRaw, 0, 1e26);
        uint256 hi = bound(bRaw, lo, 1e26 + lo);

        h.seed(_variance(v), _gap(g), _reopen(rg), lo, OI);
        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);
        uint256 imrLo = h.imr();

        vm.warp(BASE_TS + 60);
        h.setFund(hi);
        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);

        assertLe(h.imr(), imrLo, "more coverage must not cost more margin");
    }

    /// @notice More measured risk never loosens margin, at a fixed fund balance.
    function testFuzz_imr_monotoneInVariance(uint256 v, uint256 fundRaw, bool cont, uint256 bumpRaw) public {
        uint256 var0 = _variance(v);
        uint256 fund = bound(fundRaw, 0, 1e26);
        uint256 bump = bound(bumpRaw, 1e6, 1e12);

        h.seed(var0, 0, 0, fund, OI);
        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);
        uint256 imrLow = h.imr();
        uint256 targetLow = h.target();

        vm.warp(BASE_TS + 60);
        h.seed(var0 + bump, 0, 0, fund, OI);
        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);

        assertGe(h.imr(), imrLow, "rising variance must not lower IMR");
        assertGe(h.target(), targetLow, "rising variance must not lower the target");
    }

    /// @notice The warmup floor lifts margin only. It must never reach the fund target, which
    ///         sizes the ADL reserve and the LP withdrawal regime off the pair's measured risk.
    function testFuzz_warmupFloor_doesNotTouchTarget(uint256 v, uint256 g, uint256 rg, bool cont) public {
        h.seed(_variance(v), _gap(g), _reopen(rg), 0, OI);

        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);
        uint256 matureTarget = h.target();
        uint256 matureImr = h.imr();

        vm.warp(BASE_TS + 60);
        h.run(PRICE, cont, BASE_TS + 60, 0); // brand-new pair: warmup active
        assertEq(h.target(), matureTarget, "warmup must not move the target");
        assertGe(h.imr(), matureImr, "warmup is a floor, never a discount");
    }

    // ==================== liquidation-gap fade ====================

    /// @notice The faded reading never exceeds the stored value, and is the stored value itself
    ///         when no time has passed. A negative seed stores as zero.
    function testFuzz_gapFade_boundedByTheStore(uint256 gRaw, uint256 dtRaw) public {
        int256 g = _gap(gRaw);
        int256 stored = g > 0 ? g : int256(0);
        uint256 dt = bound(dtRaw, 0, 10 * 365 days);
        h.seed(0, g, 0, 0, OI);
        h.setGapTs(BASE_TS);
        _liveAt(BASE_TS + dt);
        int256 f = h.fadedGap();
        assertLe(f, stored, "a reading never exceeds the store");
        if (dt == 0) assertEq(f, stored, "no time, no fade");
    }

    /// @notice Exactly half at tau: the constant is a real half-life on the read side.
    function test_gapFade_exactlyHalfAtTau() public {
        h.seed(0, 2400, 0, 0, OI);
        h.setGapTs(BASE_TS);
        _liveAt(BASE_TS + RiskParamsLib.LIQUIDATION_GAP_EMA_TAU);
        assertEq(h.fadedGap(), 1200);
    }

    /// @notice Monotone non-increasing in the time since the last batch.
    function testFuzz_gapFade_monotoneInTime(uint256 gRaw, uint256 aRaw, uint256 bRaw) public {
        int256 g = int256(bound(gRaw, 1, 200_000));
        uint256 a = bound(aRaw, 0, 5 * 365 days);
        uint256 b = bound(bRaw, a, a + 5 * 365 days);
        h.seed(0, g, 0, 0, OI);
        h.setGapTs(BASE_TS);
        _liveAt(BASE_TS + a);
        int256 fa = h.fadedGap();
        _liveAt(BASE_TS + b);
        assertLe(h.fadedGap(), fa, "more time never raises the reading");
    }

    /// @notice Between stored prices the reading holds, however long the silence. Time without a
    ///         store is judged only when the next price lands — counted as trading time or skipped
    ///         as a closure — so no read may pre-empt that judgement by fading through it.
    function testFuzz_gapFade_holdsBetweenStores(uint256 gRaw, uint256 aRaw, uint256 dtRaw) public {
        int256 g = _gap(gRaw);
        uint256 a = bound(aRaw, 0, 365 days);
        uint256 dt = bound(dtRaw, 0, 365 days);
        h.seed(0, g, 0, 0, OI);
        h.setGapTs(BASE_TS);
        _liveAt(BASE_TS + a);
        int256 atStore = h.fadedGap();

        vm.warp(BASE_TS + a + dt); // nothing stored
        assertEq(h.fadedGap(), atStore, "no store, no fade");
    }

    /// @notice The same property through the whole pipeline: margin and the target recomputed
    ///         during a silence equal what the last store produced. This is what keeps a
    ///         recompute off the stale fallback mid-closure from storing a maintenance level the
    ///         reopen raises again. Fully funded so the fund-health leg cannot move either.
    function testFuzz_pipeline_silenceNeverMovesMargin(uint256 v, uint256 gRaw, uint256 rg, bool cont, uint256 dtRaw)
        public
    {
        int256 g = int256(bound(gRaw, 0, 200_000));
        uint256 dt = bound(dtRaw, 0, 2 * 365 days);
        h.seed(_variance(v), g, _reopen(rg), 1e30, OI);
        h.setGapTs(BASE_TS);
        _liveAt(BASE_TS + 1 hours);
        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);
        uint256 imr0 = h.imr();
        uint256 target0 = h.target();

        vm.warp(BASE_TS + 1 hours + 60 + dt); // past the IMR cooldown, nothing stored
        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);
        assertEq(h.imr(), imr0, "silence never moves margin");
        assertEq(h.target(), target0, "nor the target");
    }

    /// @notice Through the whole pipeline: with risk inputs and the fund held fixed, time since
    ///         the last liquidation never raises margin or the target. Quiet is evidence, and it
    ///         only ever loosens. Fully funded so the fund-health leg is 1x and the fade is the
    ///         only thing moving.
    function testFuzz_pipeline_nonIncreasingInQuietTime(uint256 v, uint256 gRaw, uint256 rg, bool cont, uint256 dtRaw)
        public
    {
        int256 g = int256(bound(gRaw, 0, 200_000));
        uint256 dt = bound(dtRaw, 0, 2 * 365 days);
        h.seed(_variance(v), g, _reopen(rg), 1e30, OI);
        h.setGapTs(BASE_TS);
        _liveAt(BASE_TS);
        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);
        uint256 imr0 = h.imr();
        uint256 target0 = h.target();

        _liveAt(BASE_TS + 60 + dt);
        h.run(PRICE, cont, 0, PAST_WARMUP_UPDATES);
        assertLe(h.imr(), imr0, "quiet time never raises margin");
        assertLe(h.target(), target0, "quiet time never raises the target");
    }

    /// @notice Zero open interest reads as full coverage, not as maximum stress: the pipeline
    ///         must still produce a sane curve on an empty book.
    function test_pipeline_zeroOpenInterest() public {
        h.seed(BazaarTypes.VARIANCE_EXTREME, 0, 0, 0, 0);
        h.run(PRICE, true, 0, PAST_WARMUP_UPDATES);
        assertEq(h.imr(), 900, "no OI -> insurance multiplier 1x -> IMR = 2 x M");
        assertEq(h.target(), 450, "target still reads the pair's risk");
    }

    /// @notice A zero price cannot value the fund's claim, so coverage reads zero and the margin
    ///         curve takes its maximum-stress branch rather than reverting.
    function test_pipeline_zeroPriceIsMaxStress() public {
        h.seed(0, 0, 0, 1e30, OI);
        h.run(0, true, 0, PAST_WARMUP_UPDATES);
        assertEq(h.target(), 200, "target is priceless and unaffected");
        assertEq(h.imr(), 1200, "2 x 200 x the 3x empty-fund multiplier");
    }
}
