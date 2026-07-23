// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BazaarTypes} from "./BazaarTypes.sol";

/// @title MmrSampleLib
/// @notice Manages the per-pair ring buffer of hourly MMR samples that backs the 24h-lagged
///         liquidation threshold. Internal (inlined into BazaarPair) — operates directly on the
///         pair's MmrSampleBuffer storage. A single shared copy is emitted in BazaarPair bytecode.
library MmrSampleLib {
    /// @notice Records `currentMmrBp` into the ring buffer, at most once per MMR_SAMPLE_INTERVAL.
    /// @dev No-op when less than one interval has elapsed since the last sample. The first ever
    ///      call always records (lastSampleTs == 0). Sampling is driven by matchBatch, the only
    ///      writer of MMR; quiet periods simply leave gaps, which laggedMmr() tolerates.
    /// @param buf          The pair's sample ring buffer (storage).
    /// @param currentMmrBp The pair's current maintenance-margin rate.
    function record(BazaarTypes.MmrSampleBuffer storage buf, uint256 currentMmrBp) internal {
        if (buf.lastSampleTs != 0 && block.timestamp < buf.lastSampleTs + BazaarTypes.MMR_SAMPLE_INTERVAL) {
            return;
        }
        buf.samples[buf.head] = BazaarTypes.MmrSample({ts: uint64(block.timestamp), mmrBp: currentMmrBp});
        buf.head = (buf.head + 1) % BazaarTypes.MMR_SAMPLE_COUNT;
        if (buf.count < BazaarTypes.MMR_SAMPLE_COUNT) {
            buf.count += 1;
        }
        buf.lastSampleTs = block.timestamp;
    }

    /// @notice Returns the newest sample that is at least MMR_GRACE_PERIOD old, or 0 if none.
    /// @dev Walks the ring newest-to-oldest and returns the first sample with ts <= now - grace.
    ///      Robust to missed hours: if the exact 24h-ago hour was never sampled, the next older
    ///      sample (even more than 24h old) is returned; if no sample is old enough yet, returns 0
    ///      so callers fall back to each position's entry MMR. Called once per batch (not per
    ///      position) so the O(count) walk is amortized across the whole batch.
    /// @param buf The pair's sample ring buffer (storage).
    /// @return The lagged MMR in basis points, or 0 when no sample is >= MMR_GRACE_PERIOD old.
    function laggedMmr(BazaarTypes.MmrSampleBuffer storage buf) internal view returns (uint256) {
        uint256 n = buf.count;
        if (n == 0 || block.timestamp < BazaarTypes.MMR_GRACE_PERIOD) {
            return 0;
        }
        uint256 cutoff = block.timestamp - BazaarTypes.MMR_GRACE_PERIOD;
        // Newest valid sample sits one slot behind head; iterate backward `count` times.
        uint256 idx = (buf.head + BazaarTypes.MMR_SAMPLE_COUNT - 1) % BazaarTypes.MMR_SAMPLE_COUNT;
        for (uint256 i = 0; i < n; i++) {
            BazaarTypes.MmrSample storage s = buf.samples[idx];
            if (uint256(s.ts) <= cutoff) {
                return s.mmrBp;
            }
            idx = (idx + BazaarTypes.MMR_SAMPLE_COUNT - 1) % BazaarTypes.MMR_SAMPLE_COUNT;
        }
        return 0;
    }
}
