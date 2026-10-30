// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";
import {IOptimisticOracleV3CallbackRecipient, IERC20Minimal} from "../../src/interfaces/IUmaOptimisticOracleV3.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {PythSeed} from "../PythSeed.sol";
import {PythChain} from "../PythChain.sol";

/// @notice Every UMA termination claim opens an insurer vote on its own cutoff. The vote may latch
///         the cutoff before the claim resolves; the pair then waits for the verdict and settles
///         under it: a claim UMA upholds settles under UMA's rule at the cutoff and costs the voters
///         nothing, a claim UMA rejects settles at the median of five prints chained from the cutoff
///         and forfeits half of every yes-voted share, and a claim with no verdict inside the grace
///         settles the same way at the dissent-scaled rate. A cutoff nearer than the liveness is
///         met as proposed only through the vote; without it, the claim's late acceptance moves it.
contract InsurerClaimVoteTest is Test {
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant MAJORITY_SHARES = 20_000 * BAZAAR_SCALE;
    uint256 constant STORED_PRICE = 50_000 * BAZAAR_SCALE;
    uint256 constant LIVENESS = 12 hours; // mirror of TERMINATION_PROPOSAL_LIVENESS
    uint256 constant GRACE = 12 hours; // mirror of SCHEDULED_TERMINATION_GRACE
    uint256 constant VERDICT_GRACE = 14 days; // mirror of CLAIM_VERDICT_GRACE
    uint256 constant POST_FIX_LOCK = 13 days; // mirror of INSURER_POST_FIX_LOCK
    uint256 constant LEVY_BP = 5_000; // mirror of INSURER_LEVY_BP
    uint256 constant LEVY_FLOOR_BP = 1_000; // mirror of INSURER_LEVY_FLOOR_BP
    uint64 constant MAX_LEAD = 14 days; // mirror of INSURER_TERMINATION_MAX_LEAD

    BazaarFactory factory;
    BazaarPair pair;
    BazaarPairTerminator terminator;
    MockOptimisticOracleV3 oo;
    MockUSDC usdc;
    MockPyth mockPyth;

    address deployer = makeAddr("deployer");
    address insurer = makeAddr("insurer"); // a small mature stake that never votes
    address majority = makeAddr("majority"); // holds the voting majority of mature shares
    address umaProposer = makeAddr("umaProposer");
    address disputer = makeAddr("disputer");

    uint256 umaBond;

    receive() external payable {}

    function setUp() public {
        vm.etch(address(0x64), address(new MockArbSys()).code);
        DeployBazaar dep = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = dep.deploy(makeAddr("bugBounty"));
        (, address usdcAddr,,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcAddr);
        terminator = factory.pairTerminator();
        oo = MockOptimisticOracleV3(address(factory.oo()));
        mockPyth = MockPyth(address(factory.oracle().pyth()));
        PythSeed.seed(address(mockPyth), BTC_USD_FEED_ID);

        usdc.mint(deployer, PROPOSAL_TOTAL / 1e12);
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL / 1e12);
        bytes32 assertionId = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        pair = BazaarPair(payable(factory.getPairAddress(pairId)));

        _depositInsurance(insurer, 100 * BAZAAR_SCALE);
        _depositInsurance(majority, MAJORITY_SHARES);
        vm.warp(vm.getBlockTimestamp() + 8 days); // the shares mature

        // The pair's stored price: the last print before the closed session.
        bytes[] memory pu = _tick(50_000, _now(), _now() - 1);
        pair.refreshPrice{value: factory.oracle().getUpdateFee(pu)}(pu);
        (uint256 stored,,,,) = pair.lastPairPrice();
        assertEq(stored, STORED_PRICE, "fixture: the stored price");
        umaBond = terminator.requiredTerminationBond();
    }

    // -------------------- Helpers --------------------

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }

    /// @dev The factory's bug bounty address: where the levy's forfeited shares go.
    function _bounty() internal view returns (address) {
        return factory.bugBountyAddress();
    }

    function _depositInsurance(address user, uint256 amountBazaar) internal {
        uint256 amountUsdc = amountBazaar / 1e12;
        usdc.mint(user, amountUsdc);
        vm.startPrank(user);
        usdc.approve(address(pair), amountUsdc);
        pair.depositToInsurance(amountBazaar, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev A BTC print at `priceUsd` published at `publishTime`, whose predecessor was published at
    ///      `prevPublishTime`: it is the first print at or after any instant in between.
    function _tick(uint256 priceUsd, uint64 publishTime, uint64 prevPublishTime)
        internal
        view
        returns (bytes[] memory pu)
    {
        int64 price = int64(int256(priceUsd * 1e8));
        uint64 conf = uint64(priceUsd * 1e8 / 1000);
        pu = new bytes[](1);
        pu[0] = mockPyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID, price, conf, -8, price, conf, publishTime, prevPublishTime
        );
    }

    function _fee(bytes[] memory pu) internal view returns (uint256) {
        return pu.length == 0 ? 0 : factory.oracle().getUpdateFee(pu);
    }

    /// @dev The UMA proposer files a structural-change claim for `lastTradingTs`; its vote opens.
    function _proposeClaim(uint256 lastTradingTs) internal returns (bytes32 aid) {
        usdc.mint(umaProposer, umaBond);
        vm.startPrank(umaProposer);
        usdc.approve(address(terminator), umaBond);
        aid = terminator.proposeTermination(address(pair), 3, lastTradingTs, "split at the open");
        vm.stopPrank();
    }

    function _voteMajority(bytes32 id) internal {
        vm.prank(majority);
        terminator.voteForInsurerTermination(address(pair), id, MAJORITY_SHARES);
    }

    function _dispute(bytes32 aid) internal {
        usdc.mint(disputer, umaBond);
        vm.startPrank(disputer);
        usdc.approve(address(oo), umaBond);
        oo.disputeAssertion(aid, disputer);
        vm.stopPrank();
    }

    /// @dev The DVM rules on a disputed claim and anyone settles it.
    function _ruleAndSettle(bytes32 aid, bool result) internal {
        oo.mockDvmResolve(aid, result);
        terminator.settleTerminationProposal(aid);
    }

    function _settle(bytes[] memory pu) internal {
        terminator.terminateScheduledPair{value: _fee(pu)}(address(pair), pu);
    }

    /// @dev A chain of $`priceUsd` prints, the first published at `firstPublish` after a print at `firstPrev`.
    function _chain(uint256 priceUsd, uint64 firstPublish, uint64 firstPrev) internal view returns (bytes[] memory) {
        return PythChain.flat(mockPyth, BTC_USD_FEED_ID, priceUsd, firstPublish, firstPrev);
    }

    function _chainFee(bytes[] memory pu) internal view returns (uint256) {
        return factory.oracle().getSampleSetFee(BTC_USD_FEED_ID, pu);
    }

    function _settleChain(bytes[] memory pu) internal {
        terminator.terminateScheduledPair{value: _chainFee(pu)}(address(pair), pu);
    }

    function _settlementPrice() internal view returns (uint256) {
        return pair.auxState().settlementPrice;
    }

    function _redeemAll(address user) internal {
        uint256 shares = pair.insuranceShares(user);
        vm.prank(user);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
        vm.prank(user);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "", "");
    }

    function _outcome(bytes32 id) internal view returns (bool costed, uint8 outcome, uint16 levyBp) {
        (,,,,,,,,,,,, costed,, outcome, levyBp) = terminator.insurerProposals(id);
    }

    function _verdict(bytes32 id) internal view returns (uint8 verdict) {
        (,,,,,,,,,,,,, verdict,,) = terminator.insurerProposals(id);
    }

    // -------------------- The claim opens the vote --------------------

    /// @notice Filing a claim opens a vote on its cutoff, keyed by the assertion id, with the
    ///         snapshot frozen at filing when the cutoff is within the vote window. Only the UMA
    ///         bond moves: the vote carries none of its own.
    function test_Claim_OpensVote_SnapshotAtFiling() public {
        uint256 terminatorBefore = usdc.balanceOf(address(terminator));
        uint256 tCut = _now() + 2 days;
        bytes32 aid = _proposeClaim(tCut);
        assertEq(usdc.balanceOf(address(terminator)), terminatorBefore, "no insurer bond held for a claim");

        (
            address votePair,
            address voteProposer,
            uint64 proposalTs,,
            uint256 cutoffTs,
            uint256 windowOpenTs,,
            uint256 snapshot,
            bool snapshotTaken,
            bool claimBacked,
            bool resolved,,,,,
        ) = terminator.insurerProposals(aid);
        assertEq(votePair, address(pair), "the vote is on the pair");
        assertEq(voteProposer, umaProposer, "filed by the UMA proposer");
        assertEq(proposalTs, _now(), "filed now");
        assertEq(cutoffTs, tCut, "the same cutoff as the claim");
        assertEq(windowOpenTs, _now(), "a cutoff within the window opens the vote at once");
        assertTrue(snapshotTaken, "snapshot taken at filing");
        assertEq(snapshot, pair.totalInsuranceShares() - pair.insuranceShares(address(0)), "the live supply");
        assertTrue(claimBacked, "claim-backed");
        assertFalse(resolved, "pending");
    }

    /// @notice A vote on a far cutoff opens INSURER_TERMINATION_MAX_LEAD before it. Shares deposited
    ///         the maturity period before the window opened vote; later ones do not, though all of
    ///         them count in the snapshot, which is taken at the first vote.
    function test_FarClaim_VoteOpensFourteenDaysBeforeCutoff() public {
        uint256 tCut = _now() + 60 days;
        bytes32 aid = _proposeClaim(tCut);
        uint256 windowOpen = tCut - MAX_LEAD;
        (,,,,, uint256 windowOpenTs,,, bool snapshotTaken,,,,,,,) = terminator.insurerProposals(aid);
        assertEq(windowOpenTs, windowOpen, "opens a fortnight before the cutoff");
        assertFalse(snapshotTaken, "no snapshot until the window opens");

        vm.expectRevert(
            abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__InsurerVoteNotOpen.selector, windowOpen)
        );
        vm.prank(majority);
        terminator.voteForInsurerTermination(address(pair), aid, 1);

        address early = makeAddr("early");
        address late = makeAddr("late");
        vm.warp(windowOpen - 20 days);
        _depositInsurance(early, 5_000 * BAZAAR_SCALE);
        vm.warp(windowOpen - 2 days); // inside the 4-day maturity period: too young to vote
        _depositInsurance(late, 5_000 * BAZAAR_SCALE);

        vm.warp(windowOpen);
        uint256 supply = pair.totalInsuranceShares() - pair.insuranceShares(address(0));
        uint256 earlyShares = pair.insuranceShares(early); // resolved before the prank, which the call would consume
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationSnapshot(address(pair), aid, supply, 0);
        vm.prank(early);
        terminator.voteForInsurerTermination(address(pair), aid, earlyShares);

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerInsufficientUnlockedShares.selector, 0, 1
            )
        );
        vm.prank(late);
        terminator.voteForInsurerTermination(address(pair), aid, 1);

        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        assertEq(pair.scheduledTerminationTs(), tCut, "latched a fortnight ahead");
    }

    // -------------------- The verdict decides the settlement --------------------

    /// @notice The vote latches a cutoff nearer than the liveness, the pair halts there and waits:
    ///         the fix is refused while the verdict is pending. Once the undisputed claim is past
    ///         its liveness, the settlement call settles the assertion itself, the TRUE verdict puts
    ///         the pair under UMA's rule at the cutoff, the voters are not locked, and no levy is
    ///         owed. The UMA bond returns to the proposer.
    function test_ClaimVote_LatchesBeforeVerdict_TrueSettlesUnderUmaRule() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        uint256 proposerAfterBond = usdc.balanceOf(umaProposer);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        assertEq(pair.scheduledTerminationTs(), tCut, "the vote latched the cutoff");
        assertTrue(terminator.insurerScheduled(address(pair)), "insurer-scheduled");
        assertEq(terminator.insurerScheduleId(address(pair)), aid, "by the claim's vote");
        assertEq(terminator.getLockedShares(address(pair), majority), MAJORITY_SHARES, "locked until the cutoff");

        vm.warp(tCut + 10);
        bytes[] memory windowPrint = _tick(49_000, tCut - 1, tCut - 5);
        uint256 fee = _fee(windowPrint);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerVerdictPending.selector, filing + VERDICT_GRACE
            )
        );
        terminator.terminateScheduledPair{value: fee}(address(pair), windowPrint);
        assertEq(pair.settlementPriceFixedTs(), 0, "nothing fixed while the verdict is pending");

        vm.warp(filing + LIVENESS + 1);
        uint8 outcomeTrue = terminator.OUTCOME_TRUE();
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.TerminationProposalAccepted(address(pair), aid, tCut);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationOutcome(address(pair), aid, outcomeTrue, false, 0);
        terminator.terminateScheduledPair{value: fee}(address(pair), windowPrint);

        assertEq(
            _settlementPrice(), 49_000 * BAZAAR_SCALE, "settled at the first print of the window before the cutoff"
        );
        assertEq(_verdict(aid), terminator.VERDICT_TRUE(), "verdict recorded");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), aid, "the acceptance in force");
        assertEq(terminator.umaCutoffCap(address(pair)), tCut, "its cutoff is the cap a later claim must beat");
        assertEq(usdc.balanceOf(umaProposer), proposerAfterBond + umaBond, "the UMA bond came back to the proposer");
        assertEq(terminator.getLockedShares(address(pair), majority), 0, "a TRUE verdict locks nobody");

        pair.finalizeTermination();
        _redeemAll(majority);
        assertEq(pair.insuranceShares(majority), 0, "the voter redeemed at once");
        assertEq(pair.insuranceShares(_bounty()), 0, "no levy on an upheld claim");
    }

    /// @notice A dispute the DVM upholds days after the cutoff: the grace counts from when the
    ///         verdict is recorded, not from the cutoff, so for SCHEDULED_TERMINATION_GRACE after
    ///         that only the window's print settles the pair. Once it has passed with no print, the
    ///         pair settles at its stored price, the last print before the closed session.
    function test_ClaimVote_TrueAfterDispute_GraceRunsFromTheVerdict() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        _dispute(aid);

        vm.warp(tCut + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerVerdictPending.selector, filing + VERDICT_GRACE
            )
        );
        _settle(new bytes[](0));

        vm.warp(filing + 5 days);
        uint256 verdictTs = _now();
        _ruleAndSettle(aid, true);
        assertEq(_verdict(aid), terminator.VERDICT_TRUE(), "upheld");
        (uint8 rule,,, uint256 lastResortTs,) = _rule();
        assertEq(rule, terminator.SETTLE_WINDOW(), "UMA's rule");
        assertEq(lastResortTs, verdictTs + GRACE, "the grace counts from the recorded verdict");

        vm.warp(verdictTs + GRACE);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        _settle(new bytes[](0));

        vm.warp(verdictTs + GRACE + 1);
        _settle(new bytes[](0));
        assertEq(_settlementPrice(), STORED_PRICE, "settled at the stored pre-event price");
        (bool costed, uint8 outcome, uint16 levyBp) = _outcome(aid);
        assertEq(outcome, terminator.OUTCOME_TRUE(), "upheld");
        assertFalse(costed, "not costed");
        assertEq(levyBp, 0, "no levy");
    }

    /// @notice Inside the grace a late verdict opens, an empty call is still refused and the
    ///         window's first print settles the pair, days after the cutoff it was published at.
    function test_ClaimVote_TrueAfterDispute_WindowPrintInsideTheGrace() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        _dispute(aid);

        vm.warp(filing + 5 days);
        uint256 verdictTs = _now();
        _ruleAndSettle(aid, true);

        vm.warp(verdictTs + GRACE - 1);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        _settle(new bytes[](0));
        _settle(_tick(49_000, tCut - 1, tCut - 5));
        assertEq(_settlementPrice(), 49_000 * BAZAAR_SCALE, "settled at the window's first print");
    }

    /// @notice A TRUE ruling nobody recorded by the verdict deadline still decides the settlement.
    ///         The view cannot see it and reports the chain rule, but a call records it and settles
    ///         under UMA's rule with the grace starting at once: a chain and an empty call both
    ///         revert and take the recording with them, and the window's print settles the pair.
    function test_ClaimVote_TrueRuledUnrecordedPastTheDeadline_WindowRule() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        _dispute(aid);
        oo.mockDvmResolve(aid, true); // the DVM rules inside the verdict grace; nobody records it

        vm.warp(filing + VERDICT_GRACE + 1);
        (uint8 rule,,,,) = _rule();
        assertEq(rule, terminator.SETTLE_CHAIN(), "the view cannot see an unrecorded ruling");

        bytes[] memory samples = _chain(44_000, tCut + 30 minutes, tCut - 1);
        uint256 fee = _chainFee(samples);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        terminator.terminateScheduledPair{value: fee}(address(pair), samples);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        _settle(new bytes[](0));
        assertEq(_verdict(aid), terminator.VERDICT_PENDING(), "both attempts took the recording with them");

        _settle(_tick(49_000, tCut - 1, tCut - 5));
        assertEq(_settlementPrice(), 49_000 * BAZAAR_SCALE, "settled at the window's first print");
        (bool costed, uint8 outcome,) = _outcome(aid);
        assertEq(outcome, terminator.OUTCOME_TRUE(), "upheld");
        assertFalse(costed, "not costed");
    }

    /// @notice An oracle that can no longer report the assertion leaves the recorded verdict time
    ///         as the grace's start: an undisputed claim recorded hours after its liveness ended
    ///         then counts its grace from that recording, and the view still answers.
    function test_ClaimVote_OracleCannotReport_GraceRunsFromTheRecording() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);

        vm.warp(filing + LIVENESS + 5 hours);
        uint256 recordedTs = _now();
        terminator.settleTerminationProposal(aid);
        assertEq(_verdict(aid), terminator.VERDICT_TRUE(), "upheld and recorded");

        vm.mockCallRevert(address(oo), abi.encodeCall(MockOptimisticOracleV3.getAssertion, (aid)), "gone");
        (uint8 rule,,, uint256 lastResortTs,) = _rule();
        assertEq(rule, terminator.SETTLE_WINDOW(), "UMA's rule");
        assertEq(lastResortTs, recordedTs + GRACE, "the grace counts from the recording");

        vm.warp(recordedTs + GRACE);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        _settle(new bytes[](0));
        vm.warp(recordedTs + GRACE + 1);
        _settle(new bytes[](0));
        assertEq(_settlementPrice(), STORED_PRICE, "settled at the stored price");
    }

    /// @notice An undisputed claim whose liveness ended before its cutoff counts its grace from
    ///         the cutoff, however late the assertion is settled: the end of the liveness, not the
    ///         recording, is when its verdict became known.
    function test_ClaimVote_UndisputedFarClaim_GraceRunsFromTheCutoff() public {
        uint64 filing = _now();
        uint64 tCut = filing + 2 days;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        vm.warp(filing + LIVENESS + 1 hours); // the liveness is over and nobody settles the claim
        terminator.executeInsurerTermination(address(pair), aid);
        assertEq(terminator.insurerScheduleId(address(pair)), aid, "the claim's vote latched");

        vm.warp(tCut + 6 hours);
        terminator.settleTerminationProposal(aid);
        (uint8 rule,,, uint256 lastResortTs,) = _rule();
        assertEq(rule, terminator.SETTLE_WINDOW(), "UMA's rule");
        assertEq(lastResortTs, tCut + GRACE, "the grace counts from the cutoff, not the recording");

        vm.warp(tCut + GRACE + 1);
        _settle(new bytes[](0));
        assertEq(_settlementPrice(), STORED_PRICE, "settled at the stored price");
    }

    /// @notice A verdict recorded before the vote latched the cutoff leaves the grace counting from
    ///         the cutoff, which lies after the recording. The pair refuses the acceptance's
    ///         schedule here, so the claim's own vote is what halts it.
    function test_ClaimVote_VerdictBeforeTheLatch_GraceRunsFromTheCutoff() public {
        uint64 filing = _now();
        uint64 tCut = filing + 2 days;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        _dispute(aid);
        oo.mockDvmResolve(aid, true);
        vm.mockCallRevert(
            address(pair),
            abi.encodeWithSelector(BazaarPair.setScheduledTermination.selector),
            abi.encodeWithSignature("Refused()")
        );
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.TerminationScheduleRefused(address(pair), aid);
        terminator.settleTerminationProposal(aid);
        vm.clearMockedCalls();
        assertEq(_verdict(aid), terminator.VERDICT_TRUE(), "upheld before the latch");
        assertEq(pair.scheduledTerminationTs(), 0, "the acceptance scheduled nothing");

        terminator.executeInsurerTermination(address(pair), aid);
        assertEq(pair.scheduledTerminationTs(), tCut, "the vote latched its cutoff");

        vm.warp(tCut + 1);
        (uint8 rule,,, uint256 lastResortTs,) = _rule();
        assertEq(rule, terminator.SETTLE_WINDOW(), "UMA's rule");
        assertEq(lastResortTs, tCut + GRACE, "the grace counts from the cutoff");
    }

    /// @notice A verdict the settlement call records itself starts the grace at once: days past
    ///         the cutoff, a call without the window's print reverts and takes the recording with
    ///         it, so nobody can record a late verdict and fall back to the stored price in one
    ///         transaction. The window's print then settles the pair and records the verdict.
    function test_ClaimVote_VerdictRecordedBySettlement_StartsTheGraceAtOnce() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        _dispute(aid);

        vm.warp(filing + 5 days);
        oo.mockDvmResolve(aid, true); // the DVM has ruled; nobody has recorded it
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        _settle(new bytes[](0));
        assertEq(_verdict(aid), terminator.VERDICT_PENDING(), "the recording reverted with the call");
        assertEq(pair.settlementPriceFixedTs(), 0, "nothing fixed");

        _settle(_tick(49_000, tCut - 1, tCut - 5));
        assertEq(_settlementPrice(), 49_000 * BAZAAR_SCALE, "settled at the window's first print");
        assertEq(_verdict(aid), terminator.VERDICT_TRUE(), "recorded with the fix");
    }

    /// @notice A verdict known before the cutoff leaves the grace counting from the cutoff: a
    ///         disputed claim the DVM upholds a day ahead of it settles at the stored price once the
    ///         cutoff is SCHEDULED_TERMINATION_GRACE old.
    function test_ClaimVote_VerdictBeforeTheCutoff_GraceRunsFromTheCutoff() public {
        uint64 filing = _now();
        uint64 tCut = filing + 2 days;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        _dispute(aid);

        vm.warp(filing + 1 days);
        _ruleAndSettle(aid, true);
        assertEq(pair.scheduledTerminationTs(), tCut, "the vote's cutoff stands");

        vm.warp(tCut + 1);
        (uint8 rule,,, uint256 lastResortTs,) = _rule();
        assertEq(rule, terminator.SETTLE_WINDOW(), "UMA's rule");
        assertEq(lastResortTs, tCut + GRACE, "the grace counts from the cutoff");

        vm.warp(tCut + GRACE);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        _settle(new bytes[](0));

        vm.warp(tCut + GRACE + 1);
        _settle(new bytes[](0));
        assertEq(_settlementPrice(), STORED_PRICE, "settled at the stored price");
    }

    /// @notice An undisputed claim whose cutoff falls inside its liveness is known to be upheld
    ///         only when the liveness ends, so the grace counts from then rather than from the
    ///         cutoff: an empty call past a grace counted from the cutoff is still refused.
    function test_ClaimVote_UndisputedNearClaim_GraceRunsFromTheEndOfLiveness() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);

        vm.warp(tCut + GRACE + 1);
        (uint8 rule,,, uint256 lastResortTs,) = _rule();
        assertEq(rule, terminator.SETTLE_WINDOW(), "upheld: UMA's rule");
        assertEq(lastResortTs, filing + LIVENESS + GRACE, "the grace counts from the end of the liveness");
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        _settle(new bytes[](0));

        vm.warp(filing + LIVENESS + GRACE);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        _settle(new bytes[](0));

        vm.warp(filing + LIVENESS + GRACE + 1);
        _settle(new bytes[](0));
        assertEq(_settlementPrice(), STORED_PRICE, "settled at the stored price");
        assertEq(_verdict(aid), terminator.VERDICT_TRUE(), "upheld");
    }

    /// @notice The DVM rejects the claim after the vote halted the pair: a chain starting before the
    ///         cutoff is refused, the pair settles at the median of the chain from the cutoff, the
    ///         yes-voters stay locked through the cooldown and forfeit half their voted shares to
    ///         the bug bounty address; a holder who did not vote redeems at once and in full.
    function test_ClaimVote_False_ChainRuleAndLevy() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        _dispute(aid);

        vm.warp(filing + 2 days);
        oo.mockDvmResolve(aid, false);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.TerminationProposalRejected(address(pair), aid);
        terminator.settleTerminationProposal(aid);
        assertEq(_verdict(aid), terminator.VERDICT_FALSE(), "rejected");

        bytes[] memory pre = _chain(49_000, tCut - 1, tCut - 5);
        uint256 preFee = _chainFee(pre);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        terminator.terminateScheduledPair{value: preFee}(address(pair), pre);
        bytes[] memory post = _chain(44_000, tCut + 30 minutes, tCut - 1);
        uint256 postFee = _chainFee(post);
        uint8 outcomeFalse = terminator.OUTCOME_FALSE();
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationOutcome(address(pair), aid, outcomeFalse, true, uint16(LEVY_BP));
        terminator.terminateScheduledPair{value: postFee}(address(pair), post);
        assertEq(_settlementPrice(), 44_000 * BAZAAR_SCALE, "settled at the chain's median");

        uint256 fixedTs = pair.settlementPriceFixedTs();
        assertEq(terminator.getLockedShares(address(pair), majority), MAJORITY_SHARES, "yes-voter locked after the fix");
        assertEq(terminator.getLockedShares(address(pair), insurer), 0, "the non-voter is free");

        pair.finalizeTermination();
        _redeemAll(insurer);
        assertEq(pair.insuranceShares(insurer), 0, "non-voter redeemed at once");
        assertEq(pair.insuranceShares(_bounty()), 0, "nothing forfeited by a non-voter");

        vm.prank(majority);
        pair.requestInsuranceWithdrawal(MAJORITY_SHARES, 0, 0, 0, "", "");
        vm.prank(majority);
        vm.expectRevert(InsuranceVaultLib.InsuranceVaultLib__SharesLockedForVoting.selector);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "", "");

        vm.warp(fixedTs + POST_FIX_LOCK);
        address bounty = _bounty();
        uint256 bountyBefore = pair.insuranceShares(bounty);
        vm.expectEmit(true, true, true, true, address(terminator));
        emit BazaarPairTerminator.InsurerLevyCharged(
            address(pair), aid, majority, MAJORITY_SHARES, MAJORITY_SHARES / 2, bounty
        );
        vm.prank(majority);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "", "");
        assertEq(pair.insuranceShares(majority), 0, "all shares left the voter");
        assertEq(pair.insuranceShares(bounty) - bountyBefore, MAJORITY_SHARES / 2, "half the voted stake forfeited");
    }

    /// @notice A dispute the DVM never rules on: the fix waits out CLAIM_VERDICT_GRACE from the
    ///         filing, then settles unjudged at the median of the chain from the cutoff, with the
    ///         levy at the dissent-scaled rate.
    function test_ClaimVote_NoVerdict_UnjudgedAfterGrace() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        (,,,,,,, uint256 snapshot,,,,,,,,) = terminator.insurerProposals(aid);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        _dispute(aid);

        bytes[] memory post = _chain(44_000, tCut + 30 minutes, tCut - 1);
        uint256 fee = _chainFee(post);
        vm.warp(filing + VERDICT_GRACE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerVerdictPending.selector, filing + VERDICT_GRACE
            )
        );
        terminator.terminateScheduledPair{value: fee}(address(pair), post);

        vm.warp(filing + VERDICT_GRACE);
        uint256 scaled = LEVY_BP * (snapshot - MAJORITY_SHARES) / snapshot;
        uint16 expectedLevyBp = uint16(scaled < LEVY_FLOOR_BP ? LEVY_FLOOR_BP : scaled);
        uint8 outcomeUnjudged = terminator.OUTCOME_UNJUDGED();
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationOutcome(address(pair), aid, outcomeUnjudged, true, expectedLevyBp);
        terminator.terminateScheduledPair{value: fee}(address(pair), post);
        assertEq(_settlementPrice(), 44_000 * BAZAAR_SCALE, "settled at the chain's median");
        assertEq(_verdict(aid), terminator.VERDICT_PENDING(), "no verdict ever came");
        assertEq(terminator.getLockedShares(address(pair), majority), MAJORITY_SHARES, "locked after the fix");
    }

    /// @notice A FALSE verdict before the vote has latched ends the vote: votes unlock, and the
    ///         proposal takes no further votes and cannot be executed.
    function test_ClaimVote_FalseBeforeLatch_KillsVote() public {
        uint256 tCut = _now() + 2 days;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        assertEq(terminator.getLockedShares(address(pair), majority), MAJORITY_SHARES, "locked while pending");
        _dispute(aid);

        vm.warp(_now() + LIVENESS);
        oo.mockDvmResolve(aid, false);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationRejected(address(pair), aid);
        terminator.settleTerminationProposal(aid);

        assertEq(terminator.getLockedShares(address(pair), majority), 0, "no schedule on the pair: released");
        assertEq(pair.scheduledTerminationTs(), 0, "nothing scheduled");
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerNoActiveProposal.selector);
        terminator.executeInsurerTermination(address(pair), aid);
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerNoActiveProposal.selector);
        vm.prank(insurer);
        terminator.voteForInsurerTermination(address(pair), aid, 1);
    }

    /// @notice An undisputed claim with a cutoff beyond the liveness is accepted before its cutoff
    ///         and schedules the pair itself, as before. Votes cast on it lock their shares until
    ///         the cutoff they backed; the vote is then preempted by the schedule it agrees with,
    ///         and the pair settles under UMA's rule with nothing stamped and no lock after the fix.
    function test_StandardClaim_UmaSchedules_VoteLocksToCutoffThenPreempted() public {
        uint64 tCut = _now() + 2 days;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);

        vm.warp(_now() + LIVENESS + 1);
        terminator.settleTerminationProposal(aid);
        assertEq(pair.scheduledTerminationTs(), tCut, "UMA scheduled the pair");
        assertFalse(terminator.insurerScheduled(address(pair)), "UMA's schedule, not the vote's");
        assertEq(terminator.getLockedShares(address(pair), majority), MAJORITY_SHARES, "locked until the cutoff");

        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationPreempted(address(pair), aid);
        terminator.executeInsurerTermination(address(pair), aid);

        vm.warp(tCut + 1);
        assertEq(terminator.getLockedShares(address(pair), majority), 0, "released at the cutoff");
        _settle(_tick(49_000, tCut - 1, tCut - 5));
        assertEq(_settlementPrice(), 49_000 * BAZAAR_SCALE, "UMA's rule");
        (bool costed, uint8 outcome,) = _outcome(aid);
        assertEq(outcome, terminator.OUTCOME_NONE(), "nothing stamped: the vote did not schedule the pair");
        assertFalse(costed, "not costed");
        pair.finalizeTermination();
        _redeemAll(majority);
        assertEq(pair.insuranceShares(_bounty()), 0, "no levy");
    }

    /// @notice A near cutoff nobody voted through: the vote expires at its latch deadline with no
    ///         bond of its own to move, and the claim, accepted only when its liveness ends, is
    ///         scheduled like any late acceptance, a lead past the settle and under UMA's rule.
    function test_NearClaim_NoVote_ExpiresAndTheLateAcceptanceSchedules() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        uint256 terminatorBefore = usdc.balanceOf(address(terminator));

        vm.warp(tCut);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationFailed(address(pair), aid, tCut, 0, _snapshot(aid), false);
        terminator.executeInsurerTermination(address(pair), aid);
        assertEq(usdc.balanceOf(address(terminator)), terminatorBefore, "no bond moves for a claim-backed vote");

        uint256 acceptTs = filing + LIVENESS + 1;
        uint256 cutoffTs = acceptTs + BazaarTypes.MIN_CUTOFF_LEAD;
        vm.warp(acceptTs);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.TerminationProposalAccepted(address(pair), aid, cutoffTs);
        terminator.settleTerminationProposal(aid);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "scheduled a lead past the late acceptance");
        assertFalse(terminator.insurerScheduled(address(pair)), "a UMA schedule, not the vote's");
        (uint8 rule,, uint256 latestPublishTs,,) = _rule();
        assertEq(rule, terminator.SETTLE_WINDOW(), "settles under UMA's rule");
        assertEq(latestPublishTs, cutoffTs, "in the window ending at the moved cutoff");
    }

    /// @notice Once the vote has latched and its claim is upheld, the claim's cutoff is the UMA
    ///         cutoff in force: a later claim must name an earlier one.
    function test_ClaimVote_OwnVerdictSetsTheCutoffInForce() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        vm.warp(filing + LIVENESS + 1);
        terminator.settleTerminationProposal(aid);
        assertEq(terminator.umaCutoffCap(address(pair)), tCut, "own cutoff in force");

        usdc.mint(umaProposer, umaBond);
        vm.startPrank(umaProposer);
        usdc.approve(address(terminator), umaBond);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__CutoffNotEarlier.selector, uint256(tCut), uint256(tCut)
            )
        );
        terminator.proposeTermination(address(pair), 3, tCut, "split at the open");
        vm.stopPrank();
    }

    /// @notice Votes on a claim-backed proposal lock shares like any other, and the withdrawal gate
    ///         reads them: a request filed before the vote cannot be paid while the vote is live.
    function test_ClaimVote_LockedSharesCannotBeWithdrawn() public {
        uint64 start = _now();
        vm.prank(majority);
        pair.requestInsuranceWithdrawal(MAJORITY_SHARES, 0, 0, 0, "", "");

        // A cutoff twenty days out: its window opens on day six, and the vote outlives the cooldown.
        bytes32 aid = _proposeClaim(start + 20 days);
        vm.warp(start + 20 days - MAX_LEAD);
        _voteMajority(aid);

        vm.warp(start + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1 hours);
        bytes[] memory pu = _tick(50_000, _now(), _now() - 1);
        uint256 fee = _fee(pu);
        vm.prank(majority);
        vm.expectRevert(InsuranceVaultLib.InsuranceVaultLib__SharesLockedForVoting.selector);
        pair.executeInsuranceWithdrawal{value: fee}(pu, 0, 0, 0, "", "");
    }

    /// @notice A near claim whose cutoff precedes a bare vote's halt, resolving TRUE only after the
    ///         halt, caps nothing: the pair traded through that cutoff before it stopped. It is
    ///         superseded, and the vote settles costed.
    function test_NearClaim_CutoffBeforeTheBareHalt_CapsNothing() public {
        uint64 tZ = _now() + 1 days;
        usdc.mint(insurer, 1_000 * USDC_SCALE); // INSURER_TERMINATION_BOND_USDC
        vm.startPrank(insurer);
        usdc.approve(address(terminator), 1_000 * USDC_SCALE);
        bytes32 bare = terminator.proposeInsurerTermination(address(pair), tZ);
        vm.stopPrank();
        _voteMajority(bare);
        terminator.executeInsurerTermination(address(pair), bare);
        assertEq(pair.scheduledTerminationTs(), tZ, "the bare vote holds the schedule");

        vm.warp(tZ - 3 hours);
        uint64 filing = _now();
        bytes32 near = _proposeClaim(filing + 2 hours);

        vm.warp(filing + LIVENESS + 1);
        assertGt(_now(), tZ, "fixture: the claim resolves after the bare cutoff");
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.TerminationProposalSuperseded(address(pair), near);
        terminator.settleTerminationProposal(near);
        assertEq(terminator.umaCutoffCap(address(pair)), 0, "no cap from a cutoff before the halt");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), bytes32(0), "no acceptance in force");

        _settleChain(_chain(44_000, tZ + 30 minutes, tZ - 1));
        (bool costed,,) = _outcome(bare);
        assertTrue(costed, "the bare vote is costed");
    }

    /// @notice A near claim whose cutoff is at or after a bare vote's halt, accepted after both,
    ///         caps the vote's chain at its own cutoff: a sample published past it never counts,
    ///         and the vote, having met a cutoff UMA verified, is not costed.
    function test_NearClaim_CutoffAfterTheBareHalt_CapsTheChainThere() public {
        uint64 tZ = _now() + 1 days;
        usdc.mint(insurer, 1_000 * USDC_SCALE); // INSURER_TERMINATION_BOND_USDC
        vm.startPrank(insurer);
        usdc.approve(address(terminator), 1_000 * USDC_SCALE);
        bytes32 bare = terminator.proposeInsurerTermination(address(pair), tZ);
        vm.stopPrank();
        _voteMajority(bare);
        terminator.executeInsurerTermination(address(pair), bare);

        vm.warp(tZ - 1 hours);
        uint64 filing = _now();
        uint64 tNear = filing + 2 hours; // an hour past the bare halt
        bytes32 near = _proposeClaim(tNear);

        vm.warp(filing + LIVENESS + 1);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.TerminationProposalAccepted(address(pair), near, tNear);
        terminator.settleTerminationProposal(near);
        assertEq(pair.scheduledTerminationTs(), tZ, "the bare halt stands");
        assertEq(terminator.umaCutoffCap(address(pair)), tNear, "capped at the claim's own cutoff");

        // A chain from half an hour past the halt publishes its last sample past the claim's cutoff.
        bytes[] memory late = _chain(44_000, tZ + 30 minutes, tZ - 1);
        uint256 lateFee = _chainFee(late);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        terminator.terminateScheduledPair{value: lateFee}(address(pair), late);

        _settleChain(_chain(44_000, tZ, tZ - 1));
        assertEq(_settlementPrice(), 44_000 * BAZAAR_SCALE, "the chain inside the cap settles the pair");
        (bool costed,,) = _outcome(bare);
        assertFalse(costed, "the vote met a cutoff UMA verified");
    }

    // -------------------- What keepers read --------------------

    function _rule()
        internal
        view
        returns (
            uint8 rule,
            uint256 firstTarget,
            uint256 latestPublishTs,
            uint256 lastResortTs,
            uint256 verdictDeadline
        )
    {
        return terminator.settlementRule(address(pair));
    }

    /// @notice settlementRule follows a claim-backed vote's verdict: nothing before a schedule,
    ///         a wait for the verdict while the claim is disputed, and the chain once UMA rejects it.
    function test_SettlementRule_FollowsTheVerdict() public {
        (uint8 rule,,,,) = _rule();
        assertEq(rule, terminator.SETTLE_NOTHING(), "no cutoff yet");

        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        _dispute(aid);

        uint256 deadline;
        (rule,,,, deadline) = _rule();
        assertEq(rule, terminator.SETTLE_AWAIT_VERDICT(), "the vote waits for the verdict");
        assertEq(deadline, filing + VERDICT_GRACE, "until the verdict grace runs out");

        vm.warp(filing + 2 days);
        oo.mockDvmResolve(aid, false);
        terminator.settleTerminationProposal(aid);
        uint256 firstTarget;
        uint256 latestPublishTs;
        uint256 lastResortTs;
        (rule, firstTarget, latestPublishTs, lastResortTs, deadline) = _rule();
        assertEq(rule, terminator.SETTLE_CHAIN(), "a rejected claim settles by the chain");
        assertEq(firstTarget, tCut, "chained from the cutoff");
        assertEq(latestPublishTs, type(uint64).max, "unbounded");
        assertEq(lastResortTs, tCut + 21 days, "the last resort");
        assertEq(deadline, 0, "nothing to wait for");
    }

    /// @notice A disputed claim still unresolved when the verdict grace runs out settles by the chain.
    function test_SettlementRule_NoVerdictByTheDeadlineIsTheChain() public {
        uint64 filing = _now();
        bytes32 aid = _proposeClaim(filing + 3 hours);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        _dispute(aid);

        vm.warp(filing + VERDICT_GRACE - 1);
        (uint8 rule,,,,) = _rule();
        assertEq(rule, terminator.SETTLE_AWAIT_VERDICT(), "still waiting");
        vm.warp(filing + VERDICT_GRACE);
        (rule,,,,) = _rule();
        assertEq(rule, terminator.SETTLE_CHAIN(), "unjudged: the chain");
    }

    /// @notice An undisputed claim past its liveness reads as upheld before anyone settles it, so
    ///         the vote it backs settles under UMA's window rule.
    function test_SettlementRule_UndisputedPastLivenessIsTheWindow() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);

        vm.warp(filing + LIVENESS + 1);
        (uint8 rule, uint256 firstTarget, uint256 latestPublishTs, uint256 lastResortTs, uint256 deadline) = _rule();
        assertEq(rule, terminator.SETTLE_WINDOW(), "upheld: UMA's rule");
        assertEq(firstTarget, tCut - 3, "the window opens MAX_PRICE_STALENESS before the cutoff");
        assertEq(latestPublishTs, tCut, "and closes at it");
        assertEq(lastResortTs, filing + LIVENESS + GRACE, "the grace counts from the end of the liveness");
        assertEq(deadline, 0, "nothing to wait for");
    }

    /// @notice A pair scheduled by UMA's own acceptance settles under the window rule.
    function test_SettlementRule_UmaScheduleIsTheWindow() public {
        uint64 tCut = _now() + 2 days;
        bytes32 aid = _proposeClaim(tCut);
        vm.warp(_now() + LIVENESS + 1);
        terminator.settleTerminationProposal(aid);
        assertFalse(terminator.insurerScheduled(address(pair)), "fixture: UMA scheduled the pair");
        (uint8 rule, uint256 firstTarget, uint256 latestPublishTs, uint256 lastResortTs,) = _rule();
        assertEq(rule, terminator.SETTLE_WINDOW(), "UMA's rule");
        assertEq(firstTarget, tCut - 3, "window start");
        assertEq(latestPublishTs, tCut, "window end");
        assertEq(lastResortTs, tCut + GRACE, "the grace counts from the cutoff");
    }

    /// @notice A settle OOv3 refuses because it holds its reentrancy lock is not read as "no
    ///         verdict": past the verdict deadline, on a claim the DVM has already rejected, a call
    ///         made from inside an OOv3 callback reverts instead of settling the pair unjudged, and
    ///         a call made normally then records the rejection and settles under it.
    function test_SettleInsideTheOracleLock_RefusedNotUnjudged() public {
        uint64 filing = _now();
        uint64 tCut = filing + 3 hours;
        bytes32 aid = _proposeClaim(tCut);
        _voteMajority(aid);
        terminator.executeInsurerTermination(address(pair), aid);
        _dispute(aid);
        oo.mockDvmResolve(aid, false); // the DVM has ruled; nobody has settled the claim

        vm.warp(filing + VERDICT_GRACE + 1);
        bytes[] memory samples = _chain(44_000, tCut + 30 minutes, tCut - 1);
        OracleLockHolder holder = new OracleLockHolder(oo, terminator);
        holder.settleWhileLocked(address(pair), samples, IERC20Minimal(address(usdc)));
        assertTrue(holder.reentered(), "the call was made while OOv3 held its lock");
        assertFalse(holder.settledInside(), "refused");
        assertEq(
            holder.revertData(),
            abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__OracleBusy.selector),
            "re-raised as busy"
        );
        assertEq(pair.settlementPriceFixedTs(), 0, "nothing fixed");

        uint256 fee = _chainFee(samples);
        uint8 outcomeFalse = terminator.OUTCOME_FALSE();
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationOutcome(address(pair), aid, outcomeFalse, true, uint16(LEVY_BP));
        terminator.terminateScheduledPair{value: fee}(address(pair), samples);
    }

    function _snapshot(bytes32 id) internal view returns (uint256 snapshot) {
        (,,,,,,, snapshot,,,,,,,,) = terminator.insurerProposals(id);
    }
}

/// @notice Calls terminateScheduledPair while OOv3 holds its reentrancy lock: it disputes an
///         assertion of its own, and from the dispute callback OOv3 makes before releasing the
///         lock, calls the terminator. It records how that call ended.
contract OracleLockHolder is IOptimisticOracleV3CallbackRecipient {
    MockOptimisticOracleV3 internal immutable oo;
    BazaarPairTerminator internal immutable terminator;
    address internal pair;
    bytes[] internal samples;

    bool public reentered;
    bool public settledInside;
    bytes public revertData;

    constructor(MockOptimisticOracleV3 oo_, BazaarPairTerminator terminator_) {
        oo = oo_;
        terminator = terminator_;
    }

    function settleWhileLocked(address pair_, bytes[] memory samples_, IERC20Minimal currency) external {
        pair = pair_;
        delete samples;
        for (uint256 i = 0; i < samples_.length; i++) {
            samples.push(samples_[i]);
        }
        bytes32 own = oo.assertTruth(
            "lock holder",
            address(this),
            address(this),
            address(0),
            1 hours,
            currency,
            0,
            bytes32("ASSERT_TRUTH2"),
            bytes32(0)
        );
        oo.disputeAssertion(own, address(this));
    }

    function assertionDisputedCallback(bytes32) external override {
        reentered = true;
        bytes[] memory s = samples;
        (bool ok, bytes memory data) =
            address(terminator).call(abi.encodeCall(BazaarPairTerminator.terminateScheduledPair, (pair, s)));
        settledInside = ok;
        revertData = data;
    }

    function assertionResolvedCallback(bytes32, bool) external override {}
}
