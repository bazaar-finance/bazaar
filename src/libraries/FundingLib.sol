// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";

/// @title FundingLib
/// @notice Mark-price EMA and funding-index accrual math for BazaarPair.
/// @dev Deployed as an EXTERNAL library (DELEGATECALL, like MatchingEngineLib et al.) so its
///      bytecode does not count toward BazaarPair's EIP-170 limit. The pair's funding state
///      lives in scalar storage vars, so these functions take values and return the updated
///      values for the pair's thin wrappers to write back (each has exactly one call site).
library FundingLib {
    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 internal constant BP_SCALE = BazaarTypes.BP_SCALE;

    uint256 internal constant FUNDING_INTERVAL = 1 hours;
    uint256 internal constant MAX_FUNDING_RATE = BAZAAR_SCALE / 200; // 0.5% per FUNDING_INTERVAL (hour)
    uint256 internal constant MAX_FUNDING_AGE = 30 minutes;
    uint256 internal constant MAX_FUNDING_GAP = 12 hours;
    uint256 internal constant MARK_DECAY_PERIOD = 1 hours;
    uint256 internal constant MAX_MARK_DEVIATION_BP = 500; // 5%

    uint256 internal constant VOLUME_HALFLIFE = 60 minutes;
    uint256 internal constant MAX_ALPHA = 1000; // 10% of BP_SCALE
    uint256 internal constant BASE_ALPHA = 100;

    /// @notice The pair's mark-price EMA state (scalar storage vars in BazaarPair).
    struct MarkState {
        uint256 markPrice;
        uint256 lastMarkUpdateTs;
        uint256 rollingVolume;
    }

    /// @notice Updates mark price.
    /// @dev `alpha` is the weight given to the new exec price in the EMA blend. It scales with the
    ///      fill's share of recent volume (so big fills move the mark more than tiny ones), capped
    ///      at MAX_ALPHA = 1000 (10% of BP_SCALE): even a fill that dominates recent volume can't
    ///      move the mark more than 10% toward its print — the protocol's resistance to single-
    ///      batch manipulation. There is no lower floor, so a dust fill against deep volume gets
    ///      ~0 weight and the mark just keeps decaying toward index; a tiny wash trade cannot
    ///      nudge the mark. The exec price is additionally clamped to ±MAX_MARK_DEVIATION_BP
    ///      of the index before it enters the EMA, so an implausible print can't move the mark and
    ///      the steady-state mark stays within that band of index.
    ///      Note: the zero-fill path intentionally leaves lastMarkUpdateTs unchanged.
    function updateMarkPrice(MarkState memory s, uint256 execPrice, uint256 fillNotional, uint256 indexPrice)
        external
        view
        returns (MarkState memory)
    {
        uint256 elapsed = block.timestamp - s.lastMarkUpdateTs;

        uint256 decayedVolume;
        if (elapsed >= VOLUME_HALFLIFE || s.rollingVolume == 0) {
            decayedVolume = 0;
        } else {
            decayedVolume = s.rollingVolume * (VOLUME_HALFLIFE - elapsed) / VOLUME_HALFLIFE;
        }

        uint256 decayedMark;
        if (s.markPrice == 0 || s.lastMarkUpdateTs == 0) {
            decayedMark = indexPrice;
        } else if (elapsed >= MARK_DECAY_PERIOD) {
            decayedMark = indexPrice;
        } else {
            decayedMark = (s.markPrice * (MARK_DECAY_PERIOD - elapsed) + indexPrice * elapsed) / MARK_DECAY_PERIOD;
        }

        uint256 newVolume = decayedVolume + fillNotional;
        if (newVolume == 0 || fillNotional == 0) {
            s.markPrice = decayedMark;
            s.rollingVolume = decayedVolume;
            return s;
        }

        uint256 alpha = (fillNotional * BASE_ALPHA * 100) / newVolume;
        alpha = Math.min(alpha, MAX_ALPHA);

        // Clamp the print to a band around the index before it enters the EMA, so a self-crossed
        // wash trade at an arbitrary price (a fresh-oracle Pass C cross skips the matching band)
        // can't inject that price into the mark.
        uint256 bandHigh = indexPrice * (BP_SCALE + MAX_MARK_DEVIATION_BP) / BP_SCALE;
        uint256 bandLow = indexPrice * (BP_SCALE - MAX_MARK_DEVIATION_BP) / BP_SCALE;
        uint256 boundedExec = Math.min(Math.max(execPrice, bandLow), bandHigh);

        s.markPrice = (boundedExec * alpha + decayedMark * (BP_SCALE - alpha)) / BP_SCALE;
        s.rollingVolume = newVolume;
        s.lastMarkUpdateTs = block.timestamp;
        return s;
    }

    /// @notice Updates funding index
    /// @return newFundingIndex The updated cumulative funding index (price units)
    /// @return newLastFundingUpdateTs The updated accrual timestamp
    function updateFundingIndex(
        uint256 markPrice,
        uint256 lastMarkUpdateTs,
        int256 currentFundingIndex,
        uint256 lastFundingUpdateTs,
        uint256 indexPrice,
        uint256 oracleUpdateTs
    ) external view returns (int256 newFundingIndex, uint256 newLastFundingUpdateTs) {
        uint256 currentTs = block.timestamp;
        uint256 lastUpdate = lastFundingUpdateTs;

        if (currentTs <= lastUpdate) return (currentFundingIndex, lastFundingUpdateTs);

        uint256 validStart = lastUpdate;
        if (oracleUpdateTs > lastUpdate + MAX_FUNDING_GAP) {
            validStart = oracleUpdateTs;
        } else if (oracleUpdateTs > lastUpdate + MAX_FUNDING_AGE) {
            validStart = oracleUpdateTs > MAX_FUNDING_AGE ? oracleUpdateTs - MAX_FUNDING_AGE : 0;
        }

        if (validStart >= currentTs) {
            return (currentFundingIndex, currentTs);
        }

        uint256 elapsed = currentTs - validStart;
        if (elapsed == 0) {
            return (currentFundingIndex, currentTs);
        }

        // Get decayed mark price
        uint256 currentMark;
        if (markPrice == 0 || lastMarkUpdateTs == 0) {
            currentMark = indexPrice;
        } else {
            uint256 markElapsed = currentTs - lastMarkUpdateTs;
            if (markElapsed >= MARK_DECAY_PERIOD) {
                currentMark = indexPrice;
            } else {
                uint256 remaining = MARK_DECAY_PERIOD - markElapsed;
                currentMark = (markPrice * remaining + indexPrice * markElapsed) / MARK_DECAY_PERIOD;
            }
        }

        if (indexPrice == 0 || currentMark == 0) {
            return (currentFundingIndex, currentTs);
        }

        int256 premium = (int256(currentMark) - int256(indexPrice)) * int256(BAZAAR_SCALE) / int256(indexPrice);
        int256 dampenedPremium = premium / 8;

        int256 fundingRate;
        if (dampenedPremium > int256(MAX_FUNDING_RATE)) {
            fundingRate = int256(MAX_FUNDING_RATE);
        } else if (dampenedPremium < -int256(MAX_FUNDING_RATE)) {
            fundingRate = -int256(MAX_FUNDING_RATE);
        } else {
            fundingRate = dampenedPremium;
        }

        // Accumulate in price units (rate × indexPrice): BucketLib computes funding PnL as
        // Δindex × size / 1e18, so the index must carry the price factor for PnL to be on notional.
        int256 fundingDelta =
            fundingRate * int256(indexPrice) * int256(elapsed) / int256(BAZAAR_SCALE) / int256(FUNDING_INTERVAL);
        return (currentFundingIndex + fundingDelta, currentTs);
    }
}
