// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
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
        (,,,,,, s,,,,,,,,,,) = pair.pairVault();
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

    /// @dev Stamp the staged inventory's seizure time (Vault depth 15), which the unload floor
    ///      opens from. Inventory staged without it reads as fully aged.
    function _setVaultPendingLiqSeizedTs(uint256 ts) internal {
        _stdstore.enable_packed_slots().target(address(pair)).sig("pairVault()").depth(15).checked_write(ts);
    }

    function _pendingLiqSeizedTs() internal view returns (uint64 ts) {
        (,,,,,,,,,,,,,,, ts,) = pair.pairVault();
    }

    /// @dev Stage what the deposits ledger owes the fund (Vault depth 14). Written on its own,
    ///      beside inventory whose seizure the ledger paid in full, it is a balance an earlier
    ///      inventory left behind.
    function _setVaultLedgerArrears(uint256 arrears) internal {
        _stdstore.target(address(pair)).sig("pairVault()").depth(14).checked_write(arrears);
    }

    function _ledgerArrears() internal view returns (uint256 a) {
        (,,,,,,,,,,,,,, a,,) = pair.pairVault();
    }

    /// @dev BazaarPair storage slot of the sample ring (`mmrBuffer`): 25 packed samples, ts in the
    ///      low 64 bits, mmrBp above it and the open-interest minimum above that, followed by the
    ///      packed cursor (head | count << 8 | lastSampleTs << 16 | intervalMinBp << 80 |
    ///      intervalMinOi << 112). `getLaggedMmr` is asserted after the write, so a stale pin
    ///      fails loudly.
    uint256 internal constant SLOT_MMR_BUFFER = 66;

    /// @dev Lay a single ring sample `mmrBp` stamped `ts`, the day's only and therefore lowest one.
    function _seedLaggedMmr(uint256 mmrBp, uint256 ts) internal {
        vm.store(address(pair), bytes32(SLOT_MMR_BUFFER), bytes32(ts | (mmrBp << 64)));
        vm.store(
            address(pair),
            bytes32(SLOT_MMR_BUFFER + BazaarTypes.MMR_SAMPLE_COUNT),
            bytes32(uint256(1) | (uint256(1) << 8) | (ts << 16) | (mmrBp << 80))
        );
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
        (,,,,,,,,,,, d,,,,,) = pair.pairVault();
    }

    /// @dev Storage slot of the pair's liquidation-outcome EMAs, the same pin BazaarPairLens reads
    ///      them by: +0 slippage line, +1 drift line (RiskParamsLib.GAP_EMA_SCALE units per bp),
    ///      +2 their anchors and the batch clock, +3 accumulated weight.
    uint256 internal constant SLOT_LIQUIDATION_GAP_EMA = 43;

    /// @dev The stored EMAs as the last batch wrote them, in whole basis points. On a pair's first
    ///      batch each line is anchored at that batch, where the stored value is the reading.
    function _gapEma() internal view returns (int256 slippageBp, int256 driftBp, uint256 weight) {
        uint256 scale = RiskParamsLib.GAP_EMA_SCALE;
        slippageBp = int256(uint256(pair.extsload(bytes32(SLOT_LIQUIDATION_GAP_EMA))) / scale);
        driftBp = int256(uint256(pair.extsload(bytes32(SLOT_LIQUIDATION_GAP_EMA + 1))) / scale);
        weight = uint256(pair.extsload(bytes32(SLOT_LIQUIDATION_GAP_EMA + 3)));
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

        (, uint256 sz, uint256 entry,,,,) = pair.positionBuckets(carol);
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
        (bool isLong, uint256 sz,,,,,) = pair.positionBuckets(carol);
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
    // Liquidation reward: max($0.05 per account seized, 2 bps of what the call nets and its
    // inline unload sells)
    // ============================================================

    /// @notice A liquidation whose inline unload sells into the book earns 2 bps of what it sold
    ///         when that beats the flat $0.05: 0.1 BTC at $49,950 pays $0.999 in total.
    function test_liquidate_reward_rateOnWhatTheInlineUnloadSold() public {
        _setupInsolventAlice(); // 0.1 BTC long, $5,005 entry, $10 collateral: bankrupt at $49,950
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 49_950 * BAZAAR_SCALE);

        bytes[] memory pu = _freshPrice();
        uint256 owedBefore = _escrowOwed(bob);
        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "alice liquidated");

        assertEq(_pendingLiqSize(), 0, "the inline unload sold the whole seizure");
        uint256 rate = (BTC / 10) * 49_950 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
        assertGt(rate, BazaarTypes.MIN_LIQUIDATOR_REWARD, "premise: the rate beats the flat reward");
        assertEq(_escrowOwed(bob) - owedBefore, rate, "2 bps of the notional sold, not the flat reward on top");
    }

    /// @notice With nothing to sell into, the call earns the flat $0.05 alone, however large the
    ///         seized position.
    function test_liquidate_reward_flatWhenNothingUnloads() public {
        _setupInsolventAlice();
        bytes[] memory pu = _freshPrice();
        uint256 owedBefore = _escrowOwed(bob);
        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "alice liquidated");

        assertEq(_pendingLiqSize(), BTC / 10, "nothing sold");
        assertEq(_escrowOwed(bob) - owedBefore, BazaarTypes.MIN_LIQUIDATOR_REWARD, "the flat reward alone");
    }

    /// @notice The flat reward is due for every position seized: two positions seized in one call
    ///         with nothing sold pay $0.05 each, what two separate calls would.
    function test_liquidate_reward_flatRewardPerSeizure() public {
        _setupInsolventAlice();
        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, BTC / 10, 5_005 * BAZAAR_SCALE);
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = dave;

        bytes[] memory pu = _freshPrice();
        uint256 owedBefore = _escrowOwed(bob);
        vm.prank(bob);
        assertEq(pair.liquidate(users, pu), 2, "both seized");

        assertEq(_pendingLiqSize(), 2 * BTC / 10, "nothing sold");
        assertEq(_escrowOwed(bob) - owedBefore, 2 * BazaarTypes.MIN_LIQUIDATOR_REWARD, "one flat reward per seizure");
    }

    /// @notice The rate tops up the call's whole flat total, not one seizure's share of it: two
    ///         seizures and a sale whose 2 bps falls between one and two flat rewards pay the two
    ///         flat rewards.
    function test_liquidate_reward_rateTopsUpTheWholeFlatTotal() public {
        _setupInsolventAlice();
        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, BTC / 10, 5_005 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 100, 49_950 * BAZAAR_SCALE); // $499.50: 2 bps is $0.0999
        address[] memory users = new address[](2);
        users[0] = alice;
        users[1] = dave;

        bytes[] memory pu = _freshPrice();
        uint256 owedBefore = _escrowOwed(bob);
        vm.prank(bob);
        assertEq(pair.liquidate(users, pu), 2, "both seized");

        assertEq(_posSize(carol), BTC / 100, "the bid filled");
        uint256 rate = (BTC / 100) * 49_950 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
        assertGt(rate, BazaarTypes.MIN_LIQUIDATOR_REWARD, "premise: the rate beats one flat reward");
        assertLt(rate, 2 * BazaarTypes.MIN_LIQUIDATOR_REWARD, "premise: but not two");
        assertEq(_escrowOwed(bob) - owedBefore, 2 * BazaarTypes.MIN_LIQUIDATOR_REWARD, "the flat total stands");
    }

    /// @notice When the inline unload sells a sliver, 2 bps of it is below the flat reward, which
    ///         stands: the call earns the larger of the two, never both.
    function test_liquidate_reward_flatWhenTheRateIsSmaller() public {
        _setupInsolventAlice();
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 1000, 49_950 * BAZAAR_SCALE); // $49.95: 2 bps is under a cent

        bytes[] memory pu = _freshPrice();
        uint256 owedBefore = _escrowOwed(bob);
        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "alice liquidated");

        assertEq(_posSize(carol), BTC / 1000, "a sliver sold");
        assertEq(_escrowOwed(bob) - owedBefore, BazaarTypes.MIN_LIQUIDATOR_REWARD, "the flat reward stands");
    }

    /// @notice A liquidation netted against an opposite inventory retires the overlap at once,
    ///         which takes it off the fund as a sale would: netting alice's 0.1 BTC long against
    ///         the vault's 0.1 BTC short pays 2 bps of $5,000 at the oracle, $1, where the flat
    ///         reward alone would pay $0.05.
    function test_liquidate_reward_nettingPaysTheRateOnWhatItRetired() public {
        _setVaultPendingLiq(BTC / 10, 50_000, 50_000, false); // short inventory, nothing earmarked
        _setupInsolventAlice(); // 0.1 BTC long, $5,005 entry, $10 collateral

        bytes[] memory pu = _freshPrice();
        uint256 owedBefore = _escrowOwed(bob);
        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "alice liquidated");

        assertEq(_pendingLiqSize(), 0, "alice's long netted the short inventory away");
        uint256 rate = (BTC / 10) * 50_000 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
        assertGt(rate, BazaarTypes.MIN_LIQUIDATOR_REWARD, "premise: the rate beats the flat reward");
        assertEq(_escrowOwed(bob) - owedBefore, rate, "2 bps of the netted notional, not the flat reward");
    }

    /// @notice A call that nets part of a seizure and sells the rest earns the rate on both: half
    ///         of alice's 0.1 BTC nets the vault's 0.05 BTC short, the other half becomes the
    ///         inventory and the inline unload sells it into carol's bid. What the netting earned
    ///         is not set against the sale, so the call pays 2 bps of $2,500 plus 2 bps of $2,497.50.
    function test_liquidate_reward_nettingAndTheInlineUnloadEachEarnTheirRate() public {
        _setVaultPendingLiq(BTC / 20, 50_000, 50_000, false); // 0.05 BTC short, nothing earmarked
        _setupInsolventAlice(); // 0.1 BTC long, bankrupt at $49,950
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 20, 49_950 * BAZAAR_SCALE);

        bytes[] memory pu = _freshPrice();
        uint256 owedBefore = _escrowOwed(bob);
        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "alice liquidated");

        assertEq(_pendingLiqSize(), 0, "half netted, half sold");
        assertEq(_posSize(carol), BTC / 20, "the unload sold the remainder into carol's bid");
        uint256 nettedRate = (BTC / 20) * 50_000 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
        uint256 soldRate = (BTC / 20) * 49_950 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
        assertEq(_escrowOwed(bob) - owedBefore, nettedRate + soldRate, "the rate on what was netted and what was sold");
    }

    /// @notice A netting whose 2 bps is below its flat reward leaves the difference as the walk's
    ///         credit, and the walk pays its own rate past it: alice's long nets a $10 sliver of
    ///         short inventory, a fifth of a cent against the $0.05 floor, and the inline unload
    ///         sells her other 0.0998 BTC into carol's bid. The two rates together beat the floor,
    ///         so the call earns both and nothing more.
    function test_liquidate_reward_smallNettingThenSale_walkPaysPastTheCredit() public {
        uint256 sliver = BTC / 5000; // $10 at $50k
        _setVaultPendingLiq(sliver, 50_000, 50_000, false); // short inventory, nothing earmarked
        _setupInsolventAlice(); // 0.1 BTC long, bankrupt at $49,950
        uint256 rest = BTC / 10 - sliver;
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, rest, 49_950 * BAZAAR_SCALE);

        bytes[] memory pu = _freshPrice();
        uint256 owedBefore = _escrowOwed(bob);
        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "alice liquidated");

        assertEq(_pendingLiqSize(), 0, "the sliver netted, the rest sold");
        assertEq(_posSize(carol), rest, "the unload sold the remainder into carol's bid");
        uint256 nettedRate = sliver * 50_000 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
        uint256 soldRate = rest * 49_950 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
        assertLt(nettedRate, BazaarTypes.MIN_LIQUIDATOR_REWARD, "premise: the netting's rate is under the floor");
        assertGt(nettedRate + soldRate, BazaarTypes.MIN_LIQUIDATOR_REWARD, "premise: the two rates beat it");
        assertEq(_escrowOwed(bob) - owedBefore, nettedRate + soldRate, "both rates: the floor is covered by them");
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

    // ============================================================
    // The floor beyond the band: residual equity waits for competing bids
    // ============================================================

    /// @notice Inventory seized with equity beyond the band is not sold into that region at once.
    ///         The floor starts at the band edge and slides to the estates' bankruptcy price over
    ///         UNLOAD_FLOOR_DECAY, so a bid a hair above bankruptcy waits the whole countdown
    ///         while any better bid that arrives meanwhile is taken first.
    function test_unload_floor_residualEquityOpensOverTheCountdown() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        // Neutral $46,000 against a $50k oracle: $1,500 per BTC of residual equity beyond the
        // $47,500 band edge.
        _setVaultPendingLiqRaw(BTC, 46_000 * BAZAAR_SCALE, 46_000 * BAZAAR_SCALE, true);
        _setVaultPendingLiqSeizedTs(vm.getBlockTimestamp());
        _placeLimit(carol, true, BTC / 10, 46_500 * BAZAAR_SCALE); // above bankruptcy, under the edge

        assertEq(_unloadVault(), 0, "at seizure the floor is the band edge");
        assertEq(_pendingLiqSize(), BTC, "inventory held");
        assertFalse(pair.isAdlPending(), "residual-equity inventory carries no loss at the edge");

        // Halfway: the floor is $46,750. A better bid arriving now is taken; carol's still waits.
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.UNLOAD_FLOOR_DECAY / 2);
        _placeLimit(dave, true, BTC / 10, 46_800 * BAZAAR_SCALE);
        assertEq(_unloadVault(), BTC / 10, "the bid above the half-open floor filled");
        assertEq(_posSize(dave), BTC / 10, "and it was the better bid");
        assertEq(_posSize(carol), 0, "the bid under the floor still waits");

        // Fully open: the floor is bankruptcy and carol's bid fills.
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.UNLOAD_FLOOR_DECAY / 2);
        assertEq(_unloadVault(), BTC / 10, "the bid above bankruptcy filled once the floor reached it");
        assertEq(_posSize(carol), BTC / 10);
        assertEq(_deficit(), 0, "no deficit");
    }

    /// @notice Inside the band nothing waits: an in-band bid fills the moment the inventory is
    ///         seized, whatever the countdown says.
    function test_unload_floor_inBandFillsAtSeizure() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiqRaw(BTC, 46_000 * BAZAAR_SCALE, 46_000 * BAZAAR_SCALE, true);
        _setVaultPendingLiqSeizedTs(vm.getBlockTimestamp());
        _placeLimit(carol, true, BTC / 10, 47_600 * BAZAAR_SCALE); // inside the 5% band

        assertEq(_unloadVault(), BTC / 10, "in-band bid taken at once");
        assertEq(_posSize(carol), BTC / 10);
    }

    /// @notice An estate whose bankruptcy price already sits inside the band has no residual
    ///         region: the bound is the band edge from the first instant, exactly as it is once
    ///         the countdown has run.
    function test_unload_floor_bankruptcyInsideTheBand_unchanged() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiqRaw(BTC, 49_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true); // neutral above the edge
        _setVaultPendingLiqSeizedTs(vm.getBlockTimestamp());
        _placeLimit(carol, true, BTC / 10, 48_000 * BAZAAR_SCALE); // under bankruptcy, inside the band
        _placeLimit(dave, true, BTC / 10, 47_000 * BAZAAR_SCALE); // outside the band

        assertEq(_unloadVault(), BTC / 10, "the in-band bid under bankruptcy filled at seizure");
        assertEq(_posSize(dave), 0, "the out-of-band bid untouched");
    }

    /// @notice The floor is derived from the live band edge, so it follows the oracle during the
    ///         countdown rather than freezing at the price the inventory was seized at.
    function test_unload_floor_tracksTheOracle() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiqRaw(BTC, 46_000 * BAZAAR_SCALE, 46_000 * BAZAAR_SCALE, true);
        _setVaultPendingLiqSeizedTs(vm.getBlockTimestamp());
        _placeLimit(carol, true, BTC / 10, 46_300 * BAZAAR_SCALE);
        _placeLimit(dave, true, BTC / 10, 46_200 * BAZAAR_SCALE);

        // Halfway through the countdown at a $49k oracle: band edge $46,550, floor $46,275.
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.UNLOAD_FLOOR_DECAY / 2);
        bytes[] memory pu = _priceAt(49_000);
        vm.prank(seq);
        assertEq(pair.unloadVault(0, pu), BTC / 10, "only the bid above the tracked floor");
        assertEq(_posSize(carol), BTC / 10);
        assertEq(_posSize(dave), 0, "the bid under it waits");
    }

    /// @notice The band is derived from the lower of the current MMR and the day's lagged minimum.
    ///         Here the current rate is the 10% warmup floor (band at the 5% cap) while the lagged
    ///         minimum is 2%: a bid 4% under the oracle, in-band at the cap, is beyond the 2% edge
    ///         and waits for the floor like any other residual-equity fill. A rate the market has
    ///         not carried for a day cannot pull the edge toward bankruptcy.
    function test_unload_band_readsTheLaggedMinimum() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiqRaw(BTC, 46_000 * BAZAAR_SCALE, 46_000 * BAZAAR_SCALE, true);
        _setVaultPendingLiqSeizedTs(vm.getBlockTimestamp());
        _seedLaggedMmr(200, vm.getBlockTimestamp() - 25 hours);

        _placeLimit(carol, true, BTC / 10, 48_000 * BAZAAR_SCALE); // inside a 5% band, beyond a 2% one
        _placeLimit(dave, true, BTC / 10, 49_200 * BAZAAR_SCALE); // inside the 2% band
        (, uint256 mmrNow,,) = pair.marginRequirements();
        assertEq(mmrNow, 1_000, "current rate: the warmup floor, band capped at 5%");

        assertEq(_unloadVault(), BTC / 10, "only the bid inside the 2% band filled");
        uint256 lagged = pair.getLaggedMmr();
        assertEq(lagged, 200, "the lagged minimum the band read");
        assertEq(_posSize(dave), BTC / 10);
        assertEq(_posSize(carol), 0, "the bid the 5% band would have taken waits for the floor");

        vm.warp(vm.getBlockTimestamp() + BazaarTypes.UNLOAD_FLOOR_DECAY);
        assertEq(_unloadVault(), BTC / 10, "and fills once the floor has opened to it");
        assertEq(_posSize(carol), BTC / 10);
    }

    /// @notice The mirror for short inventory: the ceiling opens upward from the band edge toward
    ///         the estates' bankruptcy price.
    function test_unload_floor_shortInventoryMirror() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        // Neutral $54,000 above a $52,500 band edge: $1,500 per BTC of residual equity.
        _setVaultPendingLiqRaw(BTC, 54_000 * BAZAAR_SCALE, 54_000 * BAZAAR_SCALE, false);
        _setVaultPendingLiqSeizedTs(vm.getBlockTimestamp());
        _placeLimit(carol, false, BTC / 10, 53_500 * BAZAAR_SCALE); // under bankruptcy, beyond the edge

        assertEq(_unloadVault(), 0, "at seizure the ceiling is the band edge");
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.UNLOAD_FLOOR_DECAY);
        assertEq(_unloadVault(), BTC / 10, "fully open, the ask under bankruptcy is taken");
        assertEq(_posSize(carol), BTC / 10);
    }

    /// @notice Through the real seizure: a liquidator cannot rest a bid a hair above the estate's
    ///         bankruptcy price and have the walk it triggers sell the seizure to it. The bid
    ///         waits out the countdown, during which any better bid takes the inventory.
    function test_liquidate_inlineUnload_residualEquityWaitsForTheFloor() public {
        // Alice: long 0.1 BTC from $50,000 on $400, 8% equity under the 10% warmup MMR, so she is
        // liquidatable with $1,500 per BTC of equity beyond the 5% band; bankruptcy $46,000.
        _deposit(alice, 400 * BAZAAR_SCALE);
        _writePosition(alice, true, BTC / 10, 5_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 46_100 * BAZAAR_SCALE); // a hair above bankruptcy

        bytes[] memory pu = _freshPrice();
        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "alice liquidated");
        assertEq(_pendingLiqSize(), BTC / 10, "the seizure was not sold into the residual region");
        assertEq(_posSize(carol), 0, "the bid above bankruptcy waits");
        assertEq(_pendingLiqSeizedTs(), uint64(vm.getBlockTimestamp()), "seizure stamped");
        assertFalse(pair.isAdlPending(), "no window: the inventory carries no loss at the edge");

        vm.warp(vm.getBlockTimestamp() + BazaarTypes.UNLOAD_FLOOR_DECAY);
        assertEq(_unloadVault(), BTC / 10, "fully open, the bid is taken");
        assertEq(_posSize(carol), BTC / 10);
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
        (,,,,,,,,,,,,, uint256 earmarkLeft,,,) = pair.pairVault();
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
        // 40 BTC at the oracle: the reserve on that notional is the whole $4,000 fund.
        _setVaultPendingLiqRaw(40 * BTC, 2_000_000 * BAZAAR_SCALE, 2_000_000 * BAZAAR_SCALE, true);
        assertGe(_reserve(40 * BTC), _insuranceBal(), "fund at or below its reserve");
        _placeLimit(carol, true, BTC / 10, 50_000 * BAZAAR_SCALE); // at the reference
        _placeLimit(dave, true, BTC / 10, 49_990 * BAZAAR_SCALE); // $10 inside it

        assertEq(_unloadVault(), BTC / 10, "the at-reference bid filled");
        assertEq(_posSize(dave), 0, "the bid inside the reference was refused");
        assertFalse(pair.isAdlPending(), "no loss carried, so no auction");
        assertEq(_deficit(), 0, "no deficit");
    }

    /// @notice The caller's reward takes no more than the fund's capital above the reserve covers
    ///         the remaining inventory's loss at the mark by. 10 BTC entered at $50,060, bankrupt
    ///         at $50,010, so $500 is earmarked and the inventory loses $100 beyond it at the
    ///         $50,000 mark; the fund holds $1,610, which is the earmark, the $1,000 reserve, that
    ///         $100 and $10 more: healthy by $10, while the walk sets aside the $100 rate on the
    ///         whole inventory, so it takes only fills at or beyond the mark. A 2 BTC bid at the
    ///         mark fills; the $4.95 of fee it pays the fund is all that moves the cover, to
    ///         $14.95, and it earns the $20 rate. Paid in full, the reward would leave the 8 BTC's
    ///         $80 loss $5.05 uncovered and open the auction; capped at $14.95, it takes exactly
    ///         the cover and the pair ends on the gate's healthy side.
    function test_unload_reward_cappedAtTheCoverLeft_opensNoWindow() public {
        _deposit(carol, 40_000 * BAZAAR_SCALE);
        _setVaultPendingLiq(10 * BTC, 50_060, 50_010, true);
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(1_610 * BAZAAR_SCALE);
        _placeLimit(carol, true, 2 * BTC, 50_000 * BAZAAR_SCALE);
        assertFalse(pair.isAdlPending(), "premise: no window");

        assertEq(_unloadVault(), 2 * BTC, "the bid at the mark filled");

        uint256 reward = _escrowOwed(seq);
        assertApproxEqAbs(reward, 14.95e18, 1e16, "the $10 slack and the fill's $4.95 fee, not the $20 rate");
        assertEq(_ledgerArrears(), 0, "nothing owed");
        uint256 lossLeft = 8 * 10 * BAZAAR_SCALE;
        assertEq(
            _insuranceBal() - _pendingLiqSeized() - _reserve(10 * BTC),
            lossLeft,
            "the reward took exactly what the cover exceeded the $80 loss by"
        );
        assertFalse(pair.isAdlPending(), "the reward carried the pair over no trigger");
        assertEq(_deficit(), 0, "no deficit");
    }

    /// @notice The caller's reward never carries a pair over the ADL trigger the walk left it short
    ///         of. Across both sides, 2 to 20 BTC under water at the mark by $1 to $50 a BTC beyond
    ///         an earmark of up to what the fund can hold, and a fund covering that loss by $0 to
    ///         $40: the inventory's loss at the mark makes the mark the walk's reference, so a
    ///         maker there fills whatever the headroom and earns the rate on what it sold, up to
    ///         $30, more than the cover on most of these books. The reward is capped at the cover,
    ///         no window opens and no deficit is booked.
    /// @param shortInventory Whether the vault's inventory is short
    /// @param size The inventory, in whole BTC
    /// @param collateral The earmark, in whole dollars a BTC
    /// @param gap How far under water the inventory is at the mark, in whole dollars a BTC
    /// @param slack What the fund covers the loss at the mark by, in whole dollars
    /// @param makerSize The maker at the mark, in tenths of a BTC
    function testFuzz_unload_reward_neverCarriesThePairOverTheTrigger(
        bool shortInventory,
        uint256 size,
        uint256 collateral,
        uint256 gap,
        uint256 slack,
        uint256 makerSize
    ) public {
        _deposit(carol, 100_000 * BAZAAR_SCALE);
        size = bound(size, 2, 20);
        gap = bound(gap, 1, 50);
        slack = bound(slack, 0, 40);
        // The fund's balance is written over the pair's own, so the books never claim cash the
        // pair does not hold: the earmark takes what the reserve, the loss and the slack leave.
        uint256 room = _insuranceBal() / BAZAAR_SCALE - _reserve(size * BTC) / BAZAAR_SCALE - size * gap - slack;
        collateral = bound(collateral, 1, room / size);
        uint256 bankruptcy = shortInventory ? 50_000 - gap : 50_000 + gap;
        uint256 entry = shortInventory ? bankruptcy - collateral : bankruptcy + collateral;
        _setVaultPendingLiq(size * BTC, entry, bankruptcy, !shortInventory);
        uint256 fund = (size * collateral + size * gap + slack) * BAZAAR_SCALE + _reserve(size * BTC);
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(fund);
        _placeLimit(carol, !shortInventory, bound(makerSize, 1, 30) * BTC / 10, 50_000 * BAZAAR_SCALE);

        assertGt(_unloadVault(), 0, "premise: the maker at the mark filled");

        assertFalse(pair.isAdlPending(), "the reward carried the pair over no trigger");
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

    /// @notice Funding the inherited shorts have received since entry would raise the fund-neutral
    ///         price, but the ceiling never passes the estates' bankruptcy price: the staged
    ///         bankruptcy notional carries no funding, so the whole $1,000 reads as received since
    ///         seizure, and the ask it alone would admit is refused. An ask at bankruptcy fills.
    function test_unload_bound_shortFundingCarryHeldAtBankruptcy() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiqRaw(BTC, 54_000 * BAZAAR_SCALE, 54_000 * BAZAAR_SCALE, false);
        _setVaultPendingLiqEntryFundingIndex(-1_000 * int256(BAZAAR_SCALE)); // $1,000/BTC received since entry
        // The carry alone would put the neutral price at $55,000; the ceiling holds at $54,000.
        _placeLimit(carol, false, BTC / 10, 54_000 * BAZAAR_SCALE);
        _placeLimit(dave, false, BTC / 10, 54_800 * BAZAAR_SCALE);

        assertEq(_unloadVault(), BTC / 10, "only the ask at bankruptcy filled");
        (bool isLong, uint256 sz,,,,,) = pair.positionBuckets(carol);
        assertEq(sz, BTC / 10, "counterparty took the slice");
        assertFalse(isLong, "and inherited the short side");
        assertEq(_posSize(dave), 0, "the ask the carry alone would admit was refused");
        assertTrue(_inBook(_newestLimitOrderId(dave)), "and still rests");
        assertFalse(pair.isAdlPending(), "walk left the pair healthy");
    }

    // ============================================================
    // Arrears an earlier inventory left behind
    // ============================================================

    /// @notice Arrears the ledger owes the fund are one pair-wide balance, counted as the
    ///         inventory's backing. A balance left behind by inventory already closed would place
    ///         the neutral price under the estates' bankruptcy price and open the floor to bids
    ///         there as free fills; the floor holds at bankruptcy instead, and the leftover stays
    ///         a receivable.
    function test_unload_bound_leftoverArrearsCannotLowerTheFloor() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        // Bankruptcy $46,000, seizure paid in full; $5,000 of arrears from before would read the
        // neutral price as $41,000.
        _setVaultPendingLiqRaw(BTC, 46_000 * BAZAAR_SCALE, 46_000 * BAZAAR_SCALE, true);
        _setVaultLedgerArrears(5_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 46_000 * BAZAAR_SCALE); // at bankruptcy
        _placeLimit(dave, true, BTC / 10, 45_500 * BAZAAR_SCALE); // under it, above the inflated figure

        assertEq(_unloadVault(), BTC / 10, "only the bid at bankruptcy filled");
        assertEq(_posSize(carol), BTC / 10, "counterparty took the slice");
        assertEq(_posSize(dave), 0, "the bid under bankruptcy was refused");
        assertTrue(_inBook(_newestLimitOrderId(dave)), "and still rests");
        assertEq(_ledgerArrears(), 5_000 * BAZAAR_SCALE, "the leftover was not spent");
        assertFalse(pair.isAdlPending(), "walk left the pair healthy");
        assertEq(_deficit(), 0, "no deficit");
    }

    /// @notice The mirror for short inventory: leftover arrears would raise the ceiling above the
    ///         estates' bankruptcy price; it holds there.
    function test_unload_bound_leftoverArrearsCannotRaiseTheCeiling() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        // Bankruptcy $54,000; $5,000 of arrears from before would read the neutral price as $59,000.
        _setVaultPendingLiqRaw(BTC, 54_000 * BAZAAR_SCALE, 54_000 * BAZAAR_SCALE, false);
        _setVaultLedgerArrears(5_000 * BAZAAR_SCALE);
        _placeLimit(carol, false, BTC / 10, 54_000 * BAZAAR_SCALE); // at bankruptcy
        _placeLimit(dave, false, BTC / 10, 54_500 * BAZAAR_SCALE); // above it, under the inflated figure

        assertEq(_unloadVault(), BTC / 10, "only the ask at bankruptcy filled");
        assertEq(_posSize(carol), BTC / 10, "counterparty took the slice");
        assertEq(_posSize(dave), 0, "the ask above bankruptcy was refused");
        assertTrue(_inBook(_newestLimitOrderId(dave)), "and still rests");
        assertEq(_ledgerArrears(), 5_000 * BAZAAR_SCALE, "the leftover was not spent");
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
        // about $54,450: carol bids above it, dave above the oracle but under it.
        _placeLimit(carol, true, BTC / 10, 54_600 * BAZAAR_SCALE);
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

    // ============================================================
    // Liquidation-outcome EMAs: what each fill records
    // ============================================================

    /// @notice A walk the market has carried more than the band past the estates' bankruptcy
    ///         price, in the fund's favor, takes any maker that still beats it. This fill lands
    ///         700bp under the oracle, so its slippage is recorded at the band: past it a reading
    ///         measures the walk's latitude, not the cost of a forced exit. The oracle sits above
    ///         bankruptcy, so drift is value the unload already paid into the fund and records
    ///         as zero — while the fill still enters the weight at full size, against a prior
    ///         weighing 1% of the book. The book is the 1 BTC the vault held: 0.9 still in the
    ///         vault and 0.1 now with the maker, so the floor is 0.01 and the band reading lands
    ///         at 500 x 0.1 / (0.01 + 0.1) = 454.
    function test_unload_gapEma_slippageCappedAtBand_driftFlooredAtZero() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiqRaw(BTC, 46_000 * BAZAAR_SCALE, 46_000 * BAZAAR_SCALE, true); // neutral $46,000
        _placeLimit(carol, true, BTC / 10, 46_500 * BAZAAR_SCALE); // 700bp under the oracle

        (,, uint256 weightBefore) = _gapEma();
        assertEq(weightBefore, 0, "a fresh pair has no liquidation history");

        assertEq(_unloadVault(), BTC / 10, "the bid above bankruptcy filled");
        (int256 slippageBp, int256 driftBp, uint256 weight) = _gapEma();
        assertEq(slippageBp, 454, "700bp recorded at the 500bp band, weighed 0.1 against a 0.01 floor");
        assertEq(driftBp, 0, "an oracle above bankruptcy records zero drift, not -869");
        assertEq(weight, BTC / 10 + BTC / 100, "the fill's full weight plus the floor");
    }

    /// @notice The zero floor applies fill by fill, never to the walk's average. A fast market
    ///         leaves stale makers on the fund's side of the oracle, and they fill first: here a
    ///         bid 100bp above the oracle, then a real one 20bp under it. Recorded per fill the
    ///         walk averages (0 + 20) / 2 = 10bp — the free fill dilutes the real cost through
    ///         weight — and the batch then enters at 0.2 against the 0.01 prior floor of a 1 BTC
    ///         book: 10 x 0.2 / 0.21 = 9. Netting the windfall inside the average would record
    ///         -40bp, and flooring only the average would record 0: both would hide what the
    ///         book behind the stale maker cost.
    function test_unload_gapEma_staleMakerDilutesButCannotCancel() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiqRaw(BTC, 49_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true); // neutral $49,000
        _placeLimit(carol, true, BTC / 10, 50_500 * BAZAAR_SCALE); // stale: 100bp above the oracle
        _placeLimit(dave, true, BTC / 10, 49_900 * BAZAAR_SCALE); // 20bp under it

        assertEq(_unloadVault(), BTC / 5, "both makers filled, the stale one first");
        (int256 slippageBp, int256 driftBp, uint256 weight) = _gapEma();
        assertEq(slippageBp, 9, "(0 x 0.1 + 20 x 0.1) / 0.2 = 10 in the walk, then 10 x 0.2 / 0.21 against the floor");
        assertEq(driftBp, 0, "the oracle is above bankruptcy: nothing overran");
        assertEq(weight, BTC / 5 + BTC / 100, "both fills carry their weight, plus the floor");
    }

    /// @notice Drift is floored but never capped. Here the estates' bankruptcy price sits 6% above
    ///         the oracle — the market ran that far past the level margin was set to survive
    ///         before the vault could get out — and the fund can still afford the close, so the
    ///         walk runs and records the overrun in full, well past the band slippage stops at.
    ///         The whole 0.1 BTC book changes hands, so the floor is 0.001 and both legs enter at
    ///         100/101 of the fill's reading: drift 566 -> 560, slippage 10 -> 9.
    function test_unload_gapEma_driftRecordsAGenuineOverrunUncapped() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiq(BTC / 10, 53_000, 53_000, true); // neutral $53,000, loss at the mark $300
        assertGt(
            _base(BTC / 10), 300 * BAZAAR_SCALE + _rewardReservation(BTC / 10), "the fund covers the loss at the mark"
        );
        _placeLimit(carol, true, BTC / 10, 49_950 * BAZAAR_SCALE); // 10bp under the oracle, inside the band

        assertEq(_unloadVault(), BTC / 10, "the in-band bid filled");
        (int256 slippageBp, int256 driftBp,) = _gapEma();
        assertEq(driftBp, 560, "(53,000 - 50,000) / 53,000 = 566 in the walk, recorded past the band at 100/101");
        assertEq(slippageBp, 9, "the fill's own 10bp against the oracle, at 100/101");
    }

    /// @notice The same ceiling on short inventory, the side where a profitable walk's latitude
    ///         has no bound at all: with the oracle 8% under the estates' bankruptcy price the vault
    ///         buys back any ask below it. The ask here lands 700bp over the oracle, and the band
    ///         reading enters against the 1 BTC short side's 0.01 floor as on the long side.
    function test_unload_gapEma_shortInventorySlippageCappedAtBand() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _setVaultPendingLiqRaw(BTC, 54_000 * BAZAAR_SCALE, 54_000 * BAZAAR_SCALE, false); // neutral $54,000
        _placeLimit(carol, false, BTC / 10, 53_500 * BAZAAR_SCALE); // 700bp over the oracle

        assertEq(_unloadVault(), BTC / 10, "the ask under bankruptcy filled");
        (int256 slippageBp, int256 driftBp,) = _gapEma();
        assertEq(slippageBp, 454, "700bp recorded at the 500bp band, weighed 0.1 against a 0.01 floor");
        assertEq(driftBp, 0, "an oracle under a short's bankruptcy price records zero drift, not -740");
    }

    /// @notice A dust estate cannot set the pair's slippage. The liquidator of a dust account can
    ///         also be the maker the vault sells it to, buying it back at the band edge for the
    ///         cost of fees: here the smallest inventory a $5 order can take, 0.0002 BTC, meets a
    ///         bid 700bp under the oracle on a book 10 BTC deep between two other traders. The
    ///         fill records the band, but weighed 0.0002 against the book's 0.1 floor it moves
    ///         the reading to 500 x 0.0002 / (0.100002 + 0.0002), under a basis point.
    function test_unload_gapEma_dustSelfDealCannotSeedTheReading() public {
        uint256 dust = BTC / 5_000; // $9.30 at the bid
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(alice, 300_000 * BAZAAR_SCALE);
        _deposit(bob, 300_000 * BAZAAR_SCALE);
        _placeLimit(alice, false, 10 * BTC, 50_000 * BAZAAR_SCALE);
        _placeLimit(bob, true, 10 * BTC, 50_000 * BAZAAR_SCALE); // crosses: a 10 BTC book
        _setVaultPendingLiq(dust, 46_000, 46_000, true); // neutral $46,000
        _placeLimit(carol, true, dust, 46_500 * BAZAAR_SCALE); // 700bp under the oracle

        assertEq(_unloadVault(), dust, "the dust bid filled");
        (int256 slippageBp,, uint256 weight) = _gapEma();
        assertEq(slippageBp, 0, "the band reading, weighed by a dust share of the book, stays under a basis point");
        assertEq(weight, (10 * BTC + dust) / 100 + dust, "1% of the book plus the fill");
    }

    // ============================================================
    // The walk's loss and the arrears the inventory left keeps
    // ============================================================

    /// @dev Stage `size` BTC of long inventory bankrupt at `bankruptcyUsd` a BTC: `seized` of the
    ///      estates' collateral in cash and `unpaid` owed by the ledger, so the entry basis is the
    ///      bankruptcy notional plus both, beside `leftover` of arrears an earlier inventory left
    ///      and a fund of `fund`.
    function _stageLongWithArrears(
        uint256 size,
        uint256 bankruptcyUsd,
        uint256 seized,
        uint256 unpaid,
        uint256 leftover,
        uint256 fund
    ) internal {
        uint256 bankruptcyNotional = size * bankruptcyUsd;
        _setVaultPendingLiqRaw(size, bankruptcyNotional + seized + unpaid, bankruptcyNotional, true);
        _stdstore.target(address(pair)).sig("pairVault()").depth(13).checked_write(seized);
        _setVaultLedgerArrears(unpaid + leftover);
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(fund);
    }

    function _pendingLiqSeized() internal view returns (uint256 s) {
        (,,,,,,,,,,,,, s,,,) = pair.pairVault();
    }

    /// @notice A fill the walk takes as free leaves the pair as healthy as it found it. The vault
    ///         holds 10 BTC bankrupt at the $50,000 mark: $3,500 of the estates' $6,300 seized in
    ///         cash and $2,800 owed, so the inventory is exactly at break-even and the mark is its
    ///         fund-neutral price. The fund holds $500 above the earmark against a $1,000 reserve:
    ///         no window. A 2 BTC bid at the mark loses $1,260 on the estates' entry, its $700
    ///         earmark and its $560 share of the arrears, and the walk takes it as costing the fund
    ///         nothing. Paid from the earmark first and then $560 of the arrears, it leaves the 8
    ///         BTC $2,240 of arrears, at break-even. Netted from the arrears first, they would keep
    ///         $1,540 and read $700 under water at the mark, while the $700 earmark joined free
    ///         capital with too little of it above the reserve to carry that loss, and the
    ///         post-walk verdict would open the auction.
    function test_unload_freeFillBelowTheReserve_keepsTheArrearsAndOpensNoWindow() public {
        _deposit(carol, 40_000 * BAZAAR_SCALE);
        _stageLongWithArrears(10 * BTC, 50_000, 3_500 * BAZAAR_SCALE, 2_800 * BAZAAR_SCALE, 0, 4_000 * BAZAAR_SCALE);
        assertLt(_insuranceBal() - _pendingLiqSeized(), _reserve(10 * BTC), "premise: free capital under the reserve");
        _placeLimit(carol, true, 2 * BTC, 50_000 * BAZAAR_SCALE);
        assertFalse(pair.isAdlPending(), "premise: no window");

        assertEq(_unloadVault(), 2 * BTC, "the bid at the neutral price filled");
        assertEq(_pendingLiqSeized(), 2_800 * BAZAAR_SCALE, "the slice's earmark left the aggregate");
        assertEq(_ledgerArrears(), 2_240 * BAZAAR_SCALE, "the 8 BTC keep their share of the arrears");
        assertEq(_deficit(), 0, "no deficit");
        assertFalse(pair.isAdlPending(), "the walk carried the pair over no trigger");
    }

    /// @notice Arrears an earlier inventory left count toward the inventory's backing at the mark,
    ///         and a free fill leaves the inventory behind it at least its share of them too. 10
    ///         BTC bankrupt at $50,300, with $3,500 seized, $2,800 owed for the estates and $3,500
    ///         left behind: $500 above water at the $50,000 mark, nothing free above the earmark,
    ///         no window, and the mark is the walk's reference. A 2 BTC bid there loses $1,860,
    ///         within its $700 earmark and its $1,260 share of the $6,300 of arrears. The earmark
    ///         pays first and the arrears the other $1,160, so the 8 BTC left keep $5,140, more
    ///         than their $5,040 share, and stay $500 above water. Netting the arrears first would
    ///         leave them $4,440 and $200 under water, and a window.
    function test_unload_freeFill_inventoryLeftKeepsItsShareOfLeftoverArrears() public {
        _deposit(carol, 40_000 * BAZAAR_SCALE);
        _stageLongWithArrears(
            10 * BTC, 50_300, 3_500 * BAZAAR_SCALE, 2_800 * BAZAAR_SCALE, 3_500 * BAZAAR_SCALE, 3_500 * BAZAAR_SCALE
        );
        _placeLimit(carol, true, 2 * BTC, 50_000 * BAZAAR_SCALE);
        assertFalse(pair.isAdlPending(), "premise: no window");

        assertEq(_unloadVault(), 2 * BTC, "the bid at the mark filled");
        assertEq(_ledgerArrears(), 5_140 * BAZAAR_SCALE, "the arrears paid only what the earmark did not");
        assertEq(_deficit(), 0, "no deficit");
        assertFalse(pair.isAdlPending(), "the walk carried the pair over no trigger");
    }

    /// @dev One unload book for the fuzz below.
    struct UnloadCase {
        bool shortInventory;
        bool vaultReceives;
        uint256 size;
        uint256 collateral;
        uint256 seized;
        uint256 leftover;
        uint256 bankruptcyOffset;
        uint256 funding;
        uint256 free;
        uint256 makerSize;
        uint256 makerOffset;
    }

    /// @dev Bounds and stages `c` against the $50,000 mark: 2 to 20 BTC bankrupt $1,000 either side
    ///      of the mark, $100 to $2,000 a BTC of the estates' collateral split between cash seized
    ///      and arrears owed, up to $3,000 of arrears an earlier inventory left, and up to $200 a
    ///      BTC of funding paid or received holding the inventory. The fund is cut from the pair's
    ///      own: up to half of it free, the seizure out of the rest, so the books never claim cash
    ///      the pair does not hold. Returns the inventory's net position at the mark
    ///      (inventoryNet) and the fund's capital above its reserve.
    /// @param c The case to bound and stage
    /// @return net What the inventory's backing and its result at the mark come to
    /// @return base Free capital above the reserve
    function _stageUnload(UnloadCase memory c) internal returns (int256 net, uint256 base) {
        c.size = bound(c.size, 2, 20);
        c.collateral = bound(c.collateral, 100, 2_000);
        uint256 fund = _insuranceBal() / BAZAAR_SCALE;
        uint256 free = bound(c.free, 0, fund / 2);
        uint256 total = c.size * c.collateral;
        uint256 seized = bound(c.seized, 0, total < fund - free ? total : fund - free);
        uint256 owed = total - seized + bound(c.leftover, 0, 3_000);
        uint256 bk = 49_000 + bound(c.bankruptcyOffset, 0, 2_000);
        uint256 entry = c.shortInventory ? bk - c.collateral : bk + c.collateral;
        _setVaultPendingLiq(c.size * BTC, entry, bk, !c.shortInventory);
        _stdstore.target(address(pair)).sig("pairVault()").depth(13).checked_write(seized * BAZAAR_SCALE);
        _setVaultLedgerArrears(owed * BAZAAR_SCALE);
        // The live index is zero, so an entry index of −x means x a BTC has accrued since entry.
        int256 accrued = int256(bound(c.funding, 0, 200));
        bool paid = !c.vaultReceives;
        _setVaultPendingLiqEntryFundingIndex((c.shortInventory == paid ? accrued : -accrued) * int256(BAZAAR_SCALE));
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write((seized + free) * BAZAAR_SCALE);
        int256 result = c.shortInventory
            ? int256(c.size * entry) - int256(c.size * 50_000)
            : int256(c.size * 50_000) - int256(c.size * entry);
        result += paid ? -accrued * int256(c.size) : accrued * int256(c.size);
        net = (int256(seized + owed) + result) * int256(BAZAAR_SCALE);
        uint256 reserve = _reserve(c.size * BTC);
        base = free * BAZAAR_SCALE > reserve ? free * BAZAAR_SCALE - reserve : 0;
    }

    /// @notice An unload never carries a pair over the ADL trigger it did not start past. Across
    ///         both sides, the earmark's split between cash and arrears, arrears an earlier
    ///         inventory left, funding the vault paid or received, bankruptcy prices either side of
    ///         the mark, fund capital either side of the reserve, and a maker anywhere in the band:
    ///         a book with no window before the walk has none after it, the caller's reward paid,
    ///         and books no deficit. Books already past the trigger are left out. A maker the walk
    ///         does not reach is a book the walk leaves as it found it.
    /// @param c The book, bounded and staged by _stageUnload
    function testFuzz_unload_neverCarriesThePairOverTheTrigger(UnloadCase memory c) public {
        _deposit(carol, 100_000 * BAZAAR_SCALE);
        (int256 net, uint256 base) = _stageUnload(c);
        uint256 loss = net < 0 ? uint256(-net) : 0;
        if (loss > base) return;
        uint256 size = bound(c.makerSize, 1, 30) * BTC / 10;
        uint256 offset = bound(c.makerOffset, 0, 2_400);
        uint256 price = (c.shortInventory ? 50_000 + offset : 50_000 - offset) * BAZAAR_SCALE;
        _placeLimit(carol, !c.shortInventory, size, price);
        assertFalse(pair.isAdlPending(), "premise: no window");

        _unloadVault();

        assertEq(_deficit(), 0, "no deficit");
        assertFalse(pair.isAdlPending(), "the walk carried the pair over no trigger");
    }

    /// @dev Bounds and stages `c` with the fund at or under its reserve and the walk's neutral
    ///      price `distance` inside the $50,000 mark: below it for a long inventory, above it for a
    ///      short one. 2 to 20 BTC, $100 to $2,000 a BTC of the estates' collateral split between
    ///      cash seized and arrears owed, up to $150 a BTC of arrears an earlier inventory left and
    ///      up to $200 a BTC of funding paid or received holding the inventory, every figure in
    ///      whole dollars a BTC so the neutral price is exact. The inventory is at or above water
    ///      at the mark, so the gate reads no window.
    /// @param c The case to bound and stage
    /// @return neutral The walk's neutral price (BAZAAR_SCALE precision)
    /// @return distance How far inside the mark the neutral price sits, in whole dollars
    function _stageAtTheNeutral(UnloadCase memory c) internal returns (uint256 neutral, uint256 distance) {
        uint256 size = bound(c.size, 2, 20);
        uint256 collateral = bound(c.collateral, 100, 2_000);
        uint256 fund = _insuranceBal() / BAZAAR_SCALE;
        uint256 reserve = _reserve(size * BTC) / BAZAAR_SCALE;
        uint256 free = bound(c.free, 0, reserve < fund ? reserve : fund);
        uint256 total = size * collateral;
        uint256 seized = bound(c.seized, 0, total < fund - free ? total : fund - free);
        uint256 leftover = bound(c.leftover, 0, 150);
        uint256 accrued = bound(c.funding, 0, 200);
        bool paid = !c.vaultReceives;
        // Funding the vault paid beyond the leftover moves the neutral price off the bankruptcy
        // price toward the mark; anything else leaves it held at the bankruptcy price.
        uint256 lift = paid && accrued > leftover ? accrued - leftover : 0;
        distance = bound(c.bankruptcyOffset, 0, 300);
        uint256 bk = c.shortInventory ? 50_000 + distance + lift : 50_000 - distance - lift;
        neutral = (c.shortInventory ? 50_000 + distance : 50_000 - distance) * BAZAAR_SCALE;
        _setVaultPendingLiq(size * BTC, c.shortInventory ? bk - collateral : bk + collateral, bk, !c.shortInventory);
        _stdstore.target(address(pair)).sig("pairVault()").depth(13).checked_write(seized * BAZAAR_SCALE);
        _setVaultLedgerArrears((total - seized + size * leftover) * BAZAAR_SCALE);
        int256 index = int256(accrued) * int256(BAZAAR_SCALE);
        _setVaultPendingLiqEntryFundingIndex(c.shortInventory == paid ? index : -index);
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write((seized + free) * BAZAAR_SCALE);
    }

    /// @notice A fill the walk takes as free leaves the inventory left its share of the arrears and
    ///         opens no window. With the fund at or under its reserve, the inventory at or above
    ///         water at the mark and a maker anywhere from the neutral price to the mark, every fill
    ///         costs the fund nothing by the walk's own measure. Across both sides, the earmark's
    ///         split between cash and arrears, arrears an earlier inventory left and funding the
    ///         vault paid or received, the arrears left are at least the inventory left's pro-rata
    ///         share of them, up to wei of rounding, no deficit is booked and no window opens.
    /// @param c The book, bounded and staged by _stageAtTheNeutral
    function testFuzz_unload_freeFill_keepsTheInventoryLeftItsShare(UnloadCase memory c) public {
        _deposit(carol, 100_000 * BAZAAR_SCALE);
        (uint256 neutral, uint256 distance) = _stageAtTheNeutral(c);
        uint256 size = bound(c.makerSize, 1, 30) * BTC / 10;
        uint256 offset = bound(c.makerOffset, 0, distance) * BAZAAR_SCALE;
        _placeLimit(carol, !c.shortInventory, size, c.shortInventory ? neutral - offset : neutral + offset);
        assertFalse(pair.isAdlPending(), "premise: no window");
        uint256 arrearsBefore = _ledgerArrears();
        uint256 sizeBefore = _pendingLiqSize();

        assertGt(_unloadVault(), 0, "premise: the walk took the free fill");

        assertEq(_deficit(), 0, "no deficit");
        assertFalse(pair.isAdlPending(), "a free fill carried the pair over no trigger");
        assertGe(
            _ledgerArrears() + 100,
            arrearsBefore * _pendingLiqSize() / sizeBefore,
            "the inventory left keeps its share of the arrears"
        );
    }
}
