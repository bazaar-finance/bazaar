// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {BucketStore} from "../BucketStore.sol";

/// @title CrisisBackstopIntegrationTest
/// @notice The protocol's last-resort insolvency backstops, end-to-end: a recorded deficit
///         terminates the pair on the next health check (Check 0), a stuck ADL past the 24h
///         timeout terminates via the equity path, and an insurer-vote consensus that outlives
///         its execution window refunds the bond WITHOUT terminating.
contract CrisisBackstopIntegrationTest is IntegrationBase {
    using stdStorage for StdStorage;

    /// @notice Check 0: a non-zero realized deficit (bad debt that overran insurance) terminates
    ///         the pair at the live price on the very next vault-health evaluation, closing the
    ///         first-come-first-served withdrawal window.
    function test_e2e_Deficit_TerminatesPairOnNextHealthCheck() public {
        // Record phantom bad debt directly (the netting-overrun producer is unit-tested elsewhere).
        _stdstore.target(address(pair)).sig("pairVault()").depth(11).checked_write(100 * BAZAAR_SCALE);
        (,,,,,,,,,,, uint256 deficit,,) = pair.pairVault();
        assertEq(deficit, 100 * BAZAAR_SCALE, "deficit seeded");

        // Any liquidation re-runs isVaultHealthy; Check 0 fires before everything else.
        _setupInsolventAlice();
        // A seeded deficit and the phantom underwater position don't move real cash, so the books
        // are still balanced right up to the terminating call.
        _assertBooksSettled("deficit: before terminating liquidation");

        vm.prank(bob);
        pair.liquidate(_arr1(alice), _freshPrice());

        // Two-stage insolvency: the deficit check FIXES the settlement price and opens the
        // settlement window (freezing withdrawals immediately — the point of Check 0) rather than
        // terminating mid-transaction. Finalize completes it, folding the deficit into what is
        // owed and charging it to the insurers' residual.
        assertGt(pair.settlementPriceFixedTs(), 0, "deficit opened the settlement window");
        assertFalse(pair.isPairTerminated(), "not terminated until finalize");

        // The pair is halted: no further deposits — INCLUDING at the stamping timestamp itself.
        // The deposit sweep guard keys on settlementPriceFixedTs directly (no timestamp
        // comparison), so there is no same-second window in which the settlement price is
        // already known but new principal still enters. Both terminator entry points are
        // permissionless, so such a window would be reachable atomically rather than only via
        // Arbitrum's shared block timestamps — the same-second leg below is the one that matters.
        vm.startPrank(carol);
        usdc.approve(address(pair), 2 * USDC_SCALE);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.depositCollateral(1 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.depositCollateral(1 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.stopPrank();

        // Nothing is left open (alice was liquidated), so anyone finalizes at once.
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminated(), "deficit settled the pair via the equity path");
    }

    /// @notice Check 0 while an accepted scheduled termination's cutoff is still in the future:
    ///         fixing the settlement price pulls scheduledTerminationTs back to now, so the sweep
    ///         window opens with matching, orders and deposits halted — rather than a market
    ///         trading live at the oracle price whose only exit is the frozen settlement price.
    function test_e2e_Deficit_DuringScheduledNotice_HaltsMarketAtFix() public {
        // An accepted scheduled-termination proposal leaves the cutoff in the future: trading is
        // meant to continue until then, so every cutoff-keyed guard is still open when the
        // deficit lands.
        uint256 futureCutoff = vm.getBlockTimestamp() + 3 days;
        _stdstore.target(address(pair)).sig("scheduledTerminationTs()").checked_write(futureCutoff);
        _stdstore.target(address(pair)).sig("pairVault()").depth(11).checked_write(100 * BAZAAR_SCALE);

        // The notice period keeps the LIVE liquidation path open; its post-liquidation health
        // check hits Check 0 and fixes the settlement price at the live price.
        _setupInsolventAlice();
        vm.prank(bob);
        pair.liquidate(_arr1(alice), _freshPrice());

        assertGt(pair.settlementPriceFixedTs(), 0, "deficit opened the settlement window");
        assertEq(pair.scheduledTerminationTs(), vm.getBlockTimestamp(), "future cutoff pulled back to the fix time");

        // Order creation (the arrival-matching path) and the keeper matching entry points are
        // halted for the whole window.
        bytes[] memory noPu = new bytes[](0);
        vm.prank(carol);
        vm.expectRevert(BazaarPair.BazaarPair__PairScheduledForTermination.selector);
        pair.createOrder(
            _limitSpec(true, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE), _hintsNone(), noPu, 0, 0, 0, "", ""
        );

        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__PairScheduledForTermination.selector);
        pair.unloadVault(0, noPu);

        // Both deposit paths refuse new principal.
        vm.startPrank(carol);
        usdc.approve(address(pair), 20 * USDC_SCALE);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.depositCollateral(1 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.depositToInsurance(10 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();

        // Sweep settlement stays live, and finalize completes inside the original notice period.
        assertEq(pair.liquidate(_arr1(carol), noPu), 0, "flat user: settlement path callable");
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminated(), "finalized before the original cutoff arrived");
    }

    /// @notice ADL timeout: an ADL that stays pending past ADL_TIMEOUT_DURATION (24h) is treated as
    ///         price-driven insolvency — the next health check settles the pair via the equity path
    ///         instead of leaving trading frozen forever.
    function test_e2e_AdlTimeout_TerminatesPairViaEquityPath() public {
        // --- reproduce the proven deep-liquidation ADL trigger ---
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        _deposit(bob, 60_000 * BAZAAR_SCALE);
        uint256 size = 5 * BAZAAR_SCALE;
        _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), size, "5 BTC opened");
        _assertBooksSettled("adltimeout: after open");

        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, size, 254_960 * BAZAAR_SCALE);
        vm.prank(carol);
        assertEq(pair.liquidate(_arr1(dave), _freshPrice()), 1, "dave liquidated");
        assertTrue(pair.isAdlPending(), "ADL triggered");
        _assertBooks("adltimeout: after adl trigger");

        // --- let the auction rot past the 24h timeout, then trigger a health check ---
        vm.warp(vm.getBlockTimestamp() + 24 hours + 2);

        address eve = makeAddr("eve");
        usdc.mint(eve, 1_000 * USDC_SCALE);
        _deposit(eve, 10 * BAZAAR_SCALE);
        BucketStore.setIsLong(address(pair), eve, true);
        BucketStore.setSize(address(pair), eve, BAZAAR_SCALE / 10);
        BucketStore.setEntryValue(address(pair), eve, 5_005 * BAZAAR_SCALE);

        vm.prank(carol);
        assertEq(pair.liquidate(_arr1(eve), _freshPrice()), 1, "eve liquidated after the timeout");

        // The first price stored past the timeout arms the runway rather than terminating: the
        // auction is owed a fresh-priced window before anyone may pull the plug, so that a feed
        // outage spanning the deadline cannot leave both paths unblocking in the same block.
        assertEq(
            pair.adlTerminationTs(),
            vm.getBlockTimestamp() + BazaarTypes.ADL_TERMINATION_GRACE,
            "runway armed off the stored price"
        );
        assertEq(pair.settlementPriceFixedTs(), 0, "arming must not terminate in the same block");

        // Let the runway lapse; the next priced call fires the expired clock.
        vm.warp(pair.adlTerminationTs());
        pair.refreshPrice(_freshPrice());

        // Two-stage: the timed-out ADL is treated as price-driven insolvency → fix the price and
        // open the settlement window, then finalize to settle via the equity path.
        assertGt(pair.settlementPriceFixedTs(), 0, "adl timeout opened the settlement window");
        assertFalse(pair.isPairTerminated(), "not terminated until finalize");

        address[] memory both = new address[](2);
        both[0] = alice;
        both[1] = bob;
        assertEq(pair.liquidate(both, new bytes[](0)), 2, "open positions settled at the fixed price");
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminated(), "timed-out ADL settled the pair via the equity path");
        assertFalse(pair.isAdlPending(), "finalize clears the ADL latch");

        // Finalize retires the window whole. This route is where a clock is most likely to be left
        // behind, since reaching it requires the runway to have been armed and elapsed, and a
        // survivor would show a window that both has and has not ended.
        assertEq(pair.adlPendingSince(), 0, "finalize clears the termination clock");
        assertEq(pair.adlTerminationTs(), 0, "finalize clears the runway");
        assertEq(pair.adlAuctionStartTs(), 0, "finalize clears the decay clock");
    }

    /// @notice Insurer-vote consensus that outlives the 7-day execution window: the proposer's bond
    ///         is refunded (consensus was real) but the pair is NOT terminated at a weeks-stale vote.
    function test_e2e_InsurerVote_ConsensusExpiredWindow_RefundsWithoutTerminating() public {
        BazaarPairTerminator terminator = factory.pairTerminator();

        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
        _assertBooksSettled("insurervote: after insurance deposit");
        vm.warp(vm.getBlockTimestamp() + 7 days + 1 hours); // share maturity

        uint256 bond = 500 * USDC_SCALE;
        uint256 totalAtProposal = pair.totalInsuranceShares();
        usdc.mint(carol, bond);
        vm.startPrank(carol);
        usdc.approve(address(terminator), bond);
        terminator.proposeInsurerTermination(address(pair));
        vm.stopPrank();
        uint256 carolAfterPropose = usdc.balanceOf(carol);

        assertGe(9_500 * BAZAAR_SCALE, totalAtProposal * 6_000 / 10_000, "vote clears 60%");
        vm.prank(carol);
        terminator.voteForInsurerTermination(address(pair), 9_500 * BAZAAR_SCALE);

        // Past votingEnd (7d) AND the 7d execution window.
        vm.warp(vm.getBlockTimestamp() + 14 days + 1);
        terminator.executeInsurerTermination(address(pair), new bytes[](0));

        assertFalse(pair.isPairTerminated(), "stale consensus must not terminate");
        assertEq(usdc.balanceOf(carol), carolAfterPropose + bond, "bond refunded on real consensus");
        (,,,,,, bool resolved, bool executed) = terminator.insurerProposals(address(pair));
        assertTrue(resolved, "proposal resolved");
        assertFalse(executed, "but not executed");

        // The pair itself was never touched by the vote (bond flows through the terminator), so its
        // books stay exactly balanced.
        _assertBooksSettled("insurervote: end (not terminated)");
    }
}
