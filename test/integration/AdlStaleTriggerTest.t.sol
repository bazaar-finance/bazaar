// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {BucketStore} from "../BucketStore.sol";

/// @title AdlStaleTriggerTest
/// @notice Opening an ADL window requires a fresh price. Everything an auction is judged by is
///         frozen when it opens — the deleveraged side, the ranking snapshot and the 24h clock —
///         so a window opened against a stale mark would deleverage profitable counterparties in
///         response to exposure that may no longer exist.
///
///         Both tests hand the vault an identical deep-underwater inheritance on the
///         non-continuously-traded AAPL pair (the only kind that can resolve a stale price at all).
///         The single difference is whether the liquidator supplies a fresh price or rides the
///         stale fallback, which isolates the suppression to the price's freshness rather than to
///         the size of the exposure.
contract AdlStaleTriggerTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant MARK = 150; // recorded AAPL mark, whole dollars
    uint256 constant POS_SIZE = 100 * BAZAAR_SCALE;
    uint256 constant POS_COLLATERAL = 10 * BAZAAR_SCALE;
    uint256 constant ADL_TERMINATION_GRACE = BazaarTypes.ADL_TERMINATION_GRACE;

    function _aaplInsurance() internal view returns (uint256 b) {
        (,,,,, b,,,,,,,,,,,) = aaplPair.pairVault();
    }

    function _aaplPendingLiqSize() internal view returns (uint256 s) {
        (,,,,,, s,,,,,,,,,,) = aaplPair.pairVault();
    }

    function _pendingLiqIsLong() internal view returns (bool b) {
        (,,,,,,,,,, b,,,,,,) = aaplPair.pairVault();
    }

    /// @dev Warm the AAPL Pyth cache AND lastPairPrice to `priceUsd`, stamped now.
    function _warmAapl(uint256 priceUsd) internal {
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, priceUsd, uint64(vm.getBlockTimestamp()));
        vm.deal(address(this), 1 ether);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(pu)}(pu);
        aaplPair.refreshPrice(new bytes[](0));
    }

    function _depositAapl(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev A long so far underwater that the vault inherits it above the mark. entryValue is sized
    ///      off the live insurance balance so the inherited loss clears the ADL trigger with room
    ///      to spare: bankruptcy notional is (entryValue - collateral), so the gap over the mark
    ///      notional lands at ~2x the fund regardless of the fixture's seed.
    function _writeDeepUnderwaterLong(address user) internal returns (uint256 expectedLoss) {
        _depositAapl(user, POS_COLLATERAL);
        uint256 markNotional = POS_SIZE * MARK;
        uint256 entryValue = markNotional + POS_COLLATERAL + 2 * _aaplInsurance();

        BucketStore.setIsLong(address(aaplPair), user, true);
        BucketStore.setSize(address(aaplPair), user, POS_SIZE);
        BucketStore.setEntryValue(address(aaplPair), user, entryValue);
        expectedLoss = entryValue - POS_COLLATERAL - markNotional;
    }

    /// The stale fallback must not open a window, even though the inherited exposure is far past
    /// the trigger. The liquidation itself still commits — only the ADL latch is withheld.
    function test_staleMark_doesNotOpenAdlWindow() public {
        _warmAapl(MARK);
        uint256 expectedLoss = _writeDeepUnderwaterLong(dave);

        // Precondition: the exposure genuinely clears the 80%-of-insurance trigger, so a suppressed
        // latch can only be the freshness gate and not an undersized fixture.
        assertGt(expectedLoss, _aaplInsurance(), "fixture clears the whole fund, let alone the fund above its reserve");

        // Age the cache past MAX_PRICE_STALENESS so empty calldata resolves the stale fallback.
        vm.warp(vm.getBlockTimestamp() + 30);

        vm.prank(bob);
        assertEq(aaplPair.liquidate(_arr1(dave), new bytes[](0)), 1, "liquidation commits on the stale mark");

        assertGt(_aaplPendingLiqSize(), 0, "vault inherited the position");
        assertFalse(aaplPair.isAdlPending(), "stale mark must not open an ADL window");
    }

    /// Control: the identical exposure DOES open the window when the liquidator supplies a fresh
    /// price, proving the suppression above is the freshness gate rather than the fixture.
    function test_freshMark_opensAdlWindow() public {
        _warmAapl(MARK);
        uint256 expectedLoss = _writeDeepUnderwaterLong(dave);
        assertGt(expectedLoss, _aaplInsurance(), "fixture clears the whole fund, let alone the fund above its reserve");

        vm.warp(vm.getBlockTimestamp() + 30);

        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        assertEq(
            aaplPair.liquidate{value: 0.01 ether}(_arr1(dave), freshPu), 1, "liquidation commits on the fresh mark"
        );

        assertGt(_aaplPendingLiqSize(), 0, "vault inherited the position");
        assertTrue(aaplPair.isAdlPending(), "fresh mark opens the ADL window");
    }

    /// @dev A short whose loss beyond its collateral is twice the fund. Netting it against a long
    ///      the vault holds at the mark cannot fit: the fund above its reserve plus the two slices'
    ///      seizure is less than the fund, let alone twice it.
    function _writeDeepUnderwaterShort(address user) internal {
        _depositAapl(user, POS_COLLATERAL);
        uint256 markNotional = POS_SIZE * MARK;
        uint256 past = POS_COLLATERAL + 2 * _aaplInsurance();
        assertLt(past, markNotional, "fixture: the short's entry stays positive");

        BucketStore.setIsLong(address(aaplPair), user, false);
        BucketStore.setSize(address(aaplPair), user, POS_SIZE);
        BucketStore.setEntryValue(address(aaplPair), user, markNotional - past);
    }

    /// A deferral on the stale fallback keeps its list entry although no window is stored. The
    /// vault holds a long at the mark, covered by the fund, so nothing opens a window until alice's
    /// loss beyond collateral is listed opposite it; the stale mark withholds that window, and the
    /// entry has to outlive the verdict for the fresh one that opens it. The inline unload fills
    /// nothing on the stale mark, so the long she was deferred against is still there to need her.
    function test_staleMark_deferral_keepsTheEntry_freshMarkOpensItsWindow() public {
        _warmAapl(MARK);
        uint256 seized = 1_000 * BAZAAR_SCALE;
        assertGt(_aaplInsurance(), seized, "fixture: the fund holds the seizure it earmarks");
        _stageHeldInventory(aaplPair, POS_SIZE, POS_SIZE * MARK, seized);
        _writeDeepUnderwaterShort(alice);

        vm.warp(vm.getBlockTimestamp() + 30);
        vm.prank(bob);
        assertEq(aaplPair.liquidate(_arr1(alice), new bytes[](0)), 0, "alice deferred, not seized");

        assertEq(_aaplPendingLiqSize(), POS_SIZE, "the long is still held");
        assertEq(aaplPair.auxState().deferredCount, 1, "alice is listed");
        assertEq(aaplPair.deferredLiquidations(0), alice, "by name");
        assertFalse(aaplPair.isAdlPending(), "stale mark must not open the window she needs");

        vm.warp(vm.getBlockTimestamp() + 30);
        _warmAapl(MARK);

        assertTrue(aaplPair.isAdlPending(), "the fresh mark opens it");
        assertEq(aaplPair.auxState().deferredCount, 1, "with alice still listed for its auction");
        assertEq(aaplPair.deferredLiquidations(0), alice, "by name");
    }

    /// @dev Opens a window against a fresh mark, then ages past ADL_TIMEOUT_DURATION so the
    ///      termination clock is expired for the timeout tests below.
    function _openWindowThenExpireClock() internal {
        _warmAapl(MARK);
        _writeDeepUnderwaterLong(dave);
        vm.warp(vm.getBlockTimestamp() + 30);

        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        aaplPair.liquidate{value: 0.01 ether}(_arr1(dave), freshPu);
        assertTrue(aaplPair.isAdlPending(), "window open before the clock is aged");

        vm.warp(vm.getBlockTimestamp() + 25 hours);
    }

    /// @dev Call executeAdl with a fresh mark and an empty winner set. Which revert comes back
    ///      identifies the health verdict: AdlLib's submission guard means reason 1 (auction still
    ///      live, execution attempted), while reason 2 skips executeAdlCore entirely and the call
    ///      succeeds. Reverting rolls the transaction back, so this probes state without arming
    ///      anything — the runway is armed by a stored price, in _warmAapl.
    function _executeAdlFresh() internal {
        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        aaplPair.executeAdl{value: 0.01 ether}(new address[](0), new address[](0), freshPu);
    }

    /// ADL refuses the stale fallback outright. Every price-driven decision downstream — the health
    /// gate, AdlLib's batch sizing and the executor reward — would otherwise run against whichever
    /// real tick was last recorded, and on a closed venue that mark is hours old with no bound.
    function test_staleMark_executeAdlReverts() public {
        _openWindowThenExpireClock();

        vm.prank(bob);
        vm.expectRevert(BazaarPair.BazaarPair__AdlPriceStale.selector);
        aaplPair.executeAdl(new address[](0), new address[](0), new bytes[](0));

        assertEq(aaplPair.settlementPriceFixedTs(), 0, "stale mark must not fix a settlement price");
        assertEq(lens.adlTerminationTs(address(aaplPair)), 0, "stale mark must not arm the termination clock");
    }

    /// The first price stored past the timeout arms the runway instead of terminating. ADL and the
    /// timeout are both fresh-gated, so a closed market blocks them together and they would
    /// otherwise unblock in the same block at reopen — a race the auction loses, at exactly the
    /// moment its threshold has fully decayed and it is most able to resolve the exposure.
    function test_expiredClock_firstFreshMark_armsRunwayWithoutTerminating() public {
        _openWindowThenExpireClock();

        uint256 armedAt = vm.getBlockTimestamp();
        // Warmed inline rather than through _warmAapl so expectEmit sits against the pair's own
        // call and not against MockPyth's PriceFeedUpdate.
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(armedAt));
        vm.deal(address(this), 1 ether);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(pu)}(pu);

        vm.expectEmit(true, false, false, true, address(aaplPair));
        emit BazaarPair.AdlTerminationArmed(aaplPair.pairId(), armedAt + ADL_TERMINATION_GRACE);
        aaplPair.refreshPrice(new bytes[](0));

        assertEq(
            lens.adlTerminationTs(address(aaplPair)),
            armedAt + ADL_TERMINATION_GRACE,
            "runway armed off the stored price"
        );
        assertEq(aaplPair.settlementPriceFixedTs(), 0, "arming must not terminate in the same block");
        assertTrue(aaplPair.isAdlPending(), "the auction is still the live path");

        // Reason 1, not 2: inside the runway the health check still reports a live auction, so
        // execution is attempted and fails on the empty winner set rather than being skipped.
        // That is what the runway buys — the auction stays the callable path throughout it.
        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(AdlLib.AdlLib__EmptySubmission.selector);
        aaplPair.executeAdl{value: 0.01 ether}(new address[](0), new address[](0), freshPu);
    }

    /// Set-once: further stored prices inside the runway leave the deadline where it is. Refreshing
    /// it per price would make it a snooze button — the refresh bounty pays keepers to store a
    /// price every few minutes while the vault holds inventory, as it does through a window, so
    /// honest upkeep alone would defer termination forever.
    function test_runway_isNotExtendedByFurtherFreshMarks() public {
        _openWindowThenExpireClock();

        _warmAapl(MARK);
        uint256 deadline = lens.adlTerminationTs(address(aaplPair));
        assertGt(deadline, 0, "armed");

        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        _warmAapl(MARK);
        assertEq(lens.adlTerminationTs(address(aaplPair)), deadline, "a later stored price must not move the deadline");

        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        _warmAapl(MARK);
        assertEq(lens.adlTerminationTs(address(aaplPair)), deadline, "repeated refreshes must not move the deadline");
        assertEq(aaplPair.settlementPriceFixedTs(), 0, "still inside the runway");
    }

    // ---------------------------------------------------------------------------------------
    //                    auction decay restart across a market discontinuity
    // ---------------------------------------------------------------------------------------

    /// @dev Opens a window against a fresh mark and returns the instant it opened. Unlike
    ///      _openWindowThenExpireClock this leaves the 24h clock unexpired, so the auction under
    ///      test is an ordinary live one.
    function _openWindow() internal returns (uint256 openedAt) {
        _warmAapl(MARK);
        _writeDeepUnderwaterLong(dave);
        vm.warp(vm.getBlockTimestamp() + 30);

        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        aaplPair.liquidate{value: 0.01 ether}(_arr1(dave), freshPu);
        assertTrue(aaplPair.isAdlPending(), "window open");
        return vm.getBlockTimestamp();
    }

    /// A closure must not spend the auction's Dutch decay. ADL cannot run without a fresh price, so
    /// the threshold would otherwise descend across the shut venue against attempts nobody could
    /// make — and the first keeper at the reopen would meet a fully decayed gate, free to
    /// deleverage any profitable account rather than the worst-ranked ones the curve exists to
    /// reach first.
    function test_discontinuity_restartsAuctionDecay() public {
        uint256 openedAt = _openWindow();
        assertEq(aaplPair.adlAuctionStartTs(), openedAt, "decay starts with the window");

        // Past the full auction duration the gate is wide open: everything profitable qualifies.
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION + 1);
        assertEq(lens.getAdlScoreThreshold(address(aaplPair)), 1, "decayed to the floor before the gap");

        // A closure longer than the pair's own discontinuity threshold, ended by a stored price.
        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.REOPEN_GAP_MIN_STALENESS + 1);
        uint256 reopenAt = vm.getBlockTimestamp();
        _warmAapl(MARK);

        assertEq(aaplPair.adlAuctionStartTs(), reopenAt, "the reopen restarts the decay");
        assertEq(
            lens.getAdlScoreThreshold(address(aaplPair)), BazaarTypes.ADL_MAX_SCORE + 1, "threshold back at the ceiling"
        );
        assertEq(aaplPair.adlPendingSince(), openedAt, "the termination clock is untouched by the restart");
    }

    /// The restart is keyed to a genuine discontinuity, not to any refresh: a gap under the
    /// threshold is ordinary call sparsity, which the refresh bounty's cadence is calibrated to
    /// exclude. Restarting on those would let routine upkeep hold the gate at its ceiling forever.
    function test_shortGap_doesNotRestartAuctionDecay() public {
        uint256 openedAt = _openWindow();

        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.REOPEN_GAP_MIN_STALENESS - 1 minutes);
        _warmAapl(MARK);

        assertEq(aaplPair.adlAuctionStartTs(), openedAt, "a sub-threshold gap leaves the decay running");
        assertEq(lens.getAdlScoreThreshold(address(aaplPair)), 1, "still fully decayed");
    }

    /// The restarted decay must run the same curve from its new origin, not sit pinned at the
    /// ceiling — otherwise a reopen would convert the auction from selective to unexecutable.
    function test_restartedDecay_descendsAgain() public {
        _openWindow();

        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.REOPEN_GAP_MIN_STALENESS + 1);
        _warmAapl(MARK);
        uint256 atCeiling = lens.getAdlScoreThreshold(address(aaplPair));

        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION / 2);
        uint256 midway = lens.getAdlScoreThreshold(address(aaplPair));
        assertLt(midway, atCeiling, "the restarted curve descends");

        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION);
        assertEq(lens.getAdlScoreThreshold(address(aaplPair)), 1, "and reaches the floor a second time");
    }

    /// Control: once the runway elapses the same expired clock terminates on the next fresh mark, so
    /// the grace defers termination rather than withdrawing it. executeAdl now returns without
    /// reverting — reason 2 skips executeAdlCore, so the empty winner set is never inspected.
    function test_expiredClock_afterRunway_terminates() public {
        _openWindowThenExpireClock();

        _warmAapl(MARK);
        vm.warp(lens.adlTerminationTs(address(aaplPair)));

        _executeAdlFresh();

        assertGt(aaplPair.settlementPriceFixedTs(), 0, "fresh mark past the runway fires the expired timeout");

        // Fixing the price only opens the settlement window; the auction is retired at finalize, so
        // every ADL clock is still standing here.
        assertTrue(aaplPair.isAdlPending(), "the latch outlives the price fix");
        assertGt(lens.adlTerminationTs(address(aaplPair)), 0, "runway still set until finalize");
        assertGt(aaplPair.adlAuctionStartTs(), 0, "decay clock still set until finalize");
    }

    /// The withdrawal quote goes to 0 for an account the pair prices once the runway has run out:
    /// that account's withdrawal runs the verdict that fires the expired timeout, which fixes the
    /// settlement price and refuses it. An account with neither a position nor orders reads no
    /// price, is judged on the USDC balance alone, and keeps its quote.
    function test_runwayRunOut_withdrawalQuoteZeroForPricedAccountsOnly() public {
        _warmAapl(MARK);
        _depositAapl(carol, 1_000 * BAZAAR_SCALE); // flat, no orders
        _depositAapl(alice, 1_000 * BAZAAR_SCALE);
        vm.prank(alice); // a deep bid resting from before the window halts trading
        aaplPair.createOrder(
            _limitSpec(true, BAZAAR_SCALE, 100 * BAZAAR_SCALE), _hintsNone(), new bytes[](0), 0, 0, 0, "", ""
        );

        _openWindowThenExpireClock();
        _warmAapl(MARK);
        uint256 deadline = lens.adlTerminationTs(address(aaplPair));
        assertGt(deadline, 0, "runway armed");
        assertGt(lens.getMaxWithdrawable(address(aaplPair), alice, 0), 0, "inside the runway alice can withdraw");

        vm.warp(deadline);
        assertEq(lens.getMaxWithdrawable(address(aaplPair), alice, 0), 0, "past the runway: priced account quotes 0");
        assertEq(
            lens.getMaxWithdrawable(address(aaplPair), carol, 0),
            1_000 * BAZAAR_SCALE,
            "unpriced account keeps its quote"
        );

        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        aaplPair.withdrawCollateral{value: 0.01 ether}(BAZAAR_SCALE, freshPu, 0, 0, 0, "");

        vm.prank(carol);
        aaplPair.withdrawCollateral(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
    }

    /// The runway belongs to the window it was measured for. A deadline that outlived its auction
    /// would be inherited by the pair's next window as an instant already in the past, making that
    /// window terminable on its first block with no chance to deleverage at all — the failure the
    /// grace exists to prevent, reintroduced by the mechanism meant to prevent it.
    function test_resolvedWindow_clearsRunway_andNextWindowArmsAfresh() public {
        _openWindowThenExpireClock();
        _warmAapl(MARK);
        assertGt(lens.adlTerminationTs(address(aaplPair)), 0, "first window armed");

        // Drain the inherited inventory so nothing is left to finish inside the band; the next
        // health check then releases the latch, which is the transition the clear hangs off.
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(6).checked_write(uint256(0));
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(7).checked_write(uint256(0));
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(8).checked_write(uint256(0));
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(13).checked_write(uint256(0));

        vm.warp(vm.getBlockTimestamp() + 30);
        _warmAapl(MARK);

        assertFalse(aaplPair.isAdlPending(), "auction resolved");
        assertEq(lens.adlTerminationTs(address(aaplPair)), 0, "runway cleared with the window it measured");

        // Open a second window on the same pair and confirm it starts unarmed.
        _writeDeepUnderwaterLong(alice);
        vm.warp(vm.getBlockTimestamp() + 30);
        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        aaplPair.liquidate{value: 0.01 ether}(_arr1(alice), freshPu);

        assertTrue(aaplPair.isAdlPending(), "second window open");
        assertEq(lens.adlTerminationTs(address(aaplPair)), 0, "second window unarmed until its own clock expires");
        assertEq(aaplPair.settlementPriceFixedTs(), 0, "second window is not instantly terminable");
    }

    // ---------------------------------------------------------------------------------------
    //                          mid-auction side flip re-snapshot
    // ---------------------------------------------------------------------------------------

    /// @dev A small short, underwater at MARK but backed well enough that seizing it realizes no
    ///      bad debt. Liquidating it is the vehicle for reaching isVaultHealthy without reverting.
    function _writeSmallUnderwaterShort(address user) internal {
        _depositAapl(user, POS_COLLATERAL);
        // Entry below the mark: a short loses as price rises.
        uint256 size = 1 * BAZAAR_SCALE;
        uint256 entryValue = size * (MARK * 2 / 3);

        BucketStore.setIsLong(address(aaplPair), user, false);
        BucketStore.setSize(address(aaplPair), user, size);
        BucketStore.setEntryValue(address(aaplPair), user, entryValue);
    }

    /// @dev Opens a window (vault inherits dave's long, so adlLongs targets shorts), then puts the
    ///      vault on the short side so the auction's frozen target matches the side it now holds —
    ///      the condition a real netting-driven flip produces. The aggregate is written directly
    ///      rather than netted into place because netting an estate this far underwater realizes
    ///      bad debt, and a non-zero deficit makes isVaultHealthy terminate at Check 0 before the
    ///      re-target is ever evaluated. The bankruptcy notional is lowered alongside the side so
    ///      the now-short estate still shows a loss and the auction stays open.
    ///
    ///      carol is staged SHORT, matching the rewritten aggregate, so her liquidation adds to it
    ///      rather than netting against it — again keeping deficit at zero.
    function _openWindowAndStageFlip() internal {
        _warmAapl(MARK);
        _writeDeepUnderwaterLong(dave);
        vm.warp(vm.getBlockTimestamp() + 30);

        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        aaplPair.liquidate{value: 0.01 ether}(_arr1(dave), freshPu);
        assertTrue(aaplPair.isAdlPending(), "window open against a fresh mark");

        // Flip the aggregate to the short side. The entry basis has to move with it: the vault's
        // exposure is measured from there, and leaving a long's entry on a short-labelled
        // aggregate reads as a large profit rather than the exposure this fixture is staging.
        // A short's bankruptcy sits above its entry, so entry goes below the notional written here.
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(10).checked_write(false);
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(8).checked_write(100 * BAZAAR_SCALE);
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(7).checked_write(50 * BAZAAR_SCALE);
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(13).checked_write(50 * BAZAAR_SCALE); // seized

        _writeSmallUnderwaterShort(carol);
        vm.warp(vm.getBlockTimestamp() + 30);
    }

    /// The re-snapshot on a side flip must not run off a stale mark. The snapshot gates eligibility
    /// — AdlLib skips any account whose PnL at it is non-positive — so a chosen mark could make an
    /// account underwater at the live market look like a winner and be closed as one.
    function test_sideFlip_staleMark_doesNotResnapshot() public {
        _openWindowAndStageFlip();

        uint256 snapshotBefore = aaplPair.auxState().adlSnapshotPrice;
        bool longsBefore = aaplPair.auxState().adlLongs;

        // Liquidating the opposing side flips the aggregate AND lands in isVaultHealthy in the same
        // transaction — the atomic path the guard has to cover.
        vm.prank(bob);
        aaplPair.liquidate(_arr1(carol), new bytes[](0));

        assertEq(aaplPair.auxState().adlSnapshotPrice, snapshotBefore, "stale mark must not move the snapshot");
        assertEq(aaplPair.auxState().adlLongs, longsBefore, "stale mark must not re-target the auction");
    }

    /// An expired clock must not suppress the re-target. The timeout verdict and the re-point are
    /// independent: reporting expiry alone would leave the auction aimed at the side the vault
    /// itself holds, which executeAdl refuses — so the runway granted before termination would be
    /// spent reverting rather than deleveraging, on exactly the pairs that most need it.
    function test_sideFlip_expiredClock_stillRetargets() public {
        _openWindowAndStageFlip();

        vm.prank(bob);
        aaplPair.liquidate(_arr1(carol), new bytes[](0));
        assertEq(aaplPair.auxState().adlLongs, false, "re-target withheld on the stale mark");

        vm.warp(vm.getBlockTimestamp() + 25 hours);

        // A fresh mark past the timeout re-targets and arms the runway in one call, leaving the
        // auction aimed correctly and executable for the whole of it.
        _warmAapl(MARK);

        assertTrue(aaplPair.auxState().adlLongs, "expired clock still re-targets on a fresh mark");
        assertTrue(aaplPair.auxState().adlLongs != _pendingLiqIsLong(), "aimed away from the vault's own side");
        assertGt(lens.adlTerminationTs(address(aaplPair)), 0, "runway armed alongside the re-target");
        assertEq(aaplPair.settlementPriceFixedTs(), 0, "re-targeting must not terminate");

        // Reason 1, not 2: the auction is the callable path throughout the runway.
        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(AdlLib.AdlLib__EmptySubmission.selector);
        aaplPair.executeAdl{value: 0.01 ether}(new address[](0), new address[](0), freshPu);
    }

    /// A flip re-points the auction and re-freezes its ranking basis, and moves neither TERMINATION
    /// clock: the 24h timeout stays monotone and the runway armed off it is never re-armed. Without
    /// that, a pair that keeps flipping could defer termination indefinitely — the flip is
    /// caller-induced, since liquidating the opposing side both causes it and lands in the health
    /// check. The decay clock is the one that does move, which is why the two are separate values.
    function test_sideFlip_afterArming_restartsDecayNotTerminationClocks() public {
        _openWindowThenExpireClock();
        _warmAapl(MARK);

        uint256 deadlineBefore = lens.adlTerminationTs(address(aaplPair));
        uint256 pendingSinceBefore = aaplPair.adlPendingSince();
        assertGt(deadlineBefore, 0, "runway armed before the flip");
        assertFalse(aaplPair.auxState().adlLongs, "auction targets shorts against the vault's longs");

        // Flip the aggregate to the short side, entry basis moving with it so the now-short estate
        // still shows a loss and the auction stays open (a short's bankruptcy sits above its entry).
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(10).checked_write(false);
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(8).checked_write(100 * BAZAAR_SCALE);
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(7).checked_write(50 * BAZAAR_SCALE);
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(13).checked_write(50 * BAZAAR_SCALE); // seized

        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        _warmAapl(MARK);

        assertTrue(aaplPair.isAdlPending(), "auction still open across the flip");
        assertTrue(aaplPair.auxState().adlLongs, "flip re-targeted the auction");
        assertEq(lens.adlTerminationTs(address(aaplPair)), deadlineBefore, "flip must not re-arm the runway");
        assertEq(aaplPair.adlPendingSince(), pendingSinceBefore, "flip must not rewind the 24h clock");
        assertEq(aaplPair.adlAuctionStartTs(), vm.getBlockTimestamp(), "flip restarts the decay clock");
    }

    /// A stale-priced call on another entry point still withholds the re-target, leaving the
    /// auction aimed at the side the vault holds. executeAdl cannot be reached in that state — it
    /// refuses the same stale mark — so the withholding is observable only through the snapshot.
    function test_sideFlip_staleMark_leavesAuctionUnretargeted() public {
        _openWindowAndStageFlip();

        vm.prank(bob);
        aaplPair.liquidate(_arr1(carol), new bytes[](0));

        assertEq(aaplPair.auxState().adlLongs, false, "re-target withheld on the stale mark");
        assertEq(aaplPair.auxState().adlLongs, _pendingLiqIsLong(), "auction aimed at the vault's own side");

        vm.prank(bob);
        vm.expectRevert(BazaarPair.BazaarPair__AdlPriceStale.selector);
        aaplPair.executeAdl(_arr1(alice), new address[](0), new bytes[](0));
    }

    /// Control: the identical flip DOES re-target and re-snapshot on a fresh mark, so the guard
    /// blocks the stale case specifically rather than disabling side-flip handling outright.
    function test_sideFlip_freshMark_resnapshots() public {
        _openWindowAndStageFlip();

        bool longsBefore = aaplPair.auxState().adlLongs;

        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        aaplPair.liquidate{value: 0.01 ether}(_arr1(carol), freshPu);

        assertTrue(aaplPair.isAdlPending(), "auction still open");
        assertTrue(aaplPair.auxState().adlLongs != longsBefore, "fresh mark re-targets the auction");
    }

    // ---------------------------------------------------------------------------------------
    //                 a re-target re-bases what the new cohort is judged by
    // ---------------------------------------------------------------------------------------

    function _aaplCollateral(address user) internal view returns (uint256 c) {
        (,,, c,,,) = aaplPair.positionBuckets(user);
    }

    /// @dev Stage `user` as a long — the side a flip re-targets to — whose entire collateral was
    ///      deposited DURING the open window, so the deposit carries a live epoch tag. A trader in
    ///      this shape is the worst case for the tag: with it subtracted the ranking denominator
    ///      floors to 1 wei, which ranks a pure-profit claim at the very front of the queue.
    function _stageTaggedLong(address user, uint256 amount) internal {
        assertTrue(aaplPair.isAdlPending(), "tag only lands while a window is open");
        _depositAapl(user, amount);
        BucketStore.setIsLong(address(aaplPair), user, true);
        BucketStore.setSize(address(aaplPair), user, 1 * BAZAAR_SCALE);
        BucketStore.setEntryValue(address(aaplPair), user, 1 * (MARK * 2 / 3) * BAZAAR_SCALE);
        assertEq(aaplPair.adlScoreDeposit(user), amount, "deposit tagged to the live ranking epoch");
    }

    /// A flip hands the newly targeted side an auction of its own. The gate descends only as an
    /// auction fails to turn up eligible accounts, and the side that just came into range was not
    /// submittable while it descended — so inheriting the decay would expose every profitable
    /// account on that side at once, with no ranking protection at all.
    function test_sideFlip_freshMark_restartsRankingGate() public {
        _openWindowAndStageFlip();

        // Run the gate to its floor, where every positive-PnL account on the targeted side passes.
        // Short of REOPEN_GAP_MIN_STALENESS, so the price store's own discontinuity restart cannot
        // be what moves the clock below.
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION + 1);
        assertEq(lens.getAdlScoreThreshold(address(aaplPair)), 1, "gate fully decayed before the flip");

        _warmAapl(MARK); // a fresh mark re-targets inside this call's health check

        assertTrue(aaplPair.auxState().adlLongs, "flip re-targeted the auction");
        assertEq(aaplPair.adlAuctionStartTs(), vm.getBlockTimestamp(), "flip restarted the decay clock");
        assertEq(
            lens.getAdlScoreThreshold(address(aaplPair)),
            1 + BazaarTypes.ADL_MAX_SCORE,
            "gate back at max for the cohort that just came into range"
        );
    }

    /// The live tags belong to the side that was NOT in range: their deposits defended against
    /// liquidation, not against a ranking they were never subject to. Charging the re-targeted
    /// cohort for them ranks it as though it held no collateral, so a re-target voids them.
    function test_sideFlip_freshMark_releasesWindowDepositTags() public {
        _openWindowAndStageFlip();
        uint256 topUp = 20 * BAZAAR_SCALE;
        _stageTaggedLong(alice, topUp);
        assertEq(lens.adlEpoch(address(aaplPair)), 1, "window opened at epoch 1");

        _warmAapl(MARK);

        assertTrue(aaplPair.auxState().adlLongs, "alice's side is the one now being deleveraged");
        assertEq(lens.adlEpoch(address(aaplPair)), 2, "re-target advanced the ranking epoch exactly once");
        assertEq(aaplPair.adlScoreDeposit(alice), 0, "her tag no longer subtracts from her ranking");

        // What the release is worth, in the denominator ADL actually ranks on: the tag would have
        // taken her whole collateral out and floored it at 1 wei.
        uint256 coll = _aaplCollateral(alice);
        assertGt(coll, 0, "collateral present to rank against");
        assertEq(AdlLib._scoreCollateral(coll, topUp), 1, "tag live: denominator floors to 1 wei");
        assertEq(
            AdlLib._scoreCollateral(coll, aaplPair.adlScoreDeposit(alice)),
            coll,
            "tag released: denominator is her real collateral"
        );
    }

    /// A re-target withheld for staleness leaves the cohort exactly as it was, so it must spend
    /// neither protection: voiding honest tags and re-arming the gate would cost the standing
    /// cohort its queue position and its decay for a target that never moved.
    function test_sideFlip_staleMark_leavesEpochAndGateAlone() public {
        _openWindowAndStageFlip();
        uint256 topUp = 20 * BAZAAR_SCALE;
        _stageTaggedLong(alice, topUp);

        // Part-way down the decay, and short of MAX_LIQUIDATION_PRICE_AGE so the stale fallback can
        // still carry a seizure — the atomic route to a withheld re-target.
        vm.warp(vm.getBlockTimestamp() + 8 minutes);
        uint256 clockBefore = aaplPair.adlAuctionStartTs();
        uint256 gateBefore = lens.getAdlScoreThreshold(address(aaplPair));
        assertLt(gateBefore, 1 + BazaarTypes.ADL_MAX_SCORE, "gate has descended from max");
        assertGt(gateBefore, 1, "and has not yet bottomed out");

        vm.prank(bob);
        aaplPair.liquidate(_arr1(carol), new bytes[](0));

        assertFalse(aaplPair.auxState().adlLongs, "re-target withheld on the stale mark");
        assertEq(lens.adlEpoch(address(aaplPair)), 1, "withheld re-target must not advance the epoch");
        assertEq(aaplPair.adlScoreDeposit(alice), topUp, "withheld re-target must not void live tags");
        assertEq(aaplPair.adlAuctionStartTs(), clockBefore, "withheld re-target must not restart the decay");
        assertEq(lens.getAdlScoreThreshold(address(aaplPair)), gateBefore, "gate keeps the decay it earned");
    }

    /// An ordinary re-evaluation of an open window is not a re-target: the auction is still aimed
    /// away from the side the vault holds, so nothing about the cohort changed and neither the
    /// epoch nor the gate may move.
    function test_pendingNoFlip_leavesEpochAndGateAlone() public {
        _warmAapl(MARK);
        _writeDeepUnderwaterLong(dave);
        vm.warp(vm.getBlockTimestamp() + 30);

        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        aaplPair.liquidate{value: 0.01 ether}(_arr1(dave), freshPu);
        assertTrue(aaplPair.isAdlPending(), "window open");

        uint64 epochBefore = lens.adlEpoch(address(aaplPair));
        uint256 clockBefore = aaplPair.adlAuctionStartTs();

        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        _warmAapl(MARK);

        assertTrue(aaplPair.isAdlPending(), "window still open across the re-evaluation");
        assertEq(lens.adlEpoch(address(aaplPair)), epochBefore, "no re-target, no epoch advance");
        assertEq(aaplPair.adlAuctionStartTs(), clockBefore, "no re-target, no decay restart");
        assertLt(lens.getAdlScoreThreshold(address(aaplPair)), 1 + BazaarTypes.ADL_MAX_SCORE, "gate kept decaying");
    }
}
