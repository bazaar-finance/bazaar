// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";

/// @title MatchingLoaderEdgeTest
/// @notice Pins the subtle head-loader guards in MatchingEngineLib that mutation probes showed
///         were previously untested: the untriggered-StopLimit race-skip (a sequencer must not
///         be able to arm a stop before its trigger is reached) and the same-price/same-id
///         sort tolerance (a duplicate list entry for an already-filled order is race-skipped,
///         not a batch-reverting SortViolation).
contract MatchingLoaderEdgeTest is IntegrationBase {
    /// @notice An untriggered SHORT StopLimit in the shortLimits list must be skipped, not
    ///         filled. Short stops trigger when oracle <= triggerPrice; at a $50k oracle a
    ///         $40k trigger is unarmed, even though its $39k limit price would cross the
    ///         resting $50k long. (Mutation probe: deleting the guard passed the full suite.)
    function test_loader_untriggeredShortStopLimit_isSkippedNotFilled() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;

        uint256 stopId = _placeStopLimit(alice, false, size, 40_000 * BAZAAR_SCALE, 39_000 * BAZAAR_SCALE);
        uint256 longId = _placeLimit(bob, true, size, 50_000 * BAZAAR_SCALE);
        _roll(2);

        assertEq(_match(_lists(_one(longId), _one(stopId), _empty(), _empty()), 10), 0, "no fills: stop unarmed");
        assertEq(_posSize(alice), 0, "stop owner has no position");
        assertEq(_posSize(bob), 0, "counterparty unfilled");
    }

    /// @notice Symmetric long-side guard: a LONG StopLimit triggers when oracle >= trigger;
    ///         at a $50k oracle a $60k trigger is unarmed even though its $61k limit price
    ///         crosses the resting $50k short.
    function test_loader_untriggeredLongStopLimit_isSkippedNotFilled() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;

        uint256 stopId = _placeStopLimit(alice, true, size, 60_000 * BAZAAR_SCALE, 61_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 50_000 * BAZAAR_SCALE);
        _roll(2);

        assertEq(_match(_lists(_one(stopId), _one(shortId), _empty(), _empty()), 10), 0, "no fills: stop unarmed");
        assertEq(_posSize(alice), 0, "stop owner has no position");
        assertEq(_posSize(bob), 0, "counterparty unfilled");
    }

    /// @notice The head-loader sort check tolerates a same-price SAME-id re-load (`id >= last`,
    ///         not `>`): a duplicate list entry for an order that just fully filled must be
    ///         race-skipped, not revert the whole batch with SortViolation. A second resting
    ///         short keeps the walk alive so the duplicate entry actually gets loaded.
    ///         (Mutation probe: tightening >= to > passed the full suite.)
    function test_loader_duplicateFilledOrderInList_isSkippedNotSortViolation() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;

        uint256 longId = _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE);
        uint256 shortId1 = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        uint256 shortId2 = _placeLimit(bob, false, size, 49_500 * BAZAAR_SCALE);
        _roll(2);

        // First occurrence of longId fills fully against shortId1; the walk then loads the
        // duplicate at the same effective price and same id (>= tolerance), sees it filled,
        // and race-skips it. shortId2 rests unmatched.
        assertEq(
            _match(_lists(_two(longId, longId), _two(shortId1, shortId2), _empty(), _empty()), 10),
            1,
            "one fill; duplicate entry skipped, not SortViolation"
        );
        assertEq(_posSize(alice), size, "long filled exactly once");
        assertEq(_posSize(bob), size, "short filled exactly once");
    }
}
