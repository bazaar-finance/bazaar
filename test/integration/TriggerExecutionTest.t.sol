// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MatchingEngineLib} from "../../src/libraries/MatchingEngineLib.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

/// @title TriggerExecutionTest
/// @notice StopLimit/StopLoss lifecycle under keeper execution: untriggered stops rest outside
///         the book until a permissionless executeTriggeredOrders call fires them against a
///         fresh oracle price, charging the owner the flat TRIGGER_TIP; a stop whose trigger a
///         fresh price already meets at creation arms immediately with no keeper and no tip.
contract TriggerExecutionTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BTC = 1e18;
    uint256 constant TIP = 0.25e18; // BazaarTypes.TRIGGER_TIP
    uint256 constant TIP_USDC = 0.25e6;

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

    function test_executeTrigger_notMet_silentSkip_noTip() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 id = _placeStopLimit(alice, true, BTC / 10, 51_500 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);
        uint256 collBefore = _posCollateral(alice);

        assertEq(_executeTriggerAt(id, 51_000), 0, "unmet trigger is skipped");
        assertFalse(_inBook(id), "still untriggered");
        assertEq(_canceledBlock(id), 0, "still live");
        assertEq(_posCollateral(alice), collBefore, "no tip charged on a skip");
    }

    function test_executeTrigger_stopLimit_armsIntoBook_chargesTip() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 id = _placeStopLimit(alice, true, BTC / 10, 51_500 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);
        uint256 collBefore = _posCollateral(alice);
        uint256 keeperBefore = usdc.balanceOf(seq);

        assertEq(_executeTriggerAt(id, 51_600), 1, "trigger met, stop fired");
        assertTrue(_inBook(id), "armed StopLimit rests in the book");
        assertEq(_posCollateral(alice), collBefore - TIP, "owner paid the tip");
        assertEq(usdc.balanceOf(seq), keeperBefore + TIP_USDC, "keeper received the tip");
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
        uint256 sl = _placeStopLoss(bob, false, BTC / 10, 48_000 * BAZAAR_SCALE, 100);

        // A resting bid gives the fired stop its liquidity.
        _placeLimitAt(dave, true, BTC / 10, 47_600 * BAZAAR_SCALE, 47_500);

        uint256 keeperBefore = usdc.balanceOf(seq);
        assertEq(_executeTriggerAt(sl, 47_500), 1, "sell stop fires below the trigger");

        assertEq(_filledSize(sl), BTC / 10, "stop filled against the resting bid");
        assertEq(_posSize(bob), 0, "position closed");
        assertEq(_stopLossOrderId(bob), 0, "SL slot cleared");
        assertEq(usdc.balanceOf(seq), keeperBefore + TIP_USDC, "keeper tipped");
        // The dave fill price is the resting maker's: dave's long entered at his own bid.
        (, uint256 daveSize, uint256 daveEntry,,,,,,) = pair.positionBuckets(dave);
        assertEq(daveSize, BTC / 10);
        assertEq(daveEntry, 47_600 * BAZAAR_SCALE / 10, "filled at the maker's price");
        _assertBooks("after stop-loss execution");
    }

    function test_executeTrigger_stopLoss_emptyBook_cancelsRemainder() public {
        _openPosition(bob, carol, true, BTC / 10);
        uint256 sl = _placeStopLoss(bob, false, BTC / 10, 48_000 * BAZAAR_SCALE, 100);

        assertEq(_executeTriggerAt(sl, 47_500), 1, "stop fired even with no liquidity");
        assertEq(_filledSize(sl), 0, "nothing to fill");
        assertGt(_canceledBlock(sl), 0, "unfilled stop-loss remainder cancels");
        assertEq(_posSize(bob), BTC / 10, "position unchanged; liquidation remains the backstop");
    }

    // ============================================================
    // Tip edge cases
    // ============================================================

    function test_executeTrigger_ownerCannotCoverTip_autoCancels() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 id = _placeStopLimit(alice, true, BTC / 10, 51_500 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);

        // Strip alice's collateral below the tip.
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(alice).depth(3).checked_write(
            uint256(1e17)
        );

        uint256 keeperBefore = usdc.balanceOf(seq);
        assertEq(_executeTriggerAt(id, 51_600), 0, "uncoverable tip does not execute");
        assertGt(_canceledBlock(id), 0, "stop auto-canceled instead");
        assertFalse(_inBook(id));
        assertEq(usdc.balanceOf(seq), keeperBefore, "no tip paid for a cancel");
    }

    function test_immediateArm_atCreation_noTip() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 collAfterDeposit = _posCollateral(alice);

        // Buy stop whose trigger the fresh $50k print already meets → arms in the creation tx.
        uint256 id = _placeStopLimit(alice, true, BTC / 10, 49_000 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);

        assertTrue(_inBook(id), "already-triggered stop arms at creation");
        assertEq(_posCollateral(alice), collAfterDeposit, "no keeper, no tip");
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
            abi.encodeWithSelector(
                MatchingEngineLib.MatchingEngineLib__InvalidTriggerBatch.selector, tooMany.length
            )
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

        vm.warp(vm.getBlockTimestamp() + 3);
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

    /// @notice A keeper cannot use its step budget to truncate someone else's stop. Hitting the
    ///         cap mid-cross cancels the remainder, so honouring a caller-chosen `maxSteps` here
    ///         would let anyone fill a protective stop against one dust node and destroy the
    ///         rest of it — for a $0.25 tip paid by the victim. The stop's owner never
    ///         authorised this caller, so the budget is always the protocol default.
    function test_executeTrigger_keeperMaxStepsCannotTruncateStop() public {
        _openPosition(bob, carol, true, BTC / 2); // bob long 0.5
        _deposit(dave, 200_000 * BAZAAR_SCALE);
        _deposit(alice, 200_000 * BAZAAR_SCALE);
        uint256 sl = _placeStopLoss(bob, false, BTC / 2, 48_000 * BAZAAR_SCALE, 500);

        // Two resting bids: a dust node at the top of book, then real liquidity behind it.
        _placeLimitAt(alice, true, BTC / 100, 47_900 * BAZAAR_SCALE, 47_500);
        _placeLimitAt(dave, true, BTC / 2, 47_800 * BAZAAR_SCALE, 47_500);

        vm.warp(vm.getBlockTimestamp() + 3);
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
}
