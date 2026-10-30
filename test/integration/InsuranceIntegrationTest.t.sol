// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";

/// @title InsuranceIntegrationTest
/// @notice End-to-end insurance-fund withdrawal lifecycle: deposit → request → cooldown → execute.
///         Exercises the two-step gate, share burn, and USDC return through the live pair.
contract InsuranceIntegrationTest is IntegrationBase {
    /// @notice Full deposit → request → cooldown → lock → claim cycle: the request cannot execute
    ///         before the cooldown elapses; inside the window the first call locks and the second
    ///         burns the shares and returns USDC at NAV.
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
            uint256 fee = oracle.getUpdateFee(pu);
            vm.deal(carol, fee);
            vm.prank(carol);
            vm.expectRevert();
            pair.executeInsuranceWithdrawal{value: fee}(pu, 0, 0, 0, "", "");
        }

        // Step 2: after the cooldown (inside the execution window) the first call locks and
        // pays nothing; the second, once its claim opens, burns the shares and pays.
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);
        _executeRedemption(pair, carol, _freshPrice());
        assertEq(pair.insuranceShares(carol), shares, "the lock burns nothing");
        assertEq(usdc.balanceOf(carol), usdcBefore, "the lock pays nothing");
        _warpToRedemptionClaim(pair, carol);
        _executeRedemption(pair, carol, _freshPrice());

        assertEq(pair.insuranceShares(carol), 0, "shares burned");
        assertEq(pair.totalInsuranceShares(), totalBefore - shares, "share supply reduced");
        assertEq(pair.insuranceWithdrawalRequestTs(carol), 0, "request cleared");
        assertLt(_insuranceBal(), fundBefore, "insurance fund debited");
        assertGt(usdc.balanceOf(carol), usdcBefore, "USDC returned to carol");
        assertApproxEqAbs(
            usdc.balanceOf(carol) - usdcBefore, expectedBazaar * USDC_SCALE / BAZAAR_SCALE, 1, "USDC returned at NAV"
        );
    }

    /// @notice Waiting past the execution window (cooldown + window) makes the request expire —
    ///         `executeInsuranceWithdrawal` reverts and the shares remain.
    function test_e2e_Insurance_WithdrawalWindowExpires() public {
        _depositInsurance(carol, 1_000 * BAZAAR_SCALE);
        uint256 shares = pair.insuranceShares(carol);

        vm.prank(carol);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");

        // Cooldown + window + slack → the request is stale.
        vm.warp(
            vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN
                + InsuranceVaultLib.INSURANCE_WITHDRAWAL_WINDOW + 1
        );
        bytes[] memory pu = _freshPrice();
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(carol, fee);
        vm.prank(carol);
        vm.expectRevert();
        pair.executeInsuranceWithdrawal{value: fee}(pu, 0, 0, 0, "", "");

        assertEq(pair.insuranceShares(carol), shares, "shares retained after expiry");
    }
}
