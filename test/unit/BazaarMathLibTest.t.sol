// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarMathLib} from "../../src/libraries/BazaarMathLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @notice External wrappers so revert paths of the internal library can be asserted cleanly.
contract MathHarness {
    function effectivePrice(BazaarTypes.OrderType ot, uint256 lp, bool isLong, uint256 slip, uint256 oracle)
        external
        pure
        returns (uint256)
    {
        return BazaarMathLib.effectivePrice(ot, lp, isLong, slip, oracle);
    }

    function stopTriggerReached(bool isLong, uint256 trig, uint256 oracle) external pure returns (bool) {
        return BazaarMathLib.stopTriggerReached(isLong, trig, oracle);
    }

    function signedMulDiv(int256 x, int256 y, int256 d) external pure returns (int256) {
        return BazaarMathLib.signedMulDiv(x, y, d);
    }

    function convertExponent(int256 v, int32 from, int32 to) external pure returns (int256) {
        return BazaarMathLib.convertExponent(v, from, to);
    }
}

contract BazaarMathLibTest is Test {
    MathHarness internal h;
    uint256 constant SCALE = 1e18;

    function setUp() public {
        h = new MathHarness();
    }

    // ---------------------------------------------------------------
    // signedMulDiv
    // ---------------------------------------------------------------

    function test_signedMulDiv_basic() public view {
        assertEq(h.signedMulDiv(6, 7, 3), 14);
        assertEq(h.signedMulDiv(1000, 3, 1000), 3);
    }

    function test_signedMulDiv_zeroOperandShortCircuits() public view {
        assertEq(h.signedMulDiv(0, 5, 3), 0);
        assertEq(h.signedMulDiv(5, 0, 3), 0);
        // zero operand short-circuits even with a zero-ish product path
        assertEq(h.signedMulDiv(0, 0, 7), 0);
    }

    function test_signedMulDiv_signCombinations() public view {
        assertEq(h.signedMulDiv(-6, 7, 3), -14); // 1 neg
        assertEq(h.signedMulDiv(6, -7, 3), -14); // 1 neg
        assertEq(h.signedMulDiv(6, 7, -3), -14); // 1 neg
        assertEq(h.signedMulDiv(-6, -7, 3), 14); // 2 neg
        assertEq(h.signedMulDiv(-6, 7, -3), 14); // 2 neg
        assertEq(h.signedMulDiv(6, -7, -3), 14); // 2 neg
        assertEq(h.signedMulDiv(-6, -7, -3), -14); // 3 neg
    }

    function test_signedMulDiv_roundsTowardZero() public view {
        // 7/2 = 3.5 -> 3;  -7/2 = -3.5 -> -3 (toward zero, NOT floor -4)
        assertEq(h.signedMulDiv(7, 1, 2), 3);
        assertEq(h.signedMulDiv(-7, 1, 2), -3);
        assertEq(h.signedMulDiv(7, -1, 2), -3);
        assertEq(h.signedMulDiv(-7, -1, 2), 3);
    }

    function test_signedMulDiv_denomZeroReverts() public {
        vm.expectRevert(BazaarMathLib.BazaarMathLib__DivisionByZero.selector);
        h.signedMulDiv(6, 7, 0);
    }

    function test_signedMulDiv_int256MinOperandReverts() public {
        vm.expectRevert(BazaarMathLib.BazaarMathLib__OperandTooSmall.selector);
        h.signedMulDiv(type(int256).min, 1, 1);
        vm.expectRevert(BazaarMathLib.BazaarMathLib__OperandTooSmall.selector);
        h.signedMulDiv(1, type(int256).min, 1);
        vm.expectRevert(BazaarMathLib.BazaarMathLib__OperandTooSmall.selector);
        h.signedMulDiv(1, 1, type(int256).min);
    }

    function test_signedMulDiv_overflowReverts() public {
        // 2 * int256.max / 1 exceeds int256.max -> overflow guard
        vm.expectRevert(BazaarMathLib.BazaarMathLib__ResultOverflow.selector);
        h.signedMulDiv(type(int256).max, 2, 1);
    }

    function test_signedMulDiv_maxInRangeOk() public view {
        // int256.max * 1 / 1 fits exactly
        assertEq(h.signedMulDiv(type(int256).max, 1, 1), type(int256).max);
    }

    function testFuzz_signedMulDiv_matchesReference(int128 x, int128 y, int128 d) public view {
        vm.assume(d != 0);
        // int128 operands can't hit int256.min and can't overflow int256 -> always valid
        int256 expected = (int256(x) * int256(y)) / int256(d); // Solidity trunc-toward-zero
        assertEq(h.signedMulDiv(x, y, d), expected);
    }

    // ---------------------------------------------------------------
    // convertExponent
    // ---------------------------------------------------------------

    function test_convertExponent_sameExpoUnchanged() public view {
        assertEq(h.convertExponent(12345, -8, -8), 12345);
        assertEq(h.convertExponent(-12345, 6, 6), -12345);
    }

    function test_convertExponent_moreToLessDivides() public view {
        // -8 -> -6 : divide by 10^2
        assertEq(h.convertExponent(123456789, -8, -6), 1234567); // trunc toward zero
        assertEq(h.convertExponent(-123456789, -8, -6), -1234567);
        // sub-unit rounds toward zero
        assertEq(h.convertExponent(199, -8, -6), 1);
        assertEq(h.convertExponent(-199, -8, -6), -1);
    }

    function test_convertExponent_lessToMoreMultiplies() public view {
        // -6 -> -8 : multiply by 10^2
        assertEq(h.convertExponent(12345, -6, -8), 1234500);
        assertEq(h.convertExponent(-12345, -6, -8), -1234500);
    }

    function test_convertExponent_pythToBazaar() public view {
        // Pyth 1e8 price scaled up to BAZAAR 1e18: multiply by 1e10
        assertEq(h.convertExponent(12345678, -8, -18), 12345678 * 1e10);
    }

    function test_convertExponent_bazaarToUsdc() public view {
        // BAZAAR 1e18 down to USDC 1e6: divide by 1e12
        assertEq(h.convertExponent(1_500_000 * int256(SCALE), -18, -6), 1_500_000 * 1e6);
    }

    // ---------------------------------------------------------------
    // effectivePrice
    // ---------------------------------------------------------------

    function test_effectivePrice_nonMarketTypesReturnLimit() public view {
        uint256 lp = 999 * SCALE;
        uint256 oracle = 100 * SCALE;
        assertEq(h.effectivePrice(BazaarTypes.OrderType.Limit, lp, true, 500, oracle), lp);
        assertEq(h.effectivePrice(BazaarTypes.OrderType.StopLimit, lp, true, 500, oracle), lp);
        assertEq(h.effectivePrice(BazaarTypes.OrderType.TakeProfit, lp, false, 500, oracle), lp);
    }

    function test_effectivePrice_marketAppliesSlippage() public view {
        uint256 oracle = 100 * SCALE;
        // 5% slippage: long pays up, short receives down
        assertEq(h.effectivePrice(BazaarTypes.OrderType.Market, 0, true, 500, oracle), 105 * SCALE);
        assertEq(h.effectivePrice(BazaarTypes.OrderType.Market, 0, false, 500, oracle), 95 * SCALE);
    }

    function test_effectivePrice_stopLossAppliesSlippage() public view {
        uint256 oracle = 100 * SCALE;
        assertEq(h.effectivePrice(BazaarTypes.OrderType.StopLoss, 0, true, 500, oracle), 105 * SCALE);
        assertEq(h.effectivePrice(BazaarTypes.OrderType.StopLoss, 0, false, 500, oracle), 95 * SCALE);
    }

    function test_effectivePrice_zeroSlippageIsOracle() public view {
        uint256 oracle = 100 * SCALE;
        assertEq(h.effectivePrice(BazaarTypes.OrderType.Market, 0, true, 0, oracle), oracle);
        assertEq(h.effectivePrice(BazaarTypes.OrderType.Market, 0, false, 0, oracle), oracle);
    }

    // ---------------------------------------------------------------
    // stopTriggerReached
    // ---------------------------------------------------------------

    function test_stopTrigger_buyStop_firesAtOrAbove() public view {
        assertTrue(h.stopTriggerReached(true, 100, 100)); // inclusive
        assertTrue(h.stopTriggerReached(true, 100, 101));
        assertFalse(h.stopTriggerReached(true, 100, 99));
    }

    function test_stopTrigger_sellStop_firesAtOrBelow() public view {
        assertTrue(h.stopTriggerReached(false, 100, 100)); // inclusive
        assertTrue(h.stopTriggerReached(false, 100, 99));
        assertFalse(h.stopTriggerReached(false, 100, 101));
    }
}
