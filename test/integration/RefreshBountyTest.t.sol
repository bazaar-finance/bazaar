// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title RefreshBountyTest
/// @notice Covers the insurance-funded refreshPrice bounty (RiskParamsLib.payRefreshBounty):
///         a caller whose refresh stores a fresh price after a >10min gap on a pair with >$10,000
///         OI notional and >$10,000 of free insurance capital earns $0.25, debited from the fund and
///         accrued to its claimable balance. Each gate is exercised, plus the books invariant (the
///         deduction and the escrow liability must move together).
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
        assertEq(_escrowOwed(keeper), 0, "keeper starts with nothing owed");

        vm.warp(vm.getBlockTimestamp() + GAP + 1);

        bytes[] memory pu = _freshPrice();
        vm.expectEmit(true, true, false, true, address(pair));
        emit BazaarTypes.FeeAccrued(pair.pairId(), keeper, BOUNTY);
        vm.prank(keeper);
        pair.refreshPrice(pu);

        assertEq(_escrowOwed(keeper), BOUNTY, "keeper owed $0.25");
        assertEq(_insuranceBal(), insuranceBefore - BOUNTY, "insurance debited exactly the bounty");
        _assertBooksSettled("after accrued bounty");

        // The refresh itself moves no USDC; the keeper pulls the bounty like any other payout.
        assertEq(_claimFees(keeper), BOUNTY_USDC, "keeper claims $0.25");
        assertEq(_escrowOwed(keeper), 0, "claim clears the balance");
        _assertBooksSettled("after claim");
    }

    function test_RefreshBounty_PaysAgainAfterNewGap() public {
        _qualifyPair();

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "first gap paid");

        // Immediately again: the stored price is now fresh, so no second payment.
        vm.warp(vm.getBlockTimestamp() + 3);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "no farming inside the gap");

        // After a full new gap the service is real again and pays again.
        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), 2 * BOUNTY, "second gap paid");
        _assertBooks("after two bounties");
    }

    // ==================== lens: where is the money ====================

    /// @notice The lens answers "which pairs owe me" from the pair set of the factory in one call,
    ///         and honours the order passed when handed an explicit list.
    function test_RefreshBounty_LensListsOwedAcrossPairs() public {
        _qualifyPair();
        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper(); // $0.25 owed on the BTC pair, nothing on AAPL

        assertEq(lens.factory(), address(factory), "lens wired to the factory of this deployment");

        (address[] memory pairs, uint256[] memory owed) = lens.getClaimableFeesAll(keeper);
        assertEq(pairs.length, 2, "both deployed pairs listed");
        assertEq(pairs[0], address(pair));
        assertEq(owed[0], BOUNTY, "BTC pair owes the bounty");
        assertEq(pairs[1], address(aaplPair));
        assertEq(owed[1], 0, "AAPL pair owes nothing, still listed");

        address[] memory chosen = new address[](2);
        chosen[0] = address(aaplPair);
        chosen[1] = address(pair);
        uint256[] memory subset = lens.getClaimableFees(chosen, keeper);
        assertEq(subset[0], 0, "follows the order passed");
        assertEq(subset[1], BOUNTY, "follows the order passed");

        _claimFees(keeper);
        (, owed) = lens.getClaimableFeesAll(keeper);
        assertEq(owed[0], 0, "claim clears the BTC entry");
    }

    // ==================== withheld paths ====================

    function test_RefreshBounty_NotPaidWithinGap() public {
        _qualifyPair();
        uint256 insuranceBefore = _insuranceBal();

        vm.warp(vm.getBlockTimestamp() + GAP - 60); // 9 minutes: inside the gate
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "no bounty inside the gap");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched");
    }

    function test_RefreshBounty_NotPaidWhenOIBelowFloor() public {
        // Insurance qualifies but no open interest exists.
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
        uint256 insuranceBefore = _insuranceBal();

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "no bounty without OI");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched");
    }

    function test_RefreshBounty_NotPaidWhenInsuranceBelowFloor() public {
        // OI qualifies but the fund sits under the $10,000 floor. A fresh pair starts with the
        // ~$4,000 deployment seed in insurance, so the balance is written UP to $9,000 directly (a
        // withheld path moves nothing, so the unbacked bookkeeping is harmless here).
        _openPosition(alice, bob, true, BAZAAR_SCALE / 2);
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(9_000 * BAZAAR_SCALE);
        uint256 insuranceBefore = _insuranceBal();
        assertLt(insuranceBefore, 10_000 * BAZAAR_SCALE, "setup: fund below floor");

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "no bounty from a small fund");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched");
    }

    function test_RefreshBounty_NotPaidWhenFreeCapitalBelowFloor() public {
        // The balance clears the floor, but most of it is the seizure earmarked against inventory
        // the vault still holds. The gate reads free capital, so no bounty.
        _qualifyPair();
        uint256 fund = _insuranceBal();
        assertGt(fund, 10_000 * BAZAAR_SCALE, "setup: balance above the floor");
        _stageHeldInventory(60_000 * BAZAAR_SCALE, fund - 5_000 * BAZAAR_SCALE); // free capital $5,000
        uint256 insuranceBefore = _insuranceBal();

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "no bounty: the earmark is not free capital");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched");
    }

    function test_RefreshBounty_NotPaidWhenNothingStored() public {
        // Non-continuous pair served by the stale fallback: the read succeeds but nothing is
        // stored, so repeated calls against the same old timestamp must never pay.
        bytes[] memory seed = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
        aaplPair.refreshPrice(seed);

        // Give the pair qualifying OI and insurance directly (nothing moves in a withheld path,
        // so unbacked fund bookkeeping is fine here).
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(0).checked_write(100 * BAZAAR_SCALE); // totalLongOI: $20,000 notional at $200
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(5).checked_write(20_000 * BAZAAR_SCALE); // insuranceFundBalance

        vm.warp(vm.getBlockTimestamp() + GAP + 1);

        (,,,,, uint256 insuranceBefore,,,,,,,,) = aaplPair.pairVault();
        vm.prank(keeper);
        aaplPair.refreshPrice(new bytes[](0)); // stale fallback path: no store

        (uint256 owed,) = aaplPair.claimableFees(keeper);
        assertEq(owed, 0, "stale fallback earns nothing");
        (,,,,, uint256 insuranceAfter,,,,,,,,) = aaplPair.pairVault();
        assertEq(insuranceAfter, insuranceBefore, "insurance untouched");
    }

    function test_RefreshBounty_NotPaidDuringSweepWindow() public {
        // Settlement price fixed but finalize not yet called: the pair is NOT terminated, yet
        // its insurance already backs the frozen settlement claims. The gate must withhold the
        // bounty for as long as the window is open (and the frozen updateTs blocks it independently).
        _qualifyPair();
        uint256 insuranceBefore = _insuranceBal();

        vm.prank(address(factory.pairTerminator()));
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        assertFalse(pair.isPairTerminated(), "setup: window open, not terminated");

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "no bounty during the sweep window");
        assertEq(_insuranceBal(), insuranceBefore, "settlement-backing insurance untouched");
    }

    function test_RefreshBounty_NotPaidWhenTerminated() public {
        _qualifyPair();
        // Terminate for real: fix the price, settle both positions at it, finalize.
        vm.prank(address(factory.pairTerminator()));
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        address[] memory both = new address[](2);
        both[0] = alice;
        both[1] = bob;
        pair.liquidate(both, new bytes[](0));
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminated(), "setup: terminated");
        uint256 residualBefore = _insuranceBal(); // finalize rewrites the fund to the insurers' residual

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "terminated pair pays no bounty");
        assertEq(_insuranceBal(), residualBefore, "insurers' residual untouched");
    }
}
