// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";

/// @title InsuranceWithdrawalCapTest
/// @notice The period-budget arithmetic of InsuranceVaultLib: which open-interest term each regime
///         reads, and how the held term is built from live and trailing open interest.
contract InsuranceWithdrawalCapTest is Test {
    uint256 constant S = 1e18;

    /// @notice Below target the budget is the stricter of the period snapshot and 5% of the fund;
    ///         the held term plays no part there.
    function test_belowTarget_stricterOfSnapshotAndFund_heldTermIgnored() public pure {
        // A $5,000 snapshot (0.5% of $1M) against 5% of a $20k fund.
        assertEq(InsuranceVaultLib.withdrawalCapOf(5_000 * S, 0, 20_000 * S, true), 1_000 * S, "the fund term binds");
        assertEq(
            InsuranceVaultLib.withdrawalCapOf(5_000 * S, type(uint256).max, 20_000 * S, true),
            1_000 * S,
            "whatever the held term reads"
        );
        assertEq(InsuranceVaultLib.withdrawalCapOf(500 * S, 0, 20_000 * S, true), 500 * S, "a smaller snapshot binds");
    }

    /// @notice Above target the OI term is the lower of the snapshot and the held term, at twice
    ///         the below-target rate, floored at 10% of the fund.
    function test_aboveTarget_oiTermIsTheLowerOfSnapshotAndHeld() public pure {
        // Snapshot $5,000 (0.5% of $1M), held $2,500 (0.5% of the $500k held all day), fund $20k.
        assertEq(
            InsuranceVaultLib.withdrawalCapOf(5_000 * S, 2_500 * S, 20_000 * S, false),
            5_000 * S,
            "1% of the held $500k"
        );
        assertEq(
            InsuranceVaultLib.withdrawalCapOf(5_000 * S, 7_500 * S, 20_000 * S, false),
            10_000 * S,
            "held above the snapshot: 1% of the snapshot's $1M"
        );
        assertEq(
            InsuranceVaultLib.withdrawalCapOf(5_000 * S, 2_500 * S, 200_000 * S, false),
            20_000 * S,
            "10% of a $200k fund beats both"
        );
        assertEq(
            InsuranceVaultLib.withdrawalCapOf(5_000 * S, 0, 20_000 * S, false),
            2_000 * S,
            "no held open interest: the fund floor alone"
        );
    }

    /// @notice The held term reads the lower of live and trailing open interest, live alone without
    ///         a trailing figure, and the one unit of size a flat stretch in the window is cached as.
    function test_heldTerm_readsTheLowerOfLiveAndTrailing() public pure {
        uint256 price = 50_000 * S;
        assertEq(
            InsuranceVaultLib.heldOiTermOf(120 * S, 20 * S, price), 5_000 * S, "trailing below live: 0.5% of 20 x $50k"
        );
        assertEq(
            InsuranceVaultLib.heldOiTermOf(10 * S, 20 * S, price), 2_500 * S, "live below trailing: 0.5% of 10 x $50k"
        );
        assertEq(InsuranceVaultLib.heldOiTermOf(120 * S, 0, price), 30_000 * S, "no day-old sample: 0.5% of 120 x $50k");
        // One wei of size at $50k is 50,000 wei of notional; 0.5% of it.
        assertEq(InsuranceVaultLib.heldOiTermOf(120 * S, 1, price), 250, "a flat stretch in the window");
    }
}
