// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @dev Minimal storage host so the external library's storage-pointer functions can be called.
contract RiskParamsHarness {
    BazaarTypes.Vault internal pairVault;
    BazaarTypes.PairPrice internal lastPairPrice;
    BazaarTypes.LiquidationGapEma internal liquidationGapEma;

    function setInsurance(uint256 balance) external {
        pairVault.insuranceFundBalance = balance;
    }

    function setOI(uint256 longOI, uint256 shortOI) external {
        pairVault.totalLongOI = longOI;
        pairVault.totalShortOI = shortOI;
    }

    function setVariance(uint256 emaVarianceBp) external {
        lastPairPrice.emaVarianceBp = emaVarianceBp;
    }

    function takerFeeEbp(uint256 currentPrice) external view returns (uint256) {
        return RiskParamsLib.getTakerInsuranceFeeEbp(pairVault, lastPairPrice, liquidationGapEma, currentPrice);
    }
}

/// @notice Pins the taker insurance fee curve to its intended scale (100 EBP = 1 bp).
///         Guards against the constants regressing to a mis-scaled magnitude — a 100×
///         error here once put the minimum all-in taker fee at ~51 bps.
contract RiskParamsLibTest is Test {
    uint256 internal constant SCALE = 1e18; // BAZAAR_SCALE
    uint256 internal constant PRICE = 1e18; // 1:1 so OI size == OI notional

    RiskParamsHarness internal h;

    function setUp() public {
        h = new RiskParamsHarness();
        h.setOI(1_000_000 * SCALE, 0); // $1M OI notional at PRICE
    }

    /// @notice Base fee endpoints: 0.5 bp (50 EBP) at the 2% target, 2 bp (200 EBP) at the 10% target.
    function test_TakerInsuranceFeeBase_Endpoints() public pure {
        assertEq(RiskParamsLib.getTakerInsuranceFeeBase(200), 50, "0.5 bp at INSURANCE_TARGET_BASE");
        assertEq(RiskParamsLib.getTakerInsuranceFeeBase(1_000), 200, "2 bp at INSURANCE_TARGET_MAX");
        // Linear interpolation midway up the target range
        assertEq(RiskParamsLib.getTakerInsuranceFeeBase(600), 125, "interpolated base fee");
    }

    /// @notice Fund exactly at target → base fee, no deficit multiplier: 50 EBP = 0.5 bp.
    function test_TakerInsuranceFee_AtTarget() public {
        h.setInsurance(20_000 * SCALE); // 2% of $1M = the low-vol target
        assertEq(h.takerFeeEbp(PRICE), 50, "0.5 bp when fund is at target");
    }

    /// @notice Fund at 2x target → surplus discount reaches zero fee.
    function test_TakerInsuranceFee_SurplusReachesZero() public {
        h.setInsurance(40_000 * SCALE); // 4% vs 2% target
        assertEq(h.takerFeeEbp(PRICE), 0, "fee fully discounted at 2x target");
    }

    /// @notice 75% deficit → fBase x (1 + 49 x 0.75^2) = 50 x 28.5625 → 1,428 EBP ≈ 14.3 bp.
    function test_TakerInsuranceFee_DeficitMultiplier() public {
        h.setInsurance(5_000 * SCALE); // 0.5% vs 2% target → deficit δ = 0.75
        assertEq(h.takerFeeEbp(PRICE), 1_428, "quadratic deficit multiplier");
    }

    /// @notice Worst case — max-vol target, empty fund → uncapped 200 x 50 = 10,000 EBP, capped at 4,500 EBP = 45 bp.
    function test_TakerInsuranceFee_CapsAt45Bp() public {
        h.setVariance(100_000_000); // VARIANCE_EXTREME → 10% target, fBase = 200 EBP
        h.setInsurance(0); // full deficit, δ = 1
        assertEq(h.takerFeeEbp(PRICE), 4_500, "hard cap is 45 bp, not 45%");
    }

    /// @notice No open interest → infinite coverage → zero fee.
    function test_TakerInsuranceFee_ZeroOI() public {
        h.setOI(0, 0);
        h.setInsurance(1 * SCALE);
        assertEq(h.takerFeeEbp(PRICE), 0, "no OI, no fee");
    }
}
