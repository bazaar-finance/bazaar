// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IOptimisticOracleV3} from "../../src/interfaces/IUmaOptimisticOracleV3.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {OwnedMockOptimisticOracleV3} from "../mocks/OwnedMockOptimisticOracleV3.sol";

/// @notice The oracle the Arbitrum Sepolia config deploys: its four override helpers answer to the
///         owner alone, and the paths OOv3 itself leaves open stay open.
contract OwnedMockOptimisticOracleV3Test is Test {
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    uint64 internal constant LIVENESS = 7200;

    OwnedMockOptimisticOracleV3 internal oo;
    address internal operator = makeAddr("operator");

    function setUp() public {
        oo = new OwnedMockOptimisticOracleV3(address(new MockUSDC()), LIVENESS, operator);
    }

    function _assertion() internal returns (bytes32) {
        return oo.assertTruthWithDefaults("", makeAddr("asserter"), address(0));
    }

    function _disputedAssertion() internal returns (bytes32 id) {
        id = _assertion();
        oo.disputeAssertion(id, makeAddr("disputer"));
    }

    function _expectNotOwner(address caller) internal {
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }

    /// @notice The Sepolia config deploys the owned variant with the broadcaster as owner. A
    ///         broadcast with no explicit signer sends from tx.origin, which a real run sets to its
    ///         `--sender`; `owner()` exists only on the owned variant, so the read also proves
    ///         which contract was deployed.
    function test_sepoliaConfig_deploysOracleOwnedByBroadcaster() public {
        vm.chainId(ARBITRUM_SEPOLIA);
        HelperConfig config = new HelperConfig();
        (,, address deployed,) = config.activeNetworkConfig();

        OwnedMockOptimisticOracleV3 sepoliaOo = OwnedMockOptimisticOracleV3(deployed);
        assertEq(sepoliaOo.owner(), tx.origin, "broadcaster owns the Sepolia oracle");

        address stranger = makeAddr("stranger");
        _expectNotOwner(stranger);
        sepoliaOo.setMinimumBond(1);
    }

    /// @notice Each helper refuses every caller but the owner. The assertions are real and
    ///         settleable, so a helper that lost its gate would succeed here rather than revert for
    ///         an unrelated reason.
    function testFuzz_helpers_refuseNonOwner(address caller) public {
        vm.assume(caller != operator);
        bytes32 undisputed = _assertion();
        bytes32 disputed = _disputedAssertion();

        _expectNotOwner(caller);
        oo.mockForceSettle(undisputed, false);

        _expectNotOwner(caller);
        oo.mockDvmResolve(disputed, false);

        _expectNotOwner(caller);
        oo.setIdentifierSupported("ASSERT_TRUTH2", false);

        _expectNotOwner(caller);
        oo.setMinimumBond(1);
    }

    function test_owner_forceSettles() public {
        bytes32 id = _assertion();

        vm.prank(operator);
        oo.mockForceSettle(id, false);

        IOptimisticOracleV3.Assertion memory a = oo.getAssertion(id);
        assertTrue(a.settled, "settled");
        assertFalse(a.settlementResolution, "owner's result");
    }

    /// @notice The owner's resolution decides the dispute; the settlement that reads it stays open
    ///         to anyone, as on OOv3.
    function test_owner_resolvesDispute() public {
        bytes32 id = _disputedAssertion();

        vm.prank(operator);
        oo.mockDvmResolve(id, false);

        vm.prank(makeAddr("anyone"));
        assertFalse(oo.settleAndGetAssertionResult(id), "owner's resolution");
    }

    function test_owner_setsIdentifierAndMinimumBond() public {
        vm.startPrank(operator);
        oo.setIdentifierSupported("ASSERT_TRUTH2", false);
        oo.setMinimumBond(250e6);
        vm.stopPrank();

        assertFalse(oo.isIdentifierSupported("ASSERT_TRUTH2"), "identifier de-whitelisted");
        assertEq(oo.getMinimumBond(address(oo.currency())), 250e6, "minimum bond");
    }

    /// @notice An undisputed assertion still settles true after liveness for any caller: the gate
    ///         covers only the helpers that bypass OOv3's own rules.
    function test_undisputedSettlement_staysOpen() public {
        bytes32 id = _assertion();
        vm.warp(block.timestamp + LIVENESS);

        vm.prank(makeAddr("anyone"));
        assertTrue(oo.settleAndGetAssertionResult(id), "settles true after liveness");
    }
}
