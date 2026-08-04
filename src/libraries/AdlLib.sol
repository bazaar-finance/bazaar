// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BucketLib} from "./BucketLib.sol";
import {VaultHealthLib} from "./VaultHealthLib.sol";

/// @title AdlLib
/// @notice External library for Auto-Deleveraging (ADL) logic. Runs via DELEGATECALL with BazaarPair storage.
///         Uses O(1) aggregate decrement instead of O(n) FIFO queue popping.
///         Settlement price = avgBP = pendingLiqBankruptcyNotional / pendingLiqSize.
library AdlLib {
    // -------------------- Constants --------------------

    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 internal constant BP_SCALE = BazaarTypes.BP_SCALE;

    uint256 internal constant MAX_ADL_WINNERS_PER_BATCH = 25;
    uint256 internal constant ADL_AUCTION_DURATION = BazaarTypes.ADL_AUCTION_DURATION;

    // -------------------- Errors --------------------

    error AdlLib__EmptySubmission();
    error AdlLib__TooManyWinners(uint256 count, uint256 max);
    error AdlLib__NoPendingLiquidations();
    error AdlLib__NoEligibleWinners();
    error AdlLib__NotDescendingAdlScoreOrder(uint256 adlScore, uint256 prevScore);

    // -------------------- Events --------------------

    event UserAdld(
        bytes32 indexed pairId,
        address indexed user,
        bool isLong,
        uint256 closedSize,
        int256 realizedPnl,
        uint256 remainingCollateral,
        uint256 adlScore,
        uint256 adlSettlementPrice
    );

    /// @dev Emitted here (via DELEGATECALL, so the log's emitter is the BazaarPair) rather than
    ///      from BazaarPair, to keep the pair under the EIP-170 code-size limit. BazaarPair also
    ///      declares this event so it stays in the pair's ABI. Mirrors the UserAdld pattern.
    event AdlExecuted(
        bytes32 indexed pairId,
        uint256 indexed adlId,
        bool adlLongs,
        address indexed submitter,
        uint256 highestBankruptcyPrice,
        uint256 lowestBankruptcyPrice,
        uint256 highestAdlScore,
        uint256 lowestAdlScore,
        uint256 adlSnapshotPrice,
        uint256 timestamp
    );

    // -------------------- External Functions --------------------

    /// @notice Core ADL execution: scan winners, close them at avg bankruptcy price, decrement aggregate
    /// @dev Called via DELEGATECALL from BazaarPair.executeAdl. Does NOT call isVaultHealthy or _sendUsdc;
    ///      BazaarPair handles reward transfers and vault health re-evaluation after this returns.
    function executeAdlCore(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        address[] calldata winners,
        BazaarTypes.AdlParams memory params,
        uint64 adlEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    ) external returns (BazaarTypes.AdlResult memory r) {
        if (winners.length == 0) revert AdlLib__EmptySubmission();
        if (winners.length > MAX_ADL_WINNERS_PER_BATCH) {
            revert AdlLib__TooManyWinners(winners.length, MAX_ADL_WINNERS_PER_BATCH);
        }
        if (pairVault.pendingLiqSize == 0) revert AdlLib__NoPendingLiquidations();

        uint256 pendingLiqSize = pairVault.pendingLiqSize;

        // Compute settlement price from aggregate: avgBP = bankruptcyNotional / size
        uint256 settlementPrice = Math.mulDiv(pairVault.pendingLiqBankruptcyNotional, BAZAAR_SCALE, pendingLiqSize);
        r.settlementPrice = settlementPrice;

        // Pass 1: Scan eligible winners (read-only)
        (r.eligibleSize, r.eligibleCount, r.highestAdlScore, r.lowestAdlScore) = _scanEligibleWinners(
            positionBuckets, winners, params, pendingLiqSize, adlEpoch, adlDepositEpoch, adlWindowDeposits
        );
        if (r.eligibleSize == 0) revert AdlLib__NoEligibleWinners();

        // Cap how much we attempt to close at the smaller of eligible-winner size and
        // pending liq. The actual closed amount may be less if the mid-batch health check
        // breaks the loop early.
        uint256 effectiveSize = r.eligibleSize < pendingLiqSize ? r.eligibleSize : pendingLiqSize;

        // Pass 2 decrements pairVault.pendingLiq* inside the loop and returns the actual
        // total it closed (which equals effectiveSize unless the early-break fired).
        r.totalLiqSize = _closeAdlWinners(
            orders,
            positionBuckets,
            pairVault,
            winners,
            params,
            effectiveSize,
            settlementPrice,
            adlEpoch,
            adlDepositEpoch,
            adlWindowDeposits
        );

        // Summary event. High/low bankruptcy price are the single avg settlement price (the vault
        // closes the whole aggregate at avgBP). msg.sender/block.timestamp are the DELEGATECALL
        // context — the keeper and the execution block, same as if BazaarPair emitted it.
        emit AdlExecuted(
            params.pairId,
            params.adlId,
            params.adlLongs,
            msg.sender,
            settlementPrice,
            settlementPrice,
            r.highestAdlScore,
            r.lowestAdlScore,
            params.adlSnapshotPrice,
            block.timestamp
        );
    }

    /// @dev Collateral used for ADL RANKING only: deposits epoch-tagged to the CURRENT window
    ///      are subtracted, so the score reflects the book as of the window's start — a
    ///      mid-auction top-up cannot re-rank the queue. Settlement and liquidation protection
    ///      use real collateral; only queue position is frozen. A tag from an older window fails
    ///      the epoch check and subtracts nothing (lazy invalidation — those deposits are
    ///      ordinary standing collateral by now).
    function _scoreCollateral(
        uint256 effectiveCollateral,
        address user,
        uint64 adlEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    ) private view returns (uint256) {
        uint256 wd = adlDepositEpoch[user] == adlEpoch ? adlWindowDeposits[user] : 0;
        return _scoreCollateral(effectiveCollateral, wd);
    }

    /// @notice Ranking-collateral core: window deposit subtracted, floored at 1 wei. Shared with
    ///         BazaarPairLens so off-chain score previews use the exact on-chain arithmetic.
    /// @dev The 1-wei floor makes a zero-(pre-window-)collateral winner a pure-profit claim that
    ///      ranks effectively infinite, FRONT of the queue. It doubles as the div-by-zero guard
    ///      for the score; skipping such accounts instead would make withdraw-everything winners
    ///      ADL-immune, the exact accounts ADL most needs to close. Settlement is unaffected:
    ///      their credit is totalPnl on their real, possibly zero, collateral.
    /// @param effectiveCollateral The bucket's collateral at the ranking snapshot
    /// @param windowDeposit The already-epoch-checked deposit tagged to the current ADL window
    /// @return The collateral denominator used in the ADL score
    function _scoreCollateral(uint256 effectiveCollateral, uint256 windowDeposit) internal pure returns (uint256) {
        uint256 base = effectiveCollateral > windowDeposit ? effectiveCollateral - windowDeposit : 0;
        return base == 0 ? 1 : base;
    }

    // -------------------- Internal Helpers --------------------

    /// @notice Computes the ADL auction score threshold (quadratic decay)
    function _getAdlScoreThreshold(uint256 adlPendingSince) internal view returns (uint256) {
        if (adlPendingSince == 0) return type(uint256).max;
        uint256 elapsed = block.timestamp - adlPendingSince;
        uint256 maxScore = BazaarTypes.ADL_MAX_SCORE;
        if (elapsed >= ADL_AUCTION_DURATION) return 1;
        uint256 remaining = ADL_AUCTION_DURATION - elapsed;
        return 1 + maxScore * remaining * remaining / (ADL_AUCTION_DURATION * ADL_AUCTION_DURATION);
    }

    /// @notice Pass 1: Read-only scan of winners to determine eligible size and scores
    function _scanEligibleWinners(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        address[] calldata winners,
        BazaarTypes.AdlParams memory params,
        uint256 maxSize,
        uint64 adlEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    )
        internal
        view
        returns (uint256 eligibleSize, uint256 eligibleCount, uint256 highestAdlScore, uint256 lowestAdlScore)
    {
        uint256 prevScore = type(uint256).max;
        uint256 threshold = _getAdlScoreThreshold(params.adlPendingSince);

        for (uint256 i = 0; i < winners.length; i++) {
            if (eligibleSize >= maxSize) break;

            address user = winners[i];
            BazaarTypes.PositionBucket storage bucket = positionBuckets[user];

            if (bucket.size == 0) continue;
            if (bucket.isLong != params.adlLongs) continue;

            // Rank against the FROZEN snapshot funding index (paired with adlSnapshotPrice), not
            // the live index. This keeps adlScore — and therefore the descending-order check
            // below — deterministic between the keeper's off-chain sort and on-chain execution.
            BazaarTypes.BucketState memory state = BucketLib.calculateState(
                bucket, params.adlSnapshotPrice, params.adlSnapshotFundingIndex, params.marginRequirements
            );
            if (state.totalPnl <= 0) continue;

            uint256 adlScore = Math.mulDiv(
                uint256(state.totalPnl),
                BAZAAR_SCALE,
                _scoreCollateral(state.effectiveCollateral, user, adlEpoch, adlDepositEpoch, adlWindowDeposits)
            );
            if (adlScore < threshold) continue;

            if (adlScore > prevScore) revert AdlLib__NotDescendingAdlScoreOrder(adlScore, prevScore);
            prevScore = adlScore;

            if (eligibleCount == 0) highestAdlScore = adlScore;
            lowestAdlScore = adlScore;

            uint256 winnerSize = state.adjustedSize;
            uint256 remaining = maxSize - eligibleSize;
            eligibleSize += winnerSize < remaining ? winnerSize : remaining;
            eligibleCount++;
        }
    }

    /// @notice Pass 2: Close eligible winners at the settlement price
    function _closeAdlWinners(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        address[] calldata winners,
        BazaarTypes.AdlParams memory params,
        uint256 requiredSize,
        uint256 settlementPrice,
        uint64 adlEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    ) internal returns (uint256 totalClosed) {
        uint256 threshold = _getAdlScoreThreshold(params.adlPendingSince);
        uint256 closedCount = 0;

        for (uint256 i = 0; i < winners.length; i++) {
            if (totalClosed >= requiredSize) break;

            // Before every close after the first, stop if the book has already healed: each close
            // shrinks the pendingLiq exposure (decremented at the bottom of this loop), so health
            // can be restored mid-batch and any further close would deleverage a winner for
            // nothing. The first close needs no check — executeAdl's entry health gate just
            // confirmed the vault unhealthy at the live price.
            if (closedCount > 0) {
                VaultHealthLib.LiqExposureResult memory healthResult = VaultHealthLib.checkLiqExposure(
                    pairVault,
                    params.currentPrice,
                    true,
                    params.adlPendingSince,
                    params.adlSnapshotPrice,
                    params.adlLongs,
                    params.currentFundingIndex,
                    params.adlSnapshotFundingIndex
                );
                if (healthResult.healthy) break;
            }

            address user = winners[i];
            BazaarTypes.PositionBucket storage bucket = positionBuckets[user];

            if (bucket.size == 0) continue;
            if (bucket.isLong != params.adlLongs) continue;

            // Eligibility ranking uses the FROZEN snapshot funding index, matching the scan pass
            // so both agree on which winners are eligible and on eligibleSize.
            BazaarTypes.BucketState memory rankingState = BucketLib.calculateState(
                bucket, params.adlSnapshotPrice, params.adlSnapshotFundingIndex, params.marginRequirements
            );
            if (rankingState.totalPnl <= 0) continue;

            uint256 adlScore = Math.mulDiv(
                uint256(rankingState.totalPnl),
                BAZAAR_SCALE,
                _scoreCollateral(rankingState.effectiveCollateral, user, adlEpoch, adlDepositEpoch, adlWindowDeposits)
            );
            if (adlScore < threshold) continue;

            // Settlement realizes at the live funding index (and the bankruptcy settlement price),
            // so the winner's credit reflects funding actually accrued up to execution.
            BazaarTypes.BucketState memory state = BucketLib.calculateState(
                bucket, settlementPrice, params.currentFundingIndex, params.marginRequirements
            );

            // Eligibility ranked PnL at the snapshot price; the credit realizes it at the
            // settlement (bankruptcy) price. A winner deleveraged at/above their entry settles
            // at zero PnL — a valid break-even close. Only skip a strictly-negative settlement
            // PnL: don't force a market-profitable trader into a realized loss, and never feed
            // a negative into the uint256 cast below.
            if (state.totalPnl < 0) continue;

            uint256 remaining = requiredSize - totalClosed;
            uint256 closedSize;

            if (state.adjustedSize <= remaining) {
                // Full close
                closedSize = state.adjustedSize;
                totalClosed += closedSize;
                _applyAdlVaultUpdate(pairVault, params.adlLongs, closedSize, state.entryValue);
                uint256 pnl = _fundWinnerPnl(pairVault, uint256(state.totalPnl));
                bucket.collateral = state.effectiveCollateral + pnl;
                emit UserAdld(
                    params.pairId,
                    user,
                    params.adlLongs,
                    closedSize,
                    int256(pnl),
                    bucket.collateral,
                    adlScore,
                    settlementPrice
                );
                _resetBucket(orders, user, bucket, params);
            } else {
                // Partial close
                closedSize = remaining;
                totalClosed += closedSize;
                uint256 partialEntry = Math.mulDiv(state.entryValue, closedSize, state.adjustedSize);
                _applyAdlVaultUpdate(pairVault, params.adlLongs, closedSize, partialEntry);
                {
                    uint256 partialPnl =
                        _fundWinnerPnl(pairVault, Math.mulDiv(uint256(state.totalPnl), closedSize, state.adjustedSize));
                    bucket.collateral = state.effectiveCollateral + partialPnl;
                    bucket.size -= closedSize;
                    bucket.entryValue -= partialEntry;
                    BucketLib.emitBucketUpdate(
                        user, bucket, params.currentFundingIndex, params.marginRequirements, params.pairId
                    );
                    emit UserAdld(
                        params.pairId,
                        user,
                        params.adlLongs,
                        closedSize,
                        int256(partialPnl),
                        bucket.collateral,
                        adlScore,
                        settlementPrice
                    );
                }
            }

            // NOTE: no explicit funding entry here, deliberately. ADL funding settles entirely
            // through the two existing channels: the estates' pre-liquidation funding is embedded
            // in the bankruptcy-derived settlement price (a funding-rich estate lowers avgBP,
            // reaching the winner via the price leg), and the winner's own funding tab is netted
            // inside their totalPnl credit — paying a tab means receiving less, which is
            // insurance collecting it. Adding a separate insurance entry for the inventory's
            // funding double-books a transfer these channels already settle. (Pass A is
            // different: it settles vs entryNotional at a market price — neither channel exists
            // there, so _settleVaultLiquidation's explicit funding term is required.)

            // Decrement aggregate pendingLiq state proportionally so the next iteration's
            // health check sees up-to-date exposure. Uses current pendingLiqSize as divisor
            // so the bk-per-unit ratio is preserved across decrements.
            {
                uint256 entryPortion =
                    Math.mulDiv(pairVault.pendingLiqEntryNotional, closedSize, pairVault.pendingLiqSize);
                uint256 bkPortion =
                    Math.mulDiv(pairVault.pendingLiqBankruptcyNotional, closedSize, pairVault.pendingLiqSize);
                pairVault.pendingLiqSize -= closedSize;
                pairVault.pendingLiqEntryNotional -= entryPortion;
                pairVault.pendingLiqBankruptcyNotional -= bkPortion;
            }
            closedCount++;
        }
    }

    /// @notice Funds an ADL'd winner's realized PnL from insurance and tracks it as collateral.
    /// @dev The winner's counterparty is the vault, whose backing is the bankrupt side's seized
    ///      collateral held in insuranceFundBalance. The credit is CAPPED at the available
    ///      insurance: we debit `min(pnl, insurance)` and credit totalCollateralDeposited by the
    ///      same amount, so both `insurance + totalCollateralDeposited` and
    ///      `totalCollateralDeposited == Σ bucket.collateral` stay exact — the books remain
    ///      solvent and no emergency termination is triggered. In the insolvency tail (bad debt
    ///      exceeds the fund) the winner is haircut to what insurance can pay; the position is
    ///      still fully closed regardless. Winners are processed in ADL-score order, so when
    ///      insurance runs out mid-batch the haircut falls on the lowest-score winners.
    /// @return funded The amount actually credited to the winner's bucket.collateral.
    function _fundWinnerPnl(BazaarTypes.Vault storage pairVault, uint256 pnl) internal returns (uint256) {
        uint256 funded = pnl < pairVault.insuranceFundBalance ? pnl : pairVault.insuranceFundBalance;
        pairVault.insuranceFundBalance -= funded;
        pairVault.totalCollateralDeposited += funded;
        return funded;
    }

    /// @notice Updates vault OI tracking after closing an ADL'd position
    function _applyAdlVaultUpdate(BazaarTypes.Vault storage pairVault, bool adlLongs, uint256 size, uint256 entryValue)
        internal
    {
        if (adlLongs) {
            pairVault.totalLongOI -= size;
            pairVault.longWeightedEntrySum -= entryValue;
        } else {
            pairVault.totalShortOI -= size;
            pairVault.shortWeightedEntrySum -= entryValue;
        }
    }

    /// @notice Resets a user's position bucket after full ADL close (cancels TP/SL/Market, zeros position fields)
    function _resetBucket(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        address user,
        BazaarTypes.PositionBucket storage bucket,
        BazaarTypes.AdlParams memory params
    ) internal {
        // Cancel active TP/SL/Market orders
        if (bucket.takeProfitOrderId != 0) {
            BazaarTypes.Order storage tpOrder = orders[bucket.takeProfitOrderId];
            if (tpOrder.canceledBlock == 0 && tpOrder.filledBlock == 0) {
                tpOrder.canceledBlock = params.currentBlock;
            }
        }
        if (bucket.stopLossOrderId != 0) {
            BazaarTypes.Order storage slOrder = orders[bucket.stopLossOrderId];
            if (slOrder.canceledBlock == 0 && slOrder.filledBlock == 0) {
                slOrder.canceledBlock = params.currentBlock;
            }
        }
        if (bucket.activeMarketOrderId != 0) {
            BazaarTypes.Order storage mktOrder = orders[bucket.activeMarketOrderId];
            if (mktOrder.canceledBlock == 0 && mktOrder.filledBlock == 0) {
                mktOrder.canceledBlock = params.currentBlock;
            }
        }

        bucket.size = 0;
        bucket.entryValue = 0;
        bucket.entryFundingIndex = 0;
        bucket.takeProfitOrderId = 0;
        bucket.stopLossOrderId = 0;
        bucket.activeMarketOrderId = 0;
        bucket.entryMmrBp = 0; // keep the "flat => no MMR grandfather" invariant
        bucket.mmrUpdateTs = 0; // and the "0 when flat" grace-clock invariant
        // Note: collateral is NOT reset (already updated by caller with PnL)

        BucketLib.emitBucketUpdate(user, bucket, params.currentFundingIndex, params.marginRequirements, params.pairId);
    }
}
