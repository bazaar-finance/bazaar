// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";

/// @title InsuranceMetaTxTest
/// @notice The relayer (EIP-712) paths of all three insurance functions: fee routing on each leg
///         (deducted from deposit, pulled from wallet, deducted from payout), the
///         fee-exceeds-deposit guard, and nonce replay.
contract InsuranceMetaTxTest is IntegrationBase {
    address internal user;
    uint256 internal userPk;
    address internal relayer = makeAddr("relayer");

    function setUp() public override {
        super.setUp();
        (user, userPk) = makeAddrAndKey("metaTxUser");
        usdc.mint(user, 100_000 * USDC_SCALE);
    }

    function _sign(bytes32 structHash) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(pair.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice depositToInsurance via relayer: shares mint to the SIGNER, the fee comes out of the
    ///         pulled amount, and the same signature cannot be replayed.
    function test_metaTx_depositToInsurance_viaRelayer() public {
        uint256 amount = 1_000 * BAZAAR_SCALE;
        uint256 fee = BAZAAR_SCALE / 2; // 50 cents (relayer fee cap is $1)
        uint256 nonce = pair.metaTxNonces(user);
        uint256 deadline = vm.getBlockTimestamp() + 30;

        vm.prank(user);
        usdc.approve(address(pair), (amount + fee) * USDC_SCALE / BAZAAR_SCALE);
        bytes memory sig =
            _sign(keccak256(abi.encode(MetaTxLib.DEPOSIT_TO_INSURANCE_TYPEHASH, amount, nonce, deadline, fee)));

        uint256 userUsdcBefore = usdc.balanceOf(user);
        vm.prank(relayer);
        pair.depositToInsurance(amount, nonce, deadline, fee, sig, "");

        assertEq(pair.insuranceShares(user), amount, "shares minted to the signer, not the relayer");
        assertEq(pair.insuranceShares(relayer), 0, "relayer holds nothing");
        assertEq(usdc.balanceOf(relayer), fee / 1e12, "relayer paid the fee");
        assertEq(userUsdcBefore - usdc.balanceOf(user), (amount + fee) / 1e12, "user funded amount + fee");

        // Same signature again: the nonce is consumed.
        vm.prank(relayer);
        vm.expectRevert();
        pair.depositToInsurance(amount, nonce, deadline, fee, sig, "");
    }

    /// @notice A relayer fee >= the deposit amount is rejected outright.
    function test_metaTx_depositToInsurance_feeExceedsDepositReverts() public {
        uint256 amount = BAZAAR_SCALE / 2; // 50 cents
        uint256 fee = BAZAAR_SCALE; // $1: at the relayer cap, but >= the amount -> reverts
        uint256 nonce = pair.metaTxNonces(user);
        uint256 deadline = vm.getBlockTimestamp() + 30;

        vm.prank(user);
        usdc.approve(address(pair), (amount + fee) * USDC_SCALE / BAZAAR_SCALE);
        bytes memory sig =
            _sign(keccak256(abi.encode(MetaTxLib.DEPOSIT_TO_INSURANCE_TYPEHASH, amount, nonce, deadline, fee)));

        vm.prank(relayer);
        vm.expectRevert(BazaarPair.BazaarPair__RelayerFeeExceedsDeposit.selector);
        pair.depositToInsurance(amount, nonce, deadline, fee, sig, "");
    }

    /// @notice requestInsuranceWithdrawal via relayer: the fee is pulled from the signer's WALLET
    ///         (there is no amount to deduct from), and the request is recorded for the signer.
    function test_metaTx_requestInsuranceWithdrawal_viaRelayer() public {
        // The user deposits directly first.
        vm.startPrank(user);
        usdc.approve(address(pair), 1_000 * USDC_SCALE);
        pair.depositToInsurance(1_000 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.stopPrank();
        uint256 shares = pair.insuranceShares(user);

        uint256 fee = BAZAAR_SCALE / 2;
        uint256 nonce = pair.metaTxNonces(user);
        uint256 deadline = vm.getBlockTimestamp() + 30;
        vm.prank(user);
        usdc.approve(address(pair), fee * USDC_SCALE / BAZAAR_SCALE);
        bytes memory sig =
            _sign(keccak256(abi.encode(MetaTxLib.REQUEST_INSURANCE_WITHDRAWAL_TYPEHASH, shares, nonce, deadline, fee)));

        uint256 userUsdcBefore = usdc.balanceOf(user);
        vm.prank(relayer);
        pair.requestInsuranceWithdrawal(shares, nonce, deadline, fee, sig, "");

        assertEq(pair.insuranceWithdrawalRequestTs(user), vm.getBlockTimestamp(), "request recorded for the signer");
        assertEq(pair.insuranceWithdrawalRequestShareAmount(user), shares, "full share amount requested");
        assertEq(usdc.balanceOf(relayer), fee / 1e12, "relayer paid from the wallet");
        assertEq(userUsdcBefore - usdc.balanceOf(user), fee / 1e12, "only the fee left the wallet");
    }

    /// @notice executeInsuranceWithdrawal via relayer after the cooldown: the fee is carved out of
    ///         the payout, the remainder reaches the signer.
    function test_metaTx_executeInsuranceWithdrawal_viaRelayer() public {
        vm.startPrank(user);
        usdc.approve(address(pair), 1_000 * USDC_SCALE);
        pair.depositToInsurance(1_000 * BAZAAR_SCALE, 0, 0, 0, "", "");
        pair.requestInsuranceWithdrawal(1_000 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 20 days + 1);

        uint256 fee = BAZAAR_SCALE / 2; // 50 cents (relayer fee cap is $1)
        uint256 nonce = pair.metaTxNonces(user);
        uint256 deadline = vm.getBlockTimestamp() + 30;
        bytes memory sig =
            _sign(keccak256(abi.encode(MetaTxLib.EXECUTE_INSURANCE_WITHDRAWAL_TYPEHASH, nonce, deadline, fee)));

        uint256 userUsdcBefore = usdc.balanceOf(user);
        bytes[] memory pu = _freshPrice();
        vm.prank(relayer);
        pair.executeInsuranceWithdrawal(pu, nonce, deadline, fee, sig);

        // Share price stayed 1:1 (no trading in between): payout 1,000, 50-cent fee to the relayer.
        assertEq(pair.insuranceShares(user), 0, "shares burned");
        assertEq(usdc.balanceOf(relayer), fee / 1e12, "relayer fee from the payout");
        assertEq(usdc.balanceOf(user) - userUsdcBefore, 1_000 * USDC_SCALE - fee / 1e12, "signer got payout minus fee");
    }
}
