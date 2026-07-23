// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";

/// @title VaultHealthLib
/// @notice Internal library for vault health checks (Check 1: liquidation exposure vs insurance fund).
///         Compiled inline into callers — both BazaarPair and AdlLib can use it without DELEGATECALL.
library VaultHealthLib {
    // -------------------- Constants --------------------

    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 internal constant BP_SCALE = BazaarTypes.BP_SCALE;

    /// @notice ADL trigger threshold: freeze trading and trigger ADL when expected losses exceed this % of insurance fund
    uint256 internal constant ADL_TRIGGER_THRESHOLD_BP = 8_000; // 80% of insurance fund
    /// @notice ADL cancel threshold: ADL ends when expected losses drop below this % of insurance fund (hysteresis)
    uint256 internal constant ADL_CANCEL_THRESHOLD_BP = 6_000; // 60% of insurance fund

    /// @notice Maximum duration ADL can remain pending before triggering emergency termination
    uint256 internal constant ADL_TIMEOUT_DURATION = 24 hours;

    // -------------------- Structs --------------------

    /// @notice Result of Check 1: liquidation exposure vs insurance fund
    struct LiqExposureResult {
        bool healthy; // True if expected loss <= ADL threshold
        bool adlTimeoutExpired; // True if ADL has been pending longer than ADL_TIMEOUT_DURATION
        // New ADL state — caller should apply these to storage
        bool newIsAdlPending;
        uint256 newAdlPendingSince;
        uint256 newAdlSnapshotPrice;
        int256 newAdlSnapshotFundingIndex; // funding index frozen alongside the price snapshot
        bool newAdlLongs; // side to deleverage (the winners) — opposite of the liquidated side
    }

    // -------------------- Functions --------------------

    /// @notice Check 1: actual real-time gap on pending liquidations vs insurance fund
    /// @dev Returns a result struct with new ADL state values for the caller to apply.
    ///      Now uses single-direction aggregate (pendingLiqSize, pendingLiqBankruptcyNotional, pendingLiqIsLong).
    function checkLiqExposure(
        BazaarTypes.Vault storage pairVault,
        uint256 currentPrice,
        bool isAdlPending,
        uint256 adlPendingSince,
        uint256 adlSnapshotPrice,
        bool adlLongs,
        int256 currentFundingIndex,
        int256 adlSnapshotFundingIndex
    ) internal view returns (LiqExposureResult memory r) {
        r.healthy = true;
        // Preserve existing state as defaults
        r.newIsAdlPending = isAdlPending;
        r.newAdlPendingSince = adlPendingSince;
        r.newAdlSnapshotPrice = adlSnapshotPrice;
        r.newAdlSnapshotFundingIndex = adlSnapshotFundingIndex;
        r.newAdlLongs = adlLongs;

        uint256 expectedLoss = 0;

        if (pairVault.pendingLiqSize > 0) {
            // Loss = (bankruptcy notional) − (current notional). The vault inherited the
            // position at bankruptcy price and will close it at current; the difference
            // is what the insurance fund has to cover. Sign depends on direction.
            uint256 currentLiqNotional = Math.mulDiv(pairVault.pendingLiqSize, currentPrice, BAZAAR_SCALE);
            uint256 bkNotional = pairVault.pendingLiqBankruptcyNotional;

            if (pairVault.pendingLiqIsLong) {
                expectedLoss = bkNotional > currentLiqNotional ? bkNotional - currentLiqNotional : 0;
            } else {
                expectedLoss = currentLiqNotional > bkNotional ? currentLiqNotional - bkNotional : 0;
            }
        }

        uint256 adlThresholdBp = isAdlPending ? ADL_CANCEL_THRESHOLD_BP : ADL_TRIGGER_THRESHOLD_BP;
        uint256 adlThreshold = Math.mulDiv(pairVault.insuranceFundBalance, adlThresholdBp, BP_SCALE);

        if (expectedLoss > adlThreshold) {
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
            } else if (adlPendingSince > 0 && block.timestamp - adlPendingSince > ADL_TIMEOUT_DURATION) {
                // ADL timeout exceeded — caller should trigger emergency termination
                r.adlTimeoutExpired = true;
                r.newIsAdlPending = true;
            } else {
                // ADL still pending, within timeout
                r.newIsAdlPending = true;
                if (adlLongs == pairVault.pendingLiqIsLong) {
                    // Vault side flipped mid-auction: opposing liquidations overwhelmed the
                    // old aggregate via netting, so the frozen target side now matches the
                    // side the vault holds. Re-target the new winners and re-snapshot the
                    // price so they rank as profitable. adlPendingSince is deliberately NOT
                    // reset — the 24h termination clock stays monotone so repeated flips
                    // can never stall emergency termination.
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
