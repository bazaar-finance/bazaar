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
    /// @dev Field order and types mirror OOv3's own struct: getAssertion encodes it positionally.
    struct EscalationManagerSettings {
        bool arbitrateViaEscalationManager;
        bool discardOracle;
        bool validateDisputers;
        address assertingCaller;
        address escalationManager;
    }

    /// @dev Field order and types mirror OOv3's own struct, with EscalationManagerSettings nested
    ///      first: getAssertion encodes it positionally, so a reordered or flattened declaration
    ///      would decode the wrong words without reverting.
    struct Assertion {
        EscalationManagerSettings escalationManagerSettings;
        address asserter;
        uint64 assertionTime;
        bool settled;
        IERC20Minimal currency;
        uint64 expirationTime; // from this instant on OOv3 refuses disputes and allows settlement
        bool settlementResolution; // false until settled
        bytes32 domainId;
        bytes32 identifier;
        uint256 bond;
        address callbackRecipient;
        address disputer; // zero while undisputed
    }

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

    /// @notice The stored record of an assertion; all-zero for an unknown id.
    /// @dev A plain view: unlike assertTruth, disputeAssertion and settleAssertion it does not
    ///      take OOv3's reentrancy lock, so it answers even from inside one of OOv3's own
    ///      callbacks, where a settlement attempt reverts on the lock.
    function getAssertion(bytes32 assertionId) external view returns (Assertion memory);
}
