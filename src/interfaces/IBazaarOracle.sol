// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

interface IBazaarOracle {
    /// @notice Parse a price update and return the USD price of the first tick published at or after
    ///         minPublishTime, provided that tick was published no later than maxPublishTime.
    /// @dev Reverts with Pyth's PriceFeedNotFoundWithinRange when no supplied update is that tick.
    function fetchFirstPriceAtOrAfter(
        bytes32 baseFeedId,
        bytes[] calldata priceUpdate,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (uint256 spotPrice);

    /// @notice Parse a chained sample set and return the median of its USD prices: the first print
    ///         at or after firstTarget, then for each later sample the first print at or after
    ///         spacing past the sample before, every one published no later than maxPublishTime.
    /// @dev Reverts unless the set holds exactly count samples, one update per leg each, and every
    ///      sample is the first print at or after its own target; msg.value must equal getSampleSetFee.
    function fetchChainedMedian(
        bytes32 baseFeedId,
        bytes[] calldata priceUpdate,
        uint64 firstTarget,
        uint64 maxPublishTime,
        uint64 spacing,
        uint256 count
    ) external payable returns (uint256 medianPrice);

    function getUpdateFee(bytes[] calldata priceUpdate) external view returns (uint256);

    /// @notice The fee fetchChainedMedian charges for priceUpdate: Pyth's fee for each sample's updates, summed.
    function getSampleSetFee(bytes32 baseFeedId, bytes[] calldata priceUpdate) external view returns (uint256 fee);
}
