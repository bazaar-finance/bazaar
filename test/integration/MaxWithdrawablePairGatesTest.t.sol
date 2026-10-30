// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";

/// @notice BazaarPairLens.getMaxWithdrawable against the pair-level refusals of withdrawCollateral
///         and against its terminal branch. On a live pair the quote is capped at the deposits
///         ledger and reads 0 in limbo, on a USDC balance short of the books, and, for an account
///         the pair prices, on realized bad debt. After finalize it is the terminal amount the
///         withdrawal accepts: collateral plus the registered claim at the profit ratio, with a
///         still-open solvent position realized at the settlement price, capped at the ledger
///         while any other position is open.
contract MaxWithdrawablePairGatesTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant ESCAPE = 14 days; // BazaarTypes.TERMINAL_SETTLEMENT_ESCAPE
    uint256 constant LOW_BRACKET = 49_950 * BAZAAR_SCALE; // spot − the mock feed's 0.1% conf at $50k

    function _quote(address user, uint256 price) internal view returns (uint256) {
        return lens.getMaxWithdrawable(address(pair), user, price);
    }

    /// @dev Vault field index 4, the deposits ledger.
    function _writeDeposited(uint256 d) internal {
        _stdstore.target(address(pair)).sig("pairVault()").depth(4).checked_write(d);
    }

    function _fix(uint256 priceUsd) internal {
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(priceUsd * BAZAAR_SCALE);
    }

    function _settle(address u) internal returns (uint256) {
        return pair.liquidate(_arr1(u), new bytes[](0));
    }

    function _profitRatio() internal view returns (uint256) {
        return pair.auxState().terminalProfitRatio;
    }

    function _withdraw(address user, uint256 amount) internal {
        vm.prank(user);
        pair.withdrawCollateral(amount, new bytes[](0), 0, 0, 0, "");
    }

    // ------------------------------------------------------------------------------------------
    // Live pair
    // ------------------------------------------------------------------------------------------

    /// @notice A flat account's quote stops at the ledger, and withdrawing it succeeds.
    function test_flat_quoteCappedAtTheLedger() public {
        _deposit(alice, 1_000 * BAZAAR_SCALE);
        uint256 ledger = 400 * BAZAAR_SCALE;
        _writeDeposited(ledger);

        assertEq(_quote(alice, 0), ledger, "capped at the ledger");
        _withdraw(alice, ledger);
    }

    /// @notice A position holder's account-level bound is capped at the ledger the same way.
    function test_position_quoteCappedAtTheLedger() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        uint256 uncapped = _quote(alice, LOW_BRACKET);
        assertGt(uncapped, 2, "setup: slack to withdraw");
        uint256 ledger = uncapped / 2;
        _writeDeposited(ledger);

        assertEq(_quote(alice, LOW_BRACKET), ledger, "capped at the ledger");
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(50_000, uint64(vm.getBlockTimestamp()));
        vm.prank(alice);
        pair.withdrawCollateral(ledger, pu, 0, 0, 0, "");
    }

    /// @notice Limbo opens LIMBO_LEAD before the cutoff and refuses every withdrawal.
    function test_limbo_quotesZero() public {
        _deposit(alice, 1_000 * BAZAAR_SCALE);
        uint256 cutoff = vm.getBlockTimestamp() + 1 days;
        vm.prank(pair.umaContract());
        pair.setScheduledTermination(cutoff, address(0));

        vm.warp(cutoff - BazaarTypes.LIMBO_LEAD - 1);
        assertEq(_quote(alice, 0), 1_000 * BAZAAR_SCALE, "a second before limbo");

        vm.warp(cutoff - BazaarTypes.LIMBO_LEAD);
        assertEq(_quote(alice, 0), 0, "in limbo");
        vm.prank(alice);
        vm.expectRevert(CollateralLib.CollateralLib__PairScheduledForTermination.selector);
        pair.withdrawCollateral(BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
    }

    /// @notice A USDC balance short of the books refuses even an account the pair does not price.
    function test_balanceShort_quotesZeroEvenUnpriced() public {
        _deposit(alice, 1_000 * BAZAAR_SCALE);
        deal(address(usdc), address(pair), _ledgerBaz() / 1e12 * 99 / 100); // 1% short, past the tolerance

        assertEq(_quote(alice, 0), 0, "short balance");
        vm.prank(alice);
        vm.expectRevert(CollateralLib.CollateralLib__WithdrawalBlockedVaultUnhealthy.selector);
        pair.withdrawCollateral(BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
    }

    /// @notice Realized bad debt refuses an account the pair prices, with a position or with
    ///         resting orders, and leaves an account with neither alone.
    function test_deficit_quotesZeroForPricedAccountsOnly() public {
        _deposit(carol, 1_000 * BAZAAR_SCALE); // flat, no orders
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _deposit(dave, 10_000 * BAZAAR_SCALE);
        _placeLimit(dave, true, BAZAAR_SCALE / 10, 40_000 * BAZAAR_SCALE); // resting, won't cross
        _stdstore.target(address(pair)).sig("pairVault()").depth(11).checked_write(uint256(1));

        assertEq(_quote(carol, 0), 1_000 * BAZAAR_SCALE, "unpriced account is not judged on bad debt");
        assertEq(_quote(alice, LOW_BRACKET), 0, "position holder");
        assertEq(_quote(dave, 50_000 * BAZAAR_SCALE), 0, "resting orders");

        _withdraw(carol, 1_000 * BAZAAR_SCALE);
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(50_000, uint64(vm.getBlockTimestamp()));
        vm.prank(dave);
        vm.expectRevert();
        pair.withdrawCollateral(BAZAAR_SCALE, pu, 0, 0, 0, "");
    }

    // ------------------------------------------------------------------------------------------
    // Termination
    // ------------------------------------------------------------------------------------------

    /// @notice Between the price fix and finalize every withdrawal is frozen.
    function test_settlementWindow_quotesZero() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _deposit(carol, 1_000 * BAZAAR_SCALE);
        _fix(55_000);

        assertEq(_quote(alice, 0), 0, "position holder");
        assertEq(_quote(carol, 0), 0, "flat depositor");
    }

    /// @notice After finalize the quote is collateral plus the claim at the profit ratio: exactly
    ///         that much withdraws, one unit more does not, and the account then quotes 0.
    function test_terminal_quoteIsTheExactBoundary() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE); // alice long at $51k
        _fix(55_000); // alice wins, bob loses within his collateral
        assertEq(pair.liquidate(_two(alice, bob), new bytes[](0)), 2, "both settled");
        pair.finalizeTermination();

        uint256 claim = pair.terminalProfitClaim(alice);
        assertGt(claim, 0, "setup: a registered claim");
        uint256 quote = _quote(alice, 0);
        assertEq(quote, _posCollateral(alice) + Math.mulDiv(claim, _profitRatio(), BAZAAR_SCALE), "the terminal amount");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralLib.CollateralLib__InsufficientCollateral.selector, quote + 1, quote)
        );
        pair.withdrawCollateral(quote + 1, new bytes[](0), 0, 0, 0, "");

        _withdraw(alice, quote);
        assertEq(_quote(alice, 0), 0, "nothing left");

        uint256 bobQuote = _quote(bob, 0);
        assertEq(bobQuote, _posCollateral(bob), "the loser's quote is what his loss left");
        _withdraw(bob, bobQuote);
    }

    /// @notice A solvent position finalize did not wait for is quoted at its equity at the
    ///         settlement price, which the withdrawal realizes before paying.
    function test_terminal_unsettledSolventPosition_quotedAtItsEquity() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(55_000);
        vm.warp(vm.getBlockTimestamp() + ESCAPE + 1);
        pair.finalizeTermination();
        assertEq(_settle(bob), 1, "the loser settles; alice is the last open position");

        uint256 quote = _quote(alice, 0);
        assertGt(quote, _posCollateral(alice), "the unrealized profit is in the quote");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralLib.CollateralLib__InsufficientCollateral.selector, quote + 1, quote)
        );
        pair.withdrawCollateral(quote + 1, new bytes[](0), 0, 0, 0, "");

        _withdraw(alice, quote);
        assertEq(_posCollateral(alice), 0, "drained");
    }

    /// @notice While another position is still open, the quote stops at what the ledger holds once
    ///         the claim is credited; a bankrupt straggler quotes 0.
    function test_terminal_quoteCappedAtTheLedgerWhileAPositionIsOpen() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(23_000); // alice deep under water
        assertEq(_settle(bob), 1, "only the winner settles");
        vm.warp(vm.getBlockTimestamp() + ESCAPE + 1);
        pair.finalizeTermination();

        uint256 claimPay = Math.mulDiv(pair.terminalProfitClaim(bob), _profitRatio(), BAZAAR_SCALE);
        uint256 ledger = _totalDeposited() + claimPay;
        assertGt(_posCollateral(bob) + claimPay, ledger, "setup: entitled above the ledger");

        uint256 quote = _quote(bob, 0);
        assertEq(quote, ledger, "capped at the ledger");
        assertEq(_quote(alice, 0), 0, "bankrupt straggler");

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralLib.CollateralLib__LedgerShortfall.selector, quote + 1, ledger)
        );
        pair.withdrawCollateral(quote + 1, new bytes[](0), 0, 0, 0, "");

        _withdraw(bob, quote);
    }

    function _two(address a, address b) internal pure returns (address[] memory u) {
        u = new address[](2);
        u[0] = a;
        u[1] = b;
    }
}
