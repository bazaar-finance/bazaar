// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

// Consolidated: margin checks, MMR (grandfather + 24h lag), and funding index.
import {Test} from "forge-std/Test.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {BucketLib} from "../../src/libraries/BucketLib.sol";
import {MatchingEngineLib} from "../../src/libraries/MatchingEngineLib.sol";
import {MmrSampleLib} from "../../src/libraries/MmrSampleLib.sol";

// ==================== from CheckMarginHarness.sol ====================

/// @notice Thin wrapper exposing MatchingEngineLib._checkMargin for direct unit testing.
///         Each branch (open, add, partial close, full close, flip) and the bad-debt /
///         incipient-loss debit logic is exercised through this harness.
contract CheckMarginHarness {
    function checkMargin(
        BazaarTypes.PositionBucket memory bucket,
        BazaarTypes.BucketState memory state,
        bool isLong,
        uint256 fillSize,
        uint256 executionPrice,
        uint256 fee,
        uint256 cachedPrice,
        uint256 imrBp,
        uint256 mmrBp,
        uint256 laggedMmrBp
    ) external view returns (bool) {
        return MatchingEngineLib._checkMargin(
            bucket, state, isLong, fillSize, executionPrice, fee, cachedPrice, imrBp, mmrBp, laggedMmrBp
        );
    }
}

// ==================== from CheckMarginTest.t.sol ====================

/// @notice Unit tests for MatchingEngineLib._checkMargin via CheckMarginHarness.
///         Exercises the four classification branches (open / same-side add / close /
///         flip), the bad-debt rejection paths, and the asymmetric incipient-loss debit.
contract CheckMarginTest is Test {
    CheckMarginHarness internal harness;

    uint256 constant SCALE = 1e18;
    uint256 constant IMR_BP = 2_000; // 20%
    uint256 constant MMR_BP = 1_000; // 10%
    uint256 constant ORACLE = 100 * SCALE;

    function setUp() public {
        harness = new CheckMarginHarness();
    }

    // ---- helpers ----

    /// @dev Builds an empty bucket / state pair (user has no open position).
    function _emptyBucket(uint256 collateral)
        internal
        pure
        returns (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state)
    {
        bucket.size = 0;
        bucket.collateral = collateral;
        state.effectiveCollateral = collateral;
        state.availableEquity = collateral;
        state.isSolvent = true;
    }

    /// @dev Builds a bucket / state pair representing an existing position priced at oracle.
    function _existingBucket(
        bool isLong,
        uint256 size,
        uint256 entryPrice, // dollars × SCALE per unit
        uint256 collateral,
        uint256 currentOraclePrice
    ) internal pure returns (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) {
        bucket.isLong = isLong;
        bucket.size = size;
        bucket.entryValue = (size * entryPrice) / SCALE;
        bucket.collateral = collateral;

        state.adjustedSize = size;
        state.entryValue = bucket.entryValue;
        state.currentNotional = (size * currentOraclePrice) / SCALE;
        if (isLong) {
            state.unrealizedPnl = int256(state.currentNotional) - int256(state.entryValue);
        } else {
            state.unrealizedPnl = int256(state.entryValue) - int256(state.currentNotional);
        }
        state.totalPnl = state.unrealizedPnl;
        int256 signed = int256(collateral) + state.totalPnl;
        state.effectiveCollateral = signed > 0 ? uint256(signed) : 0;
        state.availableEquity = state.effectiveCollateral;
        state.entryMmrBp = MMR_BP;
        state.isSolvent = true;
    }

    // ============================================================
    // Open from flat
    // ============================================================

    function testCheckMargin_OpenLong_PassesAtMid() public {
        // 1 BTC long, $20 collateral (= IMR), fillPrice = oracle = $100
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) = _emptyBucket(20 * SCALE);
        assertTrue(harness.checkMargin(bucket, state, true, 1 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_OpenLongAtAbovOracle_RejectedWhenIncipientLossDepletesBuffer() public {
        // 1 BTC long, $21 collateral, fillPrice = $105, oracle = $100
        // IMR = 0.2 × 105 = $21 → passes IMR alone
        // Incipient loss = 1 × $5 = $5 → effective collateral = $16
        // 16 < 21 → reject
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) = _emptyBucket(21 * SCALE);
        assertFalse(harness.checkMargin(bucket, state, true, 1 * SCALE, 105 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_OpenLongAtAbovOracle_PassesWithExtraCollateral() public {
        // Same setup but $30 collateral — covers IMR + incipient loss
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) = _emptyBucket(30 * SCALE);
        assertTrue(harness.checkMargin(bucket, state, true, 1 * SCALE, 105 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_OpenLongBelowOracle_NoCreditForGain() public {
        // fillPrice = $95 < oracle $100. Long entering favorably (gain).
        // IMR = 0.2 × 95 = $19. Collateral = $19 → just passes (no credit makes this exact)
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) = _emptyBucket(19 * SCALE);
        assertTrue(harness.checkMargin(bucket, state, true, 1 * SCALE, 95 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
        // With $18 collateral, fails (no credit pulls headroom up)
        (bucket, state) = _emptyBucket(18 * SCALE);
        assertFalse(harness.checkMargin(bucket, state, true, 1 * SCALE, 95 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_OpenShortBelowOracle_RejectedWhenIncipientLoss() public {
        // 1 BTC short, fillPrice = $95 < oracle = $100 → short selling at low = loss
        // IMR = 0.2 × 95 = $19. Collateral = $20. Incipient loss = 1 × 5 = $5 → effective $15. Reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) = _emptyBucket(20 * SCALE);
        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 95 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_OpenShortAboveOracle_NoCreditForGain() public {
        // fillPrice = $105 > oracle = $100 → short selling high = gain. No credit applied.
        // IMR = 0.2 × 105 = $21. Collateral = $21 → exactly passes.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) = _emptyBucket(21 * SCALE);
        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 105 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    // ============================================================
    // Close — bad debt rejection
    // ============================================================

    function testCheckMargin_FullClose_AtRecoverableLoss_Passes() public {
        // Long 1 @ $100 entry, $25 collateral, sells 1 @ $80 (oracle = $100)
        // Realized loss = $20. Post-fill collateral = $5. Remaining = 0. Required = 0 → passes.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 1 * SCALE, 100 * SCALE, 25 * SCALE, ORACLE);

        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 80 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_FullClose_AtUnrecoverableLoss_Rejected() public {
        // Long 1 @ $100 entry, $5 collateral, sells 1 @ $80 (oracle = $100)
        // Realized loss = $20 > $5 collateral → bad debt → reject (must liquidate)
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 1 * SCALE, 100 * SCALE, 5 * SCALE, ORACLE);

        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 80 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_PassesAtNeutralPrice() public {
        // Long 2 @ $100 entry, $20 collateral, sells 1 @ $100 (oracle $100)
        // Realized PnL = 0. Remaining = 1 × 100 = 100. MMR = 10. Collateral $20 ≥ $10 → passes.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 2 * SCALE, 100 * SCALE, 20 * SCALE, ORACLE);

        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_LeavingResidualUnderMMR_Rejected() public {
        // Long 2 @ $100 entry, $11 collateral, sells 1 @ $90 (oracle $100)
        // Realized loss = $10. Post-fill collateral = $1. Remaining = 1 × 100 = 100. MMR = $10.
        // 1 < 10 → reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 2 * SCALE, 100 * SCALE, 11 * SCALE, ORACLE);

        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 90 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_AllowsBelowIMR() public {
        // Long 2 @ $100 entry, $15 collateral. Position IMR = 0.2 × 200 = $40 (way over collateral).
        // User reduces by 1 unit at oracle. Realized PnL = 0. Remaining notional = $100, MMR = $10.
        // Collateral $15 ≥ $10 MMR → passes (would fail under IMR-on-close).
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 2 * SCALE, 100 * SCALE, 15 * SCALE, ORACLE);

        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    // ============================================================
    // Flip
    // ============================================================

    function testCheckMargin_Flip_OnlyResidualBearsIMR_PassesAtFavorablePrice() public {
        // Long 2 @ $100 entry, $25 collateral. Sells 3 @ $110 (oracle $100).
        // Closed portion: realized PnL = (110 - 100) × 2 = +$20. Post-close collateral = $45.
        // Residual: 1 short @ $110. IMR = 0.2 × 110 = $22.
        // No incipient loss debit (short selling above oracle = gain, ignored).
        // 45 ≥ 22 → passes.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 2 * SCALE, 100 * SCALE, 25 * SCALE, ORACLE);

        assertTrue(harness.checkMargin(bucket, state, false, 3 * SCALE, 110 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_Flip_ClosedPortionUnderwater_Rejected() public {
        // Long 2 @ $100 entry, $5 collateral. Sells 3 @ $90 (oracle $100).
        // Closed portion: realized PnL = (90 - 100) × 2 = -$20. Post-close collateral = -$15.
        // Bad debt → reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 2 * SCALE, 100 * SCALE, 5 * SCALE, ORACLE);

        assertFalse(harness.checkMargin(bucket, state, false, 3 * SCALE, 90 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_Flip_ResidualWithIncipientLoss_Rejected() public {
        // Short 2 @ $100 entry, $30 collateral. Buys 3 @ $105 (oracle $100). Flip to long.
        // Closed portion (short closing at $105): realized PnL = (100 - 105) × 2 = -$10.
        // Post-close collateral = $20.
        // Residual: 1 long @ $105. IMR = 0.2 × 105 = $21. Incipient loss (long, fill>oracle) = 1 × 5 = $5.
        // Effective $15 < $21 → reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(false, 2 * SCALE, 100 * SCALE, 30 * SCALE, ORACLE);

        assertFalse(harness.checkMargin(bucket, state, true, 3 * SCALE, 105 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    // ============================================================
    // Close / flip — funding settles on the closed shares
    // ============================================================

    function testCheckMargin_FullClose_FundingDebtCreatesBadDebt_Rejected() public {
        // Long 1 @ $100 entry, $5 collateral, sells 1 @ $100 (price PnL = 0).
        // Funding owed = $10 > $5 collateral → bad debt → reject (must liquidate).
        // Pre-fix the gate ignored funding and admitted this fill.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 1 * SCALE, 100 * SCALE, 5 * SCALE, ORACLE);
        state.fundingPnl = -10 * int256(SCALE);

        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_FullClose_FundingCreditRescuesPriceLoss_Passes() public {
        // Long 1 @ $100 entry, $5 collateral, sells 1 @ $90: price loss $10 > collateral,
        // but $10 of funding is owed TO the trader → combined post-fill = +$5 → passes.
        // Pre-fix the gate saw only the price loss and rejected a solvent close.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 1 * SCALE, 100 * SCALE, 5 * SCALE, ORACLE);
        state.fundingPnl = 10 * int256(SCALE);

        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 90 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_FundingProportionalToClosedShares() public {
        // Long 2 @ $100 entry, $12 collateral, sells 1 @ $100 (price PnL = 0).
        // Total funding owed = $4 → closed half settles $2 → post = $10.
        // Remainder MMR = 10% × $100 = $10 → passes exactly at the boundary.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 2 * SCALE, 100 * SCALE, 12 * SCALE, ORACLE);
        state.fundingPnl = -4 * int256(SCALE);

        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));

        // Total funding owed = $6 → closed half settles $3 → post = $9 < $10 MMR → reject.
        (bucket, state) = _existingBucket(true, 2 * SCALE, 100 * SCALE, 12 * SCALE, ORACLE);
        state.fundingPnl = -6 * int256(SCALE);

        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_Flip_SettlesEntireFunding() public {
        // Long 2 @ $100 entry, $30 collateral, sells 3 @ $100 (price PnL = 0) → flip.
        // The whole position closes, so ALL funding settles. Owed $12 → post = $18.
        // Residual 1 short @ $100 → IMR = $20 > $18 → reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 2 * SCALE, 100 * SCALE, 30 * SCALE, ORACLE);
        state.fundingPnl = -12 * int256(SCALE);

        assertFalse(harness.checkMargin(bucket, state, false, 3 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));

        // Owed $8 → post = $22 ≥ $20 IMR on the residual → passes.
        (bucket, state) = _existingBucket(true, 2 * SCALE, 100 * SCALE, 30 * SCALE, ORACLE);
        state.fundingPnl = -8 * int256(SCALE);

        assertTrue(harness.checkMargin(bucket, state, false, 3 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    // ============================================================
    // Same-side add
    // ============================================================

    function testCheckMargin_SameSideAdd_PassesAtMid() public {
        // Long 1 @ $100 entry, $40 collateral. Adds 1 @ $100 (oracle $100).
        // Existing notional = $100. New notional = $100. Total = $200. IMR = $40.
        // Collateral $40 ≥ $40 → passes exactly.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 1 * SCALE, 100 * SCALE, 40 * SCALE, ORACLE);

        assertTrue(harness.checkMargin(bucket, state, true, 1 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_SameSideAdd_FailsWhenIncipientLossExceedsHeadroom() public {
        // Long 1 @ $100 entry, $41 collateral. Adds 1 @ $105 (oracle $100).
        // Existing notional = $100. New notional = $105. Total = $205. IMR = $41.
        // Incipient loss (long, fill>oracle) = 1 × 5 = $5. Effective $36 < $41 → reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 1 * SCALE, 100 * SCALE, 41 * SCALE, ORACLE);

        assertFalse(harness.checkMargin(bucket, state, true, 1 * SCALE, 105 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }
}

// ==================== from MmrLagTest.t.sol ====================

/// @notice Exposes MmrSampleLib over a real storage ring buffer for unit testing.
contract MmrSampleHarness {
    BazaarTypes.MmrSampleBuffer internal buf;

    function record(uint256 mmrBp) external {
        MmrSampleLib.record(buf, mmrBp);
    }

    function lagged() external view returns (uint256) {
        return MmrSampleLib.laggedMmr(buf);
    }

    function count() external view returns (uint256) {
        return buf.count;
    }

    function head() external view returns (uint256) {
        return buf.head;
    }

    function lastSampleTs() external view returns (uint256) {
        return buf.lastSampleTs;
    }

    function sampleAt(uint256 i) external view returns (uint64 ts, uint256 mmrBp) {
        return (buf.samples[i].ts, buf.samples[i].mmrBp);
    }
}

/// @notice Exposes BucketLib.effectiveMmr (the per-position threshold selector).
contract EffectiveMmrHarness {
    function effectiveMmr(uint256 mmrUpdateTs, uint256 entryMmrBp, uint256 laggedMmrBp, uint256 currentMmrBp)
        external
        view
        returns (uint256)
    {
        return BucketLib.effectiveMmr(mmrUpdateTs, entryMmrBp, laggedMmrBp, currentMmrBp);
    }
}

contract MmrLagTest is Test {
    MmrSampleHarness internal samples;
    EffectiveMmrHarness internal eff;

    uint256 constant HOUR = 1 hours;
    uint256 constant GRACE = 24 hours;
    uint256 constant COUNT = 25; // MMR_SAMPLE_COUNT

    // Base time comfortably past GRACE so the laggedMmr() underflow guard is not the thing under test.
    uint256 constant T0 = 1_000_000;

    function setUp() public {
        samples = new MmrSampleHarness();
        eff = new EffectiveMmrHarness();
        vm.warp(T0);
    }

    // ----------------------------------------------------------------
    // MmrSampleLib.record — hourly gating + ring behaviour
    // ----------------------------------------------------------------

    function test_record_firstSampleAlwaysRecorded() public {
        samples.record(200);
        assertEq(samples.count(), 1);
        assertEq(samples.lastSampleTs(), T0);
        (uint64 ts, uint256 mmr) = samples.sampleAt(0);
        assertEq(uint256(ts), T0);
        assertEq(mmr, 200);
    }

    function test_record_withinIntervalIsNoOp() public {
        samples.record(200);
        vm.warp(T0 + HOUR - 1); // just under one hour
        samples.record(999);
        assertEq(samples.count(), 1, "no new sample under interval");
        (, uint256 mmr) = samples.sampleAt(0);
        assertEq(mmr, 200, "first sample unchanged");
    }

    function test_record_afterIntervalRecords() public {
        samples.record(200);
        vm.warp(T0 + HOUR);
        samples.record(300);
        assertEq(samples.count(), 2);
        (, uint256 m0) = samples.sampleAt(0);
        (, uint256 m1) = samples.sampleAt(1);
        assertEq(m0, 200);
        assertEq(m1, 300);
    }

    function test_record_ringCapsAtCount() public {
        // Record COUNT+5 hourly samples; count must cap at COUNT and head wraps.
        for (uint256 i = 0; i < COUNT + 5; i++) {
            vm.warp(T0 + i * HOUR);
            samples.record(100 + i);
        }
        assertEq(samples.count(), COUNT, "count caps at ring size");
        // head points at next write slot = (COUNT+5) % COUNT == 5
        assertEq(samples.head(), 5);
        // The oldest 5 samples were overwritten; newest is the last write.
        assertEq(samples.lagged() == 0 ? 0 : 1, 1); // sanity: lagged() returns a real value (see below)
    }

    // ----------------------------------------------------------------
    // MmrSampleLib.laggedMmr — selection + robustness
    // ----------------------------------------------------------------

    function test_lagged_emptyBufferReturnsZero() public view {
        assertEq(samples.lagged(), 0);
    }

    function test_lagged_noSampleOldEnoughReturnsZero() public {
        samples.record(200); // sample at T0
        vm.warp(T0 + GRACE - 1); // 1s short of 24h old
        assertEq(samples.lagged(), 0, "sample not yet 24h old");
    }

    function test_lagged_sampleExactly24hOldIsReturned() public {
        samples.record(200); // sample at T0
        vm.warp(T0 + GRACE); // exactly 24h old (cutoff inclusive)
        assertEq(samples.lagged(), 200);
    }

    function test_lagged_returnsNewestSampleAtLeast24hOld() public {
        // Samples at T0, T0+1h, ... T0+5h with rising MMR.
        for (uint256 i = 0; i <= 5; i++) {
            vm.warp(T0 + i * HOUR);
            samples.record(200 + i * 10); // 200,210,...,250
        }
        // Query at T0 + 24h + 3h => cutoff = T0 + 3h. Newest sample <= cutoff is the T0+3h one (230).
        vm.warp(T0 + GRACE + 3 * HOUR);
        assertEq(samples.lagged(), 230);
    }

    function test_lagged_robustToMissedHours() public {
        // Two early samples, then a long gap with no sampling.
        samples.record(200); // T0
        vm.warp(T0 + HOUR);
        samples.record(210); // T0+1h
        // Big gap: query 30h after T0. cutoff = T0+6h. Both samples (<= T0+1h) qualify;
        // newest qualifying is the T0+1h one (210), which is ~29h old — still >= 24h.
        vm.warp(T0 + 30 * HOUR);
        assertEq(samples.lagged(), 210, "older-than-24h sample used despite gap");
    }

    function test_lagged_fullRingSteadyStateHasA24hSample() public {
        // 25 hourly samples => oldest is 24h old when the ring is full.
        for (uint256 i = 0; i < COUNT; i++) {
            vm.warp(T0 + i * HOUR);
            samples.record(300 + i);
        }
        // now = T0 + 24h (last sample at T0+24h). cutoff = T0. Oldest sample (T0, value 300) qualifies.
        // It is the only sample <= cutoff, so lagged == 300.
        assertEq(samples.lagged(), 300, "25-slot ring retains a 24h-old sample");
    }

    // ----------------------------------------------------------------
    // BucketLib.effectiveMmr — per-position threshold selection
    // ----------------------------------------------------------------

    function test_eff_newPosition_risingMmr_graced() public {
        // age < grace => reference = entryMmrBp; entry(200) < current(400) => 200
        uint256 v = eff.effectiveMmr(block.timestamp, 200, 999, 400);
        assertEq(v, 200);
    }

    function test_eff_newPosition_fallingMmr_appliesImmediately() public {
        // entry(400) > current(200) => min => 200 (a drop helps right away)
        uint256 v = eff.effectiveMmr(block.timestamp, 400, 999, 200);
        assertEq(v, 200);
    }

    function test_eff_oldPosition_usesLaggedSample() public {
        // age >= grace and lagged != 0 => reference = lagged(300); current(500) => 300
        uint256 updated = block.timestamp - GRACE; // exactly grace old
        uint256 v = eff.effectiveMmr(updated, 200, 300, 500);
        assertEq(v, 300, "old position judged on lagged sample, not entry");
    }

    function test_eff_oldPosition_laggedAboveCurrent_usesCurrent() public {
        // lagged(600) > current(400) => min => 400
        uint256 updated = block.timestamp - GRACE - HOUR;
        uint256 v = eff.effectiveMmr(updated, 200, 600, 400);
        assertEq(v, 400);
    }

    function test_eff_oldPosition_noSample_fallsBackToEntry() public {
        // age >= grace but laggedMmrBp == 0 => reference = entryMmrBp(200); current(500) => 200
        uint256 updated = block.timestamp - GRACE - HOUR;
        uint256 v = eff.effectiveMmr(updated, 200, 0, 500);
        assertEq(v, 200, "no >=24h sample => entry MMR fallback");
    }

    function test_eff_zeroEntry_fallsBackToCurrent() public {
        // entryMmrBp == 0 and lagged == 0 => reference 0 => use current (never returns 0 MMR)
        uint256 v = eff.effectiveMmr(block.timestamp, 0, 0, 350);
        assertEq(v, 350, "zero reference must not disable liquidation");
    }

    function test_eff_flatPosition_mmrUpdateTsZero_usesEntryOrCurrent() public {
        // mmrUpdateTs == 0 => the lagged branch is skipped even if old/lagged provided.
        uint256 v = eff.effectiveMmr(0, 250, 300, 500);
        assertEq(v, 250, "ts==0 uses entry, not lagged");
    }

    function test_eff_oldPosition_justUnderGrace_stillUsesEntry() public {
        // age = grace - 1 => not yet old => entry path
        uint256 updated = block.timestamp - (GRACE - 1);
        uint256 v = eff.effectiveMmr(updated, 220, 300, 500);
        assertEq(v, 220, "below grace boundary uses entry");
    }
}

// ==================== from FundingIndexTest.t.sol ====================

/// @notice Harness exposing BazaarPair's internal funding-index machinery so accrual
///         can be driven with controlled mark/index prices and timestamps.
contract FundingIndexHarness is BazaarPair {
    function setMark(uint256 mark, uint256 ts) external {
        markPrice = mark;
        lastMarkUpdateTs = ts;
    }

    function setLastFundingUpdateTs(uint256 ts) external {
        lastFundingUpdateTs = ts;
    }

    function updateFundingIndex(uint256 indexPrice, uint256 oracleUpdateTs) external {
        _updateFundingIndex(indexPrice, oracleUpdateTs);
    }
}

/// @notice Regression tests for price-aware funding. The index must accumulate
///         rate × indexPrice (price units) so that BucketLib's Δindex × size / 1e18
///         charges funding on notional, not on raw size. Guards against the bug where
///         a dimensionless index made funding ~price× too weak for assets above $1.
contract FundingIndexTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant T0 = 1_000_000;
    // 30 min — at or below MAX_FUNDING_AGE so validStart stays at lastFundingUpdateTs
    uint256 internal constant ELAPSED = 1800;
    uint256 internal constant FUNDING_INTERVAL = 1 hours;

    FundingIndexHarness internal harness;

    function setUp() public {
        harness = new FundingIndexHarness();
        vm.warp(T0);
        harness.setLastFundingUpdateTs(T0);
    }

    /// @dev Accrues one funding window at the given mark/index and returns the index delta.
    function _accrue(FundingIndexHarness h, uint256 mark, uint256 index) internal returns (int256) {
        uint256 ts = T0 + ELAPSED;
        vm.warp(ts);
        // lastMarkUpdateTs == now → zero decay, currentMark == mark exactly
        h.setMark(mark, ts);
        h.updateFundingIndex(index, ts);
        return h.currentFundingIndex();
    }

    function test_fundingIndexAccruesInPriceUnits() public {
        // $200 asset, mark 1% above index: rate = 1%/8 = 0.125%/hr
        int256 delta = _accrue(harness, 202e18, 200e18);

        // rate 1.25e15 × price 200e18 / 1e18 × (1800/3600) = 0.125e18 ($0.125 per unit of size)
        assertEq(delta, 0.125e18);
    }

    function test_fundingIndexScalesWithPrice() public {
        // Same 1% premium fraction on a $1 asset must accrue 200× less than on a $200 asset
        FundingIndexHarness oneDollar = new FundingIndexHarness();
        oneDollar.setLastFundingUpdateTs(T0);

        int256 deltaAtOne = _accrue(oneDollar, 1.01e18, 1e18);
        int256 deltaAtTwoHundred = _accrue(harness, 202e18, 200e18);

        assertEq(deltaAtOne, 0.000625e18);
        assertEq(deltaAtTwoHundred, deltaAtOne * 200);
    }

    function test_fundingRateClampAppliesToNotional() public {
        // 10% premium dampens to 1.25%/hr, clamped to MAX_FUNDING_RATE = 0.5%/hr
        int256 delta = _accrue(harness, 220e18, 200e18);

        // 5e15 × 200e18 / 1e18 × (1800/3600) = 0.5e18 → 0.5%/hr of $200 notional
        assertEq(delta, 0.5e18);
    }

    function test_fundingIndexNegativeWhenMarkBelowIndex() public {
        int256 delta = _accrue(harness, 198e18, 200e18);

        assertEq(delta, -0.125e18);
    }

    function test_fundingPnlIsRateTimesNotional_viaBucketLib() public {
        int256 fundingIndex = _accrue(harness, 202e18, 200e18); // 0.125e18

        BazaarTypes.PositionBucket memory bucket;
        bucket.isLong = true;
        bucket.size = 10e18; // 10 units of a $200 asset = $2000 notional
        bucket.entryValue = 2000e18;
        bucket.collateral = 500e18;

        BazaarTypes.MarginRequirements memory reqs;
        reqs.imrBp = 500;
        reqs.mmrBp = 300;

        BazaarTypes.BucketState memory state = BucketLib.calculateState(bucket, 200e18, fundingIndex, reqs);

        // Long pays when mark > index: 0.125%/hr × 0.5hr × $2000 = $1.25
        assertEq(state.fundingPnl, -1.25e18);

        bucket.isLong = false;
        state = BucketLib.calculateState(bucket, 200e18, fundingIndex, reqs);
        assertEq(state.fundingPnl, 1.25e18);
    }
}

// ==================== ApplyFill funding settlement ====================

/// @notice Harness with real storage exposing MatchingEngineLib._applyFillWithState, so the
///         funding-settlement-at-close behavior can be unit-tested with a controlled funding index.
contract ApplyFillHarness {
    mapping(uint256 => BazaarTypes.Order) internal orders;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;

    function setBucket(
        address user,
        bool isLong,
        uint256 size,
        uint256 entryValue,
        uint256 collateral,
        int256 entryFundingIndex
    ) external {
        BazaarTypes.PositionBucket storage b = positionBuckets[user];
        b.isLong = isLong;
        b.size = size;
        b.entryValue = entryValue;
        b.collateral = collateral;
        b.entryFundingIndex = entryFundingIndex;
    }

    function applyFill(
        address user,
        bool orderIsLong,
        uint256 fillSize,
        uint256 executionPrice,
        uint256 currentPrice,
        int256 currentFundingIndex
    ) external returns (BazaarTypes.FillResult memory) {
        BazaarTypes.MarginRequirements memory reqs = BazaarTypes.MarginRequirements({
            imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0
        });
        BazaarTypes.PositionBucket memory bucketMem = positionBuckets[user];
        BazaarTypes.BucketState memory state =
            BucketLib.calculateState(bucketMem, currentPrice, currentFundingIndex, reqs);
        BazaarTypes.MatchContext memory ctx;
        ctx.cachedPrice = currentPrice;
        ctx.cachedFundingIdx = currentFundingIndex;
        ctx.marginReqs = reqs;
        return MatchingEngineLib._applyFillWithState(
            user, state, orderIsLong, fillSize, executionPrice, 0, ctx, orders, positionBuckets
        );
    }

    function collateralOf(address u) external view returns (uint256) {
        return positionBuckets[u].collateral;
    }

    function sizeOf(address u) external view returns (uint256) {
        return positionBuckets[u].size;
    }

    function isLongOf(address u) external view returns (bool) {
        return positionBuckets[u].isLong;
    }

    function entryFundingIndexOf(address u) external view returns (int256) {
        return positionBuckets[u].entryFundingIndex;
    }
}

/// @notice Funding must cash-settle into collateral when shares close via matching — proportional
///         on partial close, in full on close/flip, exactly once per share, with the remainder's
///         entry index untouched. Pre-fix, funding was silently dropped on every match-driven close.
contract ApplyFillFundingTest is Test {
    uint256 internal constant SCALE = 1e18;
    address internal alice = address(0xA11CE);

    ApplyFillHarness internal h;

    function setUp() public {
        h = new ApplyFillHarness();
    }

    function test_fullClose_longPaysFunding() public {
        // Long 1 @ $100 entry, $20 collateral. Index delta +2 → long owes $2.
        // Close 1 @ $110: collateral = 20 + 10 (price) − 2 (funding) = 28. (Pre-fix: 30.)
        h.setBucket(alice, true, 1 * SCALE, 100 * SCALE, 20 * SCALE, 0);
        h.applyFill(alice, false, 1 * SCALE, 110 * SCALE, 110 * SCALE, int256(2 * SCALE));

        assertEq(h.collateralOf(alice), 28 * SCALE, "price PnL + funding settled together");
        assertEq(h.sizeOf(alice), 0, "position fully closed");
        assertEq(h.entryFundingIndexOf(alice), 0, "funding index cleared when flat");
    }

    function test_fullClose_shortReceivesFunding() public {
        // Short 1 @ $100 entry, $20 collateral. Index delta +2 → short is owed $2.
        // Close 1 @ $100 (price PnL 0): collateral = 22. (Pre-fix: 20 — credit dropped.)
        h.setBucket(alice, false, 1 * SCALE, 100 * SCALE, 20 * SCALE, 0);
        h.applyFill(alice, true, 1 * SCALE, 100 * SCALE, 100 * SCALE, int256(2 * SCALE));

        assertEq(h.collateralOf(alice), 22 * SCALE, "funding credit realized on close");
    }

    function test_partialClose_settlesProportionally_thenRemainderExactly() public {
        // Long 2 @ $100/u entry, $20 collateral. Index delta +4 → total funding owed $8.
        h.setBucket(alice, true, 2 * SCALE, 200 * SCALE, 20 * SCALE, 0);

        // Close half @ entry price (price PnL 0): settles $4, remainder keeps index 0.
        h.applyFill(alice, false, 1 * SCALE, 100 * SCALE, 100 * SCALE, int256(4 * SCALE));
        assertEq(h.collateralOf(alice), 16 * SCALE, "half the funding settled on half close");
        assertEq(h.sizeOf(alice), 1 * SCALE, "half remains");
        assertEq(h.entryFundingIndexOf(alice), 0, "remainder keeps original entry index");

        // Close the remainder at the same index: settles the other $4 — exactly once per share.
        h.applyFill(alice, false, 1 * SCALE, 100 * SCALE, 100 * SCALE, int256(4 * SCALE));
        assertEq(h.collateralOf(alice), 12 * SCALE, "conservation: total settled == total accrued");
        assertEq(h.sizeOf(alice), 0, "flat");
    }

    function test_flip_settlesAllFunding_andResetsIndexForNewSide() public {
        // Long 1 @ $100 entry, $30 collateral. Index delta +2 → owes $2.
        // Sell 2 @ $100: full close (settle −$2) + open 1 short at the current index.
        h.setBucket(alice, true, 1 * SCALE, 100 * SCALE, 30 * SCALE, 0);
        h.applyFill(alice, false, 2 * SCALE, 100 * SCALE, 100 * SCALE, int256(2 * SCALE));

        assertEq(h.collateralOf(alice), 28 * SCALE, "entire funding settled on the flipped-out side");
        assertEq(h.sizeOf(alice), 1 * SCALE, "residual short opened");
        assertFalse(h.isLongOf(alice), "direction flipped");
        assertEq(h.entryFundingIndexOf(alice), int256(2 * SCALE), "new side starts a clean funding clock");
    }
}
