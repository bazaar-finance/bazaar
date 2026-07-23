// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";

/// @title RelayerFeeSolvencyTest
/// @notice Regression tests for the meta-tx relayer fee in createOrder / cancelOrders. The solvency
///         invariant (isVaultHealthy Check-3) is that insuranceFundBalance (I) + totalCollateralDeposited
///         (D), in USDC, tracks the contract's real USDC balance. The relayer fee sends real USDC out
///         of the contract, so it must decrement D as well as the bucket — otherwise I + D drifts above
///         the actual balance on every relayed order/cancel, which can force a spurious reason-3
///         emergency termination and charge a phantom shortfall at settlement.
contract RelayerFeeSolvencyTest is IntegrationBase {
    address internal relayer = makeAddr("relayer");

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Contract USDC balance in native (1e6) precision. (_ledgerBaz / _totalDeposited come from
    ///      IntegrationBase and work in BAZAAR 1e18 precision.)
    function _pairUsdc() internal view returns (uint256) {
        return usdc.balanceOf(address(pair));
    }

    /// @notice A relayed createOrder must debit the fee from BOTH the bucket and D, keeping I + D
    ///         equal to the contract's real USDC balance.
    function test_relayedCreateOrder_preservesSolvencyLedger() public {
        (address u, uint256 pk) = makeAddrAndKey("relayerFeeUserCreate");
        usdc.mint(u, 100_000 * USDC_SCALE);
        _deposit(u, 1_000 * BAZAAR_SCALE);

        // Invariant holds before the relayed order.
        assertEq(_ledgerBaz() / 1e12, _pairUsdc(), "baseline: I + D == contract USDC");

        uint256 fee = BAZAAR_SCALE / 2; // $0.50, under the $1 relayer-fee cap
        uint256 size = BAZAAR_SCALE / 100; // 0.01 BTC
        uint256 limitPrice = 50_000 * BAZAAR_SCALE;
        uint64 exp = uint64(block.number + 500_000);
        uint256 nonce = pair.metaTxNonces(u);
        uint256 deadline = vm.getBlockTimestamp() + 30;

        bytes32 structHash = keccak256(
            abi.encode(
                MetaTxLib.CREATE_ORDER_TYPEHASH,
                BazaarTypes.OrderType.Limit,
                uint256(0),
                limitPrice,
                uint256(0),
                size,
                true,
                false,
                exp,
                address(0),
                nonce,
                deadline,
                fee
            )
        );
        bytes memory sig = _sign(pk, structHash);

        uint256 dBefore = _totalDeposited();
        uint256 ledgerBefore = _ledgerBaz();
        uint256 usdcBefore = _pairUsdc();

        bytes[] memory pu = _freshPrice(); // build BEFORE the prank (mockPyth call would consume it)
        vm.prank(relayer);
        pair.createOrder(
            BazaarTypes.OrderType.Limit,
            0,
            limitPrice,
            0,
            size,
            true,
            false,
            exp,
            address(0),
            pu,
            nonce,
            deadline,
            fee,
            sig
        );

        // The fee left the contract as real USDC.
        assertEq(usdcBefore - _pairUsdc(), fee / 1e12, "fee left the contract as USDC");
        assertEq(usdc.balanceOf(relayer), fee / 1e12, "relayer received the fee");
        // D dropped by exactly the fee (the bug left D unchanged).
        assertEq(dBefore - _totalDeposited(), fee, "D decremented by the fee");
        // The ledger delta matches the USDC delta, so the invariant is preserved.
        assertEq((ledgerBefore - _ledgerBaz()) / 1e12, usdcBefore - _pairUsdc(), "ledger delta == USDC delta");
        assertEq(_ledgerBaz() / 1e12, _pairUsdc(), "after: I + D == contract USDC");
    }

    /// @notice A relayed cancelOrders must debit the fee from BOTH the bucket and D.
    function test_relayedCancelOrders_preservesSolvencyLedger() public {
        (address u, uint256 pk) = makeAddrAndKey("relayerFeeUserCancel");
        usdc.mint(u, 100_000 * USDC_SCALE);
        _deposit(u, 1_000 * BAZAAR_SCALE);

        // A resting order to cancel (placed directly by the user — no relayer fee on placement).
        uint256 orderId = _placeLimit(u, true, BAZAAR_SCALE / 100, 49_000 * BAZAAR_SCALE);

        assertEq(_ledgerBaz() / 1e12, _pairUsdc(), "baseline: I + D == contract USDC");

        uint256[] memory ids = _one(orderId);
        uint256 fee = BAZAAR_SCALE / 2;
        uint256 nonce = pair.metaTxNonces(u);
        uint256 deadline = vm.getBlockTimestamp() + 30;

        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.CANCEL_ORDERS_TYPEHASH, keccak256(abi.encodePacked(ids)), nonce, deadline, fee)
        );
        bytes memory sig = _sign(pk, structHash);

        uint256 dBefore = _totalDeposited();
        uint256 ledgerBefore = _ledgerBaz();
        uint256 usdcBefore = _pairUsdc();

        vm.prank(relayer);
        pair.cancelOrders(ids, nonce, deadline, fee, sig);

        assertEq(usdcBefore - _pairUsdc(), fee / 1e12, "fee left the contract as USDC");
        assertEq(usdc.balanceOf(relayer), fee / 1e12, "relayer received the fee");
        assertEq(dBefore - _totalDeposited(), fee, "D decremented by the fee");
        assertEq((ledgerBefore - _ledgerBaz()) / 1e12, usdcBefore - _pairUsdc(), "ledger delta == USDC delta");
        assertEq(_ledgerBaz() / 1e12, _pairUsdc(), "after: I + D == contract USDC");
    }
}
