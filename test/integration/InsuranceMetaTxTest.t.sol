// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";

/// @title InsuranceMetaTxTest
/// @notice The relayer (EIP-712) paths of all three insurance functions: fee routing on each leg
///         (deducted from the deposit, pulled from the wallet for a request or a redemption lock,
///         deducted from the payout), the fee-exceeds-deposit guard, and nonce replay.
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
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;

        vm.prank(user);
        usdc.approve(address(pair), (amount + fee) * USDC_SCALE / BAZAAR_SCALE);
        bytes memory sig =
            _sign(keccak256(abi.encode(MetaTxLib.DEPOSIT_TO_INSURANCE_TYPEHASH, amount, nonce, deadline, fee)));

        uint256 userUsdcBefore = usdc.balanceOf(user);
        vm.prank(relayer);
        pair.depositToInsurance(amount, new bytes[](0), nonce, deadline, fee, sig, "");

        assertEq(pair.insuranceShares(user), amount, "shares minted to the signer, not the relayer");
        assertEq(pair.insuranceShares(relayer), 0, "relayer holds nothing");
        assertEq(_escrowOwed(relayer), fee, "fee accrued to the relayer");
        assertEq(userUsdcBefore - usdc.balanceOf(user), (amount + fee) / 1e12, "user funded amount + fee");

        // Same signature again: the nonce is consumed.
        vm.prank(relayer);
        vm.expectRevert();
        pair.depositToInsurance(amount, new bytes[](0), nonce, deadline, fee, sig, "");
    }

    /// @notice A relayer fee >= the deposit amount is rejected outright.
    function test_metaTx_depositToInsurance_feeExceedsDepositReverts() public {
        uint256 amount = BAZAAR_SCALE / 2; // 50 cents
        uint256 fee = BAZAAR_SCALE; // $1: at the relayer cap, but >= the amount -> reverts
        uint256 nonce = pair.metaTxNonces(user);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;

        vm.prank(user);
        usdc.approve(address(pair), (amount + fee) * USDC_SCALE / BAZAAR_SCALE);
        bytes memory sig =
            _sign(keccak256(abi.encode(MetaTxLib.DEPOSIT_TO_INSURANCE_TYPEHASH, amount, nonce, deadline, fee)));

        vm.prank(relayer);
        vm.expectRevert(BazaarPair.BazaarPair__RelayerFeeExceedsDeposit.selector);
        pair.depositToInsurance(amount, new bytes[](0), nonce, deadline, fee, sig, "");
    }

    /// @notice requestInsuranceWithdrawal via relayer: the fee is pulled from the signer's WALLET
    ///         (there is no amount to deduct from), and the request is recorded for the signer.
    function test_metaTx_requestInsuranceWithdrawal_viaRelayer() public {
        // The user deposits directly first.
        vm.startPrank(user);
        usdc.approve(address(pair), 1_000 * USDC_SCALE);
        pair.depositToInsurance(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();
        uint256 shares = pair.insuranceShares(user);

        uint256 fee = BAZAAR_SCALE / 2;
        uint256 nonce = pair.metaTxNonces(user);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        vm.prank(user);
        usdc.approve(address(pair), fee * USDC_SCALE / BAZAAR_SCALE);
        bytes memory sig =
            _sign(keccak256(abi.encode(MetaTxLib.REQUEST_INSURANCE_WITHDRAWAL_TYPEHASH, shares, nonce, deadline, fee)));

        uint256 userUsdcBefore = usdc.balanceOf(user);
        vm.prank(relayer);
        pair.requestInsuranceWithdrawal(shares, nonce, deadline, fee, sig, "");

        assertEq(pair.insuranceWithdrawalRequestTs(user), vm.getBlockTimestamp(), "request recorded for the signer");
        assertEq(pair.insuranceWithdrawalRequestShareAmount(user), shares, "full share amount requested");
        assertEq(_escrowOwed(relayer), fee, "fee accrued to the relayer from the wallet pull");
        assertEq(userUsdcBefore - usdc.balanceOf(user), fee / 1e12, "only the fee left the wallet");
    }

    /// @dev Relays one signed executeInsuranceWithdrawal as `submitter`, carrying `fee` and
    ///      `permitData`, with a fresh price.
    function _relayExecute(address submitter, uint256 fee, bytes memory permitData) internal {
        uint256 nonce = pair.metaTxNonces(user);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        bytes memory sig =
            _sign(keccak256(abi.encode(MetaTxLib.EXECUTE_INSURANCE_WITHDRAWAL_TYPEHASH, nonce, deadline, fee)));
        bytes[] memory pu = _freshPrice();
        vm.prank(submitter);
        pair.executeInsuranceWithdrawal(pu, nonce, deadline, fee, sig, permitData);
    }

    /// @dev An ERC-2612 permit from the signer for `value` (BAZAAR precision) in favour of the
    ///      pair, encoded the way BazaarPair._executePermit decodes it.
    function _signPermit(uint256 value) internal view returns (bytes memory) {
        uint256 usdcValue = value / 1e12;
        uint256 permitDeadline = vm.getBlockTimestamp() + 30;
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(
            abi.encode(permitTypehash, user, address(pair), usdcValue, usdc.nonces(user), permitDeadline)
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(userPk, MessageHashUtils.toTypedDataHash(usdc.DOMAIN_SEPARATOR(), structHash));
        return abi.encode(usdcValue, permitDeadline, v, r, s);
    }

    /// @dev Deposit, request the whole stake, and serve the cooldown, all as the signer. The
    ///      deposit spends its whole approval, so the wallet is left with no allowance.
    function _depositRequestAndRipen() internal {
        vm.startPrank(user);
        usdc.approve(address(pair), 1_000 * USDC_SCALE);
        pair.depositToInsurance(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "", "");
        pair.requestInsuranceWithdrawal(1_000 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);
    }

    /// @notice Each relayed call of the exit pays whoever submits it. The lock pays out nothing, so
    ///         its fee is pulled from the signer's wallet for the relayer that submitted it; a
    ///         different relayer submits the paying call and is paid out of the payout.
    function test_metaTx_executeInsuranceWithdrawal_eachCallPaysItsOwnRelayer() public {
        _depositRequestAndRipen();
        address claimRelayer = makeAddr("claimRelayer");
        uint256 lockFee = BAZAAR_SCALE / 4; // 25 cents
        uint256 claimFee = BAZAAR_SCALE / 2; // 50 cents (relayer fee cap is $1)

        vm.prank(user);
        usdc.approve(address(pair), lockFee / 1e12);
        uint256 userUsdcBefore = usdc.balanceOf(user);
        _relayExecute(relayer, lockFee, "");
        assertEq(userUsdcBefore - usdc.balanceOf(user), lockFee / 1e12, "the lock's fee came from the wallet");
        assertEq(_escrowOwed(relayer), lockFee, "and accrued to the lock's relayer");
        assertEq(pair.insuranceShares(user), 1_000 * BAZAAR_SCALE, "the relayed lock burns nothing");

        _warpToRedemptionClaim(pair, user);
        uint256 beforeClaim = usdc.balanceOf(user);
        _relayExecute(claimRelayer, claimFee, "");

        // Share price stayed 1:1 (no trading in between): payout 1,000, the claim fee carved from it.
        assertEq(pair.insuranceShares(user), 0, "shares burned");
        assertEq(_escrowOwed(claimRelayer), claimFee, "the claim's relayer is paid from the payout");
        assertEq(_escrowOwed(relayer), lockFee, "the lock's relayer keeps its own fee");
        assertEq(
            usdc.balanceOf(user) - beforeClaim, 1_000 * USDC_SCALE - claimFee / 1e12, "signer got payout minus fee"
        );
        assertEq(_claimFees(relayer), lockFee / 1e12, "the lock's relayer claims its fee");
        assertEq(_claimFees(claimRelayer), claimFee / 1e12, "the claim's relayer claims its fee");
    }

    /// @notice With no allowance left, a permit carried by the relayed lock funds its fee.
    function test_metaTx_executeInsuranceWithdrawal_lockFeeViaPermit() public {
        _depositRequestAndRipen();
        uint256 fee = BAZAAR_SCALE / 4;
        assertEq(usdc.allowance(user, address(pair)), 0, "fixture: no allowance left");

        _relayExecute(relayer, fee, _signPermit(fee));
        assertEq(_escrowOwed(relayer), fee, "the permit funded the lock's fee");
        assertEq(usdc.allowance(user, address(pair)), 0, "and the pull spent it");
        (bool isLocked,,,,) = lens.getInsuranceWithdrawalLock(address(pair), user);
        assertTrue(isLocked, "and the lock was recorded");
    }

    /// @notice Without an allowance or a permit the relayed lock's fee cannot be pulled, so the
    ///         call reverts: no lock is recorded and the nonce is not used.
    function test_metaTx_executeInsuranceWithdrawal_lockFeeUnfundedReverts() public {
        _depositRequestAndRipen();
        uint256 fee = BAZAAR_SCALE / 4;
        uint256 nonce = pair.metaTxNonces(user);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        bytes memory sig =
            _sign(keccak256(abi.encode(MetaTxLib.EXECUTE_INSURANCE_WITHDRAWAL_TYPEHASH, nonce, deadline, fee)));
        bytes[] memory pu = _freshPrice();
        vm.prank(relayer);
        vm.expectRevert();
        pair.executeInsuranceWithdrawal(pu, nonce, deadline, fee, sig, "");

        (bool isLocked,,,,) = lens.getInsuranceWithdrawalLock(address(pair), user);
        assertFalse(isLocked, "the refused call recorded no lock");
        assertEq(pair.metaTxNonces(user), nonce, "nor used the nonce");
    }

    /// @notice Only a call that pays nothing funds its fee from the wallet: a relayed claim whose
    ///         payout is above zero but no more than its fee reverts, burning nothing and leaving
    ///         the lock claimable.
    function test_metaTx_executeInsuranceWithdrawal_claimNotAboveItsFeeReverts() public {
        vm.startPrank(user);
        usdc.approve(address(pair), 1_000 * USDC_SCALE);
        pair.depositToInsurance(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "", "");
        pair.requestInsuranceWithdrawal(BAZAAR_SCALE / 2, 0, 0, 0, "", ""); // 50 cents of shares
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);
        _relayExecute(relayer, 0, ""); // the lock, relayed without a fee
        _warpToRedemptionClaim(pair, user);

        uint256 fee = BAZAAR_SCALE * 3 / 4; // 75 cents, above the 50-cent payout
        uint256 nonce = pair.metaTxNonces(user);
        uint256 deadline = vm.getBlockTimestamp() + MetaTxLib.MAX_DEADLINE_WINDOW;
        bytes memory sig =
            _sign(keccak256(abi.encode(MetaTxLib.EXECUTE_INSURANCE_WITHDRAWAL_TYPEHASH, nonce, deadline, fee)));
        bytes[] memory pu = _freshPrice();
        vm.prank(relayer);
        vm.expectRevert(BazaarPair.BazaarPair__AmountLteRelayerFee.selector);
        pair.executeInsuranceWithdrawal(pu, nonce, deadline, fee, sig, "");

        assertEq(pair.insuranceShares(user), 1_000 * BAZAAR_SCALE, "nothing burned");
        (bool isLocked,,,,) = lens.getInsuranceWithdrawalLock(address(pair), user);
        assertTrue(isLocked, "the lock is still there to claim");
    }
}
