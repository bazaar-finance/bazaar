// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";

/// @notice Exercises BazaarPair's ADL window-deposit tagging (src/BazaarPair.sol:442-449) — a whole
///         feature branch no test executed. AdlEdgeTest hand-seeds the mappings; here a REAL
///         depositCollateral during a live ADL window drives the epoch-reset and same-epoch
///         accumulate arms. The tag lets ADL scoring discount a mid-auction top-up so it can't
///         re-rank the queue; a bug that mis-tags would let a winner escape deleveraging by depositing.
contract AdlWindowDepositTest is IntegrationBase {
    // adlDepositEpoch / adlWindowDeposits are internal mappings (no getter); slots from
    // `forge inspect BazaarPair storage-layout`. The guard assertions below fail loudly if the
    // layout ever shifts, so hardcoding the slot can't silently read the wrong word.
    uint256 constant SLOT_ADL_DEPOSIT_EPOCH = 124;
    uint256 constant SLOT_ADL_WINDOW_DEPOSITS = 125;

    function _adlDepositEpoch(address u) internal view returns (uint256) {
        return uint256(vm.load(address(pair), keccak256(abi.encode(u, SLOT_ADL_DEPOSIT_EPOCH))));
    }

    function _adlWindowDeposits(address u) internal view returns (uint256) {
        return uint256(vm.load(address(pair), keccak256(abi.encode(u, SLOT_ADL_WINDOW_DEPOSITS))));
    }

    /// @dev Drive the pair into a live ADL window via a deep-underwater liquidation the vault inherits.
    ///      Mirrors AdlIntegrationTest's trigger.
    function _triggerAdl() internal {
        vm.startPrank(seq);
        usdc.approve(address(sequencer), 20_000 * USDC_SCALE);
        sequencer.deposit(20_000 * USDC_SCALE);
        vm.stopPrank();

        _deposit(alice, 60_000 * BAZAAR_SCALE);
        _deposit(bob, 60_000 * BAZAAR_SCALE);
        uint256 size = 5 * BAZAAR_SCALE;
        uint256 aL = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        uint256 bS = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(aL), _one(bS), _empty(), _empty()), 10), 1, "5 BTC opened");

        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, size, 254_960 * BAZAAR_SCALE); // bankruptcy ~$50,990 → deep underwater
        vm.prank(carol);
        assertEq(pair.liquidate(_arr1(dave), _freshPrice()), 1, "dave liquidated");
        assertTrue(pair.isAdlPending(), "ADL window is live");
    }

    /// @notice A first deposit during the window takes the epoch-reset arm: the user's tag is stamped
    ///         to the current epoch and window deposits are SET to the amount. A second deposit in the
    ///         same window takes the accumulate arm: window deposits ADD.
    function test_deposit_duringAdlWindow_tagsAndAccumulates() public {
        _triggerAdl();
        uint64 epoch = pair.adlEpoch();
        assertEq(epoch, 1, "first ADL window is epoch 1");

        // carol has no position and no prior tag (adlDepositEpoch defaults to 0 != epoch) → reset arm.
        assertEq(_adlDepositEpoch(carol), 0, "carol untagged before depositing");
        _deposit(carol, 1_000 * BAZAAR_SCALE);
        assertEq(_adlDepositEpoch(carol), epoch, "reset arm stamps the current epoch");
        assertEq(_adlWindowDeposits(carol), 1_000 * BAZAAR_SCALE, "reset arm SETS window deposits");

        // Second deposit, same epoch → accumulate arm.
        _deposit(carol, 500 * BAZAAR_SCALE);
        assertEq(_adlDepositEpoch(carol), epoch, "epoch unchanged");
        assertEq(_adlWindowDeposits(carol), 1_500 * BAZAAR_SCALE, "accumulate arm ADDS to window deposits");
    }

    /// @notice A deposit made OUTSIDE any ADL window leaves the tag untouched (the tagging block is
    ///         guarded by isAdlPending), so a later window starts the user from a clean slate.
    function test_deposit_outsideWindow_notTagged() public {
        _deposit(carol, 2_000 * BAZAAR_SCALE); // no ADL pending yet
        assertEq(_adlWindowDeposits(carol), 0, "no tagging outside a window");
        assertEq(_adlDepositEpoch(carol), 0, "epoch tag untouched outside a window");
    }
}
