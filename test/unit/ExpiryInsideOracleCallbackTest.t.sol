// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    OptimisticOracleV3Interface
} from "../../lib/protocol/packages/core/contracts/optimistic-oracle-v3/interfaces/OptimisticOracleV3Interface.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {
    IOptimisticOracleV3,
    IOptimisticOracleV3CallbackRecipient
} from "../../src/interfaces/IUmaOptimisticOracleV3.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";
import {PythSeed} from "../PythSeed.sol";

/// @dev Settles an assertion of its own on the oracle and, from inside the resolve callback that
///      settlement fires, calls one of the factory's expiry functions. The oracle holds its
///      reentrancy lock across the callback, so the settlement the factory attempts first is
///      rejected however healthy the target proposal is.
contract CallbackExpirer is IOptimisticOracleV3CallbackRecipient {
    MockOptimisticOracleV3 internal immutable oo;
    BazaarFactory internal immutable factory;

    bytes32 internal targetPairId; // zero targets the identifier-upgrade track
    bool public reachedFactory;

    constructor(MockOptimisticOracleV3 oo_, BazaarFactory factory_) {
        oo = oo_;
        factory = factory_;
    }

    function run(bytes32 pairId) external {
        targetPairId = pairId;
        // Zero liveness and zero bond: settleable in the block it is made.
        bytes32 own = oo.assertTruth(
            "bait", address(this), address(this), address(0), 0, oo.currency(), 0, oo.defaultIdentifier(), bytes32(0)
        );
        oo.settleAndGetAssertionResult(own);
    }

    function assertionResolvedCallback(bytes32, bool) external override {
        if (targetPairId == bytes32(0)) factory.expireStuckIdentifierUpgradeProposal();
        else factory.expireStuckDeploymentProposal(targetPairId);
        reachedFactory = true;
    }

    function assertionDisputedCallback(bytes32) external override {}
}

/// @notice The expiry functions called from inside one of the oracle's own callbacks, where the
///         settlement they attempt first cannot succeed. An undisputed proposal past liveness must
///         come out approved, exactly as a settlement would have left it, and never discarded.
contract ExpiryInsideOracleCallbackTest is Test {
    bytes32 constant ETH_USD_FEED_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;

    uint256 constant PROPOSAL_TOTAL = 5_000e18;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000e6;
    uint256 constant INITIAL_BALANCE = 100_000e6;

    BazaarFactory factory;
    MockUSDC usdc;
    MockOptimisticOracleV3 mockOOv3;
    CallbackExpirer expirer;

    address alice;
    address bob;

    uint256 bondUsdc;
    uint256 seedUsdc;
    uint256 upgradeBondUsdc;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        DeployBazaar deployer = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = deployer.deploy(makeAddr("bugBounty"));
        (, address usdcContract, address oo3,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcContract);
        mockOOv3 = MockOptimisticOracleV3(oo3);
        expirer = new CallbackExpirer(mockOOv3, factory);

        PythSeed.seed(address(factory.oracle().pyth()), ETH_USD_FEED_ID);

        bondUsdc = factory.DEPLOYMENT_BOND_USDC();
        seedUsdc = PROPOSAL_TOTAL_USDC - bondUsdc;
        upgradeBondUsdc = factory.IDENTIFIER_UPGRADE_BOND_USDC();

        usdc.mint(alice, INITIAL_BALANCE);
        usdc.mint(bob, INITIAL_BALANCE);
    }

    function _proposeEth(address who) internal returns (bytes32 assertionId) {
        vm.startPrank(who);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        assertionId = factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();
    }

    function _proposeUpgrade(address who, bytes32 identifier) internal returns (bytes32 assertionId) {
        vm.startPrank(who);
        usdc.approve(address(factory), upgradeBondUsdc);
        assertionId = factory.proposeUmaIdentifierUpgrade(identifier);
        vm.stopPrank();
    }

    // -------------------- deployment track --------------------

    /// @notice A healthy listing that has just cleared liveness is expired from inside an oracle
    ///         callback. The nested settlement is rejected by the oracle's lock, and the factory
    ///         deploys the pair anyway: the caller gets no veto.
    function test_deployment_expiryInsideCallback_deploysThePair() public {
        bytes32 assertionId = _proposeEth(alice);
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS());

        vm.expectEmit(true, false, false, true, address(factory));
        emit BazaarFactory.PairDeploymentProposalResolved(assertionId, true, true);
        expirer.run(ETH_USD_FEED_ID);

        assertTrue(expirer.reachedFactory(), "the expiry ran inside the callback");
        assertFalse(mockOOv3.getAssertion(assertionId).settled, "the oracle's lock rejected the nested settlement");

        address pair = factory.getPairAddress(ETH_USD_FEED_ID);
        assertTrue(pair != address(0), "pair deployed, not discarded");
        assertEq(factory.pendingDeploymentByPairId(ETH_USD_FEED_ID), bytes32(0), "pairId released");
        assertEq(factory.seedRefundOwed(alice), 0, "seed went to the pair, not to a refund");
        assertEq(usdc.balanceOf(pair), seedUsdc, "pair holds the seed");
        assertEq(BazaarPair(payable(pair)).totalInsuranceShares(), seedUsdc * 1e12, "seed shares issued");
        BazaarFactory.PairDeploymentProposal memory p = factory.getDeploymentProposal(assertionId);
        assertTrue(p.resolved && p.deployed, "proposal recorded as approved and deployed");
    }

    /// @notice The assertion the expiry approved is still unsettled on the oracle. Settling it
    ///         afterwards pays the deployer's bond and leaves the deployed pair as it is.
    function test_deployment_expiryInsideCallback_bondCollectedBySettlingLater() public {
        bytes32 assertionId = _proposeEth(alice);
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS());
        expirer.run(ETH_USD_FEED_ID);

        address pair = factory.getPairAddress(ETH_USD_FEED_ID);
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - PROPOSAL_TOTAL_USDC, "bond still on the oracle");

        mockOOv3.settleAndGetAssertionResult(assertionId); // must not revert

        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - seedUsdc, "bond returned");
        assertEq(factory.getPairAddress(ETH_USD_FEED_ID), pair, "same pair");
        assertEq(usdc.balanceOf(pair), seedUsdc, "seed not moved twice");
        assertEq(factory.seedRefundOwed(alice), 0, "no refund credited by the late callback");
    }

    /// @notice The asset is listed, so a second proposal for it is refused: the caller has not
    ///         freed the slot for a listing of its own.
    function test_deployment_expiryInsideCallback_assetStaysListed() public {
        _proposeEth(alice);
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS());
        expirer.run(ETH_USD_FEED_ID);

        vm.startPrank(bob);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__PairAlreadyExists.selector, ETH_USD_FEED_ID));
        factory.proposePairDeployment(ETH_USD_FEED_ID, true, PROPOSAL_TOTAL, "ETH/USD");
        vm.stopPrank();
    }

    /// @notice Inside liveness the expiry is refused before it reads anything, so the caller's own
    ///         settlement reverts with it and the proposal is untouched.
    function test_deployment_expiryInsideCallback_beforeLiveness_reverts() public {
        bytes32 assertionId = _proposeEth(alice);
        uint256 expiryTs = factory.getDeploymentProposal(assertionId).proposalTs + factory.DEPLOYMENT_LIVENESS();
        vm.warp(expiryTs - 1);

        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__DeploymentNotExpired.selector, expiryTs));
        expirer.run(ETH_USD_FEED_ID);

        assertEq(factory.pendingDeploymentByPairId(ETH_USD_FEED_ID), assertionId, "still pending");
        assertEq(factory.getPairAddress(ETH_USD_FEED_ID), address(0), "nothing deployed early");
    }

    /// @notice A disputed proposal is not approved by this path. Past the dispute grace, with the
    ///         DVM still silent, the expiry discards it and refunds the seed whether it is called
    ///         directly or from inside a callback.
    function test_deployment_expiryInsideCallback_disputed_isDiscarded() public {
        bytes32 assertionId = _proposeEth(alice);
        vm.startPrank(bob);
        usdc.approve(address(mockOOv3), bondUsdc);
        mockOOv3.disputeAssertion(assertionId, bob);
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + factory.DVM_DISPUTE_GRACE());
        vm.expectEmit(true, true, false, false, address(factory));
        emit BazaarFactory.PairDeploymentProposalExpired(assertionId, alice);
        expirer.run(ETH_USD_FEED_ID);

        assertEq(factory.getPairAddress(ETH_USD_FEED_ID), address(0), "no pair deployed");
        assertEq(factory.seedRefundOwed(alice), seedUsdc, "seed refunded");
    }

    // -------------------- identifier-upgrade track --------------------

    /// @notice The same call against the single upgrade slot: the unchallenged proposal is queued
    ///         behind its timelock, not discarded, and activates when the timelock runs out.
    function test_upgrade_expiryInsideCallback_queuesTheUpgrade() public {
        bytes32 assertionId = _proposeUpgrade(alice, "ASSERT_TRUTH5");
        vm.warp(block.timestamp + factory.IDENTIFIER_UPGRADE_LIVENESS());

        uint256 effectiveTs = vm.getBlockTimestamp() + factory.IDENTIFIER_UPGRADE_TIMELOCK();
        vm.expectEmit(true, false, false, true, address(factory));
        emit BazaarFactory.UmaIdentifierUpgradeQueued(assertionId, "ASSERT_TRUTH5", effectiveTs);
        expirer.run(bytes32(0));

        assertTrue(expirer.reachedFactory(), "the expiry ran inside the callback");
        assertFalse(mockOOv3.getAssertion(assertionId).settled, "the oracle's lock rejected the nested settlement");

        assertEq(factory.pendingIdentifierUpgradeAssertionId(), bytes32(0), "slot released");
        (bytes32 queuedId, bytes32 queuedIdentifier, uint256 queuedTs) = factory.queuedIdentifierUpgrade();
        assertEq(queuedId, assertionId, "approved upgrade queued, not discarded");
        assertEq(queuedIdentifier, bytes32("ASSERT_TRUTH5"), "its identifier is queued");
        assertEq(queuedTs, effectiveTs, "behind the usual timelock");
        (,,, bool resolved, bool settlementResolution,) = factory.identifierUpgradeProposals(assertionId);
        assertTrue(resolved && settlementResolution, "proposal recorded as approved");

        vm.warp(effectiveTs);
        factory.activateIdentifierUpgrade();
        assertEq(factory.umaIdentifier(), bytes32("ASSERT_TRUTH5"), "upgrade activated");
    }

    /// @notice Settling the approved assertion afterwards returns the proposer's bond and does not
    ///         restart the timelock.
    function test_upgrade_expiryInsideCallback_bondCollectedBySettlingLater() public {
        bytes32 assertionId = _proposeUpgrade(alice, "ASSERT_TRUTH5");
        vm.warp(block.timestamp + factory.IDENTIFIER_UPGRADE_LIVENESS());
        expirer.run(bytes32(0));
        (,, uint256 queuedTs) = factory.queuedIdentifierUpgrade();
        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE - upgradeBondUsdc, "bond still on the oracle");

        vm.warp(vm.getBlockTimestamp() + 1 days);
        mockOOv3.settleAndGetAssertionResult(assertionId); // must not revert

        assertEq(usdc.balanceOf(alice), INITIAL_BALANCE, "bond returned");
        (bytes32 queuedIdAfter,, uint256 queuedTsAfter) = factory.queuedIdentifierUpgrade();
        assertEq(queuedIdAfter, assertionId, "still the queued upgrade");
        assertEq(queuedTsAfter, queuedTs, "timelock not restarted");
    }

    // -------------------- the facts the verdict rests on --------------------

    /// @notice What the factory reads back for an unchallenged proposal past liveness, and why it
    ///         is final: the oracle takes no dispute from the expiration instant on.
    function test_oracleRecord_undisputedPastLiveness_cannotBeDisputed() public {
        bytes32 assertionId = _proposeEth(alice);
        uint256 expiryTs = factory.getDeploymentProposal(assertionId).proposalTs + factory.DEPLOYMENT_LIVENESS();

        IOptimisticOracleV3.Assertion memory a = mockOOv3.getAssertion(assertionId);
        assertEq(a.asserter, alice, "asserter");
        assertEq(a.callbackRecipient, address(factory), "callback recipient");
        assertEq(a.disputer, address(0), "undisputed");
        assertEq(a.expirationTime, expiryTs, "the oracle's expiration is the factory's own liveness end");
        assertFalse(a.settled, "unsettled");

        vm.warp(expiryTs);
        vm.startPrank(bob);
        usdc.approve(address(mockOOv3), bondUsdc);
        vm.expectRevert(MockOptimisticOracleV3.Assertion__Expired.selector);
        mockOOv3.disputeAssertion(assertionId, bob);
        vm.stopPrank();
    }

    /// @notice The factory decodes the oracle's assertion record through the local struct
    ///         declaration, and the mock returns it through the same one. A declaration that
    ///         drifted from UMA's would decode the wrong words without reverting, so it is checked
    ///         here against UMA's own struct, encoded with a distinct value in every field.
    function test_assertionLayout_matchesUmasStruct() public pure {
        OptimisticOracleV3Interface.Assertion memory real = OptimisticOracleV3Interface.Assertion({
            escalationManagerSettings: OptimisticOracleV3Interface.EscalationManagerSettings({
                arbitrateViaEscalationManager: true,
                discardOracle: false,
                validateDisputers: true,
                assertingCaller: address(0xA1),
                escalationManager: address(0xA2)
            }),
            asserter: address(0xB1),
            assertionTime: 11,
            settled: true,
            currency: IERC20(address(0xB2)),
            expirationTime: 22,
            settlementResolution: true,
            domainId: bytes32(uint256(33)),
            identifier: bytes32(uint256(44)),
            bond: 55,
            callbackRecipient: address(0xB3),
            disputer: address(0xB4)
        });
        bytes memory encoded = abi.encode(real);
        assertEq(encoded.length, 16 * 32, "sixteen static words");

        IOptimisticOracleV3.Assertion memory ours = abi.decode(encoded, (IOptimisticOracleV3.Assertion));
        assertTrue(ours.escalationManagerSettings.arbitrateViaEscalationManager, "arbitrateViaEscalationManager");
        assertFalse(ours.escalationManagerSettings.discardOracle, "discardOracle");
        assertTrue(ours.escalationManagerSettings.validateDisputers, "validateDisputers");
        assertEq(ours.escalationManagerSettings.assertingCaller, address(0xA1), "assertingCaller");
        assertEq(ours.escalationManagerSettings.escalationManager, address(0xA2), "escalationManager");
        assertEq(ours.asserter, real.asserter, "asserter");
        assertEq(ours.assertionTime, real.assertionTime, "assertionTime");
        assertTrue(ours.settled, "settled");
        assertEq(address(ours.currency), address(real.currency), "currency");
        assertEq(ours.expirationTime, real.expirationTime, "expirationTime");
        assertTrue(ours.settlementResolution, "settlementResolution");
        assertEq(ours.domainId, real.domainId, "domainId");
        assertEq(ours.identifier, real.identifier, "identifier");
        assertEq(ours.bond, real.bond, "bond");
        assertEq(ours.callbackRecipient, real.callbackRecipient, "callbackRecipient");
        assertEq(ours.disputer, real.disputer, "disputer");
    }
}
