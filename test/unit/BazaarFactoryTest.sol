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
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        oracleUpgradeBondUsdc = factory.IDENTIFIER_UPGRADE_BOND_USDC();
        oracleUpgradeLiveness = factory.IDENTIFIER_UPGRADE_LIVENESS();
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

    function testProposePairDeployment_RevertsDescriptionBadCharset() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);

        // One banned character each: single quote (fake quoted value), parentheses
        // (fake numbered check), colon (fake "Field: value"), double quote, newline, tab,
        // non-ASCII homoglyph (Greek capital Alpha), underscore (outside the whitelist).
        string[8] memory bad = [
            "AAPL' on NASDAQ",
            "AAPL (Apple) on NASDAQ",
            "AAPL: NASDAQ",
            "AAPL\" on NASDAQ",
            "AAPL\non NASDAQ",
            "AAPL\ton NASDAQ",
            unicode"AAPL on NΑSDAQ",
            "AAPL_NASDAQ"
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(BazaarFactory.Factory__DescriptionInvalid.selector);
            factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, bad[i]);
        }
        vm.stopPrank();
    }

    function testProposePairDeployment_AcceptsAllWhitelistedCharClasses() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);

        // Letters, digits, space, and every allowed punctuation mark: . , & / -
        bytes32 assertionId = factory.proposePairDeployment(
            ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "Class B shares, BRK.B & S/P-500 member 2026"
        );
        vm.stopPrank();

        assertTrue(assertionId != bytes32(0));
    }

    function testDeploymentClaimBindsDescriptionOnce() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 assertionId =
            factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "UNIQUEMARKER on NASDAQ");
        vm.stopPrank();

        bytes memory claim = mockOOv3.claims(assertionId);
        // Display splice only: the description must appear exactly once, and the instruction
        // section must reference it, not re-splice it — a quoted ('<desc>') echo would hand the
        // free text a second occurrence, in a position that reads as claim structure.
        assertEq(_countOccurrences(claim, "UNIQUEMARKER"), 1, "description spliced more than once");
        assertEq(_countOccurrences(claim, "('"), 0, "quoted splice delimiter still present");
        assertEq(
            _countOccurrences(claim, "asset description stated above"), 1, "instruction must reference the description"
        );
        assertEq(_countOccurrences(claim, "untrusted free text"), 1, "verifier warning missing");
    }

    function _countOccurrences(bytes memory haystack, bytes memory needle) internal pure returns (uint256 count) {
        for (uint256 i = 0; i + needle.length <= haystack.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) count++;
        }
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

    // -------------------- proposeUmaIdentifierUpgrade Tests --------------------

    function testProposeUmaIdentifierUpgrade() public {
        bytes32 newIdentifier = "ASSERT_TRUTH3";

        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);

        // assertionId (topic1) unknown before call, check topic2 (proposer) and data
        vm.expectEmit(false, true, false, true, address(factory));
        emit BazaarFactory.UmaIdentifierUpgradeProposed(bytes32(0), user1, newIdentifier);

        bytes32 assertionId = factory.proposeUmaIdentifierUpgrade(newIdentifier);
        vm.stopPrank();

        assertTrue(assertionId != bytes32(0), "Assertion ID should not be zero");

        // Verify proposal was stored
        (
            address proposer,
            bytes32 storedNewIdentifier,, // proposalTs
            bool resolved,
            bool settlementResolution,
            bool disputed
        ) = factory.identifierUpgradeProposals(assertionId);

        assertEq(proposer, user1);
        assertEq(storedNewIdentifier, newIdentifier);
        assertFalse(resolved);
        assertFalse(settlementResolution);
        assertFalse(disputed);

        // Verify USDC was pulled from user (5,000 USDC upgrade bond, not the 1,000 deployment bond)
        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE - oracleUpgradeBondUsdc);

        // Verify bond was forwarded to OOv3
        assertEq(usdc.balanceOf(address(mockOOv3)), oracleUpgradeBondUsdc);
    }

    function testProposeUmaIdentifierUpgrade_RevertsZeroIdentifier() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);

        vm.expectRevert(BazaarFactory.Factory__InvalidIdentifier.selector);
        factory.proposeUmaIdentifierUpgrade(bytes32(0));
        vm.stopPrank();
    }

    /// @notice The full governance cycle: propose → 14d liveness → settle (queues) → 14d timelock
    ///         → activate. The identifier swaps and the predecessor is recorded as the rollback
    ///         target. The oracle address never moves — it is immutable.
    function testIdentifierUpgrade_EndToEnd() public {
        bytes32 oldIdentifier = factory.umaIdentifier();
        address ooBefore = address(factory.oo());

        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 assertionId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);
        factory.settleIdentifierUpgradeProposal(assertionId);
        assertEq(factory.umaIdentifier(), oldIdentifier, "swap deferred by the timelock");

        vm.warp(block.timestamp + factory.IDENTIFIER_UPGRADE_TIMELOCK() + 1);
        vm.expectEmit(true, false, false, true, address(factory));
        emit BazaarFactory.UmaIdentifierUpgraded(assertionId, oldIdentifier, "ASSERT_TRUTH3");
        factory.activateIdentifierUpgrade();

        assertEq(factory.umaIdentifier(), bytes32("ASSERT_TRUTH3"), "identifier swapped");
        assertEq(address(factory.oo()), ooBefore, "oracle address immutable");
    }

    function testProposeUmaIdentifierUpgrade_RevertsInsufficientAllowance() public {
        vm.startPrank(user1);

        vm.expectRevert();
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();
    }

    function testProposeUmaIdentifierUpgrade_RevertsInsufficientBalance() public {
        address broke = makeAddr("broke");

        vm.startPrank(broke);
        usdc.approve(address(factory), type(uint256).max);

        vm.expectRevert();
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();
    }

    function testProposeUmaIdentifierUpgrade_RevertsNoChange() public {
        bytes32 current = factory.umaIdentifier();

        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);

        // Propose the identifier that is already active
        vm.expectRevert(BazaarFactory.Factory__IdentifierUpgradeNoChange.selector);
        factory.proposeUmaIdentifierUpgrade(current);
        vm.stopPrank();
    }

    /// @notice A non-whitelisted identifier is rejected against UMA's LIVE IdentifierWhitelist
    ///         before the bond moves. Were an arbitrary bytes32 to sail through, activating it
    ///         would brick every assertTruth call-site including the upgrade path itself —
    ///         governance permanently dead, factory redeploy required.
    function testProposeUmaIdentifierUpgrade_RevertsNotWhitelisted() public {
        // Prefixed so this exercises the WHITELIST gate specifically: a non-prefixed value is
        // rejected earlier, by the ASSERT_TRUTH rule.
        bytes32 junk = "ASSERT_TRUTH_NOT_WHITELISTED";
        mockOOv3.setIdentifierSupported(junk, false);

        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);

        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__IdentifierNotWhitelisted.selector, junk));
        factory.proposeUmaIdentifierUpgrade(junk);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE, "no bond moved");
    }

    /// @notice Activation layer: an identifier that was whitelisted at propose time but
    ///         de-whitelisted during liveness + timelock is CANCELED at activation — the incumbent
    ///         identifier stays, the queue clears, and governance keeps working: a corrected
    ///         upgrade can be proposed immediately afterwards.
    function testActivateIdentifierUpgrade_CancelsDewhitelistedIdentifier_KeepsGovernanceAlive() public {
        bytes32 candidate = "ASSERT_TRUTH3";
        bytes32 oldIdentifier = factory.umaIdentifier();

        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 assertionId = factory.proposeUmaIdentifierUpgrade(candidate);
        vm.stopPrank();

        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);
        factory.settleIdentifierUpgradeProposal(assertionId); // approved → queued behind the timelock

        // UMA de-whitelists the incoming identifier during the exit window.
        mockOOv3.setIdentifierSupported(candidate, false);

        vm.warp(block.timestamp + factory.IDENTIFIER_UPGRADE_TIMELOCK() + 1);
        vm.expectEmit(true, false, false, true, address(factory));
        emit BazaarFactory.UmaIdentifierUpgradeCanceled(assertionId, candidate);
        factory.activateIdentifierUpgrade();

        // Incumbent untouched, queue cleared — NOT swapped to the dud.
        assertEq(factory.umaIdentifier(), oldIdentifier, "incumbent identifier kept");
        (,, uint256 effectiveTs) = factory.queuedIdentifierUpgrade();
        assertEq(effectiveTs, 0, "queued dud cleared");

        // Governance is alive: a corrected upgrade proposal goes straight through.
        vm.startPrank(user2);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 retryId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH4");
        vm.stopPrank();
        assertTrue(retryId != bytes32(0), "recovery proposal accepted");
    }

    // -------------------- expireStuckIdentifierUpgradeProposal Tests --------------------

    /// @dev Proposes an upgrade, then makes the bond payout to the proposer revert — the USDC
    ///      blacklist scenario. OOv3 pays the asserter before firing the resolve callback, so
    ///      settlement reverts wholesale and the pending slot can never clear on its own.
    function _proposeThenStrand(address proposer) internal returns (bytes32 assertionId) {
        vm.startPrank(proposer);
        usdc.approve(address(factory), type(uint256).max);
        assertionId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH8");
        vm.stopPrank();

        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, proposer, oracleUpgradeBondUsdc),
            bytes("Blacklistable: account is blacklisted")
        );
    }

    /// @notice The single proposal slot must not be permanently occupiable. A proposer blacklisted
    ///         after proposing leaves `pendingIdentifierUpgradeAssertionId` set with no settlement
    ///         path, so absent a timeout it would kill every future identifier upgrade — and there
    ///         is no other recovery route.
    function testExpireStuckOracleUpgradeProposal_UnblocksGovernance() public {
        bytes32 stuck = _proposeThenStrand(user1);

        // Confirmed unsettleable, and it blocks every competing proposal.
        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);
        vm.expectRevert();
        factory.settleIdentifierUpgradeProposal(stuck);

        bytes32 good = "ASSERT_TRUTH7";
        vm.startPrank(user2);
        usdc.approve(address(factory), type(uint256).max);
        vm.expectRevert(BazaarFactory.Factory__IdentifierUpgradeStillPending.selector);
        factory.proposeUmaIdentifierUpgrade(good);
        vm.stopPrank();

        // No grace applies: the proposal is undisputed, so a failed settlement past liveness is
        // proof the payout is blocked rather than a "not ready yet".
        vm.expectEmit(true, true, false, false, address(factory));
        emit BazaarFactory.UmaIdentifierUpgradeExpired(stuck, user1);
        vm.prank(makeAddr("anyone")); // permissionless
        factory.expireStuckIdentifierUpgradeProposal();

        assertEq(factory.pendingIdentifierUpgradeAssertionId(), bytes32(0), "slot released");

        vm.prank(user2);
        bytes32 retry = factory.proposeUmaIdentifierUpgrade(good);
        assertTrue(retry != bytes32(0), "governance unblocked");
    }

    function testExpireStuckOracleUpgradeProposal_RevertsBeforeLiveness() public {
        bytes32 stuck = _proposeThenStrand(user1);
        (,, uint256 proposalTs,,,) = factory.identifierUpgradeProposals(stuck);
        uint256 expiryTs = proposalTs + oracleUpgradeLiveness;

        vm.warp(expiryTs - 1);
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__IdentifierUpgradeNotExpired.selector, expiryTs));
        factory.expireStuckIdentifierUpgradeProposal();
    }

    /// @notice The one case a timer is unavoidable. A disputed assertion is unsettleable *by design*
    ///         while the DVM votes, and that state is not queryable from the factory (VotingV2 gates
    ///         hasPrice/getPrice behind onlyRegisteredContract). Without the extra grace, any
    ///         disputer could discard the proposal the moment liveness ended regardless of how the
    ///         DVM later voted — turning a 5k bet into a guaranteed veto.
    function testExpireStuckOracleUpgradeProposal_DisputedWaitsOutTheDvmGrace() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 assertionId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(mockOOv3), type(uint256).max);
        mockOOv3.disputeAssertion(assertionId, user2); // no DVM resolution set: vote still running
        vm.stopPrank();

        (,, uint256 proposalTs,,, bool disputed) = factory.identifierUpgradeProposals(assertionId);
        assertTrue(disputed, "dispute recorded from the callback");

        // Past liveness it is unsettleable — but that is expected, not a brick.
        uint256 expiryTs = proposalTs + oracleUpgradeLiveness + factory.DVM_DISPUTE_GRACE();
        vm.warp(proposalTs + oracleUpgradeLiveness + 1);
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__IdentifierUpgradeNotExpired.selector, expiryTs));
        factory.expireStuckIdentifierUpgradeProposal();

        // Once the grace elapses with still no resolution, the slot is released.
        vm.warp(expiryTs);
        factory.expireStuckIdentifierUpgradeProposal();
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), bytes32(0), "slot released after the DVM grace");
    }

    function testExpireStuckOracleUpgradeProposal_RevertsWhenNothingPending() public {
        vm.expectRevert(BazaarFactory.Factory__NoPendingIdentifierUpgrade.selector);
        factory.expireStuckIdentifierUpgradeProposal();
    }

    /// @notice Settlement is attempted first, so a proposal that can still resolve normally is
    ///         never discarded — it settles and queues exactly as it would have.
    function testExpireStuckOracleUpgradeProposal_SettlesRatherThanDiscardsWhenSettleable() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 assertionId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);
        factory.expireStuckIdentifierUpgradeProposal();

        assertEq(factory.pendingIdentifierUpgradeAssertionId(), bytes32(0), "slot released by settlement");
        (bytes32 qAid,, uint256 effectiveTs) = factory.queuedIdentifierUpgrade();
        assertEq(qAid, assertionId, "approved upgrade queued, not discarded");
        assertTrue(effectiveTs != 0, "timelock started");
        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE, "bond returned");
    }

    /// @notice A discarded assertion is left live on the OO. If it ever becomes settleable again,
    ///         settlement must SUCCEED so the winning party can collect — the factory's callback
    ///         has to ignore the outcome rather than revert, which would revert settleAssertion
    ///         itself and trap the bond forever.
    function testExpireStuckOracleUpgradeProposal_LateSettlementPaysOutButChangesNothing() public {
        bytes32 stuck = _proposeThenStrand(user1);
        bytes32 identifierOfStuck;
        (, identifierOfStuck,,,,) = factory.identifierUpgradeProposals(stuck);

        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);
        factory.expireStuckIdentifierUpgradeProposal();
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), bytes32(0), "slot released");

        // The proposer is un-blacklisted and settles the abandoned assertion directly on the OO.
        vm.clearMockedCalls();
        uint256 balanceBefore = usdc.balanceOf(user1);
        mockOOv3.settleAndGetAssertionResult(stuck); // must NOT revert

        assertEq(usdc.balanceOf(user1), balanceBefore + oracleUpgradeBondUsdc, "bond collected");

        // ...but the discarded proposal must not come back to life.
        (,, uint256 effectiveTs) = factory.queuedIdentifierUpgrade();
        assertEq(effectiveTs, 0, "expired proposal did not queue an upgrade");
        assertTrue(factory.umaIdentifier() != identifierOfStuck, "identifier untouched");
    }

    // -------------------- degraded mode (identifier de-whitelisted) --------------------

    /// @notice Fail closed: while the protocol's identifier is off UMA's live whitelist, a new
    ///         listing would be undisputable (auto-TRUE after 48h), so submission reverts instead.
    function testProposePairDeployment_RevertsWhileIdentifierDewhitelisted() public {
        bytes32 current = factory.umaIdentifier();
        mockOOv3.setIdentifierSupported(current, false);

        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__IdentifierNotWhitelisted.selector, current));
        factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE, "no funds moved");
    }

    /// @notice In healthy governance the upgrade assertion runs under the INCUMBENT identifier —
    ///         proposers never choose the adjudication identifier while things work.
    function testIdentifierUpgrade_AssertsUnderIncumbentWhenHealthy() public {
        bytes32 current = factory.umaIdentifier();

        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 aid = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        assertEq(mockOOv3.assertionIdentifier(aid), current, "asserted under the incumbent");
    }

    /// @notice When the incumbent has been de-whitelisted, an assertion under it would be
    ///         undisputable — first-proposer-wins governance. The upgrade proposal routes its
    ///         assertion under the PROPOSED (validated-live) identifier instead, so the recovery
    ///         proposal itself stays disputable. This is the one UMA submission that must never
    ///         gate on the incumbent being live: it is the repair path.
    function testIdentifierUpgrade_RoutesAssertionUnderProposedWhenIncumbentDead() public {
        bytes32 current = factory.umaIdentifier();
        mockOOv3.setIdentifierSupported(current, false);
        assertFalse(factory.umaIdentifierIsLive(), "degraded mode");

        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 aid = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        assertEq(mockOOv3.assertionIdentifier(aid), bytes32("ASSERT_TRUTH3"), "asserted under the proposed identifier");
    }

    /// @notice Full degraded-mode recovery: identifier dies → listings fail closed → the upgrade
    ///         (routed under the new identifier) runs its full cycle → listings resume.
    function testDegradedMode_FullRecoveryCycle() public {
        bytes32 current = factory.umaIdentifier();
        mockOOv3.setIdentifierSupported(current, false);

        // Listings fail closed.
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__IdentifierNotWhitelisted.selector, current));
        factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");

        // Governance still works: upgrade to a live identifier.
        bytes32 aid = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);
        factory.settleIdentifierUpgradeProposal(aid);
        vm.warp(block.timestamp + factory.IDENTIFIER_UPGRADE_TIMELOCK() + 1);
        factory.activateIdentifierUpgrade();

        assertEq(factory.umaIdentifier(), bytes32("ASSERT_TRUTH3"), "recovered onto the live identifier");
        assertTrue(factory.umaIdentifierIsLive(), "healthy again");

        // Listings resume.
        vm.prank(user1);
        bytes32 depId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        assertTrue(depId != bytes32(0), "listings resumed after recovery");
    }

    function testProposeUmaIdentifierUpgrade_RevertsWhilePending() public {
        // First proposal succeeds
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        // Second proposal reverts because liveness hasn't expired
        vm.startPrank(user2);
        usdc.approve(address(factory), type(uint256).max);

        vm.expectRevert(BazaarFactory.Factory__IdentifierUpgradeStillPending.selector);
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH4");
        vm.stopPrank();
    }

    function testProposeUmaIdentifierUpgrade_RevertsBeforeLivenessExpires() public {
        // First proposal
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        // Warp to 1 second before expiration — should revert
        vm.warp(block.timestamp + oracleUpgradeLiveness - 1);

        vm.startPrank(user2);
        usdc.approve(address(factory), type(uint256).max);
        vm.expectRevert(BazaarFactory.Factory__IdentifierUpgradeStillPending.selector);
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH4");
        vm.stopPrank();
    }

    function testProposeUmaIdentifierUpgrade_SettlesAtExactLiveness() public {
        // First proposal
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 firstId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        // Warp to exactly expiration time — settlement succeeds (>= check) and QUEUES the swap
        // behind the activation timelock.
        vm.warp(block.timestamp + oracleUpgradeLiveness);
        factory.settleIdentifierUpgradeProposal(firstId);
        (bytes32 qAid,, uint256 effectiveTs) = factory.queuedIdentifierUpgrade();
        assertEq(qAid, firstId, "queued at exact liveness");

        // A second proposal during the activation timelock reverts...
        vm.startPrank(user2);
        usdc.approve(address(factory), type(uint256).max);
        vm.expectRevert(BazaarFactory.Factory__IdentifierUpgradeStillPending.selector);
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH4");

        // ...and succeeds once it elapses, auto-activating the queued upgrade.
        vm.warp(effectiveTs);
        bytes32 secondId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH4");
        vm.stopPrank();

        assertTrue(secondId != bytes32(0));
        assertEq(factory.umaIdentifier(), bytes32("ASSERT_TRUTH3"), "first upgrade auto-activated");
    }

    function testProposeUmaIdentifierUpgrade_SucceedsAfterPreviousSettled() public {
        // First proposal
        uint256 user1BalanceBefore = usdc.balanceOf(user1);
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 firstAssertionId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        // Verify bond was deducted from user1
        assertEq(usdc.balanceOf(user1), user1BalanceBefore - oracleUpgradeBondUsdc);

        // Warp past liveness and settle: bond returns, upgrade QUEUES behind the timelock
        // (the identifier must not move yet).
        bytes32 oldIdentifier = factory.umaIdentifier();
        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);
        factory.settleIdentifierUpgradeProposal(firstAssertionId);
        assertEq(usdc.balanceOf(user1), user1BalanceBefore);
        assertEq(factory.umaIdentifier(), oldIdentifier, "swap deferred by the activation timelock");

        // First proposal should be resolved
        (,,, bool resolved, bool settlementResolution,) = factory.identifierUpgradeProposals(firstAssertionId);
        assertTrue(resolved);
        assertTrue(settlementResolution);

        // After the timelock, a second proposal auto-activates the first and succeeds.
        vm.warp(block.timestamp + factory.IDENTIFIER_UPGRADE_TIMELOCK() + 1);
        vm.startPrank(user2);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 secondAssertionId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH4");
        vm.stopPrank();

        assertTrue(secondAssertionId != bytes32(0));
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), secondAssertionId);

        // The first upgrade activated on the way in.
        assertEq(factory.umaIdentifier(), bytes32("ASSERT_TRUTH3"));
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

        // Seed is credited, not pushed — settlement must not depend on the deployer being able to
        // receive USDC. Balance moves only when they pull it.
        assertEq(factory.seedRefundOwed(user1), storedSeedAmountUsdc, "seed credited");
        assertEq(usdc.balanceOf(user1), user1BalanceBefore, "nothing pushed at settlement");

        vm.prank(user1);
        factory.claimSeedRefund();
        assertEq(usdc.balanceOf(user1), user1BalanceBefore + storedSeedAmountUsdc, "claimed");
        assertEq(factory.seedRefundOwed(user1), 0, "credit cleared");

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

    // ==================== settleIdentifierUpgradeProposal Tests ====================

    function testSettleIdentifierUpgradeProposal_Success() public {
        bytes32 newIdentifier = "ASSERT_TRUTH3";

        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 assertionId = factory.proposeUmaIdentifierUpgrade(newIdentifier);
        vm.stopPrank();

        // Warp past liveness
        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);

        // Settle — emits UmaIdentifierUpgradeQueued and defers the swap behind the timelock
        bytes32 oldIdentifier = factory.umaIdentifier();
        uint256 expectedEffectiveTs = block.timestamp + factory.IDENTIFIER_UPGRADE_TIMELOCK();
        vm.expectEmit(true, false, false, true, address(factory));
        emit BazaarFactory.UmaIdentifierUpgradeQueued(assertionId, newIdentifier, expectedEffectiveTs);
        factory.settleIdentifierUpgradeProposal(assertionId);

        // Verify resolved with true
        (,,, bool resolved, bool settlementResolution,) = factory.identifierUpgradeProposals(assertionId);
        assertTrue(resolved);
        assertTrue(settlementResolution);

        // Not swapped yet; pending assertion cleared; bond returned
        assertEq(factory.umaIdentifier(), oldIdentifier);
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), bytes32(0));
        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE);

        // Activation after the timelock emits UmaIdentifierUpgraded and performs the swap
        vm.warp(expectedEffectiveTs);
        vm.expectEmit(true, false, false, true, address(factory));
        emit BazaarFactory.UmaIdentifierUpgraded(assertionId, oldIdentifier, newIdentifier);
        factory.activateIdentifierUpgrade();

        assertEq(factory.umaIdentifier(), newIdentifier);
    }

    function testSettleIdentifierUpgradeProposal_RevertsNotFound() public {
        bytes32 fakeId = keccak256("nonexistent");

        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__ProposalNotFound.selector, fakeId));
        factory.settleIdentifierUpgradeProposal(fakeId);
    }

    function testSettleIdentifierUpgradeProposal_RevertsAlreadyResolved() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 assertionId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        vm.warp(block.timestamp + oracleUpgradeLiveness + 1);
        factory.settleIdentifierUpgradeProposal(assertionId);

        // Try to settle again
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__ProposalAlreadyResolved.selector, assertionId));
        factory.settleIdentifierUpgradeProposal(assertionId);
    }

    function testSettleIdentifierUpgradeProposal_DisputedAndRejected() public {
        bytes32 originalIdentifier = factory.umaIdentifier();

        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 assertionId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        // Dispute (disputer's bond must also match the upgrade bond)
        vm.startPrank(user2);
        usdc.approve(address(mockOOv3), oracleUpgradeBondUsdc);
        mockOOv3.disputeAssertion(assertionId, user2);
        vm.stopPrank();

        // DVM resolves against asserter
        mockOOv3.mockDvmResolve(assertionId, false);

        // Settle
        factory.settleIdentifierUpgradeProposal(assertionId);

        // Verify resolved with false
        (,,, bool resolved, bool settlementResolution,) = factory.identifierUpgradeProposals(assertionId);
        assertTrue(resolved);
        assertFalse(settlementResolution);

        // Verify identifier NOT changed
        assertEq(factory.umaIdentifier(), originalIdentifier);

        // Verify pending cleared
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), bytes32(0));

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

    function testIdentifierUpgradeProposal_DisputeEmitsEvent() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 assertionId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        // Dispute (disputer's bond must also match the upgrade bond)
        vm.startPrank(user2);
        usdc.approve(address(mockOOv3), oracleUpgradeBondUsdc);

        vm.expectEmit(true, false, false, false, address(factory));
        emit BazaarFactory.UmaIdentifierUpgradeDisputed(assertionId);
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

    function testGetIdentifierUpgradeProposal() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);
        bytes32 assertionId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        BazaarFactory.UmaIdentifierUpgradeProposal memory p = factory.getIdentifierUpgradeProposal(assertionId);
        assertEq(p.proposer, user1);
        assertEq(p.newIdentifier, bytes32("ASSERT_TRUTH3"));
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
            address(t),
            bytes32("ASSERT_TRUTH2")
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
            address(t),
            bytes32("ASSERT_TRUTH2")
        );
    }

    /// @notice The genesis identifier is validated against UMA's LIVE IdentifierWhitelist at
    ///         construction — a wrong value must fail the DEPLOY, not brick the protocol later.
    ///         (This is exactly what would have caught the unwhitelisted default on Arbitrum.)
    function test_constructor_RevertsOnNonWhitelistedGenesisIdentifier() public {
        MockUSDC u = new MockUSDC();
        MockOptimisticOracleV3 oo3 = new MockOptimisticOracleV3(address(u), 7200);
        oo3.setIdentifierSupported("DEAD_ID", false);

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        BazaarSequencer s = new BazaarSequencer(address(u), predicted);
        BazaarPairTerminator t = new BazaarPairTerminator(predicted);

        vm.expectRevert(
            abi.encodeWithSelector(BazaarFactory.Factory__IdentifierNotWhitelisted.selector, bytes32("DEAD_ID"))
        );
        new BazaarFactory(
            address(u),
            makeAddr("oracle"),
            makeAddr("lens"),
            makeAddr("bounty"),
            address(oo3),
            makeAddr("impl"),
            address(s),
            address(t),
            bytes32("DEAD_ID")
        );
    }

    // ---------------- adjudication-identifier rule (must start with "ASSERT_TRUTH") ----------------

    /// @notice The attack the rule exists for. UMA's IdentifierWhitelist is a "some UMIP defines
    ///         this" list, NOT a "safe to adjudicate truth assertions" list, so the whitelist gate
    ///         cannot reject a price feed. EURUSD is whitelisted on Arbitrum, and UMIP-29 scales it
    ///         to 18 decimals at 5-decimal rounding off a live FX source whose voters never read
    ///         ancillary data — at parity it resolves to exactly OOv3's `numericalTrue` (1e18).
    ///         Adopting it would invert the dispute layer for every listing, termination, and repair
    ///         proposal, silently and unrecoverably.
    function testProposeUmaIdentifierUpgrade_RevertsOnWhitelistedPriceFeed() public {
        bytes32 priceFeed = "EURUSD";
        // Whitelisted (the mock supports every identifier unless toggled off), so the ASSERT_TRUTH
        // rule is the ONLY thing standing between this value and the adjudicator slot.
        assertTrue(mockOOv3.isIdentifierSupported(priceFeed), "precondition: whitelisted");

        vm.startPrank(user1);
        usdc.approve(address(factory), oracleUpgradeBondUsdc);

        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__IdentifierNotAssertTruth.selector, priceFeed));
        factory.proposeUmaIdentifierUpgrade(priceFeed);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), INITIAL_USER_BALANCE, "rejected before the bond moves");
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), bytes32(0), "slot untouched");
    }

    /// @notice The rule matches the first 12 bytes exactly — no near-miss and no mid-string match.
    function testProposeUmaIdentifierUpgrade_AssertTruthPrefixBoundaries() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);

        // One byte short of the prefix.
        vm.expectRevert(
            abi.encodeWithSelector(BazaarFactory.Factory__IdentifierNotAssertTruth.selector, bytes32("ASSERT_TRUT"))
        );
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUT");

        // Contains the prefix, but not at the start.
        vm.expectRevert(
            abi.encodeWithSelector(BazaarFactory.Factory__IdentifierNotAssertTruth.selector, bytes32("XASSERT_TRUTH"))
        );
        factory.proposeUmaIdentifierUpgrade("XASSERT_TRUTH");

        // Exactly the prefix with no suffix passes the rule. On the real whitelist the live
        // de-whitelist gate is what rejects ASSERT_TRUTH; the mock whitelists everything.
        assertTrue(factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH") != bytes32(0), "exact prefix accepted");
        vm.stopPrank();
    }

    /// @notice Genesis is held to the same rule. The constructor's whitelist gate cannot catch a
    ///         deploy-script typo naming a whitelisted PRICE feed — which is precisely the
    ///         dangerous direction, since a dead identifier fails loudly at the first assertTruth
    ///         while a wrong-but-live one works perfectly until the first dispute.
    function test_constructor_RevertsOnNonAssertTruthGenesisIdentifier() public {
        MockUSDC u = new MockUSDC();
        MockOptimisticOracleV3 oo3 = new MockOptimisticOracleV3(address(u), 7200);
        // Deliberately left whitelisted: only the ASSERT_TRUTH rule can reject this.

        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        BazaarSequencer s = new BazaarSequencer(address(u), predicted);
        BazaarPairTerminator t = new BazaarPairTerminator(predicted);

        vm.expectRevert(
            abi.encodeWithSelector(BazaarFactory.Factory__IdentifierNotAssertTruth.selector, bytes32("EURUSD"))
        );
        new BazaarFactory(
            address(u),
            makeAddr("oracle"),
            makeAddr("lens"),
            makeAddr("bounty"),
            address(oo3),
            makeAddr("impl"),
            address(s),
            address(t),
            bytes32("EURUSD")
        );
    }

    // ---------------- UMA minimum bond tracking + the seed floor it must not eat ----------------

    /// @notice A hardcoded bond below UMA's minimum makes assertTruth revert and closes the listing
    ///         path entirely. The posted bond rises to track UMA instead.
    function testDeploymentBond_RisesToUmaMinimum() public {
        uint256 raised = bondUsdc * 3;
        mockOOv3.setMinimumBond(raised);
        assertEq(factory.requiredDeploymentBond(), raised, "bond tracks UMA upward");

        // Fund enough that the larger bond still leaves a viable seed.
        uint256 total = raised + seedUsdc;
        usdc.mint(user1, total);
        vm.startPrank(user1);
        usdc.approve(address(factory), total);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, total * 1e12, "ETH/USD");
        vm.stopPrank();

        assertTrue(assertionId != bytes32(0), "proposal accepted at the raised bond");
        assertEq(factory.getDeploymentProposal(assertionId).seedAmountUsdc, seedUsdc, "seed unaffected");
    }

    /// @notice UMA's minimum is a floor to rise to, never the bond to post: a cold OOv3 cache
    ///         reports 0, and posting that would leave the pair unseeded.
    function testDeploymentBond_FloorsAtBazaarConstantWhenUmaReportsZero() public {
        mockOOv3.setMinimumBond(0);
        assertEq(factory.requiredDeploymentBond(), bondUsdc, "never drops below Bazaar's floor");
    }

    /// @notice The seed floor is checked against the SEED, so a bond that grows to track UMA can
    ///         never silently push a proposal under BazaarPair's minimum. Before this, such a
    ///         proposal was accepted, escrowed, and then reverted inside the resolve callback —
    ///         unsettleable forever, seed stranded, pairId permanently unusable.
    function testDeploymentSeedFloor_RejectsWhenRaisedBondEatsIntoSeed() public {
        // Bond raised so that the old minimum total no longer leaves MIN_INSURANCE_SEED behind.
        mockOOv3.setMinimumBond(bondUsdc * 2);

        uint256 total = minDeploymentAmount / (BAZAAR_SCALE / USDC_SCALE); // exactly the old minimum
        vm.startPrank(user1);
        usdc.approve(address(factory), total);
        vm.expectRevert(BazaarFactory.Factory__SeedBelowMinimum.selector);
        factory.proposePairDeployment(ETH_USD_FEED_ID, true, minDeploymentAmount, "ETH/USD");
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(factory)), 0, "rejected before any escrow");
        assertEq(factory.pendingDeploymentByPairId(ETH_USD_FEED_ID), bytes32(0), "pairId untouched");
    }

    /// @notice The seed floor and BazaarPair's own check are the same constant, so a proposal that
    ///         passes the factory always survives initialize. Drives a minimum-sized listing all the
    ///         way to a deployed pair — the boundary a propose-only test never reaches.
    function testDeploymentSeedFloor_ExactMinimumDeploysEndToEnd() public {
        uint256 total = minDeploymentAmount / (BAZAAR_SCALE / USDC_SCALE);
        vm.startPrank(user1);
        usdc.approve(address(factory), total);
        bytes32 assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, minDeploymentAmount, "ETH/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);

        address pair = factory.getPairAddress(ETH_USD_FEED_ID);
        assertTrue(pair != address(0), "minimum-sized listing deploys");
        assertEq(
            factory.getDeploymentProposal(assertionId).seedAmount,
            BazaarTypes.MIN_INSURANCE_SEED,
            "seed sits exactly on the shared floor"
        );
    }

    function testIdentifierUpgradeBond_RisesToUmaMinimum() public {
        uint256 raised = oracleUpgradeBondUsdc * 2;
        mockOOv3.setMinimumBond(raised);
        assertEq(factory.requiredIdentifierUpgradeBond(), raised, "bond tracks UMA upward");

        usdc.mint(user1, raised);
        vm.startPrank(user1);
        usdc.approve(address(factory), raised);
        uint256 before = usdc.balanceOf(user1);
        bytes32 assertionId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH3");
        vm.stopPrank();

        assertTrue(assertionId != bytes32(0), "proposal accepted at the raised bond");
        assertEq(before - usdc.balanceOf(user1), raised, "the raised bond was actually pulled");
    }

    // ---------------- stuck deployment proposals: expiry + pull-payment refund ----------------

    /// @dev Make USDC transfers to `who` revert, the way a Circle blacklisting does.
    function _blacklist(address who, uint256 amount) internal {
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, who, amount),
            bytes("Blacklistable: blacklisted")
        );
    }

    function _proposeEth(address who) internal returns (bytes32) {
        vm.startPrank(who);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 id = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();
        return id;
    }

    /// @notice A deployer blacklisted after proposing blocks OOv3's bond payout, which reverts
    ///         settlement wholesale — the resolve callback never fires and the pairId would stay
    ///         occupied forever. Expiry releases it, credits the seed, and lets the asset be
    ///         listed again.
    function testExpireStuckDeployment_BlacklistedDeployer_ReleasesPairIdAndCreditsSeed() public {
        bytes32 assertionId = _proposeEth(user1);
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);

        _blacklist(user1, bondUsdc); // OOv3 returns the bond to the asserter first
        vm.expectRevert();
        factory.settleDeploymentProposal(assertionId);
        assertEq(factory.pendingDeploymentByPairId(ETH_USD_FEED_ID), assertionId, "slot stuck");

        vm.expectEmit(true, true, false, false, address(factory));
        emit BazaarFactory.PairDeploymentProposalExpired(assertionId, user1);
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);

        assertEq(factory.pendingDeploymentByPairId(ETH_USD_FEED_ID), bytes32(0), "pairId released");
        assertEq(factory.seedRefundOwed(user1), seedUsdc, "seed credited, not lost");
        assertEq(factory.getPairAddress(ETH_USD_FEED_ID), address(0), "no pair deployed");

        // The asset is listable again — the point of the whole exercise.
        vm.clearMockedCalls();
        assertTrue(_proposeEth(user2) != bytes32(0), "asset listable again");
    }

    /// @notice A blacklisted DISPUTER wedges the DVM-FALSE branch just as thoroughly, because OOv3
    ///         pays the disputer there. Expiry is the same escape.
    function testExpireStuckDeployment_BlacklistedDisputerOnFalseRuling() public {
        bytes32 assertionId = _proposeEth(user1);

        vm.startPrank(user2);
        usdc.approve(address(mockOOv3), bondUsdc);
        mockOOv3.disputeAssertion(assertionId, user2);
        vm.stopPrank();
        mockOOv3.mockDvmResolve(assertionId, false); // disputer wins → disputer is paid

        _blacklist(user2, bondUsdc * 2);
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + factory.DVM_DISPUTE_GRACE() + 1);

        vm.expectRevert();
        factory.settleDeploymentProposal(assertionId);

        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);
        assertEq(factory.pendingDeploymentByPairId(ETH_USD_FEED_ID), bytes32(0), "pairId released");
        assertEq(factory.seedRefundOwed(user1), seedUsdc, "deployer's seed still returned");
    }

    /// @notice A disputed proposal may not be discarded until the DVM has had its full life, or a
    ///         single bond becomes a guaranteed veto on any listing.
    function testExpireStuckDeployment_DisputedRequiresGrace() public {
        bytes32 assertionId = _proposeEth(user1);
        uint256 recordedTs = factory.getDeploymentProposal(assertionId).proposalTs;

        vm.startPrank(user2);
        usdc.approve(address(mockOOv3), bondUsdc);
        mockOOv3.disputeAssertion(assertionId, user2);
        vm.stopPrank();
        assertTrue(factory.deploymentDisputed(assertionId), "dispute recorded");

        // Past liveness but inside the grace: still protected.
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarFactory.Factory__DeploymentNotExpired.selector,
                recordedTs + factory.DEPLOYMENT_LIVENESS() + factory.DVM_DISPUTE_GRACE()
            )
        );
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);

        vm.warp(block.timestamp + factory.DVM_DISPUTE_GRACE());
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID); // DVM never resolved → unsettleable
        assertEq(factory.pendingDeploymentByPairId(ETH_USD_FEED_ID), bytes32(0), "released after grace");
    }

    /// @notice Expiry never discards a proposal that can still resolve: it settles it instead, so a
    ///         healthy listing deploys rather than being thrown away by a racing caller.
    function testExpireStuckDeployment_SettlesInsteadOfDiscardingWhenResolvable() public {
        _proposeEth(user1);
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);

        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);

        assertTrue(factory.getPairAddress(ETH_USD_FEED_ID) != address(0), "pair deployed, not discarded");
        assertEq(factory.seedRefundOwed(user1), 0, "seed went to the pair, not to a refund");
    }

    function testExpireStuckDeployment_RevertsBeforeLiveness() public {
        bytes32 assertionId = _proposeEth(user1);
        uint256 recordedTs = factory.getDeploymentProposal(assertionId).proposalTs;
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarFactory.Factory__DeploymentNotExpired.selector, recordedTs + factory.DEPLOYMENT_LIVENESS()
            )
        );
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);
    }

    function testExpireStuckDeployment_RevertsWithNoPendingProposal() public {
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__NoPendingDeployment.selector, ETH_USD_FEED_ID));
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);
    }

    /// @notice An expired proposal's assertion stays live on the OO. If it later settles, the
    ///         callback must stay silent: reverting would revert OOv3.settleAssertion and trap the
    ///         winner's bond, and acting on it would deploy a pair behind a replacement proposal's
    ///         back and clear that replacement's slot.
    function testLateSettlementAfterExpiry_IsSilentAndSparesReplacement() public {
        bytes32 stuckId = _proposeEth(user1);
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);

        _blacklist(user1, bondUsdc);
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);
        vm.clearMockedCalls();

        // A replacement proposal takes the freed slot.
        bytes32 freshId = _proposeEth(user2);
        assertEq(factory.pendingDeploymentByPairId(ETH_USD_FEED_ID), freshId, "replacement holds the slot");

        // The abandoned assertion finally settles once the deployer is un-blacklisted.
        mockOOv3.settleAndGetAssertionResult(stuckId); // must not revert

        assertEq(factory.pendingDeploymentByPairId(ETH_USD_FEED_ID), freshId, "replacement untouched");
        assertEq(factory.getPairAddress(ETH_USD_FEED_ID), address(0), "no pair from the abandoned proposal");
    }

    function testClaimSeedRefund_PaysOnlyTheCallerAndOnlyOnce() public {
        _proposeEth(user1);
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        _blacklist(user1, bondUsdc);
        factory.expireStuckDeploymentProposal(ETH_USD_FEED_ID);
        vm.clearMockedCalls();

        // Nobody else can pull it.
        vm.prank(user2);
        vm.expectRevert(BazaarFactory.Factory__NoSeedRefund.selector);
        factory.claimSeedRefund();

        uint256 before = usdc.balanceOf(user1);
        vm.prank(user1);
        factory.claimSeedRefund();
        assertEq(usdc.balanceOf(user1), before + seedUsdc, "refund paid");

        // And not twice.
        vm.prank(user1);
        vm.expectRevert(BazaarFactory.Factory__NoSeedRefund.selector);
        factory.claimSeedRefund();
    }
}
