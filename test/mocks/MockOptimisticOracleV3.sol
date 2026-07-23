// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {
    IOptimisticOracleV3,
    IOptimisticOracleV3CallbackRecipient,
    IERC20Minimal
} from "../../src/interfaces/IUmaOptimisticOracleV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockOptimisticOracleV3
/// @notice Realistic mock of UMA's Optimistic Oracle V3 that mirrors the real sandbox behavior.
///         Supports bond pulling, liveness enforcement, disputes with callbacks, and proper settlement.
contract MockOptimisticOracleV3 is IOptimisticOracleV3 {
    bytes32 public constant DEFAULT_IDENTIFIER = "ASSERT_TRUTH";
    IERC20Minimal public immutable currency;
    uint64 public immutable defaultLiveness;

    uint256 private _nextAssertionNonce;

    struct Assertion {
        address asserter;
        address callbackRecipient;
        address escalationManager;
        address disputer;
        IERC20Minimal bondCurrency;
        uint256 bond;
        uint64 assertionTime;
        uint64 expirationTime;
        bytes32 identifier;
        bool settled;
        bool disputed;
        bool settlementResolution;
    }

    mapping(bytes32 => Assertion) public assertions;

    // ---- Mock DVM resolution (for disputed assertions) ----
    mapping(bytes32 => bool) private _dvmResolutionSet;
    mapping(bytes32 => bool) private _dvmResolution;

    // ---- Events (matching real OOv3) ----
    event AssertionMade(
        bytes32 indexed assertionId,
        address indexed asserter,
        address callbackRecipient,
        uint64 expirationTime,
        IERC20Minimal currency,
        uint256 bond,
        bytes32 identifier
    );
    event AssertionDisputed(bytes32 indexed assertionId, address indexed disputer);
    event AssertionSettled(bytes32 indexed assertionId, address indexed asserter, bool result);

    // ---- Errors ----
    error Assertion__AlreadySettled();
    error Assertion__NotExpired();
    error Assertion__AlreadyDisputed();
    error Assertion__DoesNotExist();
    error Assertion__DisputedNotResolved();

    constructor(address _currency, uint64 _defaultLiveness) {
        currency = IERC20Minimal(_currency);
        defaultLiveness = _defaultLiveness;
    }

    function defaultIdentifier() external pure override returns (bytes32) {
        return DEFAULT_IDENTIFIER;
    }

    function defaultCurrency() external view override returns (IERC20Minimal) {
        return currency;
    }

    /// @notice Claim bytes by assertion ID, stored so tests can assert on claim content.
    mapping(bytes32 => bytes) public claims;

    /// @notice Assert a truth claim. Pulls bond from msg.sender (the contract calling this, e.g. Factory).
    function assertTruth(
        bytes memory claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        IERC20Minimal _currency,
        uint256 bond,
        bytes32 identifier,
        bytes32 /* domainId */
    ) external override returns (bytes32 assertionId) {
        // Pull bond from caller (the contract that approved, e.g. Factory or TerminatePair)
        _currency.transferFrom(msg.sender, address(this), bond);

        assertionId = keccak256(abi.encodePacked(_nextAssertionNonce++, block.timestamp, asserter));
        claims[assertionId] = claim;

        assertions[assertionId] = Assertion({
            asserter: asserter,
            callbackRecipient: callbackRecipient,
            escalationManager: escalationManager,
            disputer: address(0),
            bondCurrency: _currency,
            bond: bond,
            assertionTime: uint64(block.timestamp),
            expirationTime: uint64(block.timestamp) + liveness,
            identifier: identifier,
            settled: false,
            disputed: false,
            settlementResolution: false
        });

        emit AssertionMade(
            assertionId, asserter, callbackRecipient, uint64(block.timestamp) + liveness, _currency, bond, identifier
        );
    }

    function assertTruthWithDefaults(
        bytes memory,
        /* claim */
        address asserter,
        address callbackRecipient
    )
        external
        override
        returns (bytes32 assertionId)
    {
        assertionId = keccak256(abi.encodePacked(_nextAssertionNonce++, block.timestamp, asserter));

        assertions[assertionId] = Assertion({
            asserter: asserter,
            callbackRecipient: callbackRecipient,
            escalationManager: address(0),
            disputer: address(0),
            bondCurrency: currency,
            bond: 0,
            assertionTime: uint64(block.timestamp),
            expirationTime: uint64(block.timestamp) + defaultLiveness,
            identifier: DEFAULT_IDENTIFIER,
            settled: false,
            disputed: false,
            settlementResolution: false
        });

        emit AssertionMade(
            assertionId,
            asserter,
            callbackRecipient,
            uint64(block.timestamp) + defaultLiveness,
            currency,
            0,
            DEFAULT_IDENTIFIER
        );
    }

    /// @notice Dispute an assertion. Disputer must post matching bond. Calls assertionDisputedCallback.
    function disputeAssertion(bytes32 assertionId, address disputer) external {
        Assertion storage a = assertions[assertionId];
        if (a.asserter == address(0)) revert Assertion__DoesNotExist();
        if (a.settled) revert Assertion__AlreadySettled();
        if (a.disputed) revert Assertion__AlreadyDisputed();

        // Pull matching bond from disputer
        if (a.bond > 0) {
            a.bondCurrency.transferFrom(msg.sender, address(this), a.bond);
        }

        a.disputed = true;
        a.disputer = disputer;

        emit AssertionDisputed(assertionId, disputer);

        // Notify callback recipient
        if (a.callbackRecipient != address(0)) {
            IOptimisticOracleV3CallbackRecipient(a.callbackRecipient).assertionDisputedCallback(assertionId);
        }
    }

    /// @notice Settle an assertion and return the result.
    ///         - Undisputed + past liveness → resolves true, bond returned to asserter
    ///         - Disputed + DVM resolved → bond goes to winner
    function settleAndGetAssertionResult(bytes32 assertionId) external override returns (bool) {
        Assertion storage a = assertions[assertionId];
        if (a.asserter == address(0)) revert Assertion__DoesNotExist();
        if (a.settled) return a.settlementResolution;

        bool result;

        if (!a.disputed) {
            // Undisputed — must wait for liveness to expire
            if (block.timestamp < a.expirationTime) revert Assertion__NotExpired();
            result = true;
            // Return bond to asserter
            if (a.bond > 0) {
                IERC20(address(a.bondCurrency)).transfer(a.asserter, a.bond);
            }
        } else {
            // Disputed — check DVM resolution
            if (!_dvmResolutionSet[assertionId]) revert Assertion__DisputedNotResolved();
            result = _dvmResolution[assertionId];

            if (a.bond > 0) {
                // Winner gets both bonds (simplified — real UMA takes a fee)
                address winner = result ? a.asserter : a.disputer;
                IERC20(address(a.bondCurrency)).transfer(winner, a.bond * 2);
            }
        }

        a.settled = true;
        a.settlementResolution = result;

        emit AssertionSettled(assertionId, a.asserter, result);

        // Notify callback recipient
        if (a.callbackRecipient != address(0)) {
            IOptimisticOracleV3CallbackRecipient(a.callbackRecipient).assertionResolvedCallback(assertionId, result);
        }

        return result;
    }

    function getAssertion(bytes32 assertionId)
        external
        view
        override
        returns (
            address asserter,
            uint64 assertionTime,
            uint64 expirationTime,
            IERC20Minimal _currency,
            uint256 bond,
            bool settled,
            bool disputed,
            bool settlementResolution
        )
    {
        Assertion storage a = assertions[assertionId];
        return (
            a.asserter,
            a.assertionTime,
            a.expirationTime,
            a.bondCurrency,
            a.bond,
            a.settled,
            a.disputed,
            a.settlementResolution
        );
    }

    // ==================== Test Helpers ====================

    /// @notice Warp past liveness so the assertion can be settled. Use vm.warp in tests instead if available.
    ///         This is a convenience for cast-based testing on Anvil.

    /// @notice Resolve a disputed assertion via the mock DVM (simulates UMA voter resolution).
    function mockDvmResolve(bytes32 assertionId, bool result) external {
        Assertion storage a = assertions[assertionId];
        require(a.disputed, "Not disputed");
        require(!a.settled, "Already settled");
        _dvmResolutionSet[assertionId] = true;
        _dvmResolution[assertionId] = result;
    }

    /// @notice Force-settle an assertion immediately, bypassing liveness and dispute checks.
    ///         For quick testing when you don't want to deal with time.
    function mockForceSettle(bytes32 assertionId, bool result) external {
        Assertion storage a = assertions[assertionId];
        require(a.asserter != address(0), "Assertion does not exist");
        require(!a.settled, "Already settled");

        a.settled = true;
        a.settlementResolution = result;

        // Return bond(s) based on result
        if (a.bond > 0) {
            if (!a.disputed) {
                // Undisputed — return bond to asserter if result is true, otherwise burn (no disputer)
                if (result) {
                    IERC20(address(a.bondCurrency)).transfer(a.asserter, a.bond);
                }
            } else {
                // Disputed — winner gets both bonds
                address winner = result ? a.asserter : a.disputer;
                IERC20(address(a.bondCurrency)).transfer(winner, a.bond * 2);
            }
        }

        emit AssertionSettled(assertionId, a.asserter, result);

        // Notify callback recipient
        if (a.callbackRecipient != address(0)) {
            IOptimisticOracleV3CallbackRecipient(a.callbackRecipient).assertionResolvedCallback(assertionId, result);
        }
    }

    /// @notice Check if an assertion's liveness has expired (convenience for testing).
    function isExpired(bytes32 assertionId) external view returns (bool) {
        return block.timestamp >= assertions[assertionId].expirationTime;
    }
}
