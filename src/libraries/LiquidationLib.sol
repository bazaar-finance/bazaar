// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BucketLib} from "./BucketLib.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";
import {OrderBookLib} from "./OrderBookLib.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";

/// @title LiquidationLib
/// @notice External library for liquidation processing logic.
///         Runs via DELEGATECALL — has direct access to BazaarPair storage.
///         Liquidated positions are aggregated into the Vault's pending liquidation fields
///         rather than creating individual orders. Opposing liquidations are netted at oracle price.
library LiquidationLib {
    // -------------------- Constants --------------------

    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 internal constant MIN_LIQUIDATOR_REWARD = BazaarTypes.MIN_LIQUIDATOR_REWARD; // 0.05 USDC per account

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

    // -------------------- Structs --------------------

    /// @notice One seized position, as the vault's aggregate and the auction consume it.
    /// @param size The position's size
    /// @param entryNotional The position's entry basis
    /// @param bankruptcyNotional The notional at which its equity was zero (bankruptcyNotionalOf)
    /// @param seized The collateral the fund received for it, capped at the deposits ledger
    /// @param entryFundingIndex The position's entry funding index
    /// @param isLong The position's side
    struct Estate {
        uint256 size;
        uint256 entryNotional;
        uint256 bankruptcyNotional;
        uint256 seized;
        int256 entryFundingIndex;
        bool isLong;
    }

    // -------------------- External --------------------

    /// @notice Processes liquidations for a list of users
    /// @dev Iterates through users, checks solvency, and seizes each insolvent position into
    ///      the vault's pending-liquidation aggregate. A position on the side opposite the
    ///      inventory is netted against it at once when the netting's loss fits what the fund
    ///      may spend on it (nettingAffordable), and deferred otherwise: left open, recorded in
    ///      `deferred` for the auction to close against its own counterparties, and re-evaluated
    ///      by every later call that names it, which seizes it as soon as the netting fits or
    ///      the inventory it would have netted against is gone.
    ///      Reward, per account: flatReward for every position the call seizes and every account
    ///      it newly records as deferred — MIN_LIQUIDATOR_REWARD, or the account's own equity when
    ///      its position is worth less than MIN_ORDER_AMOUNT and holds less — earned at
    ///      liquidation time with no profit-contingent component. A seizure that nets against the
    ///      inventory retires the overlap at once, exposure it takes off the fund, and earns the
    ///      larger of its flat reward and LIQUIDATION_FEE_EBP of the overlap's notional at the
    ///      liquidation price: seizureReward's rule, which an ADL batch applies too. Per account
    ///      rather than per call so that one call naming many accounts earns what separate calls
    ///      would: a per-call amount pays more the more finely a batch is split, which moves
    ///      keepers to one transaction per account in a cascade. Paid here, so it stays due when
    ///      no walk runs, as while an ADL window is open: debited from insurance, capped at the
    ///      fund's free capital, and accrued to the liquidator's claimable balance, to be pulled
    ///      via BazaarPair.claimFees.
    ///
    ///      The rate on what liquidate()'s inline walk sells is paid by the walk
    ///      (MatchingEngineLib.unloadBook) past `LiquidateResult.unloadPrepaid`, the part of this
    ///      payment beyond the nettings' rate, so the walk pays only what its rate adds past the
    ///      flat rewards. The call earns the nettings' rate plus the larger of that credit and the
    ///      rate on what the walk sold.
    ///
    ///      A netting's rate is not part of the affordability test (nettingAffordable): counted
    ///      there it would defer nettings whose loss the fund can carry, and a deferred account
    ///      past its collateral holds an ADL window open. It is paid like the flat part, which the
    ///      reserve may fund and the earmark may not, so like the flat part it can bring a window
    ///      forward by what it pays.
    /// @param usersToLiquidate The accounts to check and liquidate
    /// @param orders Storage mapping of orders
    /// @param book The order book
    /// @param positionBuckets Storage mapping of position buckets
    /// @param pairVault The pair's vault aggregates
    /// @param feeEscrow The claimable-fee escrow the reward accrues to
    /// @param deferred The deferred liquidations
    /// @param params The liquidation parameters
    /// @return result The accounts seized and deferred, and the walk's credit (unloadPrepaid)
    function processLiquidations(
        address[] calldata usersToLiquidate,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        address[] storage deferred,
        BazaarTypes.LiquidateParams memory params
    ) external returns (BazaarTypes.LiquidateResult memory result) {
        uint256 reward;
        uint256 nettingRate;
        for (uint256 i = 0; i < usersToLiquidate.length; i++) {
            address user = usersToLiquidate[i];

            BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
            if (bucket.size == 0) {
                forgetDeferred(deferred, user);
                continue; // no position
            }

            // Use the plain oracle price (not a bracket bound) for solvency. Confidence-band
            // polarity has no clean answer for liquidation: user-favorable lets noise carry,
            // protocol-eager risks false liquidations. The 2% confidence-ratio cap at the oracle
            // layer already pauses pricing when uncertainty is too high; that is where
            // conservatism belongs.
            BazaarTypes.BucketState memory state =
                BucketLib.calculateState(bucket, params.currentPrice, params.currentFundingIndex, params.marginReqs);

            if (state.isSolvent) {
                forgetDeferred(deferred, user);
                continue;
            }

            // A position opposite the vault's inventory nets against it, closing both at the
            // oracle. That is the one settlement the fund pays for beyond the two estates' own
            // backing — the auction closes each side against its own counterparties at a
            // bankruptcy price instead — so when the netting would take the fund below its
            // reserve the position is left to the auction: open, recorded, and seized by the
            // next call that finds the netting affordable or the inventory gone.
            if (
                pairVault.pendingLiqSize != 0 && bucket.isLong != pairVault.pendingLiqIsLong
                    && !nettingAffordable(
                        pairVault, state, params.currentPrice, params.currentFundingIndex, pairVault.pendingLiqSize
                    )
            ) {
                if (defer(deferred, positionBuckets, user, state, params)) {
                    reward += flatReward(state);
                }
                unchecked {
                    ++result.deferredCount;
                }
                continue;
            }

            Estate memory e = seize(user, bucket, state, orders, book, pairVault, params);
            // Against an opposite inventory the overlap is retired here, so it earns the rate. An
            // estate larger than the inventory leaves the rest as the new inventory: exposure
            // moved onto the fund, paid for when it is retired.
            uint256 rate = rateOn(nettedSize(pairVault, e.isLong, e.size), params.currentPrice);
            nettingRate += rate;
            uint256 accountReward = flatReward(state);
            reward += rate > accountReward ? rate : accountReward;
            absorb(pairVault, e);
            forgetDeferred(deferred, user);

            unchecked {
                ++result.liquidatedCount;
            }
        }

        // The reward moves from insurance into the fee escrow here rather than in BazaarPair
        // (DELEGATECALL preserves msg.sender = caller), keeping the pair's EIP-170 budget free
        // of it. Insurance and the escrow liability move together, so the books-vs-cash check
        // stays exact, and the liquidation never runs a token transfer — nothing a liquidator's
        // address does can revert or strand it. Capped at the fund's free capital. A seizure
        // that joins the inventory does not raise it: its collateral is earmarked against the
        // inventory it arrived with, and a reward drawn from it would resurface as a shortfall
        // when that inventory settles — deficit on an unload fill, funding withheld from a
        // deleveraged winner. A netted slice's seizure is released with the slice and raises it
        // by what the netting's loss leaves of it. The reserve may pay the reward; the earmark
        // may not. The liquidations themselves commit whatever is paid.
        uint256 free = RiskParamsLib.insuranceFreeCapital(pairVault);
        if (reward > free) reward = free;
        if (reward > 0) {
            pairVault.insuranceFundBalance -= reward;
            FeeEscrowLib.credit(feeEscrow, params.pairId, msg.sender, reward);
        }
        // The walk pays the rate on what it sells past this credit: the payment less the
        // nettings' rate, which is what the flat rewards add beyond it. A cap that bit only
        // lowers the call's total.
        result.unloadPrepaid = reward > nettingRate ? reward - nettingRate : 0;
    }

    // -------------------- Seizure --------------------

    /// @notice Seizes one insolvent position: removes it from the open-interest aggregates,
    ///         credits its collateral to the insurance fund and resets its bucket. Leaves the
    ///         vault's inventory untouched — the caller absorbs the estate into it or closes it
    ///         against winners in the same transaction — and leaves the reward to the caller, which
    ///         knows how much of the position the seizure retires (seizureReward).
    /// @dev Insurance is credited with the seized book collateral. Winners realize gains into
    ///      their buckets without touching the deposits ledger and withdraw them from it later,
    ///      so a loser's book collateral can legitimately exceed the entire remaining ledger; an
    ///      uncapped debit would panic there, leaving exactly the deepest-underwater position
    ///      unliquidatable. The part the ledger cannot pay is carried as the ledger's arrears to
    ///      the fund rather than dropped or booked as deficit: the estate settles at its entry
    ///      basis through transfers paid net of those arrears, so the fund's outlay on it
    ///      is the loss beyond the bucket — the bankruptcy price — and a genuine shortfall
    ///      surfaces as deficit only if insurance cannot fund that. `seized` is the cash the
    ///      fund received and is what the inventory earmarks; the arrears back it alongside.
    /// @param user The account being liquidated
    /// @param bucket The account's bucket
    /// @param state The bucket's state at the liquidation price and the live index
    /// @param orders Storage mapping of orders
    /// @param book The order book
    /// @param pairVault The pair's vault aggregates
    /// @param params The liquidation parameters
    /// @return e The estate the seizure produced
    function seize(
        address user,
        BazaarTypes.PositionBucket storage bucket,
        BazaarTypes.BucketState memory state,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.LiquidateParams memory params
    ) internal returns (Estate memory e) {
        e.size = state.adjustedSize;
        e.isLong = bucket.isLong;
        e.entryNotional = state.entryValue;
        e.entryFundingIndex = state.adjustedEntryFundingIndex;

        e.bankruptcyNotional = bankruptcyNotionalOf(state, e.isLong);

        // Update vault aggregates - remove this position from OI
        if (e.isLong) {
            pairVault.totalLongOI = pairVault.totalLongOI > e.size ? pairVault.totalLongOI - e.size : 0;
            pairVault.longWeightedEntrySum = pairVault.longWeightedEntrySum > state.entryValue
                ? pairVault.longWeightedEntrySum - state.entryValue
                : 0;
        } else {
            pairVault.totalShortOI = pairVault.totalShortOI > e.size ? pairVault.totalShortOI - e.size : 0;
            pairVault.shortWeightedEntrySum = pairVault.shortWeightedEntrySum > state.entryValue
                ? pairVault.shortWeightedEntrySum - state.entryValue
                : 0;
        }

        e.seized = RiskParamsLib.collectFromLedger(pairVault, state.effectiveCollateral);

        _resetBucket(
            user,
            bucket,
            orders,
            book,
            params.currentFundingIndex,
            params.marginReqs,
            params.pairId,
            params.currentBlock
        );

        emit PositionLiquidated(
            params.pairId,
            user,
            msg.sender,
            e.size,
            e.isLong,
            Math.mulDiv(e.bankruptcyNotional, BAZAAR_SCALE, e.size),
            params.currentPrice,
            e.seized,
            block.timestamp
        );
    }

    /// @notice The flat part of the reward for liquidating one account: MIN_LIQUIDATOR_REWARD,
    ///         or the account's own equity when its position is worth less than MIN_ORDER_AMOUNT
    ///         at the liquidation price and that equity is smaller.
    /// @dev Maintenance margin never drops below RiskParamsLib.MIN_IMR_BP / 2, so a position worth
    ///      MIN_ORDER_AMOUNT or more holds twice the floor or more in equity at the maintenance
    ///      line, and only the market carries it further: a withdrawal must leave initial margin,
    ///      and a partial close cannot take it across the line. Such a position earns the full
    ///      floor even past bankruptcy, because until it is seized its further losses are the
    ///      fund's and a keeper must be paid to stop them.
    ///
    ///      Below that notional the maintenance line can sit under the floor, and a position can
    ///      be brought to the line, or to zero equity, with no price move at all: margin that
    ///      rounds to zero lets a withdrawal take everything, and a partial close at an off-market
    ///      price to a second account can leave the remainder exactly at maintenance. An
    ///      unconditional floor would make each such account a flat payment from insurance.
    ///      Capped at equity, the fund never pays more for one than the equity it takes over.
    /// @param state The account's bucket state at the liquidation price and the live index
    /// @return The flat reward in BAZAAR_SCALE precision
    function flatReward(BazaarTypes.BucketState memory state) internal pure returns (uint256) {
        if (state.currentNotional < BazaarTypes.MIN_ORDER_AMOUNT && state.availableEquity < MIN_LIQUIDATOR_REWARD) {
            return state.availableEquity;
        }
        return MIN_LIQUIDATOR_REWARD;
    }

    /// @notice The part of an estate that absorbing it into the inventory nets (absorb): its
    ///         overlap with an inventory on the other side, 0 against an empty inventory or one
    ///         on its own side. Read before the absorb.
    /// @param pairVault The pair's vault aggregates
    /// @param isLong The estate's side
    /// @param size The estate's size
    /// @return The size the netting retires (BAZAAR_SCALE precision)
    function nettedSize(BazaarTypes.Vault storage pairVault, bool isLong, uint256 size)
        internal
        view
        returns (uint256)
    {
        uint256 inventory = pairVault.pendingLiqSize;
        if (inventory == 0 || isLong == pairVault.pendingLiqIsLong) return 0;
        return size < inventory ? size : inventory;
    }

    /// @notice The keeper rate, LIQUIDATION_FEE_EBP, on `size` valued at `price`.
    /// @param size The size retired (BAZAAR_SCALE precision)
    /// @param price The price it is valued at (BAZAAR_SCALE precision)
    /// @return The rate in BAZAAR_SCALE precision
    function rateOn(uint256 size, uint256 price) internal pure returns (uint256) {
        return
            Math.mulDiv(Math.mulDiv(size, price, BAZAAR_SCALE), BazaarTypes.LIQUIDATION_FEE_EBP, BazaarTypes.EBP_SCALE);
    }

    /// @notice What seizing one account earns: its flat reward, or the rate on the part of its
    ///         position the seizure retires when that is larger.
    /// @dev Retired means taken off the books in the same transaction — netted against the
    ///      opposite inventory, or closed against counterparties — so it never sits on the fund.
    ///      A part that joins the inventory instead — an estate seized onto the inventory's side
    ///      or into an empty one, or the rest of one larger than the inventory it nets — is
    ///      exposure moved onto the fund, and whoever later retires it is paid for that: an
    ///      unload's sale or a later netting at this rate, an ADL batch's close of the inventory's
    ///      own exposure at this rate or at its share of the bad debt the close averts where that
    ///      is larger. Paying the rate at seizure as well would pay twice for those units. The
    ///      flat part covers gas on small positions; the rate scales with size. An ADL batch that
    ///      closes a seized account against its counterparties pays this reward and its share of
    ///      the bad debt that close averts: one for taking the account off the books, the other
    ///      for the loss it spared.
    /// @param state The account's bucket state at the liquidation price and the live index
    /// @param retiredSize The part of the position the seizure retires (BAZAAR_SCALE precision)
    /// @param price The liquidation price (BAZAAR_SCALE precision)
    /// @return The reward in BAZAAR_SCALE precision
    function seizureReward(BazaarTypes.BucketState memory state, uint256 retiredSize, uint256 price)
        internal
        pure
        returns (uint256)
    {
        uint256 flat = flatReward(state);
        uint256 rate = rateOn(retiredSize, price);
        return rate > flat ? rate : flat;
    }

    /// @notice Folds a seized estate into the vault's inventory: seeds it, adds to its side, or
    ///         nets it against the opposite side.
    /// @dev The aggregate's funding index is seeded/merged from the LIQUIDATEE'S ENTRY index,
    ///      not the liquidation-time index. The estate has no surviving owner, so its accrued
    ///      funding (entry → liquidation) must reach insurance or it vanishes while the
    ///      counterparties' offsetting side stays live — breaking funding zero-sum by exactly
    ///      the estate's funding PnL per liquidation. Carrying the entry index forward makes the
    ///      settlement paths (Pass A close, opposing netting, ADL) realize funding over
    ///      entry → close in one signed term: the estate's pre-liquidation balance and the
    ///      funding accrued while the vault held the inventory settle together into insurance.
    ///
    ///      The seizure stamp the unload floor opens from is kept the same way: seeded at the
    ///      present instant and blended by size when an estate joins, so a large estate arriving
    ///      late restarts most of the countdown while a dust one barely moves it. An aged
    ///      aggregate therefore cannot lend a large new estate an already-open floor; what a
    ///      dust estate inherits from one is its own dust-sized residual equity.
    /// @param pairVault The pair's vault aggregates
    /// @param e The estate to absorb
    function absorb(BazaarTypes.Vault storage pairVault, Estate memory e) internal {
        if (pairVault.pendingLiqSize == 0) {
            // No existing aggregate — seed it
            pairVault.pendingLiqSize = e.size;
            pairVault.pendingLiqEntryNotional = e.entryNotional;
            pairVault.pendingLiqBankruptcyNotional = e.bankruptcyNotional;
            pairVault.pendingLiqSeized = e.seized;
            pairVault.pendingLiqEntryFundingIndex = e.entryFundingIndex;
            pairVault.pendingLiqIsLong = e.isLong;
            pairVault.pendingLiqSeizedTs = uint64(block.timestamp);
        } else if (e.isLong == pairVault.pendingLiqIsLong) {
            // Same direction — add to aggregate
            uint256 newTotalSize = pairVault.pendingLiqSize + e.size;
            pairVault.pendingLiqEntryFundingIndex =
                (pairVault.pendingLiqEntryFundingIndex
                        * int256(pairVault.pendingLiqSize)
                        + e.entryFundingIndex
                        * int256(e.size)) / int256(newTotalSize);
            pairVault.pendingLiqSeizedTs =
                _blendSeizedTs(pairVault.pendingLiqSeizedTs, pairVault.pendingLiqSize, e.size, newTotalSize);
            pairVault.pendingLiqSize = newTotalSize;
            pairVault.pendingLiqEntryNotional += e.entryNotional;
            pairVault.pendingLiqBankruptcyNotional += e.bankruptcyNotional;
            pairVault.pendingLiqSeized += e.seized;
        } else {
            // Opposite direction — net against existing aggregate
            _netOpposingLiquidation(pairVault, e);
        }
    }

    /// @notice Whether netting `state`'s position against the vault's inventory would cost the
    ///         fund no more than it may spend on it.
    /// @dev Mirrors _netOpposingLiquidation's realization — the entry gap on the overlap plus
    ///      the two sides' entry-clock offset — against what backs the overlap: free capital
    ///      above the reserve, the two netted slices' seizure and the ledger's arrears, which a
    ///      loss is paid net of. The reserve is the line the unload walk never crosses either,
    ///      so a netting the fund can afford leaves it in the state every other resolution
    ///      would. The seizure is counted at the bucket's full collateral: the part the ledger
    ///      cannot pay becomes arrears, which back the netting just the same.
    ///
    ///      The arrears are one pair-wide balance, and the inventory that survives the netting
    ///      needs its share of them. A close at the estates' bankruptcy price is paid from the
    ///      slice's earmark, the arrears and free capital (AdlLib._settleInventorySlice), and what
    ///      it needs beyond the earmark (RiskParamsLib.bankruptcyCloseCost) is the collateral the
    ///      ledger never handed over plus the holding-window funding. Spent on this netting, that backing would be
    ///      missing when the survivors settle, and the shortfall would surface there as a deficit
    ///      with no insolvency verdict in between — the hazard _netOpposingLiquidation guards the
    ///      surviving earmark against. So of the arrears and the free capital above the reserve,
    ///      only what exceeds the survivors' need is spendable here: the survivors being the
    ///      `keep` units the caller must still settle, at most what the netting leaves.
    ///
    ///      The netting is paid so that it spends only what this lets it: from the two slices'
    ///      seizure first, and only then net of the arrears and from free capital
    ///      (_netOpposingLiquidation). Paid net of the arrears first, a loss the slices' seizure
    ///      covers would cancel the survivors' arrears and release the seizure into free capital,
    ///      which below the reserve this reading does not count: a netting passed here could
    ///      leave the survivors reading short by up to its whole loss while the fund held the
    ///      same value.
    /// @param pairVault The pair's vault aggregates
    /// @param state The position's bucket state at the liquidation price and the live index
    /// @param price The liquidation price (BAZAAR_SCALE precision)
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param keep The inventory whose bankruptcy-priced close must stay backed after the
    ///        netting: the whole remainder, or, once an ADL batch has closed what netting every
    ///        listed account past its collateral needs, what those nettings leave
    /// @return True when the netting's loss is within that backing, when it is a gain, or when
    ///         there is no inventory to net against at all
    function nettingAffordable(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.BucketState memory state,
        uint256 price,
        int256 currentFundingIndex,
        uint256 keep
    ) internal view returns (bool) {
        uint256 existingSize = pairVault.pendingLiqSize;
        // With no inventory there is nothing to net against: absorbing the estate seeds the
        // aggregate instead, which credits its seizure and costs the fund nothing. Answering here
        // also keeps the proportional terms below from dividing by that zero, which is reachable
        // whenever an earlier netting in the same pass consumed the aggregate exactly.
        if (existingSize == 0) return true;
        uint256 newSize = state.adjustedSize;
        uint256 netSize = existingSize < newSize ? existingSize : newSize;
        uint256 existingEntryPortion = Math.mulDiv(pairVault.pendingLiqEntryNotional, netSize, existingSize);
        uint256 newEntryPortion = Math.mulDiv(state.entryValue, netSize, newSize);
        int256 netPnl = pairVault.pendingLiqIsLong
            ? int256(newEntryPortion) - int256(existingEntryPortion)
            : int256(existingEntryPortion) - int256(newEntryPortion);
        int256 nettedFunding = BazaarMathLib.signedMulDiv(
            pairVault.pendingLiqEntryFundingIndex - state.adjustedEntryFundingIndex,
            int256(netSize),
            int256(BAZAAR_SCALE)
        );
        netPnl += pairVault.pendingLiqIsLong ? nettedFunding : -nettedFunding;
        if (netPnl >= 0) return true;

        uint256 free = RiskParamsLib.insuranceFreeCapital(pairVault);
        uint256 reserve = RiskParamsLib.adlReserve(pairVault, price);
        uint256 backing = (free > reserve ? free - reserve : 0) + pairVault.ledgerArrears;
        uint256 surviving = existingSize - netSize;
        if (keep > surviving) keep = surviving;
        // The survivors' per-unit need is the aggregate's: a netting decrements it pro rata.
        uint256 needed =
            Math.mulDiv(RiskParamsLib.bankruptcyCloseCost(pairVault, currentFundingIndex), keep, existingSize);
        backing = backing > needed ? backing - needed : 0;
        backing += Math.mulDiv(pairVault.pendingLiqSeized, netSize, existingSize);
        backing += Math.mulDiv(state.effectiveCollateral, netSize, newSize);
        return uint256(-netPnl) <= backing;
    }

    // -------------------- Deferred liquidations --------------------

    /// @notice Position of `user` in the deferred list.
    /// @return idx The index, meaningful only when `found`
    /// @return found Whether `user` is listed
    function deferredIndex(address[] storage deferred, address user) internal view returns (uint256 idx, bool found) {
        uint256 n = deferred.length;
        for (idx = 0; idx < n; idx++) {
            if (deferred[idx] == user) return (idx, true);
        }
        return (0, false);
    }

    /// @notice Removes the entry at `idx` by moving the last entry into its place.
    function removeDeferredAt(address[] storage deferred, uint256 idx) internal {
        uint256 last = deferred.length - 1;
        if (idx != last) deferred[idx] = deferred[last];
        deferred.pop();
    }

    /// @notice Removes `user` from the deferred list if it is listed.
    function forgetDeferred(address[] storage deferred, address user) internal {
        (uint256 idx, bool found) = deferredIndex(deferred, user);
        if (found) removeDeferredAt(deferred, idx);
    }

    /// @notice Records `user` as a deferred liquidation.
    /// @dev The list is bounded by MAX_DEFERRED_LIQUIDATIONS. When full, the newcomer takes
    ///      the place of the listed account with the smallest loss beyond its collateral at the
    ///      liquidation price, and only if its own is larger: the gate and the auction see the
    ///      accounts that matter most, and what stays untracked is picked up by a later call
    ///      once room frees or the inventory it would have netted against is gone. An account
    ///      already listed is left where it is.
    /// @param deferred The deferred liquidations
    /// @param positionBuckets Storage mapping of position buckets
    /// @param user The account to record
    /// @param state The account's bucket state at the liquidation price and the live index
    /// @param params The liquidation parameters
    /// @return recorded True when the account was newly listed, which earns the recording tip
    function defer(
        address[] storage deferred,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        address user,
        BazaarTypes.BucketState memory state,
        BazaarTypes.LiquidateParams memory params
    ) internal returns (bool recorded) {
        (, bool found) = deferredIndex(deferred, user);
        if (found) return false;
        if (deferred.length < BazaarTypes.MAX_DEFERRED_LIQUIDATIONS) {
            deferred.push(user);
            return true;
        }
        uint256 excess = RiskParamsLib.accountExcess(state);
        uint256 minIdx;
        uint256 minExcess = type(uint256).max;
        for (uint256 i = 0; i < deferred.length; i++) {
            BazaarTypes.PositionBucket storage listed = positionBuckets[deferred[i]];
            uint256 listedExcess = listed.size == 0
                ? 0
                : RiskParamsLib.accountExcess(
                    BucketLib.calculateState(listed, params.currentPrice, params.currentFundingIndex, params.marginReqs)
                );
            if (listedExcess < minExcess) {
                minExcess = listedExcess;
                minIdx = i;
            }
        }
        if (excess <= minExcess) return false;
        deferred[minIdx] = user;
        return true;
    }

    // -------------------- Internal --------------------

    /// @notice Nets an opposing liquidation against the existing vault aggregate
    /// @dev When a position is liquidated in the opposite direction to the existing aggregate,
    ///      the overlapping portion is settled immediately: the oracle cancels in the price leg
    ///      and the current funding index cancels in the funding leg, so settlement needs only
    ///      the two sides' entry-based values. Any remainder either reduces the existing
    ///      aggregate or flips the direction. A net loss is paid from the seizure backing the two
    ///      netted slices first, then net of the ledger's arrears and from the fund's free
    ///      capital, never from the earmark of the inventory that survives the netting; what
    ///      that cannot cover is realized as deficit here.
    /// @param pairVault The pair's vault aggregates
    /// @param e The estate netted against the aggregate
    function _netOpposingLiquidation(BazaarTypes.Vault storage pairVault, Estate memory e) internal {
        uint256 existingSize = pairVault.pendingLiqSize;
        uint256 netSize = existingSize < e.size ? existingSize : e.size;

        // Compute proportional notionals for the netted portion
        uint256 existingEntryPortion = Math.mulDiv(pairVault.pendingLiqEntryNotional, netSize, existingSize);
        uint256 newEntryPortion = Math.mulDiv(e.entryNotional, netSize, e.size);

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
            pairVault.pendingLiqEntryFundingIndex - e.entryFundingIndex, int256(netSize), int256(BAZAAR_SCALE)
        );
        netPnl += pairVault.pendingLiqIsLong ? nettedFunding : -nettedFunding;

        // The seizure backing the two netted slices: the existing aggregate's share of its
        // earmark and the netted share of the seizure credited just above. The rest of both
        // stays earmarked against the inventory the netting leaves (the unnetted remainder of
        // one side).
        uint256 existingSeizedPortion = Math.mulDiv(pairVault.pendingLiqSeized, netSize, existingSize);
        uint256 newSeizedPortion = Math.mulDiv(e.seized, netSize, e.size);
        uint256 survivingEarmark = (pairVault.pendingLiqSeized - existingSeizedPortion) + (e.seized - newSeizedPortion);

        // Reduce existing aggregate proportionally. The netted portion's seizure stays in the
        // fund as realized: it is no longer earmarked against anything.
        uint256 existingBankruptcyPortion = Math.mulDiv(pairVault.pendingLiqBankruptcyNotional, netSize, existingSize);
        pairVault.pendingLiqSize -= netSize;
        pairVault.pendingLiqEntryNotional -= existingEntryPortion;
        pairVault.pendingLiqBankruptcyNotional -= existingBankruptcyPortion;
        pairVault.pendingLiqSeized -= existingSeizedPortion;

        // Handle remainder of the new liquidation
        uint256 remainingNewSize = e.size - netSize;
        if (remainingNewSize > 0 && pairVault.pendingLiqSize == 0) {
            // Existing fully netted — new side takes over
            uint256 remainingEntryNotional = Math.mulDiv(e.entryNotional, remainingNewSize, e.size);
            uint256 remainingBankruptcyNotional = Math.mulDiv(e.bankruptcyNotional, remainingNewSize, e.size);
            pairVault.pendingLiqSize = remainingNewSize;
            pairVault.pendingLiqEntryNotional = remainingEntryNotional;
            pairVault.pendingLiqBankruptcyNotional = remainingBankruptcyNotional;
            pairVault.pendingLiqSeized = Math.mulDiv(e.seized, remainingNewSize, e.size);
            pairVault.pendingLiqEntryFundingIndex = e.entryFundingIndex;
            pairVault.pendingLiqIsLong = e.isLong;
            pairVault.pendingLiqSeizedTs = uint64(block.timestamp);
        }
        // If remainingNewSize == 0 or pairVault.pendingLiqSize > 0, the existing aggregate remains
        // (reduced), and keeps its seizure stamp: the netted slice leaves, the remainder's age does not change.

        // Apply net PnL as an insurance <-> deposits-ledger TRANSFER (same rationale as the
        // Pass-A vaultPnl booking in MatchingEngineLib._finalize): the netted estates' PnL is
        // offset by the surviving counterparties' opposite unrealized PnL, which realizes into
        // their buckets and settles against the deposits ledger at their closes/withdrawals.
        // A one-sided entry would drift expectedBalance (I + D) away from actual USDC —
        // upward on profits (accumulating toward a false reason-3 termination), downward on
        // losses (underflowing late withdrawers). I + D is invariant under the transfer. A gain
        // the ledger cannot pay is carried as its arrears; a loss is paid net of them.
        //
        // The cash a loss may draw is free capital plus the netted slices' seizure. The balance
        // also holds the surviving earmark, and that earmark is all that stands between the
        // surviving estate and bad debt: spent here, the estate would read as backed while the
        // cash behind it was gone, and the shortfall would surface only when it settled, with no
        // insolvency verdict in between. Capping the draw books the shortfall as deficit now, so
        // the health check after this batch terminates the pair in the transaction the bad debt
        // is realized in.
        //
        // Within that cap the loss spends the netted slices' seizure first, and only then nets
        // the arrears and draws on free capital (RiskParamsLib.fundLedgerFrom). The arrears back
        // the inventory the netting leaves, and nettingAffordable passed this loss against the
        // seizure plus what the arrears and free capital above the reserve exceed that
        // inventory's need by: paid in this order, the loss reaches them only by what it exceeds
        // the seizure, within that excess. Cancelled ahead of the seizure, they would go to a
        // loss the seizure covers while the seizure joined free capital, which the netting gate
        // and the ADL gate count only above the reserve: below it, the inventory would read
        // short by what they paid although the fund holds the same value, its next netting could
        // be refused, and its loss at the mark could open a window.
        if (netPnl >= 0) {
            RiskParamsLib.collectFromLedger(pairVault, uint256(netPnl));
        } else {
            uint256 fund = pairVault.insuranceFundBalance;
            uint256 fundable = fund > survivingEarmark ? fund - survivingEarmark : 0;
            uint256 uncovered = RiskParamsLib.fundLedgerFrom(
                pairVault, uint256(-netPnl), existingSeizedPortion + newSeizedPortion, fundable
            );
            if (uncovered > 0) {
                // Uncovered overrun is unbacked bad debt; recorded as realized deficit so the
                // post-liquidation isVaultHealthy terminates the pair.
                pairVault.deficit += uncovered;
            }
        }
    }

    /// @dev The inventory's seizure stamp once `newSize` seized now joins `oldSize` stamped
    ///      `oldTs`: the size-weighted mean, rounded up so the blend never reads older than the
    ///      estates in it.
    function _blendSeizedTs(uint256 oldTs, uint256 oldSize, uint256 newSize, uint256 total)
        internal
        view
        returns (uint64)
    {
        return uint64((oldTs * oldSize + block.timestamp * newSize + total - 1) / total);
    }

    /// @notice The notional at which `state`'s position holds exactly zero equity: its entry
    ///         basis less its collateral and accrued funding for a long, plus them for a short.
    /// @dev Closing the position at this notional realizes a loss equal to its collateral once
    ///      the funding it accrued is settled, so the seizure covers it to the wei. That holds
    ///      only for the exact figure. Rebuilding it as size times a per-unit price rounds twice,
    ///      and for a long both roundings lower the proceeds: the loss would exceed the seizure
    ///      by the rounding, and a fund with no free capital has nothing to pay that from.
    ///
    ///      Lets a caller price a position's settlement without seizing it first, so a batch can
    ///      check that a cohort can actually absorb an account before it takes the account apart.
    /// @param state The position's bucket state at the liquidation price and the live index
    /// @param isLong The position's side
    /// @return The bankruptcy notional in BAZAAR_SCALE precision, floored at 0: a long whose
    ///         collateral and funding cover its whole entry basis is bankrupt at no positive price
    function bankruptcyNotionalOf(BazaarTypes.BucketState memory state, bool isLong) internal pure returns (uint256) {
        int256 backing = int256(state.effectiveCollateral) + state.fundingPnl;
        int256 notional = isLong ? int256(state.entryValue) - backing : int256(state.entryValue) + backing;
        return notional > 0 ? uint256(notional) : 0;
    }

    /// @notice Resets a user's position bucket to zero state
    /// @dev Cancels any active TP/SL orders and resets all position fields to zero. The
    ///      cancellation is load-bearing: TP/SL wait outside the book for a keeper to fire them,
    ///      so an order left live after the position is seized would execute market-style and
    ///      re-open exposure for a user who was just liquidated.
    function _resetBucket(
        address user,
        BazaarTypes.PositionBucket storage bucket,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        int256 currentFundingIndex,
        BazaarTypes.MarginRequirements memory marginReqs,
        bytes32 pairId,
        uint64 currentBlock
    ) internal {
        _cancelBucketOrder(orders, book, bucket.takeProfitOrderId, pairId, currentBlock);
        _cancelBucketOrder(orders, book, bucket.stopLossOrderId, pairId, currentBlock);

        // Reset bucket fields (always reset collateral during liquidation)
        bucket.size = 0;
        bucket.entryValue = 0;
        bucket.collateral = 0;
        bucket.entryFundingIndex = 0;
        bucket.takeProfitOrderId = 0;
        bucket.stopLossOrderId = 0;

        BucketLib.emitBucketUpdate(user, bucket, currentFundingIndex, marginReqs, pairId);
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
        OrderBookLib.emitOrderUpdated(
            pairId, orderId, o, BazaarTypes.OrderAction.Canceled, BazaarTypes.CancelReason.Liquidated
        );
    }
}
