// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @dev Hosts a Vault so the external (DELEGATECALL) InsuranceVaultLib.payUmaProposerReward runs in
///      this contract's storage — the same context BazaarPair provides it. Mirrors the pair's
///      insuranceFundBalance / USDC-holding role.
contract PayRewardHarness {
    BazaarTypes.Vault internal vault;

    function setInsurance(uint256 b) external {
        vault.insuranceFundBalance = b;
    }

    function insurance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function pay(address usdc, address proposer) external {
        InsuranceVaultLib.payUmaProposerReward(vault, usdc, proposer);
    }
}

/// @notice `payUmaProposerReward` debits the insurance fund mid-termination and had zero direct
///         assertions. These pin the 1-bps computation, the $100 cap, the zero-reward early return,
///         and the soft-fail restore (a blacklisted proposer must not DoS termination OR silently
///         leak the fund) — an error in any arm breaks the I+D books during the termination flow.
contract TerminatorProposerRewardTest is Test {
    uint256 constant SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;

    PayRewardHarness internal h;
    MockUSDC internal usdc;
    address internal proposer = makeAddr("proposer");

    // transfer(address,uint256) selector
    bytes4 constant TRANSFER_SEL = 0xa9059cbb;

    function setUp() public {
        h = new PayRewardHarness();
        usdc = new MockUSDC();
        usdc.mint(address(h), 1_000_000 * USDC_SCALE); // fund the "pair" so real payouts can settle
    }

    /// @notice A large fund makes 1 bps exceed $100, so the reward caps at $100 and the proposer
    ///         receives exactly $100.
    function test_reward_capsAt100() public {
        h.setInsurance(2_000_000 * SCALE); // 1 bps = $200 -> capped to $100
        uint256 fundBefore = h.insurance();
        h.pay(address(usdc), proposer);

        assertEq(fundBefore - h.insurance(), 100 * SCALE, "fund debited exactly $100 (cap)");
        assertEq(usdc.balanceOf(proposer), 100 * USDC_SCALE, "proposer paid $100");
    }

    /// @notice Below the cap the reward is exactly 1 bps of the fund. $50k fund -> $50.
    function test_reward_oneBpsBelowCap() public {
        h.setInsurance(50_000 * SCALE); // 1 bps = $50
        h.pay(address(usdc), proposer);

        assertEq(h.insurance(), 50_000 * SCALE - 50 * SCALE, "fund debited $50 (1 bps)");
        assertEq(usdc.balanceOf(proposer), 50 * USDC_SCALE, "proposer paid $50");
    }

    /// @notice A fund so small that 1 bps rounds to zero is a no-op — nothing debited, nothing sent.
    function test_reward_zeroReward_noOp() public {
        h.setInsurance(999); // 999 * 10 / 10000 = 0
        h.pay(address(usdc), proposer);

        assertEq(h.insurance(), 999, "no debit on zero reward");
        assertEq(usdc.balanceOf(proposer), 0, "nothing sent");
    }

    /// @notice A reward positive in 1e18 terms but under one USDC micro-unit sends nothing, so the
    ///         debit is restored (net-zero) — the fund is never silently drained by sub-µUSDC dust.
    function test_reward_subMicroUsdc_restored() public {
        h.setInsurance(1e14); // 1 bps = 1e11 (>0) but 1e11/1e12 = 0 USDC units
        h.pay(address(usdc), proposer);

        assertEq(h.insurance(), 1e14, "sub-microUSDC reward restored (net zero)");
        assertEq(usdc.balanceOf(proposer), 0, "nothing sent");
    }

    /// @notice A failing transfer (e.g. a blacklisted proposer, transfer returns false) is soft-failed:
    ///         the debit is restored so the fund is intact and the termination flow is not DoS'd.
    function test_reward_transferReturnsFalse_restored() public {
        h.setInsurance(50_000 * SCALE);
        // Force transfer(...) -> false regardless of args.
        vm.mockCall(address(usdc), abi.encodeWithSelector(TRANSFER_SEL), abi.encode(false));

        h.pay(address(usdc), proposer);

        assertEq(h.insurance(), 50_000 * SCALE, "debit restored on failed transfer");
        assertEq(usdc.balanceOf(proposer), 0, "blacklisted proposer receives nothing");
    }
}
