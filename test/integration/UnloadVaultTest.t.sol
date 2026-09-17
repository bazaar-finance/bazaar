// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

/// @title UnloadVaultTest
/// @notice Vault liquidation inventory crossing into the resting book: the unload bound (the
///         looser of the estates' fund-neutral price and the liquidation band
///         min(LIQ_MAX_SLIPPAGE_BP, MMR) around oracle), the headroom the insurance fund may
///         spend above its reserve, proportional aggregate decrements, the inline unload at the
///         end of liquidate(), and the permissionless unloadVault caller reward with its
///         anti-dust gate.
contract UnloadVaultTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BTC = 1e18;

    /// @dev Inject vault liquidation inventory directly (sizes in 1e18, prices in whole USD).
    ///      entryNotional/bankruptcyNotional land in 1e18 scale because size already carries it.
    ///      The gap between entry and bankruptcy is the collateral seized with the inventory.
    function _setVaultPendingLiq(uint256 size, uint256 entryPriceUsd, uint256 bankruptcyPriceUsd, bool isLong)
        internal
    {
        _setVaultPendingLiqRaw(size, size * entryPriceUsd, size * bankruptcyPriceUsd, isLong);
    }

    function _pendingLiqSize() internal view returns (uint256 s) {
        (,,,,,, s,,,,,,,) = pair.pairVault();
    }

    /// @dev Inject inventory by raw notionals (1e18 scale). The gap between entry and bankruptcy
    ///      is staged as the collateral seized with the inventory, so entry == bankruptcy leaves
    ///      nothing earmarked: free capital is the whole fund and the fund-neutral price is
    ///      exactly bankruptcyNotional per unit.
    function _setVaultPendingLiqRaw(uint256 size, uint256 entryNotional, uint256 bankruptcyNotional, bool isLong)
        internal
    {
        uint256 seized = isLong ? entryNotional - bankruptcyNotional : bankruptcyNotional - entryNotional;
        _stdstore.target(address(pair)).sig("pairVault()").depth(6).checked_write(size);
        _stdstore.target(address(pair)).sig("pairVault()").depth(7).checked_write(entryNotional);
        _stdstore.target(address(pair)).sig("pairVault()").depth(8).checked_write(bankruptcyNotional);
        _stdstore.target(address(pair)).sig("pairVault()").depth(10).checked_write(isLong);
        _stdstore.target(address(pair)).sig("pairVault()").depth(13).checked_write(seized);
    }

    /// @dev Seed the estates' entry funding index. With the live index at zero, an entry index of
    ///      −x means x of funding per unit has accrued since entry: paid by an inherited long,
    ///      received by an inherited short. Both raise the fund-neutral price by x.
    function _setVaultPendingLiqEntryFundingIndex(int256 idx) internal {
        _stdstore.target(address(pair)).sig("pairVault()").depth(9).checked_write(uint256(idx));
    }

    /// @dev The reserve the gate and the walk keep out of the fund: ADL_RESERVE_BP of the target
    ///      ratio on the per-side open interest, which here is the vault's own inventory at the
    ///      $50k oracle. A fresh pair sits at the base target.
    function _reserve(uint256 inventorySize) internal pure returns (uint256) {
        return inventorySize * 50_000 * BazaarTypes.INSURANCE_TARGET_BASE * BazaarTypes.ADL_RESERVE_BP
            / BazaarTypes.BP_SCALE / BazaarTypes.BP_SCALE;
    }

    /// @dev Free capital above the reserve with nothing earmarked: the whole fund less the reserve.
    function _base(uint256 inventorySize) internal view returns (uint256) {
        return _insuranceBal() - _reserve(inventorySize);
    }

    /// @dev The reward reservation the walk takes off its headroom: what the caller earns for
    ///      unloading the whole inventory, at the bps rate or the flat floor.
    function _rewardReservation(uint256 inventorySize) internal pure returns (uint256 r) {
        r = inventorySize * 50_000 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
        if (r < BazaarTypes.UNLOAD_BOUNTY_MIN) r = BazaarTypes.UNLOAD_BOUNTY_MIN;
    }

    function _deficit() internal view returns (uint256 d) {
        (,,,,,,,,,,, d,,) = pair.pairVault();
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

        _unloadVault();

        // reward = max($0.25, 2bp × $4,990 unloaded) = $0.998 — the bps term binds here.
        uint256 expected = (BTC / 10) * 49_900 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE / 1e12;
        assertEq(_claimFees(seq), expected, "2bp-of-notional reward paid");
    }

    function test_unload_reward_floorApplies() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        // $499 unloaded → 2bp ≈ $0.0998, under the floor. Below the notional gate, but this call
        // CLEARS the inventory, which is the case the floor exists to pay for.
        _placeLimit(carol, true, BTC / 100, 49_900 * BAZAAR_SCALE);
        _setVaultPendingLiq(BTC / 100, 49_900, 48_000, true);

        _unloadVault();
        assertEq(_pendingLiqSize(), 0, "inventory cleared");
        assertEq(_claimFees(seq), 0.25e6, "$0.25 floor pays the clearing call");
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

        assertEq(_unloadVault(), BTC / 100, "partial unload still executes");
        assertGt(_pendingLiqSize(), 0, "inventory remains");

        uint256 expected = (BTC / 100) * 49_900 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE / 1e12;
        uint256 paid = _claimFees(seq);
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

        bytes[] memory pu1 = _freshPrice();
        vm.prank(seq);
        pair.unloadVault(1, pu1); // one node
        uint256 firstPaid = _claimFees(seq);

        bytes[] memory pu2 = _freshPrice();
        vm.prank(seq);
        pair.unloadVault(1, pu2); // the next node
        uint256 secondPaid = _claimFees(seq);

        uint256 firstExpected = (BTC / 100) * 49_900 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE / 1e12;
        uint256 secondExpected = (BTC / 100) * 49_800 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE / 1e12;
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

        assertEq(_unloadVault(), BTC / 2, "half the inventory unloaded");
        assertGt(_pendingLiqSize(), 0, "inventory remains");
        uint256 expected = (BTC / 2) * 49_900 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE / 1e12;
        assertEq(_claimFees(seq), expected, "2bp paid above the gate");
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

    // ============================================================
    // Bound, reserve and headroom
    // ============================================================
    // Every scenario below runs at a $50k oracle with the 5% band edge at $47,500 / $52,500. With
    // entry == bankruptcy and no funding carry, the fund-neutral price is the bankruptcy price,
    // and with no positions on the book the per-side open interest is the vault's inventory, so
    // the reserve is 20% of the 2% base target on that notional: $200 per BTC held.

    /// @notice The bound is the looser of the two anchors. With bankruptcy below the band edge, a
    ///         bid that deviates more than the band from the oracle still fills as long as it beats
    ///         the estates' bankruptcy price.
    function test_unload_bound_bankruptcyAdmitsOutsideTheBand() public {
        assertEq(pair.currentFundingIndex(), int256(0), "no funding carry");
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiqRaw(BTC, 46_000 * BAZAAR_SCALE, 46_000 * BAZAAR_SCALE, true); // neutral $46,000
        _placeLimit(carol, true, BTC / 10, 46_500 * BAZAAR_SCALE); // 7% under the oracle, above bankruptcy
        _placeLimit(dave, true, BTC / 10, 45_500 * BAZAAR_SCALE); // under both anchors

        assertEq(_unloadVault(), BTC / 10, "the bid above bankruptcy filled despite the band");
        assertEq(_posSize(carol), BTC / 10, "counterparty took the slice");
        assertEq(_posSize(dave), 0, "the bid under both anchors untouched");
        assertTrue(_inBook(_newestLimitOrderId(dave)), "and still resting");
        assertFalse(pair.isAdlPending(), "walk left the pair healthy");
        assertEq(_deficit(), 0, "no deficit");
    }

    /// @notice And the other way around: with bankruptcy above the band edge, a bid under the
    ///         estates' bankruptcy price still fills as long as it stays inside the band, at the
    ///         fund's expense.
    function test_unload_bound_bandAdmitsUnderBankruptcy() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiqRaw(BTC, 49_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true); // neutral $49,000
        _placeLimit(carol, true, BTC / 10, 48_000 * BAZAAR_SCALE); // under bankruptcy, inside the band
        _placeLimit(dave, true, BTC / 10, 47_000 * BAZAAR_SCALE); // outside the band

        uint256 iBefore = _insuranceBal();
        assertEq(_unloadVault(), BTC / 10, "the in-band bid under bankruptcy filled");
        assertEq(_posSize(dave), 0, "the out-of-band bid untouched");
        assertFalse(pair.isAdlPending(), "walk left the pair healthy");

        // The slice cost the fund its distance from the neutral price plus the caller's reward,
        // offset only by the maker's insurance fee.
        uint256 reward = 4_800 * BAZAAR_SCALE * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
        assertApproxEqAbs(iBefore - _insuranceBal(), 100 * BAZAAR_SCALE + reward, BAZAAR_SCALE / 2);
    }

    /// @notice The headroom is spent to the dollar and no further: the last fill is trimmed to what
    ///         is left, the walk stops, and the fund ends above its reserve by exactly the loss the
    ///         remaining inventory carries at the mark, so the pair stays healthy.
    function test_unload_headroom_trimsTheLastFillAndStops() public {
        _deposit(carol, 40_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        uint256 base = _base(BTC);
        // Expected loss sits $500 under base; the reward reservation takes $10 more, leaving $490
        // of headroom. Every unit sold $1,000 under the oracle spends $1,000 of it.
        uint256 bk = 50_000 * BAZAAR_SCALE + base - 500 * BAZAAR_SCALE;
        _setVaultPendingLiqRaw(BTC, bk, bk, true);
        uint256 carolId = _placeLimit(carol, true, BTC, 49_000 * BAZAAR_SCALE);
        _placeLimit(dave, true, BTC / 10, 48_900 * BAZAAR_SCALE);
        assertEq(_rewardReservation(BTC), 10 * BAZAAR_SCALE, "reward reservation");

        assertEq(_unloadVault(), 49 * BTC / 100, "0.49 BTC: the headroom over $1,000 per unit");
        assertEq(_posSize(carol), 49 * BTC / 100, "the maker was partially filled");
        assertTrue(_inBook(carolId), "and keeps resting with the rest of its size");
        assertEq(_orderSize(carolId) - _filledSize(carolId), 51 * BTC / 100, "0.51 BTC still on the book");
        assertEq(_posSize(dave), 0, "and the deeper maker was not reached");
        assertFalse(pair.isAdlPending(), "the walk left the pair healthy");
        assertEq(_deficit(), 0, "no deficit");
        assertGe(_insuranceBal(), _reserve(BTC), "the reserve is untouched");

        // What is left: the remainder's loss at the mark against the fund above its reserve. The
        // walk spent the headroom to zero, so the two differ only by the unused reward slack and
        // the maker's fee credit.
        uint256 lossLeft = 51 * (bk - 50_000 * BAZAAR_SCALE) / 100;
        uint256 baseLeft = _insuranceBal() - _reserve(BTC);
        assertGe(baseLeft, lossLeft, "remainder still covered at the mark");
        assertLt(baseLeft - lossLeft, 15 * BAZAAR_SCALE, "and the headroom was spent to the dollar");
    }

    /// @notice Past the trigger the base has not set the inventory's loss aside, so a fill at the
    ///         mark would spend cash the fund does not hold above its reserve. The walk takes only
    ///         fills at the neutral price or better — those cost the fund nothing — and the
    ///         post-walk verdict opens the auction for the rest.
    function test_unload_pastTrigger_takesOnlyNeutralOrBetterThenLatchesAdl() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        uint256 bk = 50_000 * BAZAAR_SCALE + _base(BTC) + 1_000 * BAZAAR_SCALE; // loss = base + 1,000
        _setVaultPendingLiqRaw(BTC, bk, bk, true); // the neutral price is bk per BTC, above the oracle
        _placeLimit(carol, true, BTC / 10, bk); // at the neutral price: costs the fund nothing
        uint256 daveId = _placeLimit(dave, true, BTC / 10, 50_500 * BAZAAR_SCALE); // above the oracle, under neutral
        assertFalse(pair.isAdlPending(), "nothing has judged the inventory yet");
        uint256 iBefore = _insuranceBal();

        assertEq(_unloadVault(), BTC / 10, "only the fill at the neutral price was taken");
        assertEq(_posSize(carol), BTC / 10, "the neutral-price maker took the slice");
        assertEq(_posSize(dave), 0, "the fill above the oracle but under neutral was refused");
        assertTrue(_inBook(daveId), "and still rests");
        uint256 tip = (BTC / 10) * bk / BAZAAR_SCALE * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
        assertEq(_claimFees(seq), tip / 1e12, "the caller's reward was paid in full from free capital");
        assertGe(_insuranceBal() + tip, iBefore, "the fill itself cost the fund nothing");
        assertTrue(pair.isAdlPending(), "post-walk verdict opened the auction for the rest");
        assertEq(_deficit(), 0, "no deficit");
        assertEq(pair.settlementPriceFixedTs(), 0, "and no termination");
    }

    /// @notice A past-the-trigger walk against bids resting at the mark: the fills the fund cannot
    ///         afford are refused rather than booked as deficit, so a pair the auction can still
    ///         save is not terminated by its own unload.
    function test_unload_pastTrigger_bidsAtTheMarkAreRefusedNotBookedAsDeficit() public {
        _deposit(carol, 100_000 * BAZAAR_SCALE);
        // A $5,000 loss at the mark against a $4,000 fund with nothing earmarked: selling at the
        // mark would need $1,000 the fund does not have.
        uint256 bk = 55_000 * BAZAAR_SCALE;
        _setVaultPendingLiqRaw(BTC, bk, bk, true);
        assertGt(5_000 * BAZAAR_SCALE, _insuranceBal(), "setup: the loss exceeds the whole fund");
        uint256 carolId = _placeLimit(carol, true, BTC, 50_000 * BAZAAR_SCALE); // a deep bid at the mark
        uint256 iBefore = _insuranceBal();

        assertEq(_unloadVault(), 0, "nothing filled: every bid is under the neutral price");
        assertEq(_pendingLiqSize(), BTC, "inventory intact");
        assertTrue(_inBook(carolId), "the bid still rests");
        assertEq(_insuranceBal(), iBefore, "the fund is untouched");
        assertEq(_deficit(), 0, "no deficit");
        assertEq(pair.settlementPriceFixedTs(), 0, "no termination");
        assertTrue(pair.isAdlPending(), "the auction opened instead");
    }

    /// @notice The caller's reward never draws on the seizure earmarked against inventory the
    ///         vault still holds: with no free capital, a fill at the neutral price leaves the fund
    ///         holding exactly the remaining earmark, and the next fill settles without deficit.
    function test_unload_reward_neverDrawsOnTheEarmark() public {
        _deposit(carol, 40_000 * BAZAAR_SCALE);
        _deposit(dave, 40_000 * BAZAAR_SCALE);
        // The whole fund is the seizure: neutral price $50,000, free capital zero.
        uint256 fund = _insuranceBal();
        _setVaultPendingLiqRaw(BTC, 50_000 * BAZAAR_SCALE + fund, 50_000 * BAZAAR_SCALE, true);
        _placeLimit(carol, true, BTC / 2, 50_000 * BAZAAR_SCALE);

        assertEq(_unloadVault(), BTC / 2, "half the inventory sold at the neutral price");
        (,,,,,,,,,,,,, uint256 earmarkLeft) = pair.pairVault();
        assertEq(earmarkLeft, fund / 2, "half the seizure still earmarked");
        assertGe(_insuranceBal(), earmarkLeft, "the fund holds the earmark whole");
        assertLt(_claimFees(seq), 5e6, "the reward was capped under the 2 bp rate on $25,000");

        _placeLimit(dave, true, BTC / 2, 50_000 * BAZAAR_SCALE);
        assertEq(_unloadVault(), BTC / 2, "the rest sold at the neutral price");
        assertEq(_pendingLiqSize(), 0, "inventory cleared");
        assertEq(_deficit(), 0, "the second fill settled in full");
        assertEq(pair.settlementPriceFixedTs(), 0, "no termination");
    }

    /// @notice A fund at its reserve has no headroom at all: the vault sells only at or beyond the
    ///         reference price, and inventory that carries no loss leaves the pair healthy.
    function test_unload_fundAtReserve_takesOnlyGains() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        // 20 BTC at the oracle: the reserve on that notional is the whole $4,000 fund.
        _setVaultPendingLiqRaw(20 * BTC, 1_000_000 * BAZAAR_SCALE, 1_000_000 * BAZAAR_SCALE, true);
        assertGe(_reserve(20 * BTC), _insuranceBal(), "fund at or below its reserve");
        _placeLimit(carol, true, BTC / 10, 50_000 * BAZAAR_SCALE); // at the reference
        _placeLimit(dave, true, BTC / 10, 49_990 * BAZAAR_SCALE); // $10 inside it

        assertEq(_unloadVault(), BTC / 10, "the at-reference bid filled");
        assertEq(_posSize(dave), 0, "the bid inside the reference was refused");
        assertFalse(pair.isAdlPending(), "no loss carried, so no auction");
        assertEq(_deficit(), 0, "no deficit");
    }

    /// @notice Funding the inherited longs have paid since entry raises the fund-neutral price:
    ///         a bid above the bankruptcy price but under the carry-adjusted neutral price is
    ///         refused.
    function test_unload_bound_longFundingCarryRaisesNeutral() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiqRaw(BTC, 46_000 * BAZAAR_SCALE, 46_000 * BAZAAR_SCALE, true);
        _setVaultPendingLiqEntryFundingIndex(-1_000 * int256(BAZAAR_SCALE)); // $1,000/BTC paid since entry
        // Neutral price is $47,000, still under the $47,500 band edge, so it is the bound.
        _placeLimit(carol, true, BTC / 10, 47_200 * BAZAAR_SCALE);
        _placeLimit(dave, true, BTC / 10, 46_800 * BAZAAR_SCALE);

        assertEq(_unloadVault(), BTC / 10, "only the bid above the carry-adjusted neutral price filled");
        assertEq(_posSize(dave), 0, "a bid the bankruptcy price alone would admit is refused");
        assertFalse(pair.isAdlPending(), "walk left the pair healthy");
    }

    /// @notice Funding the inherited shorts have received since entry raises the fund-neutral
    ///         price too: the vault can buy back that much higher.
    function test_unload_bound_shortFundingCarryRaisesNeutral() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiqRaw(BTC, 54_000 * BAZAAR_SCALE, 54_000 * BAZAAR_SCALE, false);
        _setVaultPendingLiqEntryFundingIndex(-1_000 * int256(BAZAAR_SCALE)); // $1,000/BTC received since entry
        // Neutral price is $55,000, above the $52,500 band edge, so it is the bound.
        _placeLimit(carol, false, BTC / 10, 54_800 * BAZAAR_SCALE);
        _placeLimit(dave, false, BTC / 10, 55_200 * BAZAAR_SCALE);

        assertEq(_unloadVault(), BTC / 10, "only the ask under the carry-adjusted neutral price filled");
        (bool isLong, uint256 sz,,,,,,,) = pair.positionBuckets(carol);
        assertEq(sz, BTC / 10, "counterparty took the slice");
        assertFalse(isLong, "and inherited the short side");
        assertEq(_posSize(dave), 0, "the ask above it was refused");
        assertFalse(pair.isAdlPending(), "walk left the pair healthy");
    }

    /// @notice The neutral price rounds toward the vault: one wei under the exact quotient is
    ///         refused.
    function test_unload_bound_neutralRoundsTowardTheVault() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        uint256 size = 3 * BTC / 10;
        // 14,101 / 0.3 does not divide: 47,003.33…, under the band edge, so it is the bound.
        uint256 bk = 14_101 * BAZAAR_SCALE;
        _setVaultPendingLiqRaw(size, bk, bk, true);
        uint256 exact = (bk * BAZAAR_SCALE + size - 1) / size;
        _placeLimit(carol, true, BTC / 10, exact);
        _placeLimit(dave, true, BTC / 10, exact - 1);

        assertEq(_unloadVault(), BTC / 10, "the bid at the rounded-up neutral price filled");
        assertEq(_posSize(dave), 0, "one wei under it was refused");
    }

    /// @notice A walk the bound refuses outright still renders the health verdict: an empty
    ///         unload is what opens the auction when the book has nothing the fund will pay for.
    function test_unload_zeroFill_stillJudgesHealth() public {
        uint256 bk = 50_000 * BAZAAR_SCALE + _base(BTC) + 1_000 * BAZAAR_SCALE; // past the trigger
        _setVaultPendingLiqRaw(BTC, bk, bk, true);
        assertFalse(pair.isAdlPending(), "nothing has judged the inventory yet");

        assertEq(_unloadVault(), 0, "nothing to fill");
        assertTrue(pair.isAdlPending(), "the empty walk still opened the auction");
        assertEq(_deficit(), 0, "no deficit");
    }

    /// @notice The inline unload inside liquidate() walks with the same plan: inventory already
    ///         past the trigger when a new estate joins it sells only at the neutral price or
    ///         better, and the health call that follows opens the auction instead of a deficit.
    function test_liquidate_inlineUnload_respectsBound() public {
        _setupInsolventAlice(); // 0.1 BTC long, $5,005 entry basis, $10 collateral
        uint256 bk = 50_000 * BAZAAR_SCALE + _base(BTC) + 1_000 * BAZAAR_SCALE;
        _setVaultPendingLiqRaw(BTC, bk, bk, true);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        // Alice's estate joins at $50,050 with $10 seized, pulling the merged neutral price down to
        // about $54,359: carol bids above it, dave above the oracle but under it.
        _placeLimit(carol, true, BTC / 10, 54_400 * BAZAAR_SCALE);
        _placeLimit(dave, true, BTC / 10, 50_500 * BAZAAR_SCALE);

        bytes[] memory pu = _freshPrice();
        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "alice liquidated");

        assertEq(_posSize(carol), BTC / 10, "the fill above the neutral price was taken inline");
        assertEq(_posSize(dave), 0, "the fill under it was not, though it beat the oracle");
        assertTrue(pair.isAdlPending(), "post-liquidation verdict opened the auction");
        assertEq(_deficit(), 0, "no deficit");
        assertEq(pair.settlementPriceFixedTs(), 0, "and no termination");
    }
}
