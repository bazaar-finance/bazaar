// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";

/// @title BucketLib
/// @notice Internal library for bucket state calculation and update.
///         Inlined at compile time — shared between BazaarPair and MatchingEngineLib.
library BucketLib {
    /// @notice Calculates bucket state from a memory bucket snapshot and current market data.
    /// @dev Pure — reads neither storage nor the environment. The caller passes all needed inputs,
    ///      including the batch's lagged MMR sample, so the same bucket image evaluates identically
    ///      whether it is read from storage or carried through a matching walk in memory.
    /// @param bucket The position bucket (memory copy)
    /// @param currentPrice The current spot price (BAZAAR precision)
    /// @param currentFundingIndex The current global funding index
    /// @param marginReqs The current margin requirements
    /// @return result The calculated bucket state
    function calculateState(
        BazaarTypes.PositionBucket memory bucket,
        uint256 currentPrice,
        int256 currentFundingIndex,
        BazaarTypes.MarginRequirements memory marginReqs
    ) internal pure returns (BazaarTypes.BucketState memory result) {
        result.effectiveCollateral = bucket.collateral;
        result.entryMmrBp = bucket.entryMmrBp;
        result.mmrUpdateTs = bucket.mmrUpdateTs;

        uint256 size = bucket.size;
        uint256 entryValue = bucket.entryValue;
        bool isLong = bucket.isLong;
        int256 entryFundingIdx = bucket.entryFundingIndex;

        if (size == 0) {
            result.availableEquity = result.effectiveCollateral;
            result.isSolvent = true;
            return result;
        }

        // Adjusted size (no split adjustment in current design)
        result.adjustedSize = size;

        // Current notional
        result.currentNotional = Math.mulDiv(result.adjustedSize, currentPrice, BazaarTypes.BAZAAR_SCALE);

        // Unrealized PnL
        if (isLong) {
            result.unrealizedPnl = int256(result.currentNotional) - int256(entryValue);
        } else {
            result.unrealizedPnl = int256(entryValue) - int256(result.currentNotional);
        }
        result.entryValue = entryValue;

        // Funding PnL
        result.adjustedEntryFundingIndex = entryFundingIdx;
        int256 fundingDelta = currentFundingIndex - entryFundingIdx;
        int256 rawFundingPnl =
            BazaarMathLib.signedMulDiv(fundingDelta, int256(result.adjustedSize), int256(BazaarTypes.BAZAAR_SCALE));

        if (isLong) {
            result.fundingPnl = -rawFundingPnl;
        } else {
            result.fundingPnl = rawFundingPnl;
        }

        // Total PnL
        result.totalPnl = result.unrealizedPnl + result.fundingPnl;

        // Available equity
        int256 signedEquity = int256(result.effectiveCollateral) + result.totalPnl;
        result.availableEquity = signedEquity > 0 ? uint256(signedEquity) : 0;

        // Min required collateral (using the 24h-lagged effective MMR)
        uint256 effectiveMmrBp = effectiveMmr(
            bucket.mmrUpdateTs, bucket.entryMmrBp, marginReqs.laggedMmrBp, marginReqs.laggedMmrTs, marginReqs.mmrBp
        );
        result.minRequiredCollateral = Math.mulDiv(effectiveMmrBp, result.currentNotional, BazaarTypes.BP_SCALE);

        // Solvency
        result.isSolvent = result.availableEquity >= result.minRequiredCollateral && signedEquity > 0;

        return result;
    }

    /// @notice Resolves the maintenance-margin rate a position is judged against, implementing
    ///         the 24h-lagged grace: a rising MMR cannot liquidate an existing position for
    ///         MMR_GRACE_PERIOD, while a falling MMR helps immediately.
    /// @dev The lagged sample is adopted only when it was recorded at or after the position's own
    ///      mmrUpdateTs. That single comparison also subsumes the age gate the grace needs:
    ///      laggedMmr only ever returns a sample stamped a full MMR_GRACE_PERIOD before the mark
    ///      being valued against, and that mark is never dated after the current block, so
    ///      laggedMmrTs >= mmrUpdateTs already implies the position is at least MMR_GRACE_PERIOD
    ///      old, and a younger position necessarily fails it and keeps its entry MMR.
    ///
    ///      The comparison is load-bearing, not a refinement. The sample grid is
    ///      MMR_SAMPLE_INTERVAL-spaced while the rate moves on IMR_UPDATE_COOLDOWN, so a rate
    ///      increase landing between two grid points is recorded under the *later* point's
    ///      timestamp. A position opened in that shadow carries the raised entryMmrBp, and at the
    ///      moment it crosses the grace period its cutoff equals its own mmrUpdateTs exactly —
    ///      selecting the last sample taken before it existed. Without the check that pre-open
    ///      rate would replace the entry rate, handing the position a requirement it never opened
    ///      under until the cutoff walks past its first post-open sample.
    ///
    ///      Shared by calculateState and the partial-close margin check in MatchingEngineLib so
    ///      the two stay consistent.
    /// @param mmrUpdateTs  Timestamp the position's entry MMR was last set (0 when flat).
    /// @param entryMmrBp   The position's entry MMR, i.e. the rate as of mmrUpdateTs.
    /// @param laggedMmrBp  Newest sample a full MMR_GRACE_PERIOD before this batch's mark (0 if none).
    /// @param laggedMmrTs  Timestamp that sample was recorded at (0 when there is none).
    /// @param currentMmrBp The pair's current MMR.
    /// @return The effective maintenance MMR in basis points.
    function effectiveMmr(
        uint256 mmrUpdateTs,
        uint256 entryMmrBp,
        uint256 laggedMmrBp,
        uint256 laggedMmrTs,
        uint256 currentMmrBp
    ) internal pure returns (uint256) {
        // Reference MMR: the lagged sample when it describes a rate this position actually opened
        // under, otherwise the position's own entry MMR. The mmrUpdateTs != 0 guard keeps a bucket
        // that was never stamped (flat, or reached before its first fill) out of the lagged branch,
        // where a 0 stamp would compare true against any sample; it falls to entryMmrBp == 0 and
        // then to the current rate below.
        uint256 refMmr = (mmrUpdateTs != 0 && laggedMmrTs >= mmrUpdateTs) ? laggedMmrBp : entryMmrBp;
        // Lower of reference vs current.
        return (refMmr != 0 && refMmr < currentMmrBp) ? refMmr : currentMmrBp;
    }

    /// @notice Updates a position bucket's core fields in storage from a BucketState.
    /// @param bucket Storage reference to the bucket
    /// @param newState The calculated bucket state to apply
    function updateFromState(BazaarTypes.PositionBucket storage bucket, BazaarTypes.BucketState memory newState)
        internal
    {
        bucket.size = SafeCast.toUint128(newState.adjustedSize);
        bucket.entryValue = SafeCast.toUint128(newState.entryValue);
        bucket.collateral = SafeCast.toUint128(newState.effectiveCollateral);
        bucket.entryFundingIndex = newState.adjustedEntryFundingIndex;
        bucket.entryMmrBp = SafeCast.toUint32(newState.entryMmrBp);
        bucket.mmrUpdateTs = SafeCast.toUint64(newState.mmrUpdateTs);
    }

    /// @notice Memory twin of updateFromState, for a bucket image carried across a matching
    ///         walk (the taker's). Field mapping must stay identical to updateFromState: the
    ///         image is re-read by calculateState between fills exactly as a stored bucket
    ///         would be, and is flushed to storage once at walk end.
    /// @param bucket Memory image of the bucket
    /// @param newState The calculated bucket state to apply
    function updateMemoryFromState(BazaarTypes.PositionBucket memory bucket, BazaarTypes.BucketState memory newState)
        internal
        pure
    {
        bucket.size = SafeCast.toUint128(newState.adjustedSize);
        bucket.entryValue = SafeCast.toUint128(newState.entryValue);
        bucket.collateral = SafeCast.toUint128(newState.effectiveCollateral);
        bucket.entryFundingIndex = newState.adjustedEntryFundingIndex;
        bucket.entryMmrBp = SafeCast.toUint32(newState.entryMmrBp);
        bucket.mmrUpdateTs = SafeCast.toUint64(newState.mmrUpdateTs);
    }

    /// @notice Flush a walk-carried bucket image back to storage — the write half of the
    ///         memory-taker pattern. Writes only the fields the fill path owns (the same set
    ///         updateFromState writes, plus the position side and the TP/SL slot pointers,
    ///         which the walk maintains in the image).
    function storeFromMemory(BazaarTypes.PositionBucket storage bucket, BazaarTypes.PositionBucket memory image)
        internal
    {
        bucket.isLong = image.isLong;
        bucket.size = image.size;
        bucket.entryValue = image.entryValue;
        bucket.collateral = image.collateral;
        bucket.entryFundingIndex = image.entryFundingIndex;
        bucket.takeProfitOrderId = image.takeProfitOrderId;
        bucket.stopLossOrderId = image.stopLossOrderId;
        bucket.entryMmrBp = image.entryMmrBp;
        bucket.mmrUpdateTs = image.mmrUpdateTs;
    }

    /// @notice Emits the PositionBucketUpdated event for off-chain indexers.
    /// @dev Emit-only: no bucket-state checkpoint is written on-chain. Margin correctness needs
    ///      none — every fill re-derives solvency from the live bucket via _checkMargin against
    ///      the transaction's oracle price, so a historical snapshot would have no reader.
    function emitBucketUpdate(
        address user,
        BazaarTypes.PositionBucket storage bucket,
        int256 currentFundingIndex,
        BazaarTypes.MarginRequirements memory marginReqs,
        bytes32 pairId
    ) internal {
        emit BazaarTypes.PositionBucketUpdated(
            pairId,
            user,
            bucket.isLong,
            bucket.size,
            bucket.entryValue,
            bucket.collateral,
            bucket.entryFundingIndex,
            currentFundingIndex,
            marginReqs.imrBp,
            marginReqs.mmrBp,
            bucket.entryMmrBp
        );
    }
}
