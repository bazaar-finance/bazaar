// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";

/// @title BazaarMathLib
/// @notice Internal library for signed math operations shared across BazaarPair subsystems
library BazaarMathLib {
    // -------------------- Errors --------------------

    error BazaarMathLib__DivisionByZero();
    error BazaarMathLib__OperandTooSmall();
    error BazaarMathLib__ResultOverflow();

    /// @notice Compute the effective price of an order against a batch oracle price.
    /// @dev Limit / StopLimit / TakeProfit use the configured limitPrice.
    ///      Market / StopLoss derive the bound from oracle ± slippage.
    ///      Shared between MatchingEngineLib (matching) and BazaarSequencer (omission challenges)
    ///      so both subsystems use identical math.
    function effectivePrice(
        BazaarTypes.OrderType orderType,
        uint256 limitPrice,
        bool isLong,
        uint256 maxSlippageBp,
        uint256 oraclePrice
    ) internal pure returns (uint256) {
        if (orderType != BazaarTypes.OrderType.Market && orderType != BazaarTypes.OrderType.StopLoss) {
            return limitPrice;
        }
        unchecked {
            uint256 adj = oraclePrice * maxSlippageBp / BazaarTypes.BP_SCALE;
            return isLong ? oraclePrice + adj : oraclePrice - adj;
        }
    }

    /// @notice Whether a stop order's trigger has been reached by the given oracle price, from the
    ///         order owner's perspective.
    /// @dev A buy stop (isLong) fires once the price rises to/through the trigger; a sell stop
    ///      (!isLong) fires once it falls to/through it. Inclusive at the trigger ("at or worse").
    ///      A StopLoss closing a long is a sell stop (isLong=false) → price must be <= trigger; a
    ///      StopLoss closing a short is a buy stop (isLong=true) → price must be >= trigger.
    ///      The caller is responsible for only applying this to trigger-gated order types.
    ///      Shared between MatchingEngineLib (matching) and BazaarSequencer (omission challenges)
    ///      so both subsystems use identical trigger semantics.
    function stopTriggerReached(bool isLong, uint256 triggerPrice, uint256 oraclePrice) internal pure returns (bool) {
        return isLong ? oraclePrice >= triggerPrice : oraclePrice <= triggerPrice;
    }

    /// @notice Safe signed multiply-divide: (x * y) / denominator supporting negative operands.
    /// @dev All inputs are int256. Result rounds toward zero. Reverts on denominator == 0 or overflow.
    ///      Internally uses absolute values with 512-bit precision via OZ Math.mulDiv.
    /// @param x Signed multiplicand.
    /// @param y Signed multiplier.
    /// @param denominator Signed divisor (must be non-zero).
    /// @return result Signed result of (x * y) / denominator.
    function signedMulDiv(int256 x, int256 y, int256 denominator) internal pure returns (int256 result) {
        if (denominator == 0) revert BazaarMathLib__DivisionByZero();
        if (x == 0 || y == 0) return 0;
        if (x == type(int256).min || y == type(int256).min || denominator == type(int256).min) {
            revert BazaarMathLib__OperandTooSmall();
        }

        uint8 negCount = 0;
        if (x < 0) negCount++;
        if (y < 0) negCount++;
        if (denominator < 0) negCount++;
        bool negative = (negCount % 2 == 1);

        uint256 ax = uint256(x < 0 ? -x : x);
        uint256 ay = uint256(y < 0 ? -y : y);
        uint256 ad = uint256(denominator < 0 ? -denominator : denominator);

        uint256 unsignedResult = Math.mulDiv(ax, ay, ad);

        if (unsignedResult > uint256(type(int256).max)) revert BazaarMathLib__ResultOverflow();
        result = negative ? -int256(unsignedResult) : int256(unsignedResult);
    }

    /**
     * @notice Converts a value from one exponent scale to another.
     * @dev Handles positive and negative exponents. Will revert if scaling factor overflows.
     * @param value The original integer value.
     * @param fromExpo The exponent/decimals the value is currently in (e.g., -8 for 1e8).
     * @param toExpo The target exponent/decimals (e.g., -6 for 1e6).
     * @return result The value scaled to the new exponent.
     */
    function convertExponent(int256 value, int32 fromExpo, int32 toExpo) internal pure returns (int256 result) {
        if (fromExpo == toExpo) {
            result = value;
        } else if (fromExpo < toExpo) {
            // Going from more precision (e.g., -8) to less (e.g., -6): divide
            uint32 diff = uint32(uint32(toExpo - fromExpo));
            result = value / int256(10 ** diff);
        } else {
            // Going from less precision (e.g., -6) to more (e.g., -8): multiply
            uint32 diff = uint32(uint32(fromExpo - toExpo));
            result = value * int256(10 ** diff);
        }
    }
}
