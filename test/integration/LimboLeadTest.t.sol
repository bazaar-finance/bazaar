// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";

/// @notice Limbo opens LIMBO_LEAD before a scheduled cutoff, on every entry point at once, so the
///         last block that trades is stamped a window and a second before UMA's settlement window
///         opens. That block cannot store a print from the window, and a Pyth clock running a
///         second or two ahead of the block timestamp does not put the settlement print within
///         its reach.
contract LimboLeadTest is IntegrationBase {
    uint256 internal cutoff;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 20_000 * BAZAAR_SCALE);
    }

    function _schedule(uint256 ts) internal {
        vm.prank(pair.umaContract());
        pair.setScheduledTermination(ts, address(0));
        cutoff = pair.scheduledTerminationTs();
    }

    function _createOrder(address user) internal {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        pair.createOrder(_limitSpec(true, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE), _hintsNone(), pu, 0, 0, 0, "", "");
    }

    function _expectAllRefused() internal {
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        vm.expectRevert(BazaarPair.BazaarPair__PairScheduledForTermination.selector);
        pair.createOrder(_limitSpec(true, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE), _hintsNone(), pu, 0, 0, 0, "", "");

        vm.startPrank(bob);
        usdc.approve(address(pair), 2_000 * USDC_SCALE);
        vm.expectRevert(CollateralLib.CollateralLib__PairScheduledForTermination.selector);
        pair.depositCollateral(1_000 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.expectRevert(
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__PairScheduledForTermination.selector, cutoff)
        );
        pair.depositToInsurance(1_000 * BAZAAR_SCALE, pu, 0, 0, 0, "", "");
        vm.stopPrank();

        assertEq(lens.getMaxWithdrawable(address(pair), alice, 0), 0, "the lens quotes no withdrawal");
    }

    /// @notice The block a lead and a second before the cutoff trades and takes deposits; the next
    ///         second refuses all of them.
    function test_limboOpensALeadBeforeTheCutoff() public {
        assertEq(BazaarTypes.LIMBO_LEAD, 2 * BazaarTypes.MAX_PRICE_STALENESS, "two settlement windows");
        _schedule(vm.getBlockTimestamp() + 1 days);

        vm.warp(cutoff - BazaarTypes.LIMBO_LEAD - 1);
        _createOrder(alice);
        _deposit(bob, 1_000 * BAZAAR_SCALE);
        _depositInsurance(bob, 1_000 * BAZAAR_SCALE);
        assertGt(lens.getMaxWithdrawable(address(pair), alice, 0), 0, "the lens quotes a withdrawal");

        vm.warp(cutoff - BazaarTypes.LIMBO_LEAD);
        _expectAllRefused();
    }

    /// @notice A second before the settlement window opens is already limbo, so no block that
    ///         trades sits within a second of the window's first print.
    function test_secondBeforeTheWindow_isLimbo() public {
        _schedule(vm.getBlockTimestamp() + 1 days);
        vm.warp(cutoff - BazaarTypes.MAX_PRICE_STALENESS - 1);
        _expectAllRefused();
    }

    /// @notice The last block that trades refuses a print stamped when the settlement window
    ///         opens: it lies a window and a second ahead, past the freshness bound.
    function test_lastTradingBlock_refusesTheWindowsFirstPrint() public {
        _schedule(vm.getBlockTimestamp() + 1 days);
        vm.warp(cutoff - BazaarTypes.LIMBO_LEAD - 1);
        bytes[] memory windowPrint = _priceUpdate(50_000, uint64(cutoff - BazaarTypes.MAX_PRICE_STALENESS));
        vm.expectRevert(PythErrors.StalePrice.selector);
        pair.refreshPrice(windowPrint);
    }

    /// @notice An insurance redemption inside its window locks a lead and a second before the
    ///         cutoff, and its next call a second later is refused by limbo.
    function test_insuranceRedemption_refusedFromTheLead() public {
        uint256 shares = pair.insuranceShares(deployer) / 10;
        vm.prank(deployer);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);
        _schedule(vm.getBlockTimestamp() + 1 hours);

        vm.warp(cutoff - BazaarTypes.LIMBO_LEAD - 1);
        _executeRedemption(pair, deployer, _freshPrice());
        (bool isLocked,,,,) = lens.getInsuranceWithdrawalLock(address(pair), deployer);
        assertTrue(isLocked, "the redemption locked before limbo");

        vm.warp(cutoff - BazaarTypes.LIMBO_LEAD);
        bytes[] memory pu = _freshPrice();
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__PairScheduledForTermination.selector, cutoff)
        );
        pair.executeInsuranceWithdrawal(pu, 0, 0, 0, "", "");
    }

    /// @notice The shortest lead a cutoff can be scheduled at leaves the scheduling block live and
    ///         puts limbo one second after it.
    function test_shortestLead_limboOpensTheNextSecond() public {
        uint256 scheduledAt = vm.getBlockTimestamp();
        _schedule(scheduledAt);
        assertEq(cutoff, scheduledAt + BazaarTypes.MIN_CUTOFF_LEAD, "raised to the shortest lead");

        _createOrder(alice);

        vm.warp(scheduledAt + 1);
        _expectAllRefused();
    }
}
