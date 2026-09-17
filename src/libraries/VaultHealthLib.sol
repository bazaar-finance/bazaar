// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BazaarTypes} from "./BazaarTypes.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";

/// @title VaultHealthLib
/// @notice Internal library for the ADL gate: whether the insurance fund's free capital above
///         its reserve carries the vault's inherited inventory. Compiled inline into BazaarPair.
library VaultHealthLib {
    // -------------------- Constants --------------------

    /// @notice Maximum duration ADL can remain pending before triggering emergency termination
    uint256 internal constant ADL_TIMEOUT_DURATION = 24 hours;

    // -------------------- Structs --------------------

    /// @notice Result of Check 1: liquidation exposure vs insurance fund
    struct LiqExposureResult {
        bool healthy; // True when the fund above its reserve carries the inventory (see checkLiqExposure)
        bool adlTimeoutExpired; // True if ADL has been pending longer than ADL_TIMEOUT_DURATION
        // New ADL state — caller should apply these to storage
        bool newIsAdlPending;
        uint256 newAdlPendingSince;
        uint256 newAdlSnapshotPrice;
        int256 newAdlSnapshotFundingIndex; // funding index frozen alongside the price snapshot
        bool newAdlLongs; // side to deleverage (the winners) — opposite of the liquidated side
    }

    // -------------------- Functions --------------------

    /// @notice Check 1: the vault's inherited inventory against the insurance fund's free capital
    ///         above its reserve.
    /// @dev Returns a result struct with new ADL state values for the caller to apply. The
    ///      figures come from RiskParamsLib.vaultAdlExposure, which values the single-direction
    ///      pendingLiq aggregate against the collateral seized alongside it and nets the reserve
    ///      out of the fund. The window opens when that capital cannot carry the inventory at
    ///      the mark. While open it stays open until the capital could finish the remaining
    ///      inventory at the unload band's edge — the figure the auction sizes its batches to —
    ///      so the walk that resumes afterwards can sell the remainder inside the band without
    ///      reopening the window. The gap between the two conditions is one band of the
    ///      remaining inventory, so the boundary cannot flap on a tick.
    /// @param pairVault The pair's vault aggregates
    /// @param currentPrice Price to value the inventory at (BAZAAR_SCALE precision)
    /// @param isAdlPending Whether a window is open
    /// @param adlPendingSince When the open window opened; 0 when none is open
    /// @param adlSnapshotPrice The open window's frozen ranking price
    /// @param adlLongs Whether the open window deleverages longs
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param adlSnapshotFundingIndex The open window's frozen funding index
    /// @param mmrBp The maintenance margin the unload band is derived from
    /// @return r The verdict and the ADL state the caller should store
    function checkLiqExposure(
        BazaarTypes.Vault storage pairVault,
        uint256 currentPrice,
        bool isAdlPending,
        uint256 adlPendingSince,
        uint256 adlSnapshotPrice,
        bool adlLongs,
        int256 currentFundingIndex,
        int256 adlSnapshotFundingIndex,
        uint256 mmrBp
    ) internal view returns (LiqExposureResult memory r) {
        r.healthy = true;
        // Preserve existing state as defaults
        r.newIsAdlPending = isAdlPending;
        r.newAdlPendingSince = adlPendingSince;
        r.newAdlSnapshotPrice = adlSnapshotPrice;
        r.newAdlSnapshotFundingIndex = adlSnapshotFundingIndex;
        r.newAdlLongs = adlLongs;

        (uint256 expectedLoss, uint256 base, uint256 worstFinish,) =
            RiskParamsLib.vaultAdlExposure(pairVault, currentPrice, currentFundingIndex, mmrBp);

        if (isAdlPending ? worstFinish > base : expectedLoss > base) {
            r.healthy = false;
            if (!isAdlPending) {
                // First time triggering ADL
                r.newIsAdlPending = true;
                r.newAdlPendingSince = block.timestamp;
                r.newAdlSnapshotPrice = currentPrice;
                // Freeze the funding index with the price: both define the frozen book the
                // whole auction ranks against.
                r.newAdlSnapshotFundingIndex = currentFundingIndex;
                // Deleverage the profitable counterparties — the side OPPOSITE the
                // liquidated positions the vault inherited.
                r.newAdlLongs = !pairVault.pendingLiqIsLong;
            } else {
                r.newIsAdlPending = true;

                // The timeout verdict and the re-target are independent, and both must be able
                // to run in the same evaluation. Reporting the expiry alone would leave a
                // flipped auction aimed at the side the vault itself holds, which BazaarPair
                // refuses to execute — so the runway the caller grants before terminating would
                // be dead time on exactly the pairs that need it most. Gating the expiry behind
                // the flip instead would be worse: an auction that keeps flipping would never
                // report expiry at all, and could never be terminated.
                if (adlPendingSince > 0 && block.timestamp - adlPendingSince > ADL_TIMEOUT_DURATION) {
                    // ADL timeout exceeded — caller should trigger emergency termination
                    r.adlTimeoutExpired = true;
                }

                if (adlLongs == pairVault.pendingLiqIsLong) {
                    // Vault side flipped mid-auction: opposing liquidations overwhelmed the
                    // old aggregate via netting, so the frozen target side now matches the
                    // side the vault holds. Re-target the new winners and re-snapshot the
                    // price so they rank as profitable. adlPendingSince is deliberately NOT
                    // reset — the 24h termination clock stays monotone so repeated flips
                    // can never stall emergency termination, and neither the clock nor the
                    // runway BazaarPair arms off it is re-armed by a re-target.
                    r.newAdlLongs = !pairVault.pendingLiqIsLong;
                    r.newAdlSnapshotPrice = currentPrice;
                    // Re-freeze funding with the re-snapshotted price so the re-targeted
                    // winners rank against a consistent frozen book.
                    r.newAdlSnapshotFundingIndex = currentFundingIndex;
                }
            }
        } else {
            // Pressure resolved — clear ADL state
            r.healthy = true;
            r.newIsAdlPending = false;
            r.newAdlPendingSince = 0;
            r.newAdlSnapshotPrice = 0;
            r.newAdlSnapshotFundingIndex = 0;
        }
    }
}
