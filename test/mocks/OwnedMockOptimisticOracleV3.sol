// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {MockOptimisticOracleV3} from "./MockOptimisticOracleV3.sol";

/// @title OwnedMockOptimisticOracleV3
/// @notice MockOptimisticOracleV3 with its override helpers restricted to an owner, for a public
///         chain where the mock stands in for UMA.
/// @dev The base mock leaves its helpers open to any caller, which only a local chain can afford.
///      On a public one, `mockForceSettle` would let anyone settle any listing, termination or
///      identifier-upgrade assertion at once with the result of their choosing, `mockDvmResolve`
///      would let anyone decide every dispute, `setIdentifierSupported` would let anyone
///      de-whitelist the protocol's identifier and so close listing and termination proposals, and
///      `setMinimumBond` would let anyone raise UMA's minimum above Bazaar's bond floors and price
///      every listing, termination and identifier-upgrade proposal at a figure of their choosing.
///      Here only the owner can call them: it stands in for UMA's DVM and governance, and keeps
///      force-settling, which OOv3 has no counterpart for, as an operator's shortcut. Asserting,
///      disputing and settling after liveness stay open to everyone, as on OOv3.
///
///      Two-step ownership, so handing the role to another key cannot strand it at a mistyped
///      address: the factory holds the oracle as an immutable, and an ownerless mock leaves every
///      disputed assertion unresolvable for the life of the deployment.
contract OwnedMockOptimisticOracleV3 is MockOptimisticOracleV3, Ownable2Step {
    constructor(address _currency, uint64 _defaultLiveness, address initialOwner)
        MockOptimisticOracleV3(_currency, _defaultLiveness)
        Ownable(initialOwner)
    {}

    function setIdentifierSupported(bytes32 identifier, bool supported) public override onlyOwner {
        super.setIdentifierSupported(identifier, supported);
    }

    function setMinimumBond(uint256 amount) public override onlyOwner {
        super.setMinimumBond(amount);
    }

    function mockDvmResolve(bytes32 assertionId, bool result) public override onlyOwner {
        super.mockDvmResolve(assertionId, result);
    }

    function mockForceSettle(bytes32 assertionId, bool result) public override onlyOwner {
        super.mockForceSettle(assertionId, result);
    }
}
