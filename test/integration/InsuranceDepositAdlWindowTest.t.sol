// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";
import {IntegrationBase} from "./IntegrationBase.sol";

/// @title InsuranceDepositAdlWindowTest
/// @notice Insurance deposits are refused while an ADL window is pending, and wherever the mark a
///         deposit carries would open one: where the inventory's loss exceeds free capital above
///         the reserve. A batch that closes winners at the estates' bankruptcy price moves each
///         closed slice's loss past its seizure off the fund and onto them. Shares minted before
///         the batch would take part of that recovery from incumbents the window keeps from
///         redeeming, and the capital would shrink the batch or, large enough, keep the window
///         shut and leave the LPs the loss the winners would have paid.
contract InsuranceDepositAdlWindowTest is IntegrationBase {
    uint256 constant SIZE = 72 * BAZAAR_SCALE / 100;
    uint256 constant MARK_USD = 30_000;
    uint256 constant AMOUNT = 10_000 * BAZAAR_SCALE;

    // ---------------------------- fixture ----------------------------

    /// @dev dave long and bob short 0.72 at $80k, dave with $19,200 of collateral, bob with $16,000.
    function _openPositions() internal {
        _deposit(dave, 19_200 * BAZAAR_SCALE);
        _deposit(bob, 16_000 * BAZAAR_SCALE);
        _placeLimitAt(dave, true, SIZE, 80_000 * BAZAAR_SCALE, 80_000);
        _roll(2);
        _placeLimitAt(bob, false, SIZE, 80_000 * BAZAAR_SCALE, 80_000);
        assertEq(_posSize(bob), SIZE, "fixture: dave and bob crossed");
    }

    /// @dev Seize dave as the keeper, at a fresh price three seconds on.
    function _seizeDaveAt(uint256 priceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceAt(priceUsd);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(dave), pu), 1, "fixture: dave seized");
    }

    /// @dev Seizing dave at $30k hands the vault a 0.72 long whose $36,000 loss is far past his
    ///      $19,200 and the fund, so a window opens with bob, the short, as the winner a batch
    ///      closes.
    function _openWindow() internal {
        _openPositions();
        _seizeDaveAt(MARK_USD);
        assertTrue(pair.isAdlPending(), "fixture: the estate's loss exceeds the fund");
    }

    /// @dev Seizing dave at $52k, just under his bankruptcy price near $53,333, leaves the vault a
    ///      0.72 long whose loss past the seizure is under $1,000, inside the fund's headroom, so no
    ///      window opens. At $44k the same inventory loses over $6,700 past the seizure, beyond it.
    function _holdInventoryWithinHeadroom() internal {
        _openPositions();
        _seizeDaveAt(52_000);
        assertGt(_pendingLiqSize(), 0, "fixture: the vault holds dave's position");
        assertFalse(pair.isAdlPending(), "fixture: the loss fits the fund's headroom");
    }

    function _pendingLiqSize() internal view returns (uint256 size) {
        (,,,,,, size,,,,,,,,,,) = pair.pairVault();
    }

    /// @dev A deposit of `amount` by `user` carrying a fresh update at `priceUsd`, three seconds on,
    ///      expected to revert with `err`.
    function _expectDepositRefused(address user, uint256 amount, uint256 priceUsd, bytes4 err) internal {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceAt(priceUsd);
        vm.startPrank(user);
        usdc.approve(address(pair), amount * USDC_SCALE / BAZAAR_SCALE);
        vm.expectRevert(err);
        pair.depositToInsurance(amount, pu, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    // ---------------------------- window pending ----------------------------

    /// @notice Neither an outside LP nor the winner the next batch would close can buy shares
    ///         while the window is pending. The winner's capital would also have raised the fund's
    ///         headroom and so shrunk that batch, buying its way out of its own haircut.
    function test_deposit_refusedWhileWindowPending() public {
        _openWindow();

        bytes4 halted = BazaarPair.BazaarPair__TradingHalted.selector;
        _expectDepositRefused(carol, AMOUNT, MARK_USD, halted);
        _expectDepositRefused(bob, AMOUNT, MARK_USD, halted);
        assertTrue(pair.isAdlPending(), "the refused deposits leave the window pending");
    }

    /// @notice The refusal lifts with the window: once a batch resolves it, a deposit mints shares
    ///         at the fund's value at the mark as usual.
    function test_deposit_acceptedOnceTheBatchResolvesTheWindow() public {
        _openWindow();

        // Past the Dutch decay, so bob's score clears the threshold.
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION + 1);
        bytes[] memory pu = _priceAt(MARK_USD);
        vm.prank(seq);
        pair.executeAdl(_arr1(bob), new address[](0), pu);
        assertFalse(pair.isAdlPending(), "the batch resolved the window");

        uint256 supply = pair.totalInsuranceShares();
        uint256 quoted = lens.quoteInsuranceDeposit(address(pair), AMOUNT, MARK_USD * BAZAAR_SCALE);
        _depositInsurance(carol, AMOUNT);
        uint256 minted = pair.insuranceShares(carol);
        assertGt(minted, 0, "the deposit is accepted");
        assertEq(pair.totalInsuranceShares(), supply + minted, "and mints into the live supply");
        assertApproxEqRel(minted, quoted, 1e12, "at the fund's value at the mark");
        _assertBooks("after the deposit");
    }

    // ---------------------------- window due, not yet open ----------------------------

    /// @notice A deposit whose own mark takes the inventory's loss past the fund's headroom is
    ///         refused before any health check has opened the window: the outside LP's, and the
    ///         winner's however large, since enough capital would keep the window shut. A refresh
    ///         at that same mark then opens the window, so the refusal tracks the gate.
    function test_deposit_refusedWhereItsOwnMarkWouldOpenTheWindow() public {
        _holdInventoryWithinHeadroom();

        bytes4 blocking = InsuranceVaultLib.InsuranceVaultLib__AdlBlocking.selector;
        _expectDepositRefused(carol, AMOUNT, 44_000, blocking);
        _expectDepositRefused(bob, 50_000 * BAZAAR_SCALE, 44_000, blocking);
        assertFalse(pair.isAdlPending(), "the refused deposits leave no latch behind");

        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceAt(44_000);
        vm.prank(seq);
        pair.refreshPrice(pu);
        assertTrue(pair.isAdlPending(), "a health check at the same mark opens the window");
    }

    /// @notice Control: while the loss fits the fund's headroom the same deposit is accepted, so the
    ///         refusal above is the loss crossing the trigger, not the inventory being held.
    function test_deposit_acceptedWhileTheLossFitsTheHeadroom() public {
        _holdInventoryWithinHeadroom();

        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceAt(52_000);
        vm.startPrank(carol);
        usdc.approve(address(pair), AMOUNT * USDC_SCALE / BAZAAR_SCALE);
        pair.depositToInsurance(AMOUNT, pu, 0, 0, 0, "", "");
        vm.stopPrank();

        assertGt(pair.insuranceShares(carol), 0, "the deposit is accepted");
        assertFalse(pair.isAdlPending(), "and no window is open");
        _assertBooks("after the deposit");
    }
}
