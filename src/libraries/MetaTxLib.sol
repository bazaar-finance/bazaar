// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title MetaTxLib
/// @notice Internal library for EIP-712 meta-transaction verification.
///         Inlined at compile time — no separate deployment needed.
library MetaTxLib {
    // -------------------- Constants --------------------

    /// @notice Maximum relayer fee: 1 USDC in BAZAAR_SCALE (1e18)
    uint256 internal constant MAX_RELAYER_FEE = 1e18;

    /// @notice EIP-712 domain type hash
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal constant NAME_HASH = keccak256("BazaarPair");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    // ---- Type hashes: functions WITH relayer fee ----

    bytes32 internal constant DEPOSIT_COLLATERAL_TYPEHASH =
        keccak256("DepositCollateral(uint256 amount,uint256 nonce,uint256 deadline,uint256 relayerFee)");

    bytes32 internal constant WITHDRAW_COLLATERAL_TYPEHASH =
        keccak256("WithdrawCollateral(uint256 amount,uint256 nonce,uint256 deadline,uint256 relayerFee)");

    bytes32 internal constant DEPOSIT_TO_INSURANCE_TYPEHASH =
        keccak256("DepositToInsurance(uint256 amount,uint256 nonce,uint256 deadline,uint256 relayerFee)");

    bytes32 internal constant EXECUTE_INSURANCE_WITHDRAWAL_TYPEHASH =
        keccak256("ExecuteInsuranceWithdrawal(uint256 nonce,uint256 deadline,uint256 relayerFee)");

    // ---- Type hashes: functions with relayer fee pulled from user's wallet ----

    bytes32 internal constant CREATE_ORDER_TYPEHASH = keccak256(
        "CreateOrder(uint8 orderType,uint256 triggerPrice,uint256 limitPrice,uint256 maxSlippageBp,uint256 size,bool isLong,bool isPostOnly,uint256 expirationBlock,address integrator,uint256 nonce,uint256 deadline,uint256 relayerFee)"
    );

    bytes32 internal constant CANCEL_ORDERS_TYPEHASH =
        keccak256("CancelOrders(uint256[] orderIds,uint256 nonce,uint256 deadline,uint256 relayerFee)");

    bytes32 internal constant REQUEST_INSURANCE_WITHDRAWAL_TYPEHASH =
        keccak256("RequestInsuranceWithdrawal(uint256 shareAmount,uint256 nonce,uint256 deadline,uint256 relayerFee)");

    // -------------------- Errors --------------------

    error MetaTx__InvalidSignature();
    error MetaTx__ExpiredDeadline(uint256 deadline, uint256 currentTime);
    error MetaTx__InvalidNonce(uint256 expected, uint256 provided);
    error MetaTx__RelayerFeeExceedsMax(uint256 fee, uint256 max);
    error MetaTx__DeadlineTooFar(uint256 deadline, uint256 maxDeadline);

    uint256 internal constant MAX_DEADLINE_WINDOW = 30 seconds;

    // -------------------- Functions --------------------

    /// @notice Verify an EIP-712 signature, consume the nonce, and return the signer.
    /// @param domainSeparator Cached domain separator from initialize()
    /// @param cachedChainId Chain ID at initialization time (for fork detection)
    /// @param verifyingContract Address of the contract (for domain separator recomputation)
    /// @param structHash The EIP-712 struct hash of the function-specific typed data
    /// @param signature The user's EIP-712 signature
    /// @param nonce The nonce the user signed over
    /// @param deadline The expiry timestamp the user signed over
    /// @param relayerFee The relayer fee the user signed over (0 for fee-free functions)
    /// @param nonces The nonce mapping storage reference
    /// @return signer The recovered signer address
    function verifyAndConsume(
        bytes32 domainSeparator,
        uint256 cachedChainId,
        address verifyingContract,
        bytes32 structHash,
        bytes calldata signature,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        mapping(address => uint256) storage nonces
    ) internal returns (address signer) {
        if (block.timestamp > deadline) {
            revert MetaTx__ExpiredDeadline(deadline, block.timestamp);
        }
        if (deadline > block.timestamp + MAX_DEADLINE_WINDOW) {
            revert MetaTx__DeadlineTooFar(deadline, block.timestamp + MAX_DEADLINE_WINDOW);
        }
        if (relayerFee > MAX_RELAYER_FEE) {
            revert MetaTx__RelayerFeeExceedsMax(relayerFee, MAX_RELAYER_FEE);
        }

        // Recompute domain separator if chain ID changed (fork protection)
        bytes32 ds = block.chainid == cachedChainId ? domainSeparator : _computeDomainSeparator(verifyingContract);

        bytes32 digest = MessageHashUtils.toTypedDataHash(ds, structHash);
        signer = ECDSA.recover(digest, signature);

        if (signer == address(0)) {
            revert MetaTx__InvalidSignature();
        }
        if (nonces[signer] != nonce) {
            revert MetaTx__InvalidNonce(nonces[signer], nonce);
        }

        nonces[signer] = nonce + 1;
    }

    /// @notice Compute the EIP-712 domain separator for a given contract address.
    function _computeDomainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, verifyingContract));
    }
}
