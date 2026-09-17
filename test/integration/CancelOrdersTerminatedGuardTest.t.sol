// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";

/// @notice The terminated-pair arm of the relayer-fee tests.
///
///         `_requireNoSweepWindow` deliberately LIFTS once the pair terminates, and
///         `_terminatePair` force-clears `isAdlPending` — it must, or terminal settlement
///         withdrawals would brick. So on a terminated pair no lifecycle gate stands between a
///         relayed cancel and the bucket; what keeps the terminal haircut intact is that the fee
///         never comes from the bucket at all. A user entitled to 50 cents on the dollar cannot
///         self-relay cancelOrders and take 100: the dollar the relayer is owed is the user's
///         own wallet USDC, and the principal stays inside the settlement untouched.
///
///         Termination is reached through the real two-stage path (fix price → wait out the
///         48h window → finalize) rather than by poking storage: the terminated flags are
///         packed, and a stdstore write silently fails on them.
contract CancelOrdersTerminatedGuardTest is IntegrationBase {
    struct CancelReq {
        uint256 nonce;
        uint256 deadline;
        uint256 fee;
        bytes sig;
    }

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildRelayedCancel(address user, uint256 pk, uint256[] memory ids) internal returns (CancelReq memory r) {
        r.nonce = pair.metaTxNonces(user);
        r.deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        r.fee = MetaTxLib.MAX_RELAYER_FEE;
        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.CANCEL_ORDERS_TYPEHASH, keccak256(abi.encodePacked(ids)), r.nonce, r.deadline, r.fee)
        );
        r.sig = _sign(pk, structHash);
    }

    /// @dev Real termination: stage 1 fixes the settlement price and opens the settlement
    ///      window; with no position open, stage 2 is permissionless at once.
    function _terminateForReal() internal {
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminated(), "pair terminated");
        assertFalse(pair.isAdlPending(), "termination clears the ADL flag");
    }

    /// @notice A relayed cancel on a terminated pair cancels the order and accrues the relayer's
    ///         fee from the signer's wallet — claimable even though the pair is terminated; the
    ///         bucket and D stay inside the terminal settlement.
    function test_relayedCancel_allowedAfterTermination_principalStaysInSettlement() public {
        (address user, uint256 pk) = makeAddrAndKey("terminatedGuard");
        address relayerEoa = makeAddr("terminatedSecondEOA");
        usdc.mint(user, 200_000 * USDC_SCALE);

        _deposit(user, 10_000 * BAZAAR_SCALE);
        // _deposit approves exactly the deposit; the relayed fee needs its own allowance.
        vm.prank(user);
        usdc.approve(address(pair), type(uint256).max);
        // Placed before termination — createOrder is itself halted once terminated.
        uint256 orderId = _placeLimit(user, true, BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE);

        _terminateForReal();

        uint256 collBefore = _posCollateral(user);
        uint256 dBefore = _totalDeposited();
        uint256 walletBefore = usdc.balanceOf(user);
        uint256[] memory ids = _one(orderId);
        CancelReq memory r = _buildRelayedCancel(user, pk, ids);

        vm.prank(relayerEoa);
        pair.cancelOrders(ids, r.nonce, r.deadline, r.fee, r.sig, "");

        uint256 feeUsdc = MetaTxLib.MAX_RELAYER_FEE / 1e12;
        assertGt(_canceledBlock(orderId), 0, "relayed cancel works when terminated");
        assertEq(_posCollateral(user), collBefore, "principal stays inside the terminal settlement");
        assertEq(_totalDeposited(), dBefore, "D untouched");
        assertEq(_escrowOwed(relayerEoa), MetaTxLib.MAX_RELAYER_FEE, "fee accrued to the relayer");
        assertEq(walletBefore - usdc.balanceOf(user), feeUsdc, "...from the signer's wallet");
        assertEq(_claimFees(relayerEoa), feeUsdc, "claimable on a terminated pair");
    }

    /// @notice A terminated pair must still let users cancel under their own gas: no signature,
    ///         no fee, no wallet pull.
    function test_selfSubmittedCancel_allowedAfterTermination() public {
        (address user,) = makeAddrAndKey("terminatedSelf");
        usdc.mint(user, 200_000 * USDC_SCALE);

        _deposit(user, 10_000 * BAZAAR_SCALE);
        uint256 orderId = _placeLimit(user, true, BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE);

        _terminateForReal();

        uint256 collBefore = _posCollateral(user);

        vm.prank(user);
        pair.cancelOrders(_one(orderId), 0, 0, 0, "", "");

        assertGt(_canceledBlock(orderId), 0, "self-submitted cancel still works when terminated");
        assertEq(_posCollateral(user), collBefore, "and moves no collateral");
    }
}
