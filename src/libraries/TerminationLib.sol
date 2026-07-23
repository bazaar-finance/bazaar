// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";

/// @title TerminationLib
/// @notice External library for pair termination settlement logic. Runs via DELEGATECALL.
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
    /// @param params Termination parameters
    /// @return result Values to write back to BazaarPair state
    function executeTermination(BazaarTypes.Vault storage pairVault, BazaarTypes.TerminationParams memory params)
        external
        returns (BazaarTypes.TerminationResult memory result)
    {
        uint256 terminationPrice = params.terminationPrice;

        // Snapshot values before modification for event emission
        uint256 snapshotPendingLiqSize = pairVault.pendingLiqSize;
        uint256 snapshotInsuranceFundBalance = pairVault.insuranceFundBalance;

        // === Settle the pending-liquidation (estate) aggregate ===
        // liqInsuranceImpact carries only the drift/deficit legs below; the estate leg settles
        // here as an I <-> D TRANSFER, with estateImpact kept for event reporting.
        int256 liqInsuranceImpact = 0;
        int256 estateImpact = 0;
        uint256 estateShortfall = 0;

        if (!params.isEmergency && pairVault.pendingLiqSize > 0) {
            // Reporting impact: settlement price vs avg bankruptcy price — the insurance fund's
            // true economic P&L on the inherited inventory (seized collateral already sits in I).
            uint256 avgBankruptcyPrice =
                Math.mulDiv(pairVault.pendingLiqBankruptcyNotional, BazaarTypes.BAZAAR_SCALE, pairVault.pendingLiqSize);
            uint256 absDiff = terminationPrice > avgBankruptcyPrice
                ? terminationPrice - avgBankruptcyPrice
                : avgBankruptcyPrice - terminationPrice;
            int256 impact = int256(Math.mulDiv(pairVault.pendingLiqSize, absDiff, BazaarTypes.BAZAAR_SCALE));
            if (pairVault.pendingLiqIsLong) {
                // Vault holds longs — profits when terminationPrice > bankruptcy
                estateImpact = terminationPrice > avgBankruptcyPrice ? impact : -impact;
            } else {
                // Vault holds shorts — profits when terminationPrice < bankruptcy
                estateImpact = terminationPrice < avgBankruptcyPrice ? impact : -impact;
            }

            // Deposits-ledger settlement: the estates' surviving counterparties realize their
            // wins into buckets and withdraw them FROM D, but the estates' backing — seized
            // collateral plus the bankruptcy-vs-settlement charge — sits in I. Book the estates'
            // entry-vs-settlement value as an I <-> D transfer (mirror of MatchingEngineLib's
            // vaultPnl booking and AdlLib._fundWinnerPnl): entry − settle = seizedCollateral +
            // (bankruptcy − settle), so I nets exactly ±estateImpact and D gains the winners'
            // backing. A bare I debit would leave D short by the estates' full contribution and
            // underflow late winner withdrawals despite their claims being cash-backed. The
            // uncovered remainder (estate loss beyond what I holds) is unbacked winner claim —
            // it feeds the haircut below, never a D credit (no cash behind it).
            uint256 settleNotional = Math.mulDiv(pairVault.pendingLiqSize, terminationPrice, BazaarTypes.BAZAAR_SCALE);
            uint256 entryNotional = pairVault.pendingLiqEntryNotional;
            bool estateLost =
                pairVault.pendingLiqIsLong ? entryNotional > settleNotional : settleNotional > entryNotional;
            uint256 owed =
                entryNotional > settleNotional ? entryNotional - settleNotional : settleNotional - entryNotional;
            if (estateLost) {
                uint256 take = owed < pairVault.insuranceFundBalance ? owed : pairVault.insuranceFundBalance;
                pairVault.insuranceFundBalance -= take;
                pairVault.totalCollateralDeposited += take;
                estateShortfall = owed - take;
            } else {
                // Estate side profited: its "win" has no surviving claimant, so insurance
                // inherits it. Capped at D defensively — an uncredited excess errs as
                // unclaimable surplus, never as an unbacked claim.
                uint256 take = owed < pairVault.totalCollateralDeposited ? owed : pairVault.totalCollateralDeposited;
                pairVault.totalCollateralDeposited -= take;
                pairVault.insuranceFundBalance += take;
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
            result.normalCollateralRatioBp = BazaarTypes.BP_SCALE; // no principal haircut unless deep insolvency below

            // Account for any existing USDC shortfall (actual balance < bookkeeping)
            uint256 actualUsdc = _getUsdcBalance(params.usdc);
            uint256 expectedBalance = uint256(
                BazaarMathLib.convertExponent(
                    int256(pairVault.insuranceFundBalance + pairVault.totalCollateralDeposited),
                    BazaarTypes.BAZAAR_EXPONENT,
                    BazaarTypes.USDC_EXPONENT
                )
            );
            if (expectedBalance > actualUsdc) {
                uint256 usdcDeficit = uint256(
                    BazaarMathLib.convertExponent(
                        int256(expectedBalance - actualUsdc), BazaarTypes.USDC_EXPONENT, BazaarTypes.BAZAAR_EXPONENT
                    )
                );
                liqInsuranceImpact -= int256(usdcDeficit);
            } else {
                uint256 surplusUsdc = actualUsdc - expectedBalance;
                liqInsuranceImpact += int256(
                    BazaarMathLib.convertExponent(
                        int256(surplusUsdc), BazaarTypes.USDC_EXPONENT, BazaarTypes.BAZAAR_EXPONENT
                    )
                );
            }

            // Fold realized-but-unbacked bad debt into the waterfall. Both deficit writers
            // (Pass-A vault close in MatchingEngineLib, opposing-liquidation netting in
            // LiquidationLib — including terminal sweeps) book the covered portion as an
            // I <-> D transfer, so expectedBalance (I + D) never moves and the drift check
            // above can never see this loss. Without this fold the winners' ratio stays 100%
            // while their claims exceed the pot by exactly the deficit (first-come-first-served
            // drain). isVaultHealthy Check-0 normally terminates the moment a deficit appears;
            // during the terminal sweep window that check is suppressed, so this is where swept
            // bad debt finally charges insurance -> winner-PnL -> principal.
            if (pairVault.deficit > 0) {
                liqInsuranceImpact -= int256(pairVault.deficit);
                pairVault.deficit = 0;
            }

            // Apply the drift/deficit impact to insurance as a bare credit/debit — these legs
            // have no deposits-ledger counterpart (surplus cash has no claimant bucket; unbacked
            // deficit claims must be haircut, never funded into D). The estate leg was already
            // settled above as an I <-> D transfer.
            uint256 shortfall = estateShortfall;
            if (liqInsuranceImpact >= 0) {
                pairVault.insuranceFundBalance += uint256(liqInsuranceImpact);
            } else {
                uint256 liqCost = uint256(-liqInsuranceImpact);
                if (liqCost <= pairVault.insuranceFundBalance) {
                    pairVault.insuranceFundBalance -= liqCost;
                } else {
                    shortfall += liqCost - pairVault.insuranceFundBalance;
                    pairVault.insuranceFundBalance = 0;
                }
            }

            if (shortfall == 0) {
                result.winnersPayoutRatioBp = BazaarTypes.BP_SCALE;
            } else {
                uint256 longNotional = Math.mulDiv(pairVault.totalLongOI, terminationPrice, BazaarTypes.BAZAAR_SCALE);
                uint256 shortNotional = Math.mulDiv(pairVault.totalShortOI, terminationPrice, BazaarTypes.BAZAAR_SCALE);

                int256 longPnL = int256(longNotional) - int256(pairVault.longWeightedEntrySum);
                int256 shortPnL = int256(pairVault.shortWeightedEntrySum) - int256(shortNotional);

                // Winners' collective PnL = sum of the positive side aggregates. A book left
                // imbalanced by liquidations/ADL can have BOTH sides net-positive at the
                // termination price, and the payout ratio below is applied to every winner on
                // both sides — so the denominator must be the combined total. max() of the
                // sides would over-haircut two-sided books (the excess stranded with no
                // claimant) and could trip the rung-4 wipeout while the combined PnL can
                // still absorb the shortfall. Positivity is checked before each cast; a
                // negative int256 would wrap to ~2^256 and break the haircut math.
                uint256 winningPnl;
                if (longPnL > 0) winningPnl = uint256(longPnL);
                if (shortPnL > 0) winningPnl += uint256(shortPnL);

                if (shortfall >= winningPnl) {
                    // Rung 4: zeroing the winning side's PnL still doesn't cover the shortfall,
                    // so principal itself can't be honored in full. Haircut principal pro-rata
                    // against the USDC actually on hand so cumulative payouts can never exceed
                    // the pot (no first-come-first-served drain). Conservative by construction:
                    // the denominator is pre-settlement totalCollateralDeposited, which is >= the
                    // sum of post-PnL bucket collateral (losers shrink; winners get 0 added here),
                    // so total payouts <= actualUsdc. Any rounding dust stays in the contract.
                    result.winnersPayoutRatioBp = 0;
                    uint256 actualUsdcBazaar = uint256(
                        BazaarMathLib.convertExponent(
                            int256(actualUsdc), BazaarTypes.USDC_EXPONENT, BazaarTypes.BAZAAR_EXPONENT
                        )
                    );
                    if (pairVault.totalCollateralDeposited > 0 && actualUsdcBazaar < pairVault.totalCollateralDeposited)
                    {
                        result.normalCollateralRatioBp =
                            Math.mulDiv(actualUsdcBazaar, BazaarTypes.BP_SCALE, pairVault.totalCollateralDeposited);
                    }
                } else {
                    result.winnersPayoutRatioBp = Math.mulDiv(winningPnl - shortfall, BazaarTypes.BP_SCALE, winningPnl);
                }
            }

            emit PairTerminatedNormal(
                params.pairId,
                terminationPrice,
                estateImpact + liqInsuranceImpact,
                snapshotInsuranceFundBalance,
                pairVault.insuranceFundBalance,
                result.winnersPayoutRatioBp,
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
