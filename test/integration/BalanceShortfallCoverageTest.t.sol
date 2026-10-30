// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {CollateralLib} from "../../src/libraries/CollateralLib.sol";
import {IntegrationBase} from "./IntegrationBase.sol";

/// @title BalanceShortfallCoverageTest
/// @notice The books-vs-cash comparison is the pair's seal against a leak: cash below I + D + E
///         fixes the settlement price, so the missing amount is shared pro rata rather than paid
///         to whoever withdraws first. These tests pin that the seal holds where the pair's other
///         verdicts would otherwise answer first — through an ADL window, whose exposure verdict
///         outranks everything for up to a day — and on the withdrawals that read no price at all.
contract BalanceShortfallCoverageTest is IntegrationBase {
    uint256 constant SIZE = 5 * BAZAAR_SCALE;
    address internal sink = makeAddr("sink");

    event InsolvencySettlementFixed(bytes32 indexed pairId, uint256 settlementPrice, uint8 reason);

    /// @dev alice long and bob short 5 BTC at $51k; dave's phantom long is seized at $50k with a
    ///      loss past the fund's free capital, which opens the window.
    function _openWindow() internal {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        _deposit(bob, 60_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, SIZE, 51_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, SIZE, 49_000 * BAZAAR_SCALE);
        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, SIZE, 254_960 * BAZAAR_SCALE);
        vm.prank(carol);
        pair.liquidate(_arr1(dave), _freshPrice());
        assertTrue(pair.isAdlPending(), "fixture: the window is open");
    }

    /// @dev Moves one percent of the pair's cash out from under its books, ten times the tolerance.
    function _leak() internal returns (uint256 leaked) {
        leaked = usdc.balanceOf(address(pair)) / 100;
        vm.prank(address(pair));
        usdc.transfer(sink, leaked);
    }

    /// @notice A shortfall during a pending window fixes the settlement price on the next verdict.
    ///         refreshPrice runs one, and it reports the shortfall where the exposure verdict alone
    ///         would have reported the window.
    function test_shortfallDuringAdlWindow_fixesSettlementAtOnce() public {
        _openWindow();
        _leak();

        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _freshPrice();
        vm.expectEmit(true, false, false, true, address(pair));
        emit InsolvencySettlementFixed(pair.pairId(), 50_000 * BAZAAR_SCALE, 3);
        pair.refreshPrice(pu);

        assertGt(pair.settlementPriceFixedTs(), 0, "the settlement price is fixed inside the window");
    }

    /// @notice A flat account's withdrawal reads no price, so no verdict judges it; the one check
    ///         that needs no price still runs, and the withdrawal is refused while the cash is
    ///         short. It fixes no settlement price of its own, and is paid once the cash is back.
    function test_flatWithdrawal_refusedWhileShort_paidWhenRestored() public {
        _deposit(bob, 1_000 * BAZAAR_SCALE);
        uint256 leaked = _leak();

        vm.expectRevert(CollateralLib.CollateralLib__WithdrawalBlockedVaultUnhealthy.selector);
        vm.prank(bob);
        pair.withdrawCollateral(100 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        assertEq(pair.settlementPriceFixedTs(), 0, "no price to fix a settlement at");

        vm.prank(sink);
        usdc.transfer(address(pair), leaked);
        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        pair.withdrawCollateral(100 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(bob) - before, 100 * USDC_SCALE, "paid once the books are backed");
    }

    /// @notice An account with only resting orders is priced and judged by the pair. The verdict
    ///         that finds the shortfall fixes the settlement price, which schedules the cutoff the
    ///         withdrawal that ran it is then refused on, rather than paid ahead of everyone else.
    ///         The refusal rolls the fix back with it; the next priced flow that completes fixes
    ///         it for good.
    function test_orderOnlyWithdrawal_refusedInTheTransactionThatFindsTheShortfall() public {
        _deposit(carol, 1_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BAZAAR_SCALE / 100, 49_000 * BAZAAR_SCALE);
        _leak();

        bytes[] memory pu = _freshPrice();
        vm.expectRevert(CollateralLib.CollateralLib__PairScheduledForTermination.selector);
        vm.prank(carol);
        pair.withdrawCollateral(100 * BAZAAR_SCALE, pu, 0, 0, 0, "");
        assertEq(pair.settlementPriceFixedTs(), 0, "the refusal rolls the fix back with it");

        vm.warp(vm.getBlockTimestamp() + 4);
        pu = _freshPrice();
        vm.expectEmit(true, false, false, true, address(pair));
        emit InsolvencySettlementFixed(pair.pairId(), 50_000 * BAZAAR_SCALE, 3);
        pair.refreshPrice(pu);
        assertGt(pair.settlementPriceFixedTs(), 0, "the next priced flow fixes it");
    }
}
