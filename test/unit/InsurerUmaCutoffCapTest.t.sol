// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {PythSeed} from "../PythSeed.sol";
import {PythChain} from "../PythChain.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";

/// @notice A bare insurer cutoff that meets a cutoff UMA verified halts the pair at the earlier of
///         the two, but the pair settles no later than UMA's: at the median of a chain of prints
///         published between them, every sample no later than UMA's cutoff, or at its stored price
///         once UMA's cutoff is a grace old. Both orders are covered,
///         a vote that pulls an accepted UMA schedule earlier and a UMA acceptance that lands after
///         an insurer schedule. No print between the cutoffs models the closed session ahead of
///         the event UMA verified, and the reopen print after UMA's cutoff is the post-event price
///         that must not settle the pair. The votes here are bare proposals, filed with no claim
///         of their own; the UMA claims they meet are other proposers' and go unvoted.
contract InsurerUmaCutoffCapTest is Test {
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant INSURER_BOND_USDC = 1_000 * 1e6; // mirror of INSURER_TERMINATION_BOND_USDC
    uint256 constant GRACE = 12 hours; // mirror of SCHEDULED_TERMINATION_GRACE
    uint256 constant DEAD_THRESHOLD = 21 days; // mirror of ORACLE_DEAD_THRESHOLD
    uint256 constant MAJORITY_SHARES = 20_000 * BAZAAR_SCALE;
    uint256 constant STORED_PRICE = 50_000 * BAZAAR_SCALE;
    uint256 constant REOPEN_PRICE_USD = 44_000;

    event TerminationProposalAccepted(address indexed pair, bytes32 indexed assertionId, uint256 lastTradingTs);
    event SettlementPriceFixed(address indexed pair, uint256 settlementPrice);

    BazaarFactory factory;
    BazaarPair pair;
    BazaarPairTerminator terminator;
    MockUSDC usdc;
    MockPyth mockPyth;

    address deployer = makeAddr("deployer");
    address insurer = makeAddr("insurer"); // files the insurer proposal from a small mature stake
    address majority = makeAddr("majority"); // holds the voting majority of mature shares
    address umaProposer = makeAddr("umaProposer");
    bytes32 insurerId; // the insurer's latest bare proposal

    /// @dev Refunds of unspent Pyth fees land here.
    receive() external payable {}

    function setUp() public {
        vm.etch(address(0x64), address(new MockArbSys()).code);
        DeployBazaar dep = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = dep.deploy(makeAddr("bugBounty"));
        (, address usdcAddr,,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcAddr);
        terminator = factory.pairTerminator();
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
    }

    // -------------------- Helpers --------------------

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
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

    function _proposeUma(uint256 lastTradingTs) internal returns (bytes32 aid) {
        uint256 bond = terminator.requiredTerminationBond();
        usdc.mint(umaProposer, bond);
        vm.startPrank(umaProposer);
        usdc.approve(address(terminator), bond);
        aid = terminator.proposeTermination(address(pair), 3, lastTradingTs, "special dividend");
        vm.stopPrank();
    }

    /// @dev Settles a UMA proposal filed now, once its liveness has passed; it resolves TRUE.
    function _acceptUmaAfterLiveness(bytes32 aid) internal {
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(aid);
    }

    /// @dev The insurer files a proposal for `cutoffTs`. Returns its USDC balance before the bond.
    function _proposeInsurer(uint64 cutoffTs) internal returns (uint256 balanceBeforeBond) {
        usdc.mint(insurer, INSURER_BOND_USDC);
        balanceBeforeBond = usdc.balanceOf(insurer);
        vm.startPrank(insurer);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        insurerId = terminator.proposeInsurerTermination(address(pair), cutoffTs);
        vm.stopPrank();
        assertEq(usdc.balanceOf(insurer), balanceBeforeBond - INSURER_BOND_USDC, "bond posted");
    }

    function _voteMajority() internal {
        vm.prank(majority);
        terminator.voteForInsurerTermination(address(pair), insurerId, MAJORITY_SHARES);
    }

    /// @dev The majority votes the insurer's proposal through and anyone executes it.
    function _voteAndExecute() internal {
        _voteMajority();
        terminator.executeInsurerTermination(address(pair), insurerId);
    }

    function _settle(bytes[] memory pu) internal {
        uint256 fee = pu.length == 0 ? 0 : factory.oracle().getSampleSetFee(BTC_USD_FEED_ID, pu);
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
    }

    /// @dev A chain of $`priceUsd` prints, the first published at `firstPublish` after a print at `firstPrev`.
    function _chain(uint256 priceUsd, uint64 firstPublish, uint64 firstPrev) internal view returns (bytes[] memory) {
        return PythChain.flat(mockPyth, BTC_USD_FEED_ID, priceUsd, firstPublish, firstPrev);
    }

    function _noSamples() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BazaarOracle.BazaarOracle__SampleCountMismatch.selector, 0, 5);
    }

    function _settlementPrice() internal view returns (uint256) {
        return pair.auxState().settlementPrice;
    }

    /// @dev Nothing printed between the cutoffs. Up to UMA's cutoff plus the grace, the chain of
    ///      reopen prints and empty data are both refused; past it the reopen chain still cannot
    ///      settle the pair, and the stored price does.
    function _assertSettlesAtStoredPrice(uint64 tIns, uint64 tUma) internal {
        bytes[] memory reopen = _chain(REOPEN_PRICE_USD, tUma + 10 hours, tIns - 1 hours);
        uint256 fee = factory.oracle().getSampleSetFee(BTC_USD_FEED_ID, reopen);

        vm.warp(PythChain.lastPublish(tUma + 10 hours) + 1);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        terminator.terminateScheduledPair{value: fee}(address(pair), reopen);
        vm.expectRevert(_noSamples());
        terminator.terminateScheduledPair(address(pair), new bytes[](0));

        vm.warp(tUma + GRACE);
        vm.expectRevert(_noSamples());
        terminator.terminateScheduledPair(address(pair), new bytes[](0));
        assertEq(pair.settlementPriceFixedTs(), 0, "nothing fixed inside the grace");

        vm.warp(tUma + GRACE + 1);
        vm.expectEmit(true, false, false, true, address(terminator));
        emit SettlementPriceFixed(address(pair), STORED_PRICE);
        terminator.terminateScheduledPair{value: fee}(address(pair), reopen);
        assertEq(_settlementPrice(), STORED_PRICE, "settled at the stored pre-event price");
    }

    // -------------------- The two orders --------------------

    /// @notice A vote pulls an accepted UMA schedule into the closed session ahead of the event.
    ///         Trading halts at the insurer cutoff, the proposer's bond comes back, and the pair
    ///         settles at the stored price, never at the reopen print after UMA's cutoff.
    function test_VotePullsInAcceptedUmaSchedule_SettlesNoLaterThanUmaCutoff() public {
        uint64 tUma = _now() + 2 days;
        bytes32 aid = _proposeUma(tUma);
        _acceptUmaAfterLiveness(aid);
        assertEq(pair.scheduledTerminationTs(), tUma, "UMA scheduled the pair");
        assertEq(terminator.umaCutoffCap(address(pair)), 0, "no insurer schedule to cap yet");

        uint64 tIns = _now() + 1 days;
        uint256 balanceBeforeBond = _proposeInsurer(tIns);
        _voteAndExecute();
        assertEq(pair.scheduledTerminationTs(), tIns, "the vote pulled the cutoff in");
        assertTrue(terminator.insurerScheduled(address(pair)), "insurer-scheduled");
        assertEq(terminator.umaCutoffCap(address(pair)), tUma, "capped at the UMA cutoff it pulled in");
        assertEq(usdc.balanceOf(insurer), balanceBeforeBond, "the proposer's bond came back");

        _assertSettlesAtStoredPrice(tIns, tUma);
    }

    /// @notice A coalition votes its cutoff in while the UMA proposal is still in liveness. UMA's
    ///         later acceptance leaves the insurer cutoff in place but caps its settlement print,
    ///         so the pair settles exactly as in the other order.
    function test_UmaAcceptedAfterInsurerSchedule_CapsIt() public {
        uint64 tUma = _now() + 2 days;
        bytes32 aid = _proposeUma(tUma);

        uint64 tIns = _now() + 1 days;
        uint256 balanceBeforeBond = _proposeInsurer(tIns);
        _voteAndExecute();
        assertEq(pair.scheduledTerminationTs(), tIns, "insurer-scheduled first");
        assertEq(usdc.balanceOf(insurer), balanceBeforeBond, "the proposer's bond came back");

        vm.expectEmit(true, true, false, true, address(terminator));
        emit TerminationProposalAccepted(address(pair), aid, tUma);
        _acceptUmaAfterLiveness(aid);
        assertEq(pair.scheduledTerminationTs(), tIns, "the earlier insurer cutoff stands");
        assertTrue(terminator.insurerScheduled(address(pair)), "still insurer-scheduled");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), aid, "UMA acceptance recorded");
        assertEq(terminator.umaCutoffCap(address(pair)), tUma, "UMA's cutoff caps the settlement print");

        _assertSettlesAtStoredPrice(tIns, tUma);
    }

    // -------------------- What the cap still admits --------------------

    /// @notice A chain between the two cutoffs, its first sample the first print after the halt,
    ///         settles the pair as on any insurer schedule.
    function test_ChainBetweenTheCutoffsSettles() public {
        uint64 tUma = _now() + 2 days;
        bytes32 aid = _proposeUma(tUma);
        uint64 tIns = _now() + 1 days;
        _proposeInsurer(tIns);
        _voteAndExecute();
        _acceptUmaAfterLiveness(aid);

        vm.warp(tIns + 2 hours);
        _settle(_chain(49_000, tIns + 30 minutes, tIns - 1));
        assertEq(_settlementPrice(), 49_000 * BAZAAR_SCALE, "settled at the chain after the halt");
    }

    /// @notice The cap is inclusive and binds every sample: a chain whose last sample is published
    ///         at UMA's cutoff itself settles, and one ending a second later is refused.
    function test_ChainEndingAtTheUmaCutoffSettles() public {
        uint64 tUma = _now() + 2 days;
        bytes32 aid = _proposeUma(tUma);
        _acceptUmaAfterLiveness(aid);
        uint64 tIns = _now() + 1 days;
        _proposeInsurer(tIns);
        _voteAndExecute();

        uint64 firstSample = tUma - 4 * PythChain.SPACING;
        bytes[] memory late = _chain(48_000, firstSample + 1, tIns - 1);
        uint256 fee = factory.oracle().getSampleSetFee(BTC_USD_FEED_ID, late);
        vm.warp(tUma + 2);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        terminator.terminateScheduledPair{value: fee}(address(pair), late);

        _settle(_chain(48_000, firstSample, tIns - 1));
        assertEq(_settlementPrice(), 48_000 * BAZAAR_SCALE, "settled at a chain ending at the cap");
    }

    /// @notice A cap recorded after the insurer cutoff has passed bounds the chain at the cutoff
    ///         UMA verified: prints published before it still settle the pair.
    function test_CapRecordedInLimbo_KeepsAPrintAlreadyPublished() public {
        uint64 tIns = _now() + 1 days;
        _proposeInsurer(tIns);
        _voteAndExecute();

        vm.warp(tIns + 1 hours);
        uint64 tUma = _now() + 13 hours;
        bytes32 aid = _proposeUma(tUma);
        _acceptUmaAfterLiveness(aid);
        assertEq(terminator.umaCutoffCap(address(pair)), tUma, "capped while already in limbo");

        _settle(_chain(49_000, tIns + 10 minutes, tIns - 1));
        assertEq(_settlementPrice(), 49_000 * BAZAAR_SCALE, "prints published before the cap still settle");
    }

    /// @notice A UMA acceptance arriving after the insurer schedule has already fixed its price
    ///         takes no effect and records nothing.
    function test_UmaAcceptedAfterSettlement_RecordsNothing() public {
        uint64 tIns = _now() + 1 days;
        _proposeInsurer(tIns);
        _voteAndExecute();

        vm.warp(tIns - 4 hours);
        bytes32 aid = _proposeUma(_now() + 2 days);

        vm.warp(tIns + 1 hours);
        _settle(_chain(49_000, tIns + 10 minutes, tIns - 1));
        assertGt(pair.settlementPriceFixedTs(), 0, "fixture: settled at the insurer cutoff");

        vm.warp(tIns - 4 hours + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(aid);
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), bytes32(0), "acceptance took no effect");
        assertEq(terminator.umaCutoffCap(address(pair)), 0, "no cap recorded");
        assertEq(_settlementPrice(), 49_000 * BAZAAR_SCALE, "the fixed price stands");
    }

    /// @notice A claim settled after its own cutoff caps the chain at that cutoff, not at the
    ///         moment it was settled: the chain's later samples, published past the verified
    ///         cutoff, never count, however late the claim is settled. The pair then settles at
    ///         its stored price a grace after the verified cutoff.
    function test_LateAcceptanceCapsAtTheVerifiedCutoff() public {
        uint64 tIns = _now() + 1 days;
        uint64 tUma = tIns + 20 minutes; // the verified event lands inside the chain's span
        bytes32 aid = _proposeUma(tUma);
        _proposeInsurer(tIns);
        _voteAndExecute();

        // Nobody settles the claim until every sample of the chain has been published.
        vm.warp(PythChain.lastPublish(tIns) + 1);
        terminator.settleTerminationProposal(aid);
        assertEq(terminator.umaCutoffCap(address(pair)), tUma, "capped at the verified cutoff, not at the settle");

        bytes[] memory samples = _chain(49_000, tIns, tIns - 1);
        uint256 fee = factory.oracle().getSampleSetFee(BTC_USD_FEED_ID, samples);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        terminator.terminateScheduledPair{value: fee}(address(pair), samples);

        vm.warp(tUma + GRACE + 1);
        _settle(samples);
        assertEq(_settlementPrice(), STORED_PRICE, "settled at the stored pre-event price");
    }

    /// @notice A claim whose cutoff precedes the insurer cutoff, resolved only after the pair has
    ///         halted, caps nothing: the pair traded through that event before it stopped, so the
    ///         acceptance is superseded and the chain from the insurer cutoff settles the pair.
    function test_EarlierCutoffResolvedAfterTheHalt_CapsNothing() public {
        uint64 tIns = _now() + 1 days;
        bytes32 aid = _proposeUma(tIns - 1 hours);
        _proposeInsurer(tIns);
        _voteAndExecute();

        vm.warp(PythChain.lastPublish(tIns) + 1);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.TerminationProposalSuperseded(address(pair), aid);
        terminator.settleTerminationProposal(aid);
        assertEq(terminator.umaCutoffCap(address(pair)), 0, "no cap");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), bytes32(0), "no acceptance in force");

        _settle(_chain(49_000, tIns, tIns - 1));
        assertEq(_settlementPrice(), 49_000 * BAZAAR_SCALE, "the chain from the insurer cutoff settles");
    }

    // -------------------- The last resort --------------------

    /// @notice With UMA's cutoff far out, the stored-price last resort still opens
    ///         ORACLE_DEAD_THRESHOLD after the insurer cutoff, not a grace after UMA's.
    function test_FarUmaCutoff_LastResortStillAtDeadThreshold() public {
        uint64 tUma = _now() + 60 days;
        bytes32 aid = _proposeUma(tUma);
        _acceptUmaAfterLiveness(aid);
        uint64 tIns = _now() + 2 days;
        _proposeInsurer(tIns);
        _voteAndExecute();
        assertEq(terminator.umaCutoffCap(address(pair)), tUma, "capped far out");

        vm.warp(tIns + DEAD_THRESHOLD);
        vm.expectRevert(_noSamples());
        terminator.terminateScheduledPair(address(pair), new bytes[](0));

        vm.warp(tIns + DEAD_THRESHOLD + 1);
        terminator.terminateScheduledPair(address(pair), new bytes[](0));
        assertEq(_settlementPrice(), STORED_PRICE, "the dead-feed last resort opens on time");
    }

    /// @notice A UMA cutoff past the oracle's timestamp range caps nothing and cannot overflow the
    ///         last-resort arithmetic: the pair settles at the chain from the insurer cutoff.
    function test_UnboundedUmaCutoff_CapsNothing() public {
        bytes32 aid = _proposeUma(type(uint256).max);
        _acceptUmaAfterLiveness(aid);
        assertEq(pair.scheduledTerminationTs(), type(uint256).max, "fixture: UMA scheduled at the maximum");
        uint64 tIns = _now() + 1 days;
        _proposeInsurer(tIns);
        _voteAndExecute();
        assertEq(terminator.umaCutoffCap(address(pair)), type(uint256).max, "capped at the maximum");

        vm.warp(PythChain.lastPublish(tIns + 2 days) + 1);
        _settle(_chain(REOPEN_PRICE_USD, tIns + 2 days, tIns - 1 hours));
        assertEq(_settlementPrice(), REOPEN_PRICE_USD * BAZAAR_SCALE, "settled at the chain, uncapped");
    }

    /// @notice settlementRule reports the cap: the chain's samples are bounded by UMA's cutoff, and
    ///         the last resort opens a grace after it, sooner than ORACLE_DEAD_THRESHOLD after the
    ///         insurer cutoff.
    function test_SettlementRule_CappedChain() public {
        uint64 tUma = _now() + 2 days;
        _acceptUmaAfterLiveness(_proposeUma(tUma));
        uint64 tIns = _now() + 1 days;
        _proposeInsurer(tIns);
        _voteAndExecute();

        (uint8 rule, uint256 firstTarget, uint256 latestPublishTs, uint256 lastResortTs,) =
            terminator.settlementRule(address(pair));
        assertEq(rule, terminator.SETTLE_CHAIN(), "the chain rule");
        assertEq(firstTarget, tIns, "chained from the insurer cutoff");
        assertEq(latestPublishTs, tUma, "every sample bounded by UMA's cutoff");
        assertEq(lastResortTs, tUma + GRACE, "the last resort a grace after UMA's cutoff");
    }

    // -------------------- Bonds --------------------

    /// @notice A proposal whose cutoff falls after the cutoff UMA then accepts is preempted when
    ///         executed: its bond comes back in full and the pair keeps UMA's schedule and rule.
    function test_ProposalOvertakenByUmaAcceptance_PreemptedAndRefunded() public {
        uint64 tIns = _now() + 3 days;
        uint256 balanceBeforeBond = _proposeInsurer(tIns);
        _voteMajority();

        uint64 tUma = _now() + 2 days;
        bytes32 aid = _proposeUma(tUma);
        _acceptUmaAfterLiveness(aid);
        assertEq(pair.scheduledTerminationTs(), tUma, "UMA scheduled the pair");

        terminator.executeInsurerTermination(address(pair), insurerId);
        assertEq(pair.scheduledTerminationTs(), tUma, "UMA's earlier cutoff stands");
        assertFalse(terminator.insurerScheduled(address(pair)), "settles under UMA's rule");
        assertEq(terminator.umaCutoffCap(address(pair)), 0, "no insurer schedule to cap");
        assertEq(usdc.balanceOf(insurer), balanceBeforeBond, "preempted: the bond came back");
        (,,,,,,,,,, bool resolved, bool scheduled,,,,) = terminator.insurerProposals(insurerId);
        assertTrue(resolved, "resolved");
        assertFalse(scheduled, "never scheduled the pair");
    }

    /// @notice After a UMA acceptance, a proposal for a cutoff at or after UMA's is refused up
    ///         front and no bond is taken.
    function test_ProposalNotEarlierThanAcceptedUmaCutoff_RefusedWithoutBond() public {
        uint64 tUma = _now() + 2 days;
        bytes32 aid = _proposeUma(tUma);
        _acceptUmaAfterLiveness(aid);

        usdc.mint(insurer, INSURER_BOND_USDC);
        uint256 balanceBefore = usdc.balanceOf(insurer);
        vm.startPrank(insurer);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__InsurerCutoffNotEarlier.selector, tUma)
        );
        terminator.proposeInsurerTermination(address(pair), tUma);
        vm.stopPrank();
        assertEq(usdc.balanceOf(insurer), balanceBefore, "no bond taken");
    }

    // -------------------- A second UMA acceptance --------------------

    /// @notice A UMA acceptance that beats the cap but not the insurer cutoff tightens the cap: the
    ///         insurer cutoff still halts trading, and the pair settles no later than the new UMA
    ///         cutoff.
    function test_LaterUmaAcceptanceBetweenTheCutoffs_TightensTheCap() public {
        uint64 tUmaFar = _now() + 4 days;
        _acceptUmaAfterLiveness(_proposeUma(tUmaFar));
        uint64 tIns = _now() + 1 days;
        _proposeInsurer(tIns);
        _voteAndExecute();
        assertEq(terminator.umaCutoffCap(address(pair)), tUmaFar, "fixture: the vote met the far UMA cutoff");

        uint64 tUmaNear = _now() + 2 days;
        bytes32 aid = _proposeUma(tUmaNear);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit TerminationProposalAccepted(address(pair), aid, tUmaNear);
        _acceptUmaAfterLiveness(aid);

        assertEq(pair.scheduledTerminationTs(), tIns, "the insurer cutoff still halts trading");
        assertTrue(terminator.insurerScheduled(address(pair)), "still insurer-scheduled");
        assertEq(terminator.umaCutoffCap(address(pair)), tUmaNear, "the cap tightened");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), aid, "the nearer UMA proposal is in force");

        _assertSettlesAtStoredPrice(tIns, tUmaNear);
    }

    /// @notice A UMA acceptance earlier than the insurer cutoff pulls the schedule in, and the pair
    ///         then settles under UMA's rule.
    function test_LaterUmaAcceptanceBeforeTheInsurerCutoff_PullsItIn() public {
        _acceptUmaAfterLiveness(_proposeUma(_now() + 4 days));
        uint64 tIns = _now() + 2 days;
        _proposeInsurer(tIns);
        _voteAndExecute();

        uint64 tUmaNear = _now() + 1 days;
        bytes32 aid = _proposeUma(tUmaNear);
        _acceptUmaAfterLiveness(aid);

        assertEq(pair.scheduledTerminationTs(), tUmaNear, "the UMA cutoff pulled the schedule in");
        assertFalse(terminator.insurerScheduled(address(pair)), "settles under UMA's rule");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), aid, "the nearer UMA proposal is in force");
    }

    /// @notice While an insurer schedule holds the pair, the UMA cutoff in force is the cap: a UMA
    ///         proposal at or after it is refused up front and no bond is taken.
    function test_UmaProposalNotEarlierThanTheCap_RefusedWithoutBond() public {
        uint64 tUma = _now() + 4 days;
        _acceptUmaAfterLiveness(_proposeUma(tUma));
        _proposeInsurer(_now() + 1 days);
        _voteAndExecute();

        uint256 bond = terminator.requiredTerminationBond();
        usdc.mint(umaProposer, bond);
        uint256 balanceBefore = usdc.balanceOf(umaProposer);
        vm.startPrank(umaProposer);
        usdc.approve(address(terminator), bond);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__CutoffNotEarlier.selector, uint256(tUma), uint256(tUma)
            )
        );
        terminator.proposeTermination(address(pair), 3, tUma, "special dividend");
        vm.stopPrank();
        assertEq(usdc.balanceOf(umaProposer), balanceBefore, "no bond taken");
    }

    /// @notice The cap only tightens: a UMA proposal filed while the cap was looser, whose cutoff
    ///         falls between the new cap and the old one, changes nothing when it resolves.
    function test_PendingUmaProposalAboveATightenedCap_Superseded() public {
        _acceptUmaAfterLiveness(_proposeUma(_now() + 4 days));
        uint64 tIns = _now() + 1 days;
        _proposeInsurer(tIns);
        _voteAndExecute();

        uint64 tNear = _now() + 2 days;
        bytes32 near = _proposeUma(tNear);
        bytes32 mid = _proposeUma(_now() + 3 days);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(near);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.TerminationProposalSuperseded(address(pair), mid);
        terminator.settleTerminationProposal(mid);

        assertEq(terminator.umaCutoffCap(address(pair)), tNear, "the cap stays at the tightest UMA cutoff");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), near, "the tighter acceptance stands");
        assertEq(pair.scheduledTerminationTs(), tIns, "the insurer cutoff still halts trading");
    }

    /// @notice An acceptance that only capped an insurer schedule never scheduled the pair, so the
    ///         later UMA acceptance that pulls the schedule in is the first to schedule it and earns
    ///         the listing bounty; the cap is cleared, since the pair now settles under UMA's rule.
    function test_CapOnlyAcceptanceThenPullIn_ThePullInEarnsTheBounty() public {
        uint64 tIns = _now() + 2 days;
        _proposeInsurer(tIns);
        _voteAndExecute();
        _acceptUmaAfterLiveness(_proposeUma(_now() + 3 days));
        (uint256 capOnlyBounty,) = factory.lens().claimableFees(address(pair), umaProposer);
        assertEq(capOnlyBounty, 0, "the capping acceptance earns nothing");

        address puller = makeAddr("puller");
        uint256 bond = terminator.requiredTerminationBond();
        usdc.mint(puller, bond);
        vm.startPrank(puller);
        usdc.approve(address(terminator), bond);
        uint64 tNear = _now() + 1 days;
        bytes32 aid = terminator.proposeTermination(address(pair), 3, tNear, "special dividend");
        vm.stopPrank();
        _acceptUmaAfterLiveness(aid);

        assertEq(pair.scheduledTerminationTs(), tNear, "pulled in");
        assertFalse(terminator.insurerScheduled(address(pair)), "settles under UMA's rule");
        assertEq(terminator.umaCutoffCap(address(pair)), 0, "the cap is cleared");
        (uint256 pullInBounty,) = factory.lens().claimableFees(address(pair), puller);
        assertGt(pullInBounty, 0, "the first acceptance to schedule the pair earns the bounty");
    }

    /// @notice After a UMA pull-in, a fresh insurer vote that pulls the schedule earlier again
    ///         records the UMA cutoff now in force as its cap.
    function test_VoteAfterAPullIn_CapsAtTheUmaCutoffInForce() public {
        _acceptUmaAfterLiveness(_proposeUma(_now() + 4 days));
        _proposeInsurer(_now() + 2 days);
        _voteAndExecute();
        uint64 tUma = _now() + 1 days;
        _acceptUmaAfterLiveness(_proposeUma(tUma));
        assertEq(pair.scheduledTerminationTs(), tUma, "fixture: the UMA cutoff pulled the schedule in");

        // A second insurer proposal, from the majority holder.
        uint64 tIns2 = _now() + 3 hours;
        usdc.mint(majority, INSURER_BOND_USDC);
        vm.startPrank(majority);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        bytes32 second = terminator.proposeInsurerTermination(address(pair), tIns2);
        terminator.voteForInsurerTermination(address(pair), second, MAJORITY_SHARES);
        vm.stopPrank();
        terminator.executeInsurerTermination(address(pair), second);

        assertEq(pair.scheduledTerminationTs(), tIns2, "the vote pulled the schedule in again");
        assertTrue(terminator.insurerScheduled(address(pair)), "insurer-scheduled again");
        assertEq(terminator.umaCutoffCap(address(pair)), tUma, "capped at the UMA cutoff in force");
    }
}
