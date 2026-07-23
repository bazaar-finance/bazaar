// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract MetaTxBoundaryHarness {
    mapping(address => uint256) public nonces;

    function domainSeparator(address vc) external view returns (bytes32) {
        return MetaTxLib._computeDomainSeparator(vc);
    }

    function verify(
        bytes32 ds,
        uint256 cachedChainId,
        address vc,
        bytes32 structHash,
        bytes calldata sig,
        uint256 nonce,
        uint256 deadline,
        uint256 fee
    ) external returns (address) {
        return MetaTxLib.verifyAndConsume(ds, cachedChainId, vc, structHash, sig, nonce, deadline, fee, nonces);
    }
}

/// @notice Boundary and replay cases MetaTxLibTest didn't reach: the deadline window's ACCEPTING
///         edge, cross-contract (pair A -> pair B) signature replay, and s-value malleability.
contract MetaTxBoundaryTest is Test {
    MetaTxBoundaryHarness internal h;
    address internal signer;
    uint256 internal pk;
    uint256 constant CHAIN_A = 42161;
    // secp256k1 order, for constructing the malleable (high-s) counterpart of a canonical signature.
    uint256 constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function setUp() public {
        h = new MetaTxBoundaryHarness();
        (signer, pk) = makeAddrAndKey("signer");
        vm.warp(1_000_000);
        vm.chainId(CHAIN_A);
    }

    function _structHash(uint256 nonce, uint256 deadline, uint256 fee) internal pure returns (bytes32) {
        return keccak256(abi.encode(MetaTxLib.DEPOSIT_COLLATERAL_TYPEHASH, uint256(100e18), nonce, deadline, fee));
    }

    function _sign(bytes32 ds, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils.toTypedDataHash(ds, structHash));
        return abi.encodePacked(r, s, v);
    }

    /// @notice A deadline exactly at now + MAX_DEADLINE_WINDOW is accepted — pins the strict-`>`
    ///         boundary (MetaTxLibTest only covers the +1 rejecting side).
    function test_deadlineExactlyAtWindow_accepted() public {
        uint256 deadline = block.timestamp + MetaTxLib.MAX_DEADLINE_WINDOW; // exactly at the edge
        bytes32 sh = _structHash(0, deadline, 0);
        bytes32 ds = h.domainSeparator(address(h));
        bytes memory sig = _sign(ds, sh);

        address recovered = h.verify(ds, block.chainid, address(h), sh, sig, 0, deadline, 0);
        assertEq(recovered, signer, "deadline at the exact window edge is valid");
        assertEq(h.nonces(signer), 1, "nonce consumed");
    }

    /// @notice A signature made for pair A cannot authorize pair B: pair B verifies against its OWN
    ///         domain separator, so the same signature recovers a different address and pair B never
    ///         consumes the real signer's nonce. (Domain separators bind to the verifying contract.)
    function test_crossContractReplay_doesNotRecoverSigner() public {
        uint256 deadline = block.timestamp + 10;
        bytes32 sh = _structHash(0, deadline, 0);

        // User signs for pair A.
        bytes32 dsA = h.domainSeparator(address(0xA11CE));
        bytes memory sig = _sign(dsA, sh);

        // Relayer replays the same signature at pair B, which verifies with dsB / its own address.
        bytes32 dsB = h.domainSeparator(address(0xB0B));
        address recovered = h.verify(dsB, block.chainid, address(0xB0B), sh, sig, 0, deadline, 0);

        assertTrue(recovered != signer, "pair-A signature cannot authorize pair B");
        assertEq(h.nonces(signer), 0, "real signer's nonce untouched by the cross-contract replay");
    }

    /// @notice The malleable (high-s) counterpart of a valid signature is rejected by OZ ECDSA, so an
    ///         attacker can't mint a second distinct-but-valid signature from one the user produced.
    function test_signatureMalleability_highS_rejected() public {
        uint256 deadline = block.timestamp + 10;
        bytes32 sh = _structHash(0, deadline, 0);
        bytes32 ds = h.domainSeparator(address(h));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils.toTypedDataHash(ds, sh));
        // vm.sign yields a canonical low-s signature; N - s is the high-s twin OZ must reject.
        bytes32 sHigh = bytes32(N - uint256(s));
        uint8 vFlip = v == 27 ? 28 : 27;
        bytes memory malleable = abi.encodePacked(r, sHigh, vFlip);

        vm.expectPartialRevert(ECDSA.ECDSAInvalidSignatureS.selector);
        h.verify(ds, block.chainid, address(h), sh, malleable, 0, deadline, 0);
    }
}
