// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";

/// @notice The withdrawal margin check is EQUITY-based (collateral + unrealized PnL), so without a
///         retention floor a deeply profitable position could withdraw 100% of its deposit and keep
///         the position open on paper profit alone. That state fails two ways: every fee is charged
///         against `bucket.collateral` (MatchingEngineLib._checkMargin rejects a fill whose fee
///         exceeds collateral and the caller then AUTO-CANCELS the order, and _chargeRelayerFee
///         reverts), and paper profit evaporates in the same adverse move it would need to buffer.
///         A position-holding account must therefore retain real cash: mmrBp of current notional
///         on a continuously traded pair (liquidation can interpose at the maintenance line), and
///         imrBp on a session-bound pair (a reopen jumps liquidation entirely). This suite runs on
///         the BTC pair and covers the continuous branch; the session-bound branch is covered in
///         BazaarPairTest on the AAPL pair.
contract RetainedCollateralFloorTest is IntegrationBase {
    /// @dev IntegrationBase seeds only a 5,000 USDC sequencer bond = 70,000 of volume capacity,
    ///      which the opening match nearly exhausts. Without this top-up the walk hits the capacity
    ///      cap and these tests would measure that instead of the retention constraint they are
    ///      about.
    function setUp() public override {
        super.setUp();
        vm.startPrank(seq);
        usdc.approve(address(sequencer), 200_000 * USDC_SCALE);
        sequencer.deposit(200_000 * USDC_SCALE);
        vm.stopPrank();
    }

    /// @dev The floor the withdrawal path enforces for a long on this continuously traded pair:
    ///      mmrBp of notional, with the position valued at the conservative (low) edge of the
    ///      confidence band, which _priceUpdateFor sets 0.1% below spot.
    function _floorForLong(uint256 sizeWad, uint256 spotUsd) internal view returns (uint256) {
        uint256 lowPrice = (spotUsd - spotUsd / 1000) * BAZAAR_SCALE;
        uint256 notional = sizeWad * lowPrice / BAZAAR_SCALE;
        (, uint256 mmrBp,,) = pair.marginRequirements();
        return notional * mmrBp / BazaarTypes.BP_SCALE;
    }

    /// Step 1: the floor blocks any withdrawal that would leave less than maintenance-level cash,
    ///         and it scales with notional.
    function test_cannotWithdrawBelowMmrFloor() public {
        _openPosition(alice, bob, true, 1 * BAZAAR_SCALE); // alice long 1 BTC

        // Price doubles: unrealized profit alone would satisfy the equity-based margin check.
        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceUpdate(100_000, uint64(vm.getBlockTimestamp()));

        uint256 col = _posCollateral(alice);
        uint256 floorAmt = _floorForLong(1 * BAZAAR_SCALE, 100_000);

        // Withdrawing everything is rejected...
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralLib.CollateralLib__MustRetainMinimumCollateral.selector, 0, floorAmt)
        );
        pair.withdrawCollateral(col, pu, 0, 0, 0, "");

        // ...and so is keeping a fee-scale remnant: $5 of cash cannot maintain $100k of notional.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralLib.CollateralLib__MustRetainMinimumCollateral.selector, 5 * BAZAAR_SCALE, floorAmt
            )
        );
        pair.withdrawCollateral(col - (5 * BAZAAR_SCALE), pu, 0, 0, 0, "");

        // Withdrawing down TO the floor is allowed: the profit stays in the position, the
        // maintenance margin stays in cash.
        vm.prank(alice);
        pair.withdrawCollateral(col - floorAmt, pu, 0, 0, 0, "");
        assertEq(_posCollateral(alice), floorAmt, "keeps exactly maintenance-level cash");
        assertGt(floorAmt, 1_000 * BAZAAR_SCALE, "the floor is maintenance-scale, not fee-scale");
    }

    /// Step 2: at the floor, a large position closes in one order — the retained cash covers the
    ///         closing fee with maintenance-level headroom.
    function test_atTheFloor_largePositionCloses() public {
        _openPosition(alice, bob, true, 1 * BAZAAR_SCALE);
        _deposit(carol, 200_000 * BAZAAR_SCALE); // counterparty with plenty of margin

        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceUpdate(100_000, uint64(vm.getBlockTimestamp()));
        uint256 col = _posCollateral(alice);
        uint256 floorAmt = _floorForLong(1 * BAZAAR_SCALE, 100_000);
        vm.prank(alice);
        pair.withdrawCollateral(col - floorAmt, pu, 0, 0, 0, "");

        uint256 aliceClose = _placeLimit(alice, false, 1 * BAZAAR_SCALE, 90_000 * BAZAAR_SCALE);
        uint256 carolBuy = _placeLimit(carol, true, 1 * BAZAAR_SCALE, 110_000 * BAZAAR_SCALE);
        _roll(2);
        _matchAtPrice(_lists(_one(carolBuy), _one(aliceClose), _empty(), _empty()), 10, 100_000);

        assertEq(_canceledBlock(aliceClose), 0, "close is NOT auto-canceled");
        assertGt(_filledSize(aliceClose), 0, "and it fills");
    }

    /// Step 3: the floor is purely proportional, so a small position retains proportionally small
    ///         cash — and still closes fine, because the fees it must cover are proportional too.
    function test_atTheFloor_smallPositionCloses() public {
        _deposit(alice, 2_000 * BAZAAR_SCALE);
        _deposit(bob, 2_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);

        // 0.002 BTC: ~$200 notional at $100k.
        uint256 aOpen = _placeLimit(alice, true, BAZAAR_SCALE / 500, 51_000 * BAZAAR_SCALE);
        uint256 bOpen = _placeLimit(bob, false, BAZAAR_SCALE / 500, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _match(_lists(_one(aOpen), _one(bOpen), _empty(), _empty()), 10);

        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceUpdate(100_000, uint64(vm.getBlockTimestamp()));
        uint256 floorAmt = _floorForLong(BAZAAR_SCALE / 500, 100_000);
        uint256 col = _posCollateral(alice);
        vm.prank(alice);
        pair.withdrawCollateral(col - floorAmt, pu, 0, 0, 0, "");
        assertEq(_posCollateral(alice), floorAmt, "retains mmrBp of a small notional");

        uint256 aliceClose = _placeLimit(alice, false, BAZAAR_SCALE / 500, 90_000 * BAZAAR_SCALE);
        uint256 carolBuy = _placeLimit(carol, true, BAZAAR_SCALE / 500, 110_000 * BAZAAR_SCALE);
        _roll(2);
        _matchAtPrice(_lists(_one(carolBuy), _one(aliceClose), _empty(), _empty()), 10, 100_000);

        assertEq(_canceledBlock(aliceClose), 0, "small position: close is not auto-canceled");
        assertGt(_filledSize(aliceClose), 0, "and it fills");
    }
}
