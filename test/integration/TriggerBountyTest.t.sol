// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {OrderView} from "../OrderView.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title TriggerBountyTest
/// @notice The keeper bounty a trigger order carries: escrowed from the owner's wallet at
///         creation (never from collateral), paid to executors in proportion to what they fill,
///         the remainder on completion or resting, and returned to the owner's claimable balance
///         when the order ends unexecuted. Also the two behaviours the escrow makes safe: a
///         fired order the book could not finish stays live, and a wall of resting orders in
///         front of the real liquidity can neither end a stop nor earn more than the sliver it
///         fills.
contract TriggerBountyTest is IntegrationBase {
    uint256 constant BTC = 1e18;
    uint256 constant B = 1e18; // a $1 bounty
    uint256 constant B_USDC = 1e6;

    address internal k2 = makeAddr("k2"); // a second keeper

    function _spec(BazaarTypes.OrderType ot, bool isLong, uint256 size, uint256 triggerPrice, uint256 bounty)
        internal
        view
        returns (BazaarTypes.OrderSpec memory s)
    {
        s.orderType = ot;
        s.isLong = isLong;
        s.size = size;
        s.triggerPrice = _withBounty(triggerPrice, bounty);
        s.maxSlippageBp = 500;
        s.expirationBlock = uint64(block.number + 500_000);
    }

    /// @dev A sell StopLoss for `user`'s long, trigger 48k, 5% slippage, carrying `bounty`.
    function _stopLossWithBounty(address user, uint256 size, uint256 bounty) internal returns (uint256) {
        _approveWallet(user, bounty);
        return _placeStopLoss(user, false, size, _withBounty(48_000 * BAZAAR_SCALE, bounty), 500);
    }

    function _cancel(address user, uint256 id) internal {
        vm.prank(user);
        pair.cancelOrders(_one(id), 0, 0, 0, "", "");
    }

    /// @dev Fire `orderId` as `keeper` at `priceUsd`, asserting the bounty release it emits. The
    ///      price update is built before the expectation is set, since the mock oracle call
    ///      would otherwise be the call the expectation binds to.
    function _fireExpectingRelease(address keeper, uint256 orderId, uint256 priceUsd, address recipient, uint256 amount)
        internal
        returns (uint256 executedCount)
    {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(priceUsd, uint64(vm.getBlockTimestamp()));
        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](1);
        execs[0].orderId = uint64(orderId);
        vm.expectEmit(true, true, true, true, address(pair));
        emit BazaarTypes.TriggerBountyReleased(pair.pairId(), orderId, recipient, amount);
        vm.prank(keeper);
        executedCount = pair.executeTriggeredOrders(execs, pu);
    }

    // ============================================================
    // Escrow at creation
    // ============================================================

    function test_bounty_pulledFromWallet_neverFromCollateral() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 collBefore = _posCollateral(alice);
        uint256 walletBefore = usdc.balanceOf(alice);
        uint256 pairCashBefore = usdc.balanceOf(address(pair));
        uint256 escrowBefore = _escrowTotal();

        _approveWallet(alice, B);
        BazaarTypes.OrderSpec memory s = _spec(BazaarTypes.OrderType.StopLimit, true, BTC / 10, 51_500 * BAZAAR_SCALE, B);
        s.limitPrice = 52_000 * BAZAAR_SCALE;
        bytes[] memory pu = _freshPrice();
        vm.expectEmit(true, true, false, true, address(pair));
        emit BazaarTypes.TriggerBountyEscrowed(pair.pairId(), 1, B); // the pair's first order
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        assertEq(_lastCreatedOrderId(pair), 1);

        assertEq(usdc.balanceOf(alice), walletBefore - B_USDC, "wallet paid the bounty");
        assertEq(usdc.balanceOf(address(pair)), pairCashBefore + B_USDC, "pair holds it");
        assertEq(_posCollateral(alice), collBefore, "collateral untouched");
        assertEq(_escrowTotal(), escrowBefore + B, "escrow liability covers the cash");
        assertEq(_escrowOwed(alice), 0, "nothing claimable yet: the bounty is held against the order");
        _assertBooksSettled("after escrow");
    }

    function test_bounty_storedTriggerPriceExcludesTheBounty() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _approveWallet(alice, B);
        uint256 id =
            _placeStopLimit(alice, true, BTC / 10, _withBounty(51_500 * BAZAAR_SCALE, B), 52_000 * BAZAAR_SCALE);
        assertEq(
            uint256(OrderView.order(pair, id).triggerPrice), 51_500 * BAZAAR_SCALE, "only the price half is stored"
        );
        // And the trigger is evaluated on the price half: unmet at 51_000, met at 51_500.
        assertEq(_executeTriggerAt(id, 51_000), 0, "not yet");
        assertEq(_executeTriggerAt(id, 51_500), 1, "fires at the real trigger");
    }

    function test_bounty_rejectedOnLimitAndMarket() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _approveWallet(alice, B);
        bytes[] memory pu = _freshPrice();

        BazaarTypes.OrderSpec memory lim = _limitSpec(true, BTC / 10, 49_000 * BAZAAR_SCALE);
        lim.triggerPrice = _withBounty(0, B);
        vm.prank(alice);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__BountyOnUntriggeredType.selector);
        pair.createOrder(lim, _hintsNone(), pu, 0, 0, 0, "", "");

        pu = _freshPrice();
        BazaarTypes.OrderSpec memory mkt;
        mkt.orderType = BazaarTypes.OrderType.Market;
        mkt.isLong = true;
        mkt.size = BTC / 10;
        mkt.maxSlippageBp = 100;
        mkt.triggerPrice = _withBounty(0, B);
        vm.prank(alice);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__BountyOnUntriggeredType.selector);
        pair.createOrder(mkt, _hintsNone(), pu, 0, 0, 0, "", "");
    }

    function test_bounty_mustBeWholeUsdc() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _approveWallet(alice, B);
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _spec(BazaarTypes.OrderType.StopLimit, true, BTC / 10, 51_500 * BAZAAR_SCALE, B + 1);
        s.limitPrice = 52_000 * BAZAAR_SCALE;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__BountyNotWholeUsdc.selector, B + 1)
        );
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
    }

    function test_bounty_needsWalletAllowance() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE); // the deposit consumed its own approval
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _spec(BazaarTypes.OrderType.StopLimit, true, BTC / 10, 51_500 * BAZAAR_SCALE, B);
        s.limitPrice = 52_000 * BAZAAR_SCALE;
        vm.prank(alice);
        vm.expectRevert();
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
    }

    function test_zeroBounty_executesAndPaysNothing() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 sl = _placeStopLoss(bob, false, BTC / 10, 48_000 * BAZAAR_SCALE, 500);
        _deposit(dave, 30_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 10, 47_600 * BAZAAR_SCALE, 47_500);

        assertEq(_executeTriggerAt(sl, 47_500), 1, "fires");
        assertEq(_posSize(bob), 0, "closed");
        assertEq(_escrowOwed(seq), 0, "nothing was escrowed, nothing is paid");
        assertEq(_escrowOwed(bob), 0, "and nothing to refund");
    }

    // ============================================================
    // Payment: pro rata per execution, remainder on completion
    // ============================================================

    function test_partialFills_payProRata_remainderToTheCompleter() public {
        _openPosition(bob, carol, true, BTC / 10);
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        uint256 sl = _stopLossWithBounty(bob, BTC / 10, B);

        // A quarter of the size is bid: the first keeper closes a quarter and earns a quarter.
        _placeLimitAt(dave, true, BTC / 40, 47_600 * BAZAAR_SCALE, 47_500);
        assertEq(_fireExpectingRelease(seq, sl, 47_500, seq, B / 4), 1, "first execution");
        assertEq(_filledSize(sl), BTC / 40, "quarter filled");
        assertEq(_escrowOwed(seq), B / 4, "paid for the quarter it filled");
        assertEq(_canceledBlock(sl), 0, "still live");
        assertEq(_stopLossOrderId(bob), sl, "slot still bound");

        // The rest is bid: the second keeper completes the close and earns everything left.
        _placeLimitAt(dave, true, BTC / 10, 47_600 * BAZAAR_SCALE, 47_500);
        assertEq(_executeTriggerAs(k2, sl, 47_500), 1, "second execution");
        assertEq(_posSize(bob), 0, "closed");
        assertEq(_escrowOwed(k2), B - B / 4, "the remainder, not a pro-rata share");
        assertEq(_escrowOwed(bob), 0, "nothing returned to the owner: the order was executed in full");
        assertEq(_stopLossOrderId(bob), 0, "slot freed");

        assertEq(_claimFees(seq), B_USDC / 4);
        assertEq(_claimFees(k2), B_USDC - B_USDC / 4);
        _assertBooks("after both keepers claimed");
    }

    function test_stopLimit_partialFillThenRest_paysWholeBountyToTheArmingKeeper() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _approveWallet(alice, B);
        uint256 stop =
            _placeStopLimit(alice, false, BTC / 5, _withBounty(49_000 * BAZAAR_SCALE, B), 48_700 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 10, 48_750 * BAZAAR_SCALE, 48_500);

        assertEq(_executeTriggerAt(stop, 48_500), 1, "fired");
        assertEq(_filledSize(stop), BTC / 10, "half filled against dave");
        assertTrue(_inBook(stop), "remainder rests");
        // Resting is the end of the keeper's job: nothing is left for a later execution.
        assertEq(_escrowOwed(seq), B, "whole bounty on resting");
    }

    /// @notice The stop's bound is re-priced on every execution, so a retry after a partial fill
    ///         closes exactly what the position still holds.
    function test_refireAfterPartialFill_closesExactRemainder() public {
        _openPosition(bob, carol, true, BTC / 5);
        _deposit(dave, 120_000 * BAZAAR_SCALE);
        uint256 sl = _stopLossWithBounty(bob, type(uint256).max, B);

        _placeLimitAt(dave, true, BTC / 20, 47_600 * BAZAAR_SCALE, 47_500);
        assertEq(_executeTriggerAt(sl, 47_500), 1, "first fire");
        assertEq(_posSize(bob), BTC / 5 - BTC / 20, "0.15 left");
        assertEq(_orderSize(sl), type(uint128).max, "the stored size keeps the close-everything intent");

        _placeLimitAt(dave, true, BTC / 5, 47_600 * BAZAAR_SCALE, 47_500);
        assertEq(_executeTriggerAt(sl, 47_500), 1, "second fire");
        assertEq(_posSize(bob), 0, "the remainder was the live position, not position less earlier fill");
        assertEq(_filledSize(sl), BTC / 5, "closed the whole position across two fires");
        assertEq(_escrowOwed(seq), B, "both executions by the same keeper add up to the whole bounty");
    }

    // ============================================================
    // Nothing planted in the book can end a stop
    // ============================================================

    /// @notice 32 cheap bids planted ahead of the real bid exhaust the walk budget. The stop
    ///         keeps the sliver it filled, stays live, and the wall's owner earns only that
    ///         sliver's share of the bounty; the next keeper finishes the close.
    function test_dustWall_stopSurvivesStepLimit_wallEarnsOnlyItsSliver() public {
        _openPosition(bob, carol, true, BTC / 2); // bob long 0.5
        uint256 sl = _stopLossWithBounty(bob, BTC / 2, B);

        // eve rests MAX_WALK_STEPS bids just above the real bid, each barely over the $5 floor.
        address eve = makeAddr("eve");
        usdc.mint(eve, INITIAL_USER_BALANCE);
        _deposit(eve, 20_000 * BAZAAR_SCALE);
        uint256 dust = 11 * BTC / 100_000; // 0.00011 BTC ≈ $5.27 at the wall's price
        for (uint256 i; i < BazaarTypes.MAX_WALK_STEPS; ++i) {
            _placeLimit(eve, true, dust, 47_900 * BAZAAR_SCALE);
        }
        _deposit(dave, 200_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 2, 47_800 * BAZAAR_SCALE, 47_500);

        // eve fires the stop herself, hoping to cancel it for the bounty.
        assertEq(_executeTriggerAs(eve, sl, 47_500), 1, "fired");
        uint256 sliver = dust * BazaarTypes.MAX_WALK_STEPS;
        assertEq(_filledSize(sl), sliver, "only the wall filled before the budget ran out");
        assertEq(_canceledBlock(sl), 0, "the stop survives the step limit");
        assertFalse(_inBook(sl), "and does not rest");
        assertEq(_stopLossOrderId(bob), sl, "still bound to the position");
        assertEq(_escrowOwed(eve), B * sliver / (BTC / 2), "paid only for the sliver");
        assertLt(_escrowOwed(eve), B / 100, "well under a cent of the bounty");

        // The real liquidity is next in line: an honest keeper finishes the close.
        assertEq(_executeTriggerAs(k2, sl, 47_500), 1, "re-fired");
        assertEq(_posSize(bob), 0, "closed against dave's bid");
        assertEq(_escrowOwed(k2), B - B * sliver / (BTC / 2), "the completing keeper earns the rest");
        _assertBooks("after the wall");
    }

    /// @notice A stop that reaches its owner's own resting bid stays live: the keeper is paid for
    ///         the liquidity it did take, the owner's bid is untouched, and the stop finishes once
    ///         that bid is out of the way.
    function test_selfMatch_stopStaysLive_keeperPaidForFillsBeforeIt() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 sl = _stopLossWithBounty(bob, BTC / 10, B);
        _deposit(dave, 60_000 * BAZAAR_SCALE);

        // bob's own dip bid behind dave's quarter-size bid.
        uint256 ownBid = _placeLimit(bob, true, BTC / 20, 47_700 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 40, 47_800 * BAZAAR_SCALE, 47_500);

        assertEq(_executeTriggerAt(sl, 47_500), 1, "fired");
        assertEq(_filledSize(sl), BTC / 40, "took dave's bid, stopped at bob's own");
        assertEq(_canceledBlock(sl), 0, "a self-match does not end a stop");
        assertEq(_stopLossOrderId(bob), sl, "slot still bound");
        assertEq(_canceledBlock(ownBid), 0, "the owner's bid is untouched");
        assertEq(_escrowOwed(seq), B / 4, "paid for the quarter it closed");
        assertEq(_escrowOwed(bob), 0, "nothing refunded: the stop is still working");

        // The owner clears the way; the next keeper finishes it.
        _cancel(bob, ownBid);
        _placeLimitAt(dave, true, BTC / 10, 47_800 * BAZAAR_SCALE, 47_500);
        assertEq(_executeTriggerAs(k2, sl, 47_500), 1, "re-fired");
        assertEq(_posSize(bob), 0, "closed");
        assertEq(_escrowOwed(k2), B - B / 4, "the rest to the completing keeper");
    }

    /// @notice An order its own walk kills after filling part of its size pays the executor for
    ///         that part; only what was never executed goes back to the owner. Here a StopLimit
    ///         fills most of itself and the remainder is dust that cannot rest.
    function test_killedAfterFills_executorPaidProRata_ownerRefundedTheRest() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _approveWallet(alice, B);
        uint256 size = 21 * BTC / 100_000; // 0.00021 BTC ≈ $10.2: over the $5 floor
        uint256 stop = _placeStopLimit(alice, false, size, _withBounty(49_000 * BAZAAR_SCALE, B), 48_700 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        uint256 taken = 12 * BTC / 100_000; // leaves 0.00009 BTC ≈ $4.4 of remainder: dust
        _placeLimitAt(dave, true, taken, 48_750 * BAZAAR_SCALE, 48_500);

        assertEq(_executeTriggerAt(stop, 48_500), 1, "fired");
        assertEq(_filledSize(stop), taken, "filled what dave bid");
        assertGt(_canceledBlock(stop), 0, "dust remainder cannot rest: canceled");
        uint256 earned = B * taken / size;
        assertEq(_escrowOwed(seq), earned, "paid for the filled share");
        assertEq(_escrowOwed(alice), B - earned, "the unexecuted share returned to the owner");
    }

    /// @dev alice's 0.1 BTC buy StopLimit (trigger 51.5k, limit 52k) carrying B, expiring `life`
    ///      blocks from now.
    function _stopLimitExpiringIn(uint64 life) internal returns (uint256) {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _approveWallet(alice, B);
        BazaarTypes.OrderSpec memory s = _spec(BazaarTypes.OrderType.StopLimit, true, BTC / 10, 51_500 * BAZAAR_SCALE, B);
        s.limitPrice = 52_000 * BAZAAR_SCALE;
        s.expirationBlock = uint64(vm.getBlockNumber()) + life;
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        return _lastCreatedOrderId(pair);
    }

    /// @notice A StopLimit fired with less than MIN_ORDER_LIFETIME_BLOCKS of its life left does not
    ///         rest, where it would soon expire into a dead node at its level: what crosses fills,
    ///         and the rest stays live outside the book for a later execution. Firing it when
    ///         nothing crosses therefore cannot strip the stop. A later execution still fills it
    ///         once liquidity arrives, and each keeper earns the share it filled.
    function test_stopLimitFiredInsideTheMinimumLifetime_neverRests_laterExecutionsFillIt() public {
        uint256 stop = _stopLimitExpiringIn(BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 10);
        uint64 expiry = OrderView.order(pair, stop).expiryBlock;
        uint256 keeperBefore = _escrowOwed(seq);
        vm.roll(expiry - BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 1); // one block short of the floor

        assertEq(_executeTriggerAt(stop, 52_500), 1, "fired with nothing to cross");
        assertFalse(_inBook(stop), "did not rest");
        assertEq(_canceledBlock(stop), 0, "and was not canceled");
        assertEq(_escrowOwed(seq), keeperBefore, "an execution that fills nothing earns nothing");

        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimitAt(carol, false, BTC / 20, 51_900 * BAZAAR_SCALE, 52_500); // half the stop's size
        assertEq(_executeTriggerAs(k2, stop, 52_500), 1, "fired again once liquidity arrived");
        assertEq(_filledSize(stop), BTC / 20, "took carol's ask");
        assertFalse(_inBook(stop), "the remainder did not rest");
        assertEq(_canceledBlock(stop), 0, "and is still live");
        assertEq(_escrowOwed(k2), B / 2, "that keeper earned the half it filled");

        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, false, BTC / 20, 51_950 * BAZAAR_SCALE, 52_500);
        assertEq(_executeTriggerAt(stop, 52_500), 1, "fired a third time");
        assertEq(_filledSize(stop), BTC / 10, "filled in full");
        assertGt(OrderView.order(pair, stop).filledBlock, 0, "complete");
        assertEq(_escrowOwed(seq) - keeperBefore, B / 2, "the completing keeper earned the rest");
        assertEq(_escrowOwed(alice), 0, "nothing returned to the owner: all of it was executed");
        (uint64 bidHead,,,) = pair.book();
        assertEq(bidHead, 0, "the stop never rested");
    }

    /// @notice A StopLimit left live outside the book in its last minute that nothing fills expires
    ///         there like any unexecuted stop, and its bounty returns to the owner.
    function test_stopLimitFiredInsideTheMinimumLifetime_expiresUnrested_bountyReturns() public {
        uint256 stop = _stopLimitExpiringIn(BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 10);
        uint64 expiry = OrderView.order(pair, stop).expiryBlock;
        vm.roll(expiry - 1);
        assertEq(_executeTriggerAt(stop, 52_500), 1, "fired in its second-to-last block");
        assertFalse(_inBook(stop), "did not rest");

        vm.roll(expiry + 1);
        assertEq(_executeTriggerAt(stop, 52_500), 0, "expired stops are skipped");
        vm.prank(seq);
        pair.sweepExpired(_one(stop));
        assertGt(_canceledBlock(stop), 0, "swept");
        assertEq(_escrowOwed(alice), B, "the whole bounty returns to the owner");
    }

    /// @notice With exactly MIN_ORDER_LIFETIME_BLOCKS left the stop rests at its limit as usual, and
    ///         resting pays the keeper the whole bounty.
    function test_stopLimitArmedWithTheMinimumLifetimeLeft_rests() public {
        uint256 stop = _stopLimitExpiringIn(BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 10);
        uint64 expiry = OrderView.order(pair, stop).expiryBlock;
        uint256 keeperBefore = _escrowOwed(seq);

        vm.roll(expiry - BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS);
        assertEq(_executeTriggerAt(stop, 52_500), 1, "fired");
        assertTrue(_inBook(stop), "rested at its limit");
        assertEq(_canceledBlock(stop), 0, "not canceled");
        (uint64 bidHead,,,) = pair.book();
        assertEq(bidHead, uint64(stop), "it is the bid side's head");
        assertEq(_escrowOwed(seq) - keeperBefore, B, "resting completes the keeper's job");
        assertEq(_escrowOwed(alice), 0, "nothing returns to the owner");
    }

    // ============================================================
    // Refunds: every way an order can end without an executor to pay
    // ============================================================

    function test_ownerCancel_refundsRemainingBounty() public {
        _openPosition(bob, carol, true, BTC / 10);
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        uint256 sl = _stopLossWithBounty(bob, BTC / 10, B);

        // One execution pays a quarter; the owner then cancels.
        _placeLimitAt(dave, true, BTC / 40, 47_600 * BAZAAR_SCALE, 47_500);
        assertEq(_executeTriggerAt(sl, 47_500), 1);
        uint256 escrowBefore = _escrowTotal();

        vm.expectEmit(true, true, true, true, address(pair));
        emit BazaarTypes.TriggerBountyReleased(pair.pairId(), sl, bob, B - B / 4);
        _cancel(bob, sl);

        assertGt(_canceledBlock(sl), 0, "canceled");
        assertEq(_escrowOwed(bob), B - B / 4, "unpaid remainder returned to the owner");
        assertEq(_escrowOwed(seq), B / 4, "the executed share stays with the keeper");
        assertEq(_escrowTotal(), escrowBefore, "assignment moves nothing in or out of the escrow");
        assertEq(_claimFees(bob), B_USDC - B_USDC / 4, "and it is withdrawable");
    }

    function test_positionClosedByHand_fenceCancelsStop_sweepRefunds() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 sl = _stopLossWithBounty(bob, BTC / 10, B);

        // bob closes the position through the book; the fence strands the stop.
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        _placeLimit(bob, false, BTC / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(dave, true, BTC / 10, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(bob), 0, "flat");
        assertGt(_canceledBlock(sl), 0, "stop canceled by the fence");
        assertEq(_escrowOwed(bob), 0, "the fence does not touch the escrow");

        // Anyone can release the stranded bounty to its owner.
        vm.prank(seq);
        pair.sweepExpired(_one(sl));
        assertEq(_escrowOwed(bob), B, "returned in full: nothing was ever executed");

        // Sweeping again finds nothing to do.
        vm.prank(seq);
        pair.sweepExpired(_one(sl));
        assertEq(_escrowOwed(bob), B, "idempotent");
    }

    function test_deadOrder_ownerCancelRefundsInsteadOfReverting() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 sl = _stopLossWithBounty(bob, BTC / 10, B);
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        _placeLimit(bob, false, BTC / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(dave, true, BTC / 10, 51_000 * BAZAAR_SCALE);
        assertGt(_canceledBlock(sl), 0, "dead");

        _cancel(bob, sl); // would revert OrderIsNotActive without a bounty to return
        assertEq(_escrowOwed(bob), B, "refunded");

        // With the bounty gone, the dead order reverts as any other.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__OrderIsNotActive.selector, sl));
        pair.cancelOrders(_one(sl), 0, 0, 0, "", "");
    }

    function test_expiredStopLimit_sweepCancelsAndRefunds() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _approveWallet(alice, B);
        BazaarTypes.OrderSpec memory s = _spec(BazaarTypes.OrderType.StopLimit, true, BTC / 10, 51_500 * BAZAAR_SCALE, B);
        s.limitPrice = 52_000 * BAZAAR_SCALE;
        s.expirationBlock = uint64(vm.getBlockNumber()) + BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS;
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 id = _lastCreatedOrderId(pair);

        _roll(BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 1);
        // Expired: a keeper can no longer fire it, and the owner's cancel refunds rather than
        // reverting OrderAlreadyExpired.
        assertEq(_executeTriggerAt(id, 51_600), 0, "expired stops are skipped");
        _cancel(alice, id);
        assertEq(_escrowOwed(alice), B, "refunded on the owner's cancel");
        assertEq(_canceledBlock(id), 0, "the cancel only released the bounty; the janitor retires the order");

        vm.prank(seq);
        pair.sweepExpired(_one(id));
        assertGt(_canceledBlock(id), 0, "swept");
        assertEq(_escrowOwed(alice), B, "no double refund");
    }

    function test_arrivalFire_fullFill_bountyReturnsToOwner() public {
        _openPosition(bob, carol, true, BTC / 10);
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        _placeLimit(dave, true, BTC / 10, 49_900 * BAZAAR_SCALE);

        // Target $49k, market $50k: a long's sell target that is already satisfied.
        _approveWallet(bob, B);
        uint256 walletBefore = usdc.balanceOf(bob);
        uint256 tp = _placeTakeProfit(bob, false, BTC / 10, _withBounty(49_000 * BAZAAR_SCALE, B), 500);

        assertEq(_filledSize(tp), BTC / 10, "executed in the creation transaction");
        assertEq(usdc.balanceOf(bob), walletBefore - B_USDC, "the bounty was pulled");
        assertEq(_escrowOwed(bob), B, "and credited straight back: no keeper to pay");
        assertEq(_escrowOwed(seq), 0);
    }

    function test_arrivalFire_partialFill_ownerGetsTheShare_restStaysForKeepers() public {
        _openPosition(bob, carol, true, BTC / 10);
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        _placeLimit(dave, true, BTC / 40, 49_900 * BAZAAR_SCALE);

        _approveWallet(bob, B);
        uint256 tp = _placeTakeProfit(bob, false, BTC / 10, _withBounty(49_000 * BAZAAR_SCALE, B), 500);

        assertEq(_filledSize(tp), BTC / 40, "a quarter filled on arrival");
        assertEq(_canceledBlock(tp), 0, "the rest stays live");
        assertEq(_escrowOwed(bob), B / 4, "the arrival share goes back to the owner");

        _placeLimit(dave, true, BTC / 10, 49_900 * BAZAAR_SCALE);
        assertEq(_executeTriggerAt(tp, 50_000), 1, "a keeper finishes it");
        assertEq(_posSize(bob), 0);
        assertEq(_escrowOwed(seq), B - B / 4, "and earns what was left");
    }

    // ============================================================
    // Meta-transactions: the bounty is inside the signature
    // ============================================================

    function _sign(uint256 pk, bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _createOrderHash(BazaarTypes.OrderSpec memory spec, uint256 deadline, uint256 relayerFee)
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
                uint256(0), // nonce
                deadline,
                relayerFee
            )
        );
    }

    function test_relayed_bountyPulledFromSigner_alongsideRelayerFee() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        usdc.mint(signer, 1_000_000 * USDC_SCALE);
        _deposit(signer, 20_000 * BAZAAR_SCALE);
        uint256 fee = 0.5e18;
        _approveWallet(signer, B + fee);

        BazaarTypes.OrderSpec memory spec = _spec(BazaarTypes.OrderType.StopLimit, true, BTC / 10, 51_500 * BAZAAR_SCALE, B);
        spec.limitPrice = 52_000 * BAZAAR_SCALE;
        uint256 deadline = vm.getBlockTimestamp() + 5;
        bytes memory sig = _sign(pk, _createOrderHash(spec, deadline, fee));

        uint256 walletBefore = usdc.balanceOf(signer);
        uint256 escrowBefore = _escrowTotal();
        bytes[] memory pu = _freshPrice();
        vm.prank(dave); // the relayer
        pair.createOrder(spec, _hintsNone(), pu, 0, deadline, fee, sig, "");
        uint256 id = _lastCreatedOrderId(pair);

        assertEq(usdc.balanceOf(signer), walletBefore - (B + fee) / 1e12, "signer paid fee and bounty");
        assertEq(_escrowOwed(dave), fee, "relayer earned the fee");
        assertEq(_escrowTotal(), escrowBefore + B + fee, "both are escrow liabilities");
        assertEq(_posCollateral(signer), 20_000 * BAZAAR_SCALE, "collateral untouched");

        // The keeper who later arms it earns the bounty, not the relayer.
        assertEq(_executeTriggerAt(id, 51_600), 1);
        assertEq(_escrowOwed(seq), B);
        assertEq(_escrowOwed(dave), fee, "relayer's balance unchanged by the execution");
    }

    /// @notice The bounty is inside the signed payload. A relayer that rewrites it no longer
    ///         holds a signature over what it submits: the recovered signer is some other
    ///         address with no allowance, so the pull fails and the real signer's wallet is
    ///         never touched.
    function test_relayed_relayerCannotChangeTheBounty() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        usdc.mint(signer, 1_000_000 * USDC_SCALE);
        _deposit(signer, 20_000 * BAZAAR_SCALE);
        _approveWallet(signer, 10 * B);
        uint256 walletBefore = usdc.balanceOf(signer);

        BazaarTypes.OrderSpec memory spec = _spec(BazaarTypes.OrderType.StopLimit, true, BTC / 10, 51_500 * BAZAAR_SCALE, B);
        spec.limitPrice = 52_000 * BAZAAR_SCALE;
        uint256 deadline = vm.getBlockTimestamp() + 5;
        bytes memory sig = _sign(pk, _createOrderHash(spec, deadline, 0));

        // A relayer raising the bounty by rewriting the field submits a payload the signature
        // does not cover.
        spec.triggerPrice = _withBounty(51_500 * BAZAAR_SCALE, 10 * B);
        bytes[] memory pu = _freshPrice();
        vm.prank(dave);
        vm.expectRevert();
        pair.createOrder(spec, _hintsNone(), pu, 0, deadline, 0, sig, "");
        assertEq(usdc.balanceOf(signer), walletBefore, "the signer's wallet is untouched");
        assertEq(pair.metaTxNonces(signer), 0, "and their nonce unspent");
    }
}
