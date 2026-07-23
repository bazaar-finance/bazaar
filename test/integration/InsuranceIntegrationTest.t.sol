// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";

/// @title InsuranceIntegrationTest
/// @notice End-to-end insurance-fund withdrawal lifecycle: deposit → request → 20-day cooldown →
///         execute. Exercises the two-step gate, share burn, and USDC return through the live pair.
contract InsuranceIntegrationTest is IntegrationBase {
    /// @dev Execute-with-fee: build the price update before the prank and forward the Pyth fee.
    function _executeInsuranceWithdrawal(address user) internal {
        bytes[] memory pu = _freshPrice();
        uint256 fee = pair.getPythFee(pu);
        vm.deal(user, fee);
        vm.prank(user);
        pair.executeInsuranceWithdrawal{value: fee}(pu, 0, 0, 0, "");
    }

    /// @notice Full deposit → request → cooldown → execute cycle: the request cannot execute before the
    ///         20-day cooldown, then executes cleanly — burning the shares and returning USDC at NAV.
    function test_e2e_Insurance_TwoStepWithdrawal() public {
        _depositInsurance(carol, 1_000 * BAZAAR_SCALE);
        uint256 shares = pair.insuranceShares(carol);
        assertGt(shares, 0, "carol received insurance shares");

        // Step 1: request — records the timestamp, does not move shares yet.
        uint256 nowTs = vm.getBlockTimestamp();
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
        assertEq(pair.insuranceWithdrawalRequestTs(carol), nowTs, "withdrawal request timestamped");
        assertEq(pair.insuranceWithdrawalRequestShareAmount(carol), shares, "request records the share amount");
        assertEq(pair.insuranceShares(carol), shares, "shares not yet burned");

        uint256 fundBefore = _insuranceBal();
        uint256 totalBefore = pair.totalInsuranceShares();
        uint256 usdcBefore = usdc.balanceOf(carol);
        uint256 expectedBazaar = shares * fundBefore / totalBefore;

        // Executing before the cooldown elapses reverts.
        {
            bytes[] memory pu = _freshPrice();
            uint256 fee = pair.getPythFee(pu);
            vm.deal(carol, fee);
            vm.prank(carol);
            vm.expectRevert();
            pair.executeInsuranceWithdrawal{value: fee}(pu, 0, 0, 0, "");
        }

        // Step 2: after the 20-day cooldown (inside the 3-day window) it executes.
        vm.warp(vm.getBlockTimestamp() + 20 days + 1);
        _executeInsuranceWithdrawal(carol);

        assertEq(pair.insuranceShares(carol), 0, "shares burned");
        assertEq(pair.totalInsuranceShares(), totalBefore - shares, "share supply reduced");
        assertEq(pair.insuranceWithdrawalRequestTs(carol), 0, "request cleared");
        assertLt(_insuranceBal(), fundBefore, "insurance fund debited");
        assertGt(usdc.balanceOf(carol), usdcBefore, "USDC returned to carol");
        assertApproxEqAbs(
            usdc.balanceOf(carol) - usdcBefore, expectedBazaar * USDC_SCALE / BAZAAR_SCALE, 1, "USDC returned at NAV"
        );
    }

    /// @notice Waiting past the 3-day execution window (cooldown + window) makes the request expire —
    ///         `executeInsuranceWithdrawal` reverts and the shares remain.
    function test_e2e_Insurance_WithdrawalWindowExpires() public {
        _depositInsurance(carol, 1_000 * BAZAAR_SCALE);
        uint256 shares = pair.insuranceShares(carol);

        vm.prank(carol);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");

        // 20-day cooldown + 3-day window + slack → the request is stale.
        vm.warp(vm.getBlockTimestamp() + 20 days + 3 days + 1);
        bytes[] memory pu = _freshPrice();
        uint256 fee = pair.getPythFee(pu);
        vm.deal(carol, fee);
        vm.prank(carol);
        vm.expectRevert();
        pair.executeInsuranceWithdrawal{value: fee}(pu, 0, 0, 0, "");

        assertEq(pair.insuranceShares(carol), shares, "shares retained after expiry");
    }
}
