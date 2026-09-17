// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";

/// @title RelayerFeeSolvencyTest
/// @notice The solvency invariant (isVaultHealthy Check-3) is that insuranceFundBalance (I) +
///         totalCollateralDeposited (D) + the fee escrow, in USDC, tracks the contract's real
///         USDC balance. The createOrder / cancelOrders relayer fee is pulled from the signer's
///         wallet into the contract and accrued to the relayer's claimable balance, so it enters
///         the contract only as an escrow liability: D never moves, and it must not touch the
///         signer's bucket either, since a bucket debit with no D decrement would hold the ledger
///         above the USDC actually on hand. Both cases pin the ledger identity through the accrual
///         and the relayer's later claim.
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

    /// @dev The fee is pulled from the signer's wallet; _deposit approves exactly the deposit, so
    ///      the fee needs its own allowance.
    function _allowFees(address user) internal {
        vm.prank(user);
        usdc.approve(address(pair), type(uint256).max);
    }

    /// @notice A relayed createOrder pulls the fee wallet -> escrow: bucket and D stay exactly
    ///         where they were, and the contract's USDC grows by precisely the new escrow
    ///         liability.
    function test_relayedCreateOrder_preservesSolvencyLedger() public {
        (address u, uint256 pk) = makeAddrAndKey("relayerFeeUserCreate");
        usdc.mint(u, 100_000 * USDC_SCALE);
        _deposit(u, 1_000 * BAZAAR_SCALE);
        _allowFees(u);

        // Invariant holds before the relayed order.
        assertEq(_ledgerBaz() / 1e12, _pairUsdc(), "baseline: I + D + escrow == contract USDC");

        uint256 fee = BAZAAR_SCALE / 2; // $0.50, under the $1 relayer-fee cap
        BazaarTypes.OrderSpec memory spec;
        spec.orderType = BazaarTypes.OrderType.Limit;
        spec.isLong = true;
        spec.size = BAZAAR_SCALE / 100; // 0.01 BTC
        spec.limitPrice = 50_000 * BAZAAR_SCALE;
        spec.expirationBlock = uint64(block.number + 500_000);
        uint256 nonce = pair.metaTxNonces(u);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;

        // Mirrors createOrder's struct-hash construction field for field.
        bytes32 structHash = keccak256(
            abi.encode(
                MetaTxLib.CREATE_ORDER_TYPEHASH,
                spec.orderType,
                spec.triggerPrice,
                spec.limitPrice,
                spec.maxSlippageBp,
                spec.size,
                spec.isLong,
                spec.isPostOnly,
                spec.tif,
                spec.expirationBlock,
                spec.integrator,
                nonce,
                deadline,
                fee
            )
        );
        bytes memory sig = _sign(pk, structHash);

        uint256 dBefore = _totalDeposited();
        uint256 usdcBefore = _pairUsdc();
        uint256 userBefore = usdc.balanceOf(u);

        // The book is empty, so this limit rests without filling; the fee is the only USDC the
        // call moves.
        bytes[] memory pu = _freshPrice(); // build BEFORE the prank (mockPyth call would consume it)
        vm.prank(relayer);
        pair.createOrder(spec, _hintsNone(), pu, nonce, deadline, fee, sig, "");

        assertEq(_escrowOwed(relayer), fee, "fee accrued to the relayer");
        assertEq(userBefore - usdc.balanceOf(u), fee / 1e12, "fee came from the signer's wallet");
        assertEq(_pairUsdc() - usdcBefore, fee / 1e12, "contract USDC grew by the escrowed fee");
        assertEq(_totalDeposited(), dBefore, "D untouched");
        assertEq(_posCollateral(u), 1_000 * BAZAAR_SCALE, "bucket untouched");
        assertEq(_ledgerBaz() / 1e12, _pairUsdc(), "after: I + D + escrow == contract USDC");

        assertEq(_claimFees(relayer), fee / 1e12, "relayer claims the fee");
        assertEq(_pairUsdc(), usdcBefore, "claim returns the contract to its pre-fee balance");
        assertEq(_ledgerBaz() / 1e12, _pairUsdc(), "after claim: I + D + escrow == contract USDC");
    }

    /// @notice A relayed cancelOrders accrues the fee the same way, with the same stills.
    function test_relayedCancelOrders_preservesSolvencyLedger() public {
        (address u, uint256 pk) = makeAddrAndKey("relayerFeeUserCancel");
        usdc.mint(u, 100_000 * USDC_SCALE);
        _deposit(u, 1_000 * BAZAAR_SCALE);
        _allowFees(u);

        // A resting order to cancel (placed directly by the user — no relayer fee on placement).
        uint256 orderId = _placeLimit(u, true, BAZAAR_SCALE / 100, 49_000 * BAZAAR_SCALE);

        assertEq(_ledgerBaz() / 1e12, _pairUsdc(), "baseline: I + D + escrow == contract USDC");

        uint256[] memory ids = _one(orderId);
        uint256 fee = BAZAAR_SCALE / 2;
        uint256 nonce = pair.metaTxNonces(u);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;

        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.CANCEL_ORDERS_TYPEHASH, keccak256(abi.encodePacked(ids)), nonce, deadline, fee)
        );
        bytes memory sig = _sign(pk, structHash);

        uint256 dBefore = _totalDeposited();
        uint256 usdcBefore = _pairUsdc();
        uint256 userBefore = usdc.balanceOf(u);

        vm.prank(relayer);
        pair.cancelOrders(ids, nonce, deadline, fee, sig, "");

        assertGt(_canceledBlock(orderId), 0, "order canceled");
        assertEq(_escrowOwed(relayer), fee, "fee accrued to the relayer");
        assertEq(userBefore - usdc.balanceOf(u), fee / 1e12, "fee came from the signer's wallet");
        assertEq(_pairUsdc() - usdcBefore, fee / 1e12, "contract USDC grew by the escrowed fee");
        assertEq(_totalDeposited(), dBefore, "D untouched");
        assertEq(_posCollateral(u), 1_000 * BAZAAR_SCALE, "bucket untouched");
        assertEq(_ledgerBaz() / 1e12, _pairUsdc(), "after: I + D + escrow == contract USDC");

        assertEq(_claimFees(relayer), fee / 1e12, "relayer claims the fee");
        assertEq(_ledgerBaz() / 1e12, _pairUsdc(), "after claim: I + D + escrow == contract USDC");
    }
}
