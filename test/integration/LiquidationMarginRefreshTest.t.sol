// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";

/// @title LiquidationMarginRefreshTest
/// @notice liquidate judges at the lower of the stored margin curve and the one the price it runs
///         on gives, and stores the curve only after its walk, through the cooldown; executeAdl
///         refreshes the curve before it acts. The current rate follows the fund's coverage and
///         the open interest, and an insurance deposit moves the coverage without recomputing, so
///         the stored rate is the one in force before the deposit until something recomputes. A
///         position whose equity sits between the stored rate and the live one must survive a
///         liquidation call, inside the cooldown as well as after it.
contract LiquidationMarginRefreshTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BOOK_SIZE = 10 * BAZAAR_SCALE; // $500k a side at $50k: the seed fund covers it under target
    uint256 constant POSITION = BAZAAR_SCALE; // alice's 1 BTC long
    uint256 constant ALICE_COLLATERAL = 5_000 * BAZAAR_SCALE;
    uint256 constant DROP_USD = 46_600; // equity 1,600 on 46,600 of notional: 3.4%
    uint256 constant MMR_FLOOR_BP = RiskParamsLib.MIN_IMR_BP / 2; // the rate a fund at target yields at calm variance

    uint256 constant ESTATE = 5 * BAZAAR_SCALE;

    function setUp() public override {
        super.setUp();
        // Past warmup on both gates, the 15 days and the store count: inside it the 20% floor
        // pins the curve whatever the fund's coverage.
        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.WARMUP_DURATION + 1);
        _stdstore.target(address(pair)).sig("auxState()").depth(4)
            .checked_write(RiskParamsLib.WARMUP_PRICE_UPDATE_THRESHOLD);
    }

    /// @dev Permissionless store at `priceUsd` after aging the cache past MAX_PRICE_STALENESS and
    ///      the curve past IMR_UPDATE_COOLDOWN, so the store recomputes the rate.
    function _refreshAt(uint256 priceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        bytes[] memory pu = _priceAt(priceUsd);
        vm.prank(seq);
        pair.refreshPrice(pu);
    }

    function _mmrBp() internal view returns (uint256 mmrBp) {
        (, mmrBp,,) = pair.marginRequirements();
    }

    function _curveStampedAt() internal view returns (uint256 ts) {
        (,, ts,) = pair.marginRequirements();
    }

    /// @dev Hourly stores at `priceUsd` for `hoursHeld` hours: each closes an interval of the
    ///      sample ring at the rate then in force.
    function _holdAt(uint256 priceUsd, uint256 hoursHeld) internal {
        for (uint256 i = 0; i < hoursHeld; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            bytes[] memory pu = _priceAt(priceUsd);
            vm.prank(seq);
            pair.refreshPrice(pu);
        }
    }

    /// @dev A $500k book, then alice's 1 BTC long against dave under the rate that book yields.
    ///      The seed fund covers the book at under 1%, below the 2% target, so the recompute at
    ///      the next store lifts the rate off its floor, and the book holds it there for a day of
    ///      hourly samples: the lagged minimum every position is judged against is then the
    ///      lifted rate as well, so the threshold binds at the rate actually stored. The price
    ///      then falls to DROP_USD, where her equity is 3.4% of notional: under the lifted rate,
    ///      above the floor. Returns the lifted rate the store at DROP_USD leaves in storage.
    function _openAliceUnderTheLiftedRate() internal returns (uint256 liftedMmrBp) {
        _deposit(bob, 30_000 * BAZAAR_SCALE);
        // Carol's crossing ask is reserved for a fill at its own limit, $1k under the mark on 10
        // BTC: the $10k it could book there and the maker fee come on top of initial margin.
        _deposit(carol, 31_000 * BAZAAR_SCALE);
        _placeLimit(bob, true, BOOK_SIZE, 50_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(carol, false, BOOK_SIZE, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(bob), BOOK_SIZE, "fixture: the book is open");

        _refreshAt(50_000);
        assertGt(_mmrBp(), MMR_FLOOR_BP, "fixture: the thin fund lifts the rate off its floor");

        _deposit(alice, ALICE_COLLATERAL);
        _deposit(dave, 10_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, POSITION, 50_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(dave, false, POSITION, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), POSITION, "fixture: alice is long 1 BTC");

        // A day and change of the lifted rate in force, so no sample in the grace window predates it.
        _holdAt(50_000, 26);
        assertGt(pair.getLaggedMmr(), MMR_FLOOR_BP, "fixture: the lift has held for the grace period");

        _refreshAt(DROP_USD);
        liftedMmrBp = _mmrBp();
        assertGt(liftedMmrBp, MMR_FLOOR_BP, "fixture: the drop alone leaves the rate lifted");

        BazaarTypes.BucketState memory st = lens.checkBucketSolvency(address(pair), alice, DROP_USD * BAZAAR_SCALE);
        assertLt(
            st.availableEquity * BazaarTypes.BP_SCALE,
            liftedMmrBp * st.currentNotional,
            "fixture: under the lifted rate"
        );
        assertGt(
            st.availableEquity * BazaarTypes.BP_SCALE, MMR_FLOOR_BP * st.currentNotional, "fixture: above the floor"
        );
        assertFalse(st.isSolvent, "fixture: judged at the stored rate she is seizable");
    }

    /// @notice An insurance deposit that brings the fund past target removes the multiplier from
    ///         the live rate without recomputing. The liquidation call computes the live rate
    ///         before judging, so alice, solvent under it and not under the stored one, keeps her
    ///         position, and the call's write after its walk leaves the stored rate at the live one.
    function test_liquidate_recomputesTheCurveBeforeJudging() public {
        uint256 liftedMmrBp = _openAliceUnderTheLiftedRate();

        _depositInsurance(carol, 50_000 * BAZAAR_SCALE);
        assertEq(_mmrBp(), liftedMmrBp, "a deposit does not recompute the rate");

        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        bytes[] memory pu = _priceAt(DROP_USD);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(alice), pu), 0, "alice survives the live rate");
        assertEq(_posSize(alice), POSITION, "her position is intact");

        assertEq(_curveStampedAt(), vm.getBlockTimestamp(), "the call recomputed the curve");
        uint256 liveMmrBp = _mmrBp();
        assertLt(liveMmrBp, liftedMmrBp, "past target the multiplier is gone and the rate falls");
        assertGe(liveMmrBp, MMR_FLOOR_BP, "to the stress move, never under the floor");
        assertTrue(
            lens.checkBucketSolvency(address(pair), alice, DROP_USD * BAZAAR_SCALE).isSolvent,
            "judged at the stored rate she is solvent now"
        );
    }

    /// @notice The control: with no deposit the recompute finds the same coverage, the rate stays
    ///         lifted, and alice is seized under it. The recompute after the seizure then records
    ///         the coverage the inherited inventory leaves: the collateral banked with it exceeds
    ///         its loss at the mark, so the rate ends below the one she was judged at.
    function test_liquidate_control_withoutTheDepositSheIsSeized() public {
        uint256 liftedMmrBp = _openAliceUnderTheLiftedRate();

        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        bytes[] memory pu = _priceAt(DROP_USD);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "alice is seized under the lifted rate");
        assertEq(_posSize(alice), 0, "her position is gone");

        assertEq(_curveStampedAt(), vm.getBlockTimestamp(), "the call recomputed the curve");
        assertLt(_mmrBp(), liftedMmrBp, "the recorded rate reflects the coverage the seizure left");
    }

    /// @notice Inside the cooldown a fall in the live rate protects at once: the deposit takes the
    ///         fund past target a few seconds after the store, alice is judged at the live rate
    ///         and keeps her position, and the stored rate waits for the cooldown like any other.
    function test_liquidate_insideTheCooldown_aFallProtectsAtOnce() public {
        uint256 liftedMmrBp = _openAliceUnderTheLiftedRate();
        uint256 stampedAtTheStore = _curveStampedAt();

        _depositInsurance(carol, 50_000 * BAZAAR_SCALE);
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.MAX_PRICE_STALENESS + 1);
        assertLt(
            vm.getBlockTimestamp(),
            stampedAtTheStore + RiskParamsLib.IMR_UPDATE_COOLDOWN,
            "fixture: inside the cooldown"
        );
        bytes[] memory pu = _priceAt(DROP_USD);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(alice), pu), 0, "alice survives the live rate");
        assertEq(_posSize(alice), POSITION, "her position is intact");

        assertEq(_curveStampedAt(), stampedAtTheStore, "nothing was stored inside the cooldown");
        assertEq(_mmrBp(), liftedMmrBp, "the stored rate waits for it");
    }

    /// @notice Inside the cooldown alice is judged at the stored lifted rate, which the live curve
    ///         matches, and seized. The coverage the inventory leaves reaches storage with the
    ///         first refresh once the cooldown has passed, not inside it.
    function test_liquidate_insideTheCooldown_storesTheSeizureAfterIt() public {
        uint256 liftedMmrBp = _openAliceUnderTheLiftedRate();
        uint256 stampedAtTheStore = _curveStampedAt();

        vm.warp(vm.getBlockTimestamp() + BazaarTypes.MAX_PRICE_STALENESS + 1);
        assertLt(
            vm.getBlockTimestamp(),
            stampedAtTheStore + RiskParamsLib.IMR_UPDATE_COOLDOWN,
            "fixture: inside the cooldown"
        );
        bytes[] memory pu = _priceAt(DROP_USD);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "judged at the lifted rate, she is seized");

        assertEq(_curveStampedAt(), stampedAtTheStore, "nothing was stored inside the cooldown");
        assertEq(_mmrBp(), liftedMmrBp, "the stored rate is the store's");

        _refreshAt(DROP_USD);
        assertLt(_mmrBp(), liftedMmrBp, "the next refresh records the coverage the seizure left");
    }

    // ---------------- executeAdl ----------------

    /// @dev Dave's 5 BTC long at $52k against bob's 3 and alice's 2, seized at $36k: the loss past
    ///      his collateral exceeds the seed fund, so the window opens on the liquidation's own
    ///      verdict. The fund is then written down to $16k, under the collateral the seizure
    ///      banked, so a batch of bob alone leaves alice's slice, and the window, open.
    function _openPendingAuction() internal {
        _deposit(bob, 200_000 * BAZAAR_SCALE);
        _deposit(alice, 200_000 * BAZAAR_SCALE);
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        _placeLimitAt(bob, false, 3 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE, 52_000);
        _placeLimitAt(alice, false, 2 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE, 52_000);
        _roll(2);
        _placeLimitAt(dave, true, ESTATE, 52_000 * BAZAAR_SCALE, 52_000);
        assertEq(_posSize(dave), ESTATE, "fixture: dave long 5 @ 52k");

        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceAt(36_000);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(dave), pu), 1, "fixture: dave seized");
        assertTrue(pair.isAdlPending(), "fixture: the window is open");

        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(16_000 * BAZAAR_SCALE);
    }

    /// @notice executeAdl refreshes the curve before the gate and the batch sizing read it: past the
    ///         cooldown, the stamp the call leaves is its own.
    function test_executeAdl_recomputesTheCurveBeforeTheGate() public {
        _openPendingAuction();
        uint256 stampedAtLiquidation = _curveStampedAt();

        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION + 1);
        assertGt(
            vm.getBlockTimestamp(), stampedAtLiquidation + RiskParamsLib.IMR_UPDATE_COOLDOWN, "fixture: cooldown passed"
        );
        bytes[] memory pu = _priceAt(36_000);
        vm.prank(seq);
        pair.executeAdl(_arr1(bob), new address[](0), pu);

        assertEq(_posSize(bob), 0, "bob deleveraged");
        assertEq(_posSize(alice), 2 * BAZAAR_SCALE, "alice's slice is still open");
        assertTrue(pair.isAdlPending(), "the window stays open for it");
        assertEq(_curveStampedAt(), vm.getBlockTimestamp(), "the curve was recomputed at the call");
    }

    /// @notice A batch that closes the window inside a store's cooldown leaves that store's rate in
    ///         place: the store a moment earlier recorded it from the pending inventory, whose loss
    ///         leaves the fund almost no free capital, and the call's own refresh is inside its
    ///         cooldown. The rate the healed book yields reaches storage with the next refresh once
    ///         the cooldown has passed.
    function test_executeAdl_closingTheWindow_insideTheCooldown_storesItAfter() public {
        _openPendingAuction();
        // $81k: the $60k the seizure banked, the $20k loss past it at $36k, and $1k over, so the
        // window stays open on a thin coverage and the batch can heal it. The fund is written
        // rather than deposited, so the cash behind the books is minted to match: every verdict
        // compares the two first, and a short balance would fix the settlement instead.
        uint256 fund = _stdstore.target(address(pair)).sig("pairVault()").depth(5).read_uint();
        usdc.mint(address(pair), (81_000 * BAZAAR_SCALE - fund) / 1e12);
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(81_000 * BAZAAR_SCALE);

        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION + 1);
        _refreshAt(36_000);
        assertTrue(pair.isAdlPending(), "fixture: the window is still open");
        uint256 pendingMmrBp = _mmrBp();
        assertGt(pendingMmrBp, MMR_FLOOR_BP, "fixture: the pending inventory lifts the rate");
        uint256 stampedAtTheStore = _curveStampedAt();

        vm.warp(vm.getBlockTimestamp() + BazaarTypes.MAX_PRICE_STALENESS + 1);
        address[] memory cohort = new address[](2);
        cohort[0] = bob;
        cohort[1] = alice;
        bytes[] memory pu = _priceAt(36_000);
        vm.prank(seq);
        pair.executeAdl(cohort, new address[](0), pu);

        assertFalse(pair.isAdlPending(), "the window closed");
        assertEq(_curveStampedAt(), stampedAtTheStore, "nothing was stored inside the store's cooldown");
        assertEq(_mmrBp(), pendingMmrBp, "the pending inventory's rate stays until it passes");

        _refreshAt(36_000);
        assertLt(_mmrBp(), pendingMmrBp, "the next refresh records the healed book's rate");
    }
}
