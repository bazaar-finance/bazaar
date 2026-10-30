// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

// Consolidated: margin checks, the 24h-lagged MMR, and funding index.
import {Test} from "forge-std/Test.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {BucketLib} from "../../src/libraries/BucketLib.sol";
import {MatchingEngineLib} from "../../src/libraries/MatchingEngineLib.sol";
import {MmrSampleLib} from "../../src/libraries/MmrSampleLib.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";

// ==================== checkMargin harness ====================

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
    ) external pure returns (bool) {
        // The partial-close remainder is judged at the lower of mmrBp and a nonzero laggedMmrBp
        // (BucketLib.effectiveMmrBp); the selection itself is covered against EffectiveMmrHarness.
        BazaarTypes.MarginRequirements memory marginReqs =
            BazaarTypes.MarginRequirements({imrBp: imrBp, mmrBp: mmrBp, lastUpdateTs: 0, laggedMmrBp: laggedMmrBp});
        return
            MatchingEngineLib._checkMargin(
                bucket, state, isLong, fillSize, executionPrice, fee, cachedPrice, marginReqs
            );
    }
}

// ==================== checkMargin ====================

/// @notice Unit tests for MatchingEngineLib._checkMargin via CheckMarginHarness.
///         Exercises the four classification branches (open / same-side add / close /
///         flip), the bad-debt rejection paths, the asymmetric incipient-loss debit, the held
///         position's unrealized loss, and the rule for a partial close: a remainder meeting IMR
///         passes outright, and below IMR the account must keep its margin-to-MMR ratio.
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
        bucket.collateral = uint128(collateral);
        state.effectiveCollateral = collateral;
        state.availableEquity = collateral;
        state.isSolvent = true;
    }

    /// @dev Builds a bucket / state pair for an existing position priced at `currentOraclePrice`,
    ///      with no accrued funding.
    function _existingBucket(
        bool isLong,
        uint256 size,
        uint256 entryPrice, // dollars × SCALE per unit
        uint256 collateral,
        uint256 currentOraclePrice
    ) internal pure returns (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) {
        return _existingBucketWithFunding(isLong, size, entryPrice, collateral, currentOraclePrice, 0);
    }

    /// @dev As _existingBucket, with the position owed (positive) or owing (negative) `fundingPnl`.
    ///      The state comes from BucketLib.calculateState, the derivation the fill path runs, so
    ///      collateral stays raw and the price and funding PnL arrive as the separate terms the
    ///      gate reads.
    function _existingBucketWithFunding(
        bool isLong,
        uint256 size,
        uint256 entryPrice,
        uint256 collateral,
        uint256 currentOraclePrice,
        int256 fundingPnl
    ) internal pure returns (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) {
        bucket.isLong = isLong;
        bucket.size = uint128(size);
        bucket.entryValue = uint128((size * entryPrice) / SCALE);
        bucket.collateral = uint128(collateral);

        // With the entry index at 0, a long accrues -(index × size / SCALE) and a short
        // +(index × size / SCALE), so this index yields `fundingPnl` on either side.
        int256 index = (isLong ? -fundingPnl : fundingPnl) * int256(SCALE) / int256(size);
        BazaarTypes.MarginRequirements memory reqs =
            BazaarTypes.MarginRequirements({imrBp: IMR_BP, mmrBp: MMR_BP, lastUpdateTs: 0, laggedMmrBp: 0});
        state = BucketLib.calculateState(bucket, currentOraclePrice, index, reqs);
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
        // IMR = 0.2 × 100 = $20 (notional sized at the oracle) → passes IMR alone
        // Incipient loss = 1 × $5 = $5 → effective collateral = $16
        // 16 < 20 → reject
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
        // Fresh exposure is sized at the oracle, so IMR = 0.2 × 100 = $20 whatever the fill price.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) = _emptyBucket(20 * SCALE);
        assertTrue(harness.checkMargin(bucket, state, true, 1 * SCALE, 95 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
        // $19 fails: crediting the $5 incipient gain would have made this 24 >= 20 and passed,
        // so this assertion is what pins the debit as one-sided.
        (bucket, state) = _emptyBucket(19 * SCALE);
        assertFalse(harness.checkMargin(bucket, state, true, 1 * SCALE, 95 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_OpenShortBelowOracle_RejectedWhenIncipientLoss() public {
        // 1 BTC short, fillPrice = $95 < oracle = $100 → short selling at low = loss
        // IMR = 0.2 × 100 = $20 (notional sized at the oracle). Collateral = $20.
        // Incipient loss = 1 × 5 = $5 → effective $15 < 20. Reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) = _emptyBucket(20 * SCALE);
        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 95 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_OpenShortAboveOracle_NoCreditForGain() public {
        // fillPrice = $105 > oracle = $100 → short selling high = gain. No credit applied.
        // Fresh exposure is sized at the oracle, so IMR = 0.2 × 100 = $20 whatever the fill price.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) = _emptyBucket(20 * SCALE);
        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 105 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
        // Mirror of the long case: $19 fails only because the $5 gain is discarded rather than
        // credited (crediting it would give 24 >= 20). Without this the test cannot see a credit.
        (bucket, state) = _emptyBucket(19 * SCALE);
        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 105 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
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
        // Realized PnL = 0. Remaining = 1 × 100 = 100. IMR = 20. Collateral $20 ≥ $20 → passes.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 2 * SCALE, 100 * SCALE, 20 * SCALE, ORACLE);

        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_LeavingResidualUnderMMR_Rejected() public {
        // Long 2 @ $100 entry, $11 collateral, sells 1 @ $90 (oracle $100)
        // Realized loss = $10. Post-fill collateral = $1. Remaining = 1 × 100 = 100. MMR = $10.
        // 1 < 10 leaves the remainder under maintenance, and the margin-to-MMR ratio falls from
        // 11/20 to 1/10 → reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 2 * SCALE, 100 * SCALE, 11 * SCALE, ORACLE);

        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 90 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_AllowsBelowIMR() public {
        // Long 2 @ $100 entry, $15 collateral. Position IMR = 0.2 × 200 = $40 (way over collateral).
        // User reduces by 1 unit at oracle. Realized PnL = 0. Remaining notional = $100: $15 falls
        // short of IMR on it ($20), so the ratio decides, and closing at the oracle lifts
        // margin-to-MMR from 15/20 to 15/10 → passes. Requiring IMR alone would trap the account.
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
        // Residual: 1 short, valued at the oracle for IMR = 0.2 × 100 = $20.
        // No incipient loss debit (short selling above oracle = gain, ignored).
        // 45 ≥ 20 → passes.
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
        // Residual: 1 long, valued at the oracle for IMR = 0.2 × 100 = $20. Incipient loss (long,
        // fill>oracle) = 1 × 5 = $5. Effective $15 < $20 → reject.
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
        // A gate that looked at price PnL alone would admit this fill.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucketWithFunding(true, 1 * SCALE, 100 * SCALE, 5 * SCALE, ORACLE, -10 * int256(SCALE));

        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_FullClose_FundingCreditRescuesPriceLoss_Passes() public {
        // Long 1 @ $100 entry, $5 collateral, sells 1 @ $90: price loss $10 > collateral,
        // but $10 of funding is owed TO the trader → combined post-fill = +$5 → passes.
        // A gate that saw only the price loss would reject a solvent close.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucketWithFunding(true, 1 * SCALE, 100 * SCALE, 5 * SCALE, ORACLE, 10 * int256(SCALE));

        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 90 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_FundingCreditCountsOnlyOnClosedShares() public {
        // Long 2 @ $100 entry, $20 collateral, owed $4 of funding (oracle $100). A held credit is not
        // counted, so margin is $20 against MMR $20 on the whole position.
        // Selling 1 @ $88 realizes −$12 and settles the closed half's $2 credit → $10. The
        // remainder's $2 stays a held gain and is not credited → $10 against MMR $10, below IMR
        // ($20) but holding the margin-to-MMR ratio at 1 → passes.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucketWithFunding(true, 2 * SCALE, 100 * SCALE, 20 * SCALE, ORACLE, 4 * int256(SCALE));

        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 88 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));

        // Selling 1 @ $87 → $9 < $10, and the margin-to-MMR ratio falls from 20/20 to 9/10 → reject.
        // Crediting the remainder's half as well would admit $87; crediting neither half would
        // reject $88.
        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 87 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_FundingDebtOnRemainderCounts() public {
        // Long 2 @ $100 entry, $30 collateral, owes $4 of funding (oracle $100): margin $26 against
        // MMR $20. Selling 1 @ $87 realizes −$13 and settles the closed half's $2 → $15; the
        // remainder's $2 debt is held and comes off → $13 against MMR $10, below IMR ($20) but
        // holding the margin-to-MMR ratio at 26/20 = 13/10 → passes.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucketWithFunding(true, 2 * SCALE, 100 * SCALE, 30 * SCALE, ORACLE, -4 * int256(SCALE));

        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 87 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));

        // Selling 1 @ $86 → $12, still above MMR $10, but the ratio falls from 26/20 to 12/10 →
        // reject. Leaving the remainder's debt out would read $14 and admit it.
        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 86 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_Flip_SettlesEntireFunding() public {
        // Long 2 @ $100 entry, $30 collateral, sells 3 @ $100 (price PnL = 0) → flip.
        // The whole position closes, so ALL funding settles. Owed $12 → post = $18.
        // Residual 1 short @ $100 → IMR = $20 > $18 → reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucketWithFunding(true, 2 * SCALE, 100 * SCALE, 30 * SCALE, ORACLE, -12 * int256(SCALE));

        assertFalse(harness.checkMargin(bucket, state, false, 3 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));

        // Owed $8 → post = $22 ≥ $20 IMR on the residual → passes.
        (bucket, state) =
            _existingBucketWithFunding(true, 2 * SCALE, 100 * SCALE, 30 * SCALE, ORACLE, -8 * int256(SCALE));

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
        // Existing notional = $100; the add is valued at the oracle, $100. Total = $200. IMR = $40.
        // Incipient loss (long, fill>oracle) = 1 × 5 = $5. Effective $36 < $40 → reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 1 * SCALE, 100 * SCALE, 41 * SCALE, ORACLE);

        assertFalse(harness.checkMargin(bucket, state, true, 1 * SCALE, 105 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    // ============================================================
    // Surviving exposure — its unrealized loss counts, its gain does not
    // ============================================================

    function testCheckMargin_SameSideAdd_HeldLossComesOff() public {
        // Long 1 @ $100 entry, oracle $90: the held position is $10 underwater.
        // Adding 1 @ $90 grows notional to $180 → IMR $36. $45 collateral − $10 = $35 < $36 → reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 1 * SCALE, 100 * SCALE, 45 * SCALE, 90 * SCALE);

        assertFalse(harness.checkMargin(bucket, state, true, 1 * SCALE, 90 * SCALE, 0, 90 * SCALE, IMR_BP, MMR_BP, 0));

        // $46 collateral → $36 ≥ $36 → passes.
        (bucket, state) = _existingBucket(true, 1 * SCALE, 100 * SCALE, 46 * SCALE, 90 * SCALE);

        assertTrue(harness.checkMargin(bucket, state, true, 1 * SCALE, 90 * SCALE, 0, 90 * SCALE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_SameSideAdd_HeldFundingDebtComesOff() public {
        // Long 1 @ $100 entry, oracle $100, $40 collateral, owes $5 of funding. Adding 1 @ $100 →
        // IMR $40 on $200. $40 − $5 = $35 < $40 → reject, where the same add with no funding owed
        // passes exactly.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucketWithFunding(true, 1 * SCALE, 100 * SCALE, 40 * SCALE, ORACLE, -5 * int256(SCALE));

        assertFalse(harness.checkMargin(bucket, state, true, 1 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_SameSideAdd_HeldGainNotCredited() public {
        // Long 1 @ $100 entry, oracle $110: $10 of paper profit. Adding 1 @ $110 → notional $220 →
        // IMR $44. $43 collateral fails: crediting the gain would read $53.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 1 * SCALE, 100 * SCALE, 43 * SCALE, 110 * SCALE);

        assertFalse(harness.checkMargin(bucket, state, true, 1 * SCALE, 110 * SCALE, 0, 110 * SCALE, IMR_BP, MMR_BP, 0));

        (bucket, state) = _existingBucket(true, 1 * SCALE, 100 * SCALE, 44 * SCALE, 110 * SCALE);

        assertTrue(harness.checkMargin(bucket, state, true, 1 * SCALE, 110 * SCALE, 0, 110 * SCALE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_SameSideAdd_BadDebtRejected() public {
        // Long 1 @ $100 entry, $30 collateral, oracle $60: $40 underwater, equity −$10. The raw $30
        // would cover IMR on the grown notional ($13.20 for a 0.1 add), but the held loss exceeds it.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 1 * SCALE, 100 * SCALE, 30 * SCALE, 60 * SCALE);

        assertFalse(harness.checkMargin(bucket, state, true, SCALE / 10, 60 * SCALE, 0, 60 * SCALE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_RemainderLossCounts() public {
        // Long 2 @ $100 entry, oracle $90, $50 collateral: held loss $20, margin $30 against MMR $18.
        // Selling 1 @ $75 realizes −$25 → $25, and the remainder keeps its −$10 → $15 against MMR $9
        // on the remainder, below IMR ($18) but holding the margin-to-MMR ratio at 30/18 = 15/9
        // → passes.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 2 * SCALE, 100 * SCALE, 50 * SCALE, 90 * SCALE);

        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 75 * SCALE, 0, 90 * SCALE, IMR_BP, MMR_BP, 0));

        // Selling 1 @ $74 → $24 − $10 = $14, still above MMR $9, but the ratio falls from 30/18 to
        // 14/9 → reject. Collateral alone ($24) would clear even IMR and admit it.
        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 74 * SCALE, 0, 90 * SCALE, IMR_BP, MMR_BP, 0));
    }

    // ============================================================
    // Partial close — a remainder meeting IMR passes; below IMR the ratio must hold
    // ============================================================

    function testCheckMargin_PartialClose_AtImr_OffMarketStripToMmrRejected() public {
        // Long 100 @ $100 entry, $2,000 collateral: exactly IMR on $10,000. Selling 24.95 @ $50 to a
        // colluding bid realizes −$1,247.50 → $752.50 behind a $7,505 remainder. That still covers
        // the remainder's MMR ($750.50) but not its IMR ($1,501), and the margin-to-MMR ratio falls
        // from 2,000/1,000 to 752.50/750.50 → reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 100 * SCALE, 100 * SCALE, 2_000 * SCALE, ORACLE);

        assertFalse(
            harness.checkMargin(bucket, state, false, 2_495 * SCALE / 100, 50 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0)
        );
    }

    function testCheckMargin_PartialClose_AtImr_ReducesWithinItsOwnMarginRate() public {
        // The same account at exactly IMR, with $20 of margin per unit. Selling 25 @ $80 realizes
        // −$500 → $1,500 behind a $7,500 remainder: exactly its IMR → passes.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 100 * SCALE, 100 * SCALE, 2_000 * SCALE, ORACLE);

        assertTrue(harness.checkMargin(bucket, state, false, 25 * SCALE, 80 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));

        // Selling 25 @ $79 leaves $1,475, short of IMR, and the ratio falls from 2,000/1,000 to
        // 1,475/750 → reject.
        assertFalse(harness.checkMargin(bucket, state, false, 25 * SCALE, 79 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_AboveImr_ReducesToImrNotBelow() public {
        // Long 100 @ $100 entry, $3,000 collateral against a $2,000 IMR. Selling 50 @ $60 realizes
        // −$2,000 → $1,000 behind a $5,000 remainder: exactly its IMR → passes. $2,000 is also what
        // closing 50 at the oracle and then withdrawing down to IMR would release.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 100 * SCALE, 100 * SCALE, 3_000 * SCALE, ORACLE);

        assertTrue(harness.checkMargin(bucket, state, false, 50 * SCALE, 60 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));

        // Selling 50 @ $59 leaves $950: short of IMR though still covering the remainder's $500 MMR,
        // and the ratio falls from 3,000/1,000 to 950/500 → reject.
        assertFalse(harness.checkMargin(bucket, state, false, 50 * SCALE, 59 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_BetweenMmrAndImr_HoldsRatio() public {
        // Long 100 @ $100 entry, $1,500 collateral: above MMR ($1,000), below IMR ($2,000), a
        // margin-to-MMR ratio of 1.5. Selling 50 at the oracle leaves $1,500 behind a $5,000
        // remainder, above its $1,000 IMR → passes.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 100 * SCALE, 100 * SCALE, 1_500 * SCALE, ORACLE);

        assertTrue(harness.checkMargin(bucket, state, false, 50 * SCALE, 100 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));

        // Selling 50 @ $85 leaves $750 against MMR $500: below IMR, but the ratio holds at 1.5 →
        // passes.
        assertTrue(harness.checkMargin(bucket, state, false, 50 * SCALE, 85 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));

        // Selling 50 @ $84 leaves $700: still above MMR, but the ratio falls to 1.4 → reject.
        assertFalse(harness.checkMargin(bucket, state, false, 50 * SCALE, 84 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_Short_AtImr_BuysBackWithinItsOwnMarginRate() public {
        // Short 100 @ $100 entry, $2,000 collateral: exactly IMR. Buying 25 back @ $120 realizes
        // −$500 → $1,500 behind a $7,500 remainder: exactly its IMR → passes.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(false, 100 * SCALE, 100 * SCALE, 2_000 * SCALE, ORACLE);

        assertTrue(harness.checkMargin(bucket, state, true, 25 * SCALE, 120 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));

        // Buying 25 back @ $121 leaves $1,475, short of IMR, and the ratio falls from 2,000/1,000
        // to 1,475/750 → reject.
        assertFalse(harness.checkMargin(bucket, state, true, 25 * SCALE, 121 * SCALE, 0, ORACLE, IMR_BP, MMR_BP, 0));
    }

    // ============================================================
    // Under maintenance — a reduction must not lower the margin-to-MMR ratio
    // ============================================================

    function testCheckMargin_PartialClose_UnderMaintenance_HoldsRatio() public {
        // Long 4 @ $100 entry, oracle $90, $50 collateral: held loss $40, margin $10 against MMR $36
        // (ratio 10/36, liquidatable). Selling 1 @ $90 realizes −$10 → $40, and the remainder keeps
        // −$30 → $10 against MMR $27: still under maintenance, but the ratio rises to 10/27 → passes.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 4 * SCALE, 100 * SCALE, 50 * SCALE, 90 * SCALE);

        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 90 * SCALE, 0, 90 * SCALE, IMR_BP, MMR_BP, 0));

        // A price gap within the account's margin rate ($10 on $360, i.e. $2.50 per unit) still
        // passes: selling 1 @ $88 leaves $8 against $27 (8 × 36 ≥ 10 × 27).
        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 88 * SCALE, 0, 90 * SCALE, IMR_BP, MMR_BP, 0));

        // One beyond it does not: selling 1 @ $87 leaves $7 against $27 (7 × 36 < 10 × 27) → reject.
        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 87 * SCALE, 0, 90 * SCALE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_PartialClose_BadDebt() public {
        // Long 2 @ $100 entry, $30 collateral, oracle $80: held loss $40, equity −$10.
        // Selling 1 @ $80 leaves $10 against the remainder's −$20 → −$10 → reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 2 * SCALE, 100 * SCALE, 30 * SCALE, 80 * SCALE);

        assertFalse(harness.checkMargin(bucket, state, false, 1 * SCALE, 80 * SCALE, 0, 80 * SCALE, IMR_BP, MMR_BP, 0));

        // Selling 1 @ $95 into a bid far above the oracle realizes only −$5 → $25 − $20 = $5: solvent
        // again, which lifts the ratio from negative → passes.
        assertTrue(harness.checkMargin(bucket, state, false, 1 * SCALE, 95 * SCALE, 0, 80 * SCALE, IMR_BP, MMR_BP, 0));
    }

    function testCheckMargin_FullClose_BadDebt_JudgedAtFillPrice() public {
        // Long 2 @ $100 entry, $30 collateral, oracle $80 (equity −$10). The bankruptcy price is
        // $85: a full close at $86 realizes −$28 → $2 → passes; at $84 → −$2 → reject.
        (BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory state) =
            _existingBucket(true, 2 * SCALE, 100 * SCALE, 30 * SCALE, 80 * SCALE);

        assertTrue(harness.checkMargin(bucket, state, false, 2 * SCALE, 86 * SCALE, 0, 80 * SCALE, IMR_BP, MMR_BP, 0));
        assertFalse(harness.checkMargin(bucket, state, false, 2 * SCALE, 84 * SCALE, 0, 80 * SCALE, IMR_BP, MMR_BP, 0));
    }
}

// ==================== lagged MMR ====================

/// @notice Exposes MmrSampleLib over a real storage ring buffer for unit testing.
contract MmrSampleHarness {
    BazaarTypes.MmrSampleBuffer internal buf;

    function record(uint256 mmrBp) external {
        MmrSampleLib.record(buf, mmrBp, 0);
    }

    function recordWithOi(uint256 mmrBp, uint256 oiSize) external returns (bool closed) {
        (closed,) = MmrSampleLib.record(buf, mmrBp, oiSize);
    }

    function trailingOi() external view returns (uint256 oiSize, bool found) {
        return MmrSampleLib.trailingOi(buf);
    }

    /// @dev Anchors the lookback to the calling block, i.e. what the pair resolves when the caller
    ///      supplies a fresh price.
    function lagged() external view returns (uint256) {
        return MmrSampleLib.laggedMmr(buf, block.timestamp);
    }

    /// @dev Anchors the lookback to an explicit mark timestamp, i.e. what the pair resolves when a
    ///      call falls back to a stored price older than the block.
    function laggedAt(uint256 refTs) external view returns (uint256) {
        return MmrSampleLib.laggedMmr(buf, refTs);
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

    function sampleOiAt(uint256 i) external view returns (uint256) {
        return buf.samples[i].oiSize;
    }
}

/// @notice Exposes BucketLib.effectiveMmrBp (the maintenance rate every position is judged at).
contract EffectiveMmrHarness {
    function effectiveMmrBp(uint256 mmrBp, uint256 laggedMmrBp) external pure returns (uint256) {
        return BucketLib.effectiveMmrBp(
            BazaarTypes.MarginRequirements({imrBp: mmrBp * 2, mmrBp: mmrBp, lastUpdateTs: 0, laggedMmrBp: laggedMmrBp})
        );
    }
}

contract MmrLagTest is Test {
    MmrSampleHarness internal samples;
    EffectiveMmrHarness internal eff;

    uint256 constant HOUR = 1 hours;
    uint256 constant GRACE = 24 hours;
    uint256 constant COUNT = 25; // MMR_SAMPLE_COUNT

    // Base time comfortably past GRACE, so a cutoff before the ring's first sample is the ring being
    // young rather than the reference instant sitting inside the first day of the epoch.
    uint256 constant T0 = 1_000_000;

    function setUp() public {
        samples = new MmrSampleHarness();
        eff = new EffectiveMmrHarness();
        vm.warp(T0);
    }

    // ----------------------------------------------------------------
    // MmrSampleLib.record — hourly gating + ring behaviour
    // ----------------------------------------------------------------

    /// @notice The first record only opens the first interval: a sample is written when an
    ///         interval closes, and nothing has closed yet.
    function test_record_firstCallOpensAnIntervalAndWritesNothing() public {
        samples.record(200);
        assertEq(samples.count(), 0, "nothing to close yet");
        assertEq(samples.lastSampleTs(), T0, "the interval opened now");
    }

    function test_record_withinIntervalIsNoOp() public {
        samples.record(200);
        vm.warp(T0 + HOUR - 1); // just under one hour
        samples.record(999);
        assertEq(samples.count(), 0, "no sample under interval");
        assertEq(samples.lastSampleTs(), T0, "the interval is still the one that opened at T0");
    }

    /// @notice A sample is the lowest rate in force during its interval, stamped where the
    ///         interval opened, so a rate that first appears at the closing refresh is sampled one
    ///         interval later.
    function test_record_afterIntervalRecords() public {
        samples.record(200);
        vm.warp(T0 + HOUR);
        samples.record(300);
        assertEq(samples.count(), 1);
        (uint64 ts0, uint256 m0) = samples.sampleAt(0);
        assertEq(uint256(ts0), T0, "stamped where the interval opened");
        assertEq(m0, 200, "200 held the whole interval; 300 arrived as it closed");
        assertEq(samples.lastSampleTs(), T0 + HOUR, "the next interval opened at the close");
        vm.warp(T0 + 2 * HOUR);
        samples.record(300);
        (uint64 ts1, uint256 m1) = samples.sampleAt(1);
        assertEq(uint256(ts1), T0 + HOUR);
        assertEq(m1, 300, "300 held the next interval");
    }

    /// @notice A rise that holds for part of an interval never reaches the ring: the interval's
    ///         sample is its lowest rate, whichever refresh saw it.
    function test_record_briefRiseInsideIntervalIsNotSampled() public {
        samples.record(200);
        vm.warp(T0 + 10 minutes);
        samples.record(900); // rate raised
        vm.warp(T0 + 20 minutes);
        samples.record(200); // and restored
        vm.warp(T0 + HOUR);
        samples.record(900); // raised again as the interval closes
        assertEq(samples.count(), 1);
        (, uint256 m0) = samples.sampleAt(0);
        assertEq(m0, 200, "the interval's lowest rate is what is sampled");
    }

    /// @notice A fall inside the interval is what the sample records, even when the rate is back
    ///         up by the time the interval closes.
    function test_record_dipInsideIntervalIsSampled() public {
        samples.record(500);
        vm.warp(T0 + 30 minutes);
        samples.record(200);
        vm.warp(T0 + HOUR);
        samples.record(500);
        (, uint256 m0) = samples.sampleAt(0);
        assertEq(m0, 200);
    }

    function test_record_ringCapsAtCount() public {
        // COUNT+5 hourly records close COUNT+4 intervals; count must cap at COUNT and head wraps.
        for (uint256 i = 0; i < COUNT + 5; i++) {
            vm.warp(T0 + i * HOUR);
            samples.record(100 + i);
        }
        assertEq(samples.count(), COUNT, "count caps at ring size");
        // head points at next write slot = (COUNT+4) % COUNT == 4
        assertEq(samples.head(), 4);
        assertGt(samples.lagged(), 0, "sanity: the ring still resolves a lagged value");
    }

    // ----------------------------------------------------------------
    // MmrSampleLib — open-interest sampling and the trailing minimum
    // ----------------------------------------------------------------

    uint256 constant OI_LOW = 10e18;
    uint256 constant OI_HIGH = 500e18;

    /// @dev Hourly records of `oiSize` at hours [from, to) past T0.
    function _recordHourly(uint256 from, uint256 to, uint256 oiSize) internal {
        for (uint256 i = from; i < to; i++) {
            vm.warp(T0 + i * HOUR);
            samples.recordWithOi(200, oiSize);
        }
    }

    /// @notice Open interest raised and unwound inside one interval never reaches the ring: the
    ///         sample is the interval's lowest reading, whichever refresh saw it.
    function test_oi_briefRiseInsideIntervalIsNotSampled() public {
        assertFalse(samples.recordWithOi(200, OI_LOW), "the first record only opens an interval");
        vm.warp(T0 + 10 minutes);
        assertFalse(samples.recordWithOi(200, OI_HIGH), "nothing closes inside the interval");
        vm.warp(T0 + HOUR);
        assertTrue(samples.recordWithOi(200, OI_HIGH), "the interval closes");
        assertEq(samples.sampleOiAt(0), OI_LOW, "the interval's lowest open interest is what is sampled");
    }

    /// @notice A fall inside the interval is what the sample records, even when open interest is
    ///         back up by the time the interval closes.
    function test_oi_dipInsideIntervalIsSampled() public {
        samples.recordWithOi(200, OI_HIGH);
        vm.warp(T0 + 30 minutes);
        samples.recordWithOi(200, OI_LOW);
        vm.warp(T0 + HOUR);
        samples.recordWithOi(200, OI_HIGH);
        assertEq(samples.sampleOiAt(0), OI_LOW);
    }

    /// @notice An open interest past the sample's field is recorded at the field's ceiling, not
    ///         wrapped into a small one.
    function test_oi_saturatesAtTheFieldWidth() public {
        samples.recordWithOi(200, type(uint256).max);
        vm.warp(T0 + HOUR);
        samples.recordWithOi(200, type(uint256).max);
        assertEq(samples.sampleOiAt(0), type(uint128).max);
    }

    /// @notice There is no trailing minimum until a sampled interval opened a full grace period
    ///         ago; from that instant it is found.
    function test_trailingOi_notFoundUntilASampledIntervalIsADayOld() public {
        (uint256 oi, bool found) = samples.trailingOi();
        assertFalse(found, "empty ring");
        _recordHourly(0, 2, OI_LOW); // closes the interval that opened at T0
        (oi, found) = samples.trailingOi();
        assertFalse(found, "the only sample opened an hour ago");
        assertEq(oi, 0);

        vm.warp(T0 + GRACE - 1);
        (, found) = samples.trailingOi();
        assertFalse(found, "one second short of a day");
        vm.warp(T0 + GRACE);
        (oi, found) = samples.trailingOi();
        assertTrue(found, "the interval that opened at T0 is a day old");
        assertEq(oi, OI_LOW);
    }

    /// @notice A rise reaches the trailing minimum only once every sample since the cutoff carries
    ///         it: 24 hours after the first interval that held it throughout opened.
    function test_trailingOi_sustainedRiseCountsAfterAFullDay() public {
        _recordHourly(0, 25, OI_LOW); // a day of history at the low reading
        for (uint256 i = 25; i < 49; i++) {
            vm.warp(T0 + i * HOUR);
            samples.recordWithOi(200, OI_HIGH);
            (uint256 during, bool found) = samples.trailingOi();
            assertTrue(found);
            assertEq(during, OI_LOW, "an interval that saw the low reading is still in the window");
        }
        vm.warp(T0 + 49 * HOUR);
        samples.recordWithOi(200, OI_HIGH);
        (uint256 oi,) = samples.trailingOi();
        assertEq(oi, OI_HIGH, "every interval since the cutoff held the high reading");
    }

    /// @notice A fall reaches the trailing minimum at the record that sees it, through the open
    ///         interval, with no interval having to close.
    function test_trailingOi_fallCountsAtOnce() public {
        _recordHourly(0, 26, OI_HIGH);
        (uint256 oi,) = samples.trailingOi();
        assertEq(oi, OI_HIGH);
        vm.warp(T0 + 25 * HOUR + 5 minutes);
        assertFalse(samples.recordWithOi(200, OI_LOW), "no interval closes");
        (oi,) = samples.trailingOi();
        assertEq(oi, OI_LOW);
    }

    /// @notice Zero open interest inside the window is a found minimum of zero, distinct from no
    ///         minimum at all.
    function test_trailingOi_zeroInTheWindowIsFoundAsZero() public {
        _recordHourly(0, 26, OI_HIGH);
        vm.warp(T0 + 25 * HOUR + 5 minutes);
        samples.recordWithOi(200, 0);
        (uint256 oi, bool found) = samples.trailingOi();
        assertTrue(found);
        assertEq(oi, 0);
    }

    /// @notice With hours missing from the ring, the newest interval that opened at or before the
    ///         cutoff opens the window, however old it is.
    function test_trailingOi_robustToMissedHours() public {
        _recordHourly(0, 2, OI_LOW); // one sample, stamped T0
        vm.warp(T0 + 3 days);
        samples.recordWithOi(200, OI_HIGH); // closes the interval that opened at T0 + 1h
        (uint256 oi, bool found) = samples.trailingOi();
        assertTrue(found, "the interval that opened at T0 + 1h is older than a day");
        assertEq(oi, OI_LOW, "and its reading holds the minimum down");
    }

    /// @notice The ring keeps the lagged MMR and the trailing open interest in the same samples
    ///         without either disturbing the other.
    function test_trailingOi_sharesTheRingWithTheLaggedMmr() public {
        _recordHourly(0, 26, OI_LOW);
        assertEq(samples.lagged(), 200, "the rate half of each sample");
        (uint256 oi,) = samples.trailingOi();
        assertEq(oi, OI_LOW, "the open-interest half");
        assertEq(samples.count(), 25);
    }

    // ----------------------------------------------------------------
    // MmrSampleLib.laggedMmr — selection + robustness
    // ----------------------------------------------------------------

    function test_lagged_emptyBufferReturnsZero() public view {
        assertEq(samples.lagged(), 0);
    }

    /// @notice Before any interval has closed, the open interval's running minimum is every rate
    ///         the pair has recorded, and it is what the lookback returns.
    function test_lagged_nothingClosedYetReturnsTheOpenIntervalMinimum() public {
        samples.record(300); // T0: opens the first interval
        vm.warp(T0 + 10 minutes);
        samples.record(250); // lowers the open interval's minimum
        vm.warp(T0 + 20 minutes);
        samples.record(900); // a rise inside the interval does not raise it
        assertEq(samples.count(), 0, "nothing closed yet");
        assertEq(samples.lagged(), 250, "the lowest rate recorded so far");
    }

    /// @notice A ring that does not reach back a full grace period is the history of a young pair,
    ///         and the lookback shortens to all of it: the lowest rate it has recorded.
    function test_lagged_youngRingReturnsItsLowestSample() public {
        samples.record(500); // T0: opens the first interval
        vm.warp(T0 + HOUR);
        samples.record(500); // closes it at 500
        vm.warp(T0 + 2 * HOUR);
        samples.record(200); // closes the T0+1h interval at 200, its closing rate
        vm.warp(T0 + 3 * HOUR);
        samples.record(800); // closes the T0+2h interval at 200; the rate is now 800
        vm.warp(T0 + GRACE - 1); // the first sample is one second short of a day old
        assertEq(samples.lagged(), 200, "the lowest sample the young ring holds");
    }

    /// @notice A brief rise on a young pair reaches the lookback no more than it does on an old one:
    ///         the rate must hold for every sample the pair has taken.
    function test_lagged_youngRingHoldsBackABriefRise() public {
        samples.record(200); // T0
        vm.warp(T0 + HOUR);
        samples.record(900); // the rise lands as the first interval closes: sampled at 200
        vm.warp(T0 + HOUR + 1 minutes);
        samples.record(200); // and is unwound inside the next interval
        assertEq(samples.lagged(), 200, "the young ring's lowest sample");
    }

    /// @notice The cutoff is inclusive: the interval that opened exactly a grace period before the
    ///         reference closes the window, and the older one behind it stays out.
    function test_lagged_sampleExactly24hOldIsReturned() public {
        vm.warp(T0 - HOUR);
        samples.record(100); // an interval at 100 that ends as the next opens
        vm.warp(T0);
        samples.record(300); // closes it at 100; the interval opening now holds 300
        vm.warp(T0 + HOUR);
        samples.record(900); // closes the T0 interval at 300; the open interval holds 900
        vm.warp(T0 + GRACE); // exactly 24h since the T0 interval opened
        assertEq(samples.lagged(), 300, "the interval opened at the cutoff closes the window");
    }

    function test_lagged_windowOpensOnTheIntervalInForceAtTheCutoff() public {
        // Rates at T0, T0+1h, ... T0+5h rising; each sample carries the lowest rate in force over
        // the interval it opens, so the ring holds T0:200, T0+1h:210, T0+2h:220, T0+3h:230, T0+4h:240.
        for (uint256 i = 0; i <= 5; i++) {
            vm.warp(T0 + i * HOUR);
            samples.record(200 + i * 10); // 200,210,...,250
        }
        // Query at T0 + 24h + 3h => cutoff = T0 + 3h. The interval that opened at T0+3h was in
        // force at the cutoff (230) and nothing newer is lower.
        vm.warp(T0 + GRACE + 3 * HOUR);
        assertEq(samples.lagged(), 230);
    }

    /// @notice The window is the whole day, not its opening instant: a rate sampled high at the
    ///         cutoff but lower since is judged at the lower rate, so two brief rises a day apart
    ///         cannot meet in the threshold.
    function test_lagged_lowestSampleAcrossTheWindowWins() public {
        samples.record(900); // T0: 900 in force for the whole first interval
        vm.warp(T0 + HOUR);
        samples.record(900); // closes it at 900
        for (uint256 i = 2; i <= 24; i++) {
            vm.warp(T0 + i * HOUR);
            samples.record(200);
        }
        vm.warp(T0 + 25 * HOUR);
        samples.record(900); // closes the last 200 interval; the open interval holds 900
        // Query at T0 + 24h: cutoff = T0, whose interval held 900 like the open one; every
        // interval between holds 200.
        assertEq(samples.laggedAt(T0 + GRACE), 200, "a later lower sample governs");
    }

    /// @notice A rise that holds for the whole day reaches the threshold once the cutoff has moved
    ///         onto the first interval that opened at the higher rate.
    function test_lagged_sustainedRiseBitesAfterAFullDay() public {
        samples.record(200); // T0
        for (uint256 i = 1; i <= 25; i++) {
            vm.warp(T0 + i * HOUR);
            samples.record(900); // raised at T0+1h and held
        }
        // Samples: T0 -> 200 (the interval the rise closed), T0+1h on -> 900.
        // At T0 + 24h the cutoff is T0, whose interval still holds 200.
        assertEq(samples.laggedAt(T0 + GRACE), 200, "the interval the rise landed in still opens the window");
        // At T0 + 25h the cutoff is T0+1h: the rise has held for a full day.
        assertEq(samples.lagged(), 900, "an hour later the window holds only 900");
    }

    function test_lagged_robustToMissedHours() public {
        samples.record(100); // T0
        vm.warp(T0 + HOUR);
        samples.record(200); // closes the T0 interval at 100
        vm.warp(T0 + 2 * HOUR);
        samples.record(210); // closes the T0+1h interval at 200
        // A long gap, then a record that closes the T0+2h interval at 210.
        vm.warp(T0 + 30 * HOUR);
        samples.record(250);
        // Cutoff = T0+6h. No interval opened in that hour; the newest that opened earlier, at
        // T0+2h, closes the window despite the gap, and the older 200 and 100 stay outside it.
        assertEq(samples.lagged(), 210, "older-than-24h sample used despite gap");
    }

    /// @notice An interval still open since before the cutoff was in force for the whole window,
    ///         so its running minimum is the answer and the closed samples before it stay out.
    function test_lagged_openIntervalInForceAtTheCutoffIsTheWindow() public {
        samples.record(100); // T0
        vm.warp(T0 + HOUR);
        samples.record(300); // closes the T0 interval at 100; 300 holds from here on
        vm.warp(T0 + 30 * HOUR); // nothing recorded since: cutoff = T0+6h, inside the open interval
        assertEq(samples.lagged(), 300, "the rate in force since before the cutoff");
        assertEq(
            samples.laggedAt(T0 + 2 * HOUR), 100, "measured from an earlier mark, the older sample is in the window"
        );
    }

    /// @notice A fall counts from the record that sees it: a dip inside the open interval reaches
    ///         the lookback at once and stays after the rate recovers, without waiting for the
    ///         interval to close.
    function test_lagged_dipInTheOpenIntervalCountsAtOnce() public {
        for (uint256 i = 0; i <= 25; i++) {
            vm.warp(T0 + i * HOUR);
            samples.record(500); // a day and more at 500
        }
        assertEq(samples.lagged(), 500, "every rate recorded over the day is 500");
        vm.warp(T0 + 25 * HOUR + 10 minutes);
        samples.record(200); // the rate dips inside the open interval
        assertEq(samples.lagged(), 200, "the dip counts at once");
        vm.warp(T0 + 25 * HOUR + 20 minutes);
        samples.record(500); // and recovers before the interval closes
        assertEq(samples.count(), COUNT, "no interval closed since");
        uint256 lagged = samples.lagged();
        assertEq(lagged, 200, "the recovery does not erase it");
        assertEq(eff.effectiveMmrBp(500, lagged), 200, "a position opened in the dip is judged at the dip");
    }

    /// @notice A rise inside the open interval cannot raise the lookback: the interval's running
    ///         minimum only falls.
    function test_lagged_riseInTheOpenIntervalLeavesItUnchanged() public {
        for (uint256 i = 0; i <= 25; i++) {
            vm.warp(T0 + i * HOUR);
            samples.record(300);
        }
        vm.warp(T0 + 25 * HOUR + 10 minutes);
        samples.record(900);
        assertEq(samples.lagged(), 300);
    }

    function test_lagged_fullRingSteadyStateHasA24hSample() public {
        // COUNT hourly records close COUNT-1 intervals; the oldest opened 24h before the last record.
        for (uint256 i = 0; i < COUNT; i++) {
            vm.warp(T0 + i * HOUR);
            samples.record(300 + i);
        }
        // now = T0 + 24h. cutoff = T0. The interval that opened at T0 (300) is exactly a day old.
        assertEq(samples.lagged(), 300, "the ring retains a 24h-old sample");
        // A further hourly record fills the ring; the interval that opened at T0+1h is now the
        // one in force at the cutoff.
        vm.warp(T0 + COUNT * HOUR);
        samples.record(300 + COUNT);
        assertEq(samples.count(), COUNT, "ring full");
        assertEq(samples.lagged(), 301, "the ring still holds the interval in force a day ago");
    }

    /// @notice The lookback is measured back from the reference instant the caller passes, not from
    ///         the block. Two reads of the SAME ring at the same block resolve different samples
    ///         purely because the mark they are anchored to differs.
    function test_lagged_lookbackIsMeasuredFromTheReferenceInstant() public {
        // Rising MMR sampled hourly at T0 .. T0+5h: the ring holds T0:200 ... T0+4h:240.
        for (uint256 i = 0; i <= 5; i++) {
            vm.warp(T0 + i * HOUR);
            samples.record(200 + i * 10); // 200,210,...,250
        }
        vm.warp(T0 + GRACE + 3 * HOUR);

        // Anchored to the block: cutoff = T0+3h, so the interval that opened at T0+3h (230) opens
        // the window.
        assertEq(samples.lagged(), 230, "block anchor selects the T0+3h interval");

        // Anchored to a mark two hours behind the block: cutoff = T0+1h, so the older, lower
        // T0+1h interval (210) opens the window instead.
        assertEq(
            samples.laggedAt(block.timestamp - 2 * HOUR),
            210,
            "mark anchor selects the interval in force 24h before the mark"
        );
    }

    /// @notice The ratchet the grace period implies advances with the MARK, not with wall time. A
    ///         stored price that stops advancing freezes the threshold with it, so waiting for the
    ///         cutoff to roll onto a higher sample cannot raise the requirement a position is
    ///         judged against while the mark it is judged at stays put.
    function test_lagged_staleMarkFreezesTheRatchet() public {
        samples.record(200); // T0
        vm.warp(T0 + HOUR);
        samples.record(900); // T0+1h — a sharply higher requirement; the T0 interval is sampled at 200
        vm.warp(T0 + 2 * HOUR);
        samples.record(900); // T0+2h — the T0+1h interval held 900 throughout, sampled as 900

        uint256 markTs = T0 + GRACE; // cutoff = T0: the window holds 200, 900

        vm.warp(markTs);
        assertEq(samples.laggedAt(markTs), 200, "the step has not aged into the window yet");

        // Two hours of wall time later the block-anchored cutoff has moved past the 200 sample.
        vm.warp(markTs + 2 * HOUR);
        assertEq(samples.lagged(), 900, "block anchor ratchets onto the higher sample");

        // Anchored to the same unchanged mark it does not.
        assertEq(samples.laggedAt(markTs), 200, "mark anchor holds the threshold with the price");
    }

    /// @notice A rise landing inside an interval holds every position back alike, however recently
    ///         it opened: a position opened at T0+30m, after the rise to 500, is judged at the
    ///         interval's 200 minimum until the rise has held through a whole window.
    function test_lagged_riseHoldsBackEveryPositionUntilItHasHeldADay() public {
        samples.record(200); // T0: the interval opens at 200
        vm.warp(T0 + 15 minutes);
        samples.record(500); // the rate rises; the interval's minimum stays 200
        for (uint256 i = 1; i <= 24; i++) {
            vm.warp(T0 + i * HOUR);
            samples.record(500); // 500 in force continuously from T0+15m on
        }
        // At T0+24h the cutoff is T0: the interval that opened then (200) opens the window.
        uint256 lagged = samples.laggedAt(T0 + GRACE);
        assertEq(lagged, 200, "the opening interval's minimum");
        assertEq(eff.effectiveMmrBp(500, lagged), 200, "every position, new or old, is judged at 200");
        // An hour on the window opens on the interval that began at T0+1h, in force at 500 throughout.
        lagged = samples.laggedAt(T0 + GRACE + HOUR);
        assertEq(lagged, 500);
        assertEq(eff.effectiveMmrBp(500, lagged), 500, "the rise has held for the grace period");
    }

    // ----------------------------------------------------------------
    // BucketLib.effectiveMmrBp — the rate positions and the band are judged at
    // ----------------------------------------------------------------

    /// @notice A current rate that has not held for the grace period reaches neither a position's
    ///         threshold nor the band: the lower lagged minimum stands.
    function test_eff_spikedCurrentReadsTheLaggedMinimum() public view {
        assertEq(eff.effectiveMmrBp(1000, 250), 250, "spike ignored");
    }

    function test_eff_fallsWithTheCurrentRateAtOnce() public view {
        assertEq(eff.effectiveMmrBp(200, 400), 200, "a lower current rate helps immediately");
    }

    function test_eff_equalRatesReturnThatRate() public view {
        assertEq(eff.effectiveMmrBp(300, 300), 300);
    }

    function test_eff_nothingSampledUsesCurrent() public view {
        assertEq(eff.effectiveMmrBp(700, 0), 700, "no lagged rate: the current rate stands");
    }
}

// ==================== funding index ====================

/// @notice Harness exposing BazaarPair's internal funding-index machinery so accrual
///         can be driven with controlled mark premiums, index prices and timestamps.
contract FundingIndexHarness is BazaarPair {
    /// @dev The premium the stored line reads now, over the floor the pair's open interest sets
    ///      at `indexPrice`.
    function markPremiumOf(uint256 indexPrice) external view returns (int256) {
        return FundingLib.currentPremium(
            markPremiumNotional,
            rollingVolume,
            lastMarkUpdateTs,
            FundingLib.floorVolumeOf(RiskParamsLib.openInterestSize(pairVault), indexPrice)
        );
    }

    /// @dev A line reading `premium` on `volume`, anchored at `ts`.
    function setLine(int256 premium, uint256 ts, uint256 volume) external {
        markPremiumNotional = int256(volume) * premium / int256(BazaarTypes.BAZAAR_SCALE);
        lastMarkUpdateTs = ts;
        rollingVolume = volume;
    }

    /// @dev Per-side open interest, which sizes the floor.
    function setOpenInterest(uint256 size) external {
        pairVault.totalLongOI = size;
        pairVault.totalShortOI = size;
    }

    function setLastFundingUpdateTs(uint256 ts) external {
        lastFundingUpdateTs = ts;
    }

    /// @dev Ages the index reference the mark gate reads, without storing a price.
    function setPriceReferenceTs(uint256 ts) external {
        lastPairPrice.updateTs = ts;
    }

    function markUpdateTs() external view returns (uint256) {
        return lastMarkUpdateTs;
    }

    function updateMarkPrice(uint256 fillNotional, uint256 fillSize, uint256 indexPrice) external {
        _updateMarkPrice(fillNotional, fillSize, indexPrice);
    }

    function updateFundingIndex(uint256 indexPrice, uint256 oracleUpdateTs) external {
        _updateFundingIndex(indexPrice, oracleUpdateTs);
    }
}

/// @notice Price-aware funding. The index must accumulate rate × indexPrice (price units) so
///         that BucketLib's Δindex × size / 1e18 charges funding on notional, not on raw size.
///         A dimensionless index would make funding ~price× too weak for every asset above $1.
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
        // A line anchored at the window's start on volume no floor can bind (the harness holds no
        // open interest) reads the mark's premium flat across the window, so the window accrues at
        // that premium exactly. The volume is a multiple of the period, so the fade is exact.
        h.setLine((int256(mark) - int256(index)) * int256(SCALE) / int256(index), T0, 36e29);
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

// ==================== mark reference age ====================

/// @notice A print may enter the mark EMA only while the index it is judged against is fresh:
///         stored within MAX_PRICE_STALENESS of the fill, as a fill priced off a fresh oracle
///         tick always is. That index is lastPairPrice, which a caller executes against by
///         withholding a price update, so the gate keys on the reference's age rather than on
///         whether the caller supplied an update; a print judged against an older index would
///         read the index's own move since then as premium, dated as freshly traded, and the
///         next store would charge it as funding.
contract MarkReferenceAgeTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant T0 = 1_000_000;
    uint256 internal constant STALENESS = 3 seconds; // BazaarTypes.MAX_PRICE_STALENESS

    FundingIndexHarness internal harness;

    function setUp() public {
        harness = new FundingIndexHarness();
        // One unit of open interest at $200 floors the volume at $4, so a call may add $0.40.
        harness.setOpenInterest(1e18);
        vm.warp(T0);
    }

    /// @dev One unit printed at $205 against a $200 index. Inside the ±4% band, so its premium
    ///      enters unclamped; the cap admits $1 of its $205, read over the $4 floor, so the mark
    ///      lands a quarter of the way to the print: a premium of 0.625%.
    function _print() internal {
        harness.updateMarkPrice(205 * SCALE, 1 * SCALE, 200 * SCALE);
    }

    /// @notice A reference stored within the staleness limit admits the print: the mark moves
    ///         and the mark clock is stamped.
    function test_mark_recentReference_foldsPrintIn() public {
        harness.setPriceReferenceTs(T0 - 1);

        _print();

        assertEq(harness.markPremiumOf(200 * SCALE), int256(SCALE / 160), "the print enters at the cap over the floor");
        assertEq(harness.markUpdateTs(), T0, "mark clock stamped");
    }

    /// @notice One second past the staleness limit the reference is the stale fallback, and the
    ///         print is dropped whole: neither the premium nor its anchor moves. Admitted, the
    ///         print would measure its premium against that old reference, and the anchor would
    ///         date the result as freshly traded, so the next store would charge the difference
    ///         between that reference and the live index as funding.
    function test_mark_agedReference_dropsPrintAndStamp() public {
        harness.setPriceReferenceTs(T0 - STALENESS - 1);

        _print();

        assertEq(harness.markPremiumOf(200 * SCALE), 0, "print rejected");
        assertEq(harness.markUpdateTs(), 0, "mark clock not stamped");
    }

    /// @notice The gate admits a reference exactly MAX_PRICE_STALENESS old, the oldest tick the
    ///         fresh path itself accepts, so every fresh-path fill passes it.
    function test_mark_referenceAtStalenessLimit_stillCounts() public {
        harness.setPriceReferenceTs(T0 - STALENESS);

        _print();

        assertEq(harness.markUpdateTs(), T0, "a reference exactly at the staleness limit still counts");
    }

    /// @notice A reference stamped ahead of the block, as a Pyth publish time can be, is not an
    ///         old one: the gate admits it rather than reverting on the age arithmetic.
    function test_mark_futureDatedReference_counts() public {
        harness.setPriceReferenceTs(T0 + 1);

        _print();

        assertEq(harness.markUpdateTs(), T0, "a future-dated reference is admissible");
    }

    /// @notice The reference ages on its own clock, not the caller's: warping forward past the
    ///         staleness limit closes the gate on a reference that was admissible a moment
    ///         earlier, and nothing the caller passes reopens it.
    function test_mark_referenceAgesOut() public {
        harness.setPriceReferenceTs(T0);

        _print();
        assertEq(harness.markUpdateTs(), T0, "admissible while the reference is current");

        vm.warp(T0 + STALENESS + 1);
        _print();
        assertEq(harness.markUpdateTs(), T0, "same caller, same print, aged-out reference");
    }
}

// ==================== ApplyFill funding settlement ====================

/// @notice Harness with real storage exposing MatchingEngineLib._applyFillWithState, so the
///         funding-settlement-at-close behavior can be unit-tested with a controlled funding index.
contract ApplyFillHarness {
    mapping(uint256 => BazaarTypes.Order) internal orders;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;
    BazaarTypes.OrderBook internal book;

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
        b.size = uint128(size);
        b.entryValue = uint128(entryValue);
        b.collateral = uint128(collateral);
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
        BazaarTypes.ArrivalContext memory ctx;
        ctx.cachedPrice = currentPrice;
        ctx.cachedFundingIdx = currentFundingIndex;
        ctx.marginReqs = reqs;
        return MatchingEngineLib._applyFillMaker(
            orders, positionBuckets, book, user, state, orderIsLong, fillSize, executionPrice, 0, ctx
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
///         entry index untouched. Settling price PnL alone here would silently drop funding on
///         every match-driven close.
contract ApplyFillFundingTest is Test {
    uint256 internal constant SCALE = 1e18;
    address internal alice = address(0xA11CE);

    ApplyFillHarness internal h;

    function setUp() public {
        h = new ApplyFillHarness();
    }

    function test_fullClose_longPaysFunding() public {
        // Long 1 @ $100 entry, $20 collateral. Index delta +2 → long owes $2.
        // Close 1 @ $110: collateral = 20 + 10 (price) − 2 (funding) = 28. (Price alone: 30.)
        h.setBucket(alice, true, 1 * SCALE, 100 * SCALE, 20 * SCALE, 0);
        h.applyFill(alice, false, 1 * SCALE, 110 * SCALE, 110 * SCALE, int256(2 * SCALE));

        assertEq(h.collateralOf(alice), 28 * SCALE, "price PnL + funding settled together");
        assertEq(h.sizeOf(alice), 0, "position fully closed");
        assertEq(h.entryFundingIndexOf(alice), 0, "funding index cleared when flat");
    }

    function test_fullClose_shortReceivesFunding() public {
        // Short 1 @ $100 entry, $20 collateral. Index delta +2 → short is owed $2.
        // Close 1 @ $100 (price PnL 0): collateral = 22. (Price alone: 20 — the credit vanishes.)
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
