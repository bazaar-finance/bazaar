// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";

/// @title TerminationLib
/// @notice External library for pair termination settlement logic. Runs via DELEGATECALL.
///         Normal termination uses the two-stage frozen-ratio design: a 48h settlement window
///         registers per-user profit claims and bad debt (CollateralLib.settleTerminalPositions),
///         then this finalize charges bad debt to insurance and freezes the profit payout ratio
///         from the ACTUAL cash surplus — principal (D) and the insurers' remainder (I) are
///         reserved at all times; profits pay only from cash - D - I.
library TerminationLib {
    // -------------------- Errors --------------------

    error TerminationLib__TerminationPriceRequired();
    error TerminationLib__BalanceOfFailed();

    // -------------------- Events --------------------

    event PairTerminatedEmergency(
        bytes32 indexed pairId,
        uint256 actualUsdcBalance,
        uint256 totalCollateralDeposited,
        uint256 collateralWithdrawalRatioBp,
        uint256 insuranceFundBalanceAfter,
        uint256 pendingLiqSizeCleared,
        uint256 timestamp
    );

    event PairTerminatedNormal(
        bytes32 indexed pairId,
        uint256 terminationPrice,
        int256 liqInsuranceImpact,
        uint256 insuranceFundBalanceBefore,
        uint256 insuranceFundBalanceAfter,
        uint256 winnersPayoutRatioBp,
        uint256 totalLongOI,
        uint256 totalShortOI,
        uint256 pendingLiqSizeCleared,
        uint256 timestamp
    );

    // -------------------- Functions --------------------

    /// @notice Executes pair termination settlement
    /// @dev Called via DELEGATECALL from BazaarPair._terminatePair
    /// @param pairVault The vault storage reference
    /// @param ts Terminal-settlement state (claims registered during the 48h window)
    /// @param params Termination parameters
    /// @return result Values to write back to BazaarPair state
    function executeTermination(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.TerminalSettlement storage ts,
        BazaarTypes.TerminationParams memory params
    ) external returns (BazaarTypes.TerminationResult memory result) {
        uint256 terminationPrice = params.terminationPrice;

        // Snapshot values before modification for event emission
        uint256 snapshotPendingLiqSize = pairVault.pendingLiqSize;
        uint256 snapshotInsuranceFundBalance = pairVault.insuranceFundBalance;

        // === Settle the pending-liquidation (estate) aggregate ===
        // The estate leg (vault inventory from pre-termination liquidations) settles as an
        // I <-> D transfer of its FULL entry -> settlement value change — price leg AND the
        // funding leg (currentFundingIndex vs the liquidatees' entry-weighted index), mirroring
        // _settleVaultLiquidation and _netOpposingLiquidation. The funding leg is required:
        // without it the estates' funding obligation would vanish while the surviving
        // counterparties still realize theirs, leaving unbacked claims on the deposits ledger.
        int256 estateNet = 0; // net insurance delta from the estate leg (event reporting)

        if (!params.isEmergency && pairVault.pendingLiqSize > 0) {
            uint256 settleNotional = Math.mulDiv(pairVault.pendingLiqSize, terminationPrice, BazaarTypes.BAZAAR_SCALE);
            uint256 entryNotional = pairVault.pendingLiqEntryNotional;
            int256 fundingLeg = BazaarMathLib.signedMulDiv(
                params.currentFundingIndex - pairVault.pendingLiqEntryFundingIndex,
                int256(pairVault.pendingLiqSize),
                int256(BazaarTypes.BAZAAR_SCALE)
            );
            // Estate value change entry -> settlement (longs pay a positive funding delta).
            int256 valueChange = pairVault.pendingLiqIsLong
                ? int256(settleNotional) - int256(entryNotional) - fundingLeg
                : int256(entryNotional) - int256(settleNotional) + fundingLeg;
            if (valueChange < 0) {
                // Estate lost: its counterparties' wins draw from D at withdrawal, but the
                // backing (seized collateral + settlement charge) sits in I — transfer it,
                // capped at I. Any uncovered remainder simply leaves less cash surplus for
                // the profit ratio below; nothing unbacked is ever credited to D.
                uint256 owed = uint256(-valueChange);
                uint256 take = owed < pairVault.insuranceFundBalance ? owed : pairVault.insuranceFundBalance;
                pairVault.insuranceFundBalance -= take;
                pairVault.totalCollateralDeposited += take;
                estateNet = -int256(take);
            } else if (valueChange > 0) {
                // Estate profited: no surviving claimant, insurance inherits. Capped at D —
                // an uncredited excess errs as unclaimable surplus, never an unbacked claim.
                uint256 owed = uint256(valueChange);
                uint256 take = owed < pairVault.totalCollateralDeposited ? owed : pairVault.totalCollateralDeposited;
                pairVault.totalCollateralDeposited -= take;
                pairVault.insuranceFundBalance += take;
                estateNet = int256(take);
            }
        }

        // Zero out pending liquidation tracking
        pairVault.pendingLiqSize = 0;
        pairVault.pendingLiqEntryNotional = 0;
        pairVault.pendingLiqBankruptcyNotional = 0;
        pairVault.pendingLiqEntryFundingIndex = 0;

        if (params.isEmergency) {
            result.isEmergency = true;

            // Get actual USDC balance via low-level call (DELEGATECALL context = BazaarPair's address)
            uint256 actualUsdc = _getUsdcBalance(params.usdc);
            uint256 expectedCollateral = uint256(
                BazaarMathLib.convertExponent(
                    int256(pairVault.totalCollateralDeposited), BazaarTypes.BAZAAR_EXPONENT, BazaarTypes.USDC_EXPONENT
                )
            );

            if (actualUsdc >= expectedCollateral) {
                result.emergencyCollateralRatioBp = BazaarTypes.BP_SCALE; // 100%
                uint256 surplusUsdc = actualUsdc - expectedCollateral;
                pairVault.insuranceFundBalance = uint256(
                    BazaarMathLib.convertExponent(
                        int256(surplusUsdc), BazaarTypes.USDC_EXPONENT, BazaarTypes.BAZAAR_EXPONENT
                    )
                );
            } else {
                result.emergencyCollateralRatioBp = actualUsdc * BazaarTypes.BP_SCALE / expectedCollateral;
                pairVault.insuranceFundBalance = 0;
            }

            emit PairTerminatedEmergency(
                params.pairId,
                actualUsdc,
                pairVault.totalCollateralDeposited,
                result.emergencyCollateralRatioBp,
                pairVault.insuranceFundBalance,
                snapshotPendingLiqSize,
                block.timestamp
            );
        } else {
            if (terminationPrice == 0) revert TerminationLib__TerminationPriceRequired();
            result.isNormal = true;
            result.normalTerminationPrice = terminationPrice;
            result.normalCollateralRatioBp = BazaarTypes.BP_SCALE; // no principal haircut unless cash < D below

            // === Charge registered bad debt (incl. funding legs) and realized deficit to
            // insurance. Both are unbacked-claim records with no cash counterpart; charging I
            // shrinks the insurers' reserved remainder, which grows the profit surplus below.
            {
                uint256 charge = ts.terminalBadDebt + pairVault.deficit;
                if (charge > 0) {
                    uint256 take = charge < pairVault.insuranceFundBalance ? charge : pairVault.insuranceFundBalance;
                    pairVault.insuranceFundBalance -= take;
                    pairVault.deficit = 0;
                    ts.terminalBadDebt = 0;
                }
            }

            // === Freeze the profit ratio from ACTUAL cash ===
            // surplus = cash - D (principal reserve) - I (insurers' remainder). Deriving from the
            // real balance makes drift, uncovered estate loss, and any other leak flow into the
            // ratio automatically, with no aggregate-PnL estimation: a net-per-side denominator
            // would zero every winner over a 1-wei shortfall on an internally hedged book.
            uint256 actualUsdc = _getUsdcBalance(params.usdc);
            uint256 cashBazaar = uint256(
                BazaarMathLib.convertExponent(
                    int256(actualUsdc), BazaarTypes.USDC_EXPONENT, BazaarTypes.BAZAAR_EXPONENT
                )
            );

            // Black-swan backstop: if cash cannot even cover the principal reserve (books-vs-
            // balance drift), haircut principal pro-rata so payouts can never exceed the pot.
            if (pairVault.totalCollateralDeposited > 0 && cashBazaar < pairVault.totalCollateralDeposited) {
                result.normalCollateralRatioBp =
                    Math.mulDiv(cashBazaar, BazaarTypes.BP_SCALE, pairVault.totalCollateralDeposited);
            }

            // Insurance is junior to principal: cap the insurers' claim at the cash actually
            // remaining once principal is reserved. The bad-debt charge above only sees
            // REGISTERED shortfalls; an unregistered books-vs-balance gap would leave I as a
            // phantom claim on USDC already committed to (possibly haircut) principal — and
            // post-termination insurance withdrawals are cooldown-exempt and price shares
            // against I, so junior money could exit ahead of seniors until the pot ran dry.
            // Mirrors the emergency branch, which derives I from the real cash surplus.
            {
                uint256 afterPrincipal = cashBazaar > pairVault.totalCollateralDeposited
                    ? cashBazaar - pairVault.totalCollateralDeposited
                    : 0;
                if (pairVault.insuranceFundBalance > afterPrincipal) {
                    pairVault.insuranceFundBalance = afterPrincipal;
                }
            }

            uint256 reserved = pairVault.totalCollateralDeposited + pairVault.insuranceFundBalance;
            uint256 surplus = cashBazaar > reserved ? cashBazaar - reserved : 0;
            uint256 claims = ts.totalProfitClaims;
            uint256 ratioBp = claims == 0
                ? BazaarTypes.BP_SCALE
                : (surplus >= claims ? BazaarTypes.BP_SCALE : Math.mulDiv(surplus, BazaarTypes.BP_SCALE, claims));
            ts.profitRatioBp = ratioBp;
            ts.profitReserve = Math.mulDiv(claims, ratioBp, BazaarTypes.BP_SCALE);
            result.winnersPayoutRatioBp = ratioBp;

            emit PairTerminatedNormal(
                params.pairId,
                terminationPrice,
                estateNet,
                snapshotInsuranceFundBalance,
                pairVault.insuranceFundBalance,
                ratioBp,
                pairVault.totalLongOI,
                pairVault.totalShortOI,
                snapshotPendingLiqSize,
                block.timestamp
            );
        }
    }

    /// @notice Gets the USDC balance of the current contract (BazaarPair via DELEGATECALL)
    function _getUsdcBalance(address usdc) internal view returns (uint256) {
        (bool ok, bytes memory data) =
            usdc.staticcall(
                abi.encodeWithSelector(0x70a08231, address(this)) // balanceOf(address)
            );
        if (!ok || data.length < 32) revert TerminationLib__BalanceOfFailed();
        return abi.decode(data, (uint256));
    }
}
