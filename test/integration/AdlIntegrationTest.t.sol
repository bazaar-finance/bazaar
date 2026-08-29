// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {IntegrationBase} from "./IntegrationBase.sol";

/// @title AdlIntegrationTest
/// @notice Full ADL lifecycle on the live pair: a deep-underwater liquidation hands the vault an
///         exposure whose expected loss exceeds 80% of the insurance fund → ADL triggers (freezing
///         trading) → once the auction's score threshold decays the opposite-side winner is
///         deleveraged at the vault's bankruptcy price, insurance funds the credit, the vault
///         exposure clears, and the margin curve is recomputed on completion.
contract AdlIntegrationTest is IntegrationBase {
    function test_e2e_Adl_TriggersOnDeepLiquidation_AndDeleveragesWinner() public {
        // Real matched pair: alice long 5 / bob short 5, filled at alice's resting $51k limit.
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        _deposit(bob, 60_000 * BAZAAR_SCALE);
        uint256 size = 5 * BAZAAR_SCALE;
        _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), size, "5 BTC opened at $51k");
        _assertBooksSettled("adl: after open");

        // Phantom deep-underwater long for dave: bankruptcy price $50,990/BTC → at the $50k oracle the
        // vault-inherited loss is (254,950 − 250,000) = $4,950 > 80% of the ~$4k insurance fund.
        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, size, 254_960 * BAZAAR_SCALE);
        // _writePosition only rewrites size/entryValue (not collateral), so the cash books still balance.
        _assertBooksSettled("adl: after phantom write");

        vm.recordLogs(); // capture the AdlTriggered event emitted inside this liquidate
        vm.prank(carol);
        assertEq(pair.liquidate(_arr1(dave), _freshPrice()), 1, "dave liquidated");
        _assertBooks("adl: after deep liquidation");

        // The same liquidate call re-evaluated vault health → ADL pending, vault holds dave's long.
        assertTrue(pair.isAdlPending(), "ADL triggered by the deep-underwater inheritance");
        (,,,,,, uint256 pendSize,,,, bool pendIsLong,) = pair.pairVault();
        assertEq(pendSize, size, "vault inherited the 5 BTC");
        assertTrue(pendIsLong, "vault holds the long side");

        // The trigger announced the frozen ranking basis. The event must carry exactly what the
        // auxState() getter now reports — the two channels a keeper reads must agree, or the bot
        // would score against a different basis than the contract ranks with.
        (bool foundEv, uint64 evEpoch, uint256 evPrice, int256 evFunding) = _findAdlTriggered();
        assertTrue(foundEv, "AdlTriggered emitted on the false->true trigger");
        BazaarTypes.AuxState memory aux = pair.auxState();
        assertEq(evEpoch, uint64(1), "first window -> epoch 1");
        assertFalse(aux.adlLongs, "deleverage the shorts (vault holds the long)");
        assertEq(evPrice, aux.adlSnapshotPrice, "event snapshot price matches auxState");
        assertEq(evFunding, aux.adlSnapshotFundingIndex, "event frozen funding matches auxState");

        // Wait out the 10-minute auction (ADL_AUCTION_DURATION) so the score threshold collapses,
        // then deleverage bob — the short side (opposite the vault's inherited long), in profit at
        // the snapshot price.
        vm.warp(vm.getBlockTimestamp() + 15 minutes + 1);
        uint256 insBefore = _insuranceBal();
        uint256 bobCollBefore = _posCollateral(bob);
        bytes[] memory pu = _freshPrice();
        vm.prank(carol);
        pair.executeAdl(_arr1(bob), pu);
        _assertBooks("adl: after winner deleverage");

        assertFalse(pair.isAdlPending(), "ADL resolved");
        (,,,,,, uint256 pendAfter,,,,,) = pair.pairVault();
        assertEq(pendAfter, 0, "vault exposure fully closed");
        assertEq(_posSize(bob), 0, "bob deleveraged");
        assertGt(_posCollateral(bob), bobCollBefore, "bob credited settlement PnL at the bankruptcy price");
        assertLt(_insuranceBal(), insBefore, "insurance funded the winner credit");

        // ADL completion also refreshes the margin curve (the MMR-recompute wiring).
        (,, uint256 lastTs,) = pair.marginRequirements();
        assertEq(lastTs, vm.getBlockTimestamp(), "IMR/MMR recomputed on ADL completion");
    }

    /// @dev Scans the recorded logs for the pair's AdlTriggered event and decodes it.
    function _findAdlTriggered() internal returns (bool found, uint64 epoch, uint256 price, int256 funding) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("AdlTriggered(bytes32,uint64,uint256,int256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(pair) && logs[i].topics[0] == sig) {
                epoch = uint64(uint256(logs[i].topics[2])); // topic1 = pairId, topic2 = adlEpoch
                (price, funding) = abi.decode(logs[i].data, (uint256, int256));
                return (true, epoch, price, funding);
            }
        }
    }

    /// @notice A PARTIAL deleverage must leave the winner's close-only orders sized for the
    ///         position that survived. Without the fence, a TakeProfit written for the original
    ///         size stays live and oversized: a later arrival could fill it past flat and open a
    ///         fresh opposite position for its owner — the opposite of what a close-only order
    ///         may do — and a fired StopLoss could keep taking after its position was gone.
    function test_adl_partialClose_cancelsOversizedTakeProfit() public {
        // Bob builds a short of 8 across two fills, both at $51,000, so his entry basis matches
        // the single-fill scenario: 5 against alice, then 3 against carol. A winner LARGER than
        // the vault's inventory is what makes the deleverage partial.
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        _deposit(bob, 120_000 * BAZAAR_SCALE);
        _deposit(carol, 60_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, 5 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, 5 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, 3 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, 3 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(bob), 8 * BAZAAR_SCALE, "bob short 8 at a $51k basis");

        // Bob covers the whole short with a take-profit buy targeting $45k. It waits outside the
        // book until the oracle falls that far, so nothing in this scenario can fill it.
        uint256 tp = _placeTakeProfit(bob, true, 8 * BAZAAR_SCALE, 45_000 * BAZAAR_SCALE, 500);
        assertFalse(_inBook(tp), "TakeProfit waits outside the book");
        assertEq(_takeProfitOrderId(bob), tp, "TP slot anchored");

        // Deep-underwater long of 5: bankruptcy ≈ $50,990/BTC, so the vault's expected loss
        // (~$4,950) exceeds 80% of the fund and the settlement price stays just below bob's
        // entry — he settles at a small profit, which eligibility requires.
        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, 5 * BAZAAR_SCALE, 254_960 * BAZAAR_SCALE);
        vm.prank(carol);
        assertEq(pair.liquidate(_arr1(dave), _freshPrice()), 1, "dave liquidated");
        assertTrue(pair.isAdlPending(), "ADL triggered");
        {
            (,,,,,, uint256 pend,,,,,) = pair.pairVault();
            assertEq(pend, 5 * BAZAAR_SCALE, "vault inherited exactly 5 BTC");
        }
        assertEq(_canceledBlock(tp), 0, "TP untouched by the liquidation");

        vm.warp(vm.getBlockTimestamp() + 15 minutes + 1);
        bytes[] memory pu = _freshPrice();
        vm.prank(carol);
        pair.executeAdl(_arr1(bob), pu);

        assertFalse(pair.isPairTerminatedEmergency(), "pair survives the deleverage");
        assertEq(_posSize(bob), 3 * BAZAAR_SCALE, "bob partially deleveraged: 8 - 5");
        assertGt(_canceledBlock(tp), 0, "oversized TakeProfit canceled by the fence");
        assertEq(_takeProfitOrderId(bob), 0, "TP slot cleared");
        _assertBooks("adl: after partial deleverage");
    }
}
