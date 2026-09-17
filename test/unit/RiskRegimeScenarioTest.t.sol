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

    function seed(uint256 variance, int256 gap, uint192 reopen, uint256 fund, uint256 oi) external {
        lastPairPrice.emaVarianceBp = variance;
        liquidationGapEma.emaGapBp = gap;
        reopenGapEma.gapEmaBp = reopen;
        pairVault.insuranceFundBalance = fund;
        pairVault.totalLongOI = oi;
        pairVault.totalShortOI = oi;
        marginRequirements.lastUpdateTs = 0;
    }

    function run(uint256 price, bool cont) external {
        RiskParamsLib.calculateIMRandMMR(
            marginRequirements, lastPairPrice, liquidationGapEma, pairVault, reopenGapEma, price, cont, 0, 50_000, 0
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

    RiskScenarioHarness internal h;

    function setUp() public {
        h = new RiskScenarioHarness();
        vm.warp(10 days);
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
        assertEq(fee, 96, "0.96 bp base rate: above target, so no deficit surcharge");
    }

    /// @notice The same pair genuinely underfunded at 2% coverage still prices the shortfall
    ///         hard: the deficit surcharge is quadratic, so the rate is 15.5 bp and margin
    ///         carries a fund-health uplift. The base rate is only reached once coverage
    ///         actually meets the target.
    function test_scenario_highVolUnderfunded() public {
        (uint256 imr, uint256 target, uint256 fee) = _scenario(BazaarTypes.VARIANCE_EXTREME, 0, 0, 200, true);
        assertEq(target, 450, "same target: it reads risk, not the fund");
        assertEq(imr, 1899, "2 x 450 x the 2.11x fund-health multiplier");
        assertEq(fee, 1547, "15.5 bp while coverage is 56% short");
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
        assertEq(fee3, 96, "and the taker rate rests on its base");

        assertEq(target5, 650, "5% gap: the target outruns the 5% fund");
        assertEq(imr5, 1899, "2 x 650 x the 1.46x uplift the shortfall now creates");
        assertGt(fee5, fee3, "a worse gap is priced into entry flow, not just into margin");
    }

    /// @notice A session pair that has demonstrated a 10% reopen. The target reaches the full
    ///         gap rather than half of it, so the same 5% fund now reads as half-covered and
    ///         both margin and the fee tighten sharply. This is the mirror image of the high-vol
    ///         case and the reason the two must be judged together.
    function test_scenario_sessionPairWithDemonstratedReopen() public {
        (uint256 imr, uint256 target, uint256 fee) = _scenario(0, 0, 1000, 500, false);
        assertEq(target, 1_000, "the full demonstrated reopen, capped at 10%");
        assertEq(imr, 4_000, "2 x 1000 x the 2x fund-health multiplier");
        assertEq(fee, 2_650, "26.5 bp: entry flow pre-funds the demonstrated tail");
    }

    /// @notice A freshly listed session pair with no gap history sits above the old calm
    ///         baseline: the closure prior alone gives it a 3% stress move, so it holds 3%
    ///         coverage rather than the protocol minimum.
    function test_scenario_sessionPairColdStart() public {
        (, uint256 target,) = _scenario(0, 0, 0, 200, false);
        assertEq(target, 300, "the closure prior reaches the target too");
    }

    /// @notice CHARACTERIZATION of a live hazard, not an endorsement of it. The liquidation-gap
    ///         EMA is the one leg of the stress move with no ceiling of its own: the volatility
    ///         leg stops at VOL_MULTIPLIER_MAX and the reopen peak-hold at REOPEN_GAP_EMA_CAP_BP,
    ///         while the gap is bounded only by the clamp on the SUM. A crash that leaves the
    ///         oracle far below the estates' average bankruptcy price prints a gap of that whole
    ///         distance, because the unload band is measured from the oracle. At 24% the
    ///         maintenance level lands at 25.5%, against 4.5% under a saturating multiplier.
    function test_hazard_extremeLiquidationGapHasNoLegCeiling() public {
        (uint256 imr, uint256 target,) = _scenario(0, 2400, 0, 1_000, true);
        assertEq(target, 1_000, "the target truncates at its 10% ceiling");
        assertEq(imr, 5_100, "2 x (150 + 2400): the gap leg alone carries margin to 51%");
        assertEq(imr / 2, 2_550, "maintenance margin at 25.5% off one episode");

        // The clamp on the sum is the only thing bounding it: 3850bp of gap pins the ceiling.
        (uint256 pinned,,) = _scenario(0, 3_850, 0, 1_000, true);
        assertEq(pinned, 8_000, "gap alone reaches MAX_IMR_BP, i.e. 1.25x maximum leverage");
    }

    /// @notice CHARACTERIZATION of the same hazard's persistence. The gap EMA's time decay is
    ///         applied inside updateLiquidationGapEmaBatch, which only runs when a liquidation
    ///         unload actually fills. Nothing decays it on the read side, so a pair that goes
    ///         quiet after one bad episode holds the elevated maintenance level indefinitely.
    ///         The tau = 3 days on the estimator does not bound how long the margin curve
    ///         carries the observation.
    function test_hazard_liquidationGapNeverDecaysWithoutAFurtherLiquidation() public {
        (uint256 imrAtEpisode,,) = _scenario(0, 2400, 0, 1_000, true);

        vm.warp(block.timestamp + 365 days);
        (uint256 imrAYearLater,,) = _scenario(0, 2400, 0, 1_000, true);

        assertEq(imrAYearLater, imrAtEpisode, "a year of quiet does not relax the gap leg at all");
        assertEq(imrAYearLater, 5_100, "still 51% initial margin");
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
