// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";

/// @notice The cancelOrders relayer fee IS a collateral withdrawal and needs every guard a
///         withdrawal needs. `_chargeRelayerFee` debits bucket.collateral and D; without a
///         termination / ADL / sweep-window / margin gate — and with an EMPTY orderIds array
///         reducing the loop to a no-op — self-relaying
///         `cancelOrders([], nonce, deadline, relayerFee, sig)` would be a standalone
///         collateral-extraction primitive: repeatable with fresh nonces until the bucket hit
///         zero, stripping every dollar of margin from an open position with no health check.
///         Each case below asserts the extraction is refused AND that collateral is untouched.
///
///         The paired "self-submitted still works" cases matter as much as the blocks. The guard
///         lives in `_chargeRelayerFee`, reached only when effRelayerFee > 0. If it were ever
///         "simplified" up to the top of cancelOrders, every block test here would still pass
///         while users got frozen out of de-risking during exactly the crises the freeze exists
///         for — these cases are what fail loudly on that.
contract CancelOrdersRelayerFeeGuardsTest is IntegrationBase {
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

    /// @dev Build the signed request WITHOUT submitting it. Split from submission because the
    ///      build reads metaTxNonces and DOMAIN_SEPARATOR — external calls that would swallow a
    ///      preceding vm.expectRevert. Every caller must expectRevert immediately before the
    ///      cancelOrders call itself, never before this.
    function _buildRelayedCancel(address user, uint256 pk, uint256[] memory ids) internal returns (CancelReq memory r) {
        r.nonce = pair.metaTxNonces(user);
        r.deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        r.fee = MetaTxLib.MAX_RELAYER_FEE;
        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.CANCEL_ORDERS_TYPEHASH, keccak256(abi.encodePacked(ids)), r.nonce, r.deadline, r.fee)
        );
        r.sig = _sign(pk, structHash);
    }

    /// @dev A second address controlled by the same actor — what makes the relayer fee a
    ///      self-payment rather than payment for a genuine relaying service.
    function _actor(string memory label) internal returns (address user, uint256 pk, address relayerEoa) {
        (user, pk) = makeAddrAndKey(label);
        relayerEoa = makeAddr(string.concat(label, "SecondEOA"));
        usdc.mint(user, 200_000 * USDC_SCALE);
    }

    /// @dev Drive the pair into a REAL ADL window (isAdlPending is packed with the pair's other
    ///      lifecycle flags, so there is no stdstore shortcut): liquidate a deep-underwater
    ///      phantom long whose vault-inherited loss (~$4,950 at the $50k mark) exceeds the ADL
    ///      trigger share of the ~$5k genesis insurance fund. Any order a test needs must
    ///      already exist — order creation is frozen once ADL is pending — and must rest on the
    ///      ASK side: liquidate crosses the inherited long into resting bids before judging
    ///      vault health, so a resting bid would be filled by that unload instead of surviving
    ///      to the cancel under test.
    function _triggerRealAdl() internal {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        _deposit(bob, 60_000 * BAZAAR_SCALE);
        uint256 size = 5 * BAZAAR_SCALE;
        _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE); // crosses alice's resting bid on arrival
        assertEq(_posSize(alice), size, "position opened");

        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, size, 254_960 * BAZAAR_SCALE);
        bytes[] memory liqPu = _freshPrice();
        vm.prank(makeAddr("adlLiquidator"));
        pair.liquidate(_arr1(dave), liqPu);
        assertTrue(pair.isAdlPending(), "ADL window is live");
    }

    // ─────────────────────────── the empty-list primitive ───────────────────────────

    /// @notice An empty id list is rejected outright. Without this the loop
    ///         consumes no order, so the call is pure fee extraction and repeats indefinitely.
    function test_relayedCancel_emptyList_reverts() public {
        (address user, uint256 pk, address relayerEoa) = _actor("emptyList");
        _deposit(user, 10 * BAZAAR_SCALE);

        uint256[] memory ids = _empty();
        CancelReq memory r = _buildRelayedCancel(user, pk, ids);

        vm.prank(relayerEoa);
        vm.expectRevert(BazaarPair.BazaarPair__ExceedsMaxCancelsPerCall.selector);
        pair.cancelOrders(ids, r.nonce, r.deadline, r.fee, r.sig);

        assertEq(_posCollateral(user), 10 * BAZAAR_SCALE, "collateral untouched");
        assertEq(usdc.balanceOf(relayerEoa), 0, "no fee extracted");
    }

    /// @notice An underwater position's backing collateral cannot be withdrawn via
    ///         withdrawCollateral, and must not be extractable via repeated self-relayed empty
    ///         cancels either — unguarded, that loop drains the $10 to zero and leaves the
    ///         position fully unbacked.
    function test_relayedCancel_cannotStripMarginFromUnderwaterPosition() public {
        (address user, uint256 pk, address relayerEoa) = _actor("marginStrip");

        _deposit(user, 10 * BAZAAR_SCALE);
        // 0.1 BTC long entered at $50,050 notional -> underwater at $50k spot
        _writePosition(user, true, BAZAAR_SCALE / 10, 5_005 * BAZAAR_SCALE);

        // The sanctioned exit path refuses even $1 — the margin check holds the collateral.
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        vm.expectRevert();
        pair.withdrawCollateral(1 * BAZAAR_SCALE, pu, 0, 0, 0, "");

        // The unsanctioned path must refuse too, every time.
        uint256[] memory ids = _empty();
        for (uint256 i; i < 10; ++i) {
            CancelReq memory r = _buildRelayedCancel(user, pk, ids);
            vm.prank(relayerEoa);
            vm.expectRevert(BazaarPair.BazaarPair__ExceedsMaxCancelsPerCall.selector);
            pair.cancelOrders(ids, r.nonce, r.deadline, r.fee, r.sig);
        }

        assertEq(_posCollateral(user), 10 * BAZAAR_SCALE, "margin still backing the position");
        assertEq(usdc.balanceOf(relayerEoa), 0, "nothing extracted");
        assertEq(_posSize(user), BAZAAR_SCALE / 10, "position unchanged");
        _assertBooks("after refused drain");
    }

    // ─────────────────────── lifecycle guard, with a REAL order ───────────────────────
    // The empty-list check fires first, so these are the only coverage of the guard inside
    // _chargeRelayerFee. They pass a genuine cancelable id to reach it.

    /// @notice _requireNoSweepWindow: all collateral movement freezes once the settlement price
    ///         is fixed, so the rung-4 principal-haircut denominator (cash/D) stays stable. A
    ///         relayer fee moves both, so it must freeze with everything else.
    function test_relayedCancel_blockedDuringSweepWindow() public {
        (address user, uint256 pk, address relayerEoa) = _actor("sweepGuard");
        _deposit(user, 10_000 * BAZAAR_SCALE);
        uint256 orderId = _placeLimit(user, true, BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE);

        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        assertGt(pair.settlementPriceFixedTs(), 0, "sweep window open");

        uint256 collBefore = _posCollateral(user);
        uint256[] memory ids = _one(orderId);
        CancelReq memory r = _buildRelayedCancel(user, pk, ids);

        vm.prank(relayerEoa);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.cancelOrders(ids, r.nonce, r.deadline, r.fee, r.sig);

        assertEq(_posCollateral(user), collBefore, "collateral frozen through the sweep window");
        assertEq(usdc.balanceOf(relayerEoa), 0, "no fee extracted");
        assertEq(_canceledBlock(orderId), 0, "order untouched");
    }

    /// @notice ...but the user is never trapped: a self-submitted cancel carries no signature,
    ///         hence no relayer fee, hence no collateral movement, and stays available.
    function test_selfSubmittedCancel_allowedDuringSweepWindow() public {
        (address user,,) = _actor("sweepSelf");
        _deposit(user, 10_000 * BAZAAR_SCALE);
        uint256 orderId = _placeLimit(user, true, BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE);

        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);

        uint256 collBefore = _posCollateral(user);

        vm.prank(user);
        pair.cancelOrders(_one(orderId), 0, 0, 0, "");

        assertGt(_canceledBlock(orderId), 0, "self-submitted cancel still works");
        assertEq(_posCollateral(user), collBefore, "and moves no collateral");
    }

    /// @notice _requireNotHalted / isAdlPending. adlScore is pnl / effectiveCollateral, so shaving
    ///         $1 off collateral RAISES a listed winner's score and breaks executeAdl's
    ///         descending-order check, reverting a whole batch. Position-holders'
    ///         withdrawCollateral is already frozen during ADL, so without this gate the relayer
    ///         fee is the one remaining lever — and $1 is enough to grief indefinitely.
    function test_relayedCancel_blockedDuringAdl() public {
        (address user, uint256 pk, address relayerEoa) = _actor("adlGuard");
        _deposit(user, 20_000 * BAZAAR_SCALE);
        // Placed BEFORE the trigger (order creation is frozen once ADL is pending), on the ask
        // side so the liquidation's inline unload of the inherited long cannot fill it.
        uint256 orderId = _placeLimit(user, false, BAZAAR_SCALE / 10, 55_000 * BAZAAR_SCALE);

        _triggerRealAdl();

        uint256 collBefore = _posCollateral(user);
        uint256[] memory ids = _one(orderId);
        CancelReq memory r = _buildRelayedCancel(user, pk, ids);

        vm.prank(relayerEoa);
        vm.expectRevert(BazaarPair.BazaarPair__TradingHalted.selector);
        pair.cancelOrders(ids, r.nonce, r.deadline, r.fee, r.sig);

        assertEq(_posCollateral(user), collBefore, "adlScore input cannot be moved mid-auction");
        assertEq(usdc.balanceOf(relayerEoa), 0, "no fee extracted");
    }

    /// @notice De-risking during ADL must stay possible under the user's own gas.
    function test_selfSubmittedCancel_allowedDuringAdl() public {
        (address user,,) = _actor("adlSelf");
        _deposit(user, 20_000 * BAZAAR_SCALE);
        // Ask side: survives the liquidation's inline unload of the inherited long.
        uint256 orderId = _placeLimit(user, false, BAZAAR_SCALE / 10, 55_000 * BAZAAR_SCALE);

        _triggerRealAdl();

        uint256 collBefore = _posCollateral(user);

        vm.prank(user);
        pair.cancelOrders(_one(orderId), 0, 0, 0, "");

        assertGt(_canceledBlock(orderId), 0, "self-submitted cancel still works during ADL");
        assertEq(_posCollateral(user), collBefore, "and moves no collateral");
    }
}
