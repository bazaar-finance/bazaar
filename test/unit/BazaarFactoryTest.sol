// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarSequencer} from "../../src/BazaarSequencer.sol";
import {BazaarPairLens} from "../../src/BazaarPairLens.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";

contract BazaarFactoryTest is Test {
    // Pyth ETH/USD feed ID
    bytes32 constant ETH_USD_FEED_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    // Scale constants
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;

    // Amounts (in BAZAAR_SCALE)
    uint256 constant INITIAL_USER_BALANCE = 100_000 * USDC_SCALE;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;

    // Read from factory constants
    uint256 bondUsdc;
    uint256 oracleUpgradeBondUsdc;
    uint64 oracleUpgradeLiveness;
    uint256 minDeploymentAmount;
    uint256 seedUsdc;
    uint256 seedBazaar;

    // Core contracts
    BazaarFactory public factory;

    // Sub-contracts deployed by factory
    BazaarOracle public oracle;
    BazaarSequencer public sequencer;
    BazaarPairLens public lens;
    BazaarPairTerminator public pairTerminator;

    // Mocks (from HelperConfig)
    MockUSDC public usdc;
    MockOptimisticOracleV3 public mockOOv3;

    // Test accounts
    address public user1;
    address public user2;
    address public bugBountyAddress;

    function setUp() public {
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        bugBountyAddress = makeAddr("bugBounty");

        // Deploy using the same script as `make deploy-anvil`
        DeployBazaar deployer = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = deployer.deploy(bugBountyAddress);

        // Read addresses from config
        (, address usdcContract, address optimisticOracleV3,) = helperConfig.activeNetworkConfig();

        usdc = MockUSDC(usdcContract);
        mockOOv3 = MockOptimisticOracleV3(optimisticOracleV3);

        // Store sub-contract references
        oracle = factory.oracle();
        sequencer = factory.sequencer();
        lens = factory.lens();
        pairTerminator = factory.pairTerminator();

        // Derive constants from factory
        bondUsdc = factory.DEPLOYMENT_BOND_USDC();
        oracleUpgradeBondUsdc = factory.ORACLE_UPGRADE_BOND_USDC();
        oracleUpgradeLiveness = factory.ORACLE_UPGRADE_LIVENESS();
        minDeploymentAmount = factory.MIN_DEPLOYMENT_AMOUNT();
        seedUsdc = PROPOSAL_TOTAL_USDC - bondUsdc;
        seedBazaar = PROPOSAL_TOTAL - (bondUsdc * BAZAAR_SCALE / USDC_SCALE);

        // Mint USDC to test accounts
        usdc.mint(user1, INITIAL_USER_BALANCE);
        usdc.mint(user2, INITIAL_USER_BALANCE);
    }

    function testProposePairDeployment() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);

        bytes32 expectedPairId = ETH_USD_FEED_ID;

        vm.expectEmit(true, false, true, true, address(factory));
        // assertionId (topic2) is unknown before the call, so we check topic1 (pairId) and topic3 (deployer) + data
        emit BazaarFactory.PairDeploymentProposed(
            expectedPairId, bytes32(0), user1, ETH_USD_FEED_ID, "ETH/USD", seedBazaar
        );

        bytes32 assertionId = factory.proposePairDeployment(
            ETH_USD_FEED_ID,
            true, // ETH trades 24/7
            PROPOSAL_TOTAL,
            "ETH/USD"
        );
        vm.stopPrank();

        // Verify assertion was created
        assertTrue(assertionId != bytes32(0), "Assertion ID should not be zero");

        // Verify proposal was stored
        (
            address deployer_,
            bytes32 baseFeedId,
            bool isContinuouslyTraded,
            uint256 storedSeedAmount,
            uint256 storedSeedAmountUsdc,
            string memory description,
            bytes32 pairId,, // proposalTs
            bool resolved,
            bool deployed
        ) = factory.deploymentProposals(assertionId);

        assertEq(deployer_, user1);
        assertEq(baseFeedId, ETH_USD_FEED_ID);
        assertTrue(isContinuouslyTraded);
        assertEq(storedSeedAmount, seedBazaar);
        assertEq(storedSeedAmountUsdc, seedUsdc);
        assertEq(description, "ETH/USD");
        assertFalse(resolved);
        assertFalse(deployed);

        // Verify USDC was pulled from user
        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE - PROPOSAL_TOTAL_USDC);

        // Verify bond was forwarded to OOv3, seed escrowed in factory
        assertEq(usdc.balanceOf(address(mockOOv3)), bondUsdc);
        assertEq(usdc.balanceOf(address(factory)), seedUsdc);

        // Verify pending deployment is tracked
        assertEq(factory.pendingDeploymentByPairId(pairId), assertionId);
    }

    // -------------------- Error Tests --------------------

    function testProposePairDeployment_RevertsBelowMinimum() public {
        uint256 belowMinimum = minDeploymentAmount - 1;

        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);

        vm.expectRevert(BazaarFactory.Factory__SeedBelowMinimum.selector);
        factory.proposePairDeployment(ETH_USD_FEED_ID, true, belowMinimum, "ETH/USD");
        vm.stopPrank();
    }

    function testProposePairDeployment_RevertsEmptyDescription() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);

        vm.expectRevert(BazaarFactory.Factory__DescriptionInvalid.selector);
        factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "");
        vm.stopPrank();
    }

    function testProposePairDeployment_RevertsDescriptionTooLong() public {
        // 201 characters — exceeds the 200-char limit
        bytes memory longBytes = new bytes(201);
        for (uint256 i = 0; i < 201; i++) {
            longBytes[i] = "a";
        }
        string memory longDesc = string(longBytes);

        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);

        vm.expectRevert(BazaarFactory.Factory__DescriptionInvalid.selector);
        factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, longDesc);
        vm.stopPrank();
    }

    function testProposePairDeployment_RevertsAlreadyPending() public {
        // First proposal succeeds
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC * 2);
        factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");

        // Second proposal for same pair reverts
        bytes32 pairId = ETH_USD_FEED_ID;
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__ProposalAlreadyPending.selector, pairId));
        factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();
    }

    function testProposePairDeployment_RevertsInsufficientAllowance() public {
        vm.startPrank(user1);
        // No approval given

        vm.expectRevert();
        factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();
    }

    function testProposePairDeployment_RevertsInsufficientBalance() public {
        address broke = makeAddr("broke");

        vm.startPrank(broke);
        usdc.approve(address(factory), type(uint256).max);

        vm.expectRevert();
        factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();
    }

    function testProposePairDeployment_ExactMinimumSucceeds() public {
        uint256 exactMinimumUsdc = minDeploymentAmount / (BAZAAR_SCALE / USDC_SCALE);
        uint256 expectedSeedUsdc = exactMinimumUsdc - bondUsdc;

        vm.startPrank(user1);
        usdc.approve(address(factory), exactMinimumUsdc);

        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, minDeploymentAmount, "ETH/USD");
        vm.stopPrank();

        assertTrue(assertionId != bytes32(0));
        assertEq(usdc.balanceOf(address(factory)), expectedSeedUsdc);
    }

    // -------------------- proposeUmaOracleUpgrade Tests --------------------

    function testProposeUmaOracleUpgrade() public {
        address newOracle = address(new MockOptimisticOracleV3(address(usdc), 7200));
        bytes32 newIdentifier = "ASSERT_TRUTH3";

        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);

        // assertionId (topic1) unknown before call, check topic2 (proposer) and data
        vm.expectEmit(false, true, false, true, address(factory));
        emit BazaarFactory.UmaOracleUpgradeProposed(bytes32(0), user1, newOracle, newIdentifier);

        bytes32 assertionId = factory.proposeUmaOracleUpgrade(newOracle, newIdentifier);
        vm.stopPrank();

        assertTrue(assertionId != bytes32(0), "Assertion ID should not be zero");

        // Verify proposal was stored
        (
            address proposer,
            address storedNewOracle,
            bytes32 storedNewIdentifier,, // proposalTs
            bool resolved,
            bool settlementResolution
        ) = factory.oracleUpgradeProposals(assertionId);

        assertEq(proposer, user1);
        assertEq(storedNewOracle, newOracle);
        assertEq(storedNewIdentifier, newIdentifier);
        assertFalse(resolved);
        assertFalse(settlementResolution);

        // Verify USDC was pulled from user (5,000 USDC oracle-upgrade bond, not the 1,000 deployment bond)
        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE - oracleUpgradeBondUsdc);

        // Verify bond was forwarded to OOv3
        assertEq(usdc.balanceOf(address(mockOOv3)), oracleUpgradeBondUsdc);
    }

    function testProposeUmaOracleUpgrade_RevertsZeroAddress() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);

        vm.expectRevert(BazaarFactory.Factory__ZeroAddress.selector);
        factory.proposeUmaOracleUpgrade(address(0), "ASSERT_TRUTH3");
        vm.stopPrank();
    }

    function testProposeUmaOracleUpgrade_RevertsZeroIdentifier() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);

        vm.expectRevert(BazaarFactory.Factory__InvalidIdentifier.selector);
        factory.proposeUmaOracleUpgrade(makeAddr("newOracle"), bytes32(0));
        vm.stopPrank();
    }

    function testProposeUmaOracleUpgrade_RevertsInsufficientAllowance() public {
        address newOracle = address(new MockOptimisticOracleV3(address(usdc), 7200));
        vm.startPrank(user1);

        vm.expectRevert();
        factory.proposeUmaOracleUpgrade(newOracle, "ASSERT_TRUTH3");
        vm.stopPrank();
    }

    function testProposeUmaOracleUpgrade_RevertsInsufficientBalance() public {
        address newOracle = address(new MockOptimisticOracleV3(address(usdc), 7200));
        address broke = makeAddr("broke");

        vm.startPrank(broke);
        usdc.approve(address(factory), type(uint256).max);

        vm.expectRevert();
        factory.proposeUmaOracleUpgrade(newOracle, "ASSERT_TRUTH3");
        vm.stopPrank();
    }

    function testProposeUmaOracleUpgrade_RevertsNoChange() public {
        address currentOo = address(factory.oo());
        bytes32 currentIdentifier = factory.umaIdentifier();

        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);

        // Propose with the same oracle address and identifier that are already set
        vm.expectRevert(BazaarFactory.Factory__OracleUpgradeNoChange.selector);
        factory.proposeUmaOracleUpgrade(currentOo, currentIdentifier);
        vm.stopPrank();
    }

    /// @notice L-11 regression: a no-code candidate oracle fails the conformance probe at
    ///         proposal time — before the bond moves. Pre-fix it sailed through and, if approved
    ///         and activated, bricked every assertTruth call-site including the upgrade path
    ///         itself (governance permanently dead, factory redeploy required).
    function testProposeUmaOracleUpgrade_RevertsProbeFail_NoCode() public {
        address noCode = makeAddr("noCodeOracle");
        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);

        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__OracleProbeFailed.selector, noCode));
        factory.proposeUmaOracleUpgrade(noCode, "ASSERT_TRUTH3");
        vm.stopPrank();
    }

    /// @notice L-11 regression: a contract that doesn't answer OOv3 views (here: the USDC token)
    ///         fails the probe the same way — code alone isn't conformance.
    function testProposeUmaOracleUpgrade_RevertsProbeFail_NonConforming() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);

        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__OracleProbeFailed.selector, address(usdc)));
        factory.proposeUmaOracleUpgrade(address(usdc), "ASSERT_TRUTH3");
        vm.stopPrank();
    }

    /// @notice L-11 regression, activation layer: a candidate that passed the propose-time probe
    ///         but broke during liveness + timelock (simulated by stripping its code) is CANCELED
    ///         at activation — the incumbent oracle stays, the queue clears, and governance keeps
    ///         working: a corrected upgrade can be proposed immediately afterwards.
    function testActivateOracleUpgrade_CancelsBrokenCandidate_KeepsGovernanceAlive() public {
        MockOptimisticOracleV3 candidate = new MockOptimisticOracleV3(address(usdc), 7200);
        address oldOracle = address(factory.oo());
        bytes32 oldIdentifier = factory.umaIdentifier();

        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 assertionId = factory.proposeUmaOracleUpgrade(address(candidate), "ASSERT_TRUTH3");
        vm.stopPrank();

        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);
        factory.settleOracleUpgradeProposal(assertionId); // approved → queued behind the timelock

        // The candidate breaks during the exit window (deprecation stand-in: code vanishes).
        vm.etch(address(candidate), "");

        vm.warp(block.timestamp + factory.ORACLE_UPGRADE_TIMELOCK() + 1);
        vm.expectEmit(true, false, false, true, address(factory));
        emit BazaarFactory.UmaOracleUpgradeCanceled(assertionId, address(candidate), "ASSERT_TRUTH3");
        factory.activateOracleUpgrade();

        // Incumbent untouched, queue cleared — NOT swapped to the dud.
        assertEq(address(factory.oo()), oldOracle, "incumbent oracle kept");
        assertEq(factory.umaIdentifier(), oldIdentifier, "incumbent identifier kept");
        (,,, uint256 effectiveTs) = factory.queuedOracleUpgrade();
        assertEq(effectiveTs, 0, "queued dud cleared");

        // Governance is alive: a corrected upgrade proposal goes straight through.
        address goodOracle = address(new MockOptimisticOracleV3(address(usdc), 7200));
        vm.startPrank(user2);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 retryId = factory.proposeUmaOracleUpgrade(goodOracle, "ASSERT_TRUTH3");
        vm.stopPrank();
        assertTrue(retryId != bytes32(0), "recovery proposal accepted");
    }

    function testProposeUmaOracleUpgrade_RevertsWhilePending() public {
        address newOracle = address(new MockOptimisticOracleV3(address(usdc), 7200));

        // First proposal succeeds
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        factory.proposeUmaOracleUpgrade(newOracle, "ASSERT_TRUTH3");
        vm.stopPrank();

        // Second proposal reverts because liveness hasn't expired
        vm.startPrank(user2);
        usdc.approve(address(factory), type(uint256).max);

        vm.expectRevert(BazaarFactory.Factory__OracleUpgradeStillPending.selector);
        factory.proposeUmaOracleUpgrade(makeAddr("anotherOracle"), "ASSERT_TRUTH4");
        vm.stopPrank();
    }

    function testProposeUmaOracleUpgrade_RevertsBeforeLivenessExpires() public {
        MockOptimisticOracleV3 newOracle1 = new MockOptimisticOracleV3(address(usdc), 7200);

        // First proposal
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        factory.proposeUmaOracleUpgrade(address(newOracle1), "ASSERT_TRUTH3");
        vm.stopPrank();

        // Warp to 1 second before expiration — should revert
        vm.warp(block.timestamp + oracleUpgradeLiveness - 1);

        vm.startPrank(user2);
        usdc.approve(address(factory), type(uint256).max);
        vm.expectRevert(BazaarFactory.Factory__OracleUpgradeStillPending.selector);
        factory.proposeUmaOracleUpgrade(makeAddr("anotherOracle"), "ASSERT_TRUTH4");
        vm.stopPrank();
    }

    function testProposeUmaOracleUpgrade_SettlesAtExactLiveness() public {
        MockOptimisticOracleV3 newOracle1 = new MockOptimisticOracleV3(address(usdc), 7200);
        MockOptimisticOracleV3 newOracle2 = new MockOptimisticOracleV3(address(usdc), 7200);

        // First proposal
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 firstId = factory.proposeUmaOracleUpgrade(address(newOracle1), "ASSERT_TRUTH3");
        vm.stopPrank();

        // Warp to exactly expiration time — settlement succeeds (>= check) and QUEUES the swap
        // behind the activation timelock.
        vm.warp(block.timestamp + oracleUpgradeLiveness);
        factory.settleOracleUpgradeProposal(firstId);
        (bytes32 qAid,,, uint256 effectiveTs) = factory.queuedOracleUpgrade();
        assertEq(qAid, firstId, "queued at exact liveness");

        // A second proposal during the activation timelock reverts...
        vm.startPrank(user2);
        usdc.approve(address(factory), type(uint256).max);
        vm.expectRevert(BazaarFactory.Factory__OracleUpgradeStillPending.selector);
        factory.proposeUmaOracleUpgrade(address(newOracle2), "ASSERT_TRUTH4");

        // ...and succeeds once it elapses, auto-activating the queued upgrade.
        vm.warp(effectiveTs);
        bytes32 secondId = factory.proposeUmaOracleUpgrade(address(newOracle2), "ASSERT_TRUTH4");
        vm.stopPrank();

        assertTrue(secondId != bytes32(0));
        assertEq(address(factory.oo()), address(newOracle1));
    }

    function testProposeUmaOracleUpgrade_SucceedsAfterPreviousSettled() public {
        // Deploy real MockOptimisticOracleV3 instances so oo.assertTruth works after upgrade
        MockOptimisticOracleV3 newOracle1 = new MockOptimisticOracleV3(address(usdc), 7200);
        MockOptimisticOracleV3 newOracle2 = new MockOptimisticOracleV3(address(usdc), 7200);

        // First proposal
        uint256 user1BalanceBefore = usdc.balanceOf(user1);
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 firstAssertionId = factory.proposeUmaOracleUpgrade(address(newOracle1), "ASSERT_TRUTH3");
        vm.stopPrank();

        // Verify bond was deducted from user1
        assertEq(usdc.balanceOf(user1), user1BalanceBefore - oracleUpgradeBondUsdc);

        // Warp past liveness and settle: bond returns, upgrade QUEUES behind the timelock
        // (the oo pointer must not move yet).
        address oldOo = address(factory.oo());
        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);
        factory.settleOracleUpgradeProposal(firstAssertionId);
        assertEq(usdc.balanceOf(user1), user1BalanceBefore);
        assertEq(address(factory.oo()), oldOo, "swap deferred by the activation timelock");

        // First proposal should be resolved
        (,,,, bool resolved, bool settlementResolution) = factory.oracleUpgradeProposals(firstAssertionId);
        assertTrue(resolved);
        assertTrue(settlementResolution);

        // After the timelock, a second proposal auto-activates the first and succeeds.
        // Activation swaps factory.oo to newOracle1, so user2's bond goes there.
        vm.warp(block.timestamp + factory.ORACLE_UPGRADE_TIMELOCK() + 1);
        vm.startPrank(user2);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 secondAssertionId = factory.proposeUmaOracleUpgrade(address(newOracle2), "ASSERT_TRUTH4");
        vm.stopPrank();

        assertTrue(secondAssertionId != bytes32(0));
        assertEq(factory.pendingOracleUpgradeAssertionId(), secondAssertionId);

        // Factory oo should now point to newOracle1 (from the activated first proposal)
        assertEq(address(factory.oo()), address(newOracle1));
    }

    // ==================== settleDeploymentProposal Tests ====================

    function testSettleDeploymentProposal_Success() public {
        // Propose
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        // Warp past liveness
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);

        // Settle — triggers callback, deploys pair
        vm.expectEmit(true, false, false, true, address(factory));
        emit BazaarFactory.PairDeploymentProposalResolved(assertionId, true, true);
        factory.settleDeploymentProposal(assertionId);

        // Verify proposal is resolved and deployed
        (,,,,,, bytes32 pairId,, bool resolved, bool deployed) = factory.deploymentProposals(assertionId);
        assertTrue(resolved);
        assertTrue(deployed);

        // Verify pair was created
        address pairAddr = factory.getPairAddress(pairId);
        assertTrue(pairAddr != address(0));
        assertTrue(factory.isPair(pairAddr));

        // Verify pair is registered in sequencer and terminator
        assertTrue(sequencer.isPair(pairAddr));
        assertTrue(pairTerminator.isPair(pairAddr));

        // Verify seed USDC was transferred to pair
        assertEq(usdc.balanceOf(pairAddr), seedUsdc);

        // Verify pending deployment cleared
        assertEq(factory.pendingDeploymentByPairId(pairId), bytes32(0));

        // Verify user1 got bond back (returned by OOv3 on successful settlement)
        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE - seedUsdc);
    }

    function testSettleDeploymentProposal_RevertsNotFound() public {
        bytes32 fakeId = keccak256("nonexistent");

        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__ProposalNotFound.selector, fakeId));
        factory.settleDeploymentProposal(fakeId);
    }

    function testSettleDeploymentProposal_RevertsAlreadyResolved() public {
        // Propose and settle
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);

        // Try to settle again
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__ProposalAlreadyResolved.selector, assertionId));
        factory.settleDeploymentProposal(assertionId);
    }

    function testSettleDeploymentProposal_RevertsBeforeLiveness() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        // Try to settle before liveness expires — OOv3 should revert
        vm.expectRevert();
        factory.settleDeploymentProposal(assertionId);
    }

    function testSettleDeploymentProposal_DisputedAndRejected() public {
        // Propose
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        // Dispute
        vm.startPrank(user2);
        usdc.approve(address(mockOOv3), bondUsdc);
        mockOOv3.disputeAssertion(assertionId, user2);
        vm.stopPrank();

        // DVM resolves against asserter (false)
        mockOOv3.mockDvmResolve(assertionId, false);

        uint256 user1BalanceBefore = usdc.balanceOf(user1);

        // Settle — rejected, seed refunded to deployer
        vm.expectEmit(true, false, false, true, address(factory));
        emit BazaarFactory.PairDeploymentProposalResolved(assertionId, false, false);
        factory.settleDeploymentProposal(assertionId);

        // Verify resolved but not deployed
        (,,,, uint256 storedSeedAmountUsdc,, bytes32 pairId,, bool resolved, bool deployed) =
            factory.deploymentProposals(assertionId);
        assertTrue(resolved);
        assertFalse(deployed);

        // Verify no pair was created
        assertEq(factory.getPairAddress(pairId), address(0));

        // Verify pending deployment cleared
        assertEq(factory.pendingDeploymentByPairId(pairId), bytes32(0));

        // Verify seed USDC refunded to deployer
        assertEq(usdc.balanceOf(user1), user1BalanceBefore + storedSeedAmountUsdc);

        // Verify disputer won both bonds (own bond returned + asserter's bond)
        assertEq(usdc.balanceOf(user2), INITIAL_USER_BALANCE + bondUsdc);
    }

    function testSettleDeploymentProposal_DisputedAndAccepted() public {
        // Propose
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        // Dispute
        vm.startPrank(user2);
        usdc.approve(address(mockOOv3), bondUsdc);
        mockOOv3.disputeAssertion(assertionId, user2);
        vm.stopPrank();

        // DVM resolves in favor of asserter (true)
        mockOOv3.mockDvmResolve(assertionId, true);

        // Settle — accepted, pair deployed
        vm.expectEmit(true, false, false, true, address(factory));
        emit BazaarFactory.PairDeploymentProposalResolved(assertionId, true, true);
        factory.settleDeploymentProposal(assertionId);

        // Verify resolved and deployed
        (,,,,,, bytes32 pairId,, bool resolved, bool deployed) = factory.deploymentProposals(assertionId);
        assertTrue(resolved);
        assertTrue(deployed);

        // Verify pair was created
        address pairAddr = factory.getPairAddress(pairId);
        assertTrue(pairAddr != address(0));

        // Verify asserter won both bonds
        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE - seedUsdc + bondUsdc);
    }

    // ==================== settleOracleUpgradeProposal Tests ====================

    function testSettleOracleUpgradeProposal_Success() public {
        MockOptimisticOracleV3 newOracle = new MockOptimisticOracleV3(address(usdc), 7200);
        bytes32 newIdentifier = "ASSERT_TRUTH3";

        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 assertionId = factory.proposeUmaOracleUpgrade(address(newOracle), newIdentifier);
        vm.stopPrank();

        // Warp past liveness
        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);

        // Settle — emits UmaOracleUpgradeQueued and defers the swap behind the timelock
        address oldOracle = address(factory.oo());
        bytes32 oldIdentifier = factory.umaIdentifier();
        uint256 expectedEffectiveTs = block.timestamp + factory.ORACLE_UPGRADE_TIMELOCK();
        vm.expectEmit(true, false, false, true, address(factory));
        emit BazaarFactory.UmaOracleUpgradeQueued(assertionId, address(newOracle), newIdentifier, expectedEffectiveTs);
        factory.settleOracleUpgradeProposal(assertionId);

        // Verify resolved with true
        (,,,, bool resolved, bool settlementResolution) = factory.oracleUpgradeProposals(assertionId);
        assertTrue(resolved);
        assertTrue(settlementResolution);

        // Not swapped yet; pending assertion cleared; bond returned
        assertEq(address(factory.oo()), oldOracle);
        assertEq(factory.umaIdentifier(), oldIdentifier);
        assertEq(factory.pendingOracleUpgradeAssertionId(), bytes32(0));
        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE);

        // Activation after the timelock emits UmaOracleUpgraded and performs the swap
        vm.warp(expectedEffectiveTs);
        vm.expectEmit(true, false, false, true, address(factory));
        emit BazaarFactory.UmaOracleUpgraded(assertionId, oldOracle, address(newOracle), oldIdentifier, newIdentifier);
        factory.activateOracleUpgrade();

        assertEq(address(factory.oo()), address(newOracle));
        assertEq(factory.umaIdentifier(), newIdentifier);
    }

    function testSettleOracleUpgradeProposal_RevertsNotFound() public {
        bytes32 fakeId = keccak256("nonexistent");

        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__ProposalNotFound.selector, fakeId));
        factory.settleOracleUpgradeProposal(fakeId);
    }

    function testSettleOracleUpgradeProposal_RevertsAlreadyResolved() public {
        MockOptimisticOracleV3 newOracle = new MockOptimisticOracleV3(address(usdc), 7200);

        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 assertionId = factory.proposeUmaOracleUpgrade(address(newOracle), "ASSERT_TRUTH3");
        vm.stopPrank();

        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);
        factory.settleOracleUpgradeProposal(assertionId);

        // Try to settle again
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__ProposalAlreadyResolved.selector, assertionId));
        factory.settleOracleUpgradeProposal(assertionId);
    }

    function testSettleOracleUpgradeProposal_DisputedAndRejected() public {
        MockOptimisticOracleV3 newOracle = new MockOptimisticOracleV3(address(usdc), 7200);
        address originalOo = address(factory.oo());
        bytes32 originalIdentifier = factory.umaIdentifier();

        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 assertionId = factory.proposeUmaOracleUpgrade(address(newOracle), "ASSERT_TRUTH3");
        vm.stopPrank();

        // Dispute (disputer's bond must also match the oracle-upgrade bond)
        vm.startPrank(user2);
        usdc.approve(address(mockOOv3), oracleUpgradeBondUsdc);
        mockOOv3.disputeAssertion(assertionId, user2);
        vm.stopPrank();

        // DVM resolves against asserter
        mockOOv3.mockDvmResolve(assertionId, false);

        // Settle
        factory.settleOracleUpgradeProposal(assertionId);

        // Verify resolved with false
        (,,,, bool resolved, bool settlementResolution) = factory.oracleUpgradeProposals(assertionId);
        assertTrue(resolved);
        assertFalse(settlementResolution);

        // Verify oo and identifier NOT changed
        assertEq(address(factory.oo()), originalOo);
        assertEq(factory.umaIdentifier(), originalIdentifier);

        // Verify pending cleared
        assertEq(factory.pendingOracleUpgradeAssertionId(), bytes32(0));

        // Verify user1 lost their bond
        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE - oracleUpgradeBondUsdc);

        // Verify disputer won both bonds (own bond returned + asserter's bond)
        assertEq(usdc.balanceOf(user2), INITIAL_USER_BALANCE + oracleUpgradeBondUsdc);
    }

    // ==================== Callback Access Control Tests ====================

    function testAssertionResolvedCallback_RevertsNonOracle() public {
        bytes32 fakeId = keccak256("fake");

        vm.expectRevert(BazaarFactory.Factory__OnlyUmaOracle.selector);
        factory.assertionResolvedCallback(fakeId, true);
    }

    function testAssertionDisputedCallback_RevertsNonOracle() public {
        bytes32 fakeId = keccak256("fake");

        vm.expectRevert(BazaarFactory.Factory__OnlyUmaOracle.selector);
        factory.assertionDisputedCallback(fakeId);
    }

    // ==================== Dispute Callback Tests ====================

    function testDeploymentProposal_DisputeEmitsEvent() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        // Dispute — mock OOv3 calls assertionDisputedCallback on factory
        vm.startPrank(user2);
        usdc.approve(address(mockOOv3), bondUsdc);

        vm.expectEmit(true, false, false, false, address(factory));
        emit BazaarFactory.PairDeploymentProposalDisputed(assertionId);
        mockOOv3.disputeAssertion(assertionId, user2);
        vm.stopPrank();
    }

    function testOracleUpgradeProposal_DisputeEmitsEvent() public {
        address newOracle = address(new MockOptimisticOracleV3(address(usdc), 7200));
        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 assertionId = factory.proposeUmaOracleUpgrade(newOracle, "ASSERT_TRUTH3");
        vm.stopPrank();

        // Dispute (disputer's bond must also match the oracle-upgrade bond)
        vm.startPrank(user2);
        usdc.approve(address(mockOOv3), oracleUpgradeBondUsdc);

        vm.expectEmit(true, false, false, false, address(factory));
        emit BazaarFactory.UmaOracleUpgradeDisputed(assertionId);
        mockOOv3.disputeAssertion(assertionId, user2);
        vm.stopPrank();
    }

    // ==================== PairAlreadyExists Tests ====================

    function testProposePairDeployment_RevertsIfPairAlreadyDeployed() public {
        // Deploy ETH/USD pair
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);

        // Try to propose same pair again — should revert
        bytes32 pairId = ETH_USD_FEED_ID;
        vm.startPrank(user2);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__PairAlreadyExists.selector, pairId));
        factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();
    }

    // ==================== _executePairDeployment Tests ====================

    function testExecutePairDeployment_PairInitializedCorrectly() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);

        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        address pairAddr = factory.getPairAddress(pairId);

        BazaarPair pair = BazaarPair(payable(pairAddr));

        // Verify pair was initialized with correct values
        assertEq(pair.pairId(), pairId);
        assertEq(pair.baseFeedId(), ETH_USD_FEED_ID);
        assertEq(address(pair.usdc()), address(usdc));
        assertEq(address(pair.oracle()), address(oracle));
        assertTrue(pair.isContinuouslyTraded());
        assertEq(pair.auxState().bugBountyAddress, bugBountyAddress);
        assertEq(address(pair.sequencerContract()), address(sequencer));
    }

    function testExecutePairDeployment_MultiplePairsTracked() public {
        bytes32 BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

        // Deploy first pair (ETH/USD)
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 id1 = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(id1);

        // Deploy second pair (BTC/USD)
        vm.startPrank(user2);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 id2 = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(id2);

        // Verify both pairs tracked
        assertEq(factory.pairsCount(), 2);

        address[] memory allPairs = factory.getAllPairs();
        assertEq(allPairs.length, 2);
        assertTrue(factory.isPair(allPairs[0]));
        assertTrue(factory.isPair(allPairs[1]));
        assertTrue(allPairs[0] != allPairs[1]);
    }

    // ==================== View Function Tests ====================

    function testGetDeploymentProposal() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        BazaarFactory.PairDeploymentProposal memory p = factory.getDeploymentProposal(assertionId);
        assertEq(p.deployer, user1);
        assertEq(p.baseFeedId, ETH_USD_FEED_ID);
        assertTrue(p.isContinuouslyTraded);
        assertEq(p.seedAmount, seedBazaar);
        assertEq(p.seedAmountUsdc, seedUsdc);
        assertEq(keccak256(bytes(p.description)), keccak256("ETH/USD"));
        assertFalse(p.resolved);
        assertFalse(p.deployed);
    }

    function testGetDeploymentProposal_NonexistentReturnsDefault() public view {
        BazaarFactory.PairDeploymentProposal memory p = factory.getDeploymentProposal(keccak256("nonexistent"));
        assertEq(p.deployer, address(0));
        assertEq(p.baseFeedId, bytes32(0));
        assertEq(p.seedAmount, 0);
    }

    function testgetPendingDeploymentsAssertionId() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        bytes32 pairId = ETH_USD_FEED_ID;
        assertEq(factory.getPendingDeploymentsAssertionId(pairId), assertionId);

        // After settlement, pending should be cleared
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        assertEq(factory.getPendingDeploymentsAssertionId(pairId), bytes32(0));
    }

    function testGetOracleUpgradeProposal() public {
        MockOptimisticOracleV3 newOracle = new MockOptimisticOracleV3(address(usdc), 7200);
        bytes32 newIdentifier = "ASSERT_TRUTH3";

        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 assertionId = factory.proposeUmaOracleUpgrade(address(newOracle), newIdentifier);
        vm.stopPrank();

        BazaarFactory.UmaOracleUpgradeProposal memory p = factory.getOracleUpgradeProposal(assertionId);
        assertEq(p.proposer, user1);
        assertEq(p.newOracleAddress, address(newOracle));
        assertEq(p.newIdentifier, newIdentifier);
        assertFalse(p.resolved);
        assertFalse(p.settlementResolution);
    }

    function testGetPair() public {
        // Before deployment — returns zero
        bytes32 pairId = ETH_USD_FEED_ID;
        assertEq(factory.getPairAddress(pairId), address(0));

        // Deploy pair
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);

        // After deployment — returns pair address
        address pairAddr = factory.getPairAddress(pairId);
        assertTrue(pairAddr != address(0));
    }

    function testIsPair() public {
        // Random address is not a pair
        assertFalse(factory.isPair(makeAddr("random")));

        // Deploy a pair
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);

        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        address pairAddr = factory.getPairAddress(pairId);
        assertTrue(factory.isPair(pairAddr));
    }

    function testGetAllPairs_Empty() public view {
        address[] memory pairs = factory.getAllPairs();
        assertEq(pairs.length, 0);
    }

    function testPairsCount_Empty() public view {
        assertEq(factory.pairsCount(), 0);
    }

    function testPairsCount_AfterDeployment() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);

        assertEq(factory.pairsCount(), 1);
    }

    // ---------------- constructor wiring (sequencer/terminator deployed first) ----------------

    /// @notice The deploy script bakes a CREATE-predicted factory address into the sequencer's
    ///         and terminator's immutable `factory` fields; the factory constructor re-verifies
    ///         both point back at it. Deployed system must be self-consistent.
    function test_wiring_DeployedSystemIsSelfConsistent() public view {
        assertEq(sequencer.factory(), address(factory), "sequencer wired to factory");
        assertEq(pairTerminator.factory(), address(factory), "terminator wired to factory");
    }

    /// @notice A factory constructed against a sequencer that points at a DIFFERENT factory
    ///         address (bad CREATE prediction, wrong args, hand-deploy) must be unconstructable.
    function test_wiring_RevertsOnMisWiredSequencer() public {
        MockUSDC u = new MockUSDC();
        address wrongFactory = makeAddr("wrongFactory");
        BazaarSequencer s = new BazaarSequencer(address(u), wrongFactory);
        BazaarPairTerminator t = new BazaarPairTerminator(wrongFactory);

        vm.expectRevert(BazaarFactory.Factory__WiringMismatch.selector);
        new BazaarFactory(
            address(u),
            makeAddr("oracle"),
            makeAddr("lens"),
            makeAddr("bounty"),
            makeAddr("oo"),
            makeAddr("impl"),
            address(s),
            address(t)
        );
    }

    /// @notice Same for the terminator alone: sequencer correctly wired, terminator not.
    function test_wiring_RevertsOnMisWiredTerminator() public {
        MockUSDC u = new MockUSDC();
        // Predict THIS test's next-next CREATE address the same way the script does:
        // nonce+2 because the sequencer and terminator deploys consume two nonces first.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        BazaarSequencer s = new BazaarSequencer(address(u), predicted);
        BazaarPairTerminator t = new BazaarPairTerminator(makeAddr("wrongFactory"));

        vm.expectRevert(BazaarFactory.Factory__WiringMismatch.selector);
        new BazaarFactory(
            address(u),
            makeAddr("oracle"),
            makeAddr("lens"),
            makeAddr("bounty"),
            makeAddr("oo"),
            makeAddr("impl"),
            address(s),
            address(t)
        );
    }
}
