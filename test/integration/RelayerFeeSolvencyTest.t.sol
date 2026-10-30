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

    // ------------------------------------------------------------------------------------------
    // The fee is charged at its USDC floor
    // ------------------------------------------------------------------------------------------

    /// @dev Mirrors createOrder's struct-hash construction field for field.
    function _createOrderStructHash(BazaarTypes.OrderSpec memory spec, uint256 nonce, uint256 deadline, uint256 fee)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
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
    }

    /// @dev A bid for `u` relayed with `signedFee`; the book is empty, so it rests and nothing
    ///      but the fee moves.
    function _relayRestingBid(address u, uint256 pk, uint256 signedFee) internal {
        BazaarTypes.OrderSpec memory spec;
        spec.orderType = BazaarTypes.OrderType.Limit;
        spec.isLong = true;
        spec.size = BAZAAR_SCALE / 100;
        spec.limitPrice = 50_000 * BAZAAR_SCALE;
        spec.expirationBlock = uint64(block.number + 500_000);
        uint256 nonce = pair.metaTxNonces(u);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        bytes memory sig = _sign(pk, _createOrderStructHash(spec, nonce, deadline, signedFee));
        bytes[] memory pu = _freshPrice();
        vm.prank(relayer);
        pair.createOrder(spec, _hintsNone(), pu, nonce, deadline, signedFee, sig, "");
    }

    /// @dev The books less the cash, in BAZAAR precision. Escrow credited beyond the USDC that
    ///      was actually pulled shows up here as a rise.
    function _unbacked() internal view returns (int256) {
        return int256(_ledgerBaz()) - int256(_cashBaz());
    }

    /// @notice The fee is pulled as USDC, which has no sub-unit, so the signed fee is charged and
    ///         credited at its USDC floor: the remainder below one unit is neither pulled nor owed.
    function test_relayedCreateOrder_feeIsChargedAtItsUsdcFloor() public {
        (address u, uint256 pk) = makeAddrAndKey("relayerFeeFloor");
        usdc.mint(u, 100_000 * USDC_SCALE);
        _deposit(u, 1_000 * BAZAAR_SCALE);
        _allowFees(u);
        int256 unbackedBefore = _unbacked();
        uint256 userBefore = usdc.balanceOf(u);

        // $0.50 plus the largest remainder below one USDC unit.
        _relayRestingBid(u, pk, BAZAAR_SCALE / 2 + 1e12 - 1);

        assertEq(_escrowOwed(relayer), BAZAAR_SCALE / 2, "the relayer is owed the fee's USDC floor");
        assertEq(userBefore - usdc.balanceOf(u), USDC_SCALE / 2, "the signer paid exactly that");
        assertEq(_unbacked(), unbackedBefore, "no escrow is owed cash the contract never received");
        assertEq(_claimFees(relayer), USDC_SCALE / 2, "the claim pays the floor in full");
    }

    /// @notice A signed fee below one USDC unit floors to zero: the call is relayed and the nonce
    ///         is spent, but nothing is pulled and nothing is owed.
    function test_relayedCreateOrder_feeBelowOneUsdcUnit_chargesNothing() public {
        (address u, uint256 pk) = makeAddrAndKey("relayerFeeDust");
        usdc.mint(u, 100_000 * USDC_SCALE);
        _deposit(u, 1_000 * BAZAAR_SCALE);
        _allowFees(u);
        int256 unbackedBefore = _unbacked();
        uint256 userBefore = usdc.balanceOf(u);
        uint256 nonceBefore = pair.metaTxNonces(u);

        _relayRestingBid(u, pk, 1e12 - 1);

        assertEq(pair.metaTxNonces(u), nonceBefore + 1, "relayed: the nonce is spent");
        assertEq(_escrowOwed(relayer), 0, "nothing is owed");
        assertEq(usdc.balanceOf(u), userBefore, "nothing was pulled");
        assertEq(_unbacked(), unbackedBefore, "the books did not move against the cash");
    }

    /// @notice The payout path nets the fee the same way: a relayed withdrawal pays the signer the
    ///         amount less the fee's USDC floor and credits the relayer exactly that floor.
    function test_relayedWithdrawCollateral_feeIsNettedAtItsUsdcFloor() public {
        (address u, uint256 pk) = makeAddrAndKey("relayerFeeNetted");
        usdc.mint(u, 100_000 * USDC_SCALE);
        _deposit(u, 1_000 * BAZAAR_SCALE);
        int256 unbackedBefore = _unbacked();
        uint256 userBefore = usdc.balanceOf(u);

        uint256 amount = 100 * BAZAAR_SCALE;
        uint256 signedFee = BAZAAR_SCALE / 2 + 1e12 - 1;
        uint256 nonce = pair.metaTxNonces(u);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        bytes memory sig = _sign(
            pk, keccak256(abi.encode(MetaTxLib.WITHDRAW_COLLATERAL_TYPEHASH, amount, nonce, deadline, signedFee))
        );
        vm.prank(relayer);
        pair.withdrawCollateral(amount, new bytes[](0), nonce, deadline, signedFee, sig);

        assertEq(
            usdc.balanceOf(u) - userBefore, 100 * USDC_SCALE - USDC_SCALE / 2, "paid the amount less the fee's floor"
        );
        assertEq(_escrowOwed(relayer), BAZAAR_SCALE / 2, "the relayer is owed the floor");
        assertEq(_unbacked(), unbackedBefore, "the books and the cash moved by the same amount");
    }
}
