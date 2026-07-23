// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";

/// @notice The disputed-then-UPHELD termination path — only the dispute-resolved-FALSE side was
///         covered (GovernanceIntegrationTest). When the DVM sides with the proposer, the callback
///         must still schedule the pair and route BOTH bonds to the asserter; a bug here either
///         strands the pair (censorship-resistant delisting fails) or mis-routes the forfeited bond.
contract TerminatorDisputeUpheldTest is IntegrationBase {
    BazaarPairTerminator internal terminator;
    MockOptimisticOracleV3 internal mockOO;

    function setUp() public override {
        super.setUp();
        terminator = factory.pairTerminator();
        mockOO = MockOptimisticOracleV3(address(factory.oo()));
    }

    function _bondProposer(address proposer) internal {
        uint256 bond = terminator.TERMINATION_PROPOSAL_BOND();
        usdc.mint(proposer, bond);
        vm.prank(proposer);
        usdc.approve(address(terminator), bond);
    }

    function test_e2e_DisputedTermination_ResolvedTrue_SchedulesAndAsserterNetsBonds() public {
        _bondProposer(alice);
        uint256 lastTradingTs = vm.getBlockTimestamp() + 7 days;
        vm.prank(alice);
        bytes32 aid = terminator.proposeTermination(address(pair), "BTC/USD", lastTradingTs, "Legit delisting.");
        uint256 aliceAfterPropose = usdc.balanceOf(alice); // bond now escrowed in the OO

        // Bob disputes with a matching bond; the DVM upholds the PROPOSER (resolves true).
        uint256 bond = terminator.TERMINATION_PROPOSAL_BOND();
        usdc.mint(bob, bond);
        uint256 bobStart = usdc.balanceOf(bob);
        vm.startPrank(bob);
        usdc.approve(address(mockOO), bond);
        mockOO.disputeAssertion(aid, bob);
        vm.stopPrank();
        mockOO.mockDvmResolve(aid, true);

        terminator.settleTerminationProposal(aid);

        // The upheld assertion schedules the pair — the branch the false case never reaches.
        assertEq(pair.scheduledTerminationTs(), lastTradingTs, "upheld assertion schedules termination");
        assertFalse(pair.isPairTerminatedNormal(), "scheduled, not yet executed");

        // Asserter (alice) recovers her bond AND nets bob's forfeited bond (plus the tiny proposer
        // reward paid on scheduling), so her gain is at least 2× the bond.
        assertGe(usdc.balanceOf(alice), aliceAfterPropose + 2 * bond, "asserter nets both bonds");
        // The disputer forfeits his bond.
        assertEq(usdc.balanceOf(bob), bobStart - bond, "losing disputer forfeits his bond");
    }
}
