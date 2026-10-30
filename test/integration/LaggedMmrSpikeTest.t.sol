// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";

/// @title LaggedMmrSpikeTest
/// @notice A wash trade still open when the cooldown next lets the curve recompute lifts the
///         stored margin rate, and the lift outlives the wash until the following recompute; the
///         wash need only be open at that one refresh. Every position is judged at
///         the lower of the current rate and the lagged minimum, so a position filled during such
///         a lift is held to the lagged rate like any other, and a second lift later in the day
///         cannot seize it while it is solvent at every rate that has held. Inside one
///         transaction a wash reaches neither the stored rate nor the margin a liquidation's
///         unload asks of buyers. The same minimum takes in a dip the moment it is recorded, so a
///         position opened at a dipped rate is not seizable at the older rate one recompute
///         restores.
contract LaggedMmrSpikeTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BTC = 1e18;
    uint256 constant WASH = 20 * BTC;
    address victim = makeAddr("victim");
    address dave2 = makeAddr("dave2");
    address rival = makeAddr("rival");

    function setUp() public override {
        super.setUp();
        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.WARMUP_DURATION + 1);
        _stdstore.target(address(pair)).sig("auxState()").depth(4)
            .checked_write(RiskParamsLib.WARMUP_PRICE_UPDATE_THRESHOLD);
        usdc.mint(victim, 100_000 * USDC_SCALE);
        usdc.mint(dave2, 100_000 * USDC_SCALE);
        usdc.mint(rival, 100_000 * USDC_SCALE);
        usdc.mint(alice, 1_000_000 * USDC_SCALE);
        usdc.mint(bob, 1_000_000 * USDC_SCALE);
    }

    function _mmrBp() internal view returns (uint256 m) {
        (, m,,) = pair.marginRequirements();
    }

    /// @dev A limit order carrying a BTC print at `priceUsd`, stamped now and built before the prank.
    function _placeAt(address user, bool isLong, uint256 size, uint256 limitUsd, uint256 priceUsd) internal {
        bytes[] memory pu = _priceAt(priceUsd);
        vm.prank(user);
        pair.createOrder(_limitSpec(isLong, size, limitUsd * BAZAAR_SCALE), _hintsNone(), pu, 0, 0, 0, "", "");
    }

    function _refreshAt(uint256 priceUsd) internal {
        bytes[] memory pu = _priceAt(priceUsd);
        vm.prank(seq);
        pair.refreshPrice(pu);
    }

    /// @dev Opens `user` long 0.01 BTC at $50k on $25 against carol: seizable once the price falls.
    function _openThinLong(address user) internal {
        _deposit(user, 25 * BAZAAR_SCALE);
        _placeLimit(user, true, BTC / 100, 50_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(carol, false, BTC / 100, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(user), BTC / 100, "fixture: thin long open");
    }

    /// @dev Refreshes at `priceUsd` once an hour for `hoursHeld` hours, so every interval the ring
    ///      samples carries the rate the book in place sets.
    function _holdAt(uint256 priceUsd, uint256 hoursHeld) internal {
        for (uint256 i = 0; i < hoursHeld; i++) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _refreshAt(priceUsd);
        }
    }

    /// @dev Opens `WASH` between bob (long) and alice (short) at `priceUsd`.
    function _openWash(uint256 priceUsd) internal {
        _placeAt(bob, true, WASH, priceUsd, priceUsd);
        _roll(2);
        _placeAt(alice, false, WASH, priceUsd - 400, priceUsd);
        assertEq(_posSize(alice), WASH, "the wash is open");
    }

    /// @dev Closes the wash _openWash opened.
    function _closeWash(uint256 priceUsd) internal {
        _roll(2);
        _placeAt(alice, true, WASH, priceUsd, priceUsd);
        _roll(2);
        _placeAt(bob, false, WASH, priceUsd - 400, priceUsd);
        assertEq(_posSize(alice), 0, "the wash is closed");
        assertEq(_posSize(bob), 0, "on both sides");
    }

    /// @dev Opens the wash at `priceUsd` and keeps it open until the cooldown lets a refresh
    ///      recompute, so that refresh stores the rate its open interest gives. The wash stays open.
    ///      Returns that rate.
    function _lift(uint256 priceUsd) internal returns (uint256 lifted) {
        _openWash(priceUsd);
        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        _refreshAt(priceUsd);
        lifted = _mmrBp();
    }

    function test_positionFilledDuringALiftIsJudgedAtTheLaggedRate() public {
        _deposit(carol, 10_000 * BAZAAR_SCALE);

        // The victim rests a 1 BTC bid on enough margin for today's IMR.
        _deposit(victim, 2_100 * BAZAAR_SCALE);
        _placeLimit(victim, true, BTC, 48_300 * BAZAAR_SCALE);

        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        _refreshAt(48_400);
        uint256 floorMmr = _mmrBp();
        assertEq(floorMmr, RiskParamsLib.MIN_IMR_BP / 2, "fixture: the rate sits at its floor");
        _deposit(alice, 500_000 * BAZAAR_SCALE);
        _deposit(bob, 500_000 * BAZAAR_SCALE);

        // First lift, outliving the wash until the next refresh. While it stands the victim tops
        // up to just above the lifted IMR on its whole bid, and the bid fills: the fill passes the
        // lifted IMR.
        uint256 lifted = _lift(48_400);
        assertGt(lifted, floorMmr, "the wash lifted the stored rate");
        _closeWash(48_400);
        assertEq(_mmrBp(), lifted, "the lift outlives the wash");
        uint256 targetUsd = 2 * lifted * 48_400 / 10_000 + 50;
        _deposit(victim, (targetUsd - 2_100) * BAZAAR_SCALE);
        _placeAt(carol, false, BTC, 48_000, 48_400);
        assertEq(_posSize(victim), BTC, "the victim's bid filled under the lifted rate");

        BazaarTypes.BucketState memory st = lens.checkBucketSolvency(address(pair), victim, 48_400 * BAZAAR_SCALE);
        assertEq(
            st.minRequiredCollateral,
            floorMmr * st.currentNotional / 10_000,
            "a position filled during the lift is held to the lagged rate, not the lifted one"
        );

        // The price falls; at the honest rate the victim is comfortably solvent.
        vm.warp(vm.getBlockTimestamp() + 2 minutes);
        _refreshAt(45_000);
        st = lens.checkBucketSolvency(address(pair), victim, 45_000 * BAZAAR_SCALE);
        assertTrue(st.isSolvent, "solvent at the lagged rate");

        // A second lift inside the day, and a liquidation aimed at the victim while it stands.
        uint256 lifted2 = _lift(45_000);
        st = lens.checkBucketSolvency(address(pair), victim, 45_000 * BAZAAR_SCALE);
        assertLt(
            st.availableEquity,
            lifted2 * st.currentNotional / 10_000,
            "fixture: judged at the lifted rate alone, the victim would be seized"
        );
        assertTrue(st.isSolvent, "judged at the lagged rate it is not");

        bytes[] memory pu = _priceAt(45_000);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(victim), pu), 0, "the second lift seizes nobody");
        assertEq(_posSize(victim), BTC, "the victim keeps its position");
        _closeWash(45_000);
    }

    /// @notice A wash opened, a seizable account liquidated and the wash unwound, all at one
    ///         timestamp, leave the stored rate where it was. The liquidation judges at the lower of
    ///         the stored curve and the live one, and stores its own only through the cooldown,
    ///         which the refresh before the wash already holds. A bid filled afterwards is held to
    ///         the unlifted rate.
    function test_washAndLiquidationInOneTransactionLeaveTheRateUnlifted() public {
        _deposit(carol, 10_000 * BAZAAR_SCALE);
        _openThinLong(dave);
        _deposit(victim, 10_000 * BAZAAR_SCALE);
        _placeLimit(victim, true, BTC, 48_300 * BAZAAR_SCALE);

        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        _refreshAt(48_400);
        uint256 floorMmr = _mmrBp();
        assertEq(floorMmr, RiskParamsLib.MIN_IMR_BP / 2, "fixture: the rate sits at its floor");
        _deposit(alice, 500_000 * BAZAAR_SCALE);
        _deposit(bob, 500_000 * BAZAAR_SCALE);

        uint256 t = vm.getBlockTimestamp();
        _openWash(48_400);
        bytes[] memory pu = _priceAt(48_400);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(dave), pu), 1, "dave is seized");
        _closeWash(48_400);
        assertEq(vm.getBlockTimestamp(), t, "one timestamp throughout");
        assertEq(_mmrBp(), floorMmr, "the wash never reached the stored rate");

        _placeAt(carol, false, BTC, 48_000, 48_400);
        assertEq(_posSize(victim), BTC, "the victim's bid filled");
        BazaarTypes.BucketState memory st = lens.checkBucketSolvency(address(pair), victim, 48_400 * BAZAAR_SCALE);
        assertEq(st.minRequiredCollateral, floorMmr * st.currentNotional / 10_000, "held to the unlifted rate");
    }

    /// @notice The same sequence when the cooldown has already run out: the wash's own first order
    ///         refreshes the curve before it fills, storing the rate the book gives without the wash
    ///         and stamping the cooldown, so neither the liquidation's rate nor its write after the
    ///         walk can carry the wash.
    function test_washAndLiquidationAfterTheCooldownLeaveTheRateUnlifted() public {
        _deposit(carol, 10_000 * BAZAAR_SCALE);
        _openThinLong(dave);
        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        _refreshAt(48_400);
        uint256 floorMmr = _mmrBp();
        _deposit(alice, 500_000 * BAZAAR_SCALE);
        _deposit(bob, 500_000 * BAZAAR_SCALE);

        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        (,, uint256 stampedBefore,) = pair.marginRequirements();
        assertGe(
            vm.getBlockTimestamp(),
            stampedBefore + RiskParamsLib.IMR_UPDATE_COOLDOWN,
            "fixture: the cooldown has run out"
        );
        uint256 t = vm.getBlockTimestamp();
        _openWash(48_400);
        (,, uint256 stamped,) = pair.marginRequirements();
        assertEq(stamped, t, "the wash's first order refreshed and stamped the curve before it filled");

        bytes[] memory pu = _priceAt(48_400);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(dave), pu), 1, "dave is seized");
        _closeWash(48_400);
        assertEq(vm.getBlockTimestamp(), t, "one timestamp throughout");
        assertEq(_mmrBp(), floorMmr, "the wash never reached the stored rate");
    }

    /// @notice A wash opened earlier in the same transaction does not raise the margin a
    ///         liquidation's unload asks of the bids it sells into: a bid margined for the stored
    ///         rate, and not for the lifted one, still buys the seized position.
    function test_washDoesNotRaiseTheMarginTheUnloadAsksOfBuyers() public {
        _deposit(carol, 10_000 * BAZAAR_SCALE);
        // Dave2 long 1 BTC at $50k on a sliver over the floor IMR: seizable at $48,400.
        _deposit(dave2, 2_100 * BAZAAR_SCALE);
        _placeLimit(dave2, true, BTC, 50_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(carol, false, BTC, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(dave2), BTC, "fixture: dave2 is long 1 BTC");

        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        _refreshAt(48_400);
        uint256 floorMmr = _mmrBp();
        _deposit(alice, 500_000 * BAZAAR_SCALE);
        _deposit(bob, 500_000 * BAZAAR_SCALE);

        // What the wash's open interest lifts the rate to once it is stored, then back down.
        uint256 lifted = _lift(48_400);
        _closeWash(48_400);
        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        _refreshAt(48_400);
        assertEq(_mmrBp(), floorMmr, "fixture: the rate is back at its floor");

        // The rival bids for 1 BTC on margin for the floor IMR and well short of the lifted one.
        uint256 rivalUsd = 2_300;
        assertGt(rivalUsd, 2 * floorMmr * 48_400 / 10_000 + 100, "fixture: the rival carries the floor IMR");
        assertLt(rivalUsd, 2 * lifted * 48_400 / 10_000, "fixture: and could not carry the lifted one");
        _deposit(rival, rivalUsd * BAZAAR_SCALE);
        _placeAt(rival, true, BTC, 48_300, 48_400);

        // One timestamp: the wash opens, dave2 is liquidated and the unload sells into the book.
        _openWash(48_400);
        bytes[] memory pu = _priceAt(48_400);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(dave2), pu), 1, "dave2 is seized");
        assertEq(_posSize(rival), BTC, "the rival's bid bought the seized position");
        _closeWash(48_400);
    }

    /// @notice The grace period is counted back from the stored mark, not from the block: a lift
    ///         that has held for a day of wall time but not a day of marks is still held back.
    function test_lookbackIsMeasuredFromTheStoredMark() public {
        _deposit(carol, 10_000 * BAZAAR_SCALE);
        _deposit(alice, 500_000 * BAZAAR_SCALE);
        _deposit(bob, 500_000 * BAZAAR_SCALE);
        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        _refreshAt(48_400);
        uint256 floorMmr = _mmrBp();
        _holdAt(48_400, 2);

        // The wash lifts the rate from the next recompute on, held through 23 hours of marks.
        _openWash(48_400);
        _holdAt(48_400, 23);
        assertGt(_mmrBp(), floorMmr, "fixture: the wash lifted the rate");
        assertEq(pair.getLaggedMmr(), floorMmr, "fixture: the lift has not held for a day of marks");

        // Two more hours pass with no new mark: a day of wall time since the lift, not of marks.
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        assertEq(pair.getLaggedMmr(), floorMmr, "the stored mark, not the block, dates the window");

        // A fresh mark moves the window onto the lift.
        _refreshAt(48_400);
        assertGt(pair.getLaggedMmr(), floorMmr, "measured from the new mark, the lift has held a day");
    }

    function test_positionOpenedInADipIsHeldToTheDipWhenTheRateRecovers() public {
        _deposit(carol, 10_000 * BAZAAR_SCALE);
        _deposit(alice, 500_000 * BAZAAR_SCALE);
        _deposit(bob, 500_000 * BAZAAR_SCALE);
        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        _refreshAt(48_400);
        uint256 floorMmr = _mmrBp();

        // A wash held open for a day lifts the rate in every interval the ring samples.
        _openWash(48_400);
        _holdAt(48_400, 26);
        uint256 dayRate = pair.getLaggedMmr();
        assertGt(dayRate, floorMmr, "fixture: the lifted rate has held for the grace period");

        // Inside the interval the last refresh opened, the wash unwinds and the next recompute
        // drops the rate.
        uint256 intervalOpened = vm.getBlockTimestamp();
        _closeWash(48_400);
        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        _refreshAt(48_400);
        uint256 dip = _mmrBp();
        assertLt(dip, dayRate, "fixture: the rate dipped");

        // The victim buys 1 BTC on just over the dipped IMR.
        _deposit(victim, (2 * dip * 48_400 / 10_000 + 50) * BAZAAR_SCALE);
        _placeAt(victim, true, BTC, 48_400, 48_400);
        _roll(2);
        _placeAt(carol, false, BTC, 48_000, 48_400);
        assertEq(_posSize(victim), BTC, "the victim's bid filled at the dipped IMR");

        // The wash reopens and one recompute restores the lifted rate, still inside the interval.
        _openWash(48_400);
        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.IMR_UPDATE_COOLDOWN + 1);
        _refreshAt(48_400);
        assertLt(vm.getBlockTimestamp(), intervalOpened + 1 hours, "fixture: one interval throughout");
        uint256 restored = _mmrBp();
        uint256 withoutTheDip = restored < dayRate ? restored : dayRate;

        BazaarTypes.BucketState memory st = lens.checkBucketSolvency(address(pair), victim, 48_400 * BAZAAR_SCALE);
        assertLt(
            st.availableEquity,
            withoutTheDip * st.currentNotional / 10_000,
            "fixture: judged at the day's samples and the restored rate alone, the victim would be seized"
        );
        assertEq(
            st.minRequiredCollateral,
            dip * st.currentNotional / 10_000,
            "the dip is in the lagged minimum from the moment it was recorded"
        );
        assertTrue(st.isSolvent, "the victim is solvent at every rate in force since it opened");

        bytes[] memory pu = _priceAt(48_400);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(victim), pu), 0, "the recovery seizes nobody");
        assertEq(_posSize(victim), BTC, "the victim keeps its position");
    }
}
