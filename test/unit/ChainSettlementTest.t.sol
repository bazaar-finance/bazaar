// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
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

/// @notice The chain rule a bare insurer vote settles under: the median of five prints, the first
///         published at or after the cutoff and each later one the first published at least ten
///         minutes after the one before. Every sample is pinned by Pyth's first-print proof against
///         a target the contract computes, so the set is fixed by the feed's history: other prints,
///         another order, or a short set are refused, a close-timed cutoff settles on prints from
///         the reopen, and a feed that dies before five prints settles at the stored price only
///         once the last resort opens.
contract ChainSettlementTest is Test {
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant INSURER_BOND_USDC = 1_000 * 1e6; // mirror of INSURER_TERMINATION_BOND_USDC
    uint256 constant MAJORITY_SHARES = 20_000 * BAZAAR_SCALE;
    uint256 constant STORED_PRICE = 50_000 * BAZAAR_SCALE;
    uint256 constant DEAD_THRESHOLD = 21 days; // mirror of ORACLE_DEAD_THRESHOLD
    uint64 constant SPACING = 10 minutes; // mirror of SETTLEMENT_SAMPLE_SPACING
    bytes32 constant MOCK_PYTH_FEE_SLOT = bytes32(uint256(1)); // MockPyth.singleUpdateFeeInWei

    BazaarFactory factory;
    BazaarPair pair;
    BazaarPairTerminator terminator;
    MockUSDC usdc;
    MockPyth mockPyth;

    address deployer = makeAddr("deployer");
    address insurer = makeAddr("insurer"); // files the bare proposal from a small mature stake
    address majority = makeAddr("majority"); // holds the voting majority of mature shares

    bytes32 voteId;
    uint64 cutoffTs;

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

        // The pair's stored price: the last print before the cutoff.
        bytes[] memory pu = new bytes[](1);
        pu[0] = _tick(50_000, _now(), _now() - 1);
        pair.refreshPrice{value: factory.oracle().getUpdateFee(pu)}(pu);
        (uint256 stored,,,,) = pair.lastPairPrice();
        assertEq(stored, STORED_PRICE, "fixture: the stored price");

        // A bare vote schedules the pair a day out: the chain rule applies.
        cutoffTs = _now() + 1 days;
        usdc.mint(insurer, INSURER_BOND_USDC);
        vm.startPrank(insurer);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        voteId = terminator.proposeInsurerTermination(address(pair), cutoffTs);
        vm.stopPrank();
        vm.prank(majority);
        terminator.voteForInsurerTermination(address(pair), voteId, MAJORITY_SHARES);
        terminator.executeInsurerTermination(address(pair), voteId);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "fixture: the vote scheduled the pair");
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

    function _tick(uint256 priceUsd, uint64 publishTime, uint64 prevPublishTime) internal view returns (bytes memory) {
        return PythChain.tick(mockPyth, BTC_USD_FEED_ID, priceUsd, publishTime, prevPublishTime);
    }

    function _setFee(bytes[] memory pu) internal view returns (uint256) {
        return factory.oracle().getSampleSetFee(BTC_USD_FEED_ID, pu);
    }

    function _settle(bytes[] memory pu) internal {
        uint256 fee = _setFee(pu);
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
    }

    /// @dev The fee is read before the cheatcode: expectRevert applies to the next external call.
    function _expectSettleRevert(bytes[] memory pu, bytes memory revertData) internal {
        uint256 fee = _setFee(pu);
        vm.expectRevert(revertData);
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
    }

    function _settlementPrice() internal view returns (uint256) {
        return pair.auxState().settlementPrice;
    }

    function _countMismatch(uint256 updates) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(BazaarOracle.BazaarOracle__SampleCountMismatch.selector, updates, 5);
    }

    // -------------------- The median --------------------

    /// @notice The pair settles at the median of the five chained prints: neither the first nor
    ///         the last, and not their order of publication.
    function test_SettlesAtTheMedianOfFiveChainedPrints() public {
        bytes[] memory pu = PythChain.chain(
            mockPyth, BTC_USD_FEED_ID, [uint256(50_000), 53_000, 47_000, 52_000, 61_000], cutoffTs, cutoffTs - 1
        );
        vm.warp(PythChain.lastPublish(cutoffTs) + 1);
        _settle(pu);
        assertEq(_settlementPrice(), 52_000 * BAZAAR_SCALE, "the median of the five samples");
    }

    /// @notice A single print far off the others moves nothing: one sample cannot be the median.
    function test_OneOutlierSampleMovesNothing() public {
        bytes[] memory pu = PythChain.chain(
            mockPyth, BTC_USD_FEED_ID, [uint256(5_000), 50_000, 50_100, 49_900, 50_000], cutoffTs, cutoffTs - 1
        );
        vm.warp(PythChain.lastPublish(cutoffTs) + 1);
        _settle(pu);
        assertEq(_settlementPrice(), 50_000 * BAZAAR_SCALE, "a 90% print at the cutoff is outvoted");
    }

    // -------------------- The proof --------------------

    /// @notice A sample that is not the first print after its own target is refused: here the
    ///         third sample's predecessor was published at its target.
    function test_SampleNotFirstAfterItsTargetRefused() public {
        bytes[] memory pu = PythChain.flat(mockPyth, BTC_USD_FEED_ID, 50_000, cutoffTs, cutoffTs - 1);
        uint64 target3 = cutoffTs + 2 * SPACING;
        pu[2] = _tick(50_000, target3, target3);
        vm.warp(PythChain.lastPublish(cutoffTs) + 1);
        _expectSettleRevert(pu, abi.encodeWithSelector(PythErrors.PriceFeedNotFoundWithinRange.selector));
    }

    /// @notice A sample published before its target, less than the spacing after the sample
    ///         before, is refused.
    function test_SampleBeforeItsTargetRefused() public {
        bytes[] memory pu = PythChain.flat(mockPyth, BTC_USD_FEED_ID, 50_000, cutoffTs, cutoffTs - 1);
        pu[1] = _tick(50_000, cutoffTs + SPACING - 60, cutoffTs + SPACING - 61);
        vm.warp(PythChain.lastPublish(cutoffTs) + 1);
        _expectSettleRevert(pu, abi.encodeWithSelector(PythErrors.PriceFeedNotFoundWithinRange.selector));
    }

    /// @notice The samples must come in the order the chain defines: swapping two valid samples is
    ///         refused, so the submitter cannot reorder them either.
    function test_SamplesOutOfOrderRefused() public {
        bytes[] memory pu = PythChain.flat(mockPyth, BTC_USD_FEED_ID, 50_000, cutoffTs, cutoffTs - 1);
        (pu[1], pu[2]) = (pu[2], pu[1]);
        vm.warp(PythChain.lastPublish(cutoffTs) + 1);
        _expectSettleRevert(pu, abi.encodeWithSelector(PythErrors.PriceFeedNotFoundWithinRange.selector));
    }

    /// @notice The set holds exactly five samples: a short set, a long one and no data at all are
    ///         refused before the last resort opens.
    function test_ShortOrLongSetsRefused() public {
        bytes[] memory full = PythChain.flat(mockPyth, BTC_USD_FEED_ID, 50_000, cutoffTs, cutoffTs - 1);
        bytes[] memory shortSet = new bytes[](4);
        bytes[] memory longSet = new bytes[](6);
        for (uint256 k = 0; k < 4; k++) {
            shortSet[k] = full[k];
        }
        for (uint256 k = 0; k < 5; k++) {
            longSet[k] = full[k];
        }
        uint64 sixth = PythChain.lastPublish(cutoffTs) + SPACING;
        longSet[5] = _tick(50_000, sixth, sixth - 1);
        vm.warp(sixth + 1);

        _expectSettleRevert(shortSet, _countMismatch(4));
        _expectSettleRevert(longSet, _countMismatch(6));
        _expectSettleRevert(new bytes[](0), _countMismatch(0));
        assertEq(pair.settlementPriceFixedTs(), 0, "nothing fixed by a refused set");
    }

    // -------------------- Quiet feeds --------------------

    /// @notice A cutoff at a session's close: the close is printed at the cutoff and the feed is
    ///         silent until Monday's open. The second sample is the open, and the next three follow
    ///         it at ten-minute steps, so the median is a print from the reopened session rather
    ///         than the close or the opening print alone. Repeating the opening print in the later
    ///         slots, which a set measured from the cutoff alone would accept, is refused.
    function test_CloseTimedCutoff_SettlesOnTheReopen() public {
        uint64 reopen = cutoffTs + 65 hours + 30 minutes;
        bytes[] memory pu = new bytes[](5);
        pu[0] = _tick(50_000, cutoffTs, cutoffTs - 1); // the close
        pu[1] = _tick(44_000, reopen, cutoffTs); // the feed's next print: the open
        pu[2] = _tick(44_500, reopen + SPACING, reopen + SPACING - 1);
        pu[3] = _tick(45_000, reopen + 2 * SPACING, reopen + 2 * SPACING - 1);
        pu[4] = _tick(45_500, reopen + 3 * SPACING, reopen + 3 * SPACING - 1);
        vm.warp(reopen + 3 * SPACING + 1);

        bytes[] memory collapsed = new bytes[](5);
        collapsed[0] = pu[0];
        for (uint256 k = 1; k < 5; k++) {
            collapsed[k] = pu[1];
        }
        _expectSettleRevert(collapsed, abi.encodeWithSelector(PythErrors.PriceFeedNotFoundWithinRange.selector));

        _settle(pu);
        assertEq(_settlementPrice(), 45_000 * BAZAAR_SCALE, "a print from the reopened session");
    }

    /// @notice A feed that prints twice after the cutoff and then dies never yields a full chain:
    ///         nothing settles the pair until the last resort opens, ORACLE_DEAD_THRESHOLD after the
    ///         cutoff, and from then on the short set, or no data at all, settles it at the stored
    ///         price.
    function test_FeedDiesMidChain_StoredPriceAtTheLastResort() public {
        bytes[] memory twoPrints = new bytes[](2);
        twoPrints[0] = _tick(48_000, cutoffTs + 5, cutoffTs - 1);
        twoPrints[1] = _tick(47_000, cutoffTs + 5 + SPACING, cutoffTs + 4 + SPACING);

        vm.warp(cutoffTs + DEAD_THRESHOLD);
        _expectSettleRevert(twoPrints, _countMismatch(2));
        _expectSettleRevert(new bytes[](0), _countMismatch(0));

        vm.warp(cutoffTs + DEAD_THRESHOLD + 1);
        uint256 fee = _setFee(twoPrints);
        vm.expectEmit(true, false, false, true, address(terminator));
        emit BazaarPairTerminator.SettlementPriceFixed(address(pair), STORED_PRICE);
        terminator.terminateScheduledPair{value: fee}(address(pair), twoPrints);
        assertEq(_settlementPrice(), STORED_PRICE, "the stored price as the last resort");
    }

    // -------------------- Fees --------------------

    /// @notice Each sample is its own Pyth parse, so the set costs one fee per sample: the
    ///         terminator forwards exactly that, refuses less, and refunds any excess.
    function test_FeePerSample_UnderpaymentRefused_ExcessRefunded() public {
        vm.store(address(mockPyth), MOCK_PYTH_FEE_SLOT, bytes32(uint256(7)));
        bytes[] memory pu = PythChain.flat(mockPyth, BTC_USD_FEED_ID, 50_000, cutoffTs, cutoffTs - 1);
        assertEq(_setFee(pu), 35, "seven wei for each of five samples");
        vm.warp(PythChain.lastPublish(cutoffTs) + 1);

        vm.expectRevert(
            abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__InsufficientPythFee.selector, 34, 35)
        );
        terminator.terminateScheduledPair{value: 34}(address(pair), pu);

        uint256 balanceBefore = address(this).balance;
        terminator.terminateScheduledPair{value: 135}(address(pair), pu);
        assertEq(balanceBefore - address(this).balance, 35, "only the fee was kept");
        assertEq(_settlementPrice(), 50_000 * BAZAAR_SCALE, "settled");
    }

    // -------------------- What keepers read --------------------

    /// @notice settlementRule names the chain for a bare vote: the first target is the cutoff, no
    ///         UMA cutoff bounds the samples, and the last resort opens ORACLE_DEAD_THRESHOLD
    ///         later. Once the price is fixed there is nothing left to settle.
    function test_SettlementRule_BareVoteIsTheChain() public {
        (uint8 rule, uint256 firstTarget, uint256 latestPublishTs, uint256 lastResortTs, uint256 verdictDeadline) =
            terminator.settlementRule(address(pair));
        assertEq(rule, terminator.SETTLE_CHAIN(), "the chain rule");
        assertEq(firstTarget, cutoffTs, "chained from the cutoff");
        assertEq(latestPublishTs, type(uint64).max, "no UMA cutoff bounds the samples");
        assertEq(lastResortTs, cutoffTs + DEAD_THRESHOLD, "the last resort");
        assertEq(verdictDeadline, 0, "no verdict to wait for");

        vm.warp(PythChain.lastPublish(cutoffTs) + 1);
        _settle(PythChain.flat(mockPyth, BTC_USD_FEED_ID, 50_000, cutoffTs, cutoffTs - 1));
        (rule,,,,) = terminator.settlementRule(address(pair));
        assertEq(rule, terminator.SETTLE_NOTHING(), "the price is fixed");
    }
}
