// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {OrderView} from "../OrderView.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";

/// @title FreshArrivalGuardsTest
/// @notice Fresh-oracle guards on the AAPL book: fills are UNBANDED while the oracle is fresh
///         (any consensual cross prints at the maker's price — the margin gates and FundingLib's
///         index clamp carry the defense); Limit placement is refused outside
///         ±MAX_PLACEMENT_DEVIATION_BP of the mark; and both the creation margin gate and the
///         withdrawal order-exposure gate reserve fresh exposure at no less than the mark, with
///         the maker fee on top.
contract FreshArrivalGuardsTest is IntegrationBase {
    uint256 constant SHARE = 1e18;
    uint256 constant PX = 200; // AAPL mark in whole USD; placement band $100..$300

    function _aaplDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev Push a fresh price so every subsequent same-timestamp call rides the oracle cache
    ///      (no per-call update needed, and the margin curve stays put between calls).
    function _refreshAt(uint256 priceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, priceUsd, uint64(vm.getBlockTimestamp()));
        aaplPair.refreshPrice{value: 0}(pu);
    }

    /// @dev Place an AAPL limit with no price update — consumes the fresh cache seeded above.
    function _place(address user, bool isLong, uint256 size, uint256 limitPriceBz, bool postOnly)
        internal
        returns (uint256)
    {
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Limit;
        s.isLong = isLong;
        s.isPostOnly = postOnly;
        s.size = size;
        s.limitPrice = limitPriceBz;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        vm.prank(user);
        aaplPair.createOrder(s, _hintsNone(), new bytes[](0), 0, 0, 0, "", "");
        return _lastCreatedOrderId(aaplPair);
    }

    function _aaplFilled(uint256 orderId) internal view returns (uint256 f) {
        return OrderView.order(aaplPair, orderId).filledSize;
    }

    function _aaplCanceled(uint256 orderId) internal view returns (uint64 cb) {
        return OrderView.order(aaplPair, orderId).canceledBlock;
    }

    function _aaplInBook(uint256 orderId) internal view returns (bool b) {
        return OrderView.order(aaplPair, orderId).inBook;
    }

    function setUp() public override {
        super.setUp();
        _aaplDeposit(alice, 20_000 * BAZAAR_SCALE);
        _aaplDeposit(bob, 20_000 * BAZAAR_SCALE);
        _aaplDeposit(carol, 20_000 * BAZAAR_SCALE);
        _refreshAt(PX);
    }

    // -------------------- unbanded fresh fills --------------------

    function test_fresh_wideCross_fillsAtMakerPrice() public {
        // 6% above the mark: no fresh-mode band blocks it. The taker overpaying vs the mark is
        // charged the gap by the incipient-loss debit inside its margin gate, not refused.
        uint256 ask = _place(bob, false, 1 * SHARE, 212 * BAZAAR_SCALE, false);
        uint256 bid = _place(alice, true, 1 * SHARE, 213 * BAZAAR_SCALE, false);

        assertEq(_aaplFilled(bid), 1 * SHARE, "fresh cross fills regardless of distance from mark");
        assertEq(_aaplFilled(ask), 1 * SHARE);
        (, uint256 sz, uint256 entry,,,,) = aaplPair.positionBuckets(alice);
        assertEq(sz, 1 * SHARE);
        assertEq(entry, 212 * BAZAAR_SCALE, "at the maker's price");
    }

    function test_fresh_belowMarkMaker_fillsFirst() public {
        // An ask 6% below the mark is just the best price on the book — price priority applies.
        uint256 deeperAsk = _place(carol, false, 1 * SHARE, 195 * BAZAAR_SCALE, false);
        uint256 cheapAsk = _place(bob, false, 1 * SHARE, 188 * BAZAAR_SCALE, false); // sorts ahead

        uint256 bid = _place(alice, true, 1 * SHARE, 196 * BAZAAR_SCALE, false);

        assertEq(_aaplFilled(cheapAsk), 1 * SHARE, "best-priced maker fills, wherever it sits vs the mark");
        assertEq(_aaplFilled(deeperAsk), 0, "worse-priced maker untouched");
        (, uint256 sz, uint256 entry,,,,) = aaplPair.positionBuckets(alice);
        assertEq(sz, 1 * SHARE);
        assertEq(entry, 188 * BAZAAR_SCALE);
        assertEq(_aaplFilled(bid), 1 * SHARE);
    }

    function test_fresh_postOnly_crossingLiveMaker_cancels() public {
        // With no fresh band there is no cleanup step ahead of the post-only check: crossing a
        // live maker at any price is the violation, and the incoming order dies.
        uint256 ask = _place(bob, false, 1 * SHARE, 188 * BAZAAR_SCALE, false);

        uint256 bid = _place(alice, true, 1 * SHARE, 189 * BAZAAR_SCALE, true);
        assertGt(_aaplCanceled(bid), 0, "post-only arrival crossing a live maker cancels");
        assertFalse(_aaplInBook(bid));
        assertTrue(_aaplInBook(ask), "the maker it crossed stays");
        assertEq(_aaplFilled(ask), 0);
    }

    // -------------------- placement band --------------------

    function test_placement_rejectsLimitOutsideBand() public {
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Limit;
        s.isLong = true;
        s.size = 1 * SHARE;
        s.limitPrice = 99 * BAZAAR_SCALE; // below 0.5 x $200
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderManagementLib.OrderManagementLib__LimitPriceOutsidePlacementBand.selector,
                99 * BAZAAR_SCALE,
                100 * BAZAAR_SCALE,
                300 * BAZAAR_SCALE
            )
        );
        aaplPair.createOrder(s, _hintsNone(), new bytes[](0), 0, 0, 0, "", "");

        s.isLong = false;
        s.limitPrice = 301 * BAZAAR_SCALE; // above 1.5 x $200
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderManagementLib.OrderManagementLib__LimitPriceOutsidePlacementBand.selector,
                301 * BAZAAR_SCALE,
                100 * BAZAAR_SCALE,
                300 * BAZAAR_SCALE
            )
        );
        aaplPair.createOrder(s, _hintsNone(), new bytes[](0), 0, 0, 0, "", "");
    }

    function test_placement_bandBoundsInclusive() public {
        uint256 bid = _place(alice, true, 1 * SHARE, 100 * BAZAAR_SCALE, false); // exactly 0.5x
        assertTrue(_aaplInBook(bid));
        uint256 ask = _place(bob, false, 1 * SHARE, 300 * BAZAAR_SCALE, false); // exactly 1.5x
        assertTrue(_aaplInBook(ask));
    }

    // -------------------- reservation at the mark --------------------

    function test_creation_bidBelowMark_reservesAtMark() public {
        (uint256 imrBp,,,) = aaplPair.marginRequirements();
        // 10 shares bid at $120 under a $200 mark: reserved at the mark, not the limit, plus the
        // maker fee on the limit notional (a bid under the mark books no loss when it fills).
        uint256 fee = 10 * 120 * BAZAAR_SCALE * BazaarTypes.MAKER_INSURANCE_FEE_EBP / BazaarTypes.EBP_SCALE;
        uint256 needAtMark = Math_mulDiv(10 * 200 * BAZAAR_SCALE, imrBp, 10_000) + fee;
        uint256 needAtLimit = Math_mulDiv(10 * 120 * BAZAAR_SCALE, imrBp, 10_000) + fee;

        address dave = makeAddr("dave");
        usdc.mint(dave, INITIAL_USER_BALANCE);
        uint256 shortDeposit = needAtMark - 5 * BAZAAR_SCALE; // $5 short of the mark reserve
        assertGt(shortDeposit, needAtLimit, "a limit-priced reserve would have accepted this");
        _aaplDeposit(dave, shortDeposit);

        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Limit;
        s.isLong = true;
        s.size = 10 * SHARE;
        s.limitPrice = 120 * BAZAAR_SCALE;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(
                OrderManagementLib.OrderManagementLib__InsufficientMarginAfterOrder.selector, shortDeposit, needAtMark
            )
        );
        aaplPair.createOrder(s, _hintsNone(), new bytes[](0), 0, 0, 0, "", "");

        _aaplDeposit(dave, 5 * BAZAAR_SCALE); // top up to exactly the mark reserve
        uint256 bid = _place(dave, true, 10 * SHARE, 120 * BAZAAR_SCALE, false);
        assertTrue(_aaplInBook(bid), "creatable once the mark reserve is met");
    }

    function test_withdraw_ordersReservedAtMark() public {
        (uint256 imrBp,,,) = aaplPair.marginRequirements();
        address erin = makeAddr("erin");
        usdc.mint(erin, INITIAL_USER_BALANCE);
        _aaplDeposit(erin, 10_000 * BAZAAR_SCALE);
        _place(erin, true, 1 * SHARE, 120 * BAZAAR_SCALE, false); // resting bid below the mark

        // Initial margin at the mark plus the maker fee on the limit notional.
        uint256 orderImrReq = Math_mulDiv(200 * BAZAAR_SCALE, imrBp, 10_000) + 120 * BAZAAR_SCALE
            * BazaarTypes.MAKER_INSURANCE_FEE_EBP / BazaarTypes.EBP_SCALE;
        uint256 maxOut = 10_000 * BAZAAR_SCALE - orderImrReq;

        vm.prank(erin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralLib.CollateralLib__InsufficientMarginAfterWithdrawal.selector, maxOut + 1e12, orderImrReq
            )
        );
        aaplPair.withdrawCollateral(maxOut + 1e12, new bytes[](0), 0, 0, 0, "");

        uint256 before = usdc.balanceOf(erin);
        vm.prank(erin);
        aaplPair.withdrawCollateral(maxOut, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(erin) - before, maxOut / 1e12, "boundary is exactly the mark reserve");
    }

    function Math_mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return a * b / d;
    }
}
