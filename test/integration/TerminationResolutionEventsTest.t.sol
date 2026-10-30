// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";

/// @notice Every UMA termination resolution leaves exactly one terminator event, so a resolved
///         proposal can be told from a pending one without reading storage: Accepted when it
///         schedules (or caps) the pair, Superseded when it resolves TRUE with nothing left to do,
///         Rejected when it resolves FALSE.
contract TerminationResolutionEventsTest is IntegrationBase {
    event TerminationProposalAccepted(address indexed pair, bytes32 indexed assertionId, uint256 lastTradingTs);
    event TerminationScheduleRefused(address indexed pair, bytes32 indexed assertionId);
    event TerminationProposalSuperseded(address indexed pair, bytes32 indexed assertionId);
    event TerminationProposalRejected(address indexed pair, bytes32 indexed assertionId);

    BazaarPairTerminator internal terminator;
    MockOptimisticOracleV3 internal mockOO;

    function setUp() public override {
        super.setUp();
        terminator = factory.pairTerminator();
        mockOO = MockOptimisticOracleV3(address(factory.oo()));
    }

    function _propose(address proposer, uint256 lastTradingTs) internal returns (bytes32 aid) {
        uint256 bond = terminator.TERMINATION_PROPOSAL_BOND();
        usdc.mint(proposer, bond);
        vm.startPrank(proposer);
        usdc.approve(address(terminator), bond);
        aid = terminator.proposeTermination(address(pair), 2, lastTradingTs, "delisting");
        vm.stopPrank();
    }

    /// @dev Settles `aid` and returns how many of the four resolution events the terminator emitted
    ///      while doing so, and the selector of the last one; every one must name this pair and
    ///      this assertion.
    function _settleRecording(bytes32 aid) internal returns (uint256 n, bytes32 sig) {
        vm.recordLogs();
        terminator.settleTerminationProposal(aid);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(terminator)) continue;
            bytes32 t = logs[i].topics[0];
            if (
                t == TerminationProposalAccepted.selector || t == TerminationScheduleRefused.selector
                    || t == TerminationProposalSuperseded.selector || t == TerminationProposalRejected.selector
            ) {
                ++n;
                sig = t;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(pair)))), "event names the pair");
                assertEq(logs[i].topics[2], aid, "event names the assertion");
            }
        }
    }

    function test_firstTrueResolution_emitsAccepted() public {
        uint256 lastTradingTs = vm.getBlockTimestamp() + 7 days;
        bytes32 aid = _propose(alice, lastTradingTs);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);

        vm.expectEmit(true, true, false, true, address(terminator));
        emit TerminationProposalAccepted(address(pair), aid, lastTradingTs);
        terminator.settleTerminationProposal(aid);
    }

    /// @notice Two proposals filed side by side: the first to resolve TRUE schedules the pair, and
    ///         the second, whose cutoff is later, resolves TRUE without moving it.
    function test_secondTrueResolution_emitsSupersededOnly() public {
        uint256 lastTradingTs = vm.getBlockTimestamp() + 7 days;
        bytes32 first = _propose(alice, lastTradingTs);
        bytes32 second = _propose(carol, lastTradingTs + 1 days);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(first);

        vm.expectEmit(true, true, false, true, address(terminator));
        emit TerminationProposalSuperseded(address(pair), second);
        terminator.settleTerminationProposal(second);

        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), first, "the first acceptance stands");
        assertEq(pair.scheduledTerminationTs(), lastTradingTs, "the cutoff is the first one's");
    }

    function test_secondTrueResolution_emitsExactlyOneResolutionEvent() public {
        uint256 lastTradingTs = vm.getBlockTimestamp() + 7 days;
        bytes32 first = _propose(alice, lastTradingTs);
        bytes32 second = _propose(carol, lastTradingTs);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        (uint256 n, bytes32 sig) = _settleRecording(first);
        assertEq(n, 1, "first resolution: one event");
        assertEq(sig, TerminationProposalAccepted.selector, "first resolution: accepted");
        (n, sig) = _settleRecording(second);
        assertEq(n, 1, "second resolution: one event");
        assertEq(sig, TerminationProposalSuperseded.selector, "second resolution: superseded");
    }

    /// @notice A second proposal with an earlier cutoff resolves TRUE against a pair that already
    ///         has its UMA cutoff, and brings it forward with a single Accepted event.
    function test_earlierSecondTrueResolution_emitsAcceptedOnly() public {
        uint256 lastTradingTs = vm.getBlockTimestamp() + 7 days;
        bytes32 first = _propose(alice, lastTradingTs);
        bytes32 second = _propose(carol, lastTradingTs - 1 days);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(first);

        (uint256 n, bytes32 sig) = _settleRecording(second);
        assertEq(n, 1, "second resolution: one event");
        assertEq(sig, TerminationProposalAccepted.selector, "second resolution: accepted");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), second, "the earlier cutoff is in force");
        assertEq(pair.scheduledTerminationTs(), lastTradingTs - 1 days, "the cutoff is the second one's");
    }

    /// @notice A proposal that resolves TRUE after another path fixed the pair's price.
    function test_trueResolutionAfterPriceFixed_emitsSuperseded() public {
        bytes32 aid = _propose(alice, vm.getBlockTimestamp() + 7 days);
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);

        vm.expectEmit(true, true, false, true, address(terminator));
        emit TerminationProposalSuperseded(address(pair), aid);
        terminator.settleTerminationProposal(aid);
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), bytes32(0), "nothing accepted");
    }

    /// @notice A disputed proposal the DVM resolves FALSE.
    function test_falseResolution_emitsRejected() public {
        uint256 lastTradingTs = vm.getBlockTimestamp() + 7 days;
        bytes32 aid = _propose(alice, lastTradingTs);
        uint256 bond = terminator.TERMINATION_PROPOSAL_BOND();
        usdc.mint(bob, bond);
        vm.startPrank(bob);
        usdc.approve(address(mockOO), bond);
        mockOO.disputeAssertion(aid, bob);
        vm.stopPrank();
        mockOO.mockDvmResolve(aid, false);

        (uint256 n, bytes32 sig) = _settleRecording(aid);
        assertEq(n, 1, "one resolution event");
        assertEq(sig, TerminationProposalRejected.selector, "rejected");
        assertEq(pair.scheduledTerminationTs(), 0, "the pair is not scheduled");
    }
}
