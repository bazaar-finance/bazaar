// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";

/// @title MaxWithdrawableTest
/// @notice BazaarPairLens.getMaxWithdrawable must be the EXACT boundary the real withdrawal
///         path enforces: withdrawing the preview succeeds, one dollar more reverts. Exercises
///         the live pair (real margin curve, real order-exposure sweep), not a mock.
contract MaxWithdrawableTest is IntegrationBase {
    /// @notice Position holder: the preview is exactly withdrawable and exactly maximal.
    ///         The withdrawal path margin-checks a long at the LOW bracket (spot − confidence;
    ///         the mock feed's 0.1% conf makes that $49,950 at $50k spot), so the preview is
    ///         queried at that same conservative price.
    function test_maxWithdrawable_isExactBoundary() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE); // 1 BTC long, ~$50k entry, $20k collateral

        uint256 maxW = lens.getMaxWithdrawable(address(pair), alice, 49_950 * BAZAAR_SCALE, false);
        assertGt(maxW, 0, "healthy position has withdrawable slack");

        // One dollar past the preview trips whichever gate binds.
        bytes[] memory pu = _priceAt(50_000);
        vm.prank(alice);
        vm.expectRevert();
        pair.withdrawCollateral(maxW + 1 * BAZAAR_SCALE, pu, 0, 0, 0, "");

        // Exactly the preview clears every gate.
        pu = _priceAt(50_000);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(maxW, pu, 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - before, maxW / 1e12, "preview withdrew in full");
    }

    /// @notice Flat user with no orders: the preview is the entire balance.
    function test_maxWithdrawable_flatUser_fullBalance() public {
        _deposit(alice, 1_000 * BAZAAR_SCALE);
        assertEq(
            lens.getMaxWithdrawable(address(pair), alice, 0, false),
            1_000 * BAZAAR_SCALE,
            "no position, no orders: everything is free"
        );
    }

    /// @notice Resting limit orders reserve IMR in the preview exactly as the withdrawal
    ///         path does, using the pair's live order-exposure view. (A flat user's order
    ///         check runs at spot, so the preview price is plain spot here.)
    function test_maxWithdrawable_flatWithRestingOrder_reservesOrderImr() public {
        _deposit(alice, 10_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, BAZAAR_SCALE / 10, 40_000 * BAZAAR_SCALE); // resting, won't cross

        uint256 maxW = lens.getMaxWithdrawable(address(pair), alice, 50_000 * BAZAAR_SCALE, false);
        assertLt(maxW, 10_000 * BAZAAR_SCALE, "resting order reserves margin");

        (uint256 longExp, uint256 shortExp) = pair.outstandingOrderExposure(alice);
        assertEq(longExp, 4_000 * BAZAAR_SCALE, "0.1 BTC x $40k limit");
        assertEq(shortExp, 0);

        // The boundary is exact here too (order exposure counts as exposure, so a price
        // update is still required by the withdrawal entry point).
        bytes[] memory pu = _priceAt(50_000);
        vm.prank(alice);
        vm.expectRevert();
        pair.withdrawCollateral(maxW + 1 * BAZAAR_SCALE, pu, 0, 0, 0, "");
        pu = _priceAt(50_000);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(maxW, pu, 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - before, maxW / 1e12, "preview withdrew in full");
    }
}
