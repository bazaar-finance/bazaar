// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title RefreshBountyTest
/// @notice Covers the insurance-funded refreshPrice bounty (RiskParamsLib.payRefreshBounty):
///         a caller whose refresh stores a fresh price on a pair with more than $5,000 of free
///         insurance capital earns $0.10, debited from the fund and accrued to its claimable
///         balance. The gap the stored price must have aged past follows what the fund has at
///         stake: 5 minutes while the vault holds at least $1,250 of inventory, a day otherwise.
///         Open interest is not a gate. Each gate is exercised, plus the books invariant (the
///         deduction and the escrow liability must move together).
contract RefreshBountyTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BOUNTY = 0.1e18; // = RiskParamsLib.REFRESH_BOUNTY
    uint256 constant BOUNTY_USDC = 0.1e6;
    uint256 constant GAP = 5 minutes; // = RiskParamsLib.REFRESH_BOUNTY_MIN_GAP
    uint256 constant HEARTBEAT = 1 days; // = RiskParamsLib.REFRESH_BOUNTY_HEARTBEAT
    uint256 constant INVENTORY_FLOOR_USD = 1_250; // = BazaarTypes.UNLOAD_BOUNTY_MIN_NOTIONAL
    uint256 constant SPOT_USD = 50_000; // what _freshPrice() stores

    address keeper;

    function setUp() public override {
        super.setUp();
        keeper = makeAddr("keeper");
    }

    /// @dev Qualifying baseline: a live book (0.5 BTC each side at $50k) and $10,000 insurance on
    ///      top of the deployment seed, well past the $5,000 free-capital floor.
    function _qualifyPair() internal {
        _openPosition(alice, bob, true, BAZAAR_SCALE / 2);
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
    }

    /// @dev Stage vault inventory worth `notionalUsd` at the $50k spot, with a 4% seizure behind
    ///      it, so the fund stays healthy and well above its free-capital floor.
    function _holdInventory(uint256 notionalUsd) internal {
        uint256 notional = notionalUsd * BAZAAR_SCALE;
        _stageHeldInventory(pair, notional / SPOT_USD, notional, notional / 25);
    }

    function _refreshAsKeeper() internal {
        bytes[] memory pu = _freshPrice(); // build BEFORE the prank (external mockPyth call would consume it)
        vm.prank(keeper);
        pair.refreshPrice(pu);
    }

    // ==================== paying path ====================

    function test_RefreshBounty_PaidWhenAllGatesPass() public {
        _qualifyPair();
        _holdInventory(5_000);
        uint256 insuranceBefore = _insuranceBal();
        assertEq(_escrowOwed(keeper), 0, "keeper starts with nothing owed");

        vm.warp(vm.getBlockTimestamp() + GAP + 1);

        bytes[] memory pu = _freshPrice();
        vm.expectEmit(true, true, false, true, address(pair));
        emit BazaarTypes.FeeAccrued(pair.pairId(), keeper, BOUNTY);
        vm.prank(keeper);
        pair.refreshPrice(pu);

        assertEq(_escrowOwed(keeper), BOUNTY, "keeper owed $0.10");
        assertEq(_insuranceBal(), insuranceBefore - BOUNTY, "insurance debited exactly the bounty");
        _assertBooksSettled("after accrued bounty");

        // The refresh itself moves no USDC; the keeper pulls the bounty like any other payout.
        assertEq(_claimFees(keeper), BOUNTY_USDC, "keeper claims $0.10");
        assertEq(_escrowOwed(keeper), 0, "claim clears the balance");
        _assertBooksSettled("after claim");
    }

    function test_RefreshBounty_PaysAgainAfterNewGap() public {
        _qualifyPair();
        _holdInventory(5_000);

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "first gap paid");

        // Immediately again: the stored price is now fresh, so no second payment.
        vm.warp(vm.getBlockTimestamp() + 4);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "no farming inside the gap");

        // After a full new gap the service is real again and pays again.
        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), 2 * BOUNTY, "second gap paid");
        _assertBooks("after two bounties");
    }

    /// @notice The fast cadence starts exactly at the unload reward's dust line: inventory worth
    ///         $1,250 at the fresh spot earns the 5-minute gap.
    function test_RefreshBounty_InventoryAtTheFloor_PaysEveryGap() public {
        _qualifyPair();
        _holdInventory(INVENTORY_FLOOR_USD);

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "inventory at the floor earns the 5-minute cadence");
    }

    // ==================== lens: where is the money ====================

    /// @notice The lens answers "which pairs owe me" from the pair set of the factory in one call,
    ///         and honours the order passed when handed an explicit list.
    function test_RefreshBounty_LensListsOwedAcrossPairs() public {
        _qualifyPair();
        _holdInventory(5_000);
        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper(); // $0.10 owed on the BTC pair, nothing on AAPL

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

    // ==================== cadence without inventory ====================

    /// @notice With no inventory held the bounty is a heartbeat: a stored price must be a day old.
    ///         Open interest alone does not buy the fast cadence, so a long and a short parked in
    ///         two wallets on a dormant pair draw one bounty per day, not one per 5 minutes.
    ///         Every refresh stores a price whether or not it pays, so refreshing on the fast
    ///         cadence keeps resetting the gap and earns nothing at all.
    function test_RefreshBounty_WithoutInventory_PaysOncePerHeartbeat() public {
        _qualifyPair();
        uint256 insuranceBefore = _insuranceBal();

        for (uint256 i = 0; i < 3; i++) {
            vm.warp(vm.getBlockTimestamp() + GAP + 1);
            _refreshAsKeeper();
        }
        assertEq(_escrowOwed(keeper), 0, "the 5-minute cadence pays nothing without inventory");

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT - 1 hours);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), 0, "inside the heartbeat: nothing");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched so far");

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "a day-old stored price earns the heartbeat bounty");
        assertEq(_insuranceBal(), insuranceBefore - BOUNTY, "insurance debited once");
        _assertBooksSettled("after the heartbeat bounty");
    }

    /// @notice Inventory under the $1,250 line is dust and buys nothing: the heartbeat applies.
    function test_RefreshBounty_DustInventory_HeartbeatOnly() public {
        _qualifyPair();
        _holdInventory(INVENTORY_FLOOR_USD - 250);

        vm.warp(vm.getBlockTimestamp() + GAP + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), 0, "dust inventory does not earn the 5-minute cadence");

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();
        assertEq(_escrowOwed(keeper), BOUNTY, "the heartbeat still pays");
    }

    // ==================== withheld paths ====================

    function test_RefreshBounty_NotPaidWithinGap() public {
        _qualifyPair();
        _holdInventory(5_000);
        uint256 insuranceBefore = _insuranceBal();

        vm.warp(vm.getBlockTimestamp() + GAP - 60); // 4 minutes: inside the gate
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "no bounty inside the gap");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched");
    }

    /// @notice Open interest is not a gate: a pair with a qualifying fund and no positions at all
    ///         still gets its heartbeat, which is what keeps a quiet pair's stored price inside the
    ///         stale-termination threshold when nothing else stores one.
    function test_RefreshBounty_PaidWithoutOpenInterest() public {
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
        uint256 insuranceBefore = _insuranceBal();

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), BOUNTY, "the heartbeat pays with no open interest");
        assertEq(_insuranceBal(), insuranceBefore - BOUNTY, "insurance debited the bounty");
        _assertBooksSettled("after the heartbeat bounty");
    }

    function test_RefreshBounty_NotPaidWhenInsuranceBelowFloor() public {
        // A live book, but the fund sits under the $5,000 floor: the balance is written to $4,500
        // directly, so the case does not depend on the size of the deployment seed (a withheld
        // path moves nothing, so the unbacked bookkeeping is harmless here).
        _openPosition(alice, bob, true, BAZAAR_SCALE / 2);
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(4_500 * BAZAAR_SCALE);
        uint256 insuranceBefore = _insuranceBal();
        assertLt(insuranceBefore, 5_000 * BAZAAR_SCALE, "setup: fund below floor");

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "no bounty from a small fund");
        assertEq(_insuranceBal(), insuranceBefore, "insurance untouched");
    }

    function test_RefreshBounty_NotPaidWhenFreeCapitalBelowFloor() public {
        // The balance clears the floor, but most of it is the seizure earmarked against inventory
        // the vault still holds. The gate reads free capital, so no bounty, although the inventory
        // ($50,000 of it) would otherwise earn the 5-minute cadence.
        _qualifyPair();
        uint256 fund = _insuranceBal();
        assertGt(fund, 5_000 * BAZAAR_SCALE, "setup: balance above the floor");
        _stageHeldInventory(60_000 * BAZAAR_SCALE, fund - 4_000 * BAZAAR_SCALE); // free capital $4,000
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

        // Give the pair a qualifying fund directly (nothing moves in a withheld path, so unbacked
        // fund bookkeeping is fine here).
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(5).checked_write(20_000 * BAZAAR_SCALE); // insuranceFundBalance

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);

        (,,,,, uint256 insuranceBefore,,,,,,,,,,,) = aaplPair.pairVault();
        vm.prank(keeper);
        aaplPair.refreshPrice(new bytes[](0)); // stale fallback path: no store

        (uint256 owed,) = lens.claimableFees(address(aaplPair), keeper);
        assertEq(owed, 0, "stale fallback earns nothing");
        (,,,,, uint256 insuranceAfter,,,,,,,,,,,) = aaplPair.pairVault();
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

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
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

        vm.warp(vm.getBlockTimestamp() + HEARTBEAT + 1);
        _refreshAsKeeper();

        assertEq(_escrowOwed(keeper), 0, "terminated pair pays no bounty");
        assertEq(_insuranceBal(), residualBefore, "insurers' residual untouched");
    }
}
