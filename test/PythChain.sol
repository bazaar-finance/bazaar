// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

/// @notice Builds the sample sets the chain rule settles a vote-scheduled pair at: COUNT prints of a
///         direct feed, the first published at or after the cutoff and each later one the first
///         print at least SPACING after the one before (BazaarOracle.fetchChainedMedian).
library PythChain {
    uint256 internal constant COUNT = 5; // mirror of BazaarPairTerminator.SETTLEMENT_SAMPLE_COUNT
    uint64 internal constant SPACING = 10 minutes; // mirror of BazaarPairTerminator.SETTLEMENT_SAMPLE_SPACING

    /// @dev A print of `feedId` at `priceUsd`, eight decimals, 0.1% confidence, published at
    ///      `publishTime` with its predecessor published at `prevPublishTime`.
    function tick(MockPyth pyth, bytes32 feedId, uint256 priceUsd, uint64 publishTime, uint64 prevPublishTime)
        internal
        view
        returns (bytes memory)
    {
        int64 price = int64(int256(priceUsd * 1e8));
        uint64 conf = uint64(priceUsd * 1e8 / 1000);
        return pyth.createPriceFeedUpdateData(feedId, price, conf, -8, price, conf, publishTime, prevPublishTime);
    }

    /// @dev A valid chain priced `pricesUsd`, sample by sample: the first published at
    ///      `firstPublish` with its predecessor at `firstPrev`, each later one published exactly at
    ///      its target, SPACING after the sample before, with its predecessor a second earlier.
    function chain(MockPyth pyth, bytes32 feedId, uint256[5] memory pricesUsd, uint64 firstPublish, uint64 firstPrev)
        internal
        view
        returns (bytes[] memory pu)
    {
        pu = new bytes[](COUNT);
        uint64 publish = firstPublish;
        uint64 prev = firstPrev;
        for (uint256 k = 0; k < COUNT; k++) {
            pu[k] = tick(pyth, feedId, pricesUsd[k], publish, prev);
            prev = publish + SPACING - 1;
            publish += SPACING;
        }
    }

    /// @dev As chain, every sample at `priceUsd`.
    function flat(MockPyth pyth, bytes32 feedId, uint256 priceUsd, uint64 firstPublish, uint64 firstPrev)
        internal
        view
        returns (bytes[] memory)
    {
        return chain(pyth, feedId, [priceUsd, priceUsd, priceUsd, priceUsd, priceUsd], firstPublish, firstPrev);
    }

    /// @dev When the last sample of such a chain is published, the first sample at `firstPublish`:
    ///      the earliest moment the set exists.
    function lastPublish(uint64 firstPublish) internal pure returns (uint64) {
        return firstPublish + uint64(COUNT - 1) * SPACING;
    }
}
