// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";

/// @notice The withdrawal margin check is EQUITY-based (collateral + unrealized PnL), so without a
///         retention floor a deeply profitable position could withdraw 100% of its deposit and keep
///         the position open on profit alone. That is a trap, because every fee is charged against
///         `bucket.collateral`: MatchingEngineLib._checkMargin rejects a fill whose fee exceeds
///         collateral and the caller then AUTO-CANCELS the order, and _chargeRelayerFee reverts — so
///         the holder could not close through the book (their orders would silently vanish) until
///         they re-deposited. Slicing offers no way out either: a partial close leaves a remainder
///         that must meet IMR out of collateral.
///         A position-holding account must therefore retain max(0.5% of notional, $5). The floor is
///         proportional because the fees it must cover are proportional.
contract RetainedCollateralFloorTest is IntegrationBase {
    /// @dev IntegrationBase seeds only a 5,000 USDC sequencer bond = 70,000 of volume capacity,
    ///      which the opening match nearly exhausts. Without this top-up the walk hits the capacity
    ///      cap and these tests would measure that instead of the fee constraint they are about.
    function setUp() public override {
        super.setUp();
        vm.startPrank(seq);
        usdc.approve(address(sequencer), 200_000 * USDC_SCALE);
        sequencer.deposit(200_000 * USDC_SCALE);
        vm.stopPrank();
    }

    /// @dev Long positions are valued at the conservative (low) edge of the confidence band, which
    ///      _priceUpdateFor sets 0.1% below spot.
    function _floorForLong(uint256 sizeBtc, uint256 spotUsd) internal pure returns (uint256) {
        uint256 notional = sizeBtc * (spotUsd - (spotUsd / 1000)) * BAZAAR_SCALE;
        uint256 proportional = notional * 50 / 10_000; // 0.5%
        return proportional < 5 * BAZAAR_SCALE ? 5 * BAZAAR_SCALE : proportional;
    }

    /// Step 1: the floor blocks the withdrawal that would create the trap, and it scales with
    ///         notional.
    function test_cannotWithdrawBelowProportionalFloor() public {
        _openPosition(alice, bob, true, 1 * BAZAAR_SCALE); // alice long 1 BTC

        // Price doubles: unrealized profit alone would satisfy the equity-based margin check.
        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceUpdate(100_000, uint64(vm.getBlockTimestamp()));

        uint256 col = _posCollateral(alice);
        uint256 floorAmt = _floorForLong(1, 100_000); // ~0.5% of ~$99,900 = ~$499.50

        // Withdrawing everything is rejected...
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralLib.CollateralLib__MustRetainMinimumCollateral.selector, 0, floorAmt)
        );
        pair.withdrawCollateral(col, pu, 0, 0, 0, "");

        // ...and so is leaving only a flat $5, which is nowhere near enough on $100k of notional —
        // exactly the residual gap the flat floor left open.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralLib.CollateralLib__MustRetainMinimumCollateral.selector, 5 * BAZAAR_SCALE, floorAmt
            )
        );
        pair.withdrawCollateral(col - (5 * BAZAAR_SCALE), pu, 0, 0, 0, "");

        // Withdrawing down TO the floor is allowed.
        vm.prank(alice);
        pair.withdrawCollateral(col - floorAmt, pu, 0, 0, 0, "");
        assertEq(_posCollateral(alice), floorAmt, "keeps exactly the proportional floor");
        assertGt(floorAmt, 400 * BAZAAR_SCALE, "floor really is ~$500 on $100k notional");
    }

    /// Step 2: at the floor, a large position closes in one order. A flat $5 floor would leave too
    ///         little collateral to cover this close's fee, so the fill would be rejected and the
    ///         order auto-canceled with zero fill.
    function test_atTheFloor_largePositionCloses() public {
        _openPosition(alice, bob, true, 1 * BAZAAR_SCALE);
        _deposit(carol, 200_000 * BAZAAR_SCALE); // counterparty with plenty of margin

        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceUpdate(100_000, uint64(vm.getBlockTimestamp()));
        uint256 col = _posCollateral(alice);
        vm.prank(alice);
        pair.withdrawCollateral(col - _floorForLong(1, 100_000), pu, 0, 0, 0, "");

        uint256 aliceClose = _placeLimit(alice, false, 1 * BAZAAR_SCALE, 90_000 * BAZAAR_SCALE);
        uint256 carolBuy = _placeLimit(carol, true, 1 * BAZAAR_SCALE, 110_000 * BAZAAR_SCALE);
        _roll(2);
        _matchAtPrice(_lists(_one(carolBuy), _one(aliceClose), _empty(), _empty()), 10, 100_000);

        assertEq(_canceledBlock(aliceClose), 0, "close is NOT auto-canceled");
        assertGt(_filledSize(aliceClose), 0, "and it fills");
    }

    /// Step 3: small positions are governed by the $5 absolute minimum, and still close fine.
    function test_atTheFloor_smallPositionCloses() public {
        _deposit(alice, 2_000 * BAZAAR_SCALE);
        _deposit(bob, 2_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);

        // 0.002 BTC: ~$200 notional at $100k -> 0.5% = $1, so the $5 minimum governs.
        uint256 aOpen = _placeLimit(alice, true, BAZAAR_SCALE / 500, 51_000 * BAZAAR_SCALE);
        uint256 bOpen = _placeLimit(bob, false, BAZAAR_SCALE / 500, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _match(_lists(_one(aOpen), _one(bOpen), _empty(), _empty()), 10);

        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceUpdate(100_000, uint64(vm.getBlockTimestamp()));
        uint256 col = _posCollateral(alice);
        vm.prank(alice);
        pair.withdrawCollateral(col - (5 * BAZAAR_SCALE), pu, 0, 0, 0, "");
        assertEq(_posCollateral(alice), 5 * BAZAAR_SCALE, "the $5 minimum governs small positions");

        uint256 aliceClose = _placeLimit(alice, false, BAZAAR_SCALE / 500, 90_000 * BAZAAR_SCALE);
        uint256 carolBuy = _placeLimit(carol, true, BAZAAR_SCALE / 500, 110_000 * BAZAAR_SCALE);
        _roll(2);
        _matchAtPrice(_lists(_one(carolBuy), _one(aliceClose), _empty(), _empty()), 10, 100_000);

        assertEq(_canceledBlock(aliceClose), 0, "small position: close is not auto-canceled");
        assertGt(_filledSize(aliceClose), 0, "and it fills");
    }
}
