// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BucketLib} from "./BucketLib.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";
import {OrderBookLib} from "./OrderBookLib.sol";

/// @title AdlLib
/// @notice External library for Auto-Deleveraging (ADL) logic. Runs via DELEGATECALL with BazaarPair storage.
///         Uses O(1) aggregate decrement instead of O(n) FIFO queue popping.
///         Settlement price = the estates' average bankruptcy price,
///         pendingLiqBankruptcyNotional / pendingLiqSize, or the mark when the mark sits on the
///         fund's favorable side of it.
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

    // -------------------- Structs --------------------

    /// @notice What one close pays and releases.
    /// @param credit The amount added to the winner's collateral
    /// @param withheld Funding income the fund could not back, see _settleInventorySlice
    /// @param sliceEntry The entry basis released from the winner's bucket and the OI aggregates
    struct SliceSettlement {
        uint256 credit;
        uint256 withheld;
        uint256 sliceEntry;
    }

    // -------------------- Events --------------------

    /// @notice Emitted for every winner an ADL batch closes, fully or in part.
    /// @param pairId The pair
    /// @param user The deleveraged winner
    /// @param isLong The winner's side
    /// @param closedSize The size closed against the vault's inventory
    /// @param realizedPnl The amount credited to the winner's collateral: PnL at the settlement
    ///        price with the live funding index, less `withheldFunding`
    /// @param remainingCollateral The winner's collateral after the credit
    /// @param adlScore The winner's score against the frozen snapshot
    /// @param adlSettlementPrice The price the close settled at: the estates' average bankruptcy
    ///        price, or the mark when the mark sat on the fund's favorable side of it
    /// @param withheldFunding Funding income the insurance fund could not back and therefore did
    ///        not pay; bounded by the winner's funding income on the closed size and by the credit
    event UserAdld(
        bytes32 indexed pairId,
        address indexed user,
        bool isLong,
        uint256 closedSize,
        int256 realizedPnl,
        uint256 remainingCollateral,
        uint256 adlScore,
        uint256 adlSettlementPrice,
        uint256 withheldFunding
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

    /// @notice Core ADL execution: scan winners, close them at the settlement price, decrement aggregate
    /// @dev Called via DELEGATECALL from BazaarPair.executeAdl. Does NOT call isVaultHealthy or _sendUsdc;
    ///      BazaarPair handles reward transfers and vault health re-evaluation after this returns.
    function executeAdlCore(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
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

        // The estates' average bankruptcy price is where the inventory realizes exactly the
        // collateral seized with it, so a close there is neutral to the fund whatever the
        // winner's own entry was. The window can outlive a recovery past that price: it
        // releases only once the fund could finish the remainder at the band edge, so a fund
        // at its reserve stays pending with the mark up to a band above it. Settling there at
        // the bankruptcy price would hand the winners a close better than the market at the
        // fund's expense, and executeAdl is permissionless with a caller-chosen winner list,
        // so the batch takes the mark whenever it sits on the fund's favorable side. The
        // reward then pays nothing, since no loss is averted.
        uint256 avgBankruptcyPrice = Math.mulDiv(pairVault.pendingLiqBankruptcyNotional, BAZAAR_SCALE, pendingLiqSize);
        uint256 settlementPrice = pairVault.pendingLiqIsLong
            ? Math.max(avgBankruptcyPrice, params.currentPrice)
            : Math.min(avgBankruptcyPrice, params.currentPrice);
        r.settlementPrice = settlementPrice;

        // Pass 1: Scan eligible winners (read-only)
        (r.eligibleSize, r.eligibleCount, r.highestAdlScore, r.lowestAdlScore) = _scanEligibleWinners(
            positionBuckets, winners, params, pendingLiqSize, adlEpoch, adlDepositEpoch, adlWindowDeposits
        );
        if (r.eligibleSize == 0) revert AdlLib__NoEligibleWinners();

        // Cap how much we attempt to close at the smaller of eligible-winner size and pending
        // liq, then at the size that actually restores health: a deleverage takes what the
        // exposure requires and no more. The cap holds for the whole batch, so the loop needs no
        // per-winner health re-check — its own `totalClosed >= requiredSize` break enforces it.
        uint256 effectiveSize = r.eligibleSize < pendingLiqSize ? r.eligibleSize : pendingLiqSize;
        uint256 restoringSize = _sizeToRestoreHealth(
            pairVault, params.currentPrice, params.currentFundingIndex, params.marginRequirements.mmrBp
        );
        if (restoringSize < effectiveSize) effectiveSize = restoringSize;

        // Pass 2 decrements pairVault.pendingLiq* inside the loop and returns the actual
        // total it closed (which equals effectiveSize unless the deficit break fired).
        r.totalLiqSize = _closeAdlWinners(
            orders,
            book,
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

        // Summary event. High/low bankruptcy price are both the batch's single settlement price
        // (the vault closes the whole aggregate at it). msg.sender/block.timestamp are the
        // DELEGATECALL context — the keeper and the execution block, same as if BazaarPair
        // emitted it.
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

    /// @dev Collateral used for ADL RANKING only: deposits epoch-tagged to the CURRENT ranking
    ///      epoch are subtracted, so the score reflects the book as of the moment this cohort came
    ///      into range — a top-up made while already in range cannot re-rank the queue. Settlement
    ///      and liquidation protection use real collateral; only queue position is frozen. A tag
    ///      from a superseded epoch subtracts nothing (lazy invalidation — those deposits are
    ///      ordinary standing collateral by now), which is also what keeps a mid-auction side flip
    ///      from charging the newly targeted side for deposits it made while defending against
    ///      liquidation instead.
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
    /// @dev Measured from the auction's current decay run rather than from the window's opening:
    ///      a market discontinuity restarts the run, because a threshold that descended while ADL
    ///      was unexecutable narrowed against attempts nobody could make.
    /// @param auctionStartTs Start of the current decay run; 0 when no auction is running, which
    ///        returns a threshold no score can reach
    /// @return The minimum ADL score a winner must carry to be eligible right now
    function _getAdlScoreThreshold(uint256 auctionStartTs) internal view returns (uint256) {
        if (auctionStartTs == 0) return type(uint256).max;
        uint256 elapsed = block.timestamp - auctionStartTs;
        uint256 maxScore = BazaarTypes.ADL_MAX_SCORE;
        if (elapsed >= ADL_AUCTION_DURATION) return 1;
        uint256 remaining = ADL_AUCTION_DURATION - elapsed;
        return 1 + maxScore * remaining * remaining / (ADL_AUCTION_DURATION * ADL_AUCTION_DURATION);
    }

    /// @notice The inventory size whose closure brings the vault back under the ADL cancel
    ///         threshold, or `type(uint256).max` when no size does.
    /// @dev Sizes the batch so a deleverage takes only what the exposure requires. Bounding by
    ///      winner count instead would let one account large enough to cover the aggregate absorb
    ///      all of it: every unit past this figure settles a solvent trader at the batch's
    ///      settlement price for no protective gain, and the executor reward — linear in the size
    ///      closed — pays for the excess.
    ///
    ///      The target is the gate's release condition: the fund's free capital above its reserve
    ///      must be able to finish the remaining inventory at the unload band's edge, so the walk
    ///      that resumes afterwards can sell it inside the band without reopening the window.
    ///      Closing one unit moves both sides of that comparison. The finish cost falls by its
    ///      per-unit share. Free capital above the reserve falls by two debits and rises by one
    ///      release:
    ///
    ///      - the unit's holding-window funding. The seizure released from the earmark is exactly
    ///        what funds the unit's settlement, so only the carry beyond it leaves the fund.
    ///      - the executor's share of the bad debt the unit averts. `BazaarPair.executeAdl` debits
    ///        it from the fund on this batch's own closed size, before the health re-evaluation
    ///        that ends the auction. Averted loss is the expected loss at the mark less the carry
    ///        — the same identity in both inventory directions.
    ///      - the reserve on the unit itself. A close removes the unit from the vault's side and
    ///        from the winner's, so per-side open interest falls by it and the reserve, a share
    ///        of the target on that open interest, falls with it: capital that returns to the
    ///        base without a dollar moving.
    ///
    ///      Progress per unit is the finish cost less both debits plus the release, and a batch
    ///      sized against the finish cost alone stops short: it lands on the release line, the
    ///      debits drop the line under it, and the auction is still pending when the batch that
    ///      should have ended it returns. Every leg is linear in `pendingLiqSize` under the
    ///      proportional decrement `_releaseSlice` applies, and none depends on which winner
    ///      takes the other side, so one figure holds for the whole batch. Per-unit terms are
    ///      multiplied out rather than divided, so the ratio rounds once.
    ///
    ///      A non-positive denominator means the two debits drain the fund at least as fast as
    ///      deleveraging repairs it, so no batch restores health: the auction runs to its eligible
    ///      size and the timeout or a recorded deficit resolves it.
    /// @param pairVault The pair's vault aggregates
    /// @param currentPrice The live mark the exposure is valued at
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param mmrBp The maintenance margin the unload band is derived from
    /// @return The size to close, 0 when the vault already meets the release condition
    function _sizeToRestoreHealth(
        BazaarTypes.Vault storage pairVault,
        uint256 currentPrice,
        int256 currentFundingIndex,
        uint256 mmrBp
    ) internal view returns (uint256) {
        (uint256 expectedLoss, uint256 base, uint256 worstFinish, uint256 shortfall) = RiskParamsLib.vaultAdlExposure(
            pairVault, currentPrice, currentFundingIndex, mmrBp
        );
        if (worstFinish <= base) return 0;

        uint256 pendingSize = pairVault.pendingLiqSize;
        int256 rawFunding = BazaarMathLib.signedMulDiv(
            currentFundingIndex - pairVault.pendingLiqEntryFundingIndex, int256(pendingSize), int256(BAZAAR_SCALE)
        );
        // Sign convention matches _releaseSlice: positive is funding the fund pays out on the
        // inventory it holds, which is the part of a slice's settlement the earmark cannot cover.
        int256 carry = pairVault.pendingLiqIsLong ? rawFunding : -rawFunding;
        int256 loss = SafeCast.toInt256(expectedLoss);
        // Matches executeAdl's own averted-loss test, which pays nothing once the mark has passed
        // the settlement price.
        int256 averted = loss > carry ? loss - carry : int256(0);

        // The reserve released with the inventory: ADL_RESERVE_BP of the cached target on the
        // inventory's own notional, the same figure RiskParamsLib.vaultAdlExposure charges per
        // unit of open interest.
        uint256 reserveReleased = Math.mulDiv(
            Math.mulDiv(pendingSize, currentPrice, BAZAAR_SCALE),
            pairVault.targetInsuranceRatioBp * BazaarTypes.ADL_RESERVE_BP,
            BP_SCALE * BP_SCALE
        );
        int256 denominator = SafeCast.toInt256(worstFinish) - carry
            - BazaarMathLib.signedMulDiv(averted, int256(BazaarTypes.ADL_EXECUTOR_REWARD_BP), int256(BP_SCALE))
            + SafeCast.toInt256(reserveReleased);
        if (denominator <= 0) return type(uint256).max;

        // With the fund below its reserve the base is floored at zero, and what the closed units
        // release has to fill that shortfall before any of it reaches the base: the distance to
        // cover is the finish cost plus the shortfall, not the finish cost alone. Round up:
        // landing a fraction of a unit short leaves the auction pending for a second call that
        // closes dust.
        return Math.mulDiv(worstFinish - base + shortfall, pendingSize, uint256(denominator), Math.Rounding.Ceil);
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
        uint256 threshold = _getAdlScoreThreshold(params.adlAuctionStartTs);

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
        BazaarTypes.OrderBook storage book,
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
        uint256 threshold = _getAdlScoreThreshold(params.adlAuctionStartTs);

        for (uint256 i = 0; i < winners.length; i++) {
            if (totalClosed >= requiredSize) break;

            // executeAdl's entry health check routes a pre-existing deficit into termination
            // and never reaches this loop, so a non-zero value here means an earlier close in
            // THIS batch found the fund unable to back the inventory's own settlement beyond
            // what the winner's funding income could absorb. The post-batch health check
            // terminates the pair; every further close would only turn more of the survivors'
            // unrealized claims into realized ones the fund cannot back, so stop and let the
            // settlement waterfall share the recorded shortfall pro-rata.
            if (pairVault.deficit > 0) break;

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

            // Settlement realizes at the live funding index and the batch's settlement price, so
            // the winner's credit reflects funding actually accrued up to execution.
            BazaarTypes.BucketState memory state = BucketLib.calculateState(
                bucket, settlementPrice, params.currentFundingIndex, params.marginRequirements
            );

            // Eligibility ranked PnL at the snapshot price; the credit realizes it at the
            // settlement price. A winner deleveraged at/above their entry settles at zero PnL —
            // a valid break-even close. Only skip a strictly-negative settlement PnL: don't force
            // a market-profitable trader into a realized loss, and never feed a negative into
            // the uint256 cast below.
            if (state.totalPnl < 0) continue;

            uint256 remaining = requiredSize - totalClosed;
            uint256 closedSize = state.adjustedSize <= remaining ? state.adjustedSize : remaining;
            totalClosed += closedSize;

            // Settles the inventory slice through insurance (and releases it from the pending
            // aggregates, so the next iteration's health check sees the reduced exposure), then
            // sizes the winner's credit.
            SliceSettlement memory s =
                _settleSlice(pairVault, params.currentFundingIndex, state, closedSize, settlementPrice);

            _applyAdlVaultUpdate(pairVault, params.adlLongs, closedSize, s.sliceEntry);
            bucket.collateral = SafeCast.toUint128(state.effectiveCollateral + s.credit);

            if (closedSize == state.adjustedSize) {
                emit UserAdld(
                    params.pairId,
                    user,
                    params.adlLongs,
                    closedSize,
                    int256(s.credit),
                    bucket.collateral,
                    adlScore,
                    settlementPrice,
                    s.withheld
                );
                _resetBucket(orders, book, user, bucket, params);
            } else {
                // Both subtrahends are proportional slices of the current values.
                bucket.size -= uint128(closedSize);
                bucket.entryValue -= uint128(s.sliceEntry);
                // A TP/SL sized for the pre-deleverage position needs no fence: it caps
                // itself at the live position when it fires, so it closes what is left
                // rather than filling past flat. The position keeps its side here and stays
                // non-zero (a full close takes the branch above), so it is still reducible.
                BucketLib.emitBucketUpdate(
                    user, bucket, params.currentFundingIndex, params.marginRequirements, params.pairId
                );
                emit UserAdld(
                    params.pairId,
                    user,
                    params.adlLongs,
                    closedSize,
                    int256(s.credit),
                    bucket.collateral,
                    adlScore,
                    settlementPrice,
                    s.withheld
                );
            }
        }
    }

    /// @notice Sizes one close: the winner's credit at the settlement price and the vault's own
    ///         realization on the same size of inventory.
    /// @dev The winner realizes `totalPnl` at the settlement price with the live funding index
    ///      into their bucket, exactly as a maker filled by the unload walk does, and the inventory
    ///      slice settles against the liquidatees' entry through insurance. Those are different
    ///      numbers: the winner's PnL runs from the WINNER's entry, and the part between that entry
    ///      and the estate's entry was already settled by the winner's earlier counterparties, so
    ///      it is backed by the deposits ledger and never by the fund. Charging the fund the
    ///      winner's PnL instead would misstate insurance by (estate entry − winner entry) × size
    ///      on every close: a false deficit and termination when the winner entered above the
    ///      estate, a deposits ledger below the buckets when they entered below it.
    ///
    ///      A partial close takes every term pro-rata on closedSize / adjustedSize. Only funding
    ///      income may be withheld, and never more than the net credit, so a winner whose price leg
    ///      is negative at the settlement price still closes at no worse than break-even.
    /// @param pairVault The pair's vault accounting
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param state The winner's bucket state at the settlement price and the live index
    /// @param closedSize The size closed, at most `state.adjustedSize`
    /// @param settlementPrice The price the close settles at (BAZAAR_SCALE precision)
    /// @return s The credit, the funding withheld from it, and the entry basis released
    function _settleSlice(
        BazaarTypes.Vault storage pairVault,
        int256 currentFundingIndex,
        BazaarTypes.BucketState memory state,
        uint256 closedSize,
        uint256 settlementPrice
    ) internal returns (SliceSettlement memory s) {
        uint256 slicePnl = uint256(state.totalPnl);
        uint256 sliceFunding = state.fundingPnl > 0 ? uint256(state.fundingPnl) : 0;
        s.sliceEntry = state.entryValue;
        if (closedSize < state.adjustedSize) {
            slicePnl = Math.mulDiv(slicePnl, closedSize, state.adjustedSize);
            sliceFunding = Math.mulDiv(sliceFunding, closedSize, state.adjustedSize);
            s.sliceEntry = Math.mulDiv(s.sliceEntry, closedSize, state.adjustedSize);
        }
        uint256 withholdCap = sliceFunding < slicePnl ? sliceFunding : slicePnl;
        s.withheld = _settleInventorySlice(pairVault, currentFundingIndex, closedSize, settlementPrice, withholdCap);
        s.credit = slicePnl - s.withheld;
    }

    /// @notice Values `closedSize` of inventory closed at `settlementPrice` from the liquidatees'
    ///         entry, price and funding legs, and releases the slice from the pending-liquidation
    ///         aggregates.
    /// @dev The price leg runs to the closed size at the settlement price, the notional the
    ///      winner's credit is measured against; the funding leg runs from the liquidatees' entry
    ///      index to the live index, as on an unload fill. At the estates' average bankruptcy
    ///      price the two legs net to the slice's earmark plus the funding accrued while the vault
    ///      held it: the bankruptcy price is the entry basis displaced by the seized collateral and
    ///      the estate's pre-liquidation funding, so that funding enters the price leg with one
    ///      sign and the funding leg with the other, and nothing is booked twice. At a mark on the
    ///      fund's favorable side the loss shrinks by the distance, or turns into a gain. The
    ///      aggregates decrement pro rata, which leaves the remainder's average bankruptcy price
    ///      and size-weighted entry index unchanged.
    /// @param pairVault The pair's vault accounting
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param closedSize The inventory closed against the winner
    /// @param settlementPrice The price the close settles at (BAZAAR_SCALE precision)
    /// @return vaultPnl The vault's realization on the slice, negative for a loss
    /// @return earmark The slice's share of the collateral seized alongside the inventory
    function _releaseSlice(
        BazaarTypes.Vault storage pairVault,
        int256 currentFundingIndex,
        uint256 closedSize,
        uint256 settlementPrice
    ) internal returns (int256 vaultPnl, uint256 earmark) {
        uint256 pendingSize = pairVault.pendingLiqSize;
        uint256 entryPortion = Math.mulDiv(pairVault.pendingLiqEntryNotional, closedSize, pendingSize);
        uint256 bkPortion = Math.mulDiv(pairVault.pendingLiqBankruptcyNotional, closedSize, pendingSize);
        uint256 closedNotional = Math.mulDiv(closedSize, settlementPrice, BAZAAR_SCALE);
        int256 rawFunding = BazaarMathLib.signedMulDiv(
            currentFundingIndex - pairVault.pendingLiqEntryFundingIndex, int256(closedSize), int256(BAZAAR_SCALE)
        );
        earmark = Math.mulDiv(pairVault.pendingLiqSeized, closedSize, pendingSize);
        if (pairVault.pendingLiqIsLong) {
            vaultPnl = int256(closedNotional) - int256(entryPortion) - rawFunding;
        } else {
            vaultPnl = int256(entryPortion) - int256(closedNotional) + rawFunding;
        }
        pairVault.pendingLiqSize = pendingSize - closedSize;
        pairVault.pendingLiqEntryNotional -= entryPortion;
        pairVault.pendingLiqBankruptcyNotional -= bkPortion;
        pairVault.pendingLiqSeized -= earmark;
    }

    /// @notice Books the vault's realization on a closed inventory slice as an insurance <->
    ///         deposits-ledger transfer, and decides how much of an uncovered loss the winner
    ///         absorbs.
    /// @dev A gain is a D → I transfer capped at D; a loss is an I → D transfer. Both leave I + D
    ///      unchanged, so the books-vs-cash health check is unmoved, and the deposits ledger keeps
    ///      tracking the buckets: the winner's credit lands in a bucket and is withdrawn from the
    ///      ledger later, so the ledger must gain exactly what the vault lost.
    ///
    ///      A loss is funded from the slice's own share of the seizure earmark plus the fund's
    ///      free capital, never from the earmark of inventory still open, so one close's carry
    ///      cannot consume the backing of the next and concentrate a whole batch's shortfall on
    ///      whoever the batch reaches last. Free capital is read before the slice is released,
    ///      while the aggregates still earmark it. Because the earmark sits in the fund by
    ///      construction, the fund can only fall short by the holding-window funding, or when the
    ///      seizure was capped at the deposits ledger. What it cannot pay is withheld from the
    ///      winner's funding income up to `withholdCap`: that income accrued against this
    ///      inventory, so refusing to pay what the fund cannot back keeps every remaining claim
    ///      cash-backed without touching the winner's price PnL. Anything beyond the cap is a
    ///      claim with no backing left, recorded as deficit so the post-batch health check
    ///      terminates the pair and the settlement waterfall shares it pro-rata.
    /// @param pairVault The pair's vault accounting
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param closedSize The inventory closed against the winner
    /// @param settlementPrice The price the close settles at (BAZAAR_SCALE precision)
    /// @param withholdCap The most that may be withheld from the winner's credit
    /// @return withheld The part of the vault's loss withheld from the winner's credit
    function _settleInventorySlice(
        BazaarTypes.Vault storage pairVault,
        int256 currentFundingIndex,
        uint256 closedSize,
        uint256 settlementPrice,
        uint256 withholdCap
    ) internal returns (uint256 withheld) {
        uint256 free = RiskParamsLib.insuranceFreeCapital(pairVault);
        (int256 vaultPnl, uint256 earmark) = _releaseSlice(pairVault, currentFundingIndex, closedSize, settlementPrice);

        if (vaultPnl >= 0) {
            uint256 gain = uint256(vaultPnl);
            uint256 take = gain < pairVault.totalCollateralDeposited ? gain : pairVault.totalCollateralDeposited;
            pairVault.totalCollateralDeposited -= take;
            pairVault.insuranceFundBalance += take;
            return 0;
        }

        uint256 loss = uint256(-vaultPnl);
        uint256 fundable = earmark + free;
        if (fundable > pairVault.insuranceFundBalance) fundable = pairVault.insuranceFundBalance;
        uint256 funded = loss < fundable ? loss : fundable;
        pairVault.insuranceFundBalance -= funded;
        pairVault.totalCollateralDeposited += funded;

        uint256 shortfall = loss - funded;
        withheld = shortfall < withholdCap ? shortfall : withholdCap;
        if (shortfall > withheld) {
            pairVault.deficit += shortfall - withheld;
        }
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

    /// @notice Resets a user's position bucket after full ADL close (cancels TP/SL, zeros
    ///         position fields). Cancelling is required, not hygiene: TP/SL wait outside the book
    ///         for a keeper to fire them, so a live order left behind would execute market-style
    ///         against a position that no longer exists and open a fresh one in its place.
    function _resetBucket(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        address user,
        BazaarTypes.PositionBucket storage bucket,
        BazaarTypes.AdlParams memory params
    ) internal {
        _cancelBucketOrder(orders, book, bucket.takeProfitOrderId, params.pairId, params.currentBlock);
        _cancelBucketOrder(orders, book, bucket.stopLossOrderId, params.pairId, params.currentBlock);

        bucket.size = 0;
        bucket.entryValue = 0;
        bucket.entryFundingIndex = 0;
        bucket.takeProfitOrderId = 0;
        bucket.stopLossOrderId = 0;
        bucket.entryMmrBp = 0; // keep the "flat => no MMR grandfather" invariant
        bucket.mmrUpdateTs = 0; // and the "0 when flat" grace-clock invariant
        // Note: collateral is NOT reset (already updated by caller with PnL)

        BucketLib.emitBucketUpdate(user, bucket, params.currentFundingIndex, params.marginRequirements, params.pairId);
    }

    /// @dev Cancel one slot-anchored order (0 = none): stamp, unlink, emit. Already-terminal
    ///      orders are left untouched.
    function _cancelBucketOrder(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        uint256 orderId,
        bytes32 pairId,
        uint64 currentBlock
    ) private {
        if (orderId == 0) return;
        BazaarTypes.Order storage o = orders[orderId];
        if (o.canceledBlock != 0 || o.filledBlock != 0) return;
        o.canceledBlock = currentBlock;
        OrderBookLib.unlink(orders, book, orderId);
        emit BazaarTypes.OrderUpdated(
            pairId,
            orderId,
            o.creator,
            BazaarTypes.OrderUpdatePayload({
                action: BazaarTypes.OrderAction.Canceled,
                orderType: o.orderType,
                isLong: o.isLong,
                isPostOnly: o.isPostOnly,
                size: o.size,
                filledSize: o.filledSize,
                triggerPrice: o.triggerPrice,
                limitPrice: o.limitPrice,
                maxSlippageBp: o.maxSlippageBp,
                canceledBlock: currentBlock,
                filledBlock: o.filledBlock,
                expiryBlock: o.expiryBlock,
                creationBlock: o.creationBlock
            })
        );
    }
}
