// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title TerminalSweepTest
/// @notice Two-stage normal termination, frozen-ratio design: fixSettlementPrice pins the price
///         and opens a 48h settlement window in which the permissionless settleTerminalPositions
///         marks every position to the fixed price (registering winner claims and bad debt), then
///         finalizeTermination charges bad debt to insurance and freezes the profit ratio from
///         ACTUAL cash surplus. Principal is reserved at all times; profits pay only from
///         surplus = cash - D - I. Guarantee under test: no one's deposit is ever lost to another
///         party's bankruptcy; profit shortfalls are shared at one uniform percentage.
contract TerminalSweepTest is IntegrationBase {
    uint256 constant WINDOW = 48 hours; // BazaarPair.TERMINAL_SETTLEMENT_WINDOW

    function _fix(uint256 priceUsd) internal {
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(priceUsd * BAZAAR_SCALE);
    }

    function _finalize() internal {
        vm.warp(vm.getBlockTimestamp() + WINDOW + 1);
        pair.finalizeTermination();
    }

    /// @dev Terminal settlement reuses the liquidate() entry point once the price is fixed.
    function _settle(address u) internal returns (uint256) {
        return pair.liquidate(_arr1(u), new bytes[](0));
    }

    function _settleMany(address[] memory users) internal returns (uint256) {
        return pair.liquidate(users, new bytes[](0));
    }

    function _bucket(address u)
        internal
        view
        returns (bool isLong, uint256 size, uint256 entryValue, uint256 collateral)
    {
        (isLong, size, entryValue, collateral,,,,,,) = pair.positionBuckets(u);
    }

    /// @dev Withdraw a user's entire terminal entitlement. The registered-profit / junior credit
    ///      lands in the bucket on the FIRST post-finalize withdraw (before the amount is checked),
    ///      so a first pass pays principal and a second pass drains the credited profit.
    function _withdrawAll(address u) internal returns (uint256 total) {
        uint256 before = usdc.balanceOf(u);
        for (uint256 i = 0; i < 2; i++) {
            (,,, uint256 c) = _bucket(u);
            if (c == 0) break;
            vm.prank(u);
            pair.withdrawCollateral(c, new bytes[](0), 0, 0, 0, "");
        }
        total = usdc.balanceOf(u) - before;
    }

    // ============================ gating ============================

    /// @notice Finalize is gated on the 48h window and callable by anyone afterwards.
    function test_finalize_gatedOnWindow_thenPermissionless() public {
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.finalizeTermination();

        _fix(50_000);
        assertEq(pair.settlementPriceFixedTs(), vm.getBlockTimestamp(), "price fixed");
        assertFalse(pair.isPairTerminatedNormal(), "fixing is not termination");

        vm.warp(vm.getBlockTimestamp() + WINDOW - 2);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.finalizeTermination();

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

    /// @notice During the window every user-facing withdrawal is frozen; the freeze lifts at
    ///         finalize, and settlement is blocked entirely (no live liquidation engine).
    function test_window_freezesWithdrawals_liftsAtFinalize() public {
        _deposit(alice, 1_000 * BAZAAR_SCALE); // flat user — no position
        _fix(50_000);

        vm.prank(alice);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.withdrawCollateral(1 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");

        vm.prank(deployer);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "");

        // liquidate() during the window is the settlement entry point, not the live engine:
        // alice is flat (no position) so it settles 0 and returns without reverting.
        assertEq(pair.liquidate(_arr1(alice), new bytes[](0)), 0, "flat user: nothing to settle");

        _finalize();

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - before, 1_000 * USDC_SCALE, "freeze lifted at finalize");
    }

    // ============================ settlement is harmless accounting ============================

    /// @notice Settlement is permissionless, needs no price update or ETH, and never seizes: a
    ///         position with positive equity keeps that equity, less only the settlement fee
    ///         charged to its own collateral. (0.1 BTC long, $10 collateral, ~$50,050 entry,
    ///         settled at $50,040 -> $9 equity, minus 2 bp of the $5,004 notional = $1.0008.)
    ///         The fee looks large against the remaining equity here ($1 of $9) ONLY because
    ///         _setupInsolventAlice writes the bucket via stdstore, bypassing margin: ~500x
    ///         leverage, 55x past the 10% MMR that would have liquidated it. A position that
    ///         exists under real margin rules holds equity >= MMR x notional, making the same fee
    ///         <= 0.2% of equity.
    function test_settle_positiveEquity_keepsEquityLessFee() public {
        _setupInsolventAlice(); // bucket only; seed matching OI so settlement OI-decrement is exact
        vm.store(address(pair), bytes32(uint256(6)), bytes32(BAZAAR_SCALE / 10)); // totalLongOI
        vm.store(address(pair), bytes32(uint256(8)), bytes32(uint256(5_005 * BAZAAR_SCALE))); // longWeightedEntrySum
        _fix(50_040);

        assertEq(_settle(alice), 1, "position settled");
        (, uint256 size,,) = _bucket(alice);
        assertEq(size, 0, "position closed by settlement");

        // Equity ($9) less the settlement fee, charged to her own collateral — not seized.
        uint256 notional = (BAZAAR_SCALE / 10) * 50_040; // size x settlement price
        uint256 fee = notional * 2 / 10_000; // 2 bp
        (,,, uint256 remaining) = _bucket(alice);
        assertEq(remaining, 9 * BAZAAR_SCALE - fee, "equity minus the settlement fee");

        _finalize();
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(remaining, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - before, remaining / 1e12, "she withdraws the full remainder");
    }

    /// @notice A deep-underwater position settles with no price update (dead-feed safe): its loss
    ///         releases from the principal ledger and its uncovered portion registers as bad debt.
    function test_settle_negativeEquity_deadFeed_releasesAndRegisters() public {
        _setupInsolventAlice(); // 0.1 long, $10 collateral, entry ~$50,050
        vm.store(address(pair), bytes32(uint256(6)), bytes32(BAZAAR_SCALE / 10));
        vm.store(address(pair), bytes32(uint256(8)), bytes32(uint256(5_005 * BAZAAR_SCALE)));
        vm.warp(vm.getBlockTimestamp() + 30 days); // feed long dead
        uint256 dBefore = _totalDeposited();
        _fix(30_000); // equity = 10 - (5005 - 3000) = -1995, collateral only covers 10

        assertEq(_settle(alice), 1, "swept at the fixed price, empty calldata"); // no ETH, no priceUpdate
        (, uint256 size,,) = _bucket(alice);
        assertEq(size, 0, "bucket cleared");
        assertLt(_totalDeposited(), dBefore, "loss released from the principal ledger");
    }

    // ============================ end-to-end economics ============================

    /// @notice THE guarantee: a gap makes the loser deeply insolvent, yet the winner's PRINCIPAL
    ///         is fully paid and profits are shared at one uniform ratio — no FCFS drain, no
    ///         ledger underflow, and the loser's deposit floor holds.
    function test_e2e_insolventLoser_winnerPrincipalSafe_profitsProRata() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE); // 1 BTC, ~$50k entries, ~20k collateral each

        (,, uint256 aliceEntry, uint256 aliceColl) = _bucket(alice);
        _fix(23_000); // alice (long) loss ~27k >> her ~20k collateral: deep insolvency
        assertGt(aliceEntry - 23_000 * BAZAAR_SCALE, aliceColl, "setup: alice negative equity");

        // Bots settle both sides during the window (permissionless, batched).
        address[] memory both = new address[](2);
        both[0] = alice;
        both[1] = bob;
        assertEq(_settleMany(both), 2, "both settled in-window");

        _finalize();

        // Winner (bob): full principal + profit at the frozen ratio (85.67% here). His registered
        // 28k profit claim (short from 51k to 23k) is credited on withdraw and paid pro-rata.
        uint256 ratioBp = pair.auxState().normalTerminalWinnersPayoutRatioBp;
        assertGt(ratioBp, 8_000, "meaningful pro-rata ratio");
        assertLe(ratioBp, 10_000, "ratio <= 100%");
        uint256 cashBefore = usdc.balanceOf(address(pair));
        uint256 received = _withdrawAll(bob);
        assertGt(received, 20_000 * USDC_SCALE, "winner recovered principal PLUS profit");
        assertLe(received, cashBefore, "pot covered the withdrawal");
        _assertBooks("after winner exit");

        // Loser (alice) had negative equity → zero collateral remains; nothing to withdraw.
        assertEq(_withdrawAll(alice), 0, "insolvent loser's collateral fully consumed by loss");
        _assertBooks("after loser exit");
    }

    /// @notice Unsettled winner (bots missed them) still gets principal, and their profit falls to
    ///         the junior path at first withdrawal — inline self-settlement books it post-finalize.
    ///         Solvent book -> they still collect in full from the leftover surplus.
    function test_e2e_unsettledWinner_selfSettlesAtWithdraw() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(60_000); // alice (long) wins ~10k; solvent (bob's collateral covers it)

        // Nobody settles bob's counterpart loss or alice's win during the window.
        _finalize();

        // Settle bob (the loser) first so his forfeited collateral becomes surplus backing alice's
        // junior credit. Alice was never settled during the window, so her withdraw self-settles
        // her open position (junior path: immediate credit clipped to surplus) then pays out.
        _settle(bob);
        uint256 received = _withdrawAll(alice);
        assertGt(received, 20_000 * USDC_SCALE, "principal + junior-path profit from surplus");
        _assertBooks("after unsettled winner self-settles");
    }

    /// @notice Solvency invariant across a fuzzed settlement price: cumulative withdrawable never
    ///         exceeds the cash held (the core no-loss-of-principal property).
    function testFuzz_solvencyHolds(uint256 priceUsd) public {
        priceUsd = bound(priceUsd, 1_000, 200_000);
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(priceUsd);
        address[] memory both = new address[](2);
        both[0] = alice;
        both[1] = bob;
        _settleMany(both);
        _finalize();
        _assertBooks("post-finalize solvency");
    }

    /// @notice A winner with no collateral pays the settlement bounty out of its registered
    ///         profit claim, transferred to the settler as claim units: no cash moves during the
    ///         window (so the pot backing the frozen ratio is not diluted), and the settler
    ///         collects the bounty pro-rata after finalize like any other winner.
    function test_settle_zeroCollateralWinner_bountyTransfersClaim() public {
        // Real book: carol (long 1 BTC) wins big, bob (short) is left deeply insolvent at the
        // settlement price, so the frozen ratio lands strictly below 100% — the regime where a
        // cash-paid bounty would dilute the other winners.
        _openPosition(bob, carol, false, BAZAAR_SCALE);
        // Zero-collateral winner: 0.1 BTC long at $50,050 entry with no deposit behind it, the
        // state a position-holder reaches when fees ground away the retained-collateral floor.
        _writePosition(alice, true, BAZAAR_SCALE / 10, 5_005 * BAZAAR_SCALE);
        // Seed the OI aggregates for the synthetic bucket so settlement's decrement is exact.
        vm.store(
            address(pair),
            bytes32(uint256(6)),
            bytes32(uint256(vm.load(address(pair), bytes32(uint256(6)))) + BAZAAR_SCALE / 10)
        ); // totalLongOI
        vm.store(
            address(pair),
            bytes32(uint256(8)),
            bytes32(uint256(vm.load(address(pair), bytes32(uint256(8)))) + 5_005 * BAZAAR_SCALE)
        ); // longWeightedEntrySum

        _fix(80_000); // alice +$2,995; bob (short) loses ~$30k on ~$20k collateral

        address[] memory both = new address[](2);
        both[0] = bob;
        both[1] = carol;
        _settleMany(both);

        // The keeper settles alice and receives NO cash: her bounty is a claim transfer.
        address keeper = makeAddr("terminalKeeper");
        uint256 cashBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        assertEq(pair.liquidate(_arr1(alice), new bytes[](0)), 1, "zero-collateral winner settled");
        assertEq(usdc.balanceOf(keeper), cashBefore, "bounty paid in claim units, not cash");

        _finalize();
        uint256 ratioBp = pair.auxState().normalTerminalWinnersPayoutRatioBp;
        assertGt(ratioBp, 0, "ratio meaningful");
        assertLt(ratioBp, 10_000, "underwater book: sub-100% frozen ratio");

        // Bounty = max($0.10, 2 bp of the 0.1 BTC x $80k notional) = $1.60, now held by the
        // keeper as a registered claim and paid at the same frozen ratio as every winner.
        uint256 bounty = 16 * BAZAAR_SCALE / 10;
        uint256 keeperPay = bounty * ratioBp / 10_000;
        uint256 kBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        pair.withdrawCollateral(keeperPay, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(keeper) - kBefore, keeperPay / 1e12, "settler collects bounty x ratio");

        // Alice keeps the rest of her claim at the same ratio (loose bound: her ~$2,995 claim
        // less the $1.60 bounty, paid pro-rata, comfortably exceeds $2,000 x ratio).
        uint256 aliceFloor = 2_000 * BAZAAR_SCALE * ratioBp / 10_000;
        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(aliceFloor, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - aBefore, aliceFloor / 1e12, "winner's remaining claim pays pro-rata");
        _assertBooks("after claim-unit bounty payouts");
    }

    // ============================ insurance is junior to principal ============================

    /// @notice End to end: a black-swan normal termination (books-vs-balance drift leaves
    ///         cash < D) must write the insurance fund's claim down to zero. Were I to survive on
    ///         the books, post-termination insurance withdrawals (cooldown-exempt) would pull real
    ///         USDC out of a pot already committed to the haircut principal, and the last principal
    ///         withdrawal would revert — a seniority inversion. Written down, the junior claim pays
    ///         zero and principal recovers the entire remaining pot, even when the insurer exits
    ///         FIRST.
    function test_N1_blackSwan_insuranceClaimZeroed_seniorityHolds() public {
        // Flat principal depositor: D = 10,000. Insurance I = 4,000 (deployer's factory seed).
        _deposit(alice, 10_000 * BAZAAR_SCALE);
        assertEq(_insuranceBal(), 4_000 * BAZAAR_SCALE, "setup: seeded insurance fund");

        // The precondition — an UNREGISTERED cash shortfall (the termination path alone
        // cannot produce one): USDC leaves the pair with no ledger deduction anywhere.
        // Cash 14,000 -> 7,500, below D = 10,000.
        vm.prank(address(pair));
        usdc.transfer(makeAddr("driftSink"), 6_500 * USDC_SCALE);

        _fix(50_000);
        _finalize();

        // The insurers' book claim is written down to the post-principal residual (0).
        assertEq(_insuranceBal(), 0, "insurance claim zeroed when cash < D");

        // The junior claimant exits FIRST — and must extract nothing. Post-termination,
        // request + execute run back-to-back (cooldown/window gates are terminated-exempt).
        uint256 seedShares = pair.insuranceShares(deployer);
        assertGt(seedShares, 0, "deployer holds the seed LP shares");
        bytes[] memory pu = _priceAt(50_000); // build BEFORE the prank (mockPyth call consumes it)
        vm.prank(deployer);
        pair.requestInsuranceWithdrawal(seedShares, 0, 0, 0, "", "");
        uint256 insurerBefore = usdc.balanceOf(deployer);
        vm.prank(deployer);
        pair.executeInsuranceWithdrawal(pu, 0, 0, 0, "");
        assertEq(usdc.balanceOf(deployer) - insurerBefore, 0, "junior claim pays zero");

        // Principal then recovers the ENTIRE remaining pot at the uniform cash/D haircut
        // (7,500/10,000 = 75%). Had the junior claim paid out anything above, this transfer would
        // revert on a pot short by exactly that amount.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(7_500 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - aliceBefore, 7_500 * USDC_SCALE, "principal pays at cash/D");
        assertEq(usdc.balanceOf(address(pair)), 0, "pot exactly exhausted, no phantom claim left");
    }
}
