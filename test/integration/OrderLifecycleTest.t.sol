// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {OrderView} from "../OrderView.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";

/// @title OrderLifecycleTest
/// @notice Order lifecycle around the book that the fill-path suites don't reach: the
///         permissionless expiry janitor, time-in-force validation, market-order terminality,
///         and the invariant that every terminal write also removes the order from the book —
///         so no path can leave an order that a later arrival could still fill.
contract OrderLifecycleTest is IntegrationBase {
    uint256 constant BTC = 1e18;

    /// @dev Terminate the pair for real: fix the price and finalize (no position is open, so
    ///      finalize is allowed at once).
    function _setTerminated() internal {
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminated(), "pair terminated");
    }

    function _bookCounts() internal view returns (uint64 bidCount, uint64 askCount) {
        (,, bidCount, askCount) = pair.book();
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    // ============================================================
    // sweepExpired — the permissionless expiry janitor
    // ============================================================

    /// @dev Place a limit with the minimum lifetime so it can be expired by rolling forward.
    function _placeShortLived(address user, bool isLong, uint256 size, uint256 price) internal returns (uint256) {
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(isLong, size, price);
        s.expirationBlock = uint64(vm.getBlockNumber() + 12); // MIN_ORDER_LIFETIME_BLOCKS
        vm.prank(user);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        return _lastCreatedOrderId(pair);
    }

    function test_sweepExpired_cancelsUnlinksAndDeregisters() public {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        uint256 id = _placeShortLived(alice, true, BTC / 10, 49_000 * BAZAAR_SCALE);
        assertTrue(_inBook(id), "resting before expiry");
        (uint64 bidsBefore,) = _bookCounts();
        assertEq(bidsBefore, 1);

        _roll(20); // past expiry

        // Anyone may sweep — dave has no relationship to the order.
        vm.prank(dave);
        pair.sweepExpired(_ids(id));

        assertGt(_canceledBlock(id), 0, "expired order canceled");
        assertFalse(_inBook(id), "unlinked from the book");
        (uint64 bidsAfter,) = _bookCounts();
        assertEq(bidsAfter, 0, "side count decremented");
        (, uint256 count,,) = pair.getUserActiveLimitOrders(alice);
        assertEq(count, 0, "removed from the owner's active set");
    }

    function test_sweepExpired_sweptOrderCanNeverFill() public {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        _deposit(bob, 60_000 * BAZAAR_SCALE);
        uint256 stale = _placeShortLived(alice, true, BTC / 10, 49_000 * BAZAAR_SCALE);
        _roll(20);
        vm.prank(dave);
        pair.sweepExpired(_ids(stale));

        // A crossing sell arrives afterwards: with the swept order gone from the book it must
        // rest rather than fill against a dead order.
        uint256 arriving = _placeLimit(bob, false, BTC / 10, 48_000 * BAZAAR_SCALE);
        assertEq(_filledSize(stale), 0, "swept order never fills");
        assertEq(_filledSize(arriving), 0, "nothing to fill against");
        assertTrue(_inBook(arriving), "arrival rests on an empty opposing side");
    }

    function test_sweepExpired_skipsLiveTerminalAndUnknownIds() public {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        uint256 live = _placeLimit(alice, true, BTC / 10, 49_000 * BAZAAR_SCALE);
        uint256 canceled = _placeLimit(alice, true, BTC / 10, 48_500 * BAZAAR_SCALE);
        vm.prank(alice);
        pair.cancelOrders(_ids(canceled), 0, 0, 0, "", "");
        uint64 canceledAt = _canceledBlock(canceled);

        _roll(5); // `live` has a 500k-block lifetime, so it is still live

        uint256[] memory batch = new uint256[](3);
        batch[0] = live;
        batch[1] = canceled;
        batch[2] = 9_999; // never existed
        vm.prank(dave);
        pair.sweepExpired(batch); // must not revert on any of them

        assertEq(_canceledBlock(live), 0, "live order untouched");
        assertTrue(_inBook(live), "live order still resting");
        assertEq(_canceledBlock(canceled), canceledAt, "terminal order not re-stamped");
    }

    function test_sweepExpired_isGatedWhenHalted() public {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        uint256 id = _placeShortLived(alice, true, BTC / 10, 49_000 * BAZAAR_SCALE);
        _roll(20);
        _setTerminated();

        vm.prank(dave);
        vm.expectRevert(BazaarPair.BazaarPair__TradingHalted.selector);
        pair.sweepExpired(_ids(id));
    }

    /// @notice The owner's lazy sweep (run on every creation) unlinks their expired orders too —
    ///         the janitor is an accelerant, not the only path.
    function test_lazySweep_onCreate_unlinksExpiredFromBook() public {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        uint256 stale = _placeShortLived(alice, true, BTC / 10, 49_000 * BAZAAR_SCALE);
        _roll(20);

        _placeLimit(alice, true, BTC / 10, 48_000 * BAZAAR_SCALE); // triggers the sweep

        assertGt(_canceledBlock(stale), 0, "expired order canceled by the lazy sweep");
        assertFalse(_inBook(stale), "and unlinked from the book");
        (uint64 bids,) = _bookCounts();
        assertEq(bids, 1, "only the fresh order remains linked");
    }

    // ============================================================
    // Time-in-force validation
    // ============================================================

    function _expectTifRevert(BazaarTypes.OrderSpec memory s) internal {
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__InvalidTimeInForce.selector);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
    }

    function test_ioc_rejectedOnMarket() public {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Market;
        s.isLong = true;
        s.size = BTC / 10;
        s.maxSlippageBp = 100;
        s.tif = BazaarTypes.TimeInForce.IOC;
        _expectTifRevert(s);
    }

    function test_ioc_rejectedOnStopLimit() public {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.StopLimit;
        s.isLong = true;
        s.size = BTC / 10;
        s.triggerPrice = 55_000 * BAZAAR_SCALE;
        s.limitPrice = 56_000 * BAZAAR_SCALE;
        s.expirationBlock = uint64(block.number + 500_000);
        s.tif = BazaarTypes.TimeInForce.IOC;
        _expectTifRevert(s);
    }

    function test_ioc_rejectedAlongsidePostOnly() public {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        BazaarTypes.OrderSpec memory s = _limitSpec(true, BTC / 10, 49_000 * BAZAAR_SCALE);
        s.tif = BazaarTypes.TimeInForce.IOC;
        s.isPostOnly = true; // contradictory: one demands taking, the other forbids it
        _expectTifRevert(s);
    }

    function test_ioc_rejectedOnTakeProfit() public {
        _openPosition(alice, bob, true, BTC / 10);
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.TakeProfit;
        s.isLong = false;
        s.size = BTC / 10;
        s.triggerPrice = 55_000 * BAZAAR_SCALE;
        s.maxSlippageBp = 500;
        s.tif = BazaarTypes.TimeInForce.IOC;
        _expectTifRevert(s);
    }

    // ============================================================
    // Market-order terminality
    // ============================================================

    function test_market_isTerminalAtCreation_noActiveCap() public {
        _deposit(alice, 60_000 * BAZAAR_SCALE);

        uint256 first = _placeMarket(alice, true, BTC / 100, 300);
        BazaarTypes.Order memory fo = OrderView.order(pair, first);
        (uint64 creation, uint64 expiry) = (fo.creationBlock, fo.expiryBlock);
        assertEq(expiry, creation, "market orders expire in their creation block");
        assertGt(_canceledBlock(first), 0, "unfilled market order is terminal immediately");

        // A second market order in the same block is accepted: markets never rest, so there is
        // no one-active-market slot to collide with.
        uint256 second = _placeMarket(alice, true, BTC / 100, 300);
        assertGt(second, first, "second market order created");
        assertGt(_canceledBlock(second), 0, "and is likewise terminal");
    }

    // ============================================================
    // Cancel removes the order from the book
    // ============================================================

    function test_cancel_unlinksSoLaterArrivalCannotFill() public {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        _deposit(bob, 60_000 * BAZAAR_SCALE);
        uint256 resting = _placeLimit(alice, false, BTC / 10, 50_200 * BAZAAR_SCALE);
        (, uint64 asksBefore) = _bookCounts();
        assertEq(asksBefore, 1);

        vm.prank(alice);
        pair.cancelOrders(_ids(resting), 0, 0, 0, "", "");
        assertFalse(_inBook(resting), "canceled order unlinked in the same write");
        (, uint64 asksAfter) = _bookCounts();
        assertEq(asksAfter, 0, "ask side emptied");

        uint256 arriving = _placeLimit(bob, true, BTC / 10, 50_500 * BAZAAR_SCALE);
        assertEq(_filledSize(resting), 0, "canceled order can never fill");
        assertTrue(_inBook(arriving), "arrival rests instead");
    }

    // ============================================================
    // Step-budget clamping
    // ============================================================

    /// @notice A caller-supplied budget above the protocol ceiling is clamped to it: a taker
    ///         asking for 100 steps against a deeper book still stops at MAX_WALK_STEPS and has
    ///         its still-crossing remainder canceled.
    function test_maxSteps_clampedToProtocolCeiling() public {
        uint256 depth = BazaarTypes.MAX_WALK_STEPS + 4;
        uint64 pred;
        for (uint256 i; i < depth; ++i) {
            address m = makeAddr(string.concat("mk", vm.toString(i)));
            usdc.mint(m, 1_000_000 * USDC_SCALE);
            _deposit(m, 60_000 * BAZAAR_SCALE);
            bytes[] memory pu = _freshPrice();
            BazaarTypes.OrderSpec memory s = _limitSpec(false, BTC / 100, (50_010 + i) * BAZAAR_SCALE);
            BazaarTypes.MatchHints memory h;
            h.pred = pred;
            vm.prank(m);
            pair.createOrder(s, h, pu, 0, 0, 0, "", "");
            pred = uint64(_lastCreatedOrderId(pair));
        }

        _deposit(alice, 900_000 * BAZAAR_SCALE);
        bytes[] memory pu2 = _freshPrice();
        BazaarTypes.OrderSpec memory taker = _limitSpec(true, depth * BTC / 100, 51_000 * BAZAAR_SCALE);
        BazaarTypes.MatchHints memory hints;
        hints.maxSteps = 100; // above the ceiling
        vm.prank(alice);
        pair.createOrder(taker, hints, pu2, 0, 0, 0, "", "");
        uint256 id = _lastCreatedOrderId(pair);

        assertEq(_posSize(alice), BazaarTypes.MAX_WALK_STEPS * BTC / 100, "filled exactly the ceiling's worth");
        assertGt(_canceledBlock(id), 0, "still-crossing remainder canceled at the ceiling");
        assertFalse(_inBook(id), "and never rests crossed");
    }

    // ============================================================
    // Relayed orders: the signer's execution is not the relayer's to bound
    // ============================================================

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice A relayer supplies `hints` for a signature it did not produce. A low step budget
    ///         would truncate the signed order and cancel the rest while the relayer still
    ///         collects its fee, so relayed calls always run the protocol default.
    function test_relayedOrder_relayerMaxStepsIsIgnored() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        usdc.mint(signer, 1_000_000 * USDC_SCALE);
        _deposit(signer, 200_000 * BAZAAR_SCALE);
        _deposit(bob, 200_000 * BAZAAR_SCALE);
        _deposit(carol, 200_000 * BAZAAR_SCALE);

        // Two crossing asks: a truncating budget would fill only the first.
        _placeLimit(bob, false, BTC / 10, 50_100 * BAZAAR_SCALE);
        _placeLimit(carol, false, BTC / 10, 50_200 * BAZAAR_SCALE);

        BazaarTypes.OrderSpec memory spec = _limitSpec(true, BTC / 5, 50_500 * BAZAAR_SCALE);
        uint256 deadline = vm.getBlockTimestamp() + 5;
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
                uint256(0), // nonce
                deadline,
                uint256(0) // relayerFee
            )
        );
        bytes memory sig = _sign(pk, structHash);

        bytes[] memory pu = _freshPrice();
        BazaarTypes.MatchHints memory hostile;
        hostile.maxSteps = 1; // relayer asking to fill one node only
        vm.prank(dave); // the relayer
        pair.createOrder(spec, hostile, pu, 0, deadline, 0, sig, "");

        assertEq(_posSize(signer), BTC / 5, "signed order filled in full despite the relayer's budget");
    }
}
