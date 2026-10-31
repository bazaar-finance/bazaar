// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {AmendTestBase} from "./AmendTestBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";
import {OrderView} from "../OrderView.sol";

/// @title AmendInPlaceTest
/// @notice A move whose new price and queue position still sort between the order's current
///         neighbours is written where the order stands; one that changes them relinks the order.
///         Either way the book reads as if the order had been unlinked and inserted anew: the same
///         links, heads and counts, a fresh queue position, and exposure stamps restarted against
///         the amendment's index.
contract AmendInPlaceTest is AmendTestBase {
    /// @notice A reprice that still sorts between the order's neighbours is written where the
    ///         order stands: every link, both heads and both counts read the same before and
    ///         after, while the order carries the new price, the queue position the amendment
    ///         drew and the block it was rewritten in.
    function test_reprice_betweenItsNeighbours_isWrittenInPlace() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 40_000 * BAZAAR_SCALE);
        uint256 above = _placeLimit(bob, true, SIZE, 49_500 * BAZAAR_SCALE);
        _roll(1);
        uint256 a = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);
        _roll(1);
        uint256 below = _placeLimit(bob, true, SIZE, 48_000 * BAZAAR_SCALE);
        _roll(5);
        bytes32 links = _links();
        uint256 counter = lens.nextOrderId(address(pair));
        uint32 restedAt = OrderView.order(pair, a).restedBlock;

        _amendAs(alice, _single(a, 48_500 * BAZAAR_SCALE, SIZE));

        assertEq(_links(), links, "no link, head or count changed");
        assertEq(_prev(a), uint64(above));
        assertEq(_next(a), uint64(below));
        assertEq(_bidHead(), uint64(above));
        assertEq(_bids().length, 3);
        BazaarTypes.Order memory o = OrderView.order(pair, a);
        assertEq(o.limitPrice, 48_500 * BAZAAR_SCALE, "the new price");
        assertEq(o.prioritySeq, uint48(counter), "a fresh queue position all the same");
        assertEq(lens.nextOrderId(address(pair)), counter + 1, "drawn from the counter");
        assertEq(o.restedBlock, uint32(vm.getBlockNumber()), "rests from this block");
        assertGt(o.restedBlock, restedAt);
    }

    /// @notice An in-place move restamps the order's exposure as a relink does: the block it was
    ///         rewritten in, and the far-side premium of its new price against the amendment's
    ///         index — the same stamp a relinked order lands with at that price.
    function test_inPlaceMove_restampsExposureLikeARelink() public {
        _deposit(alice, 40_000 * BAZAAR_SCALE);
        _deposit(bob, 40_000 * BAZAAR_SCALE);
        uint256 top = _placeLimit(bob, true, SIZE, 51_000 * BAZAAR_SCALE);
        _roll(1);
        uint256 a = _placeLimit(alice, true, SIZE, 50_200 * BAZAAR_SCALE);
        _roll(1);
        uint256 mid = _placeLimit(bob, true, SIZE, 49_000 * BAZAAR_SCALE);
        _roll(1);
        uint256 low = _placeLimit(alice, true, SIZE, 48_500 * BAZAAR_SCALE);
        _roll(3);
        bytes32 links = _links();

        // Between top and mid still: in place.
        _amendAs(alice, _single(a, 50_500 * BAZAAR_SCALE, SIZE));
        assertEq(_links(), links, "written in place");
        uint16 premium = FundingLib.restedPremiumOf(true, 50_500 * BAZAAR_SCALE, 50_000 * BAZAAR_SCALE);
        assertGt(premium, 0, "fixture: a bid above the index");
        assertEq(OrderView.order(pair, a).restedPremiumPpm, premium, "the new price's far-side premium");
        assertEq(OrderView.order(pair, a).restedBlock, uint32(vm.getBlockNumber()));

        // Past mid onto a's level: relinked behind a, with the same stamps.
        _amendAs(alice, _single(low, 50_500 * BAZAAR_SCALE, SIZE));
        assertEq(_bidHead(), uint64(top));
        assertEq(_next(a), uint64(low), "relinked behind the order already at the level");
        assertEq(_next(low), uint64(mid));
        assertEq(OrderView.order(pair, low).restedPremiumPpm, premium, "the relink stamps the same premium");
        assertEq(OrderView.order(pair, low).restedBlock, OrderView.order(pair, a).restedBlock);
    }

    /// @notice A reprice to the exact price of the order behind it does not keep the slot: at that
    ///         price the order queues behind the incumbent, so it is relinked there. One tick short
    ///         of that price it stays where it is.
    function test_reprice_ontoTheNextLevel_queuesBehindItsIncumbent() public {
        (uint256 a, uint256 b) = _twoBids();
        bytes32 links = _links();
        _amendAs(alice, _single(a, 48_001 * BAZAAR_SCALE, SIZE));
        assertEq(_links(), links, "a tick above the next level: in place");
        assertEq(_bidHead(), uint64(a));

        uint256 counter = lens.nextOrderId(address(pair));
        _amendAs(alice, _single(a, 48_000 * BAZAAR_SCALE, SIZE));
        assertEq(_bidHead(), uint64(b), "the incumbent leads the level");
        assertEq(_next(b), uint64(a), "the repriced order queues behind it");
        assertEq(_prev(a), uint64(b));
        assertEq(_next(a), 0);
        assertEq(_seq(a), uint64(counter));
        assertEq(_bids().length, 2);
    }

    /// @notice The head repriced to a better price is still the head: nothing around it changes,
    ///         so it is written in place, under a fresh queue position.
    function test_reprice_headToABetterPrice_staysHeadInPlace() public {
        (uint256 a, uint256 b) = _twoBids();
        bytes32 links = _links();
        uint256 counter = lens.nextOrderId(address(pair));
        _amendAs(alice, _single(a, 49_500 * BAZAAR_SCALE, SIZE));
        assertEq(_links(), links);
        assertEq(_bidHead(), uint64(a), "still the head");
        assertEq(_next(a), uint64(b));
        assertEq(_prev(b), uint64(a));
        assertEq(_seq(a), uint64(counter), "the queue position advanced");
        assertEq(OrderView.order(pair, a).limitPrice, 49_500 * BAZAAR_SCALE);
    }

    /// @notice An order alone on its side keeps its slot under any price inside the band.
    function test_reprice_soleOrder_staysInPlace() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 a = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);
        bytes32 links = _links();
        _amendAs(alice, _single(a, 40_000 * BAZAAR_SCALE, SIZE));
        _amendAs(alice, _single(a, 60_000 * BAZAAR_SCALE, SIZE));
        assertEq(_links(), links);
        assertEq(_bidHead(), uint64(a));
        assertEq(_prev(a), 0);
        assertEq(_next(a), 0);
        assertEq(_bids().length, 1);
    }

    /// @notice Growing an order that shares its price with no neighbour is written in place; once
    ///         another order rests at its price behind it, growing again queues behind that order.
    function test_grow_aloneAtItsPriceStays_sharedPriceQueuesBehind() public {
        _deposit(alice, 40_000 * BAZAAR_SCALE);
        _deposit(bob, 40_000 * BAZAAR_SCALE);
        uint256 a = _placeLimit(alice, true, SIZE, 49_000 * BAZAAR_SCALE);
        _roll(1);
        uint256 b = _placeLimit(bob, true, SIZE, 48_000 * BAZAAR_SCALE);
        bytes32 links = _links();
        uint256 counter = lens.nextOrderId(address(pair));
        _amendAs(alice, _single(a, 49_000 * BAZAAR_SCALE, 2 * SIZE));
        assertEq(_links(), links, "alone at its price: in place");
        assertEq(_seq(a), uint64(counter));
        assertEq(OrderView.order(pair, a).size, 2 * SIZE);

        _roll(1);
        uint256 c = _placeLimit(bob, true, SIZE, 49_000 * BAZAAR_SCALE);
        assertEq(_next(a), uint64(c), "fixture: an order at the same price behind it");
        _amendAs(alice, _single(a, 49_000 * BAZAAR_SCALE, 3 * SIZE));
        assertEq(_bidHead(), uint64(c), "the order already at the level leads it");
        assertEq(_next(c), uint64(a), "the grown order queues behind");
        assertEq(_next(a), uint64(b));
        assertEq(_bids().length, 3);
    }

    // ---------------------------- book shape under random amendments ----------------------------

    /// @notice Full sides: alice and bob each rest sixteen bids and sixteen asks, interleaved $125
    ///         apart, and alice's are amended at random to prices that land between everyone's
    ///         levels, onto them — her own included — and past either end. Whether an amendment is
    ///         written in place or relinks, both sides stay strictly sorted by price and then by
    ///         queue position with reciprocal links, and each count equals its traversal's length.
    function testFuzz_randomAmendments_amongOthersOrders_keepBothSidesWellFormed(uint256 seed) public {
        _deposit(alice, 500_000 * BAZAAR_SCALE);
        _deposit(bob, 500_000 * BAZAAR_SCALE);
        uint256[32] memory mine = _fullSides();
        for (uint256 step; step < 12; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 pick = seed % 32;
            // Bids 40,000..49,500 and asks 52,000..61,500 in $125 steps: every level on the side,
            // either owner's, is reachable, as is each gap between them and the room past both
            // ends, and neither side ever reaches the other.
            uint256 price = ((pick < 16 ? 40_000 : 52_000) + 125 * ((seed >> 8) % 77)) * BAZAAR_SCALE;
            uint256 size = SIZE / 4 + (SIZE / 4) * ((seed >> 16) % 8);
            _roll(1);
            _amendAs(alice, _single(mine[pick], price, size));
            _assertSideWellFormed(true, 32);
            _assertSideWellFormed(false, 32);
        }
    }

    /// @dev Sixteen bids and sixteen asks each for alice and bob: alice's bids at 45,000 + 250·i and
    ///      bob's at 45,125 + 250·i, alice's asks at 53,000 + 250·i and bob's at 53,125 + 250·i.
    ///      Bids are placed from the worst up, so each takes the head unhinted; asks from the best
    ///      up, each hinted behind the one before it. Returns alice's ids: bids, then asks.
    function _fullSides() internal returns (uint256[32] memory mine) {
        for (uint256 i; i < 16; ++i) {
            mine[i] = _placeHinted(alice, true, (45_000 + 250 * i) * BAZAAR_SCALE, 0);
            _placeHinted(bob, true, (45_125 + 250 * i) * BAZAAR_SCALE, 0);
        }
        uint64 pred;
        for (uint256 i; i < 16; ++i) {
            mine[16 + i] = _placeHinted(alice, false, (53_000 + 250 * i) * BAZAAR_SCALE, pred);
            pred = uint64(_placeHinted(bob, false, (53_125 + 250 * i) * BAZAAR_SCALE, uint64(mine[16 + i])));
        }
    }
}
