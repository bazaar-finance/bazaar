// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarSequencer} from "../../src/BazaarSequencer.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Unit tests for BazaarSequencer bond, rolling-volume window, capacity, and the dynamic
///         taker-fee curve. This test contract is the deployer (= factory) and registers itself as
///         a pair so it can drive recordVolume directly.
contract SequencerFeeVolumeTest is Test {
    BazaarSequencer internal seq;
    MockUSDC internal usdc;
    address internal op = makeAddr("operator");
    uint256 constant USDC = 1e6;

    function setUp() public {
        usdc = new MockUSDC();
        seq = new BazaarSequencer(address(usdc), address(this)); // this == factory
        seq.registerPair(address(this)); // lets this contract call recordVolume
        vm.warp(1_000_000);
        usdc.mint(op, 100_000_000 * USDC);
        vm.prank(op);
        usdc.approve(address(seq), type(uint256).max);
    }

    function _deposit(uint256 usdcAmount) internal {
        vm.prank(op);
        seq.deposit(usdcAmount);
    }

    // ---------------- bond deposit / getBond / withdraw ----------------

    function test_deposit_setsBondInBazaarPrecision() public {
        _deposit(1000 * USDC); // 1000 USDC (1e6) -> 1000e18 bond
        assertEq(seq.getBond(op), 1000 ether);
    }

    function test_firstDepositBelowMinBondReverts() public {
        // Read the constant before the prank: an external call inside the expectRevert argument
        // would consume it, sending the deposit from the test contract instead of `op`.
        uint256 minBond = seq.MIN_BOND();

        vm.prank(op);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarSequencer.Sequencer__FirstDepositBelowMinBond.selector, 999 ether, minBond)
        );
        seq.deposit(999 * USDC); // 999e18 < MIN_BOND (1000e18)
    }

    function test_withdraw_reducesBond() public {
        _deposit(3000 * USDC);
        vm.prank(op);
        seq.withdraw(1000 ether); // leaves 2000e18 >= MIN_BOND
        assertEq(seq.getBond(op), 2000 ether);
    }

    function test_withdraw_toZeroAllowed() public {
        _deposit(1000 * USDC);
        vm.prank(op);
        seq.withdraw(1000 ether);
        assertEq(seq.getBond(op), 0);
    }

    function test_withdraw_leavingBelowMinBondReverts() public {
        _deposit(1000 * USDC);
        uint256 minBond = seq.MIN_BOND(); // read before the prank — see above
        vm.prank(op);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarSequencer.Sequencer__RemainingBondBelowMinBond.selector, 500 ether, minBond)
        );
        seq.withdraw(500 ether); // would leave 500e18: below MIN_BOND and not zero
    }

    // ---------------- checkVolumeCapacity ----------------

    function test_capacity_belowMinBond_noCapacity() public view {
        (bool has, uint256 rem) = seq.checkVolumeCapacity(op, 0); // no bond
        assertFalse(has);
        assertEq(rem, 0);
    }

    function test_capacity_isBondTimesMultiplier() public {
        _deposit(1000 * USDC); // cap = 1000e18 * 14 = 14000e18
        (bool has, uint256 rem) = seq.checkVolumeCapacity(op, 0);
        assertTrue(has);
        assertEq(rem, 14000 ether);
    }

    function test_capacity_atExactBoundaryFits() public {
        _deposit(1000 * USDC);
        (bool has, uint256 rem) = seq.checkVolumeCapacity(op, 14000 ether);
        assertTrue(has);
        assertEq(rem, 0);
    }

    function test_capacity_overBoundary_reportsRemaining() public {
        _deposit(1000 * USDC);
        (bool has, uint256 rem) = seq.checkVolumeCapacity(op, 14000 ether + 1);
        assertFalse(has);
        assertEq(rem, 14000 ether);
    }

    // ---------------- recordVolume / getRollingVolume + decay ----------------

    function test_recordVolume_accumulatesInWindow() public {
        seq.recordVolume(op, 5000 ether);
        assertEq(seq.getRollingVolume(op), 5000 ether);
        seq.recordVolume(op, 2000 ether);
        assertEq(seq.getRollingVolume(op), 7000 ether);
    }

    function test_rollingVolume_decaysOutOfWindow() public {
        seq.recordVolume(op, 5000 ether);
        vm.warp(block.timestamp + seq.NUM_BUCKETS() * seq.BUCKET_DURATION());
        assertEq(seq.getRollingVolume(op), 0, "old bucket aged out");
    }

    function test_recordVolume_onlyRegisteredPair() public {
        vm.prank(makeAddr("notAPair"));
        vm.expectRevert(BazaarSequencer.Sequencer__OnlyPair.selector);
        seq.recordVolume(op, 1000 ether);
    }

    // ---------------- getDynamicTakerSequencerFee ----------------

    function test_dynamicFee_noBonds_isMax() public view {
        assertEq(seq.getDynamicTakerSequencerFee(), seq.TAKER_SEQ_FEE_MAX_EBP());
    }

    function test_dynamicFee_lowUtilization_isBase() public {
        _deposit(1000 * USDC); // cap 14000e18, zero volume -> util 0
        assertEq(seq.getDynamicTakerSequencerFee(), seq.TAKER_SEQ_FEE_BASE_EBP());
    }

    function test_dynamicFee_criticalUtilization_isMax() public {
        _deposit(1000 * USDC);
        seq.recordVolume(op, 12600 ether); // util = 12600/14000 = 90% == critical
        assertEq(seq.getDynamicTakerSequencerFee(), seq.TAKER_SEQ_FEE_MAX_EBP());
    }

    function test_dynamicFee_midUtilization_interpolatesLinearly() public {
        _deposit(1000 * USDC);
        seq.recordVolume(op, 9800 ether); // util = 9800/14000 = 70%
        // 75 + (375-75) * (7000-5000)/(9000-5000) = 75 + 150 = 225
        assertEq(seq.getDynamicTakerSequencerFee(), 225);
    }
}
