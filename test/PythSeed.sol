// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

/// @notice Marks a feed as known to a MockPyth without giving it a usable price.
/// @dev The factory lists a raw feed ID only once Pyth has stored a price for it, so every test
///      that proposes a raw feed seeds it first. The stored update carries the oldest publish time
///      the mock accepts and a dust price: it satisfies the existence read but is never fresh
///      enough to price a pair, and any real update a test pushes later replaces it.
library PythSeed {
    function seed(address pyth, bytes32 feedId) internal {
        bytes[] memory u = new bytes[](1);
        u[0] = MockPyth(pyth).createPriceFeedUpdateData(feedId, 1, 0, -8, 1, 0, 1, 0);
        MockPyth(pyth).updatePriceFeeds{value: MockPyth(pyth).getUpdateFee(u)}(u);
    }
}
