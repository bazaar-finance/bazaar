// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BucketLib} from "./BucketLib.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";

/// @title LiquidationLib
/// @notice External library for liquidation processing logic.
///         Runs via DELEGATECALL — has direct access to BazaarPair storage.
///         Liquidated positions are aggregated into the Vault's pending liquidation fields
///         rather than creating individual orders. Opposing liquidations are netted at oracle price.
library LiquidationLib {
    // -------------------- Constants --------------------

    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 internal constant MIN_LIQUIDATOR_REWARD = BazaarTypes.MIN_LIQUIDATOR_REWARD; // 0.10 USDC reward floor

    // -------------------- Events --------------------

    event PositionLiquidated(
        bytes32 indexed pairId,
        address indexed liquidatedUser,
        address indexed liquidator,
        uint256 size,
        bool isLong,
        uint256 bankruptcyPrice,
        uint256 triggerPrice,
        uint256 collateralSeized,
        uint256 timestamp
    );

    // -------------------- External --------------------

    /// @notice Processes liquidations for a list of users
    /// @dev Iterates through users, checks solvency, and aggregates liquidated positions into
    ///      the vault's pending liquidation tracking. Opposing liquidations are netted immediately.
    ///      Caller is responsible for USDC transfer of totalUpfrontReward to the liquidator.
    ///      Reward per position = max(MIN_LIQUIDATOR_REWARD, LIQUIDATION_FEE_EBP of notional),
    ///      paid unconditionally at liquidation time (no profit-contingent component).
    function processLiquidations(
        address[] calldata usersToLiquidate,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.LiquidateParams memory params
    ) external returns (BazaarTypes.LiquidateResult memory result) {
        for (uint256 i = 0; i < usersToLiquidate.length; i++) {
            address userToLiquidate = usersToLiquidate[i];

            // Get bucket and check if position exists
            BazaarTypes.PositionBucket storage bucket = positionBuckets[userToLiquidate];
            if (bucket.size == 0) {
                continue; // Skip users with no position
            }

            // Use plain oracle price for solvency. Confidence-band polarity has no clean answer
            // for liquidation (user-favorable lets noise carry, protocol-eager risks false
            // liquidations). The 2% confidence-ratio cap at the oracle layer already pauses
            // pricing when uncertainty is too high; that's where conservatism belongs.
            // Matches Drift's pattern (plain oracle for maintenance margin / liquidation).
            BazaarTypes.BucketState memory state =
                BucketLib.calculateState(bucket, params.currentPrice, params.currentFundingIndex, params.marginReqs);

            // Check if position is underwater (not solvent)
            if (state.isSolvent) {
                continue; // Skip solvent positions
            }

            // Position is underwater - proceed with liquidation
            uint256 positionSize = state.adjustedSize;
            bool isLong = bucket.isLong;
            uint256 collateralToSeize = state.effectiveCollateral;

            // Calculate bankruptcy price (price where equity = 0)
            uint256 bankruptcyPrice = _calculateBankruptcyPrice(
                isLong, state.entryValue, state.effectiveCollateral, state.fundingPnl, positionSize
            );

            // Update vault aggregates - remove this position from OI
            if (isLong) {
                pairVault.totalLongOI = pairVault.totalLongOI > positionSize ? pairVault.totalLongOI - positionSize : 0;
                pairVault.longWeightedEntrySum = pairVault.longWeightedEntrySum > state.entryValue
                    ? pairVault.longWeightedEntrySum - state.entryValue
                    : 0;
            } else {
                pairVault.totalShortOI =
                    pairVault.totalShortOI > positionSize ? pairVault.totalShortOI - positionSize : 0;
                pairVault.shortWeightedEntrySum = pairVault.shortWeightedEntrySum > state.entryValue
                    ? pairVault.shortWeightedEntrySum - state.entryValue
                    : 0;
            }

            // Add collateral to insurance fund immediately
            pairVault.insuranceFundBalance += collateralToSeize;
            pairVault.totalCollateralDeposited -= collateralToSeize;

            // Reset the user's bucket
            _resetBucket(
                userToLiquidate,
                bucket,
                orders,
                params.currentFundingIndex,
                params.marginReqs,
                params.pairId,
                params.currentBlock
            );

            // Unconditional liquidator reward: max(floor, LIQUIDATION_FEE_EBP of notional),
            // paid now regardless of how the vault later closes the inherited position.
            // The floor covers gas on small positions; the bps term scales with size.
            uint256 notional = Math.mulDiv(positionSize, params.currentPrice, BAZAAR_SCALE);
            uint256 bpsReward = Math.mulDiv(notional, BazaarTypes.LIQUIDATION_FEE_EBP, BazaarTypes.EBP_SCALE);
            result.totalUpfrontReward += bpsReward > MIN_LIQUIDATOR_REWARD ? bpsReward : MIN_LIQUIDATOR_REWARD;

            // Aggregate into vault's pending liquidation tracking
            uint256 bankruptcyNotional = Math.mulDiv(positionSize, bankruptcyPrice, BAZAAR_SCALE);
            uint256 entryNotional = state.entryValue;

            // The aggregate's funding index is seeded/merged from the LIQUIDATEE'S ENTRY index,
            // not the liquidation-time index. The estate has no surviving owner, so its accrued
            // funding (entry → liquidation) must reach insurance or it vanishes while the
            // counterparties' offsetting side stays live — breaking funding zero-sum by exactly
            // state.fundingPnl per liquidation. Carrying the entry index forward makes the
            // settlement paths (Pass A close, opposing netting, ADL) realize funding over
            // entry → close in one signed term: the estate's pre-liquidation balance and the
            // funding accrued while the vault held the inventory settle together into insurance.
            if (pairVault.pendingLiqSize == 0) {
                // No existing aggregate — seed it
                pairVault.pendingLiqSize = positionSize;
                pairVault.pendingLiqEntryNotional = entryNotional;
                pairVault.pendingLiqBankruptcyNotional = bankruptcyNotional;
                pairVault.pendingLiqEntryFundingIndex = state.adjustedEntryFundingIndex;
                pairVault.pendingLiqIsLong = isLong;
            } else if (isLong == pairVault.pendingLiqIsLong) {
                // Same direction — add to aggregate
                uint256 newTotalSize = pairVault.pendingLiqSize + positionSize;
                pairVault.pendingLiqEntryFundingIndex =
                    (pairVault.pendingLiqEntryFundingIndex
                            * int256(pairVault.pendingLiqSize)
                            + state.adjustedEntryFundingIndex
                            * int256(positionSize)) / int256(newTotalSize);
                pairVault.pendingLiqSize = newTotalSize;
                pairVault.pendingLiqEntryNotional += entryNotional;
                pairVault.pendingLiqBankruptcyNotional += bankruptcyNotional;
            } else {
                // Opposite direction — net against existing aggregate
                _netOpposingLiquidation(
                    pairVault, positionSize, entryNotional, bankruptcyNotional, isLong, state.adjustedEntryFundingIndex
                );
            }

            emit PositionLiquidated(
                params.pairId,
                userToLiquidate,
                msg.sender,
                positionSize,
                isLong,
                bankruptcyPrice,
                params.currentPrice,
                collateralToSeize,
                block.timestamp
            );

            unchecked {
                ++result.liquidatedCount;
            }
        }

        // Pay the liquidator reward here rather than in BazaarPair (EIP-170 relief; DELEGATECALL
        // preserves msg.sender = caller and address(this) = pair). Debited from insurance so the
        // bookkeeping tracks the real USDC leaving the contract (Check-3 invariant); soft-fail
        // restores the debit — the liquidations themselves still commit. Skipped entirely when
        // the fund can't cover it (no partial payment).
        if (result.totalUpfrontReward > 0 && pairVault.insuranceFundBalance >= result.totalUpfrontReward) {
            pairVault.insuranceFundBalance -= result.totalUpfrontReward;
            if (!_trySendReward(params.usdc, msg.sender, result.totalUpfrontReward)) {
                pairVault.insuranceFundBalance += result.totalUpfrontReward;
            }
        }
    }

    /// @notice Soft-fail USDC transfer for the liquidator reward (mirrors BazaarPair's
    ///         _trySendUsdcReward). Returns false instead of reverting so an unreceivable
    ///         liquidator (blacklisted, reverting receiver) can never block liquidations.
    function _trySendReward(address usdc, address to, uint256 amountBazaarPrecision) internal returns (bool) {
        if (usdc == address(0) || to == address(0) || amountBazaarPrecision == 0) return false;
        uint256 usdcAmount = uint256(
            BazaarMathLib.convertExponent(
                int256(amountBazaarPrecision), BazaarTypes.BAZAAR_EXPONENT, BazaarTypes.USDC_EXPONENT
            )
        );
        if (usdcAmount == 0) return false;
        (bool callOk, bytes memory data) =
            usdc.call(
                abi.encodeWithSelector(0xa9059cbb, to, usdcAmount) // transfer(address,uint256)
            );
        if (!callOk) return false;
        if (data.length == 0) return true; // non-compliant token that doesn't return bool
        return abi.decode(data, (bool));
    }

    // -------------------- Internal --------------------

    /// @notice Nets an opposing liquidation against the existing vault aggregate
    /// @dev When a position is liquidated in the opposite direction to the existing aggregate,
    ///      the overlapping portion is settled immediately: the oracle cancels in the price leg
    ///      and the current funding index cancels in the funding leg, so settlement needs only
    ///      the two sides' entry-based values. Any remainder either reduces the existing
    ///      aggregate or flips the direction.
    function _netOpposingLiquidation(
        BazaarTypes.Vault storage pairVault,
        uint256 newSize,
        uint256 newEntryNotional,
        uint256 newBankruptcyNotional,
        bool newIsLong,
        int256 newEntryFundingIndex
    ) internal {
        uint256 existingSize = pairVault.pendingLiqSize;
        uint256 netSize = existingSize < newSize ? existingSize : newSize;

        // Compute proportional notionals for the netted portion
        uint256 existingEntryPortion = Math.mulDiv(pairVault.pendingLiqEntryNotional, netSize, existingSize);
        uint256 newEntryPortion = Math.mulDiv(newEntryNotional, netSize, newSize);

        // Net PnL: oracle cancels out in the formula
        // If existing is long (sold at oracle) and new is short (bought at oracle):
        //   longPnL = (oracle - existingEntry) * netSize  +  shortPnL = (newEntry - oracle) * netSize
        //   total = (newEntry - existingEntry) * netSize = newEntryPortion - existingEntryPortion
        int256 netPnl;
        if (pairVault.pendingLiqIsLong) {
            netPnl = int256(newEntryPortion) - int256(existingEntryPortion);
        } else {
            netPnl = int256(existingEntryPortion) - int256(newEntryPortion);
        }

        // Funding on the netted portion: both estates settle at the same instant, so the current
        // funding index cancels — the funding-leg twin of the oracle cancelling in the price leg
        // above. What survives is the offset between the two sides' entry clocks (each side's
        // index is its liquidatees' entry-weighted index), and that single term settles BOTH
        // sides' full entry → now funding lives into insurance; nothing is deferred or dropped.
        //   existing long / new short: −(cur − vaultIdx)·q + (cur − newIdx)·q = (vaultIdx − newIdx)·q
        // The index carries the price factor, so this is USD-denominated.
        int256 nettedFunding = BazaarMathLib.signedMulDiv(
            pairVault.pendingLiqEntryFundingIndex - newEntryFundingIndex, int256(netSize), int256(BAZAAR_SCALE)
        );
        netPnl += pairVault.pendingLiqIsLong ? nettedFunding : -nettedFunding;

        // Apply net PnL as an insurance <-> deposits-ledger TRANSFER (same rationale as the
        // Pass-A vaultPnl booking in MatchingEngineLib._finalize): the netted estates' PnL is
        // offset by the surviving counterparties' opposite unrealized PnL, which realizes into
        // their buckets and settles against the deposits ledger at their closes/withdrawals.
        // A one-sided entry would drift expectedBalance (I + D) away from actual USDC —
        // upward on profits (accumulating toward a false reason-3 termination), downward on
        // losses (underflowing late withdrawers). I + D is invariant under the transfer.
        if (netPnl >= 0) {
            uint256 gain = uint256(netPnl);
            uint256 take = gain < pairVault.totalCollateralDeposited ? gain : pairVault.totalCollateralDeposited;
            pairVault.totalCollateralDeposited -= take;
            pairVault.insuranceFundBalance += take;
        } else {
            uint256 loss = uint256(-netPnl);
            uint256 covered = loss < pairVault.insuranceFundBalance ? loss : pairVault.insuranceFundBalance;
            pairVault.insuranceFundBalance -= covered;
            pairVault.totalCollateralDeposited += covered;
            if (loss > covered) {
                // Uncovered overrun is unbacked bad debt; recorded as realized deficit so the
                // post-liquidation isVaultHealthy terminates the pair.
                pairVault.deficit += loss - covered;
            }
        }

        // Reduce existing aggregate proportionally
        uint256 existingBankruptcyPortion = Math.mulDiv(pairVault.pendingLiqBankruptcyNotional, netSize, existingSize);
        pairVault.pendingLiqSize -= netSize;
        pairVault.pendingLiqEntryNotional -= existingEntryPortion;
        pairVault.pendingLiqBankruptcyNotional -= existingBankruptcyPortion;

        // Handle remainder of the new liquidation
        uint256 remainingNewSize = newSize - netSize;
        if (remainingNewSize > 0 && pairVault.pendingLiqSize == 0) {
            // Existing fully netted — new side takes over
            uint256 remainingEntryNotional = Math.mulDiv(newEntryNotional, remainingNewSize, newSize);
            uint256 remainingBankruptcyNotional = Math.mulDiv(newBankruptcyNotional, remainingNewSize, newSize);
            pairVault.pendingLiqSize = remainingNewSize;
            pairVault.pendingLiqEntryNotional = remainingEntryNotional;
            pairVault.pendingLiqBankruptcyNotional = remainingBankruptcyNotional;
            pairVault.pendingLiqEntryFundingIndex = newEntryFundingIndex;
            pairVault.pendingLiqIsLong = newIsLong;
        }
        // If remainingNewSize == 0 or pairVault.pendingLiqSize > 0, the existing aggregate remains (reduced).
    }

    /// @notice Calculates the bankruptcy price (price at which equity becomes 0)
    /// @dev For longs: bankruptcyPrice = (entryValue - effectiveCollateral - fundingPnl) * BAZAAR_SCALE / size
    ///      For shorts: bankruptcyPrice = (entryValue + effectiveCollateral + fundingPnl) * BAZAAR_SCALE / size
    function _calculateBankruptcyPrice(
        bool isLong,
        uint256 entryValue,
        uint256 effectiveCollateral,
        int256 fundingPnl,
        uint256 size
    ) internal pure returns (uint256 bankruptcyPrice) {
        if (size == 0) return 0;

        if (isLong) {
            int256 numerator = int256(entryValue) - int256(effectiveCollateral) - fundingPnl;
            if (numerator <= 0) {
                return 0;
            }
            bankruptcyPrice = Math.mulDiv(uint256(numerator), BAZAAR_SCALE, size);
        } else {
            int256 numerator = int256(entryValue) + int256(effectiveCollateral) + fundingPnl;
            if (numerator <= 0) {
                return 0;
            }
            bankruptcyPrice = Math.mulDiv(uint256(numerator), BAZAAR_SCALE, size);
        }
    }

    /// @notice Resets a user's position bucket to zero state
    /// @dev Cancels any active TP/SL/Market orders and resets all position fields to zero.
    function _resetBucket(
        address user,
        BazaarTypes.PositionBucket storage bucket,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        int256 currentFundingIndex,
        BazaarTypes.MarginRequirements memory marginReqs,
        bytes32 pairId,
        uint64 currentBlock
    ) internal {
        // Cancel active TP/SL/Market orders for this user
        if (bucket.takeProfitOrderId != 0) {
            BazaarTypes.Order storage tpOrder = orders[bucket.takeProfitOrderId];
            if (tpOrder.canceledBlock == 0 && tpOrder.filledBlock == 0) {
                tpOrder.canceledBlock = currentBlock;
            }
        }
        if (bucket.stopLossOrderId != 0) {
            BazaarTypes.Order storage slOrder = orders[bucket.stopLossOrderId];
            if (slOrder.canceledBlock == 0 && slOrder.filledBlock == 0) {
                slOrder.canceledBlock = currentBlock;
            }
        }
        if (bucket.activeMarketOrderId != 0) {
            BazaarTypes.Order storage mktOrder = orders[bucket.activeMarketOrderId];
            if (mktOrder.canceledBlock == 0 && mktOrder.filledBlock == 0) {
                mktOrder.canceledBlock = currentBlock;
            }
        }

        // Reset bucket fields (always reset collateral during liquidation)
        bucket.size = 0;
        bucket.entryValue = 0;
        bucket.collateral = 0;
        bucket.entryFundingIndex = 0;
        bucket.takeProfitOrderId = 0;
        bucket.stopLossOrderId = 0;
        bucket.activeMarketOrderId = 0;
        bucket.entryMmrBp = 0; // keep the "flat => no MMR grandfather" invariant
        bucket.mmrUpdateTs = 0; // and the "0 when flat" grace-clock invariant

        BucketLib.emitBucketUpdate(user, bucket, currentFundingIndex, marginReqs, pairId);
    }
}
