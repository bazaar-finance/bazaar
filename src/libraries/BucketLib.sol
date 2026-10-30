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

        // Min required collateral, at the lower of the current and the 24h-lagged MMR
        result.minRequiredCollateral =
            Math.mulDiv(effectiveMmrBp(marginReqs), result.currentNotional, BazaarTypes.BP_SCALE);

        // Solvency
        result.isSolvent = result.availableEquity >= result.minRequiredCollateral && signedEquity > 0;

        return result;
    }

    /// @notice The maintenance rate every position is judged against: the lower of the current
    ///         rate and the lagged minimum over the grace period. A rising MMR therefore cannot
    ///         liquidate anyone until it has held for MMR_GRACE_PERIOD, while a falling one helps
    ///         at once.
    /// @dev The current rate follows live open interest, which two accounts trading against
    ///      each other can inflate for as long as one recompute stands. The lagged minimum holds
    ///      a rise back until every rate recorded across the grace period carries it, so a spike
    ///      that short reaches no threshold, and it takes in a fall the moment the fall is
    ///      recorded. The rule is the same for every position however recently it opened: a
    ///      threshold stamped from the rate at the position's own fill would carry a spike that
    ///      coincided with that fill for the whole grace period, and a second spike inside it
    ///      could then seize a position solvent at every other rate in force. A position opened
    ///      during a genuine rise still pays the current IMR to open; only its maintenance
    ///      threshold waits for the rise to hold.
    ///
    ///      The unload walk, the ADL gate and the ADL batch sizing derive their band edge from
    ///      the same rate. A wider band moves its edge toward the estates' bankruptcy price, where
    ///      fills are immediate, so a spike in the band's rate would let the seizing transaction
    ///      buy inventory the unload floor was holding for competing bids.
    ///
    ///      Shared by calculateState, the partial-close margin check in MatchingEngineLib and
    ///      every band reader, so every reader applies the same rule. liquidate's requirements
    ///      carry the current rate its own price gives, capped by the stored one inside the
    ///      cooldown (BazaarPair._liquidationMarginReqs); that only ever makes it the more
    ///      lenient reader, since the lagged rate sits at or below the stored rate. With nothing
    ///      recorded yet (BazaarPair._laggedMmr returns 0) the current rate stands.
    /// @param mr The batch's margin requirements, lagged field filled by BazaarPair._marginReqsWithLag.
    /// @return The maintenance rate in basis points.
    function effectiveMmrBp(BazaarTypes.MarginRequirements memory mr) internal pure returns (uint256) {
        return (mr.laggedMmrBp != 0 && mr.laggedMmrBp < mr.mmrBp) ? mr.laggedMmrBp : mr.mmrBp;
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
            marginReqs.mmrBp
        );
    }
}
