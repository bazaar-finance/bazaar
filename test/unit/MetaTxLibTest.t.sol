// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Exposes the internal MetaTxLib functions so the domain separator and the
///         signature/replay logic can be tested in isolation.
contract MetaTxHarness {
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

contract MetaTxLibTest is Test {
    MetaTxHarness internal h;
    address internal signer;
    uint256 internal pk;
    uint256 constant CHAIN_A = 42161; // signing chain (literal — avoids block.chainid re-read)

    function setUp() public {
        h = new MetaTxHarness();
        (signer, pk) = makeAddrAndKey("signer");
        vm.warp(1_000_000);
        vm.chainId(CHAIN_A);
    }

    function _structHash(uint256 nonce, uint256 deadline, uint256 fee) internal pure returns (bytes32) {
        return keccak256(abi.encode(MetaTxLib.DEPOSIT_COLLATERAL_TYPEHASH, uint256(100e18), nonce, deadline, fee));
    }

    function _sign(bytes32 ds, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(ds, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ---------------- _computeDomainSeparator ----------------

    function test_domainSeparator_matchesEip712Construction() public view {
        address vc = address(0xBEEF);
        bytes32 expected = keccak256(
            abi.encode(MetaTxLib.EIP712_DOMAIN_TYPEHASH, MetaTxLib.NAME_HASH, MetaTxLib.VERSION_HASH, block.chainid, vc)
        );
        assertEq(h.domainSeparator(vc), expected);
    }

    function test_domainSeparator_bindsToVerifyingContract() public view {
        assertTrue(h.domainSeparator(address(0xA)) != h.domainSeparator(address(0xB)), "contract-bound");
    }

    function test_domainSeparator_bindsToChainId() public {
        bytes32 onArb = h.domainSeparator(address(h));
        vm.chainId(1); // mainnet
        bytes32 onMainnet = h.domainSeparator(address(h));
        assertTrue(onArb != onMainnet, "chain-bound");
    }

    // ---------------- verifyAndConsume happy path + nonce ----------------

    function test_verifyAndConsume_recoversSignerAndConsumesNonce() public {
        uint256 deadline = block.timestamp + 10;
        bytes32 sh = _structHash(0, deadline, 0);
        bytes32 ds = h.domainSeparator(address(h));
        bytes memory sig = _sign(ds, sh);

        address recovered = h.verify(ds, block.chainid, address(h), sh, sig, 0, deadline, 0);
        assertEq(recovered, signer, "recovers the real signer");
        assertEq(h.nonces(signer), 1, "nonce consumed");
    }

    function test_verifyAndConsume_wrongNonceReverts() public {
        uint256 deadline = block.timestamp + 10;
        bytes32 sh = _structHash(5, deadline, 0); // user signed nonce 5, but their stored nonce is 0
        bytes32 ds = h.domainSeparator(address(h));
        bytes memory sig = _sign(ds, sh);

        vm.expectRevert(abi.encodeWithSelector(MetaTxLib.MetaTx__InvalidNonce.selector, uint256(0), uint256(5)));
        h.verify(ds, block.chainid, address(h), sh, sig, 5, deadline, 0);
    }

    // ---------------- fork / cross-chain replay resistance ----------------

    function test_forkReplay_doesNotRecoverOriginalSigner() public {
        uint256 deadline = block.timestamp + 10;
        bytes32 sh = _structHash(0, deadline, 0);
        bytes32 dsA = h.domainSeparator(address(h)); // computed at CHAIN_A (setUp)
        bytes memory sig = _sign(dsA, sh);

        // Fork: chain id changes; cachedChainId stays CHAIN_A (the signing chain), so
        // verifyAndConsume recomputes the separator for the new chain. The same signature then
        // recovers a DIFFERENT address — the original signer is never impersonated on the fork.
        vm.chainId(999_999);
        address recovered = h.verify(dsA, CHAIN_A, address(h), sh, sig, 0, deadline, 0);
        assertTrue(recovered != signer, "fork replay cannot recover the original signer");
        assertEq(h.nonces(signer), 0, "original signer's nonce untouched on the fork");
    }

    // ---------------- domain-separator error guards (in isolation) ----------------

    function test_expiredDeadlineReverts() public {
        uint256 deadline = block.timestamp - 1;
        bytes32 sh = _structHash(0, deadline, 0);
        bytes32 ds = h.domainSeparator(address(h));
        bytes memory sig = _sign(ds, sh);
        vm.expectRevert(abi.encodeWithSelector(MetaTxLib.MetaTx__ExpiredDeadline.selector, deadline, block.timestamp));
        h.verify(ds, block.chainid, address(h), sh, sig, 0, deadline, 0);
    }

    function test_deadlineTooFarReverts() public {
        uint256 deadline = block.timestamp + MetaTxLib.MAX_DEADLINE_WINDOW + 1;
        bytes32 sh = _structHash(0, deadline, 0);
        bytes32 ds = h.domainSeparator(address(h));
        bytes memory sig = _sign(ds, sh);
        vm.expectRevert(
            abi.encodeWithSelector(
                MetaTxLib.MetaTx__DeadlineTooFar.selector, deadline, block.timestamp + MetaTxLib.MAX_DEADLINE_WINDOW
            )
        );
        h.verify(ds, block.chainid, address(h), sh, sig, 0, deadline, 0);
    }

    function test_relayerFeeExceedsMaxReverts() public {
        uint256 deadline = block.timestamp + 10;
        uint256 fee = MetaTxLib.MAX_RELAYER_FEE + 1;
        bytes32 sh = _structHash(0, deadline, fee);
        bytes32 ds = h.domainSeparator(address(h));
        bytes memory sig = _sign(ds, sh);
        vm.expectRevert(
            abi.encodeWithSelector(MetaTxLib.MetaTx__RelayerFeeExceedsMax.selector, fee, MetaTxLib.MAX_RELAYER_FEE)
        );
        h.verify(ds, block.chainid, address(h), sh, sig, 0, deadline, fee);
    }
}
