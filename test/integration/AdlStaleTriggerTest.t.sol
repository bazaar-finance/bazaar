// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";

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

    function _aaplInsurance() internal view returns (uint256 b) {
        (,,,,, b,,,,,,) = aaplPair.pairVault();
    }

    function _aaplPendingLiqSize() internal view returns (uint256 s) {
        (,,,,,, s,,,,,) = aaplPair.pairVault();
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
    ///      off the live insurance balance so the inherited loss clears the 80% ADL trigger with
    ///      room to spare: bankruptcy notional is (entryValue - collateral), so the gap over the
    ///      mark notional lands at ~2x the fund regardless of the fixture's seed.
    function _writeDeepUnderwaterLong(address user) internal returns (uint256 expectedLoss) {
        _depositAapl(user, POS_COLLATERAL);
        uint256 markNotional = POS_SIZE * MARK;
        uint256 entryValue = markNotional + POS_COLLATERAL + 2 * _aaplInsurance();

        _stdstore.target(address(aaplPair)).sig("positionBuckets(address)").with_key(user).depth(0).checked_write(true);
        _stdstore.target(address(aaplPair)).sig("positionBuckets(address)").with_key(user).depth(1).checked_write(
            POS_SIZE
        );
        _stdstore.target(address(aaplPair)).sig("positionBuckets(address)").with_key(user).depth(2).checked_write(
            entryValue
        );
        expectedLoss = entryValue - POS_COLLATERAL - markNotional;
    }

    /// The stale fallback must not open a window, even though the inherited exposure is far past
    /// the trigger. The liquidation itself still commits — only the ADL latch is withheld.
    function test_staleMark_doesNotOpenAdlWindow() public {
        _warmAapl(MARK);
        uint256 expectedLoss = _writeDeepUnderwaterLong(dave);

        // Precondition: the exposure genuinely clears the 80%-of-insurance trigger, so a suppressed
        // latch can only be the freshness gate and not an undersized fixture.
        assertGt(expectedLoss, _aaplInsurance() * 80 / 100, "fixture must clear the ADL trigger");

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
        assertGt(expectedLoss, _aaplInsurance() * 80 / 100, "fixture must clear the ADL trigger");

        vm.warp(vm.getBlockTimestamp() + 30);

        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        assertEq(aaplPair.liquidate{value: 0.01 ether}(_arr1(dave), freshPu), 1, "liquidation commits on the fresh mark");

        assertGt(_aaplPendingLiqSize(), 0, "vault inherited the position");
        assertTrue(aaplPair.isAdlPending(), "fresh mark opens the ADL window");
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

    /// An expired auction clock must not terminate the book on a stale mark: settlement would fix
    /// the whole pair to whichever real tick was last recorded. The empty winner set is what the
    /// call fails on, and that revert IS the assertion — reaching AdlLib's submission guard proves
    /// the health check returned reason 1 (auction still live) rather than reason 2 (terminated),
    /// since reason 2 skips executeAdlCore entirely and the call would then succeed.
    function test_expiredClock_staleMark_doesNotTerminate() public {
        _openWindowThenExpireClock();

        vm.prank(bob);
        vm.expectRevert(AdlLib.AdlLib__EmptySubmission.selector);
        aaplPair.executeAdl(new address[](0), new bytes[](0));

        assertEq(aaplPair.settlementPriceFixedTs(), 0, "stale mark must not fix a settlement price");
    }

    /// Control: the same expired clock DOES terminate once a fresh mark is supplied, so deferring
    /// costs nothing — the first caller carrying a fresh price settles the book.
    function test_expiredClock_freshMark_terminates() public {
        _openWindowThenExpireClock();

        bytes[] memory freshPu = _priceUpdateFor(AAPL_USD_FEED_ID, MARK, uint64(vm.getBlockTimestamp()));
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        aaplPair.executeAdl{value: 0.01 ether}(new address[](0), freshPu);

        assertGt(aaplPair.settlementPriceFixedTs(), 0, "fresh mark fires the expired timeout");
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

        _stdstore.target(address(aaplPair)).sig("positionBuckets(address)").with_key(user).depth(0).checked_write(false);
        _stdstore.target(address(aaplPair)).sig("positionBuckets(address)").with_key(user).depth(1).checked_write(size);
        _stdstore.target(address(aaplPair)).sig("positionBuckets(address)").with_key(user).depth(2).checked_write(
            entryValue
        );
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

        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(10).checked_write(false);
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(8).checked_write(100 * BAZAAR_SCALE);

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

    /// Withholding the re-target leaves the auction aimed at the side the vault itself holds, and
    /// that side is NOT reliably free of profitable positions — eligibility is per-account PnL
    /// against its own entry, and the winner list is caller-supplied, so a submitter could hand in
    /// exactly the profitable ones. Closing them would deleverage accounts that do not offset the
    /// vault's exposure while still decrementing pendingLiq. executeAdl must refuse outright.
    function test_sideFlip_staleMark_blocksExecutionUntilRetargeted() public {
        _openWindowAndStageFlip();

        vm.prank(bob);
        aaplPair.liquidate(_arr1(carol), new bytes[](0));
        assertEq(aaplPair.auxState().adlLongs, false, "re-target withheld on the stale mark");

        // alice holds a SHORT — the same side the vault now holds, and the side the un-retargeted
        // auction still points at. Profitable at the frozen snapshot, so eligibility would accept
        // it if execution were allowed to proceed.
        _depositAapl(alice, POS_COLLATERAL);
        _stdstore.target(address(aaplPair)).sig("positionBuckets(address)").with_key(alice).depth(0).checked_write(false);
        _stdstore.target(address(aaplPair)).sig("positionBuckets(address)").with_key(alice).depth(1).checked_write(
            1 * BAZAAR_SCALE
        );
        _stdstore.target(address(aaplPair)).sig("positionBuckets(address)").with_key(alice).depth(2).checked_write(
            300 * BAZAAR_SCALE
        );

        vm.prank(bob);
        vm.expectRevert(BazaarPair.BazaarPair__AdlRetargetPending.selector);
        aaplPair.executeAdl(_arr1(alice), new bytes[](0));
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
}
