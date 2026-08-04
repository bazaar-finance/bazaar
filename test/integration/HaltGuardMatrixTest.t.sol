// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

/// @notice Triggers the halt-state guards and custom errors on liquidate / executeAdl / matchBatch /
///         fixSettlementPrice / setScheduledTermination. Each guard either protects funds
///         (halted-pair mutation) or is a keeper-facing precondition, and none of them is reachable
///         from the happy paths — without this matrix, dropping any one leaves the suite green.
contract HaltGuardMatrixTest is IntegrationBase {
    using stdStorage for StdStorage;

    bytes[] internal emptyPu;

    function _emptyLists() internal pure returns (BazaarTypes.OrderLists memory) {
        return _lists(_empty(), _empty(), _empty(), _empty());
    }

    /// @dev Set a packed bool flag without disturbing its slot-mates. stdStorage cannot write
    ///      packed bools; slot/offset come from `forge inspect BazaarPair storage-layout`. The
    ///      callers assert the public getter afterward, so a future layout change fails loudly
    ///      rather than silently testing nothing.
    function _setPackedBool(uint256 slot, uint256 byteOffset) internal {
        bytes32 cur = vm.load(address(pair), bytes32(slot));
        vm.store(address(pair), bytes32(slot), bytes32(uint256(cur) | (uint256(1) << (byteOffset * 8))));
    }

    // ==================== executeAdl ====================

    /// @notice executeAdl on a pair with no pending liquidation reverts AdlNotPending.
    function test_executeAdl_notPending_reverts() public {
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__AdlNotPending.selector);
        pair.executeAdl(_arr1(alice), emptyPu);
    }

    /// @notice Once the settlement price is fixed (sweep mode), executeAdl is halted — an ADL at a
    ///         live oracle price would corrupt the frozen book. The halt check precedes AdlNotPending.
    function test_executeAdl_sweepMode_halted() public {
        _stdstore.target(address(pair)).sig("settlementPriceFixedTs()").checked_write(uint256(1));
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__TradingHalted.selector);
        pair.executeAdl(_arr1(alice), emptyPu);
    }

    /// @notice A normally-terminated pair halts executeAdl.
    function test_executeAdl_terminated_halted() public {
        _setPackedBool(29, 2); // isPairTerminatedNormal (slot 29, offset 2)
        assertTrue(pair.isPairTerminatedNormal(), "flag set");
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__TradingHalted.selector);
        pair.executeAdl(_arr1(alice), emptyPu);
    }

    // ==================== liquidate ====================

    /// @notice Empty liquidation list reverts before any price read.
    function test_liquidate_emptyList_reverts() public {
        address[] memory none = new address[](0);
        vm.prank(bob);
        vm.expectRevert(BazaarPair.BazaarPair__EmptyLiquidationList.selector);
        pair.liquidate(none, emptyPu);
    }

    /// @notice A terminated pair settles via withdrawals only — liquidate is halted.
    function test_liquidate_terminated_halted() public {
        _setPackedBool(29, 1); // isPairTerminatedEmergency (slot 29, offset 1)
        assertTrue(pair.isPairTerminatedEmergency(), "flag set");
        vm.prank(bob);
        vm.expectRevert(BazaarPair.BazaarPair__TradingHalted.selector);
        pair.liquidate(_arr1(alice), emptyPu);
    }

    /// @notice Scheduled-termination limbo (cutoff passed, settlement price not yet fixed) halts
    ///         liquidate: no price is authoritative in the window, so seizing positions is unsafe.
    function test_liquidate_scheduledLimbo_halted() public {
        // scheduledTerminationTs in the past, settlementPriceFixedTs still 0 -> limbo.
        _stdstore.target(address(pair)).sig("scheduledTerminationTs()").checked_write(block.timestamp - 1);
        vm.prank(bob);
        vm.expectRevert(BazaarPair.BazaarPair__TradingHalted.selector);
        pair.liquidate(_arr1(alice), emptyPu);
    }

    // ==================== matchBatch observation-block guards ====================

    /// @notice observationBlock == currentBlock is rejected (must be strictly in the past).
    function test_matchBatch_observationInFuture_boundary() public {
        uint64 cb = uint64(vm.getBlockNumber()); // MockArbSys mirrors block.number
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__ObservationBlockInFuture.selector);
        pair.matchBatch(_emptyLists(), 1, emptyPu, cb);
    }

    /// @notice observationBlock older than MAX_OBSERVATION_BLOCK_AGE (12) is rejected.
    function test_matchBatch_observationTooOld() public {
        _roll(20); // ensure headroom below currentBlock
        uint64 cb = uint64(vm.getBlockNumber());
        uint64 obs = cb - 13; // age 13 > 12
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__ObservationBlockTooOld.selector);
        pair.matchBatch(_emptyLists(), 1, emptyPu, obs);
    }

    /// @notice maxMatches == 0 reverts (guard sits after the halt checks, before list parsing).
    function test_matchBatch_zeroMaxMatches_reverts() public {
        uint64 obs = uint64(vm.getBlockNumber()) - 1;
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__InvalidMaxMatches.selector);
        pair.matchBatch(_emptyLists(), 0, emptyPu, obs);
    }

    /// @notice Empty order lists revert NoMatchesProvided.
    function test_matchBatch_noMatches_reverts() public {
        uint64 obs = uint64(vm.getBlockNumber()) - 1;
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__NoMatchesProvided.selector);
        pair.matchBatch(_emptyLists(), 1, emptyPu, obs);
    }

    // ==================== onlyUma settlement guards ====================

    /// @notice fixSettlementPrice(0) is rejected: a stored zero would brick finalize forever with
    ///         withdrawals frozen, so the zero-check must fail at this stage where the terminator can retry.
    function test_fixSettlementPrice_zero_reverts() public {
        address uma = pair.umaContract();
        vm.prank(uma);
        vm.expectRevert(BazaarPair.BazaarPair__NoPriceUpdatesProvided.selector);
        pair.fixSettlementPrice(0);
    }

    /// @notice setScheduledTermination is single-shot: a second acceptance reverts.
    function test_setScheduledTermination_double_reverts() public {
        // Simulate a prior acceptance without invoking the reward path.
        _stdstore.target(address(pair)).sig("scheduledTerminationTs()").checked_write(block.timestamp + 1 days);
        address uma = pair.umaContract();
        vm.prank(uma);
        vm.expectRevert(BazaarPair.BazaarPair__TerminationAlreadyScheduled.selector);
        pair.setScheduledTermination(block.timestamp + 2 days, makeAddr("proposer"));
    }

    /// @notice Non-UMA callers cannot fix the settlement price.
    function test_fixSettlementPrice_onlyUma() public {
        vm.prank(bob);
        vm.expectRevert(BazaarPair.BazaarPair__OnlyUma.selector);
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
    }
}
