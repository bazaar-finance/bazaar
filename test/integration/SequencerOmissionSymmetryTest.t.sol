// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {BazaarSequencer} from "../../src/BazaarSequencer.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @notice Exercises the SHORT-order half of BazaarSequencer._isInRange (lines 464-478), which no
///         existing test executed — every challenge in the suite challenged a long. Also pins
///         rejection reason 3 (out-of-range: honest sequencer NOT slashed) on both sides, the guard
///         that protects an honest sequencer's bond from a spurious challenge. An inverted comparison
///         in the short branch would let a sequencer censor shorts unchallenged, or false-slash an
///         honest one; nothing caught it before.
contract SequencerOmissionSymmetryTest is IntegrationBase {
    address internal challenger;

    function setUp() public override {
        super.setUp();
        challenger = makeAddr("challenger");
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
    }

    /// @dev Decode (batchId, BatchInfo) from the BatchRecorded event in the recorded logs.
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

    /// @dev Match carol's short @49k against dave's long @51k (a worse-priced pair) and capture the
    ///      batch. `highestShortLimitPrice` becomes carol's 49k, so any more-aggressive (lower) short
    ///      alive at match time was censorable. Alice's omitted short is placed by the caller first.
    function _matchWorsePricedShortBatch() internal returns (uint256 batchId, BazaarTypes.BatchInfo memory info) {
        uint256 matchedSize = 1 * BAZAAR_SCALE;
        uint256 daveLong = _placeLimit(dave, true, matchedSize, 51_000 * BAZAAR_SCALE);
        uint256 carolShort = _placeLimit(carol, false, matchedSize, 49_000 * BAZAAR_SCALE);
        _roll(2);
        vm.recordLogs();
        uint256 success = _match(_lists(_one(daveLong), _one(carolShort), _empty(), _empty()), 10);
        assertEq(success, 1, "carol/dave match");
        (batchId, info) = _captureBatch();
        assertGt(info.highestShortLimitPrice, 0, "a short limit matched (sets the short in-range cutoff)");
    }

    uint256 constant OMISSION_PENALTY_MIN = 20 * BAZAAR_SCALE;

    /// @notice A more-aggressive short (lower price) alive at match time but omitted is in-range and
    ///         the sequencer is slashed — the mirror of the long-side omission tests.
    function test_shortOmission_moreAggressive_slashed() public {
        uint256 aliceSize = 1 * BAZAAR_SCALE / 10; // 0.1 BTC
        uint256 alicePrice = 48_000 * BAZAAR_SCALE; // more aggressive (lower) than carol's 49k
        uint256 omittedShort = _placeLimit(alice, false, aliceSize, alicePrice);

        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _matchWorsePricedShortBatch();
        assertLt(alicePrice, info.highestShortLimitPrice, "alice undercuts the matched short -> in range");
        assertEq(_filledSize(omittedShort), 0, "alice omitted, unfilled");

        uint256 censoredNotional = aliceSize * alicePrice / BAZAAR_SCALE;
        uint256 expected = censoredNotional * sequencer.OMISSION_PENALTY_BP() / 10_000;
        if (expected < OMISSION_PENALTY_MIN) expected = OMISSION_PENALTY_MIN;

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.prank(challenger);
        sequencer.challengeOmission(address(pair), batchId, info, omittedShort);
        assertEq(bondBefore - sequencer.sequencerBonds(seq), expected, "short-side omission slashes the sequencer");
    }

    /// @notice Equal-price FIFO tiebreak on the short side: a short at exactly `highestShortLimitPrice`
    ///         but with a LOWER orderId (placed earlier) had priority, so omitting it is censorship
    ///         (line 468). Alice is placed before carol to get the lower id.
    function test_shortOmission_equalPriceOlder_slashed() public {
        uint256 aliceSize = 1 * BAZAAR_SCALE / 10;
        uint256 tiePrice = 49_000 * BAZAAR_SCALE; // identical to carol's short
        uint256 omittedShort = _placeLimit(alice, false, aliceSize, tiePrice); // placed FIRST -> lower id

        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _matchWorsePricedShortBatch();
        assertEq(info.highestShortLimitPrice, tiePrice, "same price as the matched short");
        assertLt(omittedShort, info.highestShortLimitId, "alice is the older order (FIFO priority)");

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.prank(challenger);
        sequencer.challengeOmission(address(pair), batchId, info, omittedShort);
        assertLt(sequencer.sequencerBonds(seq), bondBefore, "equal-price older short is in-range -> slashed");
    }

    /// @notice A LESS-aggressive short (higher price than the matched cutoff) was correctly omitted:
    ///         the challenge is rejected with reason 3 and the honest sequencer keeps its full bond.
    function test_shortOmission_lessAggressive_reason3_notSlashed() public {
        uint256 omittedShort = _placeLimit(alice, false, 1 * BAZAAR_SCALE / 10, 49_500 * BAZAAR_SCALE); // above 49k cutoff

        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _matchWorsePricedShortBatch();
        assertGt(49_500 * BAZAAR_SCALE, info.highestShortLimitPrice, "alice is less aggressive -> out of range");

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.expectEmit(true, true, true, true, address(sequencer));
        emit BazaarSequencer.OmissionChallengeRejected(address(pair), batchId, omittedShort, 3);
        vm.prank(challenger);
        sequencer.challengeOmission(address(pair), batchId, info, omittedShort);
        assertEq(sequencer.sequencerBonds(seq), bondBefore, "honest sequencer not slashed (reason 3)");
    }

    /// @notice Long-side counterpart of reason 3: a LESS-aggressive long (below the matched long
    ///         cutoff) is out of range; the challenge is rejected and no bond is slashed.
    function test_longOmission_lessAggressive_reason3_notSlashed() public {
        // A long at 50_500 is below dave's matched 51_000 long cutoff -> out of range.
        uint256 omittedLong = _placeLimit(alice, true, 1 * BAZAAR_SCALE / 10, 50_500 * BAZAAR_SCALE);

        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _matchWorsePricedShortBatch();
        assertGt(info.lowestLongLimitPrice, 0, "a long limit matched (sets the long cutoff)");
        assertLt(50_500 * BAZAAR_SCALE, info.lowestLongLimitPrice, "alice's long is below the cutoff -> out of range");

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.expectEmit(true, true, true, true, address(sequencer));
        emit BazaarSequencer.OmissionChallengeRejected(address(pair), batchId, omittedLong, 3);
        vm.prank(challenger);
        sequencer.challengeOmission(address(pair), batchId, info, omittedLong);
        assertEq(sequencer.sequencerBonds(seq), bondBefore, "honest sequencer not slashed (reason 3)");
    }
}
