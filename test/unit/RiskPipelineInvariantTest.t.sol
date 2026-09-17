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

    function seed(uint256 variance, int256 gap, uint192 reopen, uint256 fund, uint256 oi) external {
        lastPairPrice.emaVarianceBp = variance;
        liquidationGapEma.emaGapBp = gap;
        reopenGapEma.gapEmaBp = reopen;
        pairVault.insuranceFundBalance = fund;
        pairVault.totalLongOI = oi;
        pairVault.totalShortOI = oi;
    }

    function setFund(uint256 fund) external {
        pairVault.insuranceFundBalance = fund;
    }

    function run(uint256 price, bool cont, uint256 createdTs, uint256 updates) external {
        RiskParamsLib.calculateIMRandMMR(
            marginRequirements,
            lastPairPrice,
            liquidationGapEma,
            pairVault,
            reopenGapEma,
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
    function stressMove(uint256 v, int256 g, uint256 rg, bool cont) external pure returns (uint256) {
        return RiskParamsLib.stressMoveBp(v, g, rg, cont);
    }

    function targetOf(uint256 m) external pure returns (uint256) {
        return RiskParamsLib.getTargetInsuranceRatio(m);
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
    uint256 internal constant BASE_TS = 10 days; // past warmup with pairCreatedTs = 0
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

    // -------- input shaping --------

    function _variance(uint256 raw) internal pure returns (uint256) {
        return bound(raw, 0, 1e15); // far past the 247M bp^2 vol saturation
    }

    function _gap(uint256 raw) internal pure returns (int256) {
        return int256(bound(raw, 0, 200_000)) - 20_000; // [-2%, +2000%] of notional
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

    /// @notice The liquidation-gap EMA is a signed int256 with no intrinsic upper bound (a fill
    ///         against an inherited short can print arbitrarily far past bankruptcy). M's ceiling
    ///         must absorb that without reverting or wrapping.
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

    /// @notice Margin clamps hold, MMR is half IMR, and the target never exceeds the maintenance
    ///         margin it backstops. The last is the structural property the consolidation buys:
    ///         coverage is measured in the same units as, and never outruns, the level it sits
    ///         beyond.
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
