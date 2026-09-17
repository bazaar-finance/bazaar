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
    // Hourly rate ceilings, split on the pair's trading calendar. A session-bound pair accrues only
    // while its oracle is fresh — roughly a fifth of the week — so matching a continuously traded
    // pair's corrective force per calendar week takes a higher ceiling per accruing hour.
    uint256 internal constant MAX_FUNDING_RATE_SESSION = BAZAAR_SCALE / 200; // 0.5% per FUNDING_INTERVAL
    uint256 internal constant MAX_FUNDING_RATE_CONTINUOUS = BAZAAR_SCALE / 1000; // 0.1% per FUNDING_INTERVAL
    uint256 internal constant MAX_FUNDING_AGE = 30 minutes;
    uint256 internal constant MAX_FUNDING_GAP = 12 hours;
    uint256 internal constant MARK_DECAY_PERIOD = 1 hours;
    // One band for every pair, so the mark carries the same meaning wherever it is read.
    uint256 internal constant MAX_MARK_DEVIATION_BP = 400;
    // Accruing hours of funding needed to pay off the mark-index gap: the premium is divided by
    // this before the rate clamp, so a smaller value makes funding a stronger convergence force.
    // Derived from the band and the pair's ceiling rather than chosen, so a mark exactly at the
    // band edge yields exactly that ceiling and the clamp is never reached from strictly inside the
    // band. Declaring band, rate and dampener independently is what leaves a stretch of the band
    // over which funding is already saturated and stops responding to further mark movement — the
    // region a manipulated mark aims for. Holding the band common across pair types is what forces
    // the two dampeners apart; they still land at comparable calendar horizons, since 8 accruing
    // hours is a little over a day on a session pair and 40 is a little under two on a continuous
    // one.
    uint256 internal constant FUNDING_DAMPENER_SESSION =
        MAX_MARK_DEVIATION_BP * BAZAAR_SCALE / (MAX_FUNDING_RATE_SESSION * BP_SCALE);
    uint256 internal constant FUNDING_DAMPENER_CONTINUOUS =
        MAX_MARK_DEVIATION_BP * BAZAAR_SCALE / (MAX_FUNDING_RATE_CONTINUOUS * BP_SCALE);

    uint256 internal constant VOLUME_HALFLIFE = 60 minutes;
    // Floor on the alpha denominator, as a share of open-interest notional. Denominating it in
    // open interest is what makes it scale-free: funding transfers a percentage of open interest,
    // so pricing the cost of moving the mark in the same units holds the attacker's cost-to-payoff
    // ratio fixed on pairs of any size, and a pair with no open interest has nothing to transfer.
    uint256 internal constant VOLUME_FLOOR_BP = 200; // 2% of per-side open-interest notional
    // Ceiling on a single update's weight. Not the primary manipulation bound — a cost-minimising
    // attacker prefers many small prints, whose displacement per dollar is strictly higher — but it
    // rejects one anomalous print (a thin-book sweep, a fat finger) at the top end the way the
    // absence of an alpha floor rejects dust at the bottom, and it forces a mark campaign into many
    // sequential off-market quotes, each of which must survive a block of adverse selection.
    uint256 internal constant MAX_ALPHA = 1000; // 10% of BP_SCALE

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
    ///      update manipulation. That share is measured against a denominator floored at
    ///      VOLUME_FLOOR_BP of open-interest notional. The floor is load-bearing: `rollingVolume`
    ///      is fed only by prior calls to this function, so without it a pair with no other traders
    ///      lets one account supply the entire denominator and every dust print reads as
    ///      volume-dominant. Alpha itself has no lower floor, so a fill that is small against the
    ///      denominator gets ~0 weight and the mark just keeps decaying toward index. The exec
    ///      price is additionally clamped to ±MAX_MARK_DEVIATION_BP of the index before it enters
    ///      the EMA, so an implausible print can't move the mark and the steady-state mark stays
    ///      within that band of index.
    ///      Note: the zero-fill path intentionally leaves lastMarkUpdateTs unchanged.
    /// @param s Mark state to advance — mark price, its stamp, and rolling volume.
    /// @param fillNotional Σ(price × size) over this transaction's fills: both the VWAP numerator
    ///        and the traded notional alpha is weighed from. Zero on the decay-only path.
    /// @param fillSize Σ size over the same fills — the VWAP denominator.
    /// @param indexPrice Oracle price the deviation band and the decay target are taken from.
    /// @param oiSize Open-interest size the weighting floor is scaled against.
    /// @return The advanced mark state, for the caller to write back.
    function updateMarkPrice(
        MarkState memory s,
        uint256 fillNotional,
        uint256 fillSize,
        uint256 indexPrice,
        uint256 oiSize
    ) external view returns (MarkState memory) {
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

        // fillNotional IS Σ(price × size), so it is the exact VWAP numerator as well as the exact
        // traded notional — the walk's average price needs no re-derivation. A non-zero notional
        // implies a non-zero size, so the division is safe past the early-out above.
        uint256 execPrice = Math.mulDiv(fillNotional, BAZAAR_SCALE, fillSize);

        // Only the weighting denominator is floored — `rollingVolume` keeps recording true traded
        // notional, so the floor cannot inflate the pair's own volume history.
        uint256 floorVolume = Math.mulDiv(oiSize, indexPrice, BAZAAR_SCALE) * VOLUME_FLOOR_BP / BP_SCALE;
        uint256 alphaDenom = Math.max(decayedVolume, floorVolume) + fillNotional;
        uint256 alpha = Math.min(fillNotional * BP_SCALE / alphaDenom, MAX_ALPHA);

        // Clamp the print to a band around the index before it enters the EMA, so a wash trade
        // between two resting limits at an arbitrary price (fresh-oracle limit fills carry no
        // price band of their own) can't inject that price into the mark.
        uint256 bandHigh = indexPrice * (BP_SCALE + MAX_MARK_DEVIATION_BP) / BP_SCALE;
        uint256 bandLow = indexPrice * (BP_SCALE - MAX_MARK_DEVIATION_BP) / BP_SCALE;
        uint256 boundedExec = Math.min(Math.max(execPrice, bandLow), bandHigh);

        s.markPrice = (boundedExec * alpha + decayedMark * (BP_SCALE - alpha)) / BP_SCALE;
        s.rollingVolume = newVolume;
        s.lastMarkUpdateTs = block.timestamp;
        return s;
    }

    /// @notice Updates funding index
    /// @param isContinuouslyTraded Selects the pair's rate ceiling and its paired dampener. Both
    ///        pairings put the ceiling exactly at MAX_MARK_DEVIATION_BP of premium, so the choice
    ///        changes how hard funding pulls, never how far the mark may sit from the index.
    /// @return newFundingIndex The updated cumulative funding index (price units)
    /// @return newLastFundingUpdateTs The updated accrual timestamp
    function updateFundingIndex(
        uint256 markPrice,
        uint256 lastMarkUpdateTs,
        int256 currentFundingIndex,
        uint256 lastFundingUpdateTs,
        uint256 indexPrice,
        uint256 oracleUpdateTs,
        bool isContinuouslyTraded
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

        // Ceiling and dampener are one pairing, never mixed: each dampener is derived from its own
        // ceiling against the shared band, so taking one from each pair type would put the clamp
        // back inside the band.
        (uint256 maxRate, uint256 dampener) = isContinuouslyTraded
            ? (MAX_FUNDING_RATE_CONTINUOUS, FUNDING_DAMPENER_CONTINUOUS)
            : (MAX_FUNDING_RATE_SESSION, FUNDING_DAMPENER_SESSION);

        int256 premium = (int256(currentMark) - int256(indexPrice)) * int256(BAZAAR_SCALE) / int256(indexPrice);
        int256 dampenedPremium = premium / int256(dampener);

        int256 fundingRate;
        if (dampenedPremium > int256(maxRate)) {
            fundingRate = int256(maxRate);
        } else if (dampenedPremium < -int256(maxRate)) {
            fundingRate = -int256(maxRate);
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
