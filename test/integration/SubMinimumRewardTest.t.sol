// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title SubMinimumRewardTest
/// @notice The flat liquidation reward on a live pair for a position worth less than
///         MIN_ORDER_AMOUNT. Two orders that each meet the minimum leave such a position behind,
///         and a keeper who liquidates it earns the equity it still holds rather than the full
///         MIN_LIQUIDATOR_REWARD from insurance.
contract SubMinimumRewardTest is IntegrationBase {
    uint256 constant BTC = BAZAAR_SCALE;
    uint256 constant ENTRY_USD = 50_000;

    /// @dev Buy 0.00012 BTC ($6) and sell 0.0001 BTC ($5) against bob at $50,000, which leaves
    ///      alice long 0.00002 BTC: $1 of notional at a $1 entry basis.
    function _mintSubMinimumLong() internal {
        _deposit(alice, 5 * BAZAAR_SCALE);
        _deposit(bob, 5 * BAZAAR_SCALE);
        _placeLimit(bob, false, 12 * BTC / 100_000, ENTRY_USD * BAZAAR_SCALE);
        _placeLimit(alice, true, 12 * BTC / 100_000, ENTRY_USD * BAZAAR_SCALE);
        _placeLimit(bob, true, BTC / 10_000, ENTRY_USD * BAZAAR_SCALE);
        _placeLimit(alice, false, BTC / 10_000, ENTRY_USD * BAZAAR_SCALE);
    }

    /// @notice The position is stripped to initial margin plus $0.01 and then marked down until
    ///         $0.03 of equity is left, under maintenance. Liquidating it pays the keeper that
    ///         $0.03, and the fund's balance moves by the seized collateral less that reward.
    function test_liquidate_subMinimumPosition_paysOnlyItsEquity() public {
        _mintSubMinimumLong();
        (, uint256 size, uint256 entryValue, uint256 collateral,,,) = pair.positionBuckets(alice);
        assertEq(size, 2 * BTC / 100_000, "premise: 0.00002 BTC left open");
        assertEq(entryValue, BAZAAR_SCALE, "premise: a $1 entry basis");

        // Keep initial margin on the $1 position plus $0.01, and withdraw the rest.
        (uint256 imrBp,,,) = pair.marginRequirements();
        uint256 kept = imrBp * BAZAAR_SCALE / 10_000 + BAZAAR_SCALE / 100;
        bytes[] memory pu = _freshPrice(); // built before the prank: the Pyth call would consume it
        vm.prank(alice);
        pair.withdrawCollateral(collateral - kept, pu, 0, 0, 0, "");

        // At this price the $1 position has lost imrBp / 10_000 + $0.02, leaving $0.03 of equity.
        uint256 crashUsd = ENTRY_USD + 1_000 - 5 * imrBp;
        vm.warp(vm.getBlockTimestamp() + 4); // past MAX_PRICE_STALENESS, so the pair takes this update
        pair.refreshPrice(_priceAt(crashUsd));
        BazaarTypes.BucketState memory s = lens.checkBucketSolvency(address(pair), alice, crashUsd * BAZAAR_SCALE);
        assertFalse(s.isSolvent, "premise: under maintenance");
        assertLt(s.currentNotional, BazaarTypes.MIN_ORDER_AMOUNT, "premise: under the order minimum");
        assertGt(s.availableEquity, 0, "premise: some equity left");
        assertLt(s.availableEquity, BazaarTypes.MIN_LIQUIDATOR_REWARD, "premise: less equity than the floor");

        address keeper = makeAddr("keeper");
        uint256 insuranceBefore = _insuranceBal();
        vm.prank(keeper);
        assertEq(pair.liquidate(_arr1(alice), new bytes[](0)), 1, "alice liquidated");

        assertEq(_escrowOwed(keeper), s.availableEquity, "the keeper earns alice's equity, not the floor");
        assertEq(
            _insuranceBal(),
            insuranceBefore + kept - s.availableEquity,
            "the fund took her collateral and paid her equity"
        );
    }
}
