// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @notice WalkState.shortLimitHead is loaded in Pass B sub-walk 1, the TP order it holds is
///         canceled in storage by _cancelOversizedTpSl during sub-walk 2, and Pass C then reuses
///         the cached head. Were _loadHeadShortLimit to short-circuit on `h.loaded` alone, Pass C
///         would fill from the stale memory copy — a canceled order would still fill and flip its
///         owner into an unwanted short. The loaders revalidate a cached head's canceledBlock
///         against storage before reusing it, so the fence's cancel sticks and the order never fills.
contract StaleHeadCanceledOrderTest is IntegrationBase {
    function _filledBlock(uint256 orderId) internal view returns (uint64 fb) {
        (,,,,,,,,,,,,, fb) = pair.orders(orderId);
    }

    function test_CanceledTpIsNeverFilled() public {
        // Raise the sequencer bond: IntegrationBase seeds only 5,000 USDC = 70,000 of volume
        // capacity, and the 51,000 open below leaves just 19,000 — the walk would hit the volume
        // cap after the first partial match and exit BEFORE Pass C ever reaches the stale head.
        vm.startPrank(seq);
        usdc.approve(address(sequencer), 20_000 * USDC_SCALE);
        sequencer.deposit(20_000 * USDC_SCALE);
        vm.stopPrank();

        // Alice long 1 BTC @ 50k (bob short).
        _openPosition(alice, bob, true, 1 * BAZAAR_SCALE);
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        _deposit(bob, 60_000 * BAZAAR_SCALE);
        _deposit(carol, 80_000 * BAZAAR_SCALE);
        _deposit(dave, 80_000 * BAZAAR_SCALE);

        (bool aIsLong, uint256 aSize) = _position(alice);
        assertTrue(aIsLong, "alice long");
        assertEq(aSize, 1 * BAZAAR_SCALE, "alice size 1");

        // Alice's take-profit: short 1 @ 52k, lives in shortLimits.
        uint256 tp = _placeTakeProfit(alice, false, 1 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);
        assertEq(_takeProfitOrderId(alice), tp, "tp slot set");

        // Long limits, sorted DESC: carol 53k (eaten in sub-walk 2), dave 52k (crosses the TP in pass C).
        uint256 ll2 = _placeLimit(carol, true, 1 * BAZAAR_SCALE, 53_000 * BAZAAR_SCALE);
        uint256 ll = _placeLimit(dave, true, 1 * BAZAAR_SCALE, 52_000 * BAZAAR_SCALE);

        // Alice's market close (short 1) — this is the fill that trips the TP/SL fence.
        uint256 m = _placeMarket(alice, false, 1 * BAZAAR_SCALE, 100);
        // A long market whose effective price (50.5k) is BELOW the TP's 52k, so sub-walk 1 loads the
        // TP head and then breaks on price — leaving `loaded == true` with remaining == full size.
        uint256 bobMkt = _placeMarket(bob, true, 1 * BAZAAR_SCALE, 100);

        _roll(2);
        _match(_lists(_two(ll2, ll), _one(tp), _one(bobMkt), _one(m)), 10);

        // Non-vacuity: the scenario must actually reach the fence and do real matching, or this
        // test would "pass" simply by never exercising the path (exactly how the original PoC
        // silently no-op'd when the sequencer ran out of volume capacity).
        assertTrue(_canceledBlock(tp) != 0, "precondition: the fence canceled the oversized TP");
        assertGt(_filledSize(m), 0, "precondition: alice's market close actually matched");

        // --- the canceled TP must never fill ---
        assertEq(_filledSize(tp), 0, "canceled TP must not be filled");
        assertEq(_filledBlock(tp), 0, "canceled TP must not carry a filledBlock");

        // --- and alice must not be flipped into a short she never asked for ---
        (bool nIsLong, uint256 nSize) = _position(alice);
        if (nSize > 0) {
            assertTrue(nIsLong, "alice must never be flipped short by a canceled order");
        }
    }
}
