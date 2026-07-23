// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {BazaarSequencer} from "../../src/BazaarSequencer.sol";
import {MatchingEngineLib} from "../../src/libraries/MatchingEngineLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title SequencerNegativeTest
/// @notice The sequencer-abuse defenses that had no negative tests: omission-challenge reject
///         reasons (hash forgery, dead orders), challenge-window expiry, matchBatch state guards,
///         volume-capacity exhaustion, and the replay/type-smuggling head-loader reverts.
contract SequencerNegativeTest is IntegrationBase {
    using stdStorage for StdStorage;

    function _captureBatch() internal returns (uint256 batchId, BazaarTypes.BatchInfo memory info) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == BazaarTypes.BatchRecorded.selector) {
                batchId = uint256(logs[i].topics[2]);
                info = abi.decode(logs[i].data, (BazaarTypes.BatchInfo));
                return (batchId, info);
            }
        }
        revert("no BatchRecorded event emitted");
    }

    /// @dev Standard omission scenario: alice's aggressive long is left out of a carol/dave match.
    function _omissionScenario()
        internal
        returns (uint256 omittedId, uint256 batchId, BazaarTypes.BatchInfo memory info)
    {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        omittedId = _placeLimit(alice, true, BAZAAR_SCALE / 10, 52_000 * BAZAAR_SCALE);
        uint256 cL = _placeLimit(carol, true, 1 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE);
        uint256 dS = _placeLimit(dave, false, 1 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE);
        _roll(2);
        vm.recordLogs();
        assertEq(_match(_lists(_one(cL), _one(dS), _empty(), _empty()), 10), 1, "batch matched");
        (batchId, info) = _captureBatch();
    }

    // ---------------- omission reject reasons (no slash, no revert) ----------------

    /// @notice Reason 1 — a challenger cannot slash with a FORGED BatchInfo: any mutated field
    ///         breaks the preimage hash and the challenge is rejected without touching the bond.
    function test_omissionReject_forgedBatchInfo() public {
        (uint256 omittedId, uint256 batchId, BazaarTypes.BatchInfo memory info) = _omissionScenario();
        info.totalMatchNotional += 1; // forge one field

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        address challenger = makeAddr("forger");
        vm.prank(challenger);
        sequencer.challengeOmission(address(pair), batchId, info, omittedId);

        assertEq(sequencer.sequencerBonds(seq), bondBefore, "forged preimage slashes nothing");
        assertEq(usdc.balanceOf(challenger), 0, "no bounty for a forgery");
    }

    /// @notice Reason 2 — challenging a nonexistent order is rejected, not slashed.
    function test_omissionReject_nonexistentOrder() public {
        (, uint256 batchId, BazaarTypes.BatchInfo memory info) = _omissionScenario();
        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.prank(makeAddr("challenger2"));
        sequencer.challengeOmission(address(pair), batchId, info, 999_999);
        assertEq(sequencer.sequencerBonds(seq), bondBefore, "nonexistent order slashes nothing");
    }

    /// @notice Reason 4 — an order the user CANCELED before the batch was correctly skipped by the
    ///         sequencer; challenging it is rejected.
    function test_omissionReject_canceledOrder() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        uint256 canceledId = _placeLimit(alice, true, BAZAAR_SCALE / 10, 52_000 * BAZAAR_SCALE);
        uint256[] memory ids = new uint256[](1);
        ids[0] = canceledId;
        vm.prank(alice);
        pair.cancelOrders(ids, 0, 0, 0, "");

        uint256 cL = _placeLimit(carol, true, 1 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE);
        uint256 dS = _placeLimit(dave, false, 1 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE);
        _roll(2);
        vm.recordLogs();
        assertEq(_match(_lists(_one(cL), _one(dS), _empty(), _empty()), 10), 1, "batch matched");
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _captureBatch();

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.prank(makeAddr("challenger3"));
        sequencer.challengeOmission(address(pair), batchId, info, canceledId);
        assertEq(sequencer.sequencerBonds(seq), bondBefore, "dead order slashes nothing");
    }

    // ---------------- challenge windows ----------------

    /// @notice Both challenge types revert once 30 minutes have passed since the batch timestamp.
    function test_challengeWindows_expireAfter30Minutes() public {
        (uint256 omittedId, uint256 batchId, BazaarTypes.BatchInfo memory info) = _omissionScenario();
        vm.warp(vm.getBlockTimestamp() + 30 minutes + 1);

        vm.prank(makeAddr("late1"));
        vm.expectRevert(BazaarSequencer.Sequencer__ChallengeWindowExpired.selector);
        sequencer.challengeOmission(address(pair), batchId, info, omittedId);

        vm.deal(makeAddr("late2"), 1 ether);
        vm.prank(makeAddr("late2"));
        vm.expectRevert(BazaarSequencer.Sequencer__ChallengeWindowExpired.selector);
        sequencer.challengeStaleBatch(address(pair), batchId, info, new bytes[](0));
    }

    // ---------------- matchBatch state guards ----------------

    function test_matchBatch_revertsWhenTerminated() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 aL = _placeLimit(alice, true, BAZAAR_SCALE / 10, 50_000 * BAZAAR_SCALE);
        uint256 bS = _placeLimit(bob, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        address uma = pair.umaContract();
        vm.prank(uma);
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        pair.finalizeTermination();

        bytes[] memory pu = _freshPrice();
        uint64 obs = uint64(vm.getBlockNumber() - 1);
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__TradingHalted.selector);
        pair.matchBatch(_lists(_one(aL), _one(bS), _empty(), _empty()), 10, pu, obs);
    }

    function test_matchBatch_revertsWhileAdlPending() public {
        // Trigger a REAL ADL (isAdlPending shares a packed storage slot, so no stdstore shortcut):
        // same deep-underwater inheritance scenario as AdlIntegrationTest.
        vm.startPrank(seq);
        usdc.approve(address(sequencer), 20_000 * USDC_SCALE);
        sequencer.deposit(20_000 * USDC_SCALE);
        vm.stopPrank();
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        _deposit(bob, 60_000 * BAZAAR_SCALE);
        uint256 size = 5 * BAZAAR_SCALE;
        uint256 aL5 = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        uint256 bS5 = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(aL5), _one(bS5), _empty(), _empty()), 10), 1, "opened");
        // Resting order placed BEFORE the trigger (order creation is frozen during ADL too).
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 cL = _placeLimit(carol, true, BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);

        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, size, 254_960 * BAZAAR_SCALE);
        address liquidator = makeAddr("liquidator");
        bytes[] memory liqPu = _freshPrice();
        vm.prank(liquidator);
        pair.liquidate(_arr1(dave), liqPu);
        assertTrue(pair.isAdlPending(), "ADL pending");

        // Any further matching is frozen.
        _roll(2);
        bytes[] memory pu = _freshPrice();
        uint64 obs = uint64(vm.getBlockNumber() - 1);
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__TradingFrozenAdlPending.selector);
        pair.matchBatch(_lists(_one(cL), _empty(), _empty(), _empty()), 10, pu, obs);
    }

    function test_matchBatch_revertsPastScheduledCutoff() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 aL = _placeLimit(alice, true, BAZAAR_SCALE / 10, 50_000 * BAZAAR_SCALE);
        uint256 bS = _placeLimit(bob, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        uint256 cutoff = vm.getBlockTimestamp() - 1;
        _stdstore.target(address(pair)).sig("scheduledTerminationTs()").checked_write(cutoff);

        bytes[] memory pu = _freshPrice();
        uint64 obs = uint64(vm.getBlockNumber() - 1);
        vm.prank(seq);
        vm.expectRevert(abi.encodeWithSelector(BazaarPair.BazaarPair__PairScheduledForTermination.selector, cutoff));
        pair.matchBatch(_lists(_one(aL), _one(bS), _empty(), _empty()), 10, pu, obs);
    }

    // ---------------- volume capacity exhaustion ----------------

    /// @notice Once rolling volume saturates bond x 14, the next batch reverts outright.
    function test_matchBatch_noVolumeCapacityAfterSaturation() public {
        _deposit(alice, 50_000 * BAZAAR_SCALE);
        _deposit(bob, 50_000 * BAZAAR_SCALE);
        // Saturate the $70k cap with the boundary partial fill (2 BTC truncated to 1.4).
        uint256 aL = _placeLimit(alice, true, 2 * BAZAAR_SCALE, 50_000 * BAZAAR_SCALE);
        uint256 bS = _placeLimit(bob, false, 2 * BAZAAR_SCALE, 49_500 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(aL), _one(bS), _empty(), _empty()), 10), 1, "boundary fill");

        // A fresh crossable pair within the same 30-min window has zero capacity left.
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        uint256 cL = _placeLimit(carol, true, BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        uint256 dS = _placeLimit(dave, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        bytes[] memory pu = _freshPrice();
        uint64 obs = uint64(vm.getBlockNumber() - 1);
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__NoVolumeCapacity.selector);
        pair.matchBatch(_lists(_one(cL), _one(dS), _empty(), _empty()), 10, pu, obs);
    }

    // ---------------- head-loader integrity ----------------

    /// @notice A sequencer replaying an already-filled order id reverts (no double-execution).
    function test_matchBatch_replayingFilledOrderReverts() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 aL = _placeLimit(alice, true, BAZAAR_SCALE / 10, 50_000 * BAZAAR_SCALE);
        uint256 bS = _placeLimit(bob, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(aL), _one(bS), _empty(), _empty()), 10), 1, "filled");

        // Replay the filled long against a FRESH opposing short (the head only loads when the
        // walk has something to match it against).
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 cS = _placeLimit(carol, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        bytes[] memory pu = _freshPrice();
        uint64 obs = uint64(vm.getBlockNumber() - 1);
        vm.prank(seq);
        vm.expectRevert(abi.encodeWithSelector(MatchingEngineLib.MatchingEngineLib__StaleFilledOrder.selector, aL));
        pair.matchBatch(_lists(_one(aL), _one(cS), _empty(), _empty()), 10, pu, obs);
    }

    /// @notice Smuggling a StopLoss into the limit list reverts (order-type integrity).
    function test_matchBatch_wrongOrderTypeInListReverts() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE / 10);
        uint256 slId = _placeStopLoss(alice, false, BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE, 500);

        // Pair the smuggled StopLoss against a fresh opposing short so the head loads.
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 cS = _placeLimit(carol, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        bytes[] memory pu = _freshPrice();
        uint64 obs = uint64(vm.getBlockNumber() - 1);
        vm.prank(seq);
        vm.expectRevert(
            abi.encodeWithSelector(
                MatchingEngineLib.MatchingEngineLib__WrongOrderTypeInList.selector,
                slId,
                BazaarTypes.OrderType.Limit,
                BazaarTypes.OrderType.StopLoss
            )
        );
        pair.matchBatch(_lists(_one(slId), _one(cS), _empty(), _empty()), 10, pu, obs);
    }
}

/// @title GovernanceNegativeTest
/// @notice Terminator/factory negative space: UMA-callback auth, insurer-vote timing guards, the
///         bond-refund soft-fail fallback, and redeploying a terminated pair's feed.
contract GovernanceNegativeTest is IntegrationBase {
    BazaarPairTerminator internal terminator;

    function setUp() public override {
        super.setUp();
        terminator = factory.pairTerminator();
    }

    function _proposeAndVote(uint256 depositAmt, uint256 voteAmt) internal {
        _depositInsurance(carol, depositAmt);
        vm.warp(vm.getBlockTimestamp() + 7 days + 1 hours); // maturity
        uint256 bond = 500 * USDC_SCALE;
        usdc.mint(carol, bond);
        vm.startPrank(carol);
        usdc.approve(address(terminator), bond);
        terminator.proposeInsurerTermination(address(pair));
        terminator.voteForInsurerTermination(address(pair), voteAmt);
        vm.stopPrank();
    }

    /// @notice Only the assertion's own optimistic oracle may fire the resolution callbacks.
    function test_umaCallbacks_rejectNonOracleCallers() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__OnlyUmaOracle.selector);
        terminator.assertionResolvedCallback(bytes32("fake"), true);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__OnlyUmaOracle.selector);
        terminator.assertionDisputedCallback(bytes32("fake"));
    }

    /// @notice Insurer-vote timing guards: no voting after the 7-day window, no executing before it,
    ///         no double-execution.
    function test_insurerVote_timingGuards() public {
        _proposeAndVote(10_000 * BAZAAR_SCALE, 9_500 * BAZAAR_SCALE);
        (,, uint64 votingEndTs,,,,,) = terminator.insurerProposals(address(pair));

        // Execute before voting closes -> too early.
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerExecutionTooEarly.selector, votingEndTs
            )
        );
        terminator.executeInsurerTermination(address(pair), new bytes[](0));

        // Vote after voting closes -> closed.
        vm.warp(uint256(votingEndTs) + 1);
        vm.prank(carol);
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerVotingClosed.selector);
        terminator.voteForInsurerTermination(address(pair), 1);

        // Execute (succeeds: threshold met, inside window), then execute again -> no active proposal.
        bytes[] memory pu = _freshPrice();
        terminator.executeInsurerTermination(address(pair), pu);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminatedNormal(), "consensus executed");
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerNoActiveProposal.selector);
        terminator.executeInsurerTermination(address(pair), new bytes[](0));
    }

    /// @notice A USDC-blacklisted proposer cannot block consensus: the bond refund soft-fails into
    ///         the pair's insurance fund and the termination still executes.
    function test_insurerVote_bondRefundSoftFailRoutesToInsurance() public {
        _proposeAndVote(10_000 * BAZAAR_SCALE, 9_500 * BAZAAR_SCALE);
        (,, uint64 votingEndTs,,,,,) = terminator.insurerProposals(address(pair));
        vm.warp(uint256(votingEndTs) + 1);

        uint256 insBefore = _insuranceBal();
        uint256 carolUsdcBefore = usdc.balanceOf(carol);

        // Carol can no longer receive USDC (e.g. blacklisted): transfer(carol, bond) returns false.
        vm.mockCall(
            address(usdc),
            abi.encodeWithSignature("transfer(address,uint256)", carol, 500 * USDC_SCALE),
            abi.encode(false)
        );
        bytes[] memory pu = _freshPrice();
        terminator.executeInsurerTermination(address(pair), pu);
        vm.clearMockedCalls();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        pair.finalizeTermination();

        assertTrue(pair.isPairTerminatedNormal(), "termination not blockable by a failed refund");
        assertEq(usdc.balanceOf(carol), carolUsdcBefore, "proposer did not receive the bond");
        assertEq(_insuranceBal() - insBefore, 500 * BAZAAR_SCALE, "bond credited to insurance instead");
    }

    /// @notice A terminated pair's feed id can be redeployed — a dead pair does not permanently
    ///         squat its market.
    function test_factory_redeployAfterTermination() public {
        address uma = pair.umaContract();
        vm.prank(uma);
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminatedNormal(), "old pair dead");

        usdc.mint(deployer, PROPOSAL_TOTAL_USDC);
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 aid = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD v2");
        vm.stopPrank();
        assertTrue(aid != bytes32(0), "redeploy proposal accepted for a terminated pair's feed");
    }
}
