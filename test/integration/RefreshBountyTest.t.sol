// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";

/// @title RefreshBountyTest
/// @notice Covers the insurance-funded refreshPrice bounty (RiskParamsLib.payRefreshBounty):
///         a caller whose refresh stores a fresh price after a >10min gap on a pair with >$10,000
///         OI notional and >$10,000 insurance earns $0.25 from the insurance fund. Each gate is
///         exercised, plus the books invariant (the deduction and the USDC leaving the pair must
///         move together).
contract RefreshBountyTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BOUNTY = 0.25e18; // = RiskParamsLib.REFRESH_BOUNTY
    uint256 constant BOUNTY_USDC = 0.25e6;
    uint256 constant GAP = 10 minutes;

    address keeper;

    function setUp() public override {
        super.setUp();
        keeper = makeAddr("keeper");
    }

    /// @dev Qualifying baseline: 0.5 BTC each side at $50k ($50k OI notional) and $10,000 insurance
    ///      on top of the deployment seed. Both clear their floors with room to spare.
    function _qualifyPair() internal {
        _openPosition(alice, bob, true, BAZAAR_SCALE / 2);
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
    }

    function _refreshAsKeeper() internal {
        bytes[] memory pu = _freshPrice(); // build BEFORE the prank (external mockPyth call would consume it)
        vm.prank(keeper);
        pair.refreshPrice(pu);
    }

    // ==================== paying path ====================

    function test_RefreshBounty_PaidWhenAllGatesPass() public {
        _qualifyPair();
        uint256 insuranceBefore = _insuranceBal();
        assertEq(usdc.balanceOf(keeper), 0, "keeper starts empty");

        vm.warp(vm.getBlockTimestamp() + GAP + 1);

        bytes[] memory pu = _freshPrice();
        vm.expectEmit(true, false, false, true, address(pair));
        emit RiskParamsLib.RefreshBountyPaid(keeper, BOUNTY);
        vm.prank(keeper);
        pair.refreshPrice(pu);

        assertEq(usdc.balanceOf(keeper), BOUNTY_USDC, "keeper received $0.25");
        assertEq(_insuranceBal(), insuranceBefore - BOUNTY, "insurance debited exactly the bounty");
        _assertBooksSettled("after paid bounty");
    }

    function test_RefreshBounty_PaysAgainAfterNewGap() public {
        _qualifyPair();

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(usdc.balanceOf(keeper), BOUNTY_USDC, "first gap paid");

        // Immediately again: the stored price is now fresh, so no second payment.
        vm.warp(vm.getBlockTimestamp() + 3);
        _refreshAsKeeper();
        assertEq(usdc.balanceOf(keeper), BOUNTY_USDC, "no farming inside the gap");

        // After a full new gap the service is real again and pays again.
        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(usdc.balanceOf(keeper), 2 * BOUNTY_USDC, "second gap paid");
        _assertBooks("after two bounties");
    }

    // ==================== withheld paths ====================

    function test_RefreshBounty_NotPaidWithinGap() public {
        _qualifyPair();
        uint256 insuranceBefore = _insuranceBal();

        vm.warp(vm.getBlockTimestamp() + GAP - 60); // 9 minutes: inside the gate
        _refreshAsKeeper();

        assertEq(usdc.balanceOf(keeper), 0, "no bounty inside the gap");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched");
    }

    function test_RefreshBounty_NotPaidWhenOIBelowFloor() public {
        // Insurance qualifies but no open interest exists.
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
        uint256 insuranceBefore = _insuranceBal();

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();

        assertEq(usdc.balanceOf(keeper), 0, "no bounty without OI");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched");
    }

    function test_RefreshBounty_NotPaidWhenInsuranceBelowFloor() public {
        // OI qualifies but the fund sits under the $10,000 floor. A fresh pair starts with the
        // ~$4,500 deployment seed in insurance, so the balance is written down directly (a
        // withheld path transfers nothing, so the unbacked bookkeeping is harmless here).
        _openPosition(alice, bob, true, BAZAAR_SCALE / 2);
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(9_000 * BAZAAR_SCALE);
        uint256 insuranceBefore = _insuranceBal();
        assertLt(insuranceBefore, 10_000 * BAZAAR_SCALE, "setup: fund below floor");

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();

        assertEq(usdc.balanceOf(keeper), 0, "no bounty from a small fund");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched");
    }

    function test_RefreshBounty_NotPaidWhenNothingStored() public {
        // Non-continuous pair served by the stale fallback: the read succeeds but nothing is
        // stored, so repeated calls against the same old timestamp must never pay.
        bytes[] memory seed = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
        aaplPair.refreshPrice(seed);

        // Give the pair qualifying OI and insurance directly (no transfers happen in a withheld
        // path, so unbacked fund bookkeeping is fine here).
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(0).checked_write(100 * BAZAAR_SCALE); // totalLongOI: $20,000 notional at $200
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(5).checked_write(20_000 * BAZAAR_SCALE); // insuranceFundBalance

        vm.warp(vm.getBlockTimestamp() + GAP + 1);

        (,,,,, uint256 insuranceBefore,,,,,,) = aaplPair.pairVault();
        vm.prank(keeper);
        aaplPair.refreshPrice(new bytes[](0)); // stale fallback path: no store

        assertEq(usdc.balanceOf(keeper), 0, "stale fallback earns nothing");
        (,,,,, uint256 insuranceAfter,,,,,,) = aaplPair.pairVault();
        assertEq(insuranceAfter, insuranceBefore, "insurance untouched");
    }

    function test_RefreshBounty_NotPaidDuringSweepWindow() public {
        // Settlement price fixed but finalize not yet called: the pair is NOT terminated, yet
        // its insurance already backs the frozen settlement claims. The gate must withhold the
        // bounty for the whole 48h window (and the frozen updateTs blocks it independently).
        _qualifyPair();
        uint256 insuranceBefore = _insuranceBal();

        vm.prank(address(factory.pairTerminator()));
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        assertFalse(pair.isPairTerminatedNormal(), "setup: window open, not terminated");

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();

        assertEq(usdc.balanceOf(keeper), 0, "no bounty during the sweep window");
        assertEq(_insuranceBal(), insuranceBefore, "settlement-backing insurance untouched");
    }

    function test_RefreshBounty_NotPaidWhenTerminated() public {
        _qualifyPair();
        uint256 insuranceBefore = _insuranceBal();
        _stdstore.enable_packed_slots().target(address(pair)).sig("isPairTerminatedNormal()").checked_write(true);

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();

        assertEq(usdc.balanceOf(keeper), 0, "terminated pair pays no bounty");
        assertEq(_insuranceBal(), insuranceBefore, "settlement-backing insurance untouched");
    }
}
