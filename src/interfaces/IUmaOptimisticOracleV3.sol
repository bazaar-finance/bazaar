// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

/// @notice Minimal UMA Optimistic Oracle V3 interfaces shared across Bazaar contracts.
interface IOptimisticOracleV3CallbackRecipient {
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;
    function assertionDisputedCallback(bytes32 assertionId) external;
}

interface IERC20Minimal {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IOptimisticOracleV3 {
    function defaultIdentifier() external view returns (bytes32);
    function defaultCurrency() external view returns (IERC20Minimal);

    function assertTruth(
        bytes memory claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20Minimal currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 domainId
    ) external returns (bytes32 assertionId);

    function assertTruthWithDefaults(bytes memory claim, address asserter, address callbackRecipient)
        external
        returns (bytes32 assertionId);

    function settleAndGetAssertionResult(bytes32 assertionId) external returns (bool);

    function getAssertion(bytes32 assertionId)
        external
        view
        returns (
            address asserter,
            uint64 assertionTime,
            uint64 expirationTime,
            IERC20Minimal currency,
            uint256 bond,
            bool settled,
            bool disputed,
            bool settlementResolution
        );
}
