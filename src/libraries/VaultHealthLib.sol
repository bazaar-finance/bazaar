// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {BazaarTypes} from "./BazaarTypes.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";

/// @title VaultHealthLib
/// @notice External library for the ADL gate: whether the insurance fund's free capital above
///         its reserve carries the vault's inherited inventory, and whether liquidations the
///         vault could not take are waiting for the auction. Linked as an external library so
///         the gate's code lives outside the pair's EIP-170 budget; RiskParamsLib carries the
///         exposure math it calls.
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
    ///         above its reserve, and the deferred liquidations against nothing at all.
    /// @dev Returns a result struct with new ADL state values for the caller to apply. The
    ///      inventory figures come from RiskParamsLib.vaultAdlExposure, which values the
    ///      single-direction pendingLiq aggregate against the collateral seized alongside it and
    ///      nets the reserve out of the fund. The window opens when that capital cannot carry the
    ///      inventory at the mark. While open it stays open until the capital could finish the
    ///      remaining inventory at the unload band's edge — the figure the auction sizes its
    ///      batches to — so the walk that resumes afterwards can sell the remainder inside the
    ///      band without reopening the window. The gap between the two conditions is one band of
    ///      the remaining inventory, so the boundary cannot flap on a tick.
    ///
    ///      A deferred liquidation is a position opposite the inventory that could not be netted
    ///      against it without taking the fund below its reserve, so it was left open for the
    ///      auction to close against its own counterparties. Its loss beyond its collateral is
    ///      exposure no earmark backs, and no amount of fund capital carries it in place: the
    ///      window opens and stays open while any is positive, whatever the inventory reads, and
    ///      capital resolves it only by absorbing the account — the netting, once the fund can
    ///      afford it, which the auction's inventory leg closes enough inventory to pay for when
    ///      no cohort covers the account (AdlLib._sizeToAffordNettings). Counted only while the
    ///      vault holds inventory, and only for accounts still opposite it: a netting can flip
    ///      the inventory onto a listed account's side, and from then on no batch can close that
    ///      account through the window, while any liquidation that names it seizes it into the
    ///      inventory (RiskParamsLib.deferredExcess). Once the inventory is gone, by a batch or
    ///      otherwise, the deferred positions are seized and become inventory in their own
    ///      right.
    /// @param pairVault The pair's vault aggregates
    /// @param positionBuckets Storage mapping of position buckets
    /// @param deferred The deferred liquidations
    /// @param currentPrice Price to value the inventory at (BAZAAR_SCALE precision)
    /// @param isAdlPending Whether a window is open
    /// @param adlPendingSince When the open window opened; 0 when none is open
    /// @param adlSnapshotPrice The open window's frozen ranking price
    /// @param adlLongs Whether the open window deleverages longs
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param adlSnapshotFundingIndex The open window's frozen funding index
    /// @param mmrBp The maintenance rate the unload band is derived from (BucketLib.effectiveMmrBp)
    /// @return r The verdict and the ADL state the caller should store
    function checkLiqExposure(
        BazaarTypes.Vault storage pairVault,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        address[] storage deferred,
        uint256 currentPrice,
        bool isAdlPending,
        uint256 adlPendingSince,
        uint256 adlSnapshotPrice,
        bool adlLongs,
        int256 currentFundingIndex,
        int256 adlSnapshotFundingIndex,
        uint256 mmrBp
    ) public view returns (LiqExposureResult memory r) {
        r.healthy = true;
        // Preserve existing state as defaults
        r.newIsAdlPending = isAdlPending;
        r.newAdlPendingSince = adlPendingSince;
        r.newAdlSnapshotPrice = adlSnapshotPrice;
        r.newAdlSnapshotFundingIndex = adlSnapshotFundingIndex;
        r.newAdlLongs = adlLongs;

        (uint256 expectedLoss, uint256 base, uint256 worstFinish,) =
            RiskParamsLib.vaultAdlExposure(pairVault, currentPrice, currentFundingIndex, mmrBp);

        bool inventoryUncovered = isAdlPending ? worstFinish > base : expectedLoss > base;
        bool deferredUncovered = pairVault.pendingLiqSize != 0 && deferred.length != 0
            && RiskParamsLib.deferredExcess(
                    positionBuckets, deferred, pairVault.pendingLiqIsLong, currentPrice, currentFundingIndex
                ) != 0;

        if (inventoryUncovered || deferredUncovered) {
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
                    // Vault side flipped mid-auction: an opposing liquidation the fund could
                    // afford overwhelmed the old aggregate via netting, or the deferred
                    // positions were seized once the old inventory was gone, so the frozen
                    // target side now matches the side the vault holds. Re-target the new
                    // winners and re-snapshot the price so they rank as profitable.
                    // adlPendingSince is deliberately NOT reset — the 24h termination clock
                    // stays monotone so repeated flips can never stall emergency termination,
                    // and neither the clock nor the runway BazaarPair arms off it is re-armed
                    // by a re-target.
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
