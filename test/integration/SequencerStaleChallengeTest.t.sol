// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {BazaarSequencer} from "../../src/BazaarSequencer.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @notice Sequencer challenge-rejection reasons that protect an HONEST sequencer's bond, none of
///         which were exercised end-to-end: reason 9 (an order the sequencer demonstrably included
///         but the walk stale-skipped), reason 5 (Market/StopLoss can't be omission-challenged in a
///         stale batch), and reason 2 (a correctly-fresh batch can't be stale-challenged). A bug in
///         any of these lets a griefer slash an honest sequencer.
contract SequencerStaleChallengeTest is IntegrationBase {
    address internal challenger;

    function setUp() public override {
        super.setUp();
        challenger = makeAddr("challenger");
    }

    // ---------------- AAPL (non-continuous) stale-batch helpers ----------------

    function _freshPriceAapl() internal returns (bytes[] memory) {
        return _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
    }

    function _depositAapl(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function _placeLimitAapl(address user, bool isLong, uint256 size, uint256 limitPrice) internal returns (uint256) {
        bytes[] memory pu = _freshPriceAapl();
        vm.prank(user);
        aaplPair.createOrder(
            BazaarTypes.OrderType.Limit,
            0,
            limitPrice,
            0,
            size,
            isLong,
            false,
            uint64(block.number + 500_000),
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
        (uint256[] memory ids,,,) = aaplPair.getUserActiveLimitOrders(user);
        return ids[ids.length - 1];
    }

    function _placeMarketAapl(address user, bool isLong, uint256 size, uint256 maxSlippageBp)
        internal
        returns (uint256)
    {
        bytes[] memory pu = _freshPriceAapl();
        vm.prank(user);
        aaplPair.createOrder(
            BazaarTypes.OrderType.Market, 0, 0, maxSlippageBp, size, isLong, false, 0, address(0), pu, 0, 0, 0, ""
        );
        (,,,,,,,, uint256 mktId,) = aaplPair.positionBuckets(user);
        return mktId;
    }

    /// @dev Match AAPL with an EMPTY priceUpdate so the engine falls through to the stale cache.
    function _matchAaplStale(BazaarTypes.OrderLists memory lists) internal returns (uint256) {
        bytes[] memory emptyPu = new bytes[](0);
        uint64 obs = uint64(vm.getBlockNumber() - 1);
        vm.prank(seq);
        return aaplPair.matchBatch(lists, 10, emptyPu, obs);
    }

    function _captureBatch() internal returns (uint256 batchId, BazaarTypes.BatchInfo memory info) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == BazaarTypes.BatchRecorded.selector) {
                batchId = uint256(logs[i].topics[2]);
                info = abi.decode(logs[i].data, (BazaarTypes.BatchInfo));
                return (batchId, info);
            }
        }
        revert("no BatchRecorded event emitted");
    }

    function _contains(uint256[] memory arr, uint256 v) internal pure returns (bool) {
        for (uint256 i; i < arr.length; i++) {
            if (arr[i] == v) return true;
        }
        return false;
    }

    // ==================== reason 9: stale-skipped id ====================

    /// @notice An order the sequencer INCLUDED but the walk skipped for a stale-only 2×IMR failure is
    ///         recorded in staleSkippedIds. Challenging its "omission" must be rejected with reason 9
    ///         and slash nothing — it wasn't censored, it was a documented margin skip.
    function test_omission_staleSkippedId_reason9_notSlashed() public {
        // $80 passes creation + normal 30% IMR (~$60) but fails the stale 2× IMR (~$120) for 1 share @ $200.
        _depositAapl(alice, 80 * BAZAAR_SCALE); // under-margined -> stale-skipped
        _depositAapl(bob, 20_000 * BAZAAR_SCALE); // well-margined short
        _depositAapl(carol, 20_000 * BAZAAR_SCALE); // well-margined long that actually fills

        // Alice and carol both bid $202; alice is older (lower id) so the walk hits her first, skips
        // her on the stale 2× IMR, then fills carol against bob — recording a batch with the skip.
        uint256 aliceLong = _placeLimitAapl(alice, true, 1 * BAZAAR_SCALE, 202 * BAZAAR_SCALE);
        uint256 carolLong = _placeLimitAapl(carol, true, 1 * BAZAAR_SCALE, 202 * BAZAAR_SCALE);
        uint256 bobShort = _placeLimitAapl(bob, false, 1 * BAZAAR_SCALE, 198 * BAZAAR_SCALE);

        vm.warp(block.timestamp + 30); // stale the cache (MAX_PRICE_STALENESS = 2s)
        vm.roll(block.number + 2);
        vm.recordLogs();
        uint256 filled = _matchAaplStale(_lists(_two(aliceLong, carolLong), _one(bobShort), _empty(), _empty()));
        assertEq(filled, 1, "carol/bob fill; alice is stale-skipped");
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _captureBatch();

        assertTrue(info.isStale, "batch labeled stale");
        assertTrue(_contains(info.staleSkippedIds, aliceLong), "under-margined long recorded as stale-skipped");

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.expectEmit(true, true, true, false, address(sequencer));
        emit BazaarSequencer.OmissionChallengeRejected(address(aaplPair), batchId, aliceLong, 9);
        vm.prank(challenger);
        sequencer.challengeOmission(address(aaplPair), batchId, info, aliceLong);
        assertEq(sequencer.sequencerBonds(seq), bondBefore, "stale-skip is not censorship (reason 9)");
    }

    // ==================== reason 5: Market/StopLoss in a stale batch ====================

    /// @notice A market order cannot be matched during a stale batch (no oracle price to price it),
    ///         so omitting it is correct — the omission challenge is rejected with reason 5.
    function test_omission_marketInStaleBatch_reason5_notSlashed() public {
        _depositAapl(alice, 20_000 * BAZAAR_SCALE);
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);
        _depositAapl(carol, 20_000 * BAZAAR_SCALE);

        // Alice's market long exists before the oracle goes stale (market creation needs a fresh price).
        uint256 marketId = _placeMarketAapl(alice, true, 1 * BAZAAR_SCALE, 500);
        // A well-margined limit pair to actually record a stale batch.
        uint256 bobLong = _placeLimitAapl(bob, true, 1 * BAZAAR_SCALE, 202 * BAZAAR_SCALE);
        uint256 carolShort = _placeLimitAapl(carol, false, 1 * BAZAAR_SCALE, 198 * BAZAAR_SCALE);

        vm.warp(block.timestamp + 30);
        vm.roll(block.number + 2);
        vm.recordLogs();
        _matchAaplStale(_lists(_one(bobLong), _one(carolShort), _empty(), _empty()));
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _captureBatch();
        assertTrue(info.isStale, "batch labeled stale");

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.expectEmit(true, true, true, false, address(sequencer));
        emit BazaarSequencer.OmissionChallengeRejected(address(aaplPair), batchId, marketId, 5);
        vm.prank(challenger);
        sequencer.challengeOmission(address(aaplPair), batchId, info, marketId);
        assertEq(sequencer.sequencerBonds(seq), bondBefore, "market can't be omission-challenged when stale (reason 5)");
    }

    // ==================== reason 2: stale-challenge on a fresh batch ====================

    /// @notice A correctly-fresh batch (isStale = false) cannot be stale-challenged: reason 2, no slash.
    function test_staleChallenge_freshBatch_reason2_notSlashed() public {
        // Produce a normal, fresh BTC batch.
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 longId = _placeLimit(alice, true, 1 * BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, 1 * BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        vm.recordLogs();
        assertEq(_match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10), 1, "fresh batch fills");
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _captureBatch();
        assertFalse(info.isStale, "batch is fresh");

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.expectEmit(true, true, false, true, address(sequencer));
        emit BazaarSequencer.StaleChallengeRejected(address(pair), batchId, 2);
        vm.prank(challenger);
        sequencer.challengeStaleBatch(address(pair), batchId, info, new bytes[](0));
        assertEq(sequencer.sequencerBonds(seq), bondBefore, "fresh batch is not stale (reason 2)");
    }
}
