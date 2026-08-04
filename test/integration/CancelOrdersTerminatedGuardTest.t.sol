// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";

/// @notice The terminated-pair arm of the cancelOrders relayer-fee guard.
///
///         `_requireNoSweepWindow` deliberately LIFTS once the pair terminates
///         (`&& !isPairTerminatedEmergency && !isPairTerminatedNormal`), and `_terminatePair`
///         force-clears `isAdlPending` — it must, or terminal settlement withdrawals would
///         brick. So on a terminated pair neither of those blocks anything on its own, and a
///         relayer-fee debit reading raw `bucket.collateral` would bypass the terminal haircut
///         that the sanctioned exit applies: a user entitled to 50 cents on the dollar could
///         self-relay cancelOrders and take 100.
///
///         The guard therefore has to test the terminated flags EXPLICITLY rather than lean on
///         the sweep-window helper — that is what `_requireNotHalted` is for, and this test is
///         what pins it.
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

    /// @dev Build without submitting — the build makes external calls that would swallow a
    ///      preceding vm.expectRevert. See the sibling suite for the full note.
    function _buildRelayedCancel(address user, uint256 pk, uint256[] memory ids) internal returns (CancelReq memory r) {
        r.nonce = pair.metaTxNonces(user);
        r.deadline = vm.getBlockTimestamp() + 30;
        r.fee = MetaTxLib.MAX_RELAYER_FEE;
        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.CANCEL_ORDERS_TYPEHASH, keccak256(abi.encodePacked(ids)), r.nonce, r.deadline, r.fee)
        );
        r.sig = _sign(pk, structHash);
    }

    /// @dev Real normal termination: stage 1 fixes the settlement price and opens the 48h sweep
    ///      window, stage 2 is permissionless once it elapses.
    function _terminateForReal() internal {
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminatedNormal(), "pair terminated");
        assertFalse(pair.isAdlPending(), "termination clears the ADL flag");
    }

    function test_relayedCancel_blockedAfterTermination() public {
        (address user, uint256 pk) = makeAddrAndKey("terminatedGuard");
        address relayerEoa = makeAddr("terminatedSecondEOA");
        usdc.mint(user, 200_000 * USDC_SCALE);

        _deposit(user, 10_000 * BAZAAR_SCALE);
        // Placed before termination — createOrder is itself halted once terminated.
        uint256 orderId = _placeLimit(user, true, BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE);

        _terminateForReal();

        uint256 collBefore = _posCollateral(user);
        uint256[] memory ids = _one(orderId);
        CancelReq memory r = _buildRelayedCancel(user, pk, ids);

        vm.prank(relayerEoa);
        vm.expectRevert(BazaarPair.BazaarPair__TradingHalted.selector);
        pair.cancelOrders(ids, r.nonce, r.deadline, r.fee, r.sig);

        assertEq(_posCollateral(user), collBefore, "principal stays inside the terminal settlement");
        assertEq(usdc.balanceOf(relayerEoa), 0, "no pre-haircut extraction");
        assertEq(_canceledBlock(orderId), 0, "order untouched");
    }

    /// @notice A terminated pair must still let users cancel under their own gas — the guard is
    ///         scoped to the fee debit, not to cancellation itself.
    function test_selfSubmittedCancel_allowedAfterTermination() public {
        (address user,) = makeAddrAndKey("terminatedSelf");
        usdc.mint(user, 200_000 * USDC_SCALE);

        _deposit(user, 10_000 * BAZAAR_SCALE);
        uint256 orderId = _placeLimit(user, true, BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE);

        _terminateForReal();

        uint256 collBefore = _posCollateral(user);

        vm.prank(user);
        pair.cancelOrders(_one(orderId), 0, 0, 0, "");

        assertGt(_canceledBlock(orderId), 0, "self-submitted cancel still works when terminated");
        assertEq(_posCollateral(user), collBefore, "and moves no collateral");
    }
}
