// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BazaarPair} from "../src/BazaarPair.sol";
import {BazaarTypes} from "../src/libraries/BazaarTypes.sol";

/// @title OrderView
/// @notice Reads a pair's `orders` getter into a BazaarTypes.Order struct for tests.
/// @dev The getter returns an 18-element tuple, so reading one field positionally means
///      counting commas — and every field a test reads that way silently moves when the struct's
///      packed layout changes. Funnelling every read through this one destructuring means a
///      layout change breaks exactly here, and every call site keeps naming the field it wants.
library OrderView {
    /// @dev Two half-tuple reads rather than one 18-element destructuring: binding all 18 at
    ///      once exceeds the stack. Both halves read the same immutable storage in the same
    ///      call frame, so they cannot disagree.
    function order(BazaarPair pair, uint256 orderId) internal view returns (BazaarTypes.Order memory o) {
        (
            o.creator,
            o.canceledBlock,
            o.orderType,
            o.isLong,
            o.isPostOnly,
            o.tif,
            o.integrator,
            o.expiryBlock,
            o.inBook
        ) = _head(pair, orderId);
        (
            o.maxSlippageBp,
            o.triggerPrice,
            o.limitPrice,
            o.size,
            o.filledSize,
            o.creationBlock,
            o.filledBlock,
            o.prevInBook,
            o.nextInBook
        ) = _tail(pair, orderId);
    }

    function _head(BazaarPair pair, uint256 orderId)
        private
        view
        returns (address, uint64, BazaarTypes.OrderType, bool, bool, BazaarTypes.TimeInForce, address, uint64, bool)
    {
        (
            address creator,
            uint64 canceledBlock,
            BazaarTypes.OrderType orderType,
            bool isLong,
            bool isPostOnly,
            BazaarTypes.TimeInForce tif,
            address integrator,
            uint64 expiryBlock,
            bool inBook,,,,,,,,,
        ) = pair.orders(orderId);
        return (creator, canceledBlock, orderType, isLong, isPostOnly, tif, integrator, expiryBlock, inBook);
    }

    function _tail(BazaarPair pair, uint256 orderId)
        private
        view
        returns (uint24, uint128, uint128, uint128, uint128, uint64, uint64, uint64, uint64)
    {
        (
            ,,,,,,,,,
            uint24 maxSlippageBp,
            uint128 triggerPrice,
            uint128 limitPrice,
            uint128 size,
            uint128 filledSize,
            uint64 creationBlock,
            uint64 filledBlock,
            uint64 prevInBook,
            uint64 nextInBook
        ) = pair.orders(orderId);
        return
            (
                maxSlippageBp,
                triggerPrice,
                limitPrice,
                size,
                filledSize,
                creationBlock,
                filledBlock,
                prevInBook,
                nextInBook
            );
    }
}
