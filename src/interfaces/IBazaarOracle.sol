// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

interface IBazaarOracle {
    /// @notice Parse historical price update data and return the price within [minPublishTime, maxPublishTime].
    /// @dev Reverts if no price is found within the window (PriceFeedNotFoundWithinRange).
    function fetchHistoricalPrice(
        bytes32 baseFeedId,
        bytes[] calldata priceUpdate,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (uint256 spotPrice);

    function getUpdateFee(bytes[] calldata priceUpdate) external view returns (uint256);
}
