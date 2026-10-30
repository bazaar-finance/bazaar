// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BazaarMathLib} from "./BazaarMathLib.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BucketLib} from "./BucketLib.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";
import {LiquidationLib} from "./LiquidationLib.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";
import {OrderBookLib} from "./OrderBookLib.sol";

/// @title AdlLib
/// @notice External library for Auto-Deleveraging (ADL) logic. Runs via DELEGATECALL with BazaarPair storage.
///         Uses O(1) aggregate decrement instead of O(n) FIFO queue popping.
///         Settlement price = the estates' average bankruptcy price,
///         pendingLiqBankruptcyNotional / pendingLiqSize, or the mark when the mark sits on the
///         fund's favorable side of it. A batch settles there the inventory its restoring figure
///         calls for (_sizeToRestoreHealth) and closes past that at the mark.
///
///         One batch works two independent problems, each against its own counterparties. The
///         vault's inventory is closed against the cohort on the opposite side, as the auction
///         always has. Liquidations the vault could not take — accounts on the opposite side
///         whose netting against the inventory would have cost the fund more than it may spend,
///         recorded as deferred by LiquidationLib — are closed against the cohort on the
///         inventory's own side: each is seized inside the batch, its counterparties are settled
///         against it at its own bankruptcy price, or at the mark when the mark sits on the
///         fund's favorable side of it, and nothing of it outlives the transaction.
///         The two meet only through the fund: when no cohort covers a deferred account, the
///         inventory leg closes enough inventory for the fund to afford netting it, and the fund
///         pays what it can afford, as the liquidation that deferred it would have. The units
///         closed for that purpose settle at the mark, so the inventory's winners bear none of
///         the deferred account's loss. Netting the two
///         sides against each other at the oracle
///         would instead charge the fund a loss that belongs to the deferred accounts' winners,
///         which is the case deferral exists to avoid.
library AdlLib {
    // -------------------- Constants --------------------

    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 internal constant BP_SCALE = BazaarTypes.BP_SCALE;

    uint256 internal constant MAX_ADL_WINNERS_PER_BATCH = 25;
    uint256 internal constant ADL_AUCTION_DURATION = BazaarTypes.ADL_AUCTION_DURATION;

    /// @dev The most of one close's shortfall that is treated as rounding rather than as a loss
    ///      the fund failed to back (_settleInventorySlice): one unit of USDC precision, the
    ///      smallest amount the pair can pay anyone.
    uint256 internal constant ROUNDING_ALLOWANCE = BAZAAR_SCALE / BazaarTypes.USDC_SCALE;

    /// @dev The inventory leg's planned close when the batch made no plan: no listed account is
    ///      past its collateral, or the leg did not run. No close equals it, so such a batch never
    ///      reads as having closed what it planned.
    uint256 internal constant NO_PLAN = type(uint256).max;

    // -------------------- Errors --------------------

    error AdlLib__EmptySubmission();
    error AdlLib__TooManyWinners(uint256 count, uint256 max);
    error AdlLib__NoPendingLiquidations();
    error AdlLib__NoEligibleWinners();
    error AdlLib__NotDescendingAdlScoreOrder(uint256 adlScore, uint256 prevScore);
    error AdlLib__NotAscendingAddressTie(address user, address prevUser);
    error AdlLib__CohortDidNotCover(uint256 uncovered);

    // -------------------- Structs --------------------

    /// @notice What one close pays and releases.
    /// @param credit The amount added to the winner's collateral
    /// @param withheld The part of the credit the fund could not back, see _settleInventorySlice
    /// @param sliceEntry The entry basis released from the winner's bucket and the OI aggregates
    struct SliceSettlement {
        uint256 credit;
        uint256 withheld;
        uint256 sliceEntry;
    }

    /// @notice An inventory the batch closes winners against: the vault's own aggregate loaded
    ///         from storage, or a deferred account seized for the duration of one batch.
    /// @dev The same fields as the vault's pending-liquidation aggregate. Closes decrement it
    ///      pro rata in memory; only the vault's own copy is written back.
    struct Inventory {
        uint256 size;
        uint256 entryNotional;
        uint256 bankruptcyNotional;
        uint256 seized;
        int256 entryFundingIndex;
        bool isLong;
    }

    /// @notice What the batch earns its executor, accumulated across both phases and paid once,
    ///         and how many deferred accounts it seized on the way.
    /// @param seizure The seizure reward of every deferred account seized in the batch, each on
    ///        what the batch retires with it (LiquidationLib.seizureReward)
    /// @param averted The bad debt the batch's closes averted, rewarded at ADL_EXECUTOR_REWARD_BP
    /// @param seized The number of deferred accounts seized: closed against their cohort, netted
    ///        into the inventory or made the inventory
    struct Rewards {
        uint256 seizure;
        uint256 averted;
        uint256 seized;
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
    ///        price, or the mark when the mark sat on the fund's favorable side of it or the
    ///        close was past the batch's restoring figure and the fund could pay for it there
    /// @param withheldFunding What the insurance fund could not back and therefore did not pay;
    ///        bounded by the winner's funding income on the closed size, or by ROUNDING_ALLOWANCE
    ///        where that is larger, and by the credit
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

    /// @notice Emitted once per ADL batch.
    /// @dev Emitted here (via DELEGATECALL, so the log's emitter is the BazaarPair) rather than
    ///      from BazaarPair, which keeps the pair's EIP-170 budget free of it. Like every event a
    ///      linked library emits, it is absent from the pair's compiled ABI; script/export-abis.sh
    ///      writes an ABI that includes it.
    /// @param pairId The pair
    /// @param adlId The batch's sequence number on the pair
    /// @param adlLongs The side the window targets: the winners opposite the vault's inventory
    /// @param submitter The executor, credited with the batch's rewards
    /// @param highestBankruptcyPrice The higher of the prices the inventory leg settled at
    /// @param lowestBankruptcyPrice The lower of them. The leg settles at the estates' average
    ///        bankruptcy price, or at the mark when the mark sits on the fund's favorable side of
    ///        it, and settles at the mark what it closes past its restoring figure. Both fields
    ///        hold the settlement price when nothing closed at the mark, including when the leg
    ///        closed nothing, and are zero when the leg did not run: no inventory opposite the
    ///        targeted side, or neither winners nor listed accounts to size it for
    /// @param highestAdlScore The inventory leg's first admitted winner's score
    /// @param lowestAdlScore Its last admitted winner's score
    /// @param adlSnapshotPrice The window's frozen ranking price
    /// @param timestamp The block timestamp
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

    /// @notice Core ADL execution: close deferred accounts against their own counterparties,
    ///         close the vault's inventory against its opposite cohort, seize what deferrals
    ///         remain once the inventory is gone, and pay the executor.
    /// @dev Called via DELEGATECALL from BazaarPair.executeAdl, which re-evaluates vault health
    ///      after this returns. Rewards accrue to msg.sender's claimable balance here: the
    ///      seizure reward of every deferred account taken in the batch plus
    ///      ADL_EXECUTOR_REWARD_BP of the bad debt the closes averted, capped together at the
    ///      fund's free capital — the earmark left against unclosed inventory settles that
    ///      inventory, so a reward drawn from it would come out of a later winner's funding
    ///      income or an unload fill's backing.
    ///
    ///      Order: deferred accounts first, because theirs is the exposure no earmark backs;
    ///      then the inventory. Either phase runs without the other's cohort, and the deferred
    ///      phase runs whether or not one was submitted at all: only closing an account against
    ///      counterparties needs `deferredWinners`, while dropping one that is flat or solvent
    ///      again, delisting one that now sits on the inventory's own side (the next liquidation
    ///      that names it seizes it into the inventory), and netting one the fund can afford are
    ///      all operations on stored state. Gating the pass on the cohort
    ///      would skip that housekeeping in precisely the batch that ends the window, since a
    ///      caller finishing the inventory has no reason to submit a second list. With no cohort
    ///      the eligible size is zero, so the close branch is the only one that goes quiet.
    ///
    ///      An account the deferred pass leaves listed past its collateral — no cohort covers it
    ///      whole, and the fund cannot afford its netting while keeping its reserve and the whole
    ///      remaining inventory's bankruptcy-priced close backed — is resolved through the
    ///      inventory leg: the leg is sized so that the fund can absorb every such account by
    ///      netting and still carry the inventory those nettings leave (_sizeToAffordNettings), and
    ///      the deferred pass runs once more after it, with no cohort and taking only such
    ///      accounts, to make those nettings. Since the nettings retire inventory themselves, the
    ///      fund can be able to carry what they leave with nothing closed; the size is then zero
    ///      and the second pass makes them all the same. A leg that closes part of a positive size
    ///      leaves that pass keeping the whole remainder backed, as the first pass does, and one
    ///      that closes none of it leaves the first pass's refusals standing. The fund then pays
    ///      what it can afford, as the liquidation that deferred the account would have. None of
    ///      that loss reaches the inventory's winners:
    ///      the leg settles at the settlement price only the units its restoring figure calls
    ///      for (_sizeToRestoreHealth), and once those have closed it closes the units past them
    ///      at the mark, the fund paying their distance to the settlement price. Settled at the
    ///      bankruptcy price instead, those units would haircut the inventory's winners to pay a
    ///      loss the deferred accounts owe their own counterparties on the inventory's side. The
    ///      fund can always pay for them: the restoring units leave it able to finish what
    ///      remains at the band edge, which lies further from the settlement price than the mark
    ///      does, so the capital that carries the remainder covers that distance on any part of
    ///      it, with the reserve kept.
    ///
    ///      Once the inventory is empty, deferred accounts that are still open are seized on the
    ///      spot and become the inventory — there is nothing left to net them against, and
    ///      leaving them open would keep a window pending with nothing for the auction to close
    ///      — so the health check that follows re-targets the window at their counterparties.
    /// @param winners The cohort opposite the vault's inventory, descending score
    /// @param deferredWinners The cohort on the inventory's side, descending score, to be closed
    ///        against the deferred accounts
    function executeAdlCore(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        address[] storage deferred,
        address[] calldata winners,
        address[] calldata deferredWinners,
        BazaarTypes.AdlParams memory params,
        uint64 adlEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    ) external returns (BazaarTypes.AdlResult memory r) {
        if (winners.length == 0 && deferredWinners.length == 0) {
            revert AdlLib__EmptySubmission();
        }
        uint256 longest = winners.length > deferredWinners.length ? winners.length : deferredWinners.length;
        if (longest > MAX_ADL_WINNERS_PER_BATCH) revert AdlLib__TooManyWinners(longest, MAX_ADL_WINNERS_PER_BATCH);
        if (pairVault.pendingLiqSize == 0 && deferred.length == 0) revert AdlLib__NoPendingLiquidations();

        Rewards memory rw;
        // The part of the inventory leg's close settled at the mark rather than at the
        // settlement price, for the price range AdlExecuted reports.
        uint256 markSettled;
        // The size the leg was sized to close so that the fund can net every listed account past
        // its collateral (_sizeToAffordNettings), zero when it can as it stands.
        uint256 plannedClose = NO_PLAN;

        if (deferred.length != 0 && pairVault.pendingLiqSize != 0) {
            r.deferredClosedSize = _closeDeferred(
                orders,
                book,
                positionBuckets,
                pairVault,
                deferred,
                deferredWinners,
                params,
                rw,
                _unheldEpoch(adlEpoch),
                adlDepositEpoch,
                adlWindowDeposits
            );
        }

        // The winners were chosen for the side the window targeted when the batch began, and the
        // deferred pass can have moved the inventory onto that side since: a netting larger than
        // the inventory hands the remainder over, and one that empties it exactly lets the next
        // listed account seed a fresh aggregate on its own side. Closing the winners against an
        // inventory on their own side would take the closed size out of both that side's open
        // interest and the inventory, leaving the other side that much exposure with no
        // counterparty. The leg is skipped rather than reverted so the deferred resolutions
        // stand; the health check after the batch re-targets the window at the new side.
        if (
            pairVault.pendingLiqSize != 0 && pairVault.pendingLiqIsLong != params.adlLongs
                && (winners.length != 0 || deferred.length != 0)
        ) {
            Inventory memory inv = _loadInventory(pairVault);
            r.settlementPrice = _settlementPrice(inv, params.currentPrice);

            // Pass 1: Scan eligible winners (read-only)
            (r.eligibleSize, r.eligibleCount, r.highestAdlScore, r.lowestAdlScore) = _scanEligibleWinners(
                positionBuckets, winners, params, inv.size, adlEpoch, adlDepositEpoch, adlWindowDeposits
            );

            if (r.eligibleSize != 0 || deferred.length != 0) {
                uint256 mmrBp = BucketLib.effectiveMmrBp(params.marginRequirements);
                uint256 accrued = rw.seizure + Math.mulDiv(rw.averted, BazaarTypes.ADL_EXECUTOR_REWARD_BP, BP_SCALE);
                uint256 restoringSize = _sizeToRestoreHealth(pairVault, params, inv, r.settlementPrice, mmrBp, accrued);
                uint256 batchSize = restoringSize;
                // Accounts the deferred pass left listed past their collateral hold the window
                // open however the inventory reads, and only the fund absorbing them ends it.
                // What the exposure requires is then the size after which the fund can net every
                // one of them and still carry what remains (_sizeToAffordNettings). That figure
                // is sized on the release condition of the inventory the nettings leave, so it
                // replaces the restoring figure rather than competing with it: the nettings take
                // inventory off the fund too, which can put it below the restoring figure, and
                // closing to the larger would haircut winners for units the nettings retire. That
                // holds down to a figure of zero, when the fund can net them as it stands: the
                // batch then closes nothing and the pass after the leg takes them. Nettings need
                // no winner, so the figure is taken whether or not the scan admitted one.
                if (deferred.length != 0) {
                    (uint256 nettingSize, bool planned) = _sizeToAffordNettings(
                        pairVault,
                        positionBuckets,
                        deferred,
                        params,
                        inv,
                        r.settlementPrice,
                        mmrBp,
                        accrued,
                        restoringSize
                    );
                    if (planned) {
                        batchSize = nettingSize;
                        plannedClose = nettingSize;
                    }
                }
                // Cap how much we attempt to close at the smaller of eligible-winner size and
                // pending liq, then at the batch size: a deleverage takes what the exposure
                // requires and no more. The cap holds for the whole batch, so the loop needs no
                // per-winner health re-check — its own `totalClosed >= requiredSize` break
                // enforces it.
                uint256 effectiveSize = r.eligibleSize < inv.size ? r.eligibleSize : inv.size;
                if (batchSize < effectiveSize) effectiveSize = batchSize;
                // Only the restoring units, those _sizeToRestoreHealth finds the fund cannot carry,
                // settle at the settlement price. Units past them are closed for the deferred
                // accounts alone, and settled at the bankruptcy price they would haircut the
                // inventory's winners to pay a loss those accounts owe their own counterparties;
                // they settle at the mark instead. With the mark as the settlement price the two
                // coincide and one close takes the whole batch.
                uint256 settledSize = restoringSize < effectiveSize && r.settlementPrice != params.currentPrice
                    ? restoringSize
                    : effectiveSize;
                if (settledSize != 0) {
                    r.totalLiqSize = _closeAdlWinners(
                        orders,
                        book,
                        positionBuckets,
                        pairVault,
                        winners,
                        params,
                        settledSize,
                        r.settlementPrice,
                        inv,
                        true,
                        adlEpoch,
                        adlDepositEpoch,
                        adlWindowDeposits
                    );
                    rw.averted += _avertedLoss(inv.isLong, params.currentPrice, r.settlementPrice, r.totalLiqSize);
                }
                // The rest of the batch closes only once the restoring units have closed in full:
                // short of them — a winner at a loss at the bankruptcy price is skipped — the
                // batch has not reached the state it was sized for, and closing more would spend
                // the fund's capital without ending the window. The rest settles at the mark, and
                // the fund can pay its distance to the settlement price: the restoring units leave
                // it able to finish what remains at the band edge, which lies further from the
                // settlement price than the mark does, so the capital that carries the remainder
                // covers that distance on any part of it, with the reserve kept.
                if (settledSize < effectiveSize && r.totalLiqSize == settledSize) {
                    markSettled = _closeAdlWinners(
                        orders,
                        book,
                        positionBuckets,
                        pairVault,
                        winners,
                        params,
                        effectiveSize - settledSize,
                        params.currentPrice,
                        inv,
                        true,
                        adlEpoch,
                        adlDepositEpoch,
                        adlWindowDeposits
                    );
                    r.totalLiqSize += markSettled;
                }
            }
        }

        // The inventory leg moves what the nettings' gate reads: every unit closed settles its
        // slice, takes its share off what the inventory left has to keep, and, once live open
        // interest is down to the reading the reserve is sized on, frees its share of the
        // reserve. Nettings the deferred pass had to refuse can fit now, and the batch was sized
        // for exactly that: the accounts past their collateral. The pass runs again with no
        // cohort to close against and takes only those, so what the close freed goes to the
        // nettings it was raised for. It runs too when the plan was to close nothing, the fund
        // being able to net them as it stands. With nothing closed and no such plan it is
        // skipped: nothing was freed for it, and the first pass has already offered every
        // account its netting.
        if ((r.totalLiqSize != 0 || plannedClose == 0) && deferred.length != 0 && pairVault.pendingLiqSize != 0) {
            DeferredPass memory d = _deferredPass(pairVault, params, rw);
            d.heldOnly = true;
            // The nettings' gate keeps what the inventory they leave needs to close at its
            // bankruptcy price out of their reach. When the leg closed what it planned, that
            // inventory is what is left once every account this pass takes is netted, which the
            // plan sized the fund to carry; protecting the whole remainder instead would refuse
            // nettings the batch was sized for. A leg short of its plan — too few eligible
            // winners, a winner skipped at the price it would close at, or a close stopped by a
            // deficit — vouches for no such end state: gated on it, the first nettings could spend
            // backing the inventory still needs once a later one is refused. Each netting then
            // keeps the whole remainder backed, as in the first pass.
            if (r.totalLiqSize == plannedClose) {
                uint256 held = _heldSize(positionBuckets, deferred, d.lp, pairVault.pendingLiqIsLong);
                uint256 left = pairVault.pendingLiqSize;
                d.keep = left > held ? left - held : 0;
            }
            _walkDeferred(
                orders,
                book,
                positionBuckets,
                pairVault,
                deferred,
                deferredWinners,
                d,
                _unheldEpoch(adlEpoch),
                adlDepositEpoch,
                adlWindowDeposits
            );
        }

        if (pairVault.pendingLiqSize == 0 && deferred.length != 0) {
            _seizeRemainingDeferred(orders, book, positionBuckets, pairVault, deferred, params, rw);
        }
        // Nothing to do at all: no winner passed the scan on the inventory's side and no deferred
        // account was seized (every close against one begins with its seizure). A winner the
        // scan admitted but the close skipped at the settlement price is not that case, so the
        // batch returns quietly.
        if (r.eligibleSize == 0 && rw.seized == 0) revert AdlLib__NoEligibleWinners();

        _payRewards(pairVault, feeEscrow, params.pairId, rw);
        _emitExecuted(params, r, markSettled);
    }

    /// @dev AdlExecuted with the range of prices the inventory leg settled at: its settlement
    ///      price, the mark when part of the close settled there, or the mark alone when all of
    ///      it did.
    /// @param params The batch parameters
    /// @param r The batch's result: the leg's settlement price, its total close and its scores
    /// @param markSettled The part of the leg's close that settled at the mark
    function _emitExecuted(BazaarTypes.AdlParams memory params, BazaarTypes.AdlResult memory r, uint256 markSettled)
        internal
    {
        uint256 highest = r.settlementPrice;
        uint256 lowest = highest;
        if (markSettled != 0) {
            if (markSettled == r.totalLiqSize) {
                highest = params.currentPrice;
                lowest = params.currentPrice;
            } else if (params.currentPrice > highest) {
                highest = params.currentPrice;
            } else {
                lowest = params.currentPrice;
            }
        }
        emit AdlExecuted(
            params.pairId,
            params.adlId,
            params.adlLongs,
            msg.sender,
            highest,
            lowest,
            r.highestAdlScore,
            r.lowestAdlScore,
            params.adlSnapshotPrice,
            block.timestamp
        );
    }

    /// @notice The ranking denominator: the bucket's collateral at the snapshot less any deposit
    ///         tagged to the current ADL window, floored at 1.
    /// @dev A deposit made while the account was already in range for this window must not
    ///      improve its queue position, which is what dividing by the pre-deposit collateral
    ///      guarantees. Deposits from earlier windows (a different epoch) are not subtracted.
    ///      `adlWindowDeposits` is read only when the tag's epoch matches, so a caller that
    ///      passes an epoch no tag holds (_unheldEpoch) ranks on the full collateral. Floored at
    ///      1 so a zero-collateral winner ranks at the top rather than reverting the batch —
    ///      profit on no collateral is the strongest possible claim.
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

    /// @notice The ranking denominator as the lens computes it: the bucket's collateral at the
    ///         snapshot less the already-epoch-checked deposit, floored at 1.
    /// @param effectiveCollateral The bucket's collateral at the ranking snapshot
    /// @param windowDeposit The already-epoch-checked deposit tagged to the current ADL window
    /// @return The collateral denominator used in the ADL score
    function _scoreCollateral(uint256 effectiveCollateral, uint256 windowDeposit) internal pure returns (uint256) {
        uint256 base = effectiveCollateral > windowDeposit ? effectiveCollateral - windowDeposit : 0;
        return base == 0 ? 1 : base;
    }

    /// @notice An epoch no deposit tag holds: one past the window's current epoch.
    /// @dev A tag carries the epoch of the window it was made in, and the counter only advances,
    ///      so no tag is ahead of it. The deferred cohort is scored with this in place of the
    ///      window's epoch (_closeDeferred), which leaves its window deposits in its collateral:
    ///      that cohort ranks at the price, funding index and collateral of the call itself, and
    ///      there is no snapshot for a deposit to postdate. Derived from the live counter rather
    ///      than written as a literal (`type(uint64).max` would do): a literal argument has the
    ///      optimizer specialise a copy of every function on the path down to _closeAdlWinners,
    ///      and that copy does not fit the stack. Unchecked so the wrap at the counter's limit,
    ///      2⁶⁴ windows away, cannot revert a batch.
    /// @param adlEpoch The window's current epoch
    /// @return An epoch no tag holds
    function _unheldEpoch(uint64 adlEpoch) private pure returns (uint64) {
        unchecked {
            return adlEpoch + 1;
        }
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

    /// @notice The inventory size whose closure at `settlementPrice` brings the vault back under
    ///         the ADL cancel threshold, or `type(uint256).max` when no size does.
    /// @dev Sizes the batch so a deleverage takes only what the exposure requires. Bounding by
    ///      winner count instead would let one account large enough to cover the aggregate absorb
    ///      all of it: every unit past this figure settles a solvent trader at the batch's
    ///      settlement price for no protective gain, and the executor reward — linear in the size
    ///      closed — pays for the excess.
    ///
    ///      The target is the gate's release condition: the fund's budget (_releaseFigures) must
    ///      be able to finish the remaining inventory at the unload band's edge, so the walk that
    ///      resumes afterwards can sell it inside the band without reopening the window. Closing
    ///      one unit moves both sides of that comparison. The finish cost falls by its per-unit
    ///      share. The budget moves by what the unit's settlement hands the fund — the earmark
    ///      released plus the realization at the settlement price, which at the bankruptcy price
    ///      is the earmark less the unpaid collateral and the holding-window funding, the funding
    ///      the estates paid or received before liquidation being folded into that price — less
    ///      the executor's share of the bad debt the unit averts, debited on this batch's own
    ///      closed size before the health re-evaluation that ends the auction; and it rises by
    ///      the reserve on the unit itself. A close removes the unit from the vault's side and
    ///      from the winner's, so per-side open interest falls by it and the reserve, a share of
    ///      the target on that open interest, falls with it: capital that returns to the budget
    ///      without a dollar moving. The reserve is sized on live open interest only up to its
    ///      trailing minimum (RiskParamsLib.reserveOiSizeOf), so while live open interest sits
    ///      above that minimum the first units closed release nothing: the release starts once
    ///      the close has brought live open interest down to it.
    ///
    ///      Progress per unit is therefore the settlement price's distance to the band edge, less
    ///      the executor's cut, plus the release — positive whenever the band is, so a batch sized
    ///      here lands on the release line where one sized against the finish cost alone would
    ///      stop short of it. Every leg is linear in the size closed under the proportional
    ///      decrement _releaseSlice applies, and none depends on which winner takes the other
    ///      side, so one figure holds for the whole batch; _sizeToCover solves the two segments.
    ///      ROUNDING_ALLOWANCE on top, so the pro-rata shares each slice rounds on its own cannot
    ///      land the release a few wei short and leave a second call to close dust.
    ///
    ///      With a zero band the settlement price can be the band edge itself, where a unit
    ///      closed takes the same off the finish cost and the budget and no size restores health:
    ///      the auction then runs to its eligible size, and the timeout or a recorded deficit
    ///      resolves it.
    ///
    ///      What the batch has already earned closing the deferred cohort is paid from the same
    ///      free capital after this close, so it is part of the distance to cover.
    /// @param pairVault The pair's vault aggregates
    /// @param params The batch parameters
    /// @param inv The vault's inventory as loaded for the leg, read only
    /// @param settlementPrice The inventory leg's settlement price (_settlementPrice)
    /// @param mmrBp The maintenance rate the unload band is derived from (BucketLib.effectiveMmrBp)
    /// @param accruedReward The executor's reward accrued in this batch before this close
    /// @return The size to close, 0 when the vault already meets the release condition
    function _sizeToRestoreHealth(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.AdlParams memory params,
        Inventory memory inv,
        uint256 settlementPrice,
        uint256 mmrBp,
        uint256 accruedReward
    ) internal view returns (uint256) {
        // The gate's own reading first, so the figure is 0 exactly when the gate would release.
        (, uint256 base, uint256 worstFinish,) =
            RiskParamsLib.vaultAdlExposure(pairVault, params.currentPrice, params.currentFundingIndex, mmrBp);
        if (worstFinish + accruedReward <= base) return 0;

        (int256 progress, uint256 finish, int256 budget, uint256 heldBack) =
            _releaseFigures(pairVault, params, inv, settlementPrice, mmrBp);
        uint256 need = finish + accruedReward + ROUNDING_ALLOWANCE;
        if (int256(need) <= budget) return 0;
        progress += int256(finish)
        - int256(
            Math.mulDiv(
                _avertedLoss(inv.isLong, params.currentPrice, settlementPrice, inv.size),
                BazaarTypes.ADL_EXECUTOR_REWARD_BP,
                BP_SCALE
            )
        );
        return _sizeToCover(
            uint256(int256(need) - budget),
            progress,
            RiskParamsLib.adlReserveOf(inv.size, params.currentPrice, pairVault.targetInsuranceRatioBp),
            RiskParamsLib.adlReserveOf(heldBack, params.currentPrice, pairVault.targetInsuranceRatioBp),
            heldBack,
            inv.size
        );
    }

    /// @notice The figures a close at `settlementPrice` is sized on, read over the whole
    ///         inventory.
    /// @dev The gate's release condition, LiquidationLib.nettingAffordable's backing and
    ///      VaultHealthLib's release reduced to one budget: free capital above the reserve
    ///      (negative by the shortfall below it) plus the ledger's arrears, which both a netting's
    ///      loss and a close's loss are paid net of. Free capital is taken signed, the balance
    ///      less the earmark: a fund holding less than it has earmarked is short by the
    ///      difference, and what the closes hand it fills that hole before any of it reaches the
    ///      reserve or the finish cost — the gate reads such a fund as holding nothing, and would
    ///      go on reading it so after a close sized as if the hole were not there. Against the
    ///      budget, what finishing the inventory at the band edge would cost beyond its earmark,
    ///      taken without the arrears since the budget counts them once, and what closing the
    ///      inventory at `settlementPrice` hands the fund: the earmark released plus the
    ///      realization there. _releaseSlice decrements the inventory it is given, so each reading
    ///      runs on its own copy.
    /// @param pairVault The pair's vault aggregates
    /// @param params The batch parameters
    /// @param inv The vault's inventory as loaded for the leg, read only
    /// @param settlementPrice The price the close settles at
    /// @param mmrBp The maintenance rate the unload band is derived from (BucketLib.effectiveMmrBp)
    /// @return progress The earmark plus the realization at `settlementPrice` over the whole
    ///         inventory, negative when the close costs the fund
    /// @return finish What finishing the whole inventory at the band edge would cost beyond its
    ///         earmark; 0 when the earmark covers the loss there
    /// @return budget The balance less the earmark and the reserve, plus the arrears: negative by
    ///         any shortfall below the reserve, or below the earmark itself
    /// @return heldBack Live open interest above the trailing reading the reserve is sized on:
    ///         units that close without releasing any reserve
    function _releaseFigures(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.AdlParams memory params,
        Inventory memory inv,
        uint256 settlementPrice,
        uint256 mmrBp
    ) internal view returns (int256 progress, uint256 finish, int256 budget, uint256 heldBack) {
        (int256 pnl, uint256 earmark) = _releaseSlice(_copy(inv), params.currentFundingIndex, inv.size, settlementPrice);
        progress = pnl + int256(earmark);
        uint256 bandBp = mmrBp < BazaarTypes.LIQ_MAX_SLIPPAGE_BP ? mmrBp : BazaarTypes.LIQ_MAX_SLIPPAGE_BP;
        uint256 bandEdge = inv.isLong
            ? params.currentPrice * (BP_SCALE - bandBp) / BP_SCALE
            : params.currentPrice * (BP_SCALE + bandBp) / BP_SCALE;
        (pnl,) = _releaseSlice(_copy(inv), params.currentFundingIndex, inv.size, bandEdge);
        pnl += int256(earmark);
        if (pnl < 0) finish = uint256(-pnl);
        uint256 reserve = RiskParamsLib.adlReserve(pairVault, params.currentPrice);
        budget = int256(pairVault.insuranceFundBalance) - int256(pairVault.pendingLiqSeized) - int256(reserve)
            + int256(pairVault.ledgerArrears);
        uint256 liveOi = RiskParamsLib.openInterestSize(pairVault);
        heldBack = liveOi - RiskParamsLib.reserveOiSizeOf(liveOi, pairVault.trailingOiSize);
    }

    /// @notice The smallest size whose close covers `distance`, when closing all of `size`
    ///         progresses `progress` before any reserve release and the units past the first
    ///         `heldBack` release `reserve` between them.
    /// @dev With units that release nothing ahead of the ones that do, progress is two straight
    ///      segments, and the size is the smaller of two solutions: the one that never reaches
    ///      the release, and the one that counts it from the first unit and adds the reserve on
    ///      the unreleased stretch to the distance. The first is the answer when it falls inside
    ///      that stretch and the second when it does not, and in each case it is the smaller.
    ///      Neither solution exists when its denominator is non-positive: closing drains the fund
    ///      at least as fast as it repairs it.
    ///
    ///      Rounded up: landing a fraction of a unit short leaves the auction pending for a
    ///      second call that closes dust.
    /// @param distance What the close has to cover
    /// @param progress What closing the whole `size` contributes before any reserve release;
    ///        negative when closing costs the fund
    /// @param reserve The reserve released by closing the whole `size`, were every unit to release
    /// @param reserveHeldBack The reserve on the first `heldBack` units, which release nothing
    /// @param heldBack The units that close without releasing any reserve
    /// @param size The size the whole-inventory figures are measured over
    /// @return result The size to close, type(uint256).max when no size covers the distance
    function _sizeToCover(
        uint256 distance,
        int256 progress,
        uint256 reserve,
        uint256 reserveHeldBack,
        uint256 heldBack,
        uint256 size
    ) internal pure returns (uint256 result) {
        result = type(uint256).max;
        int256 denominator = progress + SafeCast.toInt256(reserve);
        if (denominator > 0) {
            result = Math.mulDiv(distance + reserveHeldBack, size, uint256(denominator), Math.Rounding.Ceil);
        }
        if (heldBack != 0 && progress > 0) {
            uint256 withoutRelease = Math.mulDiv(distance, size, uint256(progress), Math.Rounding.Ceil);
            if (withoutRelease < result) result = withoutRelease;
        }
    }

    /// @notice The figures _sizeToAffordNettings gathers over the deferred list.
    /// @param cost What netting every listed account at its full size costs the fund beyond the
    ///        two netted slices' own backing
    /// @param size The listed accounts' total size: the inventory the nettings consume
    /// @param reward The seizure reward those nettings pay the executor
    struct Nettings {
        uint256 cost;
        uint256 size;
        uint256 reward;
    }

    /// @notice The size the inventory leg has to close so that the fund can absorb every account
    ///         the deferred pass left listed past its collateral by netting it, and still carry
    ///         the inventory those nettings leave: keep its close at the bankruptcy price backed
    ///         and meet the release condition on it.
    /// @dev An account is still listed after the pass because no cohort covers it whole and its
    ///      netting against the inventory costs more than the fund may spend. Of these, the ones
    ///      past their collateral are what the gate counts, and they hold the window open however
    ///      the inventory reads; the size is for them alone. An account within its collateral
    ///      holds nothing open: the window releases once the inventory is covered, the release
    ///      clears the list, and the account is an ordinary liquidation candidate again. Nothing
    ///      else can take an account past its collateral: it sits opposite the inventory, the
    ///      vault holds one aggregate, so seizing it is that netting, and the window it holds
    ///      open halts every unload. The inventory leg is what moves the fund's means. Each unit
    ///      it closes hands the fund the slice's earmark plus its realization at the price it
    ///      settles at, takes its share off what the fund has to keep for the remainder, and,
    ///      once live open interest is down to the trailing reading the reserve is sized on,
    ///      frees the unit's share of the reserve. Where closing enough units makes the nettings
    ///      affordable, the pass that runs after the leg takes them, and only them; where the
    ///      fund can afford them with no close at all, that pass takes them with nothing closed;
    ///      where no close short of the whole inventory does, the whole inventory goes (below).
    ///
    ///      Sized to end the window in one batch rather than merely to afford the nettings: a
    ///      netting that just fits leaves the fund holding no more above its reserve than the gate
    ///      keeps for the inventory it leaves, and the release condition can need more — that
    ///      inventory's band-edge finish cost where it is the larger figure, and the rewards the
    ///      batch pays after the nettings — and the batch that then closes the rest at the mark
    ///      averts nothing and so pays nothing. The condition is the gate's release
    ///      test on the post-netting state, on the budget _releaseFigures reads, with the
    ///      nettings' own gate folded in: the budget after the batch has to cover the nettings'
    ///      cost beyond the netted slices' own backing, what the inventory they leave has to keep,
    ///      and what the batch pays its executor — the reward accrued before this close and the
    ///      seizure reward of every account netted, both debited from free capital before the
    ///      health check that ends the window.
    ///
    ///      What that inventory has to keep is the larger of two figures over the whole
    ///      inventory, taken pro rata: its finish cost at the band edge, which the release test
    ///      reads, and the cost beyond its earmark of closing it at the estates' bankruptcy price
    ///      (RiskParamsLib.bankruptcyCloseCost), which the nettings' gate holds out of their reach
    ///      (LiquidationLib.nettingAffordable) so that a later bankruptcy-priced close of it books
    ///      no deficit. The two prices value the same inventory against the same earmark, so the
    ///      finish cost is the larger when the band edge lies past the bankruptcy price, on the
    ///      side where the inventory loses, and the bankruptcy-priced close when the edge lies
    ///      short of it. That close needs the collateral the deposits ledger could not hand over
    ///      at seizure and the net funding the vault paid holding the inventory, and with the edge
    ///      short of the bankruptcy price the finish cost can read zero while it does: counted at
    ///      the finish cost alone, a close the gate needs would read as unneeded, the batch would
    ///      close nothing, and the gate would refuse every netting, batch after batch. Counted at
    ///      the larger, a batch sized here clears the gate for every one of them.
    ///
    ///      Every term is linear in the size closed, so the same two-segment solve as
    ///      _sizeToRestoreHealth gives the size: progress per unit is the earmark plus the
    ///      realization, plus the unit's share of what the remainder has to keep, which the close
    ///      takes off it, less the executor's cut of what the close averts; the reserve release is
    ///      the same figure. The nettings themselves free reserve too, which is left out, so the
    ///      size errs toward closing a little more rather than leaving the window open.
    ///
    ///      That progress is read at the settlement price. When the settlement price is the
    ///      bankruptcy price, executeAdlCore settles only the first `restoringSize` units there
    ///      and closes the rest at the mark, where a unit realizes less by the distance between
    ///      the two prices and averts nothing. A close that needs units past `restoringSize` is
    ///      therefore solved again from that point on the mark's progress (_sizePastRestore),
    ///      which takes more units to cover the same distance.
    ///
    ///      Valid while the inventory left after the close still covers every listed account, so
    ///      each netting runs at the account's full size and costs what the pass measured. Past
    ///      that point the nettings would consume the whole inventory and flip the remainder onto
    ///      the deferred side, and the fund would have paid netting costs for inventory it does
    ///      not keep; the whole inventory goes instead, so nothing is spent on nettings, and the
    ///      accounts are seized as the new inventory with nothing to net against. The same
    ///      holds when the listed accounts are at least the inventory's size, and when no size
    ///      covers the distance.
    /// @param pairVault The pair's vault aggregates
    /// @param positionBuckets Storage mapping of position buckets
    /// @param deferred The deferred liquidations, every entry opposite the inventory and insolvent
    /// @param params The batch parameters
    /// @param inv The vault's inventory as loaded for the leg, read only
    /// @param settlementPrice The inventory leg's settlement price (_settlementPrice)
    /// @param mmrBp The maintenance rate the unload band is derived from (BucketLib.effectiveMmrBp)
    /// @param accruedReward The executor's reward accrued in this batch before this close
    /// @param restoringSize The size _sizeToRestoreHealth gives: the units the leg settles at
    ///        `settlementPrice` before it closes the rest at the mark
    /// @return The size to close: 0 when the fund can already net every account past its
    ///         collateral and carry what remains, the whole inventory when no smaller close
    ///         leaves inventory the fund can carry
    /// @return Whether any listed account is past its collateral. When none is, there is nothing
    ///         to plan for: the size is 0 and the restoring figure sizes the batch
    function _sizeToAffordNettings(
        BazaarTypes.Vault storage pairVault,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        address[] storage deferred,
        BazaarTypes.AdlParams memory params,
        Inventory memory inv,
        uint256 settlementPrice,
        uint256 mmrBp,
        uint256 accruedReward,
        uint256 restoringSize
    ) internal view returns (uint256, bool) {
        Nettings memory n;
        {
            BazaarTypes.LiquidateParams memory lp = _liquidateParams(params);
            for (uint256 i = 0; i < deferred.length; i++) {
                BazaarTypes.BucketState memory state = BucketLib.calculateState(
                    positionBuckets[deferred[i]], lp.currentPrice, lp.currentFundingIndex, lp.marginReqs
                );
                // Only an account past its collateral holds the window open, which is the gate's
                // own count (RiskParamsLib.deferredExcess). One within its collateral is left for
                // the release that clears the list, or for a liquidation that names it.
                if (RiskParamsLib.accountExcess(state) == 0) continue;
                uint256 size = state.adjustedSize;
                // The netting's realization at the account's full size, as
                // LiquidationLib._netOpposingLiquidation books it: the entry gap on the overlap
                // plus the two sides' entry-clock offset.
                uint256 inventoryEntry = Math.mulDiv(inv.entryNotional, size, inv.size);
                int256 netPnl = inv.isLong
                    ? int256(state.entryValue) - int256(inventoryEntry)
                    : int256(inventoryEntry) - int256(state.entryValue);
                int256 nettedFunding = BazaarMathLib.signedMulDiv(
                    inv.entryFundingIndex - state.adjustedEntryFundingIndex, int256(size), int256(BAZAAR_SCALE)
                );
                netPnl += inv.isLong ? nettedFunding : -nettedFunding;
                if (netPnl < 0) {
                    // Backed by the netted slices themselves: the inventory's earmark on the
                    // overlap and the account's own collateral. Only the rest draws on the budget.
                    uint256 own = Math.mulDiv(inv.seized, size, inv.size) + state.effectiveCollateral;
                    uint256 loss = uint256(-netPnl);
                    if (loss > own) n.cost += loss - own;
                }
                n.size += size;
                // The seizure reward the netting pays, on the account's full size: the close this
                // solves for leaves inventory covering every listed account, so none of these
                // nettings flips and each retires the whole position.
                n.reward += LiquidationLib.seizureReward(state, size, lp.currentPrice);
            }
        }
        if (n.size == 0) return (0, false);
        if (n.size >= inv.size) return (inv.size, true);

        (int256 progress, uint256 survivorCost, int256 budget, uint256 heldBack) =
            _releaseFigures(pairVault, params, inv, settlementPrice, mmrBp);
        // What the inventory the nettings leave has to keep, over the whole inventory: the larger
        // of the release test's finish cost, as read, and the gate's bankruptcy-priced close.
        {
            uint256 bankruptcyClose = RiskParamsLib.bankruptcyCloseCost(pairVault, params.currentFundingIndex);
            if (bankruptcyClose > survivorCost) survivorCost = bankruptcyClose;
        }
        // ROUNDING_ALLOWANCE on top, so the pro-rata shares the closes and nettings each round on
        // their own cannot land the release, or a netting's gate, a few wei short.
        uint256 need = n.cost + n.reward + accruedReward + Math.mulDiv(survivorCost, inv.size - n.size, inv.size)
            + ROUNDING_ALLOWANCE;
        if (int256(need) <= budget) return (0, true);

        progress += int256(survivorCost)
        - int256(
            Math.mulDiv(
                _avertedLoss(inv.isLong, params.currentPrice, settlementPrice, inv.size),
                BazaarTypes.ADL_EXECUTOR_REWARD_BP,
                BP_SCALE
            )
        );
        uint256 distance = uint256(int256(need) - budget);
        uint256 close = _sizeToCover(
            distance,
            progress,
            RiskParamsLib.adlReserveOf(inv.size, params.currentPrice, pairVault.targetInsuranceRatioBp),
            RiskParamsLib.adlReserveOf(heldBack, params.currentPrice, pairVault.targetInsuranceRatioBp),
            heldBack,
            inv.size
        );
        // Past `restoringSize` the leg closes at the mark, so a close that needs more is solved
        // again on the mark's figures. A restoring size that leaves the nettings no room past it
        // needs no second solve: any close beyond it consumes the inventory they need, and the
        // whole inventory goes either way.
        if (close > restoringSize && restoringSize < inv.size - n.size && settlementPrice != params.currentPrice) {
            close = _sizePastRestore(pairVault, params, inv, distance, progress, survivorCost, heldBack, restoringSize);
        }
        return (close <= inv.size - n.size ? close : inv.size, true);
    }

    /// @notice _sizeToAffordNettings' close when the leg settles only its first `restoringSize`
    ///         units at the settlement price and the rest at the mark.
    /// @dev The restoring units cover what the single solve counts for them: their share of
    ///      `progress`, and the reserve on those of them past the `heldBack` stretch. The rest of
    ///      `distance` falls to units closed at the mark. Each hands the fund the slice's earmark
    ///      plus its realization at the mark, which falls short of the settlement price's by the
    ///      distance between the two prices, and takes its share of `survivorCost` off the
    ///      remainder; it averts nothing, so it pays the executor no cut. Whatever of the
    ///      `heldBack` stretch the restoring units did not use up comes first among them.
    /// @param pairVault The pair's vault aggregates
    /// @param params The batch parameters
    /// @param inv The vault's inventory as loaded for the leg, read only
    /// @param distance What the close has to cover
    /// @param progress What closing the whole inventory at the settlement price contributes
    ///        before any reserve release: the earmark plus the realization there, plus the
    ///        `survivorCost` the closes take off the remainder, less the executor's cut
    /// @param survivorCost What the inventory left has to keep, over the whole inventory: the
    ///        larger of its band-edge finish cost and its bankruptcy-priced close, beyond its
    ///        earmark (_sizeToAffordNettings)
    /// @param heldBack The units that close without releasing any reserve
    /// @param restoringSize The units settled at the settlement price, short of the inventory
    /// @return The size to close, type(uint256).max when no size short of the whole inventory
    ///         covers the distance
    function _sizePastRestore(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.AdlParams memory params,
        Inventory memory inv,
        uint256 distance,
        int256 progress,
        uint256 survivorCost,
        uint256 heldBack,
        uint256 restoringSize
    ) internal view returns (uint256) {
        uint256 reserve = RiskParamsLib.adlReserveOf(inv.size, params.currentPrice, pairVault.targetInsuranceRatioBp);
        int256 covered = BazaarMathLib.signedMulDiv(progress, int256(restoringSize), int256(inv.size));
        if (restoringSize > heldBack) covered += int256(Math.mulDiv(reserve, restoringSize - heldBack, inv.size));
        if (covered >= int256(distance)) return restoringSize;

        (int256 pnl, uint256 earmark) =
            _releaseSlice(_copy(inv), params.currentFundingIndex, inv.size, params.currentPrice);
        uint256 stillHeld = heldBack > restoringSize ? heldBack - restoringSize : 0;
        uint256 extra = _sizeToCover(
            uint256(int256(distance) - covered),
            pnl + int256(earmark) + int256(survivorCost),
            reserve,
            RiskParamsLib.adlReserveOf(stillHeld, params.currentPrice, pairVault.targetInsuranceRatioBp),
            stillHeld,
            inv.size
        );
        return extra < inv.size ? restoringSize + extra : type(uint256).max;
    }

    /// @dev A copy of `inv`, for a reading by a function that decrements the inventory it is
    ///      given. A memory-to-memory struct assignment shares the pointer.
    function _copy(Inventory memory inv) internal pure returns (Inventory memory) {
        return Inventory({
            size: inv.size,
            entryNotional: inv.entryNotional,
            bankruptcyNotional: inv.bankruptcyNotional,
            seized: inv.seized,
            entryFundingIndex: inv.entryFundingIndex,
            isLong: inv.isLong
        });
    }

    /// @notice Pass 1: Read-only scan of winners to determine eligible size and scores
    /// @dev Admitted entries must arrive in descending score order, ties in ascending address
    ///      order. That is a total order, so no account can be admitted twice: a repeat carries
    ///      exactly its predecessor's score and address. The scan stops once `maxSize` is covered
    ///      and checks nothing past that point; for the deferred cohort, _closeSeized refuses a
    ///      remainder such an unchecked repeat would produce.
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
        address prevUser;
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
            // Ties break on ascending address, which makes the order total and rules out the same
            // account twice. That matters for the deferred cohort: _settleableSize adds an
            // account's size once per entry, while the close loop consumes it once, so a repeat
            // would test as covering size the loop cannot close.
            if (adlScore == prevScore && user <= prevUser) {
                revert AdlLib__NotAscendingAddressTie(user, prevUser);
            }
            prevScore = adlScore;
            prevUser = user;

            if (eligibleCount == 0) highestAdlScore = adlScore;
            lowestAdlScore = adlScore;

            uint256 winnerSize = state.adjustedSize;
            uint256 remaining = maxSize - eligibleSize;
            eligibleSize += winnerSize < remaining ? winnerSize : remaining;
            eligibleCount++;
        }
    }

    /// @notice Pass 2: Close eligible winners at the settlement price
    /// @dev `params.adlLongs` is the winners' side. `inv` is what they close against: the
    ///      vault's aggregate, written back after every close when `persistent`, or a deferred
    ///      account seized for this batch, which is never stored.
    function _closeAdlWinners(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        address[] calldata winners,
        BazaarTypes.AdlParams memory params,
        uint256 requiredSize,
        uint256 settlementPrice,
        Inventory memory inv,
        bool persistent,
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

            // Settles the inventory slice through insurance (and releases it from the aggregate,
            // so the next iteration sees the reduced exposure), then sizes the winner's credit.
            // A deferred account's seizure sits in the fund but is not earmarked in the vault's
            // aggregate, so free capital is read net of what is still to be released from it.
            uint256 free = RiskParamsLib.insuranceFreeCapital(pairVault);
            if (!persistent) free = free > inv.seized ? free - inv.seized : 0;
            SliceSettlement memory s =
                _settleSlice(pairVault, inv, free, params.currentFundingIndex, state, closedSize, settlementPrice);
            if (persistent) _storeInventory(pairVault, inv);

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

    /// @notice The state one pass over the deferred list carries, bundled so the pass and its
    ///         helpers keep few live locals.
    /// @param p The batch parameters with `adlLongs` set to the cohort's side
    /// @param lp The same parameters in the shape the seizure takes
    /// @param rw The batch's reward accumulator
    /// @param eligible The cohort's eligible size not yet closed
    /// @param closedTotal The size closed against deferred accounts so far
    /// @param heldOnly Whether the pass takes only accounts past their collateral, the ones the
    ///        window is held open for and the inventory leg was sized to net
    /// @param keep The inventory whose bankruptcy-priced close every netting must leave backed
    ///        (LiquidationLib.nettingAffordable): the whole remainder, or, on the pass after an
    ///        inventory leg that closed what it planned, what the nettings that leg was sized for
    ///        leave
    /// @param flat The flat part of the seizure reward of the account _closeSeized is closing,
    ///        taken before its close and paid after it
    struct DeferredPass {
        BazaarTypes.AdlParams p;
        BazaarTypes.LiquidateParams lp;
        Rewards rw;
        uint256 eligible;
        uint256 closedTotal;
        bool heldOnly;
        uint256 keep;
        uint256 flat;
    }

    /// @notice Closes deferred accounts against the cohort on the inventory's side.
    /// @dev Each account is taken whole or not at all: it is seized only when the cohort can
    ///      absorb its whole position AT ITS SETTLEMENT PRICE — its own bankruptcy price, or the
    ///      mark when the mark sits on the fund's favorable side of it (_settlementPriceOf) — so
    ///      nothing seized here can be left half-closed as a second inventory, and nothing is
    ///      seized that the cohort turns out to refuse. Its counterparties are settled against it
    ///      at that price, where its seizure covers the loss (exactly at the bankruptcy price,
    ///      with room to spare at the mark) and no holding window has accrued any carry, so the
    ///      fund pays nothing.
    ///
    ///      The coverage test is _settleableSize rather than the eligibility scan's figure, and
    ///      the difference is load-bearing: a winner between the live price and the settlement
    ///      price is profitable at the mark, under water at the settlement, and refused by the
    ///      close. Counting it would seize an account with nothing to close against, and the
    ///      seizure would fall through to the netting deferral exists to avoid — which a
    ///      permissionless caller could therefore trigger by choosing such a cohort.
    ///
    ///      An account the cohort cannot cover is netted after all if the closes above freed
    ///      enough capital for its netting to fit, and otherwise stays deferred for the next
    ///      batch. Accounts that are flat or solvent again are dropped from the list.
    /// @return closedTotal The size closed against deferred accounts
    function _closeDeferred(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        address[] storage deferred,
        address[] calldata cohort,
        BazaarTypes.AdlParams memory params,
        Rewards memory rw,
        uint64 scoreEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    ) internal returns (uint256 closedTotal) {
        DeferredPass memory d = _deferredPass(pairVault, params, rw);
        (d.eligible,,,) = _scanEligibleWinners(
            positionBuckets,
            cohort,
            d.p,
            _deferredSize(positionBuckets, deferred),
            scoreEpoch,
            adlDepositEpoch,
            adlWindowDeposits
        );
        _walkDeferred(
            orders,
            book,
            positionBuckets,
            pairVault,
            deferred,
            cohort,
            d,
            scoreEpoch,
            adlDepositEpoch,
            adlWindowDeposits
        );
        closedTotal = d.closedTotal;
    }

    /// @dev The state a pass over the deferred list runs on, with no cohort size yet: a pass
    ///      built here and walked as is drops and nets but closes nothing against the cohort.
    ///
    ///      The cohort is the inventory's own side; a deferred account is always on the other.
    ///      It ranks at the live price rather than the window's snapshot: a deferred account
    ///      entered the window after that snapshot was taken, at a price that made it bankrupt,
    ///      and its counterparties' profit exists at that price and not necessarily at the
    ///      snapshot — an inventory seized on the way down is ranked at the bottom, where the
    ///      longs a later rise bankrupted shorts against had no profit at all. The live price is
    ///      the one this call resolved and stored: the Pyth cache's when the cache is fresh, the
    ///      caller's update only otherwise. It is fixed for the rest of the call, so the ranking
    ///      is deterministic within the call, but not across calls the way the snapshot is across
    ///      a window — a sort made at an older tick is rejected as out of order and must be
    ///      redone at the stored price. The decay threshold is the window's own.
    ///
    ///      It ranks on live collateral too: the window's deposit tags are not subtracted (the
    ///      caller passes an epoch no tag holds as the walk's `scoreEpoch`). The subtraction
    ///      keeps the target side's score pinned to the snapshot the price is frozen at; this
    ///      cohort has no such snapshot, and its tags belong to the side the window was
    ///      deleveraging against, whose deposits defended against liquidation rather than
    ///      against a ranking it was not yet subject to. A re-target voids those tags for the
    ///      same reason; a deferral moves the inventory side into the winners' seat without the
    ///      re-target, so the pass has to do it itself.
    ///
    ///      Built field by field rather than assigned from `params`. A memory-to-memory struct
    ///      assignment shares the pointer, so setting the side and the snapshot through a copy of
    ///      `params` would rewrite the caller's own parameters: the inventory phase would then
    ///      rank its winners against this phase's side, which is the opposite one, and close
    ///      nothing. `d.rw` is shared on purpose — the reward counters this phase accumulates
    ///      have to reach the payout and the empty-batch guard — which is exactly why the
    ///      difference has to be spelled out here. `marginRequirements` is shared too, and only
    ///      ever read.
    ///
    ///      A pass built here has every netting leave the whole remaining inventory backed
    ///      (`keep`); the pass after an inventory leg that closed what it planned lowers that to
    ///      what the nettings it was sized for leave.
    function _deferredPass(BazaarTypes.Vault storage pairVault, BazaarTypes.AdlParams memory params, Rewards memory rw)
        internal
        view
        returns (DeferredPass memory d)
    {
        d.p = BazaarTypes.AdlParams({
            adlLongs: pairVault.pendingLiqIsLong,
            adlSnapshotPrice: params.currentPrice,
            adlSnapshotFundingIndex: params.currentFundingIndex,
            adlAuctionStartTs: params.adlAuctionStartTs,
            currentPrice: params.currentPrice,
            currentFundingIndex: params.currentFundingIndex,
            marginRequirements: params.marginRequirements,
            pairId: params.pairId,
            adlId: params.adlId,
            currentBlock: params.currentBlock
        });
        d.lp = _liquidateParams(params);
        d.rw = rw;
        d.keep = pairVault.pendingLiqSize;
    }

    /// @dev Resolves every listed account in turn (_resolveDeferred). A resolved account is
    ///      swapped out of the list by its last entry, which is then the one at `i`.
    function _walkDeferred(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        address[] storage deferred,
        address[] calldata cohort,
        DeferredPass memory d,
        uint64 scoreEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    ) internal {
        uint256 i;
        while (i < deferred.length) {
            if (_resolveDeferred(
                    orders,
                    book,
                    positionBuckets,
                    pairVault,
                    deferred,
                    cohort,
                    d,
                    i,
                    scoreEpoch,
                    adlDepositEpoch,
                    adlWindowDeposits
                )) {
                continue;
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev One deferred account: dropped if flat or solvent, seized and closed if the cohort
    ///      covers it, netted if that has become affordable, left otherwise. On a held-only pass
    ///      an account within its collateral is left as it is before either is tried.
    /// @return removed True when the entry at `i` was removed from the list
    function _resolveDeferred(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        address[] storage deferred,
        address[] calldata cohort,
        DeferredPass memory d,
        uint256 i,
        uint64 scoreEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    ) internal returns (bool removed) {
        address user = deferred[i];
        BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
        if (bucket.size == 0 || bucket.isLong == d.p.adlLongs) {
            LiquidationLib.removeDeferredAt(deferred, i);
            return true;
        }
        BazaarTypes.BucketState memory state =
            BucketLib.calculateState(bucket, d.lp.currentPrice, d.lp.currentFundingIndex, d.lp.marginReqs);
        if (state.isSolvent) {
            LiquidationLib.removeDeferredAt(deferred, i);
            return true;
        }
        // The pass after the inventory leg takes only what that leg was sized for: the accounts
        // past their collateral, which hold the window open. One within its collateral holds
        // nothing open and was left out of that sizing, so netting it here could spend what the
        // others' nettings need; it is left for the release that clears the list, or for a
        // liquidation that names it.
        if (d.heldOnly && RiskParamsLib.accountExcess(state) == 0) return false;
        // Priced before anything is taken apart: an account seized without a cohort to absorb it
        // would fall through to the netting that deferring it avoided.
        uint256 settlement = _settlementPriceOf(
            bucket.isLong,
            LiquidationLib.bankruptcyNotionalOf(state, bucket.isLong),
            state.adjustedSize,
            d.p.currentPrice
        );
        if (
            d.eligible != 0
                && _settleableSize(
                        positionBuckets,
                        cohort,
                        d.p,
                        settlement,
                        state.adjustedSize,
                        scoreEpoch,
                        adlDepositEpoch,
                        adlWindowDeposits
                    ) >= state.adjustedSize
        ) {
            _closeSeized(
                orders,
                book,
                positionBuckets,
                pairVault,
                cohort,
                d,
                user,
                state,
                settlement,
                scoreEpoch,
                adlDepositEpoch,
                adlWindowDeposits
            );
            LiquidationLib.removeDeferredAt(deferred, i);
            return true;
        }
        if (LiquidationLib.nettingAffordable(pairVault, state, d.lp.currentPrice, d.lp.currentFundingIndex, d.keep)) {
            LiquidationLib.Estate memory e = LiquidationLib.seize(user, bucket, state, orders, book, pairVault, d.lp);
            // On what the absorb retires: the overlap with an inventory on the other side. An
            // estate larger than that inventory leaves the rest as the new one; once a netting has
            // done so, a later account sits on the inventory's side and merges into it; and an
            // inventory a netting emptied exactly is seeded by the next account. None of those
            // retires anything.
            {
                uint256 retired = LiquidationLib.nettedSize(pairVault, e.isLong, e.size);
                d.rw.seizure += LiquidationLib.seizureReward(state, retired, d.lp.currentPrice);
            }
            ++d.rw.seized;
            LiquidationLib.absorb(pairVault, e);
            LiquidationLib.removeDeferredAt(deferred, i);
            return true;
        }
        return false;
    }

    /// @dev Seize one deferred account and close the cohort against it at `settlement`, the price
    ///      its coverage was tested at. The test applies the close loop's own filters, so the
    ///      cohort takes the whole account unless the loop stops early, which it does only on a
    ///      deficit booked by one of its own slices — an estate whose bankruptcy price was struck
    ///      against collateral the deposits ledger could not hand over in full. What that leaves
    ///      is absorbed into the vault's aggregate, with the netting's own cap as the backstop,
    ///      and the health check that follows freezes the pair on the deficit either way.
    ///
    ///      A remainder with no deficit means the test admitted size the loop could not consume:
    ///      an account listed more than once adds its size once per entry there and is closed
    ///      once here. Absorbing that remainder would be the netting the deferral refused, with
    ///      no affordability gate in front of it, so the batch reverts instead.
    function _closeSeized(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        address[] calldata cohort,
        DeferredPass memory d,
        address user,
        BazaarTypes.BucketState memory state,
        uint256 settlement,
        uint64 scoreEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    ) internal {
        LiquidationLib.Estate memory e = LiquidationLib.seize(
            user, positionBuckets[user], state, orders, book, pairVault, d.lp
        );
        ++d.rw.seized;
        // Kept in the pass rather than a local: nothing more fits on the stack across the close.
        d.flat = LiquidationLib.flatReward(state);
        Inventory memory t =
            Inventory(e.size, e.entryNotional, e.bankruptcyNotional, e.seized, e.entryFundingIndex, e.isLong);
        uint256 closed = _closeAdlWinners(
            orders,
            book,
            positionBuckets,
            pairVault,
            cohort,
            d.p,
            e.size,
            settlement,
            t,
            false,
            scoreEpoch,
            adlDepositEpoch,
            adlWindowDeposits
        );
        d.closedTotal += closed;
        d.eligible -= closed;
        d.rw.averted += _avertedLoss(t.isLong, d.p.currentPrice, settlement, closed);
        if (t.size != 0) {
            if (pairVault.deficit == 0) revert AdlLib__CohortDidNotCover(t.size);
            // The remainder nets against an opposite inventory where it overlaps, which retires
            // that much too, so the overlap joins `closed` for the reward below; any rest joins the
            // inventory. One variable rather than two: nothing more fits on the stack here.
            closed += LiquidationLib.nettedSize(pairVault, t.isLong, t.size);
            LiquidationLib.absorb(
                pairVault,
                LiquidationLib.Estate(
                    t.size, t.entryNotional, t.bankruptcyNotional, t.seized, t.entryFundingIndex, t.isLong
                )
            );
        }
        // The seizure reward on what the batch retired with the account
        // (LiquidationLib.seizureReward): the cohort's close and any netting of the remainder.
        {
            uint256 rate = LiquidationLib.rateOn(closed, d.lp.currentPrice);
            d.rw.seizure += rate > d.flat ? rate : d.flat;
        }
    }

    /// @notice Seizes every deferred account still open once the vault holds no inventory, so
    ///         they become the inventory the next health check re-targets the window at.
    /// @dev Every entry left here sits on one side: the per-account pass delists every account
    ///      on the batch-start inventory side before this runs, and nothing lists an account
    ///      mid-batch. The first seizure therefore seeds the inventory and every later one
    ///      merges into it, so no seizure nets and no affordability gate is needed.
    function _seizeRemainingDeferred(
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.OrderBook storage book,
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        address[] storage deferred,
        BazaarTypes.AdlParams memory params,
        Rewards memory rw
    ) internal {
        BazaarTypes.LiquidateParams memory lp = _liquidateParams(params);
        while (deferred.length != 0) {
            address user = deferred[deferred.length - 1];
            deferred.pop();
            BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
            if (bucket.size == 0) continue;
            BazaarTypes.BucketState memory state =
                BucketLib.calculateState(bucket, lp.currentPrice, lp.currentFundingIndex, lp.marginReqs);
            if (state.isSolvent) continue;
            LiquidationLib.Estate memory e = LiquidationLib.seize(user, bucket, state, orders, book, pairVault, lp);
            // The account seeds or joins the inventory: exposure moved onto the fund, which earns
            // the flat reward alone, as liquidate() pays for such a seizure. Whoever later retires
            // it is paid for that.
            rw.seizure += LiquidationLib.flatReward(state);
            ++rw.seized;
            LiquidationLib.absorb(pairVault, e);
        }
    }

    /// @dev The executor's reward for the whole batch: every seizure it performed plus its share
    ///      of the bad debt its closes averted, together capped at the fund's free capital.
    function _payRewards(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        bytes32 pairId,
        Rewards memory rw
    ) internal {
        uint256 reward =
            rw.seizure + Math.mulDiv(rw.averted, BazaarTypes.ADL_EXECUTOR_REWARD_BP, BP_SCALE);
        uint256 free = RiskParamsLib.insuranceFreeCapital(pairVault);
        if (reward > free) reward = free;
        if (reward > 0) {
            pairVault.insuranceFundBalance -= reward;
            FeeEscrowLib.credit(feeEscrow, pairId, msg.sender, reward);
        }
    }

    /// @dev The bad debt a close averted: the distance from the mark to the settlement price on
    ///      the closed size, in the direction that would have cost the fund; nothing once the
    ///      mark sits on the fund's favorable side.
    function _avertedLoss(bool inventoryIsLong, uint256 currentPrice, uint256 settlementPrice, uint256 closedSize)
        internal
        pure
        returns (uint256)
    {
        if (inventoryIsLong) {
            return
                currentPrice < settlementPrice
                    ? Math.mulDiv(closedSize, settlementPrice - currentPrice, BAZAAR_SCALE)
                    : 0;
        }
        return
            currentPrice > settlementPrice ? Math.mulDiv(closedSize, currentPrice - settlementPrice, BAZAAR_SCALE) : 0;
    }

    /// @dev The estates' average bankruptcy price is where the inventory realizes exactly the
    ///      collateral seized with it, so a close there is neutral to the fund whatever the
    ///      winner's own entry was. The window can outlive a recovery past that price: it
    ///      releases only once the fund could finish the remainder at the band edge, so a fund
    ///      at its reserve stays pending with the mark up to a band above it. Settling there at
    ///      the bankruptcy price would hand the winners a close better than the market at the
    ///      fund's expense, and executeAdl is permissionless with a caller-chosen winner list,
    ///      so the batch takes the mark whenever it sits on the fund's favorable side. The
    ///      reward then pays nothing, since no loss is averted.
    ///
    ///      executeAdlCore settles at this price the units its restoring figure calls for, and
    ///      closes the rest of a batch at the mark.
    function _settlementPrice(Inventory memory inv, uint256 currentPrice) internal pure returns (uint256) {
        return _settlementPriceOf(inv.isLong, inv.bankruptcyNotional, inv.size, currentPrice);
    }

    /// @dev _settlementPrice on the figures alone, so a deferred account can be priced before it
    ///      is seized. The average bankruptcy price rounds toward the fund: up for long inventory,
    ///      which the vault sells, and down for short inventory, which it buys back. Closed in
    ///      full at that price the inventory realizes no less than its bankruptcy notional as a
    ///      long and pays no more than it as a short, so the seizure covers the close; rounded
    ///      the other way the close would cost the fund up to a wei per unit of size beyond it.
    function _settlementPriceOf(bool isLong, uint256 bankruptcyNotional, uint256 size, uint256 currentPrice)
        internal
        pure
        returns (uint256)
    {
        uint256 avgBankruptcyPrice = Math.mulDiv(
            bankruptcyNotional, BAZAAR_SCALE, size, isLong ? Math.Rounding.Ceil : Math.Rounding.Floor
        );
        return isLong ? Math.max(avgBankruptcyPrice, currentPrice) : Math.min(avgBankruptcyPrice, currentPrice);
    }

    /// @notice The cohort size that can actually be closed against an account settling at
    ///         `settlementPrice`, read from the live buckets.
    /// @dev The coverage test the whole-account rule rests on, and it has to apply the close
    ///      loop's own two filters rather than the eligibility scan's one. Eligibility ranks at
    ///      the live price; settlement happens at the account's bankruptcy price, which for a
    ///      bankrupt counterparty lies on the far side of the market from it. A winner between
    ///      the two prices is profitable at the mark and under water at the settlement, and the
    ///      close refuses to realize a loss on it — so counting the scan's figure would seize an
    ///      account its cohort cannot take, leaving the seizure to fall through to the netting
    ///      that deferring it avoided. Sizes come from the buckets, so a winner already spent on
    ///      an earlier account in the same batch contributes only what is left of it.
    /// @param positionBuckets Storage mapping of position buckets
    /// @param cohort The submitted winners on the inventory's side
    /// @param params The batch parameters, with `adlLongs` set to the cohort's side and the
    ///        snapshot fields set to the ranking basis
    /// @param settlementPrice The price the account would settle its counterparties at
    /// @param needed The size that must be covered; the scan stops once it is reached
    /// @return total The settleable size, never more than `needed`
    function _settleableSize(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        address[] calldata cohort,
        BazaarTypes.AdlParams memory params,
        uint256 settlementPrice,
        uint256 needed,
        uint64 adlEpoch,
        mapping(address => uint64) storage adlDepositEpoch,
        mapping(address => uint256) storage adlWindowDeposits
    ) internal view returns (uint256 total) {
        uint256 threshold = _getAdlScoreThreshold(params.adlAuctionStartTs);

        for (uint256 i = 0; i < cohort.length; i++) {
            if (total >= needed) break;

            BazaarTypes.PositionBucket storage bucket = positionBuckets[cohort[i]];
            if (bucket.size == 0) continue;
            if (bucket.isLong != params.adlLongs) continue;

            BazaarTypes.BucketState memory ranking = BucketLib.calculateState(
                bucket, params.adlSnapshotPrice, params.adlSnapshotFundingIndex, params.marginRequirements
            );
            if (ranking.totalPnl <= 0) continue;
            uint256 adlScore = Math.mulDiv(
                uint256(ranking.totalPnl),
                BAZAAR_SCALE,
                _scoreCollateral(ranking.effectiveCollateral, cohort[i], adlEpoch, adlDepositEpoch, adlWindowDeposits)
            );
            if (adlScore < threshold) continue;

            BazaarTypes.BucketState memory settling = BucketLib.calculateState(
                bucket, settlementPrice, params.currentFundingIndex, params.marginRequirements
            );
            if (settling.totalPnl < 0) continue;

            total += settling.adjustedSize;
        }
    }

    function _liquidateParams(BazaarTypes.AdlParams memory params)
        internal
        pure
        returns (BazaarTypes.LiquidateParams memory lp)
    {
        lp.currentPrice = params.currentPrice;
        lp.currentFundingIndex = params.currentFundingIndex;
        lp.marginReqs = params.marginRequirements;
        lp.pairId = params.pairId;
        lp.currentBlock = params.currentBlock;
    }

    function _deferredSize(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        address[] storage deferred
    ) internal view returns (uint256 total) {
        for (uint256 i = 0; i < deferred.length; i++) {
            total += positionBuckets[deferred[i]].size;
        }
    }

    /// @dev The size of every listed account past its collateral at the live price, opposite the
    ///      inventory: what the pass after the inventory leg nets, and what that leg was sized for
    ///      (_sizeToAffordNettings counts the same accounts).
    function _heldSize(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        address[] storage deferred,
        BazaarTypes.LiquidateParams memory lp,
        bool inventoryIsLong
    ) internal view returns (uint256 total) {
        for (uint256 i = 0; i < deferred.length; i++) {
            BazaarTypes.PositionBucket storage bucket = positionBuckets[deferred[i]];
            if (bucket.size == 0 || bucket.isLong == inventoryIsLong) continue;
            BazaarTypes.BucketState memory state =
                BucketLib.calculateState(bucket, lp.currentPrice, lp.currentFundingIndex, lp.marginReqs);
            if (RiskParamsLib.accountExcess(state) != 0) total += state.adjustedSize;
        }
    }

    function _loadInventory(BazaarTypes.Vault storage v) internal view returns (Inventory memory inv) {
        inv.size = v.pendingLiqSize;
        inv.entryNotional = v.pendingLiqEntryNotional;
        inv.bankruptcyNotional = v.pendingLiqBankruptcyNotional;
        inv.seized = v.pendingLiqSeized;
        inv.entryFundingIndex = v.pendingLiqEntryFundingIndex;
        inv.isLong = v.pendingLiqIsLong;
    }

    /// @dev Only the fields a proportional close moves; the side and the size-weighted entry
    ///      index are unchanged by it.
    function _storeInventory(BazaarTypes.Vault storage v, Inventory memory inv) internal {
        v.pendingLiqSize = inv.size;
        v.pendingLiqEntryNotional = inv.entryNotional;
        v.pendingLiqBankruptcyNotional = inv.bankruptcyNotional;
        v.pendingLiqSeized = inv.seized;
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
    ///      income may be withheld, or ROUNDING_ALLOWANCE where the funding income is smaller,
    ///      and never more than the net credit, so a winner whose price leg is negative at the
    ///      settlement price still closes at no worse than break-even.
    /// @param pairVault The pair's vault accounting
    /// @param inv The inventory the slice is released from
    /// @param free The fund's free capital available to this close
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param state The winner's bucket state at the settlement price and the live index
    /// @param closedSize The size closed, at most `state.adjustedSize`
    /// @param settlementPrice The price the close settles at (BAZAAR_SCALE precision)
    /// @return s The credit, the amount withheld from it, and the entry basis released
    function _settleSlice(
        BazaarTypes.Vault storage pairVault,
        Inventory memory inv,
        uint256 free,
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
        uint256 withholdCap = sliceFunding > ROUNDING_ALLOWANCE ? sliceFunding : ROUNDING_ALLOWANCE;
        if (withholdCap > slicePnl) withholdCap = slicePnl;
        s.withheld =
            _settleInventorySlice(pairVault, inv, free, currentFundingIndex, closedSize, settlementPrice, withholdCap);
        s.credit = slicePnl - s.withheld;
    }

    /// @notice Values `closedSize` of inventory closed at `settlementPrice` from the liquidatees'
    ///         entry, price and funding legs, and releases the slice from the inventory.
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
    /// @param inv The inventory the slice is released from, decremented in place
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param closedSize The inventory closed against the winner
    /// @param settlementPrice The price the close settles at (BAZAAR_SCALE precision)
    /// @return vaultPnl The vault's realization on the slice, negative for a loss
    /// @return earmark The slice's share of the collateral seized alongside the inventory
    function _releaseSlice(
        Inventory memory inv,
        int256 currentFundingIndex,
        uint256 closedSize,
        uint256 settlementPrice
    ) internal pure returns (int256 vaultPnl, uint256 earmark) {
        uint256 pendingSize = inv.size;
        uint256 entryPortion = Math.mulDiv(inv.entryNotional, closedSize, pendingSize);
        uint256 bkPortion = Math.mulDiv(inv.bankruptcyNotional, closedSize, pendingSize);
        uint256 closedNotional = Math.mulDiv(closedSize, settlementPrice, BAZAAR_SCALE);
        int256 rawFunding = BazaarMathLib.signedMulDiv(
            currentFundingIndex - inv.entryFundingIndex, int256(closedSize), int256(BAZAAR_SCALE)
        );
        earmark = Math.mulDiv(inv.seized, closedSize, pendingSize);
        if (inv.isLong) {
            vaultPnl = int256(closedNotional) - int256(entryPortion) - rawFunding;
        } else {
            vaultPnl = int256(entryPortion) - int256(closedNotional) + rawFunding;
        }
        inv.size = pendingSize - closedSize;
        inv.entryNotional -= entryPortion;
        inv.bankruptcyNotional -= bkPortion;
        inv.seized -= earmark;
    }

    /// @notice Books the vault's realization on a closed inventory slice as an insurance <->
    ///         deposits-ledger transfer, and decides how much of an uncovered loss the winner
    ///         absorbs.
    /// @dev A gain is a D → I transfer, carried as the ledger's arrears where D cannot pay it; a
    ///      loss is an I → D transfer paid net of those arrears. Both leave I + D unchanged, so
    ///      the books-vs-cash health check is unmoved, and the deposits ledger keeps tracking the
    ///      buckets: the winner's credit lands in a bucket and is withdrawn from the ledger
    ///      later, so the ledger must gain exactly what the vault lost, less the cash it already
    ///      owed the fund for this inventory.
    ///
    ///      A loss is funded from the slice's own share of the seizure earmark plus the fund's
    ///      free capital, never from the earmark of inventory still open, so one close's carry
    ///      cannot consume the backing of the next and concentrate a whole batch's shortfall on
    ///      whoever the batch reaches last. It is paid from the slice's earmark first, and only
    ///      then net of the arrears and from free capital (RiskParamsLib.fundLedgerFrom). Netted
    ///      from the arrears first, the loss would leave the inventory left reading worse to the
    ///      netting gate and the ADL gate, which count the arrears in full, while the earmark
    ///      sat in free capital, which below the reserve they do not count; a deferred account's
    ///      close against its cohort would take arrears the vault's own inventory relies on for a
    ///      loss the account's seizure covers. Because the earmark sits in the fund by
    ///      construction and the arrears net off what the earmark could not hold, the fund can
    ///      only fall short by the holding-window funding and by rounding. What it cannot pay is
    ///      withheld from the winner's credit up to `withholdCap`. The cap is the winner's funding
    ///      income: that income accrued against this inventory, so refusing to pay what the fund
    ///      cannot back keeps every remaining claim cash-backed without touching the winner's
    ///      price PnL. Anything beyond the cap is a claim with no backing left, recorded as
    ///      deficit so the post-batch health check terminates the pair and the settlement
    ///      waterfall shares it pro-rata.
    ///
    ///      Rounding is the exception to both. The slice's entry basis and earmark are pro-rata
    ///      shares rounded on their own, its notional and funding leg each round once more, and
    ///      the funding leg runs from an entry index averaged across estates, so a close at the
    ///      bankruptcy price can land a few wei past its earmark with no carry at all. That is
    ///      not a loss the fund failed to back: what a rounded share leaves one slice short, the
    ///      rest of the inventory holds over. The cap is therefore never below
    ///      ROUNDING_ALLOWANCE, so the credit absorbs it where the winner has no funding income,
    ///      and a remainder within the allowance that the credit is too small to absorb is not
    ///      recorded: a deficit of any size fixes the settlement price, and this one would
    ///      terminate a pair that is solvent to the wei over less than it can pay anyone.
    /// @param pairVault The pair's vault accounting
    /// @param inv The inventory the slice is released from
    /// @param free The fund's free capital available to this close, read before the release
    /// @param currentFundingIndex The pair's live cumulative funding index
    /// @param closedSize The inventory closed against the winner
    /// @param settlementPrice The price the close settles at (BAZAAR_SCALE precision)
    /// @param withholdCap The most that may be withheld from the winner's credit: the larger of
    ///        its funding income and ROUNDING_ALLOWANCE, capped at the credit
    /// @return withheld The part of the vault's loss withheld from the winner's credit
    function _settleInventorySlice(
        BazaarTypes.Vault storage pairVault,
        Inventory memory inv,
        uint256 free,
        int256 currentFundingIndex,
        uint256 closedSize,
        uint256 settlementPrice,
        uint256 withholdCap
    ) internal returns (uint256 withheld) {
        (int256 vaultPnl, uint256 earmark) = _releaseSlice(inv, currentFundingIndex, closedSize, settlementPrice);

        if (vaultPnl >= 0) {
            RiskParamsLib.collectFromLedger(pairVault, uint256(vaultPnl));
            return 0;
        }

        uint256 shortfall = RiskParamsLib.fundLedgerFrom(pairVault, uint256(-vaultPnl), earmark, earmark + free);
        withheld = shortfall < withholdCap ? shortfall : withholdCap;
        if (shortfall - withheld > ROUNDING_ALLOWANCE) {
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
        OrderBookLib.emitOrderUpdated(
            pairId, orderId, o, BazaarTypes.OrderAction.Canceled, BazaarTypes.CancelReason.Deleveraged
        );
    }
}
