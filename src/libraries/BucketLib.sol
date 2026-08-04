// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";

/// @title BucketLib
/// @notice Internal library for bucket state calculation and update.
///         Inlined at compile time — shared between BazaarPair and MatchingEngineLib.
library BucketLib {
    /// @notice Calculates bucket state from a memory bucket snapshot and current market data.
    /// @dev Pure function — does not access storage. Caller passes all needed inputs.
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
    ) internal view returns (BazaarTypes.BucketState memory result) {
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
        uint256 effectiveMmrBp =
            effectiveMmr(bucket.mmrUpdateTs, bucket.entryMmrBp, marginReqs.laggedMmrBp, marginReqs.mmrBp);
        result.minRequiredCollateral = Math.mulDiv(effectiveMmrBp, result.currentNotional, BazaarTypes.BP_SCALE);

        // Solvency
        result.isSolvent = result.availableEquity >= result.minRequiredCollateral && signedEquity > 0;

        return result;
    }

    /// @notice Resolves the maintenance-margin rate a position is judged against, implementing
    ///         the 24h-lagged grace: a rising MMR cannot liquidate an existing position for
    ///         MMR_GRACE_PERIOD, while a falling MMR helps immediately.
    /// @dev `view` (not pure) because it reads block.timestamp. Shared by calculateState and the
    ///      partial-close margin check in MatchingEngineLib so the two stay consistent.
    /// @param mmrUpdateTs  Timestamp the position's entry MMR was last set (0 when flat).
    /// @param entryMmrBp   The position's entry MMR.
    /// @param laggedMmrBp  Newest sample >= MMR_GRACE_PERIOD old for this batch (0 if none).
    /// @param currentMmrBp The pair's current MMR.
    /// @return The effective maintenance MMR in basis points.
    function effectiveMmr(uint256 mmrUpdateTs, uint256 entryMmrBp, uint256 laggedMmrBp, uint256 currentMmrBp)
        internal
        view
        returns (uint256)
    {
        // Reference MMR: a position older than the grace period is judged against the lagged
        // sample; a newer position — or an older one with no sample that old yet — uses its
        // entry MMR. A 0 reference (entry MMR never set) falls back to the current rate.
        uint256 refMmr;
        if (mmrUpdateTs != 0 && block.timestamp - mmrUpdateTs >= BazaarTypes.MMR_GRACE_PERIOD && laggedMmrBp != 0) {
            refMmr = laggedMmrBp;
        } else {
            refMmr = entryMmrBp;
        }
        // Lower of reference vs current.
        return (refMmr != 0 && refMmr < currentMmrBp) ? refMmr : currentMmrBp;
    }

    /// @notice Updates a position bucket's core fields in storage from a BucketState.
    /// @param bucket Storage reference to the bucket
    /// @param newState The calculated bucket state to apply
    function updateFromState(BazaarTypes.PositionBucket storage bucket, BazaarTypes.BucketState memory newState)
        internal
    {
        bucket.size = newState.adjustedSize;
        bucket.entryValue = newState.entryValue;
        bucket.collateral = newState.effectiveCollateral;
        bucket.entryFundingIndex = newState.adjustedEntryFundingIndex;
        bucket.entryMmrBp = newState.entryMmrBp;
        bucket.mmrUpdateTs = newState.mmrUpdateTs;
    }

    /// @notice Emits the PositionBucketUpdated event for off-chain indexers.
    /// @dev Emit-only: no bucket-state checkpoint is written on-chain, because omission challenges
    ///      do not require solvency proofs (see BazaarSequencer.challengeOmission).
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
