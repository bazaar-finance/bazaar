// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {OrderView} from "../OrderView.sol";
import {MatchingEngineLib} from "../../src/libraries/MatchingEngineLib.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BucketStore} from "../BucketStore.sol";

/// @title TriggerExecutionTest
/// @notice StopLimit/StopLoss lifecycle under keeper execution: untriggered stops rest outside
///         the book until a permissionless executeTriggeredOrders call fires them against a
///         fresh oracle price, earning the keeper the bounty the owner escrowed with the order;
///         a stop whose trigger a fresh price already meets at creation arms immediately with no
///         keeper, and its bounty returns to the owner. The bounty accounting itself is covered
///         in TriggerBountyTest.
contract TriggerExecutionTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BTC = 1e18;
    uint256 constant BOUNTY = 0.25e18; // an owner-chosen keeper bounty, BAZAAR precision
    uint256 constant BOUNTY_USDC = 0.25e6;

    /// @dev A buy StopLimit carrying BOUNTY, with the wallet approval its creation needs.
    function _placeStopLimitWithBounty(
        address user,
        bool isLong,
        uint256 size,
        uint256 triggerPrice,
        uint256 limitPrice
    ) internal returns (uint256) {
        _approveWallet(user, BOUNTY);
        return _placeStopLimit(user, isLong, size, _withBounty(triggerPrice, BOUNTY), limitPrice);
    }

    function _placeStopLossWithBounty(
        address user,
        bool isLong,
        uint256 size,
        uint256 triggerPrice,
        uint256 maxSlippageBp
    ) internal returns (uint256) {
        _approveWallet(user, BOUNTY);
        return _placeStopLoss(user, isLong, size, _withBounty(triggerPrice, BOUNTY), maxSlippageBp);
    }

    // ============================================================
    // Resting-untriggered lifecycle
    // ============================================================

    function test_untriggeredStopLimit_restsOutsideBook() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        // Buy stop: fires at price >= 51_500; oracle prints 50k at creation → untriggered.
        uint256 id = _placeStopLimit(alice, true, BTC / 10, 51_500 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);

        assertFalse(_inBook(id), "untriggered stop is not in the book");
        assertEq(_canceledBlock(id), 0);
        (uint64 bidHead,,,) = pair.book();
        assertEq(bidHead, 0, "book stays empty");
    }

    function test_executeTrigger_notMet_silentSkip_noBounty() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 id = _placeStopLimitWithBounty(alice, true, BTC / 10, 51_500 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);
        uint256 collBefore = _posCollateral(alice);

        assertEq(_executeTriggerAt(id, 51_000), 0, "unmet trigger is skipped");
        assertFalse(_inBook(id), "still untriggered");
        assertEq(_canceledBlock(id), 0, "still live");
        assertEq(_posCollateral(alice), collBefore, "collateral untouched by a skip");
        assertEq(_escrowOwed(seq), 0, "no bounty earned on a skip");
    }

    function test_executeTrigger_stopLimit_armsIntoBook_paysBounty() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 id = _placeStopLimitWithBounty(alice, true, BTC / 10, 51_500 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);
        uint256 collBefore = _posCollateral(alice);
        assertEq(_executeTriggerAt(id, 51_600), 1, "trigger met, stop fired");
        assertTrue(_inBook(id), "armed StopLimit rests in the book");
        assertEq(_posCollateral(alice), collBefore, "collateral is never charged for a keeper");
        assertEq(_claimFees(seq), BOUNTY_USDC, "keeper received the whole bounty for arming it");
        _assertBooks("after stop-limit arming");
    }

    function test_executeTrigger_inclusiveAtTriggerPrice() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 id = _placeStopLimit(alice, true, BTC / 10, 51_500 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);
        assertEq(_executeTriggerAt(id, 51_500), 1, "buy stop fires at exactly the trigger");
    }

    function test_executeTrigger_stopLoss_closesThroughBook() public {
        // Bob long 0.1 @ 51k entry; SL sell below 48k with a 1% slippage cap.
        _openPosition(bob, carol, true, BTC / 10);
        _deposit(dave, 30_000 * BAZAAR_SCALE);
        uint256 sl = _placeStopLossWithBounty(bob, false, BTC / 10, 48_000 * BAZAAR_SCALE, 100);

        // A resting bid gives the fired stop its liquidity.
        _placeLimitAt(dave, true, BTC / 10, 47_600 * BAZAAR_SCALE, 47_500);

        assertEq(_executeTriggerAt(sl, 47_500), 1, "sell stop fires below the trigger");

        assertEq(_filledSize(sl), BTC / 10, "stop filled against the resting bid");
        assertEq(_posSize(bob), 0, "position closed");
        assertEq(_stopLossOrderId(bob), 0, "SL slot cleared");
        assertEq(_claimFees(seq), BOUNTY_USDC, "keeper earned the whole bounty for a full close");
        // The dave fill price is the resting maker's: dave's long entered at his own bid.
        (, uint256 daveSize, uint256 daveEntry,,,,) = pair.positionBuckets(dave);
        assertEq(daveSize, BTC / 10);
        assertEq(daveEntry, 47_600 * BAZAAR_SCALE / 10, "filled at the maker's price");
        _assertBooks("after stop-loss execution");
    }

    /// @notice A stop fired into an empty book is not consumed: it stays live outside the book,
    ///         earns its keeper nothing, and closes on a later execution once liquidity exists.
    function test_executeTrigger_stopLoss_emptyBook_staysLive() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 sl = _placeStopLossWithBounty(bob, false, BTC / 10, 48_000 * BAZAAR_SCALE, 100);

        assertEq(_executeTriggerAt(sl, 47_500), 1, "stop fired even with no liquidity");
        assertEq(_filledSize(sl), 0, "nothing to fill");
        assertEq(_canceledBlock(sl), 0, "unfilled stop-loss stays live");
        assertFalse(_inBook(sl), "never rests");
        assertEq(_stopLossOrderId(bob), sl, "slot still bound");
        assertEq(_escrowOwed(seq), 0, "nothing filled, nothing earned");
        assertEq(_posSize(bob), BTC / 10, "position unchanged");

        // Liquidity arrives and the trigger still holds: the same order closes the position.
        _deposit(dave, 30_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 10, 47_600 * BAZAAR_SCALE, 47_500);
        assertEq(_executeTriggerAt(sl, 47_500), 1, "re-fired");
        assertEq(_posSize(bob), 0, "closed on the second execution");
        assertEq(_escrowOwed(seq), BOUNTY, "the completing keeper earns the bounty");
    }

    // ============================================================
    // Bounty edge cases
    // ============================================================

    /// @notice The bounty is escrowed from the wallet, so an owner whose collateral is nearly
    ///         gone still gets their stop executed, and the keeper is still paid.
    function test_executeTrigger_thinCollateral_stillExecutes_collateralUntouched() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 id = _placeStopLimitWithBounty(alice, true, BTC / 10, 51_500 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);

        // Strip alice's collateral to dust.
        BucketStore.setCollateral(address(pair), alice, uint256(1e17));

        assertEq(_executeTriggerAt(id, 51_600), 1, "executes regardless of collateral");
        assertTrue(_inBook(id), "armed");
        assertEq(_posCollateral(alice), 1e17, "collateral untouched");
        assertEq(_escrowOwed(seq), BOUNTY, "keeper paid from the escrow");
    }

    function test_immediateArm_atCreation_bountyReturnsToOwner() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 collAfterDeposit = _posCollateral(alice);
        uint256 walletBefore = usdc.balanceOf(alice);

        // Buy stop whose trigger the fresh $50k print already meets → arms in the creation tx.
        uint256 id = _placeStopLimitWithBounty(alice, true, BTC / 10, 49_000 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);

        assertTrue(_inBook(id), "already-triggered stop arms at creation");
        assertEq(_posCollateral(alice), collAfterDeposit, "no keeper, collateral untouched");
        assertEq(usdc.balanceOf(alice), walletBefore - BOUNTY_USDC, "bounty was pulled at creation");
        assertEq(_escrowOwed(alice), BOUNTY, "and credited straight back to the owner: nobody to pay");
        assertEq(_escrowOwed(seq), 0);
    }

    // ============================================================
    // Skips and batch shape
    // ============================================================

    function test_executeTrigger_skipsIneligibleIds() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 restingLimit = _placeLimit(alice, true, BTC / 10, 49_000 * BAZAAR_SCALE);
        uint256 armed = _placeStopLimit(alice, true, BTC / 20, 49_500 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);
        assertTrue(_inBook(armed), "armed at creation (trigger already met)");

        bytes[] memory pu = _freshPrice();
        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](3);
        execs[0].orderId = uint64(restingLimit); // wrong type
        execs[1].orderId = uint64(armed); // already in the book
        execs[2].orderId = 9_999; // nonexistent
        vm.prank(seq);
        assertEq(pair.executeTriggeredOrders(execs, pu), 0, "every ineligible id skipped silently");
        assertEq(_canceledBlock(restingLimit), 0, "resting limit untouched");
        assertTrue(_inBook(armed), "armed stop untouched");
    }

    function test_executeTrigger_batchShapeBounds() public {
        bytes[] memory pu = _freshPrice();
        BazaarTypes.TriggerExec[] memory tooMany =
            new BazaarTypes.TriggerExec[](BazaarTypes.MAX_TRIGGER_EXECS_PER_CALL + 1);
        vm.prank(seq);
        vm.expectRevert(
            abi.encodeWithSelector(MatchingEngineLib.MatchingEngineLib__InvalidTriggerBatch.selector, tooMany.length)
        );
        pair.executeTriggeredOrders(tooMany, pu);

        bytes[] memory pu2 = _freshPrice();
        BazaarTypes.TriggerExec[] memory none = new BazaarTypes.TriggerExec[](0);
        vm.prank(seq);
        vm.expectRevert(abi.encodeWithSelector(MatchingEngineLib.MatchingEngineLib__InvalidTriggerBatch.selector, 0));
        pair.executeTriggeredOrders(none, pu2);
    }

    function test_executeTrigger_twoStopsOneCall_bothFire() public {
        _openPosition(bob, carol, true, BTC / 10);
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 30_000 * BAZAAR_SCALE);

        // Alice's entry stop (buy StopLimit) + bob's protective StopLoss, both triggered by the
        // same downtick... a buy stop triggers on the way UP, so give alice a sell-side
        // StopLimit instead: sell at >= 47_800 once price <= 48_000.
        uint256 aliceStop = _placeStopLimit(alice, false, BTC / 10, 48_000 * BAZAAR_SCALE, 47_800 * BAZAAR_SCALE);
        uint256 bobSl = _placeStopLoss(bob, false, BTC / 10, 48_000 * BAZAAR_SCALE, 100);

        // Liquidity for bob's stop-loss.
        _placeLimitAt(dave, true, BTC / 5, 47_900 * BAZAAR_SCALE, 47_500);

        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(47_500, uint64(vm.getBlockTimestamp()));
        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](2);
        execs[0].orderId = uint64(aliceStop);
        execs[1].orderId = uint64(bobSl);
        vm.prank(seq);
        assertEq(pair.executeTriggeredOrders(execs, pu), 2, "both stops fired in one call");

        // Alice's armed sell StopLimit at 47_800 crossed dave's 47_900 bid and filled.
        assertEq(_filledSize(aliceStop), BTC / 10, "armed stop-limit filled on arrival");
        assertEq(_filledSize(bobSl), BTC / 10, "stop-loss filled");
        assertEq(_posSize(bob), 0, "bob closed");
        _assertBooks("after double trigger execution");
    }

    /// @notice A keeper cannot use its step budget to truncate someone else's stop: honouring a
    ///         caller-chosen `maxSteps` would let anyone fill a protective stop against one dust
    ///         node and leave the rest waiting. The stop's owner never authorised this caller, so
    ///         the budget is always the protocol default.
    function test_executeTrigger_keeperMaxStepsCannotTruncateStop() public {
        _openPosition(bob, carol, true, BTC / 2); // bob long 0.5
        _deposit(dave, 200_000 * BAZAAR_SCALE);
        _deposit(alice, 200_000 * BAZAAR_SCALE);
        uint256 sl = _placeStopLoss(bob, false, BTC / 2, 48_000 * BAZAAR_SCALE, 500);

        // Two resting bids: a dust node at the top of book, then real liquidity behind it.
        _placeLimitAt(alice, true, BTC / 100, 47_900 * BAZAAR_SCALE, 47_500);
        _placeLimitAt(dave, true, BTC / 2, 47_800 * BAZAAR_SCALE, 47_500);

        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(47_500, uint64(vm.getBlockTimestamp()));
        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](1);
        execs[0].orderId = uint64(sl);
        execs[0].hints.maxSteps = 1; // a hostile keeper asking for one node only

        vm.prank(seq);
        assertEq(pair.executeTriggeredOrders(execs, pu), 1, "stop fired");

        // The walk ran to the protocol default, not the keeper's budget: the stop closed the
        // whole position instead of stopping after the dust fill.
        assertEq(_filledSize(sl), BTC / 2, "stop filled in full despite maxSteps = 1");
        assertEq(_posSize(bob), 0, "position fully protected");
    }

    // ============================================================
    // TakeProfit: the mirrored trigger
    // ============================================================

    /// @notice A take-profit fires when the market moves IN FAVOUR of the position, the mirror of
    ///         a stop. For a long that means a sell target ABOVE the market: unreached below it,
    ///         live at or above it.
    function test_takeProfit_long_firesOnlyWhenPriceRisesToTarget() public {
        _openPosition(bob, carol, true, BTC / 10); // bob long 0.1 @ 51k
        uint256 tp = _placeTakeProfit(bob, false, BTC / 10, 52_000 * BAZAAR_SCALE, 500);
        assertFalse(_inBook(tp), "waits outside the book");

        // Below the target: not reached. A stop with these same arguments WOULD fire here, which
        // is exactly the direction this test pins.
        assertEq(_executeTriggerAt(tp, 51_000), 0, "not fired below the target");
        assertEq(_canceledBlock(tp), 0, "still live");

        // At the target: fires (inclusive), and takes market-style against resting liquidity.
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 10, 51_900 * BAZAAR_SCALE, 52_000);
        assertEq(_executeTriggerAt(tp, 52_000), 1, "fires at exactly the target");
        assertEq(_filledSize(tp), BTC / 10, "closed against the resting bid");
        assertEq(_posSize(bob), 0, "position closed");
        assertEq(_takeProfitOrderId(bob), 0, "TP slot cleared");
    }

    /// @notice The short mirror: a take-profit buy targets a price BELOW the market.
    function test_takeProfit_short_firesOnlyWhenPriceFallsToTarget() public {
        _openPosition(bob, carol, false, BTC / 10); // bob short 0.1
        uint256 tp = _placeTakeProfit(bob, true, BTC / 10, 48_000 * BAZAAR_SCALE, 500);

        assertEq(_executeTriggerAt(tp, 49_000), 0, "not fired above the target");
        assertEq(_canceledBlock(tp), 0, "still live");

        _deposit(dave, 60_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, false, BTC / 10, 48_100 * BAZAAR_SCALE, 48_000);
        assertEq(_executeTriggerAt(tp, 48_000), 1, "fires at exactly the target");
        assertEq(_filledSize(tp), BTC / 10, "closed against the resting ask");
        assertEq(_posSize(bob), 0, "position closed");
    }

    /// @notice A take-profit whose target the current price already satisfies arms in its own
    ///         creation transaction, with no keeper — same as a stop.
    function test_takeProfit_targetAlreadyReached_executesAtCreation() public {
        _openPosition(bob, carol, true, BTC / 10);
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        _placeLimit(dave, true, BTC / 10, 49_900 * BAZAAR_SCALE); // liquidity at the market

        uint256 collBefore = _posCollateral(bob);
        uint256 keeperBefore = usdc.balanceOf(seq);
        // Target $49k, market $50k: already satisfied for a long's sell target.
        uint256 tp = _placeTakeProfit(bob, false, BTC / 10, 49_000 * BAZAAR_SCALE, 500);

        assertEq(_filledSize(tp), BTC / 10, "executed in the creation transaction");
        assertEq(_posSize(bob), 0, "position closed");
        assertEq(usdc.balanceOf(seq), keeperBefore, "no keeper involved");
        assertGt(collBefore, 0);
    }

    /// @notice Market-style execution: an unfilled remainder never rests as book liquidity. It
    ///         stays live outside the book instead, still bound to the position's slot.
    function test_takeProfit_remainderStaysLive_neverRests() public {
        _openPosition(bob, carol, true, BTC / 10);
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        uint256 tp = _placeTakeProfit(bob, false, BTC / 10, 52_000 * BAZAAR_SCALE, 500);

        // Only a fraction of the size is available at the target.
        _placeLimitAt(dave, true, BTC / 100, 51_900 * BAZAAR_SCALE, 52_000);
        assertEq(_executeTriggerAt(tp, 52_000), 1, "fired");

        assertEq(_filledSize(tp), BTC / 100, "filled only what the book offered");
        assertEq(_canceledBlock(tp), 0, "remainder stays live");
        assertFalse(_inBook(tp), "never rests");
        assertEq(_takeProfitOrderId(bob), tp, "slot still bound");
        assertEq(_posSize(bob), BTC / 10 - BTC / 100, "the rest of the position survives");
    }

    /// @notice A thin book leaves the position PARTIALLY closed and the take-profit armed for
    ///         the rest: it fires again once the book can absorb more, and the slot stays taken
    ///         until it completes or the owner cancels it.
    function test_takeProfit_partialFill_staysArmedForTheRemainder() public {
        _openPosition(bob, carol, true, BTC / 10);
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        uint256 tp = _placeTakeProfit(bob, false, BTC / 10, 52_000 * BAZAAR_SCALE, 500);
        assertEq(_takeProfitOrderId(bob), tp, "slot armed");

        // Only a tenth of the size is bid at the target.
        _placeLimitAt(dave, true, BTC / 100, 51_900 * BAZAAR_SCALE, 52_000);
        assertEq(_executeTriggerAt(tp, 52_000), 1, "fired");

        uint256 remainder = BTC / 10 - BTC / 100;
        assertEq(_posSize(bob), remainder, "position only partially closed");
        assertEq(_canceledBlock(tp), 0, "take-profit is still live for the remainder");
        assertEq(_takeProfitOrderId(bob), tp, "slot still taken");

        // The slot is occupied, so a replacement is refused until this one is gone.
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.TakeProfit;
        s.isLong = false;
        s.size = remainder;
        s.triggerPrice = 53_000 * BAZAAR_SCALE;
        s.maxSlippageBp = 500;
        vm.prank(bob);
        vm.expectRevert(OrderManagementLib.OrderManagementLib__TpSlOrderAlreadyExists.selector);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");

        // Back at the target with depth behind it, the same order finishes the close.
        _placeLimitAt(dave, true, remainder, 51_900 * BAZAAR_SCALE, 52_000);
        assertEq(_executeTriggerAt(tp, 52_000), 1, "re-fired");
        assertEq(_posSize(bob), 0, "flat");
        assertEq(_filledSize(tp), BTC / 10, "closed the whole written size across two executions");
        assertEq(_takeProfitOrderId(bob), 0, "slot freed on completion");
    }

    // ============================================================
    // type(uint256).max: close the whole position, resolved when it fires
    // ============================================================

    /// @notice A max-sized take-profit closes whatever the position holds AT FIRE TIME, not at
    ///         creation. Resolving at creation would have frozen this order at 0.1 and left the
    ///         half it grew into uncovered.
    function test_takeProfit_maxSize_closesPositionGrownAfterCreation() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 tp = _placeTakeProfit(bob, false, type(uint256).max, 52_000 * BAZAAR_SCALE, 500);

        _openPosition(bob, carol, true, BTC / 10); // grow to 0.2
        assertEq(_posSize(bob), BTC / 5, "position doubled after the TP was written");

        _deposit(dave, 120_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 5, 51_900 * BAZAAR_SCALE, 52_000);
        assertEq(_executeTriggerAt(tp, 52_000), 1, "fired");

        assertEq(_filledSize(tp), BTC / 5, "closed the grown position in full");
        assertEq(_posSize(bob), 0, "flat");
    }

    /// @notice The mirror: a position that shrank is closed at its smaller size, and the order is
    ///         never cancelled for being oversized on the way there.
    function test_takeProfit_maxSize_closesPositionShrunkAfterCreation() public {
        _openPosition(bob, carol, true, BTC / 5);
        uint256 tp = _placeTakeProfit(bob, false, type(uint256).max, 52_000 * BAZAAR_SCALE, 500);

        // Shrink to 0.1 through an ordinary close.
        _deposit(dave, 120_000 * BAZAAR_SCALE);
        _placeLimit(bob, false, BTC / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(dave, true, BTC / 10, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(bob), BTC / 10, "shrunk to 0.1");
        assertEq(_canceledBlock(tp), 0, "TP survived the shrink");

        _placeLimitAt(dave, true, BTC / 5, 51_900 * BAZAAR_SCALE, 52_000);
        assertEq(_executeTriggerAt(tp, 52_000), 1, "fired");
        assertEq(_filledSize(tp), BTC / 10, "closed only what was left");
        assertEq(_posSize(bob), 0, "flat, not flipped short");
    }

    /// @notice Capping bounds the CLOSE and is re-resolved on every execution: after a thin
    ///         first fill the order's remainder is capped to what the position holds at the
    ///         next fire, so a max-sized order still closes a position that GREW in between —
    ///         the stored size keeps the "all of it" intent, and the earlier fill is not counted
    ///         against the position a second time.
    function test_takeProfit_maxSize_thinBook_refiresForTheLivePosition() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 tp = _placeTakeProfit(bob, false, type(uint256).max, 52_000 * BAZAAR_SCALE, 500);

        _deposit(dave, 60_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 100, 51_900 * BAZAAR_SCALE, 52_000);
        assertEq(_executeTriggerAt(tp, 52_000), 1, "fired");

        assertEq(_filledSize(tp), BTC / 100, "filled only what the book offered");
        assertEq(_orderSize(tp), type(uint128).max, "stored size keeps the close-everything intent");
        assertEq(_posSize(bob), BTC / 10 - BTC / 100, "the rest of the position survives");
        assertEq(_canceledBlock(tp), 0, "still armed");
        assertEq(_takeProfitOrderId(bob), tp, "slot still bound");

        // The position grows before the next fire, and the book is deep now.
        _openPosition(bob, carol, true, BTC / 10);
        assertEq(_posSize(bob), BTC / 5 - BTC / 100, "grown");
        _placeLimitAt(dave, true, BTC / 5, 51_900 * BAZAAR_SCALE, 52_000);
        assertEq(_executeTriggerAt(tp, 52_000), 1, "re-fired");
        assertEq(_posSize(bob), 0, "flat: the remainder was sized to the live, grown position");
        assertEq(_filledSize(tp), BTC / 5, "closed everything across two executions");
        assertEq(_takeProfitOrderId(bob), 0, "slot freed on completion");
    }

    /// @notice A stop whose position vanished before the keeper reached it is cancelled instead
    ///         of filling: it has nothing to reduce, and taking here would OPEN a short.
    function test_stopLoss_positionAlreadyFlat_cancelsInsteadOfOpening() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 sl = _placeStopLoss(bob, false, BTC / 10, 49_000 * BAZAAR_SCALE, 500);

        // Close the position by hand, which strands the stop.
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        _placeLimit(bob, false, BTC / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(dave, true, BTC / 10, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(bob), 0, "flat");

        assertEq(_executeTriggerAt(sl, 49_000), 0, "stranded stop does not fire");
        assertEq(_posSize(bob), 0, "no short opened");
        assertGt(_canceledBlock(sl), 0, "stop canceled");
    }

    /// @notice The idiom works the same for a stop: it closes whatever the position holds when
    ///         the stop fires, not what it held when the stop was written.
    function test_stopLoss_maxSize_closesWholePositionAtFireTime() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 sl = _placeStopLoss(bob, false, type(uint256).max, 48_000 * BAZAAR_SCALE, 500);

        _openPosition(bob, carol, true, BTC / 10); // grow to 0.2 after the stop was written
        assertEq(_posSize(bob), BTC / 5, "position doubled");

        _deposit(dave, 60_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 5, 47_600 * BAZAAR_SCALE, 47_500);
        assertEq(_executeTriggerAt(sl, 47_500), 1, "stop fired");

        assertEq(_filledSize(sl), BTC / 5, "closed the grown position in full");
        assertEq(_posSize(bob), 0, "flat");
    }

    /// @notice An oversized TP is NOT clamped at creation — only when it fires. So a position
    ///         grown after the order was written is covered by it, with no cancel-and-replace:
    ///         0.15 written against a 0.1 position closes the 0.11 that exists at fire time.
    function test_takeProfit_oversized_coversPositionGrownLater_withoutReplacing() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 tp = _placeTakeProfit(bob, false, 15 * BTC / 100, 52_000 * BAZAAR_SCALE, 500);
        assertEq(_orderSize(tp), 15 * BTC / 100, "stored as written, not clamped to the position");

        _openPosition(bob, carol, true, BTC / 100); // grow 0.1 -> 0.11
        assertEq(_posSize(bob), 11 * BTC / 100, "position grew after the TP was written");

        _deposit(dave, 120_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 5, 51_900 * BAZAAR_SCALE, 52_000);
        assertEq(_executeTriggerAt(tp, 52_000), 1, "fired");

        assertEq(_filledSize(tp), 11 * BTC / 100, "covered the grown position in full");
        assertEq(_posSize(bob), 0, "flat");
    }

    /// @notice The written size is still the ceiling: growth beyond it is NOT covered, which is
    ///         the whole reason type(uint256).max exists as the close-everything idiom.
    function test_takeProfit_oversized_doesNotCoverGrowthBeyondItsOwnSize() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 tp = _placeTakeProfit(bob, false, 15 * BTC / 100, 52_000 * BAZAAR_SCALE, 500);

        _openPosition(bob, carol, true, BTC / 10); // grow 0.1 -> 0.2, past the TP's 0.15
        assertEq(_posSize(bob), BTC / 5, "position now exceeds the order");

        _deposit(dave, 120_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 5, 51_900 * BAZAAR_SCALE, 52_000);
        assertEq(_executeTriggerAt(tp, 52_000), 1, "fired");

        assertEq(_filledSize(tp), 15 * BTC / 100, "closed only what the order asked for");
        assertEq(_posSize(bob), 5 * BTC / 100, "0.05 left uncovered");
    }

    // ============================================================
    // Unreachable resting slot: skip, never revert
    // ============================================================

    /// @dev Rest `count` asks at consecutive whole-dollar prices just below `ceilingUsd`, placed
    ///      in descending price order so each becomes the new ask head and needs no hint. Split
    ///      across two fresh padders to stay under MAX_ACTIVE_LIMIT_ORDERS_PER_USER. Returns the
    ///      ids in placement order, so ids[0] is the highest-priced ask — the side's tail, and the
    ///      predecessor of any ask at `ceilingUsd`.
    function _padAsksBelow(uint256 ceilingUsd, uint256 count) internal returns (uint256[] memory ids) {
        address padA = makeAddr("padA");
        address padB = makeAddr("padB");
        usdc.mint(padA, INITIAL_USER_BALANCE);
        usdc.mint(padB, INITIAL_USER_BALANCE);
        _deposit(padA, 20_000 * BAZAAR_SCALE);
        _deposit(padB, 20_000 * BAZAAR_SCALE);
        ids = new uint256[](count);
        for (uint256 k = 1; k <= count; ++k) {
            address who = k <= count / 2 ? padA : padB;
            ids[k - 1] = _placeLimit(who, false, BTC / 1000, (ceilingUsd - k) * BAZAAR_SCALE);
        }
    }

    function _exec(uint256 orderId, uint64 pred) internal pure returns (BazaarTypes.TriggerExec memory e) {
        e.orderId = uint64(orderId);
        e.hints.pred = pred;
    }

    /// @dev Fire a keeper batch at a custom oracle price (warps +3s so the update is strictly newer).
    function _executeBatchAt(BazaarTypes.TriggerExec[] memory execs, uint256 priceUsd)
        internal
        returns (uint256 executedCount)
    {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(priceUsd, uint64(vm.getBlockTimestamp()));
        vm.prank(seq);
        executedCount = pair.executeTriggeredOrders(execs, pu);
    }

    /// @notice A StopLimit whose resting slot lies past MAX_WALK_STEPS from the keeper's hints is
    ///         skipped — untouched, its bounty unassigned — and the other owners' stops in the
    ///         batch still execute. The same stop arms once a keeper supplies a hint that reaches
    ///         the slot.
    function test_executeTrigger_unreachableSlot_skipsStop_batchSurvives() public {
        // Alice: sell StopLimit at 48_700, fires once the oracle is at or below 49_000.
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 stop = _placeStopLimitWithBounty(alice, false, BTC / 10, 49_000 * BAZAAR_SCALE, 48_700 * BAZAAR_SCALE);
        // Bob: long 0.1 with a sell StopLoss at 49_000; dave's bid is its liquidity.
        _openPosition(bob, carol, true, BTC / 10);
        uint256 sl = _placeStopLossWithBounty(bob, false, BTC / 10, 49_000 * BAZAAR_SCALE, 100);
        // MAX_WALK_STEPS + 2 asks between the head and alice's slot: from the head anchor the
        // slot is one advance past the cap.
        uint256[] memory pad = _padAsksBelow(48_700, BazaarTypes.MAX_WALK_STEPS + 2);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 10, 48_400 * BAZAAR_SCALE, 48_500);

        uint256 aliceCollBefore = _posCollateral(alice);
        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](2);
        execs[0] = _exec(stop, 0); // no hint: the anchor is the head
        execs[1] = _exec(sl, 0);
        assertEq(_executeBatchAt(execs, 48_500), 1, "only bob's stop executed");

        // Alice's stop is exactly as it was.
        assertFalse(_inBook(stop), "not armed");
        assertEq(_canceledBlock(stop), 0, "not canceled");
        assertEq(_filledSize(stop), 0, "nothing filled");
        assertEq(_posCollateral(alice), aliceCollBefore, "collateral untouched by the skip");
        // Bob's stop went through, untouched by alice's stale hint.
        assertEq(_filledSize(sl), BTC / 10, "stop-loss filled");
        assertEq(_posSize(bob), 0, "bob flat");
        assertEq(_escrowOwed(seq), BOUNTY, "one bounty earned: bob's");

        // Positive control: the padding's tail is the exact predecessor, and arming is O(1).
        execs = new BazaarTypes.TriggerExec[](1);
        execs[0] = _exec(stop, uint64(pad[0]));
        assertEq(_executeBatchAt(execs, 48_500), 1, "armed with a reaching hint");
        assertTrue(_inBook(stop), "rests in the book");
        assertEq(uint256(OrderView.order(pair, stop).prevInBook), pad[0], "behind the highest padding ask");
        assertEq(uint256(OrderView.order(pair, stop).nextInBook), 0, "at the tail");
        assertEq(uint256(OrderView.order(pair, pad[0]).nextInBook), stop, "padding tail links forward to it");
        assertEq(_posCollateral(alice), aliceCollBefore, "collateral untouched when it armed");
        assertEq(_escrowOwed(seq), 2 * BOUNTY, "alice's bounty earned when it actually armed");
        (,,, uint64 askCount) = pair.book();
        assertEq(uint256(askCount), pad.length + 1, "ask count");
        _assertBooks("after hinted arming");
    }

    /// @notice A StopLimit that fills part of its size rests the remainder at the head of its
    ///         side: anything on that side priced at or better than the fill it just took would
    ///         have crossed the same liquidity, so no predecessor can exist. Hints are irrelevant
    ///         to a head placement, so a hint naming an order that sorts after it cannot fail the
    ///         exec.
    function test_executeTrigger_stopLimit_partialFill_restsAtHead() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 stop = _placeStopLimit(alice, false, BTC / 5, 49_000 * BAZAAR_SCALE, 48_700 * BAZAAR_SCALE);
        // Two asks above alice's limit: they sit behind her once she rests.
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 ask1 = _placeLimit(carol, false, BTC / 100, 48_800 * BAZAAR_SCALE);
        uint256 ask2 = _placeLimit(carol, false, BTC / 100, 48_900 * BAZAAR_SCALE);
        // Half of alice's size in crossing bids.
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, BTC / 10, 48_750 * BAZAAR_SCALE, 48_500);

        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](1);
        execs[0] = _exec(stop, uint64(ask2)); // sorts AFTER alice: not a valid predecessor
        assertEq(_executeBatchAt(execs, 48_500), 1, "fired");

        assertEq(_filledSize(stop), BTC / 10, "half filled against dave's bid");
        assertTrue(_inBook(stop), "remainder rests");
        (, uint64 askHead,,) = pair.book();
        assertEq(uint256(askHead), stop, "at the head of the ask side");
        assertEq(uint256(OrderView.order(pair, stop).nextInBook), ask1, "ahead of the 48_800 ask");
        assertEq(uint256(OrderView.order(pair, ask1).prevInBook), stop, "48_800 ask links back to it");
        (bool isLong, uint256 size) = _position(alice);
        assertFalse(isLong, "alice is short");
        assertEq(size, BTC / 10, "the filled half");
        _assertBooks("after partial-fill arming");
    }

    /// @notice A hint a few nodes short of the slot is repaired by the bounded walk, the same way
    ///         createOrder repairs its own: the stop rests exactly where an exact hint would put
    ///         it.
    function test_executeTrigger_nearMissHint_repairsAndRests() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 stop = _placeStopLimit(alice, false, BTC / 10, 49_000 * BAZAAR_SCALE, 48_700 * BAZAAR_SCALE);
        uint256[] memory pad = _padAsksBelow(48_700, 5); // 48_699 (tail) .. 48_695 (head)

        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](1);
        execs[0] = _exec(stop, uint64(pad[2])); // 48_697: two advances short of the slot
        assertEq(_executeBatchAt(execs, 48_500), 1, "fired");

        assertTrue(_inBook(stop), "rests");
        assertEq(uint256(OrderView.order(pair, stop).prevInBook), pad[0], "behind the 48_699 ask");
        assertEq(uint256(OrderView.order(pair, stop).nextInBook), 0, "tail");
        _assertBooks("after near-miss arming");
    }
}
