// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";

/// @title RestingReserveBoundTest
/// @notice The creation, amendment and withdrawal gates judge the resting set from its tally's
///         bound first and from the orders themselves only when the bound does not clear the
///         caller; the verdict is the one the orders give either way. Covers the tally's
///         bookkeeping through creation, amendment and cancellation, the fallback when the tally
///         has drifted above the set, the lazy pruning of expired orders, a waiting StopLimit,
///         and the withdrawal boundary against the lens's own reading of the set.
contract RestingReserveBoundTest is IntegrationBase {
    uint256 constant BTC = 1e18;
    uint256 constant SLOT_USER_ACTIVE_LIMIT_ORDERS = 2;

    function _tally(address user) internal view returns (BazaarTypes.RestingTally memory) {
        return lens.restingTally(address(pair), user);
    }

    /// @dev Every id in `user`'s set, dead entries included, read the way the lens reads it.
    function _rawSetIds(address user) internal view returns (uint256[] memory ids) {
        bytes32 base = keccak256(abi.encode(user, SLOT_USER_ACTIVE_LIMIT_ORDERS));
        uint256 len = uint256(pair.extsload(base));
        ids = new uint256[](len);
        uint256 data = uint256(keccak256(abi.encode(base)));
        for (uint256 i; i < len; ++i) {
            ids[i] = uint256(pair.extsload(bytes32(data + i)));
        }
    }

    function _withdraw(address user, uint256 amount, uint256 priceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(priceUsd, uint64(vm.getBlockTimestamp()));
        vm.prank(user);
        pair.withdrawCollateral(amount, pu, 0, 0, 0, "");
    }

    function _refreshAt(uint256 priceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(priceUsd, uint64(vm.getBlockTimestamp()));
        vm.prank(seq);
        pair.refreshPrice(pu);
    }

    // ------------------------------------------------------------------ bookkeeping

    /// @notice Creation records the whole order under its side; an amendment moves the leg to its
    ///         new price; a cancel takes the remaining leg out and never tightens the price bounds.
    function test_tally_createAmendCancel() public {
        _deposit(alice, 100_000 * BAZAAR_SCALE);
        uint256 high = _placeLimit(alice, true, BTC / 10, 49_000 * BAZAAR_SCALE);
        uint256 low = _placeLimit(alice, true, BTC / 5, 48_000 * BAZAAR_SCALE);
        _placeLimit(alice, false, BTC / 10, 51_000 * BAZAAR_SCALE);

        BazaarTypes.RestingTally memory t = _tally(alice);
        assertEq(t.bidSize, 3 * BTC / 10, "bid size");
        assertEq(t.bidLimitNotional, 4_900 * BAZAAR_SCALE + 9_600 * BAZAAR_SCALE, "bid limit notional");
        assertEq(t.askSize, BTC / 10, "ask size");
        assertEq(t.askLimitNotional, 5_100 * BAZAAR_SCALE, "ask limit notional");
        assertEq(t.highestBid, 49_000 * BAZAAR_SCALE, "highest bid");
        assertEq(t.lowestAsk, 51_000 * BAZAAR_SCALE, "lowest ask");
        assertEq(t.stopCount, 0, "no stops");

        // Reprice the low bid up by $500 and grow it to 0.3.
        uint256[] memory w = new uint256[](3);
        (w[0], w[1], w[2]) = (low, 48_500 * BAZAAR_SCALE, 3 * BTC / 10);
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        pair.amendOrders(w, pu, 0, 0, 0, "", "");
        t = _tally(alice);
        assertEq(t.bidSize, 4 * BTC / 10, "bid size after the amend");
        assertEq(t.bidLimitNotional, 4_900 * BAZAAR_SCALE + 14_550 * BAZAAR_SCALE, "bid notional after the amend");
        assertEq(t.highestBid, 49_000 * BAZAAR_SCALE, "highest bid unchanged");

        // Cancel the higher bid: the leg leaves, the price bound does not move.
        vm.prank(alice);
        pair.cancelOrders(_one(high), 0, 0, 0, "", "");
        t = _tally(alice);
        assertEq(t.bidSize, 3 * BTC / 10, "bid size after the cancel");
        assertEq(t.bidLimitNotional, 14_550 * BAZAAR_SCALE, "bid notional after the cancel");
        assertEq(t.highestBid, 49_000 * BAZAAR_SCALE, "a cancel never tightens the bound");
    }

    /// @notice A fill is not reported to the tally: it stays above the set until a gate reads
    ///         the set, and a gate the drifted bound refuses still passes on that reading.
    function test_create_fallsBackToTheOrders_whenTheDriftedBoundRefuses() public {
        (uint256 imrBp,,,) = pair.marginRequirements();
        uint256 size = BTC / 10;
        uint256 markNotional = Math_mulDiv(size, 50_000 * BAZAAR_SCALE);
        // After the first bid fills, the position is `size` long and the second bid adds the
        // same again. The bound still counts the filled bid: one more `size` at the mark.
        uint256 exactRequired = imrBp * (2 * markNotional) / BazaarTypes.BP_SCALE;
        uint256 boundRequired = imrBp * (3 * markNotional) / BazaarTypes.BP_SCALE;
        uint256 deposit = (exactRequired + boundRequired) / 2;

        _deposit(alice, deposit);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 first = _placeLimit(alice, true, size, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, size, 48_900 * BAZAAR_SCALE);
        assertEq(_posSize(alice), size, "fixture: alice's bid filled");
        assertEq(_filledSize(first), size, "fixture: the bid is complete");
        assertEq(_tally(alice).bidSize, size, "the fill is not reported to the tally");

        // The bound refuses (collateral is well under its requirement); the orders admit.
        uint256 second = _placeLimit(alice, true, size, 49_000 * BAZAAR_SCALE);
        assertTrue(_inBook(second), "the second bid rests");
        BazaarTypes.RestingTally memory t = _tally(alice);
        assertEq(t.bidSize, size, "the reading rewrote the tally onto the live set before the new leg joined");
        assertEq(t.bidLimitNotional, Math_mulDiv(size, 49_000 * BAZAAR_SCALE), "one live bid");
    }

    /// @notice With less than the orders themselves require, the reading refuses — the fallback
    ///         is not a second chance, it is the verdict.
    function test_create_refusedByTheOrders_whenBothFail() public {
        (uint256 imrBp,,,) = pair.marginRequirements();
        uint256 size = BTC / 10;
        uint256 markNotional = Math_mulDiv(size, 50_000 * BAZAAR_SCALE);
        uint256 exactRequired = imrBp * (2 * markNotional) / BazaarTypes.BP_SCALE;
        uint256 firstRequired = imrBp * markNotional / BazaarTypes.BP_SCALE;
        uint256 deposit = (firstRequired + exactRequired) / 2;

        _deposit(alice, deposit);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, size, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, size, 48_900 * BAZAAR_SCALE);
        assertEq(_posSize(alice), size, "fixture: alice's bid filled");

        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__InsufficientMarginAfterOrder.selector);
        pair.createOrder(_limitSpec(true, size, 49_000 * BAZAAR_SCALE), _hintsNone(), pu, 0, 0, 0, "", "");
    }

    // ------------------------------------------------------------------ pruning

    /// @notice Below the cap, creating an order does not sweep the owner's expired orders: an
    ///         expired entry stays in the set until something reads it. A withdrawal does.
    function test_create_belowCap_leavesExpiredEntries_untilTheSetIsRead() public {
        _deposit(alice, 50_000 * BAZAAR_SCALE);
        BazaarTypes.OrderSpec memory s = _limitSpec(true, BTC / 10, 49_000 * BAZAAR_SCALE);
        s.expirationBlock = uint64(vm.getBlockNumber()) + BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS;
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 expired = _lastCreatedOrderId(pair);
        _roll(BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 1);

        // Ample collateral: the bound clears the creation, so the set is not read.
        _placeLimit(alice, true, BTC / 10, 48_000 * BAZAAR_SCALE);
        assertEq(_rawSetIds(alice).length, 2, "the expired entry is still in the set");
        assertEq(_canceledBlock(expired), 0, "and not canceled");
        (, uint256 live,,) = lens.getUserActiveLimitOrders(address(pair), alice);
        assertEq(live, 1, "the lens reports only the live order");
        assertEq(_tally(alice).bidSize, BTC / 5, "the tally still counts it");

        // A withdrawal sweeps the set ahead of its gate.
        _withdraw(alice, BAZAAR_SCALE, 50_000);
        assertEq(_rawSetIds(alice).length, 1, "the withdrawal pruned it");
        assertEq(_canceledBlock(expired), uint64(vm.getBlockNumber()), "canceled as expired");
    }

    /// @notice At the cap, creation still prunes expired entries before judging the cap.
    function test_create_atCap_prunesExpiredEntries() public {
        _deposit(alice, 200_000 * BAZAAR_SCALE);
        uint64 expiry = uint64(vm.getBlockNumber()) + BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS;
        for (uint256 i; i < BazaarTypes.MAX_ACTIVE_LIMIT_ORDERS_PER_USER; ++i) {
            BazaarTypes.OrderSpec memory s = _limitSpec(true, BTC / 100, (40_000 + i) * BAZAAR_SCALE);
            s.expirationBlock = expiry;
            bytes[] memory pu = _freshPrice();
            vm.prank(alice);
            pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        }
        _roll(BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS + 1);
        uint256 kept = _placeLimit(alice, true, BTC / 100, 45_000 * BAZAAR_SCALE);
        uint256[] memory ids = _rawSetIds(alice);
        assertEq(ids.length, 1, "the full set was pruned before the cap check");
        assertEq(ids[0], kept, "only the new order remains");
        // The prune does not touch the tally: it sits above the set by the 32 pruned legs, which
        // ample collateral clears on the bound, until a gate reads the set. A withdrawal that
        // leaves too little for the bound's 0.33 BTC but enough for the live 0.01 BTC forces
        // that reading, passes on it, and leaves the tally rewritten.
        assertEq(_tally(alice).bidSize, 33 * BTC / 100, "the prune leaves the tally above the set");
        _withdraw(alice, 199_400 * BAZAAR_SCALE, 50_000);
        assertEq(_posCollateral(alice), 600 * BAZAAR_SCALE, "paid on the orders' own reading");
        assertEq(_tally(alice).bidSize, BTC / 100, "the reading rewrote the tally onto the live set");
    }

    // ------------------------------------------------------------------ stops

    /// @notice A waiting StopLimit keeps the gates reading the set, through its arming, until a
    ///         gate's reading finds it armed.
    function test_waitingStopLimit_keepsTheGatesOnTheOrders_untilRead() public {
        _deposit(alice, 50_000 * BAZAAR_SCALE);
        uint256 stop = _placeStopLimit(alice, true, BTC / 10, 52_000 * BAZAAR_SCALE, 52_500 * BAZAAR_SCALE);
        BazaarTypes.RestingTally memory t = _tally(alice);
        assertEq(t.stopCount, 1, "one waiting stop");
        assertEq(t.bidSize, BTC / 10, "recorded under its side at its limit");
        assertEq(t.highestBid, 52_500 * BAZAAR_SCALE, "its limit bounds the bids");

        _executeTriggerAt(stop, 52_000);
        assertTrue(_inBook(stop), "fixture: armed and resting");
        assertEq(_tally(alice).stopCount, 1, "arming is not reported to the tally");

        // The gate cannot bound a counted stop, so this withdrawal reads the set and rewrites it.
        _withdraw(alice, BAZAAR_SCALE, 52_000);
        t = _tally(alice);
        assertEq(t.stopCount, 0, "the reading found no waiting stop");
        assertEq(t.bidSize, BTC / 10, "the armed stop is a bid");
    }

    // ------------------------------------------------------------------ withdrawal boundary

    /// @notice The largest withdrawal the lens computes from the orders themselves is accepted,
    ///         and a hair more is refused, with an ask resting below the mark: the bound, which
    ///         overstates that ask's loss leg and the fee, is not what decides at the boundary.
    function test_withdraw_boundaryMatchesTheLens_withAnAskBelowTheMark() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, false, BTC / 5, 51_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, BTC / 5, 49_000 * BAZAAR_SCALE);
        _refreshAt(52_000);

        uint256 max = lens.getMaxWithdrawable(address(pair), alice, 52_000 * BAZAAR_SCALE);
        assertGt(max, 0, "fixture: something is withdrawable");
        assertLt(max, 20_000 * BAZAAR_SCALE, "fixture: the orders reserve something");

        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(52_000, uint64(vm.getBlockTimestamp()));
        vm.prank(alice);
        vm.expectRevert();
        pair.withdrawCollateral(max + 1e12, pu, 0, 0, 0, "");

        pu = _priceUpdate(52_000, uint64(vm.getBlockTimestamp()));
        vm.prank(alice);
        pair.withdrawCollateral(max, pu, 0, 0, 0, "");
        assertEq(_posCollateral(alice), 20_000 * BAZAAR_SCALE - max, "paid out to the line the orders set");
    }

    /// @notice The same boundary with a bid resting above the mark.
    function test_withdraw_boundaryMatchesTheLens_withABidAboveTheMark() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, BTC / 5, 49_500 * BAZAAR_SCALE);
        _placeLimit(alice, false, BTC / 5, 51_000 * BAZAAR_SCALE);
        _refreshAt(48_000);

        uint256 max = lens.getMaxWithdrawable(address(pair), alice, 48_000 * BAZAAR_SCALE);
        assertGt(max, 0, "fixture: something is withdrawable");

        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(48_000, uint64(vm.getBlockTimestamp()));
        vm.prank(alice);
        vm.expectRevert();
        pair.withdrawCollateral(max + 1e12, pu, 0, 0, 0, "");

        pu = _priceUpdate(48_000, uint64(vm.getBlockTimestamp()));
        vm.prank(alice);
        pair.withdrawCollateral(max, pu, 0, 0, 0, "");
        assertEq(_posCollateral(alice), 20_000 * BAZAAR_SCALE - max, "paid out to the line the orders set");
    }

    function Math_mulDiv(uint256 size, uint256 price) internal pure returns (uint256) {
        return size * price / BAZAAR_SCALE;
    }
}
