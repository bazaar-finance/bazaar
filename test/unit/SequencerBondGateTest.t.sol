// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarSequencer} from "../../src/BazaarSequencer.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice The withdraw-side bond gates that make slashing enforceable: a sequencer cannot pull its
///         bond while recent matched volume still requires it, plus adjacent deposit/withdraw edges.
///         Mirrors SequencerFeeVolumeTest's harness (this contract is factory + registered pair).
contract SequencerBondGateTest is Test {
    BazaarSequencer internal seq;
    MockUSDC internal usdc;
    address internal op = makeAddr("operator");
    uint256 constant USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        seq = new BazaarSequencer(address(usdc), address(this)); // this == factory
        seq.registerPair(address(this));
        vm.warp(1_000_000);
        usdc.mint(op, 100_000_000 * USDC);
        vm.prank(op);
        usdc.approve(address(seq), type(uint256).max);
    }

    function _deposit(uint256 usdcAmount) internal {
        vm.prank(op);
        seq.deposit(usdcAmount);
    }

    /// @notice Rolling volume pins the bond: with $16k volume against a $1k bond (required bond
    ///         = 16k/14 ≈ $1,143) a full exit reverts — until the volume ages out of the window.
    function test_withdraw_blockedWhileRollingVolumeRequiresBond() public {
        _deposit(1000 * USDC);
        seq.recordVolume(op, 16_000 ether);

        // Read the constant before the prank: an external call inside the expectRevert argument
        // would consume it, sending the withdraw from the test contract instead of `op`.
        uint256 requiredBond = 16_000 ether / seq.VOLUME_CAP_MULTIPLIER();

        vm.prank(op);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarSequencer.Sequencer__BondBelowRollingVolumeRequirement.selector, 0, requiredBond
            )
        );
        seq.withdraw(1000 ether); // full exit while volume is live

        // Volume ages out after the 30-minute window → the same exit succeeds.
        vm.warp(block.timestamp + seq.NUM_BUCKETS() * seq.BUCKET_DURATION() + 1);
        vm.prank(op);
        seq.withdraw(1000 ether);
        assertEq(seq.getBond(op), 0, "full exit after volume decay");
    }

    /// @notice Partial withdraws are gated the same way: leaving less than rollingVolume/14 reverts;
    ///         leaving exactly enough succeeds.
    function test_withdraw_partialGatedAtRequiredBond() public {
        _deposit(3000 * USDC);
        seq.recordVolume(op, 28_000 ether); // required bond = 28000e18 / 14 = 2000e18

        vm.prank(op);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarSequencer.Sequencer__BondBelowRollingVolumeRequirement.selector, 1500 ether, 2000 ether
            )
        );
        seq.withdraw(1500 ether); // would leave 1500 < 2000 required

        vm.prank(op);
        seq.withdraw(1000 ether); // leaves exactly 2000 == required
        assertEq(seq.getBond(op), 2000 ether);
    }

    /// @notice Top-ups below MIN_BOND are allowed once a bond exists (the floor is first-deposit only).
    function test_deposit_topUpBelowMinBondAllowed() public {
        _deposit(1000 * USDC);
        _deposit(1 * USDC); // tiny top-up
        assertEq(seq.getBond(op), 1001 ether);
    }

    /// @notice Withdrawals too small to convert to a whole USDC unit revert instead of burning dust.
    function test_withdraw_dustBelowUsdcGranularityReverts() public {
        _deposit(2000 * USDC);
        vm.prank(op);
        vm.expectRevert(BazaarSequencer.Sequencer__WithdrawalBelowUsdcGranularity.selector);
        seq.withdraw(1e11); // < 1e12 bazaar-per-usdc unit
    }

    /// @notice Write-side bucket aging: a record 31 minutes after the first overwrites the stale
    ///         bucket rather than accumulating into it.
    function test_recordVolume_staleBucketOverwritten() public {
        seq.recordVolume(op, 5000 ether);
        vm.warp(block.timestamp + seq.NUM_BUCKETS() * seq.BUCKET_DURATION() + 1);
        seq.recordVolume(op, 2000 ether);
        assertEq(seq.getRollingVolume(op), 2000 ether, "old bucket overwritten, not accumulated");
    }

    /// @notice Invariant guard for the epoch-spillover fix: the volume-retention window must exceed
    ///         the challenge window by at least one full bucket, so a batch's bond stays in the
    ///         withdrawal floor for the entire time its challenge is valid (covers the up-to-59s
    ///         intra-minute offset between minute-bucketed volume aging and the exact per-batch
    ///         window). This is exactly SEQUENCER_WINDOW <= (NUM_BUCKETS - 1) * BUCKET_DURATION;
    ///         bumping SEQUENCER_WINDOW back to 30 minutes reopens the gap and fails here.
    function test_invariant_challengeWindowLeavesSpilloverMargin() public view {
        assertLe(
            seq.SEQUENCER_WINDOW() + seq.BUCKET_DURATION(),
            seq.NUM_BUCKETS() * seq.BUCKET_DURATION(),
            "challenge window + one bucket must fit within volume retention"
        );
    }

    /// @notice Invariant guard for floor/slash consistency: the withdrawal floor retains
    ///         1/VOLUME_CAP_MULTIPLIER of rolling volume, which must cover the worst-case omission
    ///         slash (OMISSION_PENALTY_BP of that volume). Bumping the multiplier above
    ///         BP_SCALE / OMISSION_PENALTY_BP (≈14.28) reopens the uncollectable-shortfall gap
    ///         and fails here.
    function test_invariant_withdrawalFloorCoversOmissionSlash() public view {
        assertGe(
            seq.BP_SCALE() / seq.VOLUME_CAP_MULTIPLIER(),
            seq.OMISSION_PENALTY_BP(),
            "withdrawal floor must cover the max omission penalty"
        );
    }
}
