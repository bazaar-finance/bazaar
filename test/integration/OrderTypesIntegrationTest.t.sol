// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";

/// @title OrderTypesIntegrationTest
/// @notice End-to-end coverage of the non-limit order types through the arrival walk: market
///         orders (immediate fill at the resting maker's price, auto-cancel of any unfillable
///         remainder) and stop orders (arm-at-creation when a fresh price already meets the
///         trigger, keeper-fired execution via executeTriggeredOrders otherwise).
contract OrderTypesIntegrationTest is IntegrationBase {
    // ============================ market orders ============================

    /// @notice A long market order sweeps a resting short limit on arrival, bounded by its
    ///         slippage cap, and fills at the maker's limit price.
    function test_e2e_MarketOrder_TakesRestingLimit() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10; // 0.1 BTC

        uint256 shortId = _placeLimit(bob, false, size, 50_500 * BAZAAR_SCALE); // resting ask above oracle
        _roll(2);
        uint256 marketId = _placeMarket(alice, true, size, 200); // 2% cap → bound $51k ≥ $50.5k

        assertEq(_filledSize(shortId), size, "resting limit filled");
        assertEq(_filledSize(marketId), size, "market order filled");
        (bool aliceLong, uint256 aliceSize) = _position(alice);
        assertTrue(aliceLong, "alice is long");
        assertEq(aliceSize, size, "alice holds the market fill");
    }

    /// @notice A market order whose slippage cap is below the resting ask does not fill: market
    ///         orders never rest, so the unfillable remainder auto-cancels in the creation
    ///         transaction and the book is untouched.
    function test_e2e_MarketOrder_SlippageCapBelowLimit_AutoCancels() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;

        uint256 shortId = _placeLimit(bob, false, size, 51_500 * BAZAAR_SCALE); // ask well above oracle
        _roll(2);
        uint256 marketId = _placeMarket(alice, true, size, 100); // 1% cap → bound $50.5k < $51.5k

        assertEq(_filledSize(marketId), 0, "market order unfilled");
        assertEq(_canceledBlock(marketId), vm.getBlockNumber(), "remainder canceled in its own tx");
        assertEq(_filledSize(shortId), 0, "resting ask untouched");
        assertTrue(_inBook(shortId), "resting ask still in the book");
        assertEq(_posSize(alice), 0, "no position opened");
    }

    // ============================ stop orders ============================

    /// @notice A StopLoss (sell stop closing a long) rests untriggered outside the book, then the
    ///         permissionless keeper fires it once the oracle falls to/below its trigger. The
    ///         execution fills against the resting bid at the maker's price, closes the position,
    ///         and pays the keeper the bounty the owner escrowed with the order.
    function test_e2e_StopLoss_TriggersAndCloses() public {
        uint256 size = BAZAAR_SCALE / 10;
        _openPosition(alice, bob, true, size); // alice LONG, bob SHORT

        // Sell stop closing alice's long: fires when oracle <= $49.5k (untriggered at the $50k print).
        // It carries a $0.25 keeper bounty, escrowed from alice's wallet at creation.
        _approveWallet(alice, BAZAAR_SCALE / 4);
        uint256 slId =
            _placeStopLoss(alice, false, size, _withBounty(49_500 * BAZAAR_SCALE, BAZAAR_SCALE / 4), 500);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 carolLong = _placeLimit(carol, true, size, 49_500 * BAZAAR_SCALE); // resting counterparty bid
        _roll(2);

        uint256 executed = _executeTriggerAt(slId, 49_000); // oracle <= trigger → fires
        assertEq(executed, 1, "stop-loss triggered and filled");
        assertEq(_posSize(alice), 0, "alice closed via stop-loss");
        assertEq(_filledSize(slId), size, "stop order fully filled");
        assertEq(_filledSize(carolLong), size, "counterparty bid filled");
        assertEq(_claimFees(seq), USDC_SCALE / 4, "keeper earned the whole $0.25 bounty for the full close");
    }

    /// @notice The same StopLoss is skipped — not filled, not canceled, no tip — while the oracle
    ///         stays above its trigger: keeper calls on untriggered stops are silent no-ops.
    function test_e2e_StopLoss_UntriggeredDoesNotFill() public {
        uint256 size = BAZAAR_SCALE / 10;
        _openPosition(alice, bob, true, size);

        uint256 slId = _placeStopLoss(alice, false, size, 49_500 * BAZAAR_SCALE, 500);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 carolLong = _placeLimit(carol, true, size, 49_500 * BAZAAR_SCALE);
        _roll(2);

        assertEq(_executeTriggerAt(slId, 50_000), 0, "not triggered above the stop price");
        assertEq(_filledSize(slId), 0, "stop order unfilled");
        assertEq(_canceledBlock(slId), 0, "skipped, not canceled");
        assertEq(_posSize(alice), size, "alice position intact");
        assertEq(_filledSize(carolLong), 0, "counterparty bid untouched");
    }

    /// @notice A buy StopLimit whose trigger a fresh oracle price already meets arms in its own
    ///         creation transaction — no keeper, no tip — and immediately fills against the
    ///         crossing resting ask at the maker's price.
    function test_e2e_StopLimit_ArmedAtCreation_FillsImmediately() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;

        uint256 shortId = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE); // resting crossable ask
        _roll(2);
        // Buy StopLimit: trigger $49.5k, limit $51k (limit >= trigger for a buy). Oracle $50k >= trigger.
        uint256 stopId = _placeStopLimit(alice, true, size, 49_500 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE);

        assertEq(_filledSize(stopId), size, "armed stop-limit filled at creation");
        assertEq(_filledSize(shortId), size, "resting ask filled");
        (bool aliceLong, uint256 aliceSize) = _position(alice);
        assertTrue(aliceLong, "alice went long via stop-limit");
        assertEq(aliceSize, size, "position opened");
    }
}
