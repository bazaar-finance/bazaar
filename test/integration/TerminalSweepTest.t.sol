// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title TerminalSweepTest
/// @notice Two-stage normal termination: fixSettlementPrice pins the settlement price and opens
///         a 1h terminal sweep window — liquidate() then runs at the FIXED price with an
///         equity <= 0 threshold and no oracle read — and finalizeTermination settles the book,
///         folding swept bad debt (pendingLiq + deficit) into the insurance/haircut waterfall.
///         Closes the "normal termination doesn't socialize open-position bad debt" hole
///         (first-come-first-served drain of insurance + other winners' collateral).
contract TerminalSweepTest is IntegrationBase {
    uint256 constant WINDOW = 1 hours; // BazaarPair.TERMINAL_SWEEP_WINDOW

    function _fix(uint256 priceUsd) internal {
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(priceUsd * BAZAAR_SCALE);
    }

    function _bucket(address u)
        internal
        view
        returns (bool isLong, uint256 size, uint256 entryValue, uint256 collateral)
    {
        (isLong, size, entryValue, collateral,,,,,,) = pair.positionBuckets(u);
    }

    function _pendingLiqSize() internal view returns (uint256 s) {
        (,,,,,, s,,,,,) = pair.pairVault();
    }

    // ============================ gating ============================

    /// @notice Finalize is gated on the sweep window and callable by anyone afterwards.
    function test_finalize_gatedOnWindow_thenPermissionless() public {
        // Nothing fixed yet → finalize reverts.
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.finalizeTermination();

        _fix(50_000);
        assertEq(pair.settlementPriceFixedTs(), vm.getBlockTimestamp(), "price fixed");
        assertFalse(pair.isPairTerminatedNormal(), "fixing is not termination");

        // Window still open → finalize reverts.
        vm.warp(vm.getBlockTimestamp() + WINDOW - 2);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.finalizeTermination();

        // After the window, ANY address finalizes at the fixed price.
        vm.warp(vm.getBlockTimestamp() + 3);
        vm.prank(makeAddr("randomKeeper"));
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminatedNormal(), "finalized");
        assertEq(pair.auxState().normalTerminationPrice, 50_000 * BAZAAR_SCALE, "settled at the fixed price");
    }

    /// @notice fixSettlementPrice is terminator-only, single-shot, and stamps
    ///         scheduledTerminationTs so all limbo guards engage (insurer/stale paths).
    function test_fix_onlyUma_singleShot_stampsSchedule() public {
        vm.expectRevert(); // onlyUma
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);

        assertEq(pair.scheduledTerminationTs(), 0, "no schedule before fix");
        _fix(50_000);
        assertEq(pair.scheduledTerminationTs(), vm.getBlockTimestamp(), "scheduledTs stamped by fix");

        vm.prank(pair.umaContract());
        vm.expectRevert(BazaarPair.BazaarPair__AlreadyTerminated.selector);
        pair.fixSettlementPrice(40_000 * BAZAAR_SCALE);
    }

    /// @notice During the window every user-facing withdrawal is frozen; the freeze lifts the
    ///         moment the pair finalizes.
    function test_window_freezesWithdrawals_liftsAtFinalize() public {
        _deposit(alice, 1_000 * BAZAAR_SCALE); // flat user — no position
        _fix(50_000);

        vm.prank(alice);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.withdrawCollateral(1 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");

        vm.prank(deployer);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "");

        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        pair.finalizeTermination();

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - before, 1_000 * USDC_SCALE, "freeze lifted at finalize");
    }

    // ============================ sweep threshold ============================

    /// @notice Sweep-mode solvency is equity <= 0 at the FIXED price — a position below any live
    ///         MMR but with positive equity at the settlement price must NOT be seized; it
    ///         settles fairly (collateral - loss) at withdrawal. Alice: 0.1 BTC long, entry
    ///         $50,050 notional, $10 collateral — hopelessly below maintenance margin, but $9 of
    ///         genuine equity at a $50,040 settlement.
    function test_sweep_belowMmrButPositiveEquity_notSeized_settlesFairly() public {
        _setupInsolventAlice(); // 0.1 long, entryValue 5_005e18, $10 collateral
        // _setupInsolventAlice writes only the bucket; mirror it into the vault aggregates so
        // the post-withdrawal position-close OI update can't underflow. pairVault base slot is
        // 6 (see TerminationTest's SLOT_VAULT_INSURANCE_FUND_BALANCE = 6 + 5): totalLongOI at
        // +0, longWeightedEntrySum at +2.
        vm.store(address(pair), bytes32(uint256(6)), bytes32(BAZAAR_SCALE / 10));
        vm.store(address(pair), bytes32(uint256(8)), bytes32(uint256(5_005 * BAZAAR_SCALE)));
        _fix(50_040); // equity = 10 - (5005 - 5004) = +9

        uint256 count = pair.liquidate(_arr1(alice), new bytes[](0));
        assertEq(count, 0, "positive equity at the fixed price: not seized despite being below MMR");
        assertEq(_posSize(alice), BAZAAR_SCALE / 10, "position untouched");

        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        pair.finalizeTermination();

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(9 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - before, 9 * USDC_SCALE, "settled to collateral - loss, not zero");
    }

    /// @notice A negative-equity-at-settlement position is sweepable with NO price update and no
    ///         Pyth fee — exactly what the dead-feed paths (post-cessation, 21-day stale) need.
    function test_sweep_negativeEquity_sweptWithDeadFeed() public {
        _setupInsolventAlice(); // deep underwater at $30k: equity = 10 - (5005 - 3000) = -1995
        vm.warp(vm.getBlockTimestamp() + 30 days); // feed long dead; no fresh price exists
        _fix(30_000);

        uint256 count = pair.liquidate(_arr1(alice), new bytes[](0)); // empty calldata, no ETH
        assertEq(count, 1, "swept at the fixed settlement price");
        assertEq(_posSize(alice), 0, "bucket seized");
        assertGt(_pendingLiqSize(), 0, "estate entered pendingLiq for waterfall settlement");
    }

    // ============================ end-to-end economics ============================

    /// @notice THE regression for the original finding: a gap leaves the loser with negative
    ///         equity at the settlement price. Swept during the window, the bad debt routes
    ///         through insurance and then haircuts the winner's PnL pro-rata — and the winner's
    ///         FULL exit succeeds, funded by the pot (no ledger underflow, no FCFS drain).
    function test_e2e_sweptBadDebt_haircutsWinner_fullExitCovered() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE); // 1 BTC, ~$50k entries, ~20k collateral each

        (,, uint256 aliceEntry, uint256 aliceColl) = _bucket(alice);
        // Discontinuity: settle at $23k → alice's loss (~27k) far exceeds her collateral (~20k).
        _fix(23_000);
        assertGt(aliceEntry - 23_000 * BAZAAR_SCALE, aliceColl, "setup: alice has negative equity");

        assertEq(pair.liquidate(_arr1(alice), new bytes[](0)), 1, "alice swept");
        assertEq(_posCollateral(alice), 0, "loser's bucket cleared by the sweep");

        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        pair.finalizeTermination();

        uint256 ratioBp = pair.auxState().normalTerminalWinnersPayoutRatioBp;
        assertLt(ratioBp, 10_000, "winner is haircut: bad debt was socialized, not ignored");
        assertGt(ratioBp, 7_000, "haircut is proportionate (insurance absorbed most of it)");

        // Bob exits IN FULL: first withdrawal realizes PnL x ratio into the bucket, second
        // drains it. Pre-fix this underflowed totalCollateralDeposited / overdrew the pot.
        uint256 cashBefore = usdc.balanceOf(address(pair));
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        pair.withdrawCollateral(1 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        uint256 rest = _posCollateral(bob);
        vm.prank(bob);
        pair.withdrawCollateral(rest, new bytes[](0), 0, 0, 0, "");

        uint256 received = usdc.balanceOf(bob) - bobBefore;
        assertGt(received, 40_000 * USDC_SCALE, "winner got principal + most of the haircut PnL");
        assertLe(received, cashBefore, "pot covered the full exit");
        assertEq(_posCollateral(bob), 0, "bob fully exited");
        _assertBooks("after full winner exit");
    }

    /// @notice Strictly-no-worse: if NO keeper sweeps during the window, finalize still works and
    ///         produces exactly today's behavior — winners at 100% against a pot that cannot
    ///         cover them (the residual FCFS hole the sweep exists to close). Documents why the
    ///         window matters rather than pretending it is a hard guarantee.
    function test_e2e_noSweep_finalizeStillWorks_residualHoleDocumented() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(23_000);
        // Nobody sweeps.
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        pair.finalizeTermination();

        assertEq(
            pair.auxState().normalTerminalWinnersPayoutRatioBp,
            10_000,
            "unswept bad debt is invisible: winners promised 100% (old behavior)"
        );

        // Bob realizes 100% of a ~27k win his counterparty cannot fund; the ledger stops the
        // over-claim only at the very end (underflow) — i.e. FCFS until the pot runs dry.
        vm.prank(bob);
        pair.withdrawCollateral(1 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        uint256 rest = _posCollateral(bob);
        vm.prank(bob);
        vm.expectRevert();
        pair.withdrawCollateral(rest, new bytes[](0), 0, 0, 0, "");
    }
}
