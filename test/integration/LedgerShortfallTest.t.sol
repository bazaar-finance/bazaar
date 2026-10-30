// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";

/// @notice Inter-user realized PnL never reaches the deposits ledger: a winner closing against a
///         fresh opener is credited into their bucket while the counterparty carrying the other
///         side of that move still holds it unrealized. `Σ bucket.collateral` can therefore exceed
///         `totalCollateralDeposited`, and nothing on the withdrawal path bounds a caller by that
///         ledger — every gate bounds them by their own balance alone.
///         A withdrawal the ledger cannot fund is refused by name on both live branches: the flat
///         branch, which reads no price and runs no vault-health check, and the position branch,
///         which reaches the debit only once the solvency, retention and IMR gates have passed.
contract LedgerShortfallTest is IntegrationBase {
    using stdStorage for StdStorage;

    /// @dev Put the deposits ledger (Vault struct depth 4) below the buckets it backs — the state
    ///      winners-realizing-before-losers produces — without staging a whole book to get there.
    function _writeDeposited(uint256 d) internal {
        _stdstore.target(address(pair)).sig("pairVault()").depth(4).checked_write(d);
    }

    /// A flat account clears every gate on its own balance, so the ledger debit is the first thing
    /// a shortfall can reach.
    function test_flatWithdrawalNamesTheShortfall() public {
        uint256 amount = 1_000 * BAZAAR_SCALE;
        _deposit(alice, amount);
        assertEq(_totalDeposited(), amount);

        uint256 ledger = 400 * BAZAAR_SCALE;
        _writeDeposited(ledger);
        assertEq(_posCollateral(alice), amount, "bucket keeps the full balance");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralLib.CollateralLib__LedgerShortfall.selector, amount, ledger));
        pair.withdrawCollateral(amount, new bytes[](0), 0, 0, 0, "");
    }

    /// The ledger is a ceiling, not a rounding allowance: the last unit it can fund leaves, and the
    /// one past it is named rather than paid down or panicked on.
    function test_flatWithdrawalClearsAtExactlyTheLedger() public {
        _deposit(alice, 1_000 * BAZAAR_SCALE);
        uint256 ledger = 400 * BAZAAR_SCALE;
        _writeDeposited(ledger);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralLib.CollateralLib__LedgerShortfall.selector, ledger + 1, ledger)
        );
        pair.withdrawCollateral(ledger + 1, new bytes[](0), 0, 0, 0, "");

        vm.prank(alice);
        pair.withdrawCollateral(ledger, new bytes[](0), 0, 0, 0, "");

        assertEq(_totalDeposited(), 0, "ledger drains to exactly zero");
        assertEq(_posCollateral(alice), 600 * BAZAAR_SCALE, "the unfunded remainder stays in the bucket");
    }

    /// The position branch ends at the same debit, so an exhausted ledger must name itself there
    /// too — the margin gates ahead of it pass on a position that is solvent and well above IMR.
    function test_positionWithdrawalNamesTheShortfall() public {
        _openPosition(alice, bob, true, 1 * BAZAAR_SCALE);
        _writeDeposited(0);

        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(50_000, uint64(vm.getBlockTimestamp()));

        uint256 amount = 1 * BAZAAR_SCALE;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CollateralLib.CollateralLib__LedgerShortfall.selector, amount, 0));
        pair.withdrawCollateral(amount, pu, 0, 0, 0, "");
    }
}
