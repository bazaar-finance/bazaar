// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";

/// @title SettlementFundingFreezeTest
/// @notice Once the settlement price is fixed the pair stores no further price, so the funding
///         index every terminal settlement reads stays where the fix left it. A tick published
///         at or before the cutoff is still fresh for MAX_PRICE_STALENESS after it; if a store
///         of that tick could land between two settlements, positions settled before it would
///         pay funding only to the old index while those settled after it collected to the new
///         one, and the insurers' residual would fund the difference. A hedged trader who
///         settles its paying leg, stores the tick and then settles its receiving leg would
///         pocket that difference.
contract SettlementFundingFreezeTest is IntegrationBase {
    uint256 constant SIZE = BAZAAR_SCALE; // 1 BTC
    uint256 constant FILL_TOL = 1e12; // $0.000001: per-leg rounding of the realized PnL

    BazaarPairTerminator internal terminator;

    function setUp() public override {
        super.setUp();
        terminator = factory.pairTerminator();
    }

    function _refreshAt(uint256 priceUsd, uint64 publishTime) internal {
        bytes[] memory pu = _priceUpdate(priceUsd, publishTime);
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(address(this), fee);
        pair.refreshPrice{value: fee}(pu);
    }

    function _storedPriceTs() internal view returns (uint256 updateTs) {
        (,, updateTs,,) = pair.lastPairPrice();
    }

    function _settleSelf(address u) internal {
        vm.prank(u);
        assertEq(pair.liquidate(_arr1(u), new bytes[](0)), 1, "position settled");
    }

    /// @dev Schedules a UMA termination a day out, opens alice long / bob short 1 BTC at $51k
    ///      40 minutes before the cutoff (alice's bid stood above the oracle, so the fill forms a
    ///      premium and longs pay), stores a $48k index 10 minutes later, and warps to one second
    ///      past the cutoff. The funding accrued since that store is pending: only a stored price
    ///      moves it into the index. Returns the cutoff, read back from the pair.
    function _scheduleAndOpenBeforeCutoff() internal returns (uint256 cutoff) {
        uint256 bond = terminator.TERMINATION_PROPOSAL_BOND();
        usdc.mint(carol, bond);
        vm.prank(carol);
        usdc.approve(address(terminator), bond);
        uint256 lastTradingTs = vm.getBlockTimestamp() + 1 days;
        vm.prank(carol);
        bytes32 aid = terminator.proposeTermination(address(pair), 2, lastTradingTs, "Delisting announced.");
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(aid);
        cutoff = pair.scheduledTerminationTs();
        assertEq(cutoff, lastTradingTs, "setup: cutoff scheduled");

        vm.warp(cutoff - 40 minutes);
        _openPosition(alice, bob, true, SIZE);
        vm.warp(cutoff - 30 minutes);
        _refreshAt(48_000, uint64(cutoff - 30 minutes));
        assertEq(_storedPriceTs(), cutoff - 30 minutes, "setup: last store 30 min before the cutoff");

        vm.warp(cutoff + 1);
    }

    function _fixAtCutoffTick(uint256 cutoff) internal {
        // The window's first print: the feed's previous print came before the window opened.
        bytes[] memory tick = _priceUpdateFor(BTC_USD_FEED_ID, 48_000, uint64(cutoff), uint64(cutoff) - 4);
        uint256 fee = oracle.getUpdateFee(tick);
        vm.deal(address(this), fee);
        terminator.terminateScheduledPair{value: fee}(address(pair), tick);
        assertGt(pair.settlementPriceFixedTs(), 0, "setup: settlement price fixed");
    }

    /// @notice The hedged sequence inside the first seconds after the cutoff: fix, settle the
    ///         paying long, refresh with the cutoff tick, settle the receiving short. The refresh
    ///         stores nothing and leaves the funding index alone, so both legs settle at one
    ///         index and the short's registered profit equals the long's realized loss.
    function test_refreshAfterFix_storesNothing_bothLegsSettleAtOneIndex() public {
        uint256 cutoff = _scheduleAndOpenBeforeCutoff();
        _fixAtCutoffTick(cutoff);

        int256 indexAtFix = pair.currentFundingIndex();
        uint256 aliceCollateral = _posCollateral(alice);
        _settleSelf(alice);

        // The cutoff tick is newer than the last store, not past the cutoff, and fresh at
        // cutoff + 1: everything but the fixed price would admit it.
        _refreshAt(48_000, uint64(cutoff));
        assertEq(_storedPriceTs(), cutoff - 30 minutes, "no price stored after the fix");
        assertEq(pair.currentFundingIndex(), indexAtFix, "funding index frozen at the fix");

        _settleSelf(bob);
        uint256 aliceLoss = aliceCollateral - _posCollateral(alice);
        assertGe(aliceLoss, 3_000 * BAZAAR_SCALE, "long lost at least the price move");
        assertApproxEqAbs(
            pair.terminalProfitClaim(bob), aliceLoss, FILL_TOL, "short's claim is exactly the long's loss"
        );
    }

    /// @notice A store between the cutoff and the fix is still taken: it carries a tick from at
    ///         or before the cutoff, and every position then settles after it at the same index.
    ///         It also shows the pending funding the frozen index leaves out is real.
    function test_refreshBeforeFix_stillAccruesToTheCutoff() public {
        uint256 cutoff = _scheduleAndOpenBeforeCutoff();

        int256 indexBefore = pair.currentFundingIndex();
        _refreshAt(48_000, uint64(cutoff));
        assertEq(_storedPriceTs(), cutoff, "cutoff tick stored before the fix");
        assertGt(
            pair.currentFundingIndex(),
            indexBefore + int256(BAZAAR_SCALE / 100),
            "longs paid more than $0.01 per BTC for the last 30 minutes"
        );

        _fixAtCutoffTick(cutoff);
        uint256 aliceCollateral = _posCollateral(alice);
        _settleSelf(alice);
        _settleSelf(bob);
        assertApproxEqAbs(
            pair.terminalProfitClaim(bob),
            aliceCollateral - _posCollateral(alice),
            FILL_TOL,
            "short's claim is exactly the long's loss"
        );
    }

    /// @notice A fix with no schedule (the insolvency, ADL-timeout and stale-oracle paths) stamps
    ///         the cutoff at the fix instant. A tick published in that same second is fresh and
    ///         not past the cutoff, and is still refused.
    function test_unscheduledFix_refreshInTheFixSecond_storesNothing() public {
        _openPosition(alice, bob, true, SIZE);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        _refreshAt(48_000, uint64(vm.getBlockTimestamp()));
        uint256 lastStore = _storedPriceTs();
        vm.warp(vm.getBlockTimestamp() + 20 minutes);

        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(48_000 * BAZAAR_SCALE);
        uint256 fixTs = pair.settlementPriceFixedTs();
        assertEq(pair.scheduledTerminationTs(), fixTs, "setup: cutoff stamped at the fix");
        int256 indexAtFix = pair.currentFundingIndex();

        _refreshAt(48_000, uint64(fixTs));
        assertEq(_storedPriceTs(), lastStore, "no price stored after the fix");
        assertEq(pair.currentFundingIndex(), indexAtFix, "funding index frozen at the fix");
    }
}
