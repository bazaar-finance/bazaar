// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";

/// @notice Every way the single-slot UMA identifier-upgrade pipeline can be jammed, and the bound
///         on each: a settlement that can never succeed, a poisoned identifier value, and a
///         well-formed proposal filed purely to hold the slot.
contract IdentifierUpgradeBrickTest is Test {
    BazaarFactory public factory;
    MockUSDC public usdc;
    MockOptimisticOracleV3 public mockOOv3;

    address public user1;
    address public user2;
    address public mallory;

    uint256 bond;
    uint64 liveness;
    uint256 timelock;

    function setUp() public {
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        mallory = makeAddr("mallory");

        DeployBazaar deployer = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = deployer.deploy(makeAddr("bugBounty"));
        (, address usdcContract, address oo3,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcContract);
        mockOOv3 = MockOptimisticOracleV3(oo3);

        bond = factory.IDENTIFIER_UPGRADE_BOND_USDC();
        liveness = factory.IDENTIFIER_UPGRADE_LIVENESS();
        timelock = factory.IDENTIFIER_UPGRADE_TIMELOCK();

        usdc.mint(user1, 1_000_000e6);
        usdc.mint(user2, 1_000_000e6);
        usdc.mint(mallory, 1_000_000e6);
    }

    /// A proposer who becomes USDC-blacklisted after asserting can never be paid the bond back, so
    /// settleAssertion reverts on the payout to the asserter, the resolve callback never fires, and
    /// the single pendingIdentifierUpgradeAssertionId slot is never cleared. Nothing else can clear
    /// it — no owner, no timeout on the assertion, and `oo` is immutable — so absent
    /// expireStuckIdentifierUpgradeProposal the jam would be permanent and the identifier could
    /// never move again. This walks the whole jam, then shows the expiry releasing the slot.
    function test_BlacklistedProposerStallsUpgradePathUntilExpiry() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 idU = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH5");
        vm.stopPrank();
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), idU, "slot occupied");

        // Circle blacklists user1 AFTER the assertion is live. USDC transfers TO user1 revert.
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, user1, bond),
            bytes("Blacklistable: blacklisted")
        );

        vm.warp(block.timestamp + liveness + 1);

        // Settlement is now permanently impossible: OOv3/mock pays the asserter BEFORE the callback.
        vm.expectRevert();
        factory.settleIdentifierUpgradeProposal(idU);

        // Ten years later, nothing has changed. Every future proposal reverts.
        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert();
        factory.settleIdentifierUpgradeProposal(idU);

        assertEq(factory.pendingIdentifierUpgradeAssertionId(), idU, "slot STILL occupied");

        vm.startPrank(user2);
        usdc.approve(address(factory), type(uint256).max);
        vm.expectRevert(BazaarFactory.Factory__IdentifierUpgradeStillPending.selector);
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH6");
        vm.stopPrank();

        // No repair path: nothing is queued, so activateIdentifierUpgrade cannot move the identifier.
        vm.expectRevert(BazaarFactory.Factory__NoQueuedIdentifierUpgrade.selector);
        factory.activateIdentifierUpgrade();

        (,, uint256 effTs) = factory.queuedIdentifierUpgrade();
        assertEq(effTs, 0, "nothing queued");
        assertEq(factory.umaIdentifier(), bytes32("ASSERT_TRUTH2"), "identifier frozen at genesis value");

        // A restore-the-incumbent lever would not help here: what is stuck is the pending slot, not
        // the identifier, and the live identifier is still whitelisted. The expiry is the whole
        // recovery.

        // This proposal was never disputed, so a settlement that keeps failing past liveness is
        // proof the payout itself is blocked rather than evidence of an unresolved dispute — anyone
        // may discard it immediately, no grace period, and governance resumes.
        factory.expireStuckIdentifierUpgradeProposal();
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), bytes32(0), "slot finally released");

        vm.prank(user2);
        assertTrue(factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH6") != bytes32(0), "governance resumed");
    }

    /// If the assertion is DISPUTED and the DVM rules TRUE, the payout still goes to the
    /// blacklisted asserter -> the same permanent jam. Disputing is not an escape hatch, which is
    /// why the expiry lever cannot be conditioned on the proposal having gone undisputed forever.
    function test_DisputeDoesNotRescueWhenDvmRulesTrue() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 idU = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH5");
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(mockOOv3), type(uint256).max);
        mockOOv3.disputeAssertion(idU, user2);
        vm.stopPrank();
        mockOOv3.mockDvmResolve(idU, true);

        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, user1, bond * 2),
            bytes("Blacklistable: blacklisted")
        );

        vm.expectRevert();
        factory.settleIdentifierUpgradeProposal(idU);
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), idU, "slot stuck after truthful dispute");
    }

    /// Identifier poisoning is unreachable. Every proposed identifier is validated against UMA's
    /// LIVE IdentifierWhitelist before the bond moves, so an arbitrary junk bytes32 — which would
    /// otherwise clear the internal guards and, once activated, brick every assertTruth call-site —
    /// dies at the door. The oracle contract is not a second axis for the same attack: `oo` is
    /// immutable, so there is no path to swap in a malicious oracle at all.
    function test_IdentifierPoisoningIsUnreachable() public {
        bytes32 identifierBefore = factory.umaIdentifier();
        // Prefixed so this exercises the WHITELIST gate specifically: a non-prefixed value is
        // rejected earlier, by the ASSERT_TRUTH rule.
        bytes32 junk = "ASSERT_TRUTH_NOT_WHITELISTED";
        mockOOv3.setIdentifierSupported(junk, false);

        vm.startPrank(mallory);
        usdc.approve(address(factory), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__IdentifierNotWhitelisted.selector, junk));
        factory.proposeUmaIdentifierUpgrade(junk);
        vm.stopPrank();

        assertEq(usdc.balanceOf(mallory), 1_000_000e6, "no bond moved");
        assertEq(factory.umaIdentifier(), identifierBefore, "identifier untouched");

        // An upgrade that IS accepted can only carry a whitelisted identifier — and because the
        // whitelist is a mutable external fact, one that gets de-whitelisted between proposal and
        // activation is re-checked and canceled at activation rather than adopted.
        vm.startPrank(mallory);
        bytes32 idM = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH5");
        vm.stopPrank();

        vm.warp(block.timestamp + liveness + 1);
        factory.settleIdentifierUpgradeProposal(idM);
        vm.warp(block.timestamp + timelock);
        factory.activateIdentifierUpgrade();

        assertEq(factory.umaIdentifier(), bytes32("ASSERT_TRUTH5"), "whitelisted identifier adopted");
    }

    /// The residual cost of a single-slot pipeline: occupying the slot stalls honest emergency
    /// migration for the full liveness window, and absent a disputer the grief costs nothing. The
    /// whitelist gate bounds which VALUE can be proposed, not who may hold the slot, so a
    /// well-formed proposal filed only to block others is still admitted.
    function test_AttackerStallsGovernanceForFullLiveness() public {
        vm.startPrank(mallory);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 idM = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH9");
        vm.stopPrank();
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), idM);

        // Honest emergency migration is blocked for the whole liveness window.
        bytes32 good = "ASSERT_TRUTH7";
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        vm.warp(block.timestamp + liveness - 1);
        vm.expectRevert(BazaarFactory.Factory__IdentifierUpgradeStillPending.selector);
        factory.proposeUmaIdentifierUpgrade(good);
        vm.stopPrank();

        // Undisputed -> settles TRUE and queues, blocking another 14 days.
        vm.warp(block.timestamp + 2);
        factory.settleIdentifierUpgradeProposal(idM);
        (,, uint256 effTs) = factory.queuedIdentifierUpgrade();
        assertEq(effTs, block.timestamp + timelock);

        vm.startPrank(user1);
        vm.expectRevert(BazaarFactory.Factory__IdentifierUpgradeStillPending.selector);
        factory.proposeUmaIdentifierUpgrade(good);
        vm.stopPrank();

        // Mallory's 5k bond was returned in full (undisputed truthful settlement).
        assertEq(usdc.balanceOf(mallory), 1_000_000e6, "grief was free absent a disputer");
    }

    /// The try-settle inside proposeUmaIdentifierUpgrade cannot advance a matured TRUTHFUL pending
    /// proposal: settling it queues the upgrade, the queued-upgrade timelock guard immediately
    /// after then reverts because the timelock has not elapsed, and the whole tx — settlement
    /// included — rolls back. Only the standalone permissionless settler moves such a proposal
    /// forward, which is why it exists as its own entry point.
    function test_TrySettleIsInertForTruthfulPending() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), type(uint256).max);
        bytes32 idU = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH5");
        vm.stopPrank();

        vm.warp(block.timestamp + liveness + 1);

        vm.startPrank(user2);
        usdc.approve(address(factory), type(uint256).max);
        vm.expectRevert(BazaarFactory.Factory__IdentifierUpgradeStillPending.selector);
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH6");
        vm.stopPrank();

        // Settlement was rolled back with the outer revert.
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), idU, "settlement rolled back");
        (,, uint256 effTs) = factory.queuedIdentifierUpgrade();
        assertEq(effTs, 0, "nothing queued despite a matured truthful proposal");

        // But the standalone permissionless settler works fine, so this is only cosmetic.
        factory.settleIdentifierUpgradeProposal(idU);
        assertEq(factory.pendingIdentifierUpgradeAssertionId(), bytes32(0));
    }
}
