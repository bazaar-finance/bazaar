// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";

/// @title RefreshPriceHealthTest
/// @notice refreshPrice judges vault health against the price it stores. The ADL latch that
///         executeAdl requires is set only by health checks, and every other entry point runs one
///         only after real activity, so on a book too thin to trade the permissionless refresh is
///         what opens the auction — under the same freshness rule as every other health call, and
///         never once a settlement price is fixed.
contract RefreshPriceHealthTest is IntegrationBase {
    address keeper;

    function setUp() public override {
        super.setUp();
        keeper = makeAddr("keeper");
    }

    /// @dev One unit of inherited long inventory at a $60k entry with half the fund seized
    ///      alongside it, staged directly so no fill, unload or health check runs before the
    ///      refresh. Free capital is the other half of the fund, less the reserve on one unit of
    ///      open interest; the mark the refresh stores decides how far past the seizure the
    ///      inventory sits.
    function _stageDriftingInventory() internal returns (uint256 fund) {
        fund = _insuranceBal();
        _stageHeldInventory(60_000 * BAZAAR_SCALE, fund / 2);
    }

    /// @dev Refresh the BTC pair at `priceUsd` as the keeper. Ages Pyth's cache past
    ///      MAX_PRICE_STALENESS first so the supplied update, not the cached tick, is the one
    ///      stored and judged.
    function _refreshAt(uint256 priceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + 30);
        bytes[] memory pu = _priceAt(priceUsd);
        vm.prank(keeper);
        pair.refreshPrice(pu);
    }

    /// @notice A fresh refresh past the trigger opens the ADL window that nothing else on a quiet
    ///         book would, and executeAdl stops refusing for want of a latch.
    function test_refreshPrice_freshMarkPastTrigger_opensAdlWindow() public {
        uint256 fund = _stageDriftingInventory();
        // At a $50k mark the loss beyond the seizure is $10k - fund/2, past the whole free half.
        assertGt(10_000 * BAZAAR_SCALE - fund / 2, fund / 2, "fixture clears the ADL trigger");
        assertFalse(pair.isAdlPending(), "no health check has run since the drift");

        _refreshAt(50_000);

        assertTrue(pair.isAdlPending(), "the refresh opened the window");
        assertEq(pair.adlPendingSince(), vm.getBlockTimestamp(), "the timeout clock started at the refresh");
        assertFalse(pair.auxState().adlLongs, "the winners are the side opposite the vault's longs");

        // The auction is startable now: the only refusal left is the empty submission, not the latch.
        bytes[] memory pu = _freshPrice();
        vm.expectRevert(AdlLib.AdlLib__EmptySubmission.selector);
        pair.executeAdl(new address[](0), new address[](0), pu);
    }

    /// @notice Under the trigger the refresh leaves no latch behind, so the block above is the
    ///         live verdict and not the mere presence of inventory.
    function test_refreshPrice_underTrigger_leavesNoLatch() public {
        uint256 fund = _stageDriftingInventory();
        // At a $57k mark the loss beyond the seizure is $3k - fund/2, under the free half even
        // after the reserve on one unit of open interest (well under $300) comes off it.
        assertLt(3_000 * BAZAAR_SCALE - fund / 2, fund / 2 - 300 * BAZAAR_SCALE, "fixture stays under the ADL trigger");

        _refreshAt(57_000);

        assertFalse(pair.isAdlPending(), "healthy verdict");
        assertEq(pair.adlPendingSince(), 0, "no latch");
    }

    /// @notice A stale refresh reports the verdict but must not open the window: everything the
    ///         auction is judged by is frozen at the instant it opens, and a stale mark is
    ///         whichever tick someone last recorded. The same fixture opens on the first fresh
    ///         print, so the suppression is the freshness gate and not the fixture.
    function test_refreshPrice_staleMark_doesNotOpenWindow_freshMarkDoes() public {
        // Warm the AAPL mark so the stale fallback has a price to resolve.
        bytes[] memory warm = _priceUpdateFor(AAPL_USD_FEED_ID, 150, uint64(vm.getBlockTimestamp()));
        vm.deal(address(this), 1 ether);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(warm)}(warm);
        aaplPair.refreshPrice(new bytes[](0));

        (,,,,, uint256 fund,,,,,,,,,,,) = aaplPair.pairVault();
        // One unit long at an $8k entry with half the fund seized: at the $150 mark the loss
        // beyond the seizure is $7,850 - fund/2, past the whole free half.
        _stageHeldInventory(aaplPair, 8_000 * BAZAAR_SCALE, fund / 2);
        assertGt(7_850 * BAZAAR_SCALE - fund / 2, fund / 2, "fixture clears the ADL trigger");

        // Age the cache past MAX_PRICE_STALENESS so empty calldata resolves the stale fallback.
        vm.warp(vm.getBlockTimestamp() + 30);
        aaplPair.refreshPrice(new bytes[](0));
        assertFalse(aaplPair.isAdlPending(), "a stale mark never opens a window");
        assertEq(aaplPair.adlPendingSince(), 0, "no latch");

        bytes[] memory fresh = _priceUpdateFor(AAPL_USD_FEED_ID, 150, uint64(vm.getBlockTimestamp()));
        aaplPair.refreshPrice(fresh);
        assertTrue(aaplPair.isAdlPending(), "a fresh mark opens it");
        assertEq(aaplPair.adlPendingSince(), vm.getBlockTimestamp(), "the timeout clock started");
    }

    /// @notice Once a settlement price is fixed the auction state must not move, so the refresh
    ///         keeps storing prices but no longer judges health — even against inventory that
    ///         would otherwise trip the trigger.
    function test_refreshPrice_afterSettlementFixed_doesNotTouchAdlState() public {
        _stageDriftingInventory();
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);

        _refreshAt(50_000);

        assertFalse(pair.isAdlPending(), "no window once settlement has begun");
        assertEq(pair.adlPendingSince(), 0, "no latch");
    }

    /// @notice The refresh that discovers a books-vs-balance shortfall fixes the settlement price
    ///         and is still paid for the fresh mark it stored; the next refresh is not.
    function test_refreshPrice_discoveringShortfall_fixesSettlement_bountyPaidOnce() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE / 2); // a live book for the shortfall to strand
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE); // fund past the bounty floor
        // The vault holds no inventory, so the bounty's gap is its one-day heartbeat.
        vm.warp(vm.getBlockTimestamp() + 1 days + 1 minutes);
        vm.prank(address(pair));
        usdc.transfer(makeAddr("driftSink"), 1_000 * USDC_SCALE); // books now exceed cash

        _refreshAt(50_000);

        assertEq(_escrowOwed(keeper), 0.1e18, "the refresh that opened the window is paid");
        assertEq(pair.settlementPriceFixedTs(), vm.getBlockTimestamp(), "the shortfall fixed the settlement price");
        assertEq(pair.auxState().settlementPrice, 50_000 * BAZAAR_SCALE, "at the refreshed mark");
        assertFalse(pair.isPairTerminated(), "window open, not finalized");

        vm.warp(vm.getBlockTimestamp() + 1 days + 1 minutes);
        _refreshAt(50_000);
        assertEq(_escrowOwed(keeper), 0.1e18, "no bounty once the settlement price is fixed");
    }
}
