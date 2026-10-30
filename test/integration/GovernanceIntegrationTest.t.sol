// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";
import {PythChain} from "../PythChain.sol";

/// @title GovernanceIntegrationTest
/// @notice End-to-end UMA governance flows: scheduled pair termination through the real Terminator
///         + OptimisticOracle assertion lifecycle, post-termination user settlement, the
///         oracle-upgrade proposal, and composite-pair deployment/pricing/termination-claim.
contract GovernanceIntegrationTest is IntegrationBase {
    BazaarPairTerminator internal terminator;
    MockOptimisticOracleV3 internal mockOO;

    function setUp() public override {
        super.setUp();
        terminator = factory.pairTerminator();
        mockOO = MockOptimisticOracleV3(address(factory.oo()));
    }

    /// @dev Refresh the pair's stored price at the current timestamp, paying the Pyth fee.
    function _warmPrice(BazaarPair p, bytes[] memory pu) internal {
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(address(this), fee);
        p.refreshPrice{value: fee}(pu);
    }

    /// @dev Fund `proposer` for a termination proposal's $1000 bond.
    ///      The bond is read into a local BEFORE the prank — the external getter call would consume it.
    function _bondProposer(address proposer) internal {
        uint256 bond = terminator.TERMINATION_PROPOSAL_BOND();
        usdc.mint(proposer, bond);
        vm.prank(proposer);
        usdc.approve(address(terminator), bond);
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) return false;
        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) matched = false;
                break;
            }
            if (matched) return true;
        }
        return false;
    }

    // ============================ scheduled termination ============================

    /// @notice Full scheduled-termination chain: propose via UMA → liveness passes → settle (schedules,
    ///         does NOT yet terminate) → trading window ends → anyone executes → pair terminated at the
    ///         stored price.
    function test_e2e_ScheduledTermination_ProposeSettleExecute() public {
        _warmPrice(pair, _freshPrice()); // stored price for the after-grace fallback

        uint256 lastTradingTs = vm.getBlockTimestamp() + 7 days;
        _bondProposer(alice);
        vm.prank(alice);
        bytes32 aid = terminator.proposeTermination(address(pair), 3, lastTradingTs, "Reverse split announced.");

        // Settle truthfully after the 12h liveness: schedules the cutoff, pair keeps trading.
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(aid);
        assertEq(pair.scheduledTerminationTs(), lastTradingTs, "termination scheduled");
        assertFalse(pair.isPairTerminated(), "scheduling is not termination");

        // Past the cutoff + the precise-tick grace, anyone fixes the price using the stored-price
        // fallback, then finalizes at once: no position is open.
        vm.warp(lastTradingTs + 12 hours + 1);
        terminator.terminateScheduledPair(address(pair), new bytes[](0));
        assertFalse(pair.isPairTerminated(), "price fixed, settlement window still open");
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminated(), "pair terminated after the trading window");
    }

    // ============================ settlement at the verified tick ============================

    /// @notice Scheduled termination settling at the verified tick: once the cutoff has passed,
    ///         anyone posts the archived Pyth update from that moment and the pair settles at the
    ///         price verified on-chain from it. Users with open positions can then withdraw their
    ///         settled collateral.
    function test_e2e_ScheduledTermination_UsersSettleAtVerifiedPrice() public {
        // Open a matched 0.1 BTC long/short at $50k so both sides hold positions at termination:
        // alice's $50k bid rests, bob's crossing short fills at her maker price.
        uint256 size = BAZAAR_SCALE / 10;
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), size, "0.1 BTC opened at $50k");

        // A delisting is announced for a day out; the feed's last print at the cutoff is $50k.
        uint64 lastTradingTs = uint64(vm.getBlockTimestamp() + 1 days);
        _bondProposer(carol);
        vm.prank(carol);
        bytes32 aid = terminator.proposeTermination(address(pair), 2, lastTradingTs, "Delisting announced.");

        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(aid);

        // Acceptance schedules the cutoff — it does NOT settle a price by itself.
        assertFalse(pair.isPairTerminated(), "acceptance alone does not terminate");
        assertEq(pair.scheduledTerminationTs(), lastTradingTs, "cutoff scheduled");

        // Past the cutoff, anyone fixes the price with the archived Pyth update from that moment —
        // the feed's first print in the 3 s window ending at the cutoff, its predecessor published
        // before the window opened. The price is verified on-chain against that payload, not read
        // from the proposal.
        vm.warp(uint256(lastTradingTs) + 1);
        bytes[] memory tick = _priceUpdateFor(BTC_USD_FEED_ID, 50_000, lastTradingTs, lastTradingTs - 4);
        uint256 fee = oracle.getUpdateFee(tick);
        vm.deal(address(this), fee);
        terminator.terminateScheduledPair{value: fee}(address(pair), tick);
        address[] memory both = new address[](2);
        both[0] = alice;
        both[1] = bob;
        assertEq(pair.liquidate(both, new bytes[](0)), 2, "both positions settled at the fixed price");
        pair.finalizeTermination();

        assertTrue(pair.isPairTerminated(), "pair terminated at the verified tick");
        BazaarTypes.AuxState memory aux = pair.auxState();
        assertEq(aux.settlementPrice, 50_000 * BAZAAR_SCALE, "termination price normalized to 1e18");

        // Both traders settle at $50k (entry price → no PnL) and withdraw collateral.
        uint256 amount = 10_000 * BAZAAR_SCALE;
        uint256 aliceBal = usdc.balanceOf(alice);
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        pair.withdrawCollateral(amount, pu, 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice), aliceBal + 10_000 * USDC_SCALE, "alice withdrew settled collateral");

        uint256 bobBal = usdc.balanceOf(bob);
        pu = _freshPrice();
        vm.prank(bob);
        pair.withdrawCollateral(amount, pu, 0, 0, 0, "");
        assertEq(usdc.balanceOf(bob), bobBal + 10_000 * USDC_SCALE, "bob withdrew settled collateral");
    }

    // ============================ identifier upgrade ============================

    /// @notice Identifier-upgrade governance: propose a new UMA identifier (whitelist-validated),
    ///         wait out the liveness window, settle (queues the swap), wait out the 12-day
    ///         activation timelock — the users' exit window — then anyone activates and the
    ///         protocol asserts under the new identifier. The oracle address never moves — it is
    ///         immutable; the identifier is the axis UMA actually changes.
    function test_e2e_IdentifierUpgrade_SwapsGovernanceIdentifier() public {
        address oldOo = address(factory.oo());
        bytes32 oldIdentifier = factory.umaIdentifier();

        usdc.mint(alice, factory.IDENTIFIER_UPGRADE_BOND_USDC());
        vm.startPrank(alice);
        usdc.approve(address(factory), factory.IDENTIFIER_UPGRADE_BOND_USDC());
        bytes32 aid = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH5");
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + factory.IDENTIFIER_UPGRADE_LIVENESS() + 1);
        factory.settleIdentifierUpgradeProposal(aid);

        // Approval queues; the incoming identifier governs nothing during the exit window.
        assertEq(factory.umaIdentifier(), oldIdentifier, "swap deferred by the activation timelock");
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), bytes32(0), "no pending upgrade");
        (,,, bool resolved, bool settlementResolution,) = factory.identifierUpgradeProposals(aid);
        assertTrue(resolved, "proposal resolved");
        assertTrue(settlementResolution, "proposal accepted");

        // After the timelock, anyone finalizes the swap.
        vm.warp(vm.getBlockTimestamp() + factory.IDENTIFIER_UPGRADE_TIMELOCK() + 1);
        vm.prank(bob);
        factory.activateIdentifierUpgrade();

        assertEq(factory.umaIdentifier(), bytes32("ASSERT_TRUTH5"), "governance identifier swapped");
        assertEq(address(factory.oo()), oldOo, "oracle address immutable");
    }

    /// @notice Fail closed: while the protocol's identifier is off UMA's live whitelist, the
    ///         termination proposal reverts — an assertion made in that state would be
    ///         undisputable and termination assertions pin settlement semantics. The non-UMA
    ///         termination paths (insurer vote, stale price, insolvency) are unaffected.
    function test_e2e_TerminationProposal_FailClosedWhileIdentifierDewhitelisted() public {
        mockOO.setIdentifierSupported(factory.umaIdentifier(), false);

        _bondProposer(alice);
        vm.prank(alice);
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__UmaIdentifierNotLive.selector);
        terminator.proposeTermination(address(pair), 3, vm.getBlockTimestamp() + 7 days, "Reverse split announced.");
    }

    // ============================ disputed termination ============================

    /// @notice A disputed termination assertion that the DVM resolves FALSE leaves the pair untouched:
    ///         no scheduling, no termination — and the disputer collects both bonds.
    function test_e2e_DisputedTermination_ResolvedFalse_PairUnaffected() public {
        _bondProposer(alice);
        vm.prank(alice);
        bytes32 aid = terminator.proposeTermination(address(pair), 2, vm.getBlockTimestamp() + 7 days, "Bogus claim.");

        // Bob disputes with a matching $1000 bond, and the DVM sides with him.
        uint256 bond = terminator.TERMINATION_PROPOSAL_BOND();
        usdc.mint(bob, bond);
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.startPrank(bob);
        usdc.approve(address(mockOO), bond);
        mockOO.disputeAssertion(aid, bob);
        vm.stopPrank();
        mockOO.mockDvmResolve(aid, false);

        terminator.settleTerminationProposal(aid);

        assertEq(pair.scheduledTerminationTs(), 0, "nothing scheduled on a false assertion");
        assertFalse(pair.isPairTerminated(), "pair not terminated");
        assertEq(usdc.balanceOf(bob), bobBefore + bond, "disputer nets the proposer's forfeited bond");
    }

    // ============================ insurer-vote termination ============================

    /// @notice Insurer-vote termination (no UMA): a majority insurer proposes a cutoff, votes 60%+ of
    ///         the share snapshot with mature shares, and executes at once — the pair is scheduled to
    ///         stop trading at the cutoff, settles at the median of the chain of prints from it, and the
    ///         proposer's bond is refunded.
    function test_e2e_InsurerVoteTermination_MajorityExecutes() public {
        // Carol becomes the majority insurer: 10,000 shares vs the 4,000-share deployment seed.
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
        uint256 carolShares = pair.insuranceShares(carol);
        assertEq(carolShares, 10_000 * BAZAAR_SCALE, "carol holds 10k shares");

        // Shares must be mature (held >= 7 days before the proposal) to vote.
        vm.warp(vm.getBlockTimestamp() + 7 days + 1 hours);

        uint256 bond = 1_000 * USDC_SCALE; // INSURER_TERMINATION_BOND_USDC
        uint256 totalAtProposal = pair.totalInsuranceShares(); // carol's 10k + the deployment seed
        usdc.mint(carol, bond);
        vm.startPrank(carol);
        usdc.approve(address(terminator), bond);
        bytes32 id = terminator.proposeInsurerTermination(address(pair), uint64(vm.getBlockTimestamp()) + 1 days);
        vm.stopPrank();
        uint256 carolAfterPropose = usdc.balanceOf(carol);

        // 9,500 votes — above the 60% threshold of the snapshot (carol holds the clear majority).
        assertGe(9_500 * BAZAAR_SCALE, totalAtProposal * 6_000 / 10_000, "vote clears the 60% threshold");
        vm.prank(carol);
        terminator.voteForInsurerTermination(address(pair), id, 9_500 * BAZAAR_SCALE);

        // The threshold schedules the pair at the cutoff at once; a bare vote settles at the median
        // of five prints chained from the cutoff.
        terminator.executeInsurerTermination(address(pair), id);
        (,,,, uint256 cutoffTs,,,,,,,,,,,) = terminator.insurerProposals(id);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "scheduled at the proposal's cutoff");
        bytes[] memory pu = PythChain.flat(mockPyth, BTC_USD_FEED_ID, 50_000, uint64(cutoffTs), uint64(cutoffTs) - 1);
        vm.warp(PythChain.lastPublish(uint64(cutoffTs)) + 10);
        terminator.terminateScheduledPair{value: oracle.getSampleSetFee(BTC_USD_FEED_ID, pu)}(address(pair), pu);
        pair.finalizeTermination();

        assertTrue(pair.isPairTerminated(), "pair terminated by insurer consensus");
        (,,,,,, uint256 yesShares, uint256 snapshot,,, bool resolved, bool scheduled,,,,) =
            terminator.insurerProposals(id);
        assertEq(yesShares, 9_500 * BAZAAR_SCALE, "votes tallied");
        assertEq(snapshot, totalAtProposal, "snapshot froze total shares at proposal");
        assertTrue(resolved && scheduled, "proposal resolved by scheduling");
        assertEq(usdc.balanceOf(carol), carolAfterPropose + bond, "successful consensus refunds the bond");
    }

    // ============================ books-vs-balance shortfall ============================

    /// @notice Vault-health Check 2: when the pair's actual USDC no longer backs its books, the
    ///         next health check fixes the settlement price at the live price; finalize then pays
    ///         principal pro-rata on the cash that is actually there.
    function test_e2e_BooksVsBalanceMismatch_OpensSettlementWindow() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);

        // Simulate the un-fakeable condition: USDC leaves the pair without the books moving.
        vm.prank(address(pair));
        usdc.transfer(makeAddr("thief"), 10_000 * USDC_SCALE);

        // Any liquidation re-runs the vault health check, which now fails Check 2 (books vs balance).
        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, BAZAAR_SCALE / 10, 5_005 * BAZAAR_SCALE);
        vm.prank(bob);
        pair.liquidate(_arr1(dave), _freshPrice());

        assertGt(pair.settlementPriceFixedTs(), 0, "shortfall opened the settlement window");
        assertFalse(pair.isPairTerminated(), "not terminated until finalize");

        // The pair is frozen: no further deposits.
        vm.startPrank(bob);
        usdc.approve(address(pair), 1 * USDC_SCALE);
        vm.expectRevert();
        pair.depositCollateral(1 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.stopPrank();

        // Nothing is left open (dave was liquidated), so finalize runs at once.
        pair.finalizeTermination();
        uint256 ratio = pair.auxState().terminalPrincipalRatio;
        assertGt(ratio, 0, "principal ratio set");
        assertLt(ratio, BAZAAR_SCALE, "ratio reflects the missing USDC");
    }

    // ============================ composite pairs ============================

    /// @notice A 2-feed composite pair deploys (non-continuous), prices off both legs combined
    ///         (3000 JPY / 150 JPY-per-USD = $20), and its termination claim asserts that
    ///         decommissioning of EITHER leg is sufficient grounds.
    function test_e2e_CompositePair_DeployPriceAndTerminationClaim() public {
        bytes32 assetJpyFeed = keccak256("test.EQUITY.7203/JPY");
        bytes32 usdJpyFeed = keccak256("test.FX.USD/JPY");
        bytes32 compositeId = oracle.registerComposite(assetJpyFeed, usdJpyFeed, true); // USD = base/quote

        usdc.mint(deployer, PROPOSAL_TOTAL_USDC);
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 aid = factory.proposePairDeployment(compositeId, false, PROPOSAL_TOTAL, "Toyota on TSE");
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(aid);
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(aid);
        BazaarPair cpair = BazaarPair(payable(factory.getPairAddress(pairId)));
        assertFalse(cpair.isContinuouslyTraded(), "composite pairs are non-continuous");

        // Push both legs, then refresh from the Pyth cache: 3000 JPY / 150 = $20.
        uint64 nowTs = uint64(vm.getBlockTimestamp());
        bytes[] memory u = new bytes[](1);
        u[0] = mockPyth.createPriceFeedUpdateData(assetJpyFeed, 3000e8, 0, PYTH_EXPO, 3000e8, 0, nowTs, nowTs - 1);
        vm.deal(address(this), 1 ether);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(u)}(u);
        u[0] = mockPyth.createPriceFeedUpdateData(usdJpyFeed, 150e8, 0, PYTH_EXPO, 150e8, 0, nowTs, nowTs - 1);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(u)}(u);
        cpair.refreshPrice(new bytes[](0));
        (uint256 spot,,,,) = cpair.lastPairPrice();
        assertEq(spot, 20 * BAZAAR_SCALE, "composite priced at base/quote = $20");

        // The termination claim for a composite spells out the either-leg-decommission grounds.
        _bondProposer(alice);
        vm.prank(alice);
        bytes32 termAid =
            terminator.proposeTermination(address(cpair), 2, vm.getBlockTimestamp() + 7 days, "Delisting announced.");
        bytes memory claim = mockOO.claims(termAid);
        assertTrue(_contains(claim, "decommissioning of EITHER leg"), "claim covers either-leg decommission");
    }
}
