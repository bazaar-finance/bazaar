// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {OrderView} from "../OrderView.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";

/// @title WrongSideOrderReserveTest
/// @notice Creation, amendment and withdrawal reserve what the fill gate debits ahead of its
///         margin test — the loss a limit on the wrong side of the mark books when it fills, and
///         the maker fee — so an order admitted at the mark fills at full size there, and no taker
///         sized past the maker's collateral can auto-cancel it. On the AAPL book at a $200 mark,
///         with no per-call price update: every call rides the cache.
contract WrongSideOrderReserveTest is IntegrationBase {
    uint256 constant SHARE = 1e18;
    uint256 constant PX = 200;
    uint256 constant UNIT = 1e12; // one USDC unit in BAZAAR precision

    uint256 imrBp;

    function setUp() public override {
        super.setUp();
        _aaplDeposit(alice, 20_000 * BAZAAR_SCALE);
        _aaplDeposit(bob, 20_000 * BAZAAR_SCALE);
        _refreshAt(PX);
        (imrBp,,,) = aaplPair.marginRequirements();
    }

    // -------------------- helpers --------------------

    function _aaplDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function _fund(string memory name) internal returns (address user) {
        user = makeAddr(name);
        usdc.mint(user, INITIAL_USER_BALANCE);
    }

    /// @dev A funded account holding exactly `collateral`. Deposits have a $5 floor, so a
    ///      "one unit short" case and its "exactly enough" twin are two accounts, not a top-up.
    function _fundWith(string memory name, uint256 collateral) internal returns (address user) {
        user = _fund(name);
        _aaplDeposit(user, collateral);
    }

    /// @dev Push a fresh price so every subsequent same-timestamp call rides the oracle cache.
    function _refreshAt(uint256 priceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, priceUsd, uint64(vm.getBlockTimestamp()));
        aaplPair.refreshPrice{value: 0}(pu);
    }

    function _imr(uint256 notional) internal view returns (uint256) {
        return imrBp * notional / 10_000;
    }

    function _fee(uint256 limitNotional) internal pure returns (uint256) {
        return limitNotional * BazaarTypes.MAKER_INSURANCE_FEE_EBP / BazaarTypes.EBP_SCALE;
    }

    function _limitSpecAt(bool isLong, uint256 size, uint256 limitPriceBz)
        internal
        view
        returns (BazaarTypes.OrderSpec memory s)
    {
        s.orderType = BazaarTypes.OrderType.Limit;
        s.isLong = isLong;
        s.size = size;
        s.limitPrice = limitPriceBz;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
    }

    function _stopSpec(bool isLong, uint256 size, uint256 triggerUsd, uint256 limitUsd)
        internal
        view
        returns (BazaarTypes.OrderSpec memory s)
    {
        s.orderType = BazaarTypes.OrderType.StopLimit;
        s.isLong = isLong;
        s.size = size;
        s.triggerPrice = triggerUsd * BAZAAR_SCALE;
        s.limitPrice = limitUsd * BAZAAR_SCALE;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
    }

    /// @dev Place an AAPL limit off the fresh cache.
    function _place(address user, bool isLong, uint256 size, uint256 limitPriceBz) internal returns (uint256) {
        vm.prank(user);
        aaplPair.createOrder(_limitSpecAt(isLong, size, limitPriceBz), _hintsNone(), new bytes[](0), 0, 0, 0, "", "");
        return _lastCreatedOrderId(aaplPair);
    }

    /// @dev The creation gate refuses `spec` for `user`, reporting their collateral and the reserve.
    function _expectRefused(address user, BazaarTypes.OrderSpec memory spec, uint256 have, uint256 need) internal {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderManagementLib.OrderManagementLib__InsufficientMarginAfterOrder.selector, have, need
            )
        );
        aaplPair.createOrder(spec, _hintsNone(), new bytes[](0), 0, 0, 0, "", "");
    }

    /// @dev The withdrawal boundary for a flat `user`: one unit past `maxOut` is refused with the
    ///      reserve, `maxOut` itself leaves in full, and the lens quotes the same figure.
    function _assertWithdrawBoundary(address user, uint256 maxOut, uint256 reserve) internal {
        assertEq(lens.getMaxWithdrawable(address(aaplPair), user, 0), maxOut, "lens quotes the boundary");
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralLib.CollateralLib__InsufficientMarginAfterWithdrawal.selector, maxOut + UNIT, reserve
            )
        );
        aaplPair.withdrawCollateral(maxOut + UNIT, new bytes[](0), 0, 0, 0, "");

        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        aaplPair.withdrawCollateral(maxOut, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(user) - before, maxOut / UNIT, "the boundary leaves in full");
    }

    function _filled(uint256 orderId) internal view returns (uint256) {
        return OrderView.order(aaplPair, orderId).filledSize;
    }

    function _canceled(uint256 orderId) internal view returns (uint64) {
        return OrderView.order(aaplPair, orderId).canceledBlock;
    }

    function _aaplInBook(uint256 orderId) internal view returns (bool) {
        return OrderView.order(aaplPair, orderId).inBook;
    }

    // -------------------- creation --------------------

    /// @notice An ask under the mark books (mark − limit) × size the moment it fills, so creation
    ///         reserves that loss and the maker fee on top of initial margin at the mark: one unit
    ///         short is refused with the full figure, and exactly that figure rests the order.
    function test_askBelowMark_reservesTheLossAndTheFee() public {
        uint256 need = _imr(10 * 200 * BAZAAR_SCALE) + 10 * 2 * BAZAAR_SCALE + _fee(10 * 198 * BAZAAR_SCALE);
        address dave = _fundWith("dave", need - UNIT);
        _expectRefused(dave, _limitSpecAt(false, 10 * SHARE, 198 * BAZAAR_SCALE), need - UNIT, need);

        address eve = _fundWith("eve", need);
        uint256 ask = _place(eve, false, 10 * SHARE, 198 * BAZAAR_SCALE);
        assertTrue(_aaplInBook(ask), "rests at exactly the reserve");
    }

    /// @notice A bid above the mark books (limit − mark) × size. Initial margin values it at the
    ///         mark — the excess over the mark is that loss, charged once in full — so the reserve
    ///         is IMR at the mark plus the loss plus the maker fee on the limit notional.
    function test_bidAboveMark_reservesTheLossAndTheFee() public {
        uint256 need = _imr(10 * 200 * BAZAAR_SCALE) + 10 * 10 * BAZAAR_SCALE + _fee(10 * 210 * BAZAAR_SCALE);
        address dave = _fundWith("dave", need - UNIT);
        _expectRefused(dave, _limitSpecAt(true, 10 * SHARE, 210 * BAZAAR_SCALE), need - UNIT, need);

        address eve = _fundWith("eve", need);
        uint256 bid = _place(eve, true, 10 * SHARE, 210 * BAZAAR_SCALE);
        assertTrue(_aaplInBook(bid), "rests at exactly the reserve");
    }

    /// @notice At the mark nothing is booked, but the maker fee is still taken ahead of the gate's
    ///         margin test, so the reserve is initial margin plus the fee, and an order admitted
    ///         at exactly that fills whole.
    function test_askAtTheMark_feeReserved_fillsWhole() public {
        uint256 need = _imr(10 * 200 * BAZAAR_SCALE) + _fee(10 * 200 * BAZAAR_SCALE);
        address dave = _fundWith("dave", need - UNIT);
        _expectRefused(dave, _limitSpecAt(false, 10 * SHARE, 200 * BAZAAR_SCALE), need - UNIT, need);

        address eve = _fundWith("eve", need);
        uint256 ask = _place(eve, false, 10 * SHARE, 200 * BAZAAR_SCALE);
        _place(alice, true, 10 * SHARE, 200 * BAZAAR_SCALE);
        assertEq(_filled(ask), 10 * SHARE, "fills whole at the minimum reserve");
        assertEq(_canceled(ask), 0, "not canceled");
    }

    /// @notice The probe: at the minimum creation reserve a taker sized past the maker fills the
    ///         maker whole and keeps its own remainder, instead of the maker being auto-canceled
    ///         for a fill its collateral could not carry.
    function test_askBelowMark_minimumReserve_fillsWholeAgainstAnOversizedTaker() public {
        address dave = _fund("dave");
        uint256 need = _imr(10 * 200 * BAZAAR_SCALE) + 10 * 2 * BAZAAR_SCALE + _fee(10 * 198 * BAZAAR_SCALE);
        _aaplDeposit(dave, need);
        uint256 ask = _place(dave, false, 10 * SHARE, 198 * BAZAAR_SCALE);

        uint256 bid = _place(alice, true, 104 * SHARE / 10, 198 * BAZAAR_SCALE);
        assertEq(_filled(ask), 10 * SHARE, "the maker fills whole");
        assertEq(_canceled(ask), 0, "and is not canceled");
        assertEq(_filled(bid), 10 * SHARE);
        assertTrue(_aaplInBook(bid), "the taker's remainder rests");
        (bool isLong, uint256 size,,,,,) = aaplPair.positionBuckets(dave);
        assertFalse(isLong);
        assertEq(size, 10 * SHARE);
    }

    /// @notice The resting set's debit is summed over both sides whichever side sets the worst-case
    ///         notional: a resting ask's loss and fee count against a new bid on the other side.
    function test_restingDebit_sumsAcrossSides() public {
        uint256 askDebit = 2 * BAZAAR_SCALE + _fee(198 * BAZAAR_SCALE); // ask 1 @ 198: loss 2 + fee
        uint256 bidDebit = _fee(150 * BAZAAR_SCALE); // bid 1 @ 150: fee only
        // Flat, both orders valued at the $200 mark: the worst case is one side's $200.
        uint256 need = _imr(200 * BAZAAR_SCALE) + askDebit + bidDebit;
        address dave = _fundWith("dave", need - UNIT);
        uint256 ask = _place(dave, false, 1 * SHARE, 198 * BAZAAR_SCALE);
        assertTrue(_aaplInBook(ask));
        _expectRefused(dave, _limitSpecAt(true, 1 * SHARE, 150 * BAZAAR_SCALE), need - UNIT, need);

        address eve = _fundWith("eve", need);
        _place(eve, false, 1 * SHARE, 198 * BAZAAR_SCALE);
        uint256 bid = _place(eve, true, 1 * SHARE, 150 * BAZAAR_SCALE);
        assertTrue(_aaplInBook(bid), "both rest at exactly the summed reserve");
    }

    // -------------------- withdrawal --------------------

    /// @notice A withdrawal cannot strip the reserve back out: the boundary is initial margin at
    ///         the mark plus the resting ask's loss and fee, and the lens quotes it.
    function test_withdraw_cannotStripTheDebit() public {
        address erin = _fund("erin");
        _aaplDeposit(erin, 10_000 * BAZAAR_SCALE);
        _place(erin, false, 1 * SHARE, 198 * BAZAAR_SCALE);

        uint256 reserve = _imr(200 * BAZAAR_SCALE) + 2 * BAZAAR_SCALE + _fee(198 * BAZAAR_SCALE);
        _assertWithdrawBoundary(erin, 10_000 * BAZAAR_SCALE - reserve, reserve);
    }

    /// @notice A position holder's withdrawal carries the same debit through the IMR gate: a
    ///         reducing ask under the mark lowers what the holder can release by exactly the
    ///         loss it would book plus its fee, on chain and in the lens.
    function test_withdraw_positionHolder_debitBindsTheImrGate() public {
        // alice buys 1 share at the mark from bob; the withdrawal values her long at the low
        // bracket (spot less the mock feed's 0.1% confidence).
        _place(bob, false, 1 * SHARE, 200 * BAZAAR_SCALE);
        _place(alice, true, 1 * SHARE, 200 * BAZAAR_SCALE);
        uint256 low = 200 * BAZAAR_SCALE - 200 * BAZAAR_SCALE / 1000;

        uint256 before = lens.getMaxWithdrawable(address(aaplPair), alice, low);
        _place(alice, false, 1 * SHARE, 198 * BAZAAR_SCALE);
        uint256 maxOut = lens.getMaxWithdrawable(address(aaplPair), alice, low);
        assertEq(before - maxOut, 2 * BAZAAR_SCALE + _fee(198 * BAZAAR_SCALE), "the debit alone moves the quote");

        vm.prank(alice);
        vm.expectRevert();
        aaplPair.withdrawCollateral(maxOut + UNIT, new bytes[](0), 0, 0, 0, "");
        uint256 cash = usdc.balanceOf(alice);
        vm.prank(alice);
        aaplPair.withdrawCollateral(maxOut, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - cash, maxOut / UNIT, "the quote leaves in full");
    }

    // -------------------- amendment --------------------

    /// @notice Repricing a resting ask from above the mark to well below it needs the loss it
    ///         would then book: the batch is refused by the gate on the set it leaves, and
    ///         accepted once the collateral covers it.
    function test_amend_ontoTheWrongSide_needsTheDebit() public {
        uint256 atCreation = _imr(205 * BAZAAR_SCALE) + _fee(205 * BAZAAR_SCALE);
        address fay = _fundWith("fay", atCreation);
        uint256 ask = _place(fay, false, 1 * SHARE, 205 * BAZAAR_SCALE);

        // $10 under the mark: a loss the $5 of limit the creation reserve had over the mark
        // cannot cover at any initial margin rate below 100%.
        uint256 need = _imr(200 * BAZAAR_SCALE) + 10 * BAZAAR_SCALE + _fee(190 * BAZAAR_SCALE);
        uint256[] memory words = new uint256[](3);
        words[0] = ask;
        words[1] = 190 * BAZAAR_SCALE;
        words[2] = 1 * SHARE;
        vm.prank(fay);
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderManagementLib.OrderManagementLib__InsufficientMarginAfterOrder.selector, atCreation, need
            )
        );
        aaplPair.amendOrders(words, new bytes[](0), 0, 0, 0, "", "");

        _aaplDeposit(fay, need - atCreation);
        vm.prank(fay);
        aaplPair.amendOrders(words, new bytes[](0), 0, 0, 0, "", "");
        assertEq(OrderView.order(aaplPair, ask).limitPrice, 190 * BAZAAR_SCALE, "repriced once covered");
    }

    // -------------------- stop-limits --------------------

    /// @notice A StopLimit waiting outside the book is bounded by its trigger, not by the mark it
    ///         waits under: a buy stop with trigger $220 and limit $225 can lose at most $5 a
    ///         share on arming, so that — not the $25 to today's mark — is reserved, at creation
    ///         and against a withdrawal.
    function test_stopLimit_waiting_reservesTheTriggerGap() public {
        uint256 need = _imr(225 * BAZAAR_SCALE) + 5 * BAZAAR_SCALE + _fee(225 * BAZAAR_SCALE);
        address gus = _fundWith("gus", need - UNIT);
        _expectRefused(gus, _stopSpec(true, 1 * SHARE, 220, 225), need - UNIT, need);

        address hal = _fundWith("hal", need);
        vm.prank(hal);
        aaplPair.createOrder(_stopSpec(true, 1 * SHARE, 220, 225), _hintsNone(), new bytes[](0), 0, 0, 0, "", "");
        uint256 stop = _lastCreatedOrderId(aaplPair);
        assertFalse(_aaplInBook(stop), "waits outside the book");

        assertEq(lens.getMaxWithdrawable(address(aaplPair), hal, 0), 0, "nothing beyond the reserve is free");
        vm.prank(hal);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralLib.CollateralLib__InsufficientMarginAfterWithdrawal.selector, UNIT, need)
        );
        aaplPair.withdrawCollateral(UNIT, new bytes[](0), 0, 0, 0, "");
    }

    /// @notice Once armed the stop rests as a Limit and is reserved against the mark like one:
    ///         armed at $221 with no ask to cross, the $225 bid is valued at the $221 mark and
    ///         books $4 a share, not the $5 trigger bound.
    function test_stopLimit_armed_reservedAsALimitAgainstTheMark() public {
        address gus = _fund("gus");
        _aaplDeposit(gus, 10_000 * BAZAAR_SCALE);
        vm.prank(gus);
        aaplPair.createOrder(_stopSpec(true, 1 * SHARE, 220, 225), _hintsNone(), new bytes[](0), 0, 0, 0, "", "");
        uint256 stop = _lastCreatedOrderId(aaplPair);

        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, 221, uint64(vm.getBlockTimestamp()));
        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](1);
        execs[0].orderId = uint64(stop);
        vm.prank(seq);
        aaplPair.executeTriggeredOrders(execs, pu);
        assertTrue(_aaplInBook(stop), "armed with nothing to cross, it rests");

        (imrBp,,,) = aaplPair.marginRequirements();
        uint256 reserve = _imr(221 * BAZAAR_SCALE) + 4 * BAZAAR_SCALE + _fee(225 * BAZAAR_SCALE);
        _assertWithdrawBoundary(gus, 10_000 * BAZAAR_SCALE - reserve, reserve);
    }
}
