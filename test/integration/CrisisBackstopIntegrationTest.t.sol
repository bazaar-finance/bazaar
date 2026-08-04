// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";

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
        (,,,,,,,,,,, uint256 deficit) = pair.pairVault();
        assertEq(deficit, 100 * BAZAAR_SCALE, "deficit seeded");

        // Any liquidation re-runs isVaultHealthy; Check 0 fires before everything else.
        _setupInsolventAlice();
        // A seeded deficit and the phantom underwater position don't move real cash, so the books
        // are still balanced right up to the terminating call.
        _assertBooksSettled("deficit: before terminating liquidation");

        vm.prank(bob);
        pair.liquidate(_arr1(alice), _freshPrice());

        // Two-stage insolvency: the deficit check FIXES the settlement price and opens the 48h
        // window (freezing withdrawals immediately — the point of Check 0) rather than
        // terminating mid-transaction. Finalize completes it, charging the deficit to insurance.
        assertGt(pair.settlementPriceFixedTs(), 0, "deficit opened the settlement window");
        assertFalse(pair.isPairTerminatedNormal(), "not terminated until finalize");

        // The pair is halted: no further deposits — INCLUDING at the stamping timestamp itself.
        // scheduledTerminationTs is stamped at `now` and the limbo guards compare with >=, so
        // there is no same-second window in which the settlement price is already known but
        // deposits/orders/matching still pass. A strict > would open exactly that window, and it
        // is reachable atomically (both terminator entry points are permissionless) rather than
        // only via Arbitrum's shared block timestamps — so the same-second leg below is the one
        // that matters.
        vm.startPrank(carol);
        usdc.approve(address(pair), 2 * USDC_SCALE);
        vm.expectRevert(CollateralLib.CollateralLib__PairScheduledForTermination.selector);
        pair.depositCollateral(1 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(CollateralLib.CollateralLib__PairScheduledForTermination.selector);
        pair.depositCollateral(1 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.stopPrank();

        // After the window, anyone finalizes → normal (equity) termination.
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminatedNormal(), "deficit settled the pair via the equity path");
        assertFalse(pair.isPairTerminatedEmergency(), "live price -> normal, not emergency");
    }

    /// @notice ADL timeout: an ADL that stays pending past ADL_TIMEOUT_DURATION (24h) is treated as
    ///         price-driven insolvency — the next health check settles the pair via the equity path
    ///         instead of leaving trading frozen forever.
    function test_e2e_AdlTimeout_TerminatesPairViaEquityPath() public {
        // --- reproduce the proven ADL trigger (same scenario as AdlIntegrationTest) ---
        vm.startPrank(seq);
        usdc.approve(address(sequencer), 20_000 * USDC_SCALE);
        sequencer.deposit(20_000 * USDC_SCALE);
        vm.stopPrank();

        _deposit(alice, 60_000 * BAZAAR_SCALE);
        _deposit(bob, 60_000 * BAZAAR_SCALE);
        uint256 size = 5 * BAZAAR_SCALE;
        uint256 aL = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        uint256 bS = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(aL), _one(bS), _empty(), _empty()), 10), 1, "5 BTC opened");
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
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(eve).depth(0).checked_write(true);
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(eve).depth(1)
            .checked_write(BAZAAR_SCALE / 10);
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(eve).depth(2)
            .checked_write(5_005 * BAZAAR_SCALE);

        vm.prank(carol);
        assertEq(pair.liquidate(_arr1(eve), _freshPrice()), 1, "eve liquidated after the timeout");

        // Two-stage: the timed-out ADL is treated as price-driven insolvency → fix the price and
        // open the settlement window, then finalize to settle via the equity path.
        assertGt(pair.settlementPriceFixedTs(), 0, "adl timeout opened the settlement window");
        assertFalse(pair.isPairTerminatedNormal(), "not terminated until finalize");

        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminatedNormal(), "timed-out ADL settled the pair via the equity path");
        assertFalse(pair.isPairTerminatedEmergency(), "live price -> normal termination, not emergency");
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

        assertFalse(pair.isPairTerminatedNormal(), "stale consensus must not terminate");
        assertEq(usdc.balanceOf(carol), carolAfterPropose + bond, "bond refunded on real consensus");
        (,,,,,, bool resolved, bool executed) = terminator.insurerProposals(address(pair));
        assertTrue(resolved, "proposal resolved");
        assertFalse(executed, "but not executed");

        // The pair itself was never touched by the vote (bond flows through the terminator), so its
        // books stay exactly balanced.
        _assertBooksSettled("insurervote: end (not terminated)");
    }
}
