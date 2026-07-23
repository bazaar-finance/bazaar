// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";

/// @title OrderTypesIntegrationTest
/// @notice End-to-end coverage of the non-limit order types through matchBatch: market orders
///         (Pass B against a resting limit) and stop orders (StopLoss in Pass B, StopLimit in Pass C),
///         including the live trigger evaluation against the batch settlement oracle price.
contract OrderTypesIntegrationTest is IntegrationBase {
    // ============================ market orders ============================

    /// @notice A long market order sweeps a resting short limit in Pass B, bounded by its slippage cap.
    function test_e2e_MarketOrder_TakesRestingLimit() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10; // 0.1 BTC

        uint256 shortId = _placeLimit(bob, false, size, 50_500 * BAZAAR_SCALE); // resting ask above oracle
        uint256 marketId = _placeMarket(alice, true, size, 200); // 2% cap → bound $51k ≥ $50.5k
        _roll(2);

        uint256 success = _match(_lists(_empty(), _one(shortId), _one(marketId), _empty()), 10);
        assertEq(success, 1, "long market took the short limit");
        assertEq(_filledSize(shortId), size, "resting limit filled");
        assertEq(_filledSize(marketId), size, "market order filled");
        (bool aliceLong, uint256 aliceSize) = _position(alice);
        assertTrue(aliceLong, "alice is long");
        assertEq(aliceSize, size, "alice holds the market fill");
    }

    /// @notice A market order whose slippage cap is below the resting limit's price does not fill.
    function test_e2e_MarketOrder_SlippageCapBelowLimit_NoFill() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;

        uint256 shortId = _placeLimit(bob, false, size, 51_500 * BAZAAR_SCALE); // ask well above oracle
        uint256 marketId = _placeMarket(alice, true, size, 100); // 1% cap → bound $50.5k < $51.5k
        _roll(2);

        assertEq(_match(_lists(_empty(), _one(shortId), _one(marketId), _empty()), 10), 0, "no fill: cap too tight");
        assertEq(_filledSize(marketId), 0, "market order unfilled");
    }

    // ============================ stop orders ============================

    /// @notice A StopLoss (sell stop closing a long) triggers when the batch oracle price falls to/below
    ///         its trigger, then fills in Pass B against a resting long — closing the position.
    function test_e2e_StopLoss_TriggersAndCloses() public {
        uint256 size = BAZAAR_SCALE / 10;
        _openPosition(alice, bob, true, size); // alice LONG, bob SHORT at $50k

        // Sell stop closing alice's long: triggers when oracle <= $49.5k.
        uint256 slId = _placeStopLoss(alice, false, size, 49_500 * BAZAAR_SCALE, 500);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 carolLong = _placeLimit(carol, true, size, 49_500 * BAZAAR_SCALE); // counterparty
        _roll(2);

        // Settle at $49k (<= trigger) → stop fires and fills.
        uint256 success = _matchAtPrice(_lists(_one(carolLong), _empty(), _empty(), _one(slId)), 10, 49_000);
        assertEq(success, 1, "stop-loss triggered and filled");
        assertEq(_posSize(alice), 0, "alice closed via stop-loss");
        assertEq(_filledSize(slId), size, "stop order fully filled");
    }

    /// @notice The same StopLoss does NOT fire while the oracle stays above its trigger.
    function test_e2e_StopLoss_UntriggeredDoesNotFill() public {
        uint256 size = BAZAAR_SCALE / 10;
        _openPosition(alice, bob, true, size);

        uint256 slId = _placeStopLoss(alice, false, size, 49_500 * BAZAAR_SCALE, 500);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 carolLong = _placeLimit(carol, true, size, 49_500 * BAZAAR_SCALE);
        _roll(2);

        // Settle at $50k (> trigger) → stop stays dormant.
        assertEq(_matchAtPrice(_lists(_one(carolLong), _empty(), _empty(), _one(slId)), 10, 50_000), 0, "not triggered");
        assertEq(_filledSize(slId), 0, "stop order unfilled");
        assertEq(_posSize(alice), size, "alice position intact");
    }

    /// @notice A StopLimit rests like a limit and, once its trigger is crossed, matches in Pass C.
    function test_e2e_StopLimit_TriggersAndMatchesInPassC() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;

        // Buy StopLimit: trigger $49.5k, limit $51k (limit >= trigger for a buy). Oracle $50k >= trigger.
        uint256 stopId = _placeStopLimit(alice, true, size, 49_500 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE); // crossable ask
        _roll(2);

        uint256 success = _match(_lists(_one(stopId), _one(shortId), _empty(), _empty()), 10);
        assertEq(success, 1, "triggered stop-limit matched in Pass C");
        assertEq(_filledSize(stopId), size, "stop-limit filled");
        (bool aliceLong, uint256 aliceSize) = _position(alice);
        assertTrue(aliceLong, "alice went long via stop-limit");
        assertEq(aliceSize, size, "position opened");
    }
}
