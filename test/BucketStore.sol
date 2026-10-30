// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";

interface IBucketRead {
    function positionBuckets(address user)
        external
        view
        returns (bool, uint128, uint128, uint128, int256, uint64, uint64);
}

/// @title BucketStore
/// @notice Seeds fields of a `positionBuckets[user]` entry directly in storage, for tests that
///         need a position the normal trading path cannot produce (already-insolvent accounts,
///         pre-existing exposure without a counterparty).
/// @dev BazaarTypes.PositionBucket packs several fields per slot, and stdstore writes whole
///      slots — so `depth(n).checked_write(x)` clobbers every field sharing the slot with `x`.
///      These setters read-modify-write the one field they name, which is what the per-field
///      stdstore calls they replace were assumed to do.
///
///      Layout mirrored here (keep in sync with BazaarTypes.PositionBucket):
///        base+0: isLong (bit 0) | size (bits 8..135)
///        base+1: entryValue (bits 0..127) | collateral (bits 128..255)
///        base+2: entryFundingIndex (full slot)
///        base+3: takeProfitOrderId | stopLossOrderId
library BucketStore {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Locate `positionBuckets[user]` by probing: write a sentinel into each candidate
    ///      mapping's entryFundingIndex slot (the one full-width field, so it round-trips
    ///      through the getter unmasked) and keep the base whose getter reports it back.
    ///      Probed rather than hardcoded so reordering the pair's state variables surfaces as a
    ///      clear failure here instead of as writes landing on an unrelated mapping.
    function baseOf(address pair, address user) internal returns (bytes32) {
        int256 sentinel = 0x5EED;
        for (uint256 i; i < 32; ++i) {
            bytes32 base = keccak256(abi.encode(user, i));
            bytes32 slot = bytes32(uint256(base) + 2);
            bytes32 prev = vm.load(pair, slot);
            vm.store(pair, slot, bytes32(uint256(sentinel)));
            (,,,, int256 got,,) = IBucketRead(pair).positionBuckets(user);
            vm.store(pair, slot, prev);
            if (got == sentinel) return base;
        }
        revert("BucketStore: positionBuckets slot not found");
    }

    function setIsLong(address pair, address user, bool v) internal {
        bytes32 base = baseOf(pair, user);
        uint256 w = uint256(vm.load(pair, base));
        w = (w & ~uint256(0xff)) | (v ? 1 : 0);
        vm.store(pair, base, bytes32(w));
    }

    function setSize(address pair, address user, uint256 v) internal {
        require(v <= type(uint128).max, "BucketStore: size overflows uint128");
        bytes32 base = baseOf(pair, user);
        uint256 w = uint256(vm.load(pair, base));
        w = (w & ~(uint256(type(uint128).max) << 8)) | (v << 8);
        vm.store(pair, base, bytes32(w));
    }

    function setEntryValue(address pair, address user, uint256 v) internal {
        require(v <= type(uint128).max, "BucketStore: entryValue overflows uint128");
        bytes32 slot = bytes32(uint256(baseOf(pair, user)) + 1);
        uint256 w = uint256(vm.load(pair, slot));
        w = (w & ~uint256(type(uint128).max)) | v;
        vm.store(pair, slot, bytes32(w));
    }

    function setCollateral(address pair, address user, uint256 v) internal {
        require(v <= type(uint128).max, "BucketStore: collateral overflows uint128");
        bytes32 slot = bytes32(uint256(baseOf(pair, user)) + 1);
        uint256 w = uint256(vm.load(pair, slot));
        w = (w & uint256(type(uint128).max)) | (v << 128);
        vm.store(pair, slot, bytes32(w));
    }
}
