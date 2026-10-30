// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @dev Host that reads margin, the fund target and the taker insurance rate off ONE seeded
///      state, so a scenario's three outputs are all judged against the same inputs.
contract RiskScenarioHarness {
    BazaarTypes.MarginRequirements internal marginRequirements;
    BazaarTypes.PairPrice internal lastPairPrice;
    BazaarTypes.LiquidationGapEma internal liquidationGapEma;
    BazaarTypes.Vault internal pairVault;
    BazaarTypes.ReopenGapEma internal reopenGapEma;
    BazaarTypes.MmrSampleBuffer internal mmrBuffer;

    /// @dev `slip` in whole basis points; the stored line is unsigned, so a negative one stores as
    ///      zero.
    function seed(uint256 variance, int256 slip, uint192 reopen, uint256 fund, uint256 oi) external {
        lastPairPrice.emaVarianceBp = variance;
        liquidationGapEma.slippage = slip > 0 ? uint256(slip) * RiskParamsLib.GAP_EMA_SCALE : 0;
        reopenGapEma.gapEmaBp = uint128(reopen);
        pairVault.insuranceFundBalance = fund;
        pairVault.totalLongOI = oi;
        pairVault.totalShortOI = oi;
        marginRequirements.lastUpdateTs = 0;
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

    function run(uint256 price, bool cont) external {
        RiskParamsLib.calculateIMRandMMR(
            marginRequirements,
            lastPairPrice,
            liquidationGapEma,
            pairVault,
            reopenGapEma,
            mmrBuffer,
            price,
            cont,
            0,
            50_000,
            0
        );
    }

    function takerFeeEbp(uint256 price, bool cont) external view returns (uint256 f) {
        (f,) = RiskParamsLib.getInsuranceFeeRates(
            pairVault, lastPairPrice, liquidationGapEma, reopenGapEma, price, cont, 0
        );
    }

    function readout() external view returns (uint256 imr, uint256 mmr, uint256 target) {
        return (marginRequirements.imrBp, marginRequirements.mmrBp, pairVault.targetInsuranceRatioBp);
    }
}

/// @notice Pins the composed outputs for the scenarios that decide whether the regime is
///         calibrated as intended. Each asserts margin, the fund target and the taker insurance
///         rate together, because a change to the target moves all three: it is the denominator
///         the coverage ratio is judged against, so it also drives the margin curve's
///         fund-health multiplier and the fee's deficit surcharge.
contract RiskRegimeScenarioTest is Test {
    uint256 internal constant OI = 1_000_000e18;
    uint256 internal constant PRICE = 1e18; // OI size == OI notional, so fund bp is direct
    uint256 internal constant EPISODE_TS = 30 days; // the clock every test starts on, past warmup

    RiskScenarioHarness internal h;

    function setUp() public {
        h = new RiskScenarioHarness();
        vm.warp(EPISODE_TS);
    }

    /// @dev `fundBp` is the fund as bp of OI notional, which at PRICE is the coverage ratio.
    function _scenario(uint256 variance, int256 gap, uint192 reopen, uint256 fundBp, bool cont)
        internal
        returns (uint256 imr, uint256 target, uint256 fee)
    {
        h.seed(variance, gap, reopen, OI * fundBp / 10_000, OI);
        h.run(PRICE, cont);
        (imr,, target) = h.readout();
        fee = h.takerFeeEbp(PRICE, cont);
    }

    /// @notice A 100%-vol 24/7 pair holding 5% coverage. The fund is sized to one further stress
    ///         move beyond the 4.5% maintenance level, so it reads as adequate: the fund-health
    ///         multiplier is 1x and the taker rate rests on its base. This is the single largest
    ///         posture change in the regime, and all three outputs move together because they
    ///         share the target as their reference point.
    function test_scenario_highVolAdequatelyFunded() public {
        (uint256 imr, uint256 target, uint256 fee) = _scenario(BazaarTypes.VARIANCE_EXTREME, 0, 0, 500, true);
        assertEq(target, 450, "target = the 4.5% stress move");
        assertEq(imr, 900, "IMR = 2 x M, no fund-health uplift at 5% coverage");
        assertEq(fee, 159, "1.59 bp base rate: above target, so no deficit surcharge");
    }

    /// @notice The same pair genuinely underfunded at 2% coverage still prices the shortfall
    ///         hard: the deficit surcharge is quadratic, so the rate is 25.63 bp and margin
    ///         carries a fund-health uplift. The base rate is only reached once coverage
    ///         actually meets the target.
    function test_scenario_highVolUnderfunded() public {
        (uint256 imr, uint256 target, uint256 fee) = _scenario(BazaarTypes.VARIANCE_EXTREME, 0, 0, 200, true);
        assertEq(target, 450, "same target: it reads risk, not the fund");
        assertEq(imr, 1899, "2 x 450 x the 2.11x fund-health multiplier");
        assertEq(fee, 2563, "25.63 bp while coverage is 56% short");
    }

    /// @notice A realized liquidation gap keeps raising margin past the 3% point where a
    ///         multiplicative form saturated, and the response COMPOUNDS: the gap lifts the
    ///         stress move, the risen target leaves the same fund short of its coverage, and the
    ///         fund-health multiplier then scales the already-larger stress move. Holding a 5%
    ///         fund, margin runs 900 -> 1899 between a 3% and a 5% gap, far more than the 200bp
    ///         the stress move itself moved. Any change to the target reaches margin and the
    ///         taker rate by this same route.
    function test_scenario_liquidationGapKeepsResponding() public {
        (uint256 imr3, uint256 target3, uint256 fee3) = _scenario(0, 300, 0, 500, true);
        (uint256 imr5, uint256 target5, uint256 fee5) = _scenario(0, 500, 0, 500, true);

        assertEq(target3, 450, "3% gap: 150 + 300, still inside the 5% fund's coverage");
        assertEq(imr3, 900, "so no fund-health uplift: 2 x 450");
        assertEq(fee3, 159, "and the taker rate rests on its base");

        assertEq(target5, 650, "5% gap: the target outruns the 5% fund");
        assertEq(imr5, 1899, "2 x 650 x the 1.46x uplift the shortfall now creates");
        assertGt(fee5, fee3, "a worse gap is priced into entry flow, not just into margin");
    }

    /// @notice A session pair that has demonstrated a 10% reopen. The target reaches the full
    ///         gap rather than half of it, so the same 5% fund now reads as half-covered and
    ///         both margin and the fee tighten sharply, the fee to its 50 bp cap. This is the
    ///         mirror image of the high-vol case and the reason the two must be judged together.
    function test_scenario_sessionPairWithDemonstratedReopen() public {
        (uint256 imr, uint256 target, uint256 fee) = _scenario(0, 0, 1000, 500, false);
        assertEq(target, 1_000, "the full demonstrated reopen, capped at 10%");
        assertEq(imr, 4_000, "2 x 1000 x the 2x fund-health multiplier");
        assertEq(fee, 5_000, "the 50 bp cap: entry flow pre-funds the demonstrated tail");
    }

    /// @notice A session pair carrying a cap-sized reopen. The peak enters the maintenance level
    ///         at full size, so MMR is the cap itself and IMR is twice it — which leaves the
    ///         fund-health multiplier room to lift margin further as coverage falls. A cap set at
    ///         the stress-move ceiling would instead arrive already on MAX_IMR_BP, with no margin
    ///         response left for a pair that is both gap-prone and underfunded.
    function test_scenario_sessionPairAtReopenCap() public {
        uint192 cap = uint192(RiskParamsLib.REOPEN_GAP_EMA_CAP_BP);

        (uint256 imrFunded, uint256 target,) = _scenario(0, 0, cap, 1_000, false);
        assertEq(target, 1_000, "a cap-sized reopen saturates the coverage band");
        assertEq(imrFunded, 5_000, "2 x the cap while the fund meets its target");

        (uint256 imrShort,,) = _scenario(0, 0, cap, 900, false);
        assertEq(imrShort, 6_000, "a short fund still has margin response left under MAX_IMR_BP");
    }

    /// @notice A freshly listed session pair with no gap history sits above the old calm
    ///         baseline: the closure prior alone gives it a 3% stress move, so it holds 3%
    ///         coverage rather than the protocol minimum.
    function test_scenario_sessionPairColdStart() public {
        (, uint256 target,) = _scenario(0, 0, 0, 200, false);
        assertEq(target, 300, "the closure prior reaches the target too");
    }

    /// @notice Every leg of the stress move carries a ceiling of its own: the volatility leg stops
    ///         at VOL_MULTIPLIER_MAX, the reopen peak-hold at REOPEN_GAP_EMA_CAP_BP, and slippage
    ///         at LIQ_MAX_SLIPPAGE_BP — set where it is measured, since each fill is clamped before
    ///         it is weighted and the stored reading is only ever a blend of clamped fills. On a
    ///         calm 24/7 pair that bounds what slippage alone can ask of margin at 2 x (150 + 500),
    ///         about 7.7x leverage, however thin the book a walk sold into.
    function test_slippageLegCeilingIsTheUnloadBand() public {
        (uint256 imr, uint256 target,) = _scenario(0, int256(BazaarTypes.LIQ_MAX_SLIPPAGE_BP), 0, 1_000, true);
        assertEq(target, 650, "150 + 500: the target still tracks M inside the band");
        assertEq(imr, 1_300, "2 x (150 + 500): the most the slippage leg alone can ask");
    }

    /// @notice The reading fades with the clock. With no further liquidation the value the curves
    ///         read halves three days after the batch and keeps falling harmonically — 1/11 of
    ///         itself at thirty days — on a 24/7 market storing prices as it goes, so the pair
    ///         walks back to its volatility curve on its own, and the target walks down with it.
    ///         The store is seeded at 2400, well past the band the measurement caps each fill at,
    ///         so the decay spans the whole curve; it still holds 2400 throughout, since only a
    ///         batch rewrites it, blending against the faded value.
    function test_liquidationGapFadesWithoutAFurtherLiquidation() public {
        // Constants, not a local holding block.timestamp: the optimizer re-reads the opcode
        // after each vm.warp, which would move the anchor with the clock.
        h.setGapTs(EPISODE_TS);
        h.setLastPriceTs(EPISODE_TS);

        (uint256 imr0,,) = _scenario(0, 2400, 0, 1_000, true);
        assertEq(imr0, 5_100, "at the episode: 2 x (150 + 2400)");

        _liveAt(EPISODE_TS + 3 days);
        (uint256 imr3,,) = _scenario(0, 2400, 0, 1_000, true);
        assertEq(imr3, 2_700, "half the gap remains: 2 x (150 + 1200)");

        _liveAt(EPISODE_TS + 30 days);
        (uint256 imr30, uint256 target30,) = _scenario(0, 2400, 0, 1_000, true);
        assertEq(imr30, 736, "2 x (150 + 218)");
        assertEq(target30, 368, "the target follows it down");

        _liveAt(EPISODE_TS + 365 days);
        (uint256 imr365,,) = _scenario(0, 2400, 0, 1_000, true);
        assertEq(imr365, 400, "back on the calm-pair floor");
    }

    /// @dev Moves the clock the way a live market does: its latest stored price lands with it.
    function _liveAt(uint256 ts) internal {
        vm.warp(ts);
        h.setLastPriceTs(ts);
    }

    /// @notice Coverage per unit of maintenance margin is constant while the target band is not
    ///         binding, and decays only once the 10% ceiling truncates it. This is the property
    ///         the consolidation buys, and the exact point at which it stops holding.
    function test_scenario_coverageRatioIsFlatThenTruncates() public {
        // Each fully funded, so the fund-health multiplier is 1x and IMR is exactly 2 x M.
        (uint256 imrA, uint256 targetA,) = _scenario(0, 0, 0, 10_000, true); // M = 200
        (uint256 imrB, uint256 targetB,) = _scenario(BazaarTypes.VARIANCE_EXTREME, 0, 0, 10_000, true); // M = 450
        (uint256 imrC, uint256 targetC,) = _scenario(0, 0, 2000, 10_000, false); // M = 2000, truncated

        assertEq(targetA, imrA / 2, "coverage equals maintenance margin inside the band");
        assertEq(targetB, imrB / 2, "and still does at 100% vol");
        assertEq(targetA, 200);
        assertEq(targetB, 450);

        assertEq(targetC, 1_000, "truncated: M is 2000 but the band stops at 10%");
        assertEq(imrC / 2, 2_000, "so here coverage is half the maintenance margin it backstops");
    }
}
