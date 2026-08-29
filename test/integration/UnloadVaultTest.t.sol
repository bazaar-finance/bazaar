// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

/// @title UnloadVaultTest
/// @notice Vault liquidation inventory crossing into the resting book: the liquidation price
///         band (min(LIQ_MAX_SLIPPAGE_BP, MMR) around oracle), proportional aggregate
///         decrements, the inline unload at the end of liquidate(), and the permissionless
///         unloadVault caller reward with its anti-dust gate.
contract UnloadVaultTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BTC = 1e18;

    /// @dev Inject vault liquidation inventory directly (sizes in 1e18, prices in whole USD).
    ///      entryNotional/bankruptcyNotional land in 1e18 scale because size already carries it.
    function _setVaultPendingLiq(uint256 size, uint256 entryPriceUsd, uint256 bankruptcyPriceUsd, bool isLong)
        internal
    {
        _stdstore.target(address(pair)).sig("pairVault()").depth(6).checked_write(size);
        _stdstore.target(address(pair)).sig("pairVault()").depth(7).checked_write(size * entryPriceUsd);
        _stdstore.target(address(pair)).sig("pairVault()").depth(8).checked_write(size * bankruptcyPriceUsd);
        _stdstore.target(address(pair)).sig("pairVault()").depth(10).checked_write(isLong);
    }

    function _pendingLiqSize() internal view returns (uint256 s) {
        (,,,,,, s,,,,,) = pair.pairVault();
    }

    // ============================================================
    // Band + fills + aggregates
    // ============================================================

    function test_unload_fillsRestingBid_clearsInventory() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 49_900 * BAZAAR_SCALE);

        // Vault holds a 0.1 BTC long at a $50k basis.
        _setVaultPendingLiq(BTC / 10, 50_000, 48_000, true);

        assertEq(_unloadVault(), BTC / 10, "inventory fully unloaded");
        assertEq(_pendingLiqSize(), 0, "aggregate cleared");

        (, uint256 sz, uint256 entry,,,,,,) = pair.positionBuckets(carol);
        assertEq(sz, BTC / 10, "counterparty took the inventory over");
        assertEq(entry, 49_900 * BAZAAR_SCALE / 10, "filled at the resting maker's price");
    }

    function test_unload_stopsAtFirstOutOfBandMaker() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        // Band at warmup MMR (10%) is min(5%, 10%) = 5% → floor $47,500 at a $50k oracle.
        _placeLimit(carol, true, BTC / 10, 47_600 * BAZAAR_SCALE); // inside
        _placeLimit(dave, true, BTC / 10, 47_400 * BAZAAR_SCALE); // outside

        _setVaultPendingLiq(3 * BTC / 10, 50_000, 48_000, true);

        assertEq(_unloadVault(), BTC / 10, "only the in-band maker filled");
        assertEq(_pendingLiqSize(), 2 * BTC / 10, "remainder stays as vault inventory");
        assertEq(_posSize(dave), 0, "out-of-band maker untouched");
        assertTrue(_inBook(_newestLimitOrderId(dave)), "out-of-band maker still resting");
    }

    function test_unload_respectsStepBudget() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 49_900 * BAZAAR_SCALE);
        _placeLimit(dave, true, BTC / 10, 49_800 * BAZAAR_SCALE);

        _setVaultPendingLiq(3 * BTC / 10, 50_000, 48_000, true);

        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        assertEq(pair.unloadVault(1, pu), BTC / 10, "one node visited, one fill");
        assertEq(_pendingLiqSize(), 2 * BTC / 10);
        assertEq(_posSize(dave), 0, "second maker beyond the budget");
    }

    function test_unload_noInventory_noop() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 49_900 * BAZAAR_SCALE);
        assertEq(_unloadVault(), 0, "nothing to unload");
        assertEq(_posSize(carol), 0, "maker untouched");
    }

    function test_unload_shortInventory_walksAsks() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, false, BTC / 10, 50_100 * BAZAAR_SCALE); // resting ask, inside +5% band

        // Vault holds a short: it buys back from the ask side.
        _setVaultPendingLiq(BTC / 10, 50_000, 52_000, false);

        assertEq(_unloadVault(), BTC / 10);
        assertEq(_pendingLiqSize(), 0);
        (bool isLong, uint256 sz,,,,,,,) = pair.positionBuckets(carol);
        assertEq(sz, BTC / 10);
        assertFalse(isLong, "counterparty inherited the short side");
    }

    // ============================================================
    // Caller reward
    // ============================================================

    function test_unload_reward_paidAboveMinNotional() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 49_900 * BAZAAR_SCALE);
        _setVaultPendingLiq(BTC / 10, 49_900, 48_000, true); // entry == fill → zero vault PnL

        uint256 keeperBefore = usdc.balanceOf(seq);
        _unloadVault();

        // reward = max($0.25, 2bp × $4,990 unloaded) = $0.998 — the bps term binds here.
        uint256 expected = (BTC / 10) * 49_900 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE / 1e12;
        assertEq(usdc.balanceOf(seq) - keeperBefore, expected, "2bp-of-notional reward paid");
    }

    function test_unload_reward_floorApplies() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        // $499 unloaded → 2bp ≈ $0.0998, under the floor. Below the notional gate, but this call
        // CLEARS the inventory, which is the case the floor exists to pay for.
        _placeLimit(carol, true, BTC / 100, 49_900 * BAZAAR_SCALE);
        _setVaultPendingLiq(BTC / 100, 49_900, 48_000, true);

        uint256 keeperBefore = usdc.balanceOf(seq);
        _unloadVault();
        assertEq(_pendingLiqSize(), 0, "inventory cleared");
        assertEq(usdc.balanceOf(seq) - keeperBefore, 0.25e6, "$0.25 floor pays the clearing call");
    }

    /// @notice Below the notional gate, with inventory left over, the caller still earns the plain
    ///         bps rate — it just does not get the flat floor. A keeper that drains every in-band
    ///         maker on a thin book has done all the work available, and must not come away with
    ///         nothing merely because the inventory is larger than the book.
    function test_unload_reward_bpsPaidBelowGate_withoutFloor() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        // The book can only absorb ~$499 of a 1 BTC inventory: under the $1,250 gate, and the
        // inventory survives, so the bps term pays on its own.
        _placeLimit(carol, true, BTC / 100, 49_900 * BAZAAR_SCALE);
        _setVaultPendingLiq(BTC, 49_900, 48_000, true);

        uint256 keeperBefore = usdc.balanceOf(seq);
        assertEq(_unloadVault(), BTC / 100, "partial unload still executes");
        assertGt(_pendingLiqSize(), 0, "inventory remains");

        uint256 expected = (BTC / 100) * 49_900 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE / 1e12;
        uint256 paid = usdc.balanceOf(seq) - keeperBefore;
        assertEq(paid, expected, "2bp of the unloaded notional paid below the gate");
        assertLt(paid, 0.25e6, "and the flat floor was NOT applied");
    }

    /// @notice The property that makes paying below the gate safe: slicing an unload into
    ///         sub-gate calls earns no premium. Each call is paid the plain rate on what it
    ///         moved, so the total is the same however the work is divided — only a call that
    ///         clears the inventory or crosses the gate may add the flat floor, and that can
    ///         happen at most once per inventory.
    function test_unload_reward_slicingEarnsNoPremium() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 100, 49_900 * BAZAAR_SCALE);
        _placeLimit(dave, true, BTC / 100, 49_800 * BAZAAR_SCALE);
        _setVaultPendingLiq(BTC, 49_900, 48_000, true); // far larger than the book: never cleared

        uint256 firstBefore = usdc.balanceOf(seq);
        bytes[] memory pu1 = _freshPrice();
        vm.prank(seq);
        pair.unloadVault(1, pu1); // one node
        uint256 firstPaid = usdc.balanceOf(seq) - firstBefore;

        uint256 secondBefore = usdc.balanceOf(seq);
        bytes[] memory pu2 = _freshPrice();
        vm.prank(seq);
        pair.unloadVault(1, pu2); // the next node
        uint256 secondPaid = usdc.balanceOf(seq) - secondBefore;

        uint256 firstExpected =
            (BTC / 100) * 49_900 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE / 1e12;
        uint256 secondExpected =
            (BTC / 100) * 49_800 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE / 1e12;
        assertEq(firstPaid, firstExpected, "first slice paid its own bps");
        assertEq(secondPaid, secondExpected, "second slice paid its own bps");

        // Two slices == one call over the same notional: no flat floor was collected on either.
        uint256 combined = ((BTC / 100) * 49_900 + (BTC / 100) * 49_800) * BazaarTypes.LIQUIDATION_FEE_EBP
            / BazaarTypes.EBP_SCALE / 1e12;
        assertEq(firstPaid + secondPaid, combined, "slicing earns exactly the single-call total");
    }

    /// @notice Above the notional gate the bps term stands on its own, so a large single unload
    ///         is paid at the intended rate whether or not it clears the inventory.
    function test_unload_reward_paidAboveGate_withInventoryRemaining() public {
        _deposit(carol, 200_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 2, 49_900 * BAZAAR_SCALE); // ~$24,950 absorbed
        _setVaultPendingLiq(BTC, 49_900, 48_000, true); // 1 BTC inventory: half remains

        uint256 keeperBefore = usdc.balanceOf(seq);
        assertEq(_unloadVault(), BTC / 2, "half the inventory unloaded");
        assertGt(_pendingLiqSize(), 0, "inventory remains");
        uint256 expected = (BTC / 2) * 49_900 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE / 1e12;
        assertEq(usdc.balanceOf(seq) - keeperBefore, expected, "2bp paid above the gate");
    }

    // ============================================================
    // Inline unload inside liquidate()
    // ============================================================

    function test_liquidate_inlineUnload_absorbsIntoRestingBid() public {
        _setupInsolventAlice(); // 0.1 BTC long, $5,005 entry basis, $10 collateral
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 49_950 * BAZAAR_SCALE);

        vm.prank(dave);
        bytes[] memory pu = _freshPrice();
        // Build the update before the prank is consumed by an external call.
        vm.stopPrank();
        vm.prank(dave);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "alice liquidated");

        assertEq(_pendingLiqSize(), 0, "inline unload absorbed the whole seizure in the same tx");
        assertEq(_posSize(carol), BTC / 10, "resting bidder inherited the position");
        assertEq(_posSize(alice), 0);
    }

    function test_liquidate_inlineUnload_emptyBook_leavesInventory() public {
        _setupInsolventAlice();
        vm.prank(dave);
        assertEq(pair.liquidate(_arr1(alice), _freshPrice()), 1, "alice liquidated");
        assertEq(_pendingLiqSize(), BTC / 10, "no liquidity: inventory awaits unloadVault");
    }

    // ============================================================
    // Seizure vs unload: the user's orders die with the position
    // ============================================================

    /// @notice Liquidation seizes the WHOLE position in one write and the vault inherits it, so
    ///         a partial unload leaves inventory on the *vault*, not a remainder of the user's
    ///         position. The liquidatee's TP and SL are therefore both canceled outright —
    ///         there is no surviving position for a close-only order to reduce, and a live one
    ///         would re-open exposure for someone who was just liquidated.
    function test_liquidation_cancelsBothTpAndSl_evenWhenUnloadOnlyPartlyFills() public {
        _setupInsolventAlice(); // alice: long 0.1 BTC, insolvent at $50k

        uint256 tp = _placeTakeProfit(alice, false, BTC / 10, 55_000 * BAZAAR_SCALE, 500);
        uint256 sl = _placeStopLoss(alice, false, BTC / 10, 45_000 * BAZAAR_SCALE, 500);
        assertEq(_takeProfitOrderId(alice), tp, "TP slot armed");
        assertEq(_stopLossOrderId(alice), sl, "SL slot armed");

        // Only 0.02 BTC of in-band bid depth: the inline unload cannot absorb the full 0.1.
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 50, 47_600 * BAZAAR_SCALE);

        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), _freshPrice()), 1, "alice liquidated");

        // The premise: the unload really was partial.
        assertGt(_pendingLiqSize(), 0, "vault still holds unsold inventory");
        assertEq(_posSize(carol), BTC / 50, "the in-band maker absorbed its slice");

        // The user's side is fully gone regardless.
        assertEq(_posSize(alice), 0, "position seized in full, not partially");
        assertEq(_takeProfitOrderId(alice), 0, "TP slot cleared");
        assertEq(_stopLossOrderId(alice), 0, "SL slot cleared");
        assertGt(_canceledBlock(tp), 0, "TP canceled");
        assertGt(_canceledBlock(sl), 0, "SL canceled");

        // And neither can be revived by a keeper at a price that would have triggered it.
        assertEq(_executeTriggerAt(tp, 55_000), 0, "canceled TP cannot fire");
        assertEq(_executeTriggerAt(sl, 45_000), 0, "canceled SL cannot fire");
        assertEq(_posSize(alice), 0, "alice stays flat");
    }

    /// @notice The vault's inherited inventory carries no TP/SL of its own: finishing the unload
    ///         later moves size to fresh counterparties without reviving anything.
    function test_laterUnload_ofSeizedInventory_revivesNothing() public {
        _setupInsolventAlice();
        uint256 tp = _placeTakeProfit(alice, false, BTC / 10, 55_000 * BAZAAR_SCALE, 500);

        vm.prank(bob);
        pair.liquidate(_arr1(alice), _freshPrice());
        uint256 leftover = _pendingLiqSize();
        assertGt(leftover, 0, "nothing absorbed with an empty book");

        // Now supply depth and finish the unload permissionlessly.
        _deposit(dave, 40_000 * BAZAAR_SCALE);
        _placeLimit(dave, true, leftover, 47_600 * BAZAAR_SCALE);
        assertEq(_unloadVault(), leftover, "remaining inventory cleared");

        assertEq(_posSize(dave), leftover, "inventory moved to the new counterparty");
        assertEq(_posSize(alice), 0, "liquidatee unaffected by the later unload");
        assertGt(_canceledBlock(tp), 0, "TP still canceled");
        assertEq(_takeProfitOrderId(dave), 0, "no TP follows the inventory");
    }
}
