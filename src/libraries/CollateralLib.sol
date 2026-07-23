// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BucketLib} from "./BucketLib.sol";

/// @title CollateralLib
/// @notice External library for deposit and withdrawal collateral logic.
///         Runs via DELEGATECALL — has direct access to BazaarPair storage.
library CollateralLib {
    // -------------------- Constants --------------------

    uint256 internal constant MIN_COLLATERAL_AMOUNT = 1 * BazaarTypes.BAZAAR_SCALE;
    uint256 internal constant STALE_MARGIN_MULTIPLIER = BazaarTypes.STALE_MARGIN_MULTIPLIER;

    // -------------------- Errors --------------------

    error CollateralLib__DepositsAreBlocked(bool isPairTerminatedEmergency, bool isPairTerminatedNormal);
    error CollateralLib__PairScheduledForTermination();
    error CollateralLib__InvalidDepositAmount(uint256 amount, uint256 minAmount);
    error CollateralLib__ZeroWithdrawalAmount();
    error CollateralLib__WithdrawalBlockedDueToEmergencyTermination();
    error CollateralLib__WithdrawalsFrozenAdlPending();
    error CollateralLib__InsolventPositionBucket(uint256 availableEquity, uint256 minRequiredCollateral);
    error CollateralLib__InsufficientCollateral(uint256 amount, uint256 available);
    error CollateralLib__InsufficientMarginAfterWithdrawal(uint256 amount, uint256 available);
    error CollateralLib__NoPriceUpdateDataProvided();

    // ================================================================
    //                         Deposit Logic
    // ================================================================

    /// @notice Processes deposit collateral logic: validates, adds to raw collateral, emits bucket update.
    /// @dev Called via DELEGATECALL from BazaarPair. Does NOT handle USDC transfer or ETH refund.
    ///      No price needed — deposit simply adds to stored collateral. PnL and funding
    ///      adjustments are computed lazily at match/withdrawal/liquidation time.
    function depositCollateral(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.DepositParams memory params,
        address caller
    ) external {
        // Block deposits if pair is terminated
        if (params.isPairTerminatedEmergency || params.isPairTerminatedNormal) {
            revert CollateralLib__DepositsAreBlocked(params.isPairTerminatedEmergency, params.isPairTerminatedNormal);
        }

        // Block deposits if pair is past scheduled termination
        if (params.scheduledTerminationTs != 0 && block.timestamp > params.scheduledTerminationTs) {
            revert CollateralLib__PairScheduledForTermination();
        }

        // Validate minimum deposit
        if (params.amount < MIN_COLLATERAL_AMOUNT) {
            revert CollateralLib__InvalidDepositAmount(params.amount, MIN_COLLATERAL_AMOUNT);
        }

        BazaarTypes.PositionBucket storage positionBucket = positionBuckets[caller];

        positionBucket.collateral += params.amount;

        BucketLib.emitBucketUpdate(caller, positionBucket, params.currentFundingIndex, params.marginReqs, params.pairId);

        emit BazaarTypes.CollateralDeposited(params.pairId, caller, params.amount);
    }

    // ================================================================
    //                        Withdraw Logic
    // ================================================================

    /// @notice Processes withdraw collateral logic: validates, handles all termination states, updates bucket.
    /// @dev Called via DELEGATECALL from BazaarPair. Does NOT handle USDC transfer or ETH refund.
    function withdrawCollateral(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => bool) storage terminalHaircutApplied,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.CollateralWithdrawParams memory params,
        address caller
    ) external returns (BazaarTypes.CollateralWithdrawResult memory result) {
        if (params.amount == 0) revert CollateralLib__ZeroWithdrawalAmount();

        if (params.pendingTermination) {
            revert CollateralLib__PairScheduledForTermination();
        }

        // ------------------------------------------------------------------
        // Emergency Termination: users withdraw original collateral (no PnL)
        // ------------------------------------------------------------------
        if (params.isPairTerminatedEmergency) {
            BazaarTypes.PositionBucket storage suspendedBucket = positionBuckets[caller];

            // Apply haircut once per user if ratio < 100%
            if (
                params.emergencyHaircutBp < BazaarTypes.BP_SCALE && !terminalHaircutApplied[caller]
                    && suspendedBucket.collateral > 0
            ) {
                terminalHaircutApplied[caller] = true;
                uint256 adjustedCollateral =
                    Math.mulDiv(suspendedBucket.collateral, params.emergencyHaircutBp, BazaarTypes.BP_SCALE);
                pairVault.totalCollateralDeposited -= (suspendedBucket.collateral - adjustedCollateral);
                suspendedBucket.collateral = adjustedCollateral;
            }

            if (params.amount > suspendedBucket.collateral) {
                revert CollateralLib__InsufficientCollateral(params.amount, suspendedBucket.collateral);
            }

            suspendedBucket.collateral -= params.amount;
            BucketLib.emitBucketUpdate(
                caller, suspendedBucket, params.currentFundingIndex, params.marginReqs, params.pairId
            );

            pairVault.totalCollateralDeposited -= params.amount;

            result.withdrawAmount = params.amount;
            result.totalCollateralDecrease = params.amount;
            emit BazaarTypes.CollateralWithdrawn(params.pairId, caller, result.withdrawAmount, result.positionClosed);
            return result;
        }

        // ------------------------------------------------------------------
        // Normal Termination: settle position at terminal price, then withdraw
        // ------------------------------------------------------------------
        if (params.isPairTerminatedNormal && params.normalTerminationPrice > 0) {
            BazaarTypes.PositionBucket storage termBucket = positionBuckets[caller];

            // If user has an open position, realize PnL at terminal price (once)
            if (termBucket.size > 0) {
                BazaarTypes.BucketState memory state = BucketLib.calculateState(
                    termBucket, params.normalTerminationPrice, params.currentFundingIndex, params.marginReqs
                );

                int256 totalPnl = state.totalPnl;

                if (totalPnl > 0) {
                    // Winner: apply payout ratio haircut
                    uint256 adjustedPnl =
                        Math.mulDiv(uint256(totalPnl), params.normalTerminalWinnersPayoutRatioBp, BazaarTypes.BP_SCALE);
                    termBucket.collateral += adjustedPnl;
                } else if (totalPnl < 0) {
                    // Loser: deduct loss from collateral (floor at 0)
                    uint256 loss = uint256(-totalPnl);
                    termBucket.collateral = termBucket.collateral > loss ? termBucket.collateral - loss : 0;
                }

                // Record closed position info for vault OI updates by caller
                result.positionClosed = true;
                result.isLong = termBucket.isLong;
                result.closedSize = termBucket.size;
                result.closedEntryValue = termBucket.entryValue;

                // Zero out position (keep collateral)
                termBucket.size = 0;
                termBucket.entryValue = 0;
                termBucket.entryFundingIndex = 0;
                termBucket.entryMmrBp = 0;
                termBucket.mmrUpdateTs = 0;
                BucketLib.emitBucketUpdate(
                    caller, termBucket, params.currentFundingIndex, params.marginReqs, params.pairId
                );
            }

            // Rung-4 principal haircut: in deep insolvency the winning side's PnL was fully wiped
            // and a shortfall still remained, so TerminationLib set a sub-100% collateral ratio.
            // Apply it once per user (flat users included) so cumulative principal payouts cannot
            // exceed the USDC on hand. The once-flag (terminalHaircutApplied) is shared with the
            // emergency haircut; a pair is only ever emergency XOR normal terminated, so no collision.
            // NOTE: the guard is `< BP_SCALE`, NOT `> 0 && < BP_SCALE`. Every normal termination
            // sets this ratio (BP_SCALE = no haircut, anything below = a real haircut), so a value
            // of exactly 0 is a *legitimately computed* near-total-wipeout (pot < 0.01% of the book),
            // NOT the unset default. Treating 0 as "skip" would re-open the first-come-first-served
            // drain this haircut exists to prevent. A 0 ratio correctly zeroes every payout (the
            // sub-bp dust stays stranded in the contract rather than draining to early withdrawers).
            if (
                params.normalTerminalCollateralRatioBp < BazaarTypes.BP_SCALE && !terminalHaircutApplied[caller]
                    && termBucket.collateral > 0
            ) {
                terminalHaircutApplied[caller] = true;
                uint256 adjustedCollateral =
                    Math.mulDiv(termBucket.collateral, params.normalTerminalCollateralRatioBp, BazaarTypes.BP_SCALE);
                pairVault.totalCollateralDeposited -= (termBucket.collateral - adjustedCollateral);
                termBucket.collateral = adjustedCollateral;
            }

            if (params.amount > termBucket.collateral) {
                revert CollateralLib__InsufficientCollateral(params.amount, termBucket.collateral);
            }

            termBucket.collateral -= params.amount;
            BucketLib.emitBucketUpdate(caller, termBucket, params.currentFundingIndex, params.marginReqs, params.pairId);

            pairVault.totalCollateralDeposited -= params.amount;

            result.withdrawAmount = params.amount;
            result.totalCollateralDecrease = params.amount;
            emit BazaarTypes.CollateralWithdrawn(params.pairId, caller, result.withdrawAmount, result.positionClosed);
            return result;
        }

        // ------------------------------------------------------------------
        // Normal Operation: position-aware withdrawal with margin checks
        // ------------------------------------------------------------------
        BazaarTypes.PositionBucket memory bucket = positionBuckets[caller];

        bool exposurePresent = bucket.size != 0;

        if (exposurePresent) {
            // Price update is required when there's exposure
            // (caller must have already obtained currentPrice from oracle)
            if (params.currentPrice == 0) {
                revert CollateralLib__NoPriceUpdateDataProvided();
            }

            // Defensive backstop: if isVaultHealthy reported an unhealthy result this tx, block a
            // normal-operation withdrawal from slipping through. Reason 2 (ADL timeout) now
            // normal-terminates and reason 3 (USDC shortfall) emergency-terminates — both set a
            // termination flag that routes withdrawals to the terminal branches above, so reaching
            // here with reason 2/3 should not happen; this guard ensures it can't.
            if (!params.isVaultHealthy && (params.vaultHealthReason == 2 || params.vaultHealthReason == 3)) {
                revert CollateralLib__WithdrawalBlockedDueToEmergencyTermination();
            }

            // Reason 1 = the ADL window is open — possibly opened by the isVaultHealthy call
            // in THIS tx, after the pair-level freeze guard was already evaluated (it reads
            // isAdlPending before the health check can set it). Blocking here closes the
            // one-withdrawal gap in the window-opening transaction. Flat users are exempt by
            // placement: this branch only runs when the caller holds a position.
            if (!params.isVaultHealthy && params.vaultHealthReason == 1) {
                revert CollateralLib__WithdrawalsFrozenAdlPending();
            }

            // Calculate current bucket state
            BazaarTypes.BucketState memory currentState =
                BucketLib.calculateState(bucket, params.currentPrice, params.currentFundingIndex, params.marginReqs);

            // Revert if position is insolvent
            if (!currentState.isSolvent) {
                revert CollateralLib__InsolventPositionBucket(
                    currentState.availableEquity, currentState.minRequiredCollateral
                );
            }

            // Ensure withdrawal amount doesn't exceed effective collateral
            if (params.amount > currentState.effectiveCollateral) {
                revert CollateralLib__InsufficientCollateral(params.amount, currentState.effectiveCollateral);
            }

            // Check IMR requirement (2x during stale oracle periods)
            uint256 effectiveImrBp = params.marginReqs.imrBp;
            if (params.isOracleStale) {
                effectiveImrBp = effectiveImrBp * STALE_MARGIN_MULTIPLIER;
            }
            // Worst-case directional exposure: position + same-dir orders, or opposite-dir orders overshooting
            uint256 worstCaseNotional;
            {
                bool posIsLong = bucket.isLong;
                uint256 posNotional = currentState.currentNotional;
                uint256 sameDirExposure =
                    posIsLong ? params.outstandingLongOrderExposure : params.outstandingShortOrderExposure;
                uint256 oppDirExposure =
                    posIsLong ? params.outstandingShortOrderExposure : params.outstandingLongOrderExposure;
                uint256 worstSameDir = posNotional + sameDirExposure;
                uint256 worstFlip = oppDirExposure > posNotional ? oppDirExposure - posNotional : 0;
                worstCaseNotional = worstSameDir > worstFlip ? worstSameDir : worstFlip;
            }
            uint256 imrRequirement = Math.mulDiv(effectiveImrBp, worstCaseNotional, BazaarTypes.BP_SCALE);
            if (currentState.availableEquity < imrRequirement + params.amount) {
                revert CollateralLib__InsufficientMarginAfterWithdrawal(params.amount, imrRequirement);
            }

            // Update collateral to reflect withdrawal
            currentState.effectiveCollateral = currentState.effectiveCollateral - params.amount;

            // Update bucket from state
            BazaarTypes.PositionBucket storage storageBucket = positionBuckets[caller];
            BucketLib.updateFromState(storageBucket, currentState);
            BucketLib.emitBucketUpdate(
                caller, storageBucket, params.currentFundingIndex, params.marginReqs, params.pairId
            );

            pairVault.totalCollateralDeposited -= params.amount;

            result.withdrawAmount = params.amount;
            result.totalCollateralDecrease = params.amount;
            emit BazaarTypes.CollateralWithdrawn(params.pairId, caller, result.withdrawAmount, result.positionClosed);
            return result;
        }

        // ------------------------------------------------------------------
        // No position exposure: collateral withdrawal with order margin check
        // ------------------------------------------------------------------
        if (bucket.collateral < params.amount) {
            revert CollateralLib__InsufficientCollateral(params.amount, bucket.collateral);
        }

        // If user has outstanding limit orders, ensure enough margin remains
        // No position → worst case is max(longOrders, shortOrders)
        {
            uint256 maxOrderExposure = params.outstandingLongOrderExposure > params.outstandingShortOrderExposure
                ? params.outstandingLongOrderExposure
                : params.outstandingShortOrderExposure;
            if (maxOrderExposure > 0) {
                uint256 effectiveImrBp = params.marginReqs.imrBp;
                if (params.isOracleStale) {
                    effectiveImrBp = effectiveImrBp * STALE_MARGIN_MULTIPLIER;
                }
                uint256 orderImrReq = Math.mulDiv(effectiveImrBp, maxOrderExposure, BazaarTypes.BP_SCALE);
                if (bucket.collateral - params.amount < orderImrReq) {
                    revert CollateralLib__InsufficientMarginAfterWithdrawal(params.amount, orderImrReq);
                }
            }
        }

        // Persist updated collateral (keep same position fields)
        BazaarTypes.PositionBucket storage noExpBucket = positionBuckets[caller];
        noExpBucket.collateral = bucket.collateral - params.amount;
        BucketLib.emitBucketUpdate(caller, noExpBucket, params.currentFundingIndex, params.marginReqs, params.pairId);

        pairVault.totalCollateralDeposited -= params.amount;
        result.withdrawAmount = params.amount;
        result.totalCollateralDecrease = params.amount;
        emit BazaarTypes.CollateralWithdrawn(params.pairId, caller, result.withdrawAmount, result.positionClosed);
    }
}
