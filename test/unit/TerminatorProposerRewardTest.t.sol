// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @dev Hosts a Vault and a FeeEscrow so the external (DELEGATECALL) InsuranceVaultLib
///      .payUmaProposerReward runs in this contract's storage — the same context BazaarPair
///      provides it.
contract PayRewardHarness {
    bytes32 internal constant PAIR_ID = bytes32("TEST");

    BazaarTypes.Vault internal vault;
    BazaarTypes.FeeEscrow internal feeEscrow;

    function setInsurance(uint256 b) external {
        vault.insuranceFundBalance = b;
    }

    function insurance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function claimable(address who) external view returns (uint256) {
        return feeEscrow.claimable[who];
    }

    function escrowTotal() external view returns (uint256) {
        return feeEscrow.total;
    }

    function pay(address proposer) external {
        InsuranceVaultLib.payUmaProposerReward(vault, feeEscrow, PAIR_ID, proposer);
    }
}

/// @notice `payUmaProposerReward` debits the insurance fund mid-termination. These pin the 1-bps
///         computation, the $100 cap, the zero-reward early return, and the escrow booking: the
///         debit and the proposer's claimable credit must move together, or the I + D + escrow
///         books drift during the termination flow.
contract TerminatorProposerRewardTest is Test {
    uint256 constant SCALE = 1e18;
    bytes32 constant PAIR_ID = bytes32("TEST");

    PayRewardHarness internal h;
    address internal proposer = makeAddr("proposer");

    function setUp() public {
        h = new PayRewardHarness();
    }

    /// @notice A large fund makes 1 bps exceed $100, so the reward caps at $100 and exactly $100
    ///         becomes claimable by the proposer.
    function test_reward_capsAt100() public {
        h.setInsurance(2_000_000 * SCALE); // 1 bps = $200 -> capped to $100
        uint256 fundBefore = h.insurance();

        vm.expectEmit(true, true, false, true, address(h));
        emit BazaarTypes.FeeAccrued(PAIR_ID, proposer, 100 * SCALE);
        h.pay(proposer);

        assertEq(fundBefore - h.insurance(), 100 * SCALE, "fund debited exactly $100 (cap)");
        assertEq(h.claimable(proposer), 100 * SCALE, "proposer owed $100");
        assertEq(h.escrowTotal(), 100 * SCALE, "escrow liability matches the debit");
    }

    /// @notice Below the cap the reward is exactly 1 bps of the fund. $50k fund -> $50.
    function test_reward_oneBpsBelowCap() public {
        h.setInsurance(50_000 * SCALE); // 1 bps = $50
        h.pay(proposer);

        assertEq(h.insurance(), 50_000 * SCALE - 50 * SCALE, "fund debited $50 (1 bps)");
        assertEq(h.claimable(proposer), 50 * SCALE, "proposer owed $50");
    }

    /// @notice A fund so small that 1 bps rounds to zero is a no-op — nothing debited, nothing owed.
    function test_reward_zeroReward_noOp() public {
        h.setInsurance(999); // 999 * 10 / 10000 = 0
        h.pay(proposer);

        assertEq(h.insurance(), 999, "no debit on zero reward");
        assertEq(h.claimable(proposer), 0, "nothing owed");
        assertEq(h.escrowTotal(), 0, "no liability recorded");
    }

    /// @notice A reward positive in 1e18 terms but under one USDC micro-unit still accrues: the
    ///         escrow keeps BAZAAR precision, so dust accumulates toward a claimable amount
    ///         instead of being dropped, and the fund is debited exactly what was credited.
    function test_reward_subMicroUsdc_accrues() public {
        h.setInsurance(1e14); // 1 bps = 1e11 (>0) but 1e11 / 1e12 = 0 USDC units
        h.pay(proposer);

        assertEq(h.insurance(), 1e14 - 1e11, "fund debited the dust reward");
        assertEq(h.claimable(proposer), 1e11, "dust accrues at full precision");
    }

    /// @notice The reward path is pure storage — no token call for a blacklisted or reverting
    ///         proposer address to break, so the termination callback that triggers it can never
    ///         be reverted by the recipient. A contract that rejects everything is credited like
    ///         any other address.
    function test_reward_revertingRecipient_stillAccrues() public {
        h.setInsurance(50_000 * SCALE);
        address hostile = address(new RevertsOnEverything());

        h.pay(hostile);

        assertEq(h.insurance(), 50_000 * SCALE - 50 * SCALE, "fund debited despite a hostile recipient");
        assertEq(h.claimable(hostile), 50 * SCALE, "credit recorded for the hostile recipient");
    }
}

/// @dev Reverts on any call or plain transfer — the shape of a recipient that would poison a push
///      payment.
contract RevertsOnEverything {
    fallback() external payable {
        revert("no");
    }

    receive() external payable {
        revert("no");
    }
}
