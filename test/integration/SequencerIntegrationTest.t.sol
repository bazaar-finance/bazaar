// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title SequencerIntegrationTest
/// @notice End-to-end sequencer accountability: an omission challenge slashing the bond and routing
///         it 1%/6% to challenger/insurance, plus the volume-cap partial-fill boundary and rolling
///         volume accumulation across sequential batches.
contract SequencerIntegrationTest is IntegrationBase {
    /// @dev Pull the most recent BatchRecorded event (batchId + full BatchInfo preimage) from the logs.
    ///      Call vm.recordLogs() immediately before the matchBatch that produced it.
    function _captureBatch() internal returns (uint256 batchId, BazaarTypes.BatchInfo memory info) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == BazaarTypes.BatchRecorded.selector) {
                batchId = uint256(logs[i].topics[2]); // topics: [sig, pairId, batchId, sequencer]
                info = abi.decode(logs[i].data, (BazaarTypes.BatchInfo));
                return (batchId, info);
            }
        }
        revert("no BatchRecorded event emitted");
    }

    // ============================ omission challenge ============================

    /// @notice A sequencer that omits a crossable, better-priced order is challengeable: the challenge
    ///         slashes 7% of the censored notional, routing 1/7 to the challenger and 6/7 to the pair's
    ///         insurance fund (so a sequencer censoring its own order cannot recover the 6%).
    function test_e2e_OmissionChallenge_SlashesSequencerToInsurance() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);

        // Alice's aggressive long @ $52k should have matched first — but the sequencer only submits a
        // worse-priced carol/dave pair, omitting alice.
        uint256 aliceSize = BAZAAR_SCALE / 10; // 0.1 BTC
        uint256 aliceLimitPrice = 52_000 * BAZAAR_SCALE;
        uint256 omittedLong = _placeLimit(alice, true, aliceSize, aliceLimitPrice);

        uint256 matchedSize = 1 * BAZAAR_SCALE;
        uint256 carolLong = _placeLimit(carol, true, matchedSize, 51_000 * BAZAAR_SCALE);
        uint256 daveShort = _placeLimit(dave, false, matchedSize, 49_000 * BAZAAR_SCALE);

        _roll(2);
        vm.recordLogs();
        assertEq(_match(_lists(_one(carolLong), _one(daveShort), _empty(), _empty()), 10), 1, "carol/dave matched");
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _captureBatch();

        // Expected slash math: 7% of min(censored, matched) notional, split 1/7 : 6/7.
        uint256 censoredNotional = aliceSize * aliceLimitPrice / BAZAAR_SCALE;
        uint256 penaltyBase = censoredNotional < info.totalMatchNotional ? censoredNotional : info.totalMatchNotional;
        uint256 fullPenalty = penaltyBase * sequencer.OMISSION_PENALTY_BP() / 10_000;
        uint256 challengerShare = fullPenalty / 7;
        uint256 insuranceShare = fullPenalty - challengerShare;

        address challenger = makeAddr("omitChallenger");
        uint256 bondBefore = sequencer.sequencerBonds(seq);
        uint256 insBefore = _insuranceBal();

        vm.prank(challenger);
        sequencer.challengeOmission(address(pair), batchId, info, omittedLong);

        assertEq(bondBefore - sequencer.sequencerBonds(seq), fullPenalty, "full 7% penalty slashed from bond");
        assertEq(usdc.balanceOf(challenger), challengerShare / 1e12, "challenger receives the 1/7 (1%) bounty");
        assertEq(_insuranceBal() - insBefore, (insuranceShare / 1e12) * 1e12, "6/7 (6%) credited to insurance");
    }

    // ============================ volume cap ============================

    /// @notice A single fill exceeding the sequencer's remaining capacity is truncated at the boundary.
    ///         Bond $5,000 × VOLUME_CAP_MULTIPLIER (14) = $70k capacity; a 2 BTC × $50k = $100k fill is
    ///         cut to exactly 1.4 BTC ($70k).
    function test_e2e_VolumeCap_PartialFillAtBoundary() public {
        _deposit(alice, 50_000 * BAZAAR_SCALE);
        _deposit(bob, 50_000 * BAZAAR_SCALE);

        uint256 size = 2 * BAZAAR_SCALE;
        uint256 longId = _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE); // older → fill $50k
        uint256 shortId = _placeLimit(bob, false, size, 49_500 * BAZAAR_SCALE);
        _roll(2);

        assertEq(_match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10), 1, "one partial fill");
        uint256 filledLong = _filledSize(longId);
        assertEq(filledLong, _filledSize(shortId), "long/short fills balance");
        assertLt(filledLong, size, "fill truncated by the volume cap");
        assertEq(filledLong, 14 * BAZAAR_SCALE / 10, "truncated to exactly 1.4 BTC at the $70k cap");
    }

    // ============================ stale-batch challenge ============================

    function _depositAapl(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function _placeLimitAapl(address user, bool isLong, uint256 size, uint256 limitPrice) internal returns (uint256) {
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
        vm.prank(user);
        aaplPair.createOrder(
            BazaarTypes.OrderType.Limit,
            0,
            limitPrice,
            0,
            size,
            isLong,
            false,
            uint64(vm.getBlockNumber() + 500_000),
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

    /// @notice A sequencer that labels a batch stale while a fresh tick actually existed is slashed:
    ///         the challenger proves the tick (publishTime inside [matchTs−2s, matchTs−1s]) and the
    ///         penalty — max(1% of batch notional, $20) — splits 50/50 challenger/insurance.
    function test_e2e_StaleBatchChallenge_SlashesFalseStaleLabel() public {
        _depositAapl(alice, 20_000 * BAZAAR_SCALE);
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = 1 * BAZAAR_SCALE;
        uint256 longId = _placeLimitAapl(alice, true, size, 202 * BAZAAR_SCALE);
        uint256 shortId = _placeLimitAapl(bob, false, size, 198 * BAZAAR_SCALE);

        // Stale the cache, then match with an empty price update → the batch records isStale = true.
        vm.warp(vm.getBlockTimestamp() + 30);
        _roll(2);
        vm.recordLogs();
        uint64 obs = uint64(vm.getBlockNumber() - 1);
        BazaarTypes.OrderLists memory lists = _lists(_one(longId), _one(shortId), _empty(), _empty());
        vm.prank(seq);
        assertEq(aaplPair.matchBatch(lists, 10, new bytes[](0), obs), 1, "stale batch matched");
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _captureBatch();
        assertTrue(info.isStale, "batch labeled stale");

        // But a fresh tick DID exist 1s before the match — the stale label was false. Prove it.
        bytes[] memory tick = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(info.matchTimestamp) - 1);
        uint256 penalty = info.totalMatchNotional * sequencer.STALE_PENALTY_BP() / 10_000;
        if (penalty < 20 * BAZAAR_SCALE) penalty = 20 * BAZAAR_SCALE; // $20 floor
        uint256 challengerShare = penalty / 2;
        uint256 insuranceShare = penalty - challengerShare;

        address challenger = makeAddr("staleChallenger");
        uint256 bondBefore = sequencer.sequencerBonds(seq);
        (,,,,, uint256 insBefore,,,,,,) = aaplPair.pairVault();

        vm.deal(challenger, 1 ether);
        vm.prank(challenger);
        sequencer.challengeStaleBatch{value: 0.05 ether}(address(aaplPair), batchId, info, tick);

        assertEq(bondBefore - sequencer.sequencerBonds(seq), penalty, "penalty slashed from bond");
        assertEq(usdc.balanceOf(challenger), challengerShare / 1e12, "challenger gets half");
        (,,,,, uint256 insAfter,,,,,,) = aaplPair.pairVault();
        assertEq(insAfter - insBefore, (insuranceShare / 1e12) * 1e12, "insurance gets the other half");
    }

    /// @notice Rolling volume accumulates across sequential batches within the window, consuming the
    ///         sequencer's capacity.
    function test_e2e_MultiBatch_AccumulatesRollingVolume() public {
        _deposit(alice, 50_000 * BAZAAR_SCALE);
        _deposit(bob, 50_000 * BAZAAR_SCALE);

        // Batch 1: 1 BTC × $50k = $50k volume.
        uint256 l1 = _placeLimit(alice, true, 1 * BAZAAR_SCALE, 50_000 * BAZAAR_SCALE);
        uint256 s1 = _placeLimit(bob, false, 1 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(l1), _one(s1), _empty(), _empty()), 10), 1, "batch 1 matched");
        uint256 vol1 = sequencer.getRollingVolume(seq);
        assertGt(vol1, 0, "batch 1 recorded volume");

        // Batch 2: another 0.4 BTC × $50k = $20k → cumulative $70k, exactly saturating the $70k cap
        // (a fill that lands exactly on the boundary is not truncated — the capacity check is strict >).
        uint256 l2 = _placeLimit(alice, true, 4 * BAZAAR_SCALE / 10, 50_000 * BAZAAR_SCALE);
        uint256 s2 = _placeLimit(bob, false, 4 * BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(l2), _one(s2), _empty(), _empty()), 10), 1, "batch 2 matched");
        uint256 vol2 = sequencer.getRollingVolume(seq);
        assertGt(vol2, vol1, "rolling volume accumulated across batches");
    }
}
