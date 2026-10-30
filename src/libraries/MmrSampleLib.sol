// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BazaarTypes} from "./BazaarTypes.sol";

/// @title MmrSampleLib
/// @notice Manages the per-pair ring buffer of hourly samples: the MMR that backs the 24h-lagged
///         liquidation threshold, and the open interest that backs the trailing figure the fund's
///         reserve is sized on. Internal — operates directly on the pair's MmrSampleBuffer
///         storage. The lagged-MMR lookup is inlined into BazaarPair; recording and the
///         open-interest lookup run inside RiskParamsLib.calculateIMRandMMR.
library MmrSampleLib {
    /// @notice Folds `currentMmrBp` and `currentOiSize` into the running minimums of the open
    ///         interval and, once MMR_SAMPLE_INTERVAL has elapsed since that interval opened,
    ///         records the minimums as a sample stamped with the instant the interval opened,
    ///         then opens the next interval.
    /// @dev A sample is the lowest rate in force, and the lowest open interest held, at any point
    ///      during its interval, not the readings at the instant the interval closed. Every
    ///      refresh passes what it found in force, so a rise that holds for the whole hour is
    ///      sampled while one that lasts a minute never is; open interest counts matched positions
    ///      of one owner, so a pair of accounts can inflate it, and the rate that follows it, for
    ///      as long as it takes one recompute to land. The sample carries the instant its interval
    ///      opened because that is the earliest its rate can have been in force: laggedMmr closes
    ///      its window on the first interval stamped at or before the cutoff, which with this
    ///      stamp is the interval in force at the cutoff. Stamped at its close, it would be the
    ///      interval before that one, which ended by the cutoff, so every rise would wait up to an
    ///      interval more before it binds. The first ever call only opens the first interval
    ///      (lastSampleTs == 0); there is nothing to close yet. Sampling rides
    ///      BazaarPair._refreshMarginCurve, which every matching entry point, liquidation, ADL,
    ///      and refreshPrice call; quiet periods simply leave gaps, which both lookups tolerate.
    /// @param buf           The pair's sample ring buffer (storage).
    /// @param currentMmrBp  The pair's current maintenance-margin rate.
    /// @param currentOiSize The pair's current per-side open interest (RiskParamsLib.openInterestSize).
    /// @return closed Whether this call closed an interval and wrote its sample.
    /// @return oiLowered Whether this call lowered the open interval's open-interest minimum
    ///         without closing it. Together the two say when the trailing minimum can have moved.
    function record(BazaarTypes.MmrSampleBuffer storage buf, uint256 currentMmrBp, uint256 currentOiSize)
        internal
        returns (bool closed, bool oiLowered)
    {
        // Saturate rather than truncate: a size past the narrow field would otherwise be recorded
        // as a small one.
        if (currentOiSize > type(uint128).max) currentOiSize = type(uint128).max;
        uint256 heldBp = buf.intervalMinBp;
        bool lowerBp = heldBp == 0 || currentMmrBp < heldBp;
        if (lowerBp) heldBp = currentMmrBp;
        uint256 opened = buf.lastSampleTs;
        if (opened != 0) {
            uint256 heldOi = buf.intervalMinOi;
            bool lowerOi = currentOiSize < heldOi;
            if (lowerOi) heldOi = currentOiSize;
            if (block.timestamp < opened + BazaarTypes.MMR_SAMPLE_INTERVAL) {
                if (lowerBp) buf.intervalMinBp = uint32(heldBp);
                if (lowerOi) buf.intervalMinOi = uint128(heldOi);
                return (false, lowerOi);
            }
            // A basis-point rate bounded by the margin curve's clamps sits far inside the narrow field.
            buf.samples[buf.head] =
                BazaarTypes.MmrSample({ts: uint64(opened), mmrBp: uint32(heldBp), oiSize: uint128(heldOi)});
            buf.head = uint8((buf.head + 1) % BazaarTypes.MMR_SAMPLE_COUNT);
            if (buf.count < BazaarTypes.MMR_SAMPLE_COUNT) {
                buf.count += 1;
            }
            closed = true;
        }
        buf.lastSampleTs = uint64(block.timestamp);
        buf.intervalMinBp = uint32(currentMmrBp);
        buf.intervalMinOi = uint128(currentOiSize);
    }

    /// @notice The lowest open interest seen from MMR_GRACE_PERIOD before the present up to now:
    ///         the minimum over every sample from the interval in force at that cutoff to the
    ///         newest, and over the open interval. `found` is false when no sampled interval
    ///         opened that long ago.
    /// @dev The same window laggedMmr walks, measured back from the block rather than from the
    ///      mark: the figure sizes the fund's reserve, which no position's solvency is judged by,
    ///      so there is no second instant it has to agree with. Open interest reaches the result
    ///      only once every sample since the cutoff carries it, which is what "held for the grace
    ///      period" means; a fall reaches it at the next record. With gaps in the ring the newest
    ///      interval that opened at or before the cutoff opens the window, however old it is.
    ///      Unlike laggedMmr, a ring that does not reach the cutoff yet reports nothing found
    ///      rather than a shortened window, and the reserve is sized on live open interest.
    /// @param buf The pair's sample ring buffer (storage).
    /// @return oiSize The trailing minimum, in BAZAAR_SCALE precision; 0 when not found.
    /// @return found  Whether a sampled interval opened at least MMR_GRACE_PERIOD ago.
    function trailingOi(BazaarTypes.MmrSampleBuffer storage buf) internal view returns (uint256 oiSize, bool found) {
        uint256 n = buf.count;
        if (n == 0 || block.timestamp < BazaarTypes.MMR_GRACE_PERIOD) {
            return (0, false);
        }
        uint256 cutoff = block.timestamp - BazaarTypes.MMR_GRACE_PERIOD;
        uint256 idx = (buf.head + BazaarTypes.MMR_SAMPLE_COUNT - 1) % BazaarTypes.MMR_SAMPLE_COUNT;
        oiSize = buf.intervalMinOi;
        for (uint256 i = 0; i < n; i++) {
            BazaarTypes.MmrSample storage s = buf.samples[idx];
            uint256 sampled = s.oiSize;
            if (sampled < oiSize) oiSize = sampled;
            if (uint256(s.ts) <= cutoff) return (oiSize, true);
            idx = (idx + BazaarTypes.MMR_SAMPLE_COUNT - 1) % BazaarTypes.MMR_SAMPLE_COUNT;
        }
        return (0, false);
    }

    /// @notice Returns the lowest rate recorded from the interval in force MMR_GRACE_PERIOD before
    ///         `refTs` up to now, the open interval included. Where the ring does not reach back
    ///         that far, the lowest rate it holds; 0 only before anything has been recorded.
    /// @dev Starts from the open interval's running minimum. If that interval opened at or before
    ///      the cutoff (refTs - grace), it was in force for the whole window and is the answer.
    ///      Otherwise the walk takes the minimum of every sample newest-to-oldest and closes the
    ///      window on the first one stamped at or before the cutoff — the interval in force at the
    ///      cutoff. A rise can therefore seize only once every rate in force since the cutoff
    ///      carries it, which is what "in force for the grace period" means; the cutoff sample
    ///      alone would test the rate at a single instant a day before the present, and together
    ///      with the current rate that is two instants a caller can choose. Robust to missed
    ///      hours: if no interval opened in the exact 24h-ago hour, the newest one that opened
    ///      earlier (even more than 24h old) opens the window.
    ///
    ///      The open interval counts because every recompute records the rate it sets, so its
    ///      running minimum holds every rate in force since the interval opened. Without it a
    ///      dip and a recovery inside one interval would leave no trace until the interval
    ///      closed: a position opened at the dipped rate's IMR would be judged at the older,
    ///      higher samples as soon as one recompute over a re-inflated open interest restored
    ///      them, a rate that has not held for a moment since the position opened.
    ///
    ///      The walk runs out of samples in two cases, and the whole ring is then the window. On a
    ///      pair younger than the grace period nothing opened that long ago, so the result is
    ///      every rate the pair has recorded. Returning nothing there would leave every position on
    ///      a new pair to the current rate alone, which one recompute over an inflated open
    ///      interest can lift; the shortened window still makes a rise hold for every rate the pair
    ///      has recorded before it binds. Behind a mark older than the newest sample, which a
    ///      closed-market pair that keeps refreshing on its stored price produces, a full ring
    ///      spans more than a grace period ending now (BazaarPair._laggedMmr says why no seizure
    ///      reads it). Called once per batch (not per position) so the O(count) walk is amortized
    ///      across the whole batch.
    /// @param buf   The pair's sample ring buffer (storage).
    /// @param refTs The instant the lookback is measured back from. Callers pass the timestamp of
    ///              the mark positions are being valued against, not the calling block — see
    ///              BazaarPair._laggedMmr for why the two must be the same instant.
    /// @return mmrBp The lagged MMR in basis points, or 0 when nothing has been recorded.
    function laggedMmr(BazaarTypes.MmrSampleBuffer storage buf, uint256 refTs) internal view returns (uint256 mmrBp) {
        // 0 when no refresh has run yet, which callers read as "no lagged rate".
        uint256 lowest = buf.intervalMinBp;
        // A reference younger than the grace period clamps the cutoff to 0, which no stamp meets
        // once anything is recorded, so the walk below takes the minimum over the whole ring.
        uint256 cutoff = refTs > BazaarTypes.MMR_GRACE_PERIOD ? refTs - BazaarTypes.MMR_GRACE_PERIOD : 0;
        // The open interval was already in force at the cutoff: nothing older is in the window.
        if (buf.lastSampleTs <= cutoff) return lowest;
        uint256 n = buf.count;
        // Newest valid sample sits one slot behind head; iterate backward `count` times.
        uint256 idx = (buf.head + BazaarTypes.MMR_SAMPLE_COUNT - 1) % BazaarTypes.MMR_SAMPLE_COUNT;
        for (uint256 i = 0; i < n; i++) {
            BazaarTypes.MmrSample storage s = buf.samples[idx];
            uint256 rate = s.mmrBp;
            if (lowest == 0 || rate < lowest) lowest = rate;
            if (uint256(s.ts) <= cutoff) return lowest;
            idx = (idx + BazaarTypes.MMR_SAMPLE_COUNT - 1) % BazaarTypes.MMR_SAMPLE_COUNT;
        }
        // The ring does not reach the cutoff: every sample it holds is inside the window.
        return lowest;
    }
}
