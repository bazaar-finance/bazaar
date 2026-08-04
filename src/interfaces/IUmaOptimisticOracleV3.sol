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
    function finder() external view returns (address);

    /// @notice Re-reads the DVM's whitelists into OOv3's local cache for the given identifier and
    ///         currency. PUBLIC and OVERWRITING: it sets the cache to the current live-whitelist
    ///         value, so anyone can flip a de-whitelisted identifier's cache back to false (only
    ///         the internal assert-path cache check is sticky-true). The factory calls this at
    ///         construction and activation purely as a first-assertion gas nicety — no liveness
    ///         property relies on the cache.
    function syncUmaParams(bytes32 identifier, address currency) external;

    /// @notice The smallest bond OOv3 will accept for `currency`, derived from UMA's final fee.
    /// @dev Reads the SAME cached final fee that `assertTruth`'s own `bond >= getMinimumBond` check
    ///      uses, and that cache is only refreshed by `syncUmaParams`. So a value read here and the
    ///      requirement enforced moments later inside `assertTruth` cannot disagree within a
    ///      transaction. Returns 0 for a currency OOv3 has never cached — callers must therefore
    ///      treat this as a floor to rise to, never as the bond to post.
    function getMinimumBond(address currency) external view returns (uint256);

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

    // NOTE: real OOv3's getAssertion returns a single struct with nested EscalationManagerSettings
    // — NOT a flat tuple. A flat-tuple declaration here would decode garbage on mainnet while
    // passing against the mock, so it is deliberately omitted; nothing in src/ needs it.
}
