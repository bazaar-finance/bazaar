// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

/// @title ArrivalGasBenchTest
/// @notice Gas envelope of the arrival-matching hot paths, measured against Arbitrum's block gas
///         limit (32M). The numbers that matter: a resting insert (the common case), a deep
///         sweep at the protocol's MAX_WALK_STEPS ceiling (the worst case a taker can buy), and
///         the per-node marginal cost that governs both.
///
///         These are `emit log_named_uint` measurements, not assertions on absolute gas — those
///         drift with every optimizer change. The one hard assertion is the property that must
///         never regress: a full-depth sweep fits inside a single Arbitrum block.
contract ArrivalGasBenchTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BTC = 1e18;
    uint256 constant ARBITRUM_BLOCK_GAS_LIMIT = 32_000_000;

    address[] internal makers;

    /// @dev Fund a fresh maker address (one per resting order, so no self-match and no
    ///      same-bucket netting distorts the per-fill cost).
    function _maker(uint256 i) internal returns (address m) {
        m = makers[i];
        usdc.mint(m, 1_000_000 * USDC_SCALE);
        _deposit(m, 60_000 * BAZAAR_SCALE);
    }

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 70; ++i) {
            makers.push(makeAddr(string.concat("maker", vm.toString(i))));
        }
    }

    /// @dev Build an ask ladder of `n` distinct makers, each 0.01 BTC, one dollar apart starting
    ///      just above the $50k oracle. Each insert is hinted with its predecessor, so building
    ///      the book is O(1) per order and the ladder cost stays out of the measured sweep.
    function _buildAskLadder(uint256 n) internal returns (uint256 firstId) {
        uint64 pred;
        for (uint256 i; i < n; ++i) {
            address m = _maker(i);
            bytes[] memory pu = _freshPrice();
            BazaarTypes.OrderSpec memory s = _limitSpec(false, BTC / 100, (50_010 + i) * BAZAAR_SCALE);
            BazaarTypes.MatchHints memory hints;
            hints.pred = pred;
            vm.prank(m);
            pair.createOrder(s, hints, pu, 0, 0, 0, "", "");
            uint256 id = _lastCreatedOrderId(pair);
            if (i == 0) firstId = id;
            pred = uint64(id);
        }
    }

    // ============================================================
    // Common case: a limit order that rests
    // ============================================================

    function test_gas_restingInsert_emptyBook() public {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(true, BTC / 100, 49_000 * BAZAAR_SCALE);

        vm.prank(alice);
        uint256 g0 = gasleft();
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 used = g0 - gasleft();

        emit log_named_uint("createOrder: rest on empty book", used);
    }

    /// @dev Ladder depth for the hinted-vs-unhinted comparison: under MAX_WALK_STEPS so the
    ///      unhinted variant's repair walk can legally traverse the whole book. Past the cap an
    ///      unhinted insert reverts by design — hints are mandatory for deep books.
    uint256 constant COMPARE_DEPTH = BazaarTypes.MAX_WALK_STEPS - 8;

    function test_gas_restingInsert_hintedIntoDeepBook() public {
        _buildAskLadder(COMPARE_DEPTH);
        _deposit(alice, 60_000 * BAZAAR_SCALE);

        // Rest a new ask at the far end of the ladder, hinted at its exact predecessor: the
        // insert must cost the same as on an empty book (O(1), no traversal).
        uint256 tail = _lastCreatedOrderId(pair);
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(false, BTC / 100, 50_100 * BAZAAR_SCALE);
        BazaarTypes.MatchHints memory hints;
        hints.pred = uint64(tail);

        vm.prank(alice);
        uint256 g0 = gasleft();
        pair.createOrder(s, hints, pu, 0, 0, 0, "", "");
        uint256 used = g0 - gasleft();

        emit log_named_uint("createOrder: hinted insert into deep book", used);
    }

    function test_gas_restingInsert_unhintedIntoDeepBook() public {
        _buildAskLadder(COMPARE_DEPTH);
        _deposit(alice, 60_000 * BAZAAR_SCALE);

        // Same placement with NO hint: the repair walk traverses the whole ladder. The delta
        // against the hinted case is exactly what hints buy.
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(false, BTC / 100, 50_100 * BAZAAR_SCALE);

        vm.prank(alice);
        uint256 g0 = gasleft();
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 used = g0 - gasleft();

        emit log_named_uint("createOrder: UNHINTED insert into deep book", used);
    }

    /// @notice Past MAX_WALK_STEPS the repair walk gives up rather than searching further: an
    ///         unhinted insert into a book deeper than the cap reverts, which is what forces
    ///         integrations to supply real hints instead of always walking from the head.
    function test_unhintedInsert_beyondCap_reverts() public {
        _buildAskLadder(BazaarTypes.MAX_WALK_STEPS + 8);
        _deposit(alice, 60_000 * BAZAAR_SCALE);

        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(false, BTC / 100, 50_100 * BAZAAR_SCALE);
        vm.prank(alice);
        vm.expectRevert();
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
    }

    // ============================================================
    // Sweeps: the taker's cost scales with nodes consumed
    // ============================================================

    function _sweep(uint256 depth) internal returns (uint256 used) {
        _buildAskLadder(depth);
        _deposit(alice, 900_000 * BAZAAR_SCALE);

        // A marketable limit above the whole ladder: consumes every resting ask.
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(true, depth * BTC / 100, 51_000 * BAZAAR_SCALE);

        vm.prank(alice);
        uint256 g0 = gasleft();
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        used = g0 - gasleft();

        assertEq(_posSize(alice), depth * BTC / 100, "sweep consumed the whole ladder");
    }

    function test_gas_sweep_1() public {
        emit log_named_uint("createOrder: sweep 1 maker", _sweep(1));
    }

    function test_gas_sweep_8() public {
        emit log_named_uint("createOrder: sweep 8 makers", _sweep(8));
    }

    function test_gas_sweep_32() public {
        emit log_named_uint("createOrder: sweep 32 makers", _sweep(32));
    }

    /// @notice The protocol's worst case: a taker consuming MAX_WALK_STEPS (32) nodes in one
    ///         transaction. This must fit inside an Arbitrum block with room to spare — the cap
    ///         exists precisely so no arrival can be constructed that cannot be mined.
    function test_gas_sweep_maxWalkSteps_fitsInBlock() public {
        uint256 used = _sweep(BazaarTypes.MAX_WALK_STEPS);
        emit log_named_uint("createOrder: sweep MAX_WALK_STEPS makers", used);
        emit log_named_uint("Arbitrum block gas limit", ARBITRUM_BLOCK_GAS_LIMIT);
        emit log_named_uint("headroom vs block limit", ARBITRUM_BLOCK_GAS_LIMIT - used);

        assertLt(used, ARBITRUM_BLOCK_GAS_LIMIT / 2, "max-depth sweep must fit in well under half a block");
    }

    // ============================================================
    // Keeper paths
    // ============================================================

    function test_gas_executeTrigger_singleStop() public {
        _openPosition(bob, carol, true, BTC / 10);
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        uint256 sl = _placeStopLoss(bob, false, BTC / 10, 48_000 * BAZAAR_SCALE, 100);
        _placeLimitAt(dave, true, BTC / 10, 47_600 * BAZAAR_SCALE, 47_500);

        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceUpdate(47_500, uint64(vm.getBlockTimestamp()));
        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](1);
        execs[0].orderId = uint64(sl);

        vm.prank(seq);
        uint256 g0 = gasleft();
        pair.executeTriggeredOrders(execs, pu);
        uint256 used = g0 - gasleft();

        emit log_named_uint("executeTriggeredOrders: 1 stop, 1 fill", used);
    }

    function test_gas_unloadVault_singleFill() public {
        _deposit(carol, 60_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 49_900 * BAZAAR_SCALE);
        _stdstore.target(address(pair)).sig("pairVault()").depth(6).checked_write(BTC / 10);
        _stdstore.target(address(pair)).sig("pairVault()").depth(7).checked_write((BTC / 10) * 50_000);
        _stdstore.target(address(pair)).sig("pairVault()").depth(8).checked_write((BTC / 10) * 48_000);
        _stdstore.target(address(pair)).sig("pairVault()").depth(10).checked_write(true);
        _stdstore.target(address(pair)).sig("pairVault()").depth(13).checked_write((BTC / 10) * 2_000); // seized

        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        uint256 g0 = gasleft();
        pair.unloadVault(0, pu);
        uint256 used = g0 - gasleft();

        emit log_named_uint("unloadVault: 1 fill", used);
    }

    function test_gas_cancelAndSweep() public {
        _deposit(alice, 60_000 * BAZAAR_SCALE);
        uint256 id = _placeLimit(alice, true, BTC / 100, 49_000 * BAZAAR_SCALE);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(alice);
        uint256 g0 = gasleft();
        pair.cancelOrders(ids, 0, 0, 0, "", "");
        uint256 used = g0 - gasleft();

        emit log_named_uint("cancelOrders: 1 resting order (incl. unlink)", used);
    }
}

/// @title UserOrderCountColdBench
/// @notice The per-user exposure sweep measured with COLD storage — the production reading.
///         A test body is one transaction, so a ladder built inside it leaves every order warm
///         (~100 gas a slot) and makes the sweep look almost free. A real maker places an order
///         in a fresh transaction and pays ~2,100 a slot to re-read the orders they placed
///         earlier, so the ladder is built in setUp() instead.
abstract contract UserOrderCountColdBench is IntegrationBase {
    uint256 constant BTC = 1e18;

    /// @dev How many orders the caller already holds when the measured create runs.
    function _resting() internal pure virtual returns (uint256);

    function setUp() public override {
        super.setUp();
        _deposit(alice, 900_000 * BAZAAR_SCALE);
        uint64 pred;
        for (uint256 i; i < _resting(); ++i) {
            bytes[] memory pu = _freshPrice();
            BazaarTypes.OrderSpec memory s = _limitSpec(true, BTC / 100, (49_000 - i) * BAZAAR_SCALE);
            BazaarTypes.MatchHints memory hints;
            hints.pred = pred;
            vm.prank(alice);
            pair.createOrder(s, hints, pu, 0, 0, 0, "", "");
            pred = uint64(_lastCreatedOrderId(pair));
        }
    }

    function test_gas_coldCreateWithOwnResting() public {
        uint256 n = _resting();
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(true, BTC / 100, (49_000 - n) * BAZAAR_SCALE);
        BazaarTypes.MatchHints memory hints;
        hints.pred = n == 0 ? uint64(0) : uint64(_lastCreatedOrderId(pair));

        vm.prank(alice);
        uint256 g0 = gasleft();
        pair.createOrder(s, hints, pu, 0, 0, 0, "", "");
        uint256 used = g0 - gasleft();

        emit log_named_uint("COLD createOrder, own resting orders", n);
        emit log_named_uint("COLD createOrder gas", used);
    }
}

contract UserOrderCountCold1 is UserOrderCountColdBench {
    function _resting() internal pure override returns (uint256) {
        return 1;
    }
}

contract UserOrderCountCold10 is UserOrderCountColdBench {
    function _resting() internal pure override returns (uint256) {
        return 10;
    }
}

/// @notice The worst case a single caller can reach: placing an order while already holding a
///         full set. Tracks MAX_ACTIVE_LIMIT_ORDERS_PER_USER, which is chosen against exactly
///         this reading — the sweep is linear in the set size, so the cap sets its ceiling.
contract UserOrderCountColdAtCap is UserOrderCountColdBench {
    function _resting() internal pure override returns (uint256) {
        return BazaarTypes.MAX_ACTIVE_LIMIT_ORDERS_PER_USER - 1;
    }
}

/// @title ArrivalGasBenchColdTest
/// @notice The same max-depth sweep measured with COLD storage. A test body runs as one
///         transaction, so a book built inside it is warm when the sweep reads it — which
///         understates production cost, where a taker sweeps orders nobody touched this block.
///         Building the ladder in setUp() (a separate transaction) makes every maker's order
///         struct and position bucket a cold access, matching what a real arrival pays.
contract ArrivalGasBenchColdTest is IntegrationBase {
    uint256 constant BTC = 1e18;
    uint256 constant ARBITRUM_BLOCK_GAS_LIMIT = 32_000_000;
    uint256 constant DEPTH = BazaarTypes.MAX_WALK_STEPS;

    function setUp() public override {
        super.setUp();
        uint64 pred;
        for (uint256 i; i < DEPTH; ++i) {
            address m = makeAddr(string.concat("coldMaker", vm.toString(i)));
            usdc.mint(m, 1_000_000 * USDC_SCALE);
            _deposit(m, 60_000 * BAZAAR_SCALE);
            bytes[] memory pu = _freshPrice();
            BazaarTypes.OrderSpec memory s = _limitSpec(false, BTC / 100, (50_010 + i) * BAZAAR_SCALE);
            BazaarTypes.MatchHints memory hints;
            hints.pred = pred;
            vm.prank(m);
            pair.createOrder(s, hints, pu, 0, 0, 0, "", "");
            pred = uint64(_lastCreatedOrderId(pair));
        }
        _deposit(alice, 900_000 * BAZAAR_SCALE);
    }

    function test_gas_coldSweep_maxWalkSteps_fitsInBlock() public {
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s = _limitSpec(true, DEPTH * BTC / 100, 51_000 * BAZAAR_SCALE);

        vm.prank(alice);
        uint256 g0 = gasleft();
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        uint256 used = g0 - gasleft();

        assertEq(_posSize(alice), DEPTH * BTC / 100, "cold sweep consumed the whole ladder");
        emit log_named_uint("COLD createOrder: sweep MAX_WALK_STEPS makers", used);
        emit log_named_uint("COLD headroom vs 32M block limit", ARBITRUM_BLOCK_GAS_LIMIT - used);

        assertLt(used, ARBITRUM_BLOCK_GAS_LIMIT / 2, "cold max-depth sweep must fit in under half a block");
    }
}
