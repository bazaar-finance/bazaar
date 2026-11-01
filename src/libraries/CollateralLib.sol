// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BucketLib} from "./BucketLib.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";
import {TerminationLib} from "./TerminationLib.sol";

/// @title CollateralLib
/// @notice External library for deposit and withdrawal collateral logic.
///         Runs via DELEGATECALL — has direct access to BazaarPair storage.
library CollateralLib {
    using EnumerableSet for EnumerableSet.UintSet;

    // -------------------- Constants --------------------

    /// @notice Minimum collateral deposit. Matches the insurance-fund minimum so both entry points
    ///         speak the same "$5 minimum" rule.
    uint256 internal constant MIN_COLLATERAL_AMOUNT = 5 * BazaarTypes.BAZAAR_SCALE;

    /// @notice Tip credited to a caller who settles someone else's position at the fixed terminal
    ///         price; _paySettlementTip describes who funds it.
    uint256 internal constant TERMINAL_SETTLEMENT_TIP = BazaarTypes.TERMINAL_SETTLEMENT_TIP;

    // -------------------- Errors --------------------

    error CollateralLib__DepositsAreBlocked();
    error CollateralLib__PairScheduledForTermination();
    error CollateralLib__InvalidDepositAmount(uint256 amount, uint256 minAmount);
    error CollateralLib__ZeroWithdrawalAmount();
    error CollateralLib__NothingToClaim();
    error CollateralLib__ClaimTransferFailed();
    error CollateralLib__WithdrawalBlockedVaultUnhealthy();
    error CollateralLib__WithdrawalsFrozenAdlPending();
    error CollateralLib__InsolventPositionBucket(uint256 availableEquity, uint256 minRequiredCollateral);
    error CollateralLib__InsufficientCollateral(uint256 amount, uint256 available);
    error CollateralLib__InsufficientMarginAfterWithdrawal(uint256 amount, uint256 available);
    error CollateralLib__NoPriceUpdateDataProvided();
    error CollateralLib__MustRetainMinimumCollateral(uint256 remaining, uint256 minimum);
    error CollateralLib__WithdrawalRequiresFreshPrice();
    error CollateralLib__LedgerShortfall(uint256 amount, uint256 available);

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
        if (params.isPairTerminated) revert CollateralLib__DepositsAreBlocked();

        // Block deposits in scheduled-termination limbo, which begins LIMBO_LEAD before the
        // cutoff (the pair's _pastTradingCutoff rule).
        if (
            params.scheduledTerminationTs != 0
                && block.timestamp + BazaarTypes.LIMBO_LEAD >= params.scheduledTerminationTs
        ) {
            revert CollateralLib__PairScheduledForTermination();
        }

        // Validate minimum deposit
        if (params.amount < MIN_COLLATERAL_AMOUNT) {
            revert CollateralLib__InvalidDepositAmount(params.amount, MIN_COLLATERAL_AMOUNT);
        }

        BazaarTypes.PositionBucket storage positionBucket = positionBuckets[caller];

        positionBucket.collateral = SafeCast.toUint128(uint256(positionBucket.collateral) + params.amount);

        BucketLib.emitBucketUpdate(caller, positionBucket, params.currentFundingIndex, params.marginReqs, params.pairId);

        emit BazaarTypes.CollateralDeposited(params.pairId, caller, params.amount);
    }

    /// @dev Shortfall of the USDC balance against the books that isBalanceShort tolerates, in bp.
    ///      Declared here so the pair's verdict and BazaarPairLens's withdrawal quote read one value.
    uint256 internal constant USDC_BALANCE_TOLERANCE_BP = 10;

    /// @notice Vault-health Check 1: does the contract still hold the USDC its books promise?
    /// @dev Expected balance is every claim on the contract's cash — the deposits ledger (D),
    ///      the insurance fund (I), and fees earned but not yet claimed. Lives here rather than
    ///      in BazaarPair so the pair's EIP-170 budget stays free of it, and here rather than in
    ///      VaultHealthLib because that library is internal (inlined into its callers), so a
    ///      function placed there would land back in the pair's bytecode.
    /// @param usdc The pair's USDC token.
    /// @param pairVault The pair's vault aggregates.
    /// @param claimableFeesTotal Unclaimed fee-escrow liability, in BAZAAR precision.
    /// @param toleranceBp Shortfall tolerated before the pair is judged short — absorbs the
    ///        1e18 -> 1e6 truncation dust that accrues in the contract's favour on payouts.
    /// @return short True when the books promise materially more than the contract holds.
    function isBalanceShort(
        address usdc,
        BazaarTypes.Vault storage pairVault,
        uint256 claimableFeesTotal,
        uint256 toleranceBp
    ) external view returns (bool short) {
        // Division floors, understating the expected balance by sub-cent dust — the same
        // direction the tolerance errs in, i.e. toward NOT flagging a shortfall.
        uint256 expected =
            (pairVault.insuranceFundBalance + pairVault.totalCollateralDeposited + claimableFeesTotal) / 1e12;
        (bool ok, bytes memory data) = usdc.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!ok || data.length < 32) return false; // an unreadable balance is not evidence of a shortfall
        return expected > abi.decode(data, (uint256)) + (expected * toleranceBp / BazaarTypes.BP_SCALE);
    }

    /// @notice Pay out the caller's escrowed balance — every third-party payout the pair accrues
    ///         through FeeEscrowLib.credit (fee shares, keeper rewards, relayer fees).
    /// @dev Lives here rather than in BazaarPair so the pair's EIP-170 budget stays free of the
    ///      transfer and precision-conversion code. Reverts on a failed transfer rather than
    ///      soft-failing: the cash is already the claimant's own, so there is no fallback
    ///      recipient to credit, and leaving the balance intact lets them simply try again.
    /// @return amount The amount paid, in BAZAAR precision.
    function claimFees(BazaarTypes.FeeEscrow storage feeEscrow, address usdc, bytes32 pairId)
        external
        returns (uint256 amount)
    {
        amount = feeEscrow.claimable[msg.sender];
        if (amount == 0) revert CollateralLib__NothingToClaim();
        feeEscrow.claimable[msg.sender] = 0;
        unchecked {
            // total is the sum of all claimable balances and held trigger bounties.
            feeEscrow.total -= amount;
        }
        if (!_trySendUsdc(usdc, msg.sender, amount)) revert CollateralLib__ClaimTransferFailed();
        emit BazaarTypes.FeesClaimed(pairId, msg.sender, amount);
    }

    // ================================================================
    //                 Terminal Settlement (two-stage termination)
    // ================================================================

    /// @notice Settle positions at the fixed terminal price. Permissionless: marking a position
    ///         to a price that will never change cannot alter what its owner is owed, so no
    ///         solvency threshold, price update or ETH is needed. Before finalize a loser's loss
    ///         leaves its collateral (the remainder is tallied as bad debt) and a winner's profit
    ///         is registered as a claim; after finalize a position realizes against the frozen
    ///         ledgers. Accounts holding no position are skipped. Each position settled for
    ///         someone else credits the caller's escrow with up to TERMINAL_SETTLEMENT_TIP, funded
    ///         as _paySettlementTip describes; settling one's own position pays nothing.
    /// @param positionBuckets Storage mapping of position buckets
    /// @param pairVault The vault storage reference
    /// @param terminalProfitClaim Storage mapping of registered profit claims
    /// @param ts Terminal-settlement state (tallies before finalize, frozen ratios after)
    /// @param feeEscrow Fee escrow the settler's tip accrues to
    /// @param settlementPrice The fixed terminal price
    /// @param currentFundingIndex The pair's current funding index
    /// @param postFinalize Whether finalize has already run
    /// @param pairId The pair identifier for events
    /// @param users Accounts to settle
    /// @return settledCount Number of positions settled
    function settleTerminalPositions(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        mapping(address => uint256) storage terminalProfitClaim,
        BazaarTypes.TerminalSettlement storage ts,
        BazaarTypes.FeeEscrow storage feeEscrow,
        uint256 settlementPrice,
        int256 currentFundingIndex,
        bool postFinalize,
        bytes32 pairId,
        address[] calldata users
    ) external returns (uint256 settledCount) {
        BazaarTypes.TerminalSettleParams memory p = BazaarTypes.TerminalSettleParams({
            settlementPrice: settlementPrice,
            currentFundingIndex: currentFundingIndex,
            postFinalize: postFinalize,
            pairId: pairId
        });
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            // Read before settlement zeroes the size: it decides whether insurance may top up the tip.
            bool fullSize = Math.mulDiv(positionBuckets[user].size, settlementPrice, BazaarTypes.BAZAAR_SCALE)
                >= BazaarTypes.MIN_ORDER_AMOUNT;
            (bool settled, bool bankrupt) = _settleOne(positionBuckets, pairVault, terminalProfitClaim, ts, p, user);
            if (!settled) continue;
            unchecked {
                ++settledCount;
            }
            if (user != msg.sender) {
                _paySettlementTip(positionBuckets, pairVault, feeEscrow, p, user, bankrupt, fullSize);
            }
        }
    }

    /// @dev Settle a single position at the terminal price; false when `user` holds none.
    ///
    ///      Before finalize nothing here touches the deposits ledger: finalize derives the total
    ///      owed to traders from the ledger identity (see TerminationLib), which holds only while
    ///      settlement leaves the ledger alone. A loss comes out of the bucket up to its
    ///      collateral and the rest is tallied as bad debt; a profit becomes a registered claim,
    ///      paid at the frozen profit ratio.
    ///
    ///      After finalize the position is one finalize did not wait for (escape hatch). Its
    ///      equity was already inside the total owed at collateral + PnL, so a solvent position
    ///      realizes to exactly that figure with no ledger change — profit included, since
    ///      finalize reserved it inside principal. A bankrupt one was counted below zero: the
    ///      insurers' residual, junior to every trader entitlement, funds its shortfall as far as
    ///      it goes, and that funded amount moves into the principal ledger so the remaining
    ///      withdrawals stay covered. Whatever the residual cannot fund re-freezes the payout
    ///      ratios on the entitlements still unpaid (_refreezeRatios), so the gap is shared by
    ///      every holder who has not withdrawn yet rather than landing on whoever withdraws last.
    ///      Only the part of the shortfall finalize subtracted from the total owed is credited at
    ///      all: the part beyond the principal every other bucket holds, which finalize carried
    ///      in `deficit`, offset nothing and is consumed from that carry instead.
    ///
    ///      Never reverts for a position that exists: settlement must be able to clear every
    ///      position, or one of them could hold finalize hostage.
    /// @return settled False when `user` holds no position
    /// @return bankrupt True when the position could not cover its own loss — before finalize a
    ///         loss beyond its collateral, after finalize negative equity. Decides who funds the
    ///         settler's tip.
    function _settleOne(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        mapping(address => uint256) storage terminalProfitClaim,
        BazaarTypes.TerminalSettlement storage ts,
        BazaarTypes.TerminalSettleParams memory p,
        address user
    ) internal returns (bool settled, bool bankrupt) {
        BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
        uint256 size = bucket.size;
        if (size == 0) return (false, false);

        BazaarTypes.MarginRequirements memory zeroReqs; // settlement ignores margins
        BazaarTypes.BucketState memory state =
            BucketLib.calculateState(bucket, p.settlementPrice, p.currentFundingIndex, zeroReqs);

        // Remove from the OI aggregates (floored, mirroring LiquidationLib). Both reaching zero
        // is what tells finalize the sweep is complete.
        if (bucket.isLong) {
            pairVault.totalLongOI = pairVault.totalLongOI > size ? pairVault.totalLongOI - size : 0;
            pairVault.longWeightedEntrySum = pairVault.longWeightedEntrySum > bucket.entryValue
                ? pairVault.longWeightedEntrySum - bucket.entryValue
                : 0;
        } else {
            pairVault.totalShortOI = pairVault.totalShortOI > size ? pairVault.totalShortOI - size : 0;
            pairVault.shortWeightedEntrySum = pairVault.shortWeightedEntrySum > bucket.entryValue
                ? pairVault.shortWeightedEntrySum - bucket.entryValue
                : 0;
        }

        int256 pnl = state.totalPnl;
        uint256 collateral = bucket.collateral;
        if (!p.postFinalize) {
            if (pnl < 0) {
                uint256 loss = uint256(-pnl);
                uint256 covered = loss < collateral ? loss : collateral;
                // covered <= collateral by construction.
                bucket.collateral = uint128(collateral - covered);
                if (loss > covered) {
                    ts.terminalBadDebt += loss - covered;
                    bankrupt = true;
                }
            } else if (pnl > 0) {
                terminalProfitClaim[user] += uint256(pnl);
                ts.totalProfitClaims += uint256(pnl);
            }
        } else {
            int256 equity = int256(collateral) + pnl;
            if (equity >= 0) {
                bucket.collateral = _toCollateral(uint256(equity));
            } else {
                uint256 shortfall = uint256(-equity);
                bucket.collateral = 0;
                ts.terminalBadDebt += shortfall;
                bankrupt = true;
                // Finalize subtracted this position's negative equity from the total owed only as
                // far as other entitlements absorbed it; the excess is carried in `deficit`, under
                // its terminal meaning, and is consumed first, since crediting it would reserve
                // principal no bucket holds. What remains is the part finalize did subtract.
                {
                    uint256 carried = shortfall < pairVault.deficit ? shortfall : pairVault.deficit;
                    pairVault.deficit -= carried;
                    shortfall -= carried;
                }
                // Insurance funds it as far as it goes, and that much moves into the principal
                // ledger — the same rule the live protocol applies to a vault loss insurance
                // cannot cover. The remainder has no cash behind it, so crediting it at the
                // frozen ratios would have the books claim more than the pot holds; it is
                // credited at ratios derived again on what is still to be paid.
                uint256 take = shortfall < pairVault.insuranceFundBalance ? shortfall : pairVault.insuranceFundBalance;
                pairVault.insuranceFundBalance -= take;
                pairVault.totalCollateralDeposited += take;
                if (take < shortfall) _refreezeRatios(pairVault, ts, shortfall - take, p.pairId);
            }
        }

        // Zero the position (keep collateral).
        bucket.size = 0;
        bucket.entryValue = 0;
        bucket.entryFundingIndex = 0;
        BucketLib.emitBucketUpdate(user, bucket, p.currentFundingIndex, zeroReqs, p.pairId);
        settled = true;
    }

    /// @dev Re-derive the frozen payout ratios after the post-finalize settlement of a bankrupt
    ///      position left `unfunded` of its shortfall beyond the insurers' residual.
    ///
    ///      Finalize counted that position at its negative equity, so the principal it froze sits
    ///      `unfunded` below what the solvent buckets hold, and the ratios it froze were derived
    ///      against that smaller figure. Paying the buckets at those ratios would draw more cash
    ///      than finalize reserved for them: the excess would come first out of the fee escrow,
    ///      which claimFees promises stays whole in every pair state, and then out of whoever
    ///      withdraws last. Instead the ledger is raised to the buckets' sum and both ratios are
    ///      derived again, by finalize's own rule, on the entitlements still unpaid: the principal
    ///      the ledger still owes, the registered claims not yet credited, and the cash the old
    ///      ratios reserved for both. Every holder still in is then paid at the ratios the cash
    ///      left in the contract supports. That matches what finalize would have paid had the
    ///      position been settled before it only when nobody has withdrawn since: what earlier
    ///      withdrawals took at the old ratios cannot be recovered, so it falls on the holders
    ///      still in, principal as well as claims. That is why the completeness gate on finalize
    ///      and the pre-finalize settlement tip push for settlement before finalize, where a
    ///      shortfall is shared by every winner at one ratio. A claim an earlier withdrawal
    ///      credited into its bucket ranks as principal here; that never beats withdrawing it
    ///      outright, since the re-derived principal ratio is at most the old one, and leaves the
    ///      other holders no worse off than that withdrawal would.
    ///
    ///      The reserved cash is derived from the ledgers rather than read from the balance. Each
    ///      terminal withdrawal takes `amount` off the ledger and `amount × principalRatio` off
    ///      the cash; each claim payout moves `claim × profitRatio` out of the claims' reservation
    ///      and into the ledger, consistent because profitRatio is 0 whenever principalRatio is
    ///      below 100%; and the funded part of a shortfall moves from the residual into the
    ///      ledger. So `ledger × principalRatio + unpaid claims × profitRatio + residual` is the
    ///      pot still in the contract net of the fee escrow, and the residual is empty here
    ///      because the funding just took all of it: the new ratios are derived on the reserved
    ///      cash alone, and the residual becomes what their rounding leaves of it.
    function _refreezeRatios(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.TerminalSettlement storage ts,
        uint256 unfunded,
        bytes32 pairId
    ) private {
        uint256 principal = pairVault.totalCollateralDeposited;
        uint256 claims = ts.totalProfitClaims;
        uint256 pot = Math.mulDiv(principal, ts.principalRatio, BazaarTypes.BAZAAR_SCALE)
            + Math.mulDiv(claims, ts.profitRatio, BazaarTypes.BAZAAR_SCALE) + pairVault.insuranceFundBalance;
        principal += unfunded;
        (uint256 principalRatio, uint256 profitRatio, uint256 residual) =
            TerminationLib.freezeRatios(pot, principal, claims);
        ts.principalRatio = principalRatio;
        ts.profitRatio = profitRatio;
        pairVault.totalCollateralDeposited = principal;
        pairVault.insuranceFundBalance = residual;
        emit BazaarTypes.TerminalRatiosRefrozen(pairId, unfunded, principalRatio, profitRatio);
    }

    /// @dev Credit the settler's escrow with TERMINAL_SETTLEMENT_TIP, or as much of it as its
    ///      sources can fund. Settlement must never revert, so every leg is capped at its source.
    ///
    ///      Before finalize the settled position pays first, from whatever collateral its own
    ///      settlement left it, charged like a trading fee: the bucket and the deposits ledger
    ///      drop together, so the total finalize derives from the ledger falls by exactly what
    ///      left the pot and the insurers' residual is untouched. Insurance covers the rest,
    ///      all-or-nothing on coverage: a remainder the balance cannot meet in full is skipped
    ///      rather than trimmed, so the settler earns either the whole tip or only what the
    ///      position itself could pay. Insurance's balance at this point is the nominal one that
    ///      finalize rewrites from the pot, so the top-up's real cost is the escrow credit, which
    ///      finalize takes off the pot before any trader is paid. A pot that covers every principal
    ///      and registered claim takes it from the insurers' residual; one that does not takes it
    ///      from the profit ratio and, with cash short of principal, from the principal ratio, at
    ///      most TERMINAL_SETTLEMENT_TIP per settled position. That is what it costs to pay keepers
    ///      to settle bankrupt positions before the ratios freeze, which books their shortfall then
    ///      rather than leaving it to the holders still in after finalize.
    ///
    ///      Insurance pays any part of the tip only when `fullSize` is set: the settled position
    ///      was worth at least MIN_ORDER_AMOUNT at the settlement price. The maintenance margin on
    ///      such a position is at least the tip, and the margin rules keep that cushion in the
    ///      bucket, so emptying it takes a loss at least as large as the tip. A smaller position
    ///      can be left with no collateral at no cost, through margin that rounds to zero or a
    ///      partial close at an off-market price, so it pays only what its own collateral covers:
    ///      a top-up there would draw a tip from the pot for every such account an attacker opens.
    ///
    ///      After finalize a solvent straggler harms nobody (finalize reserved its equity in
    ///      full), so only a bankrupt one pays, from whatever residual the funding of its own
    ///      shortfall left: that settlement is the one the insurers' sweep gate waits for and the
    ///      one nobody is otherwise motivated to run. A bankrupt straggler below MIN_ORDER_AMOUNT
    ///      pays nothing, for the same reason as above.
    function _paySettlementTip(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        BazaarTypes.TerminalSettleParams memory p,
        address user,
        bool bankrupt,
        bool fullSize
    ) internal {
        uint256 tip;
        if (!p.postFinalize) {
            BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
            uint256 fromCollateral = bucket.collateral;
            if (fromCollateral > TERMINAL_SETTLEMENT_TIP) fromCollateral = TERMINAL_SETTLEMENT_TIP;
            if (fromCollateral > pairVault.totalCollateralDeposited) {
                fromCollateral = pairVault.totalCollateralDeposited;
            }
            if (fromCollateral > 0) {
                // fromCollateral <= bucket.collateral, so the narrowing cast is exact.
                bucket.collateral -= uint128(fromCollateral);
                pairVault.totalCollateralDeposited -= fromCollateral;
                BazaarTypes.MarginRequirements memory zeroReqs;
                BucketLib.emitBucketUpdate(user, bucket, p.currentFundingIndex, zeroReqs, p.pairId);
                tip = fromCollateral;
            }
        } else if (!bankrupt) {
            return;
        }
        uint256 remainder = TERMINAL_SETTLEMENT_TIP - tip;
        if (fullSize && remainder <= pairVault.insuranceFundBalance) {
            pairVault.insuranceFundBalance -= remainder;
            tip += remainder;
        }
        if (tip > 0) FeeEscrowLib.credit(feeEscrow, p.pairId, msg.sender, tip);
    }

    /// @dev Clamp into the bucket's collateral width rather than revert: settlement must never
    ///      fail for a position that exists. Unreachable in practice (it takes equity above
    ///      3.4e20 USD), but a revert here would let one position hold finalize hostage.
    function _toCollateral(uint256 amount) internal pure returns (uint128) {
        return amount > type(uint128).max ? type(uint128).max : uint128(amount);
    }

    /// @notice Worst-case directional notional for IMR purposes: the position plus same-direction
    ///         resting orders, or opposite-direction orders overshooting into a flip — whichever
    ///         is larger. Shared with BazaarPairLens so off-chain withdrawal previews margin-check
    ///         against the same base the on-chain withdrawal check does.
    function _worstCaseNotional(
        bool posIsLong,
        uint256 posNotional,
        uint256 longOrderExposure,
        uint256 shortOrderExposure
    ) internal pure returns (uint256) {
        uint256 sameDirExposure = posIsLong ? longOrderExposure : shortOrderExposure;
        uint256 oppDirExposure = posIsLong ? shortOrderExposure : longOrderExposure;
        uint256 worstSameDir = posNotional + sameDirExposure;
        uint256 worstFlip = oppDirExposure > posNotional ? oppDirExposure - posNotional : 0;
        return worstSameDir > worstFlip ? worstSameDir : worstFlip;
    }

    /// @notice The collateral the fill gate (MatchingEngineLib._checkMargin) debits ahead of its
    ///         initial-margin test for a Limit or StopLimit order of `size` at `limitPrice`: the
    ///         loss a fill at the limit books against the mark on fresh exposure — a bid above
    ///         the mark, an ask below it; a gain is never credited — plus the maker fee on the
    ///         limit notional. Creation, amendment and withdrawal reserve it on top of initial
    ///         margin so that an order they admit at the mark can rest and, as a maker, fill at
    ///         full size there (a crossing arrival pays the taker rate instead, which is not
    ///         reserved). Without it a wrong-side order would rest under-reserved, and any taker
    ///         sized past what its collateral affords would auto-cancel it at the gate for the
    ///         cost of gas. Shared with BazaarPairLens.
    /// @dev A StopLimit waiting outside the book arms at a mark that is unknown here but lies at
    ///      or past its trigger (a buy fires at or above it, a sell at or below), and its limit
    ///      lies on the far side of the trigger, so the loss of the arming walk is bounded by
    ///      the limit's distance from the trigger. Callers pass the Limit type for an armed one:
    ///      it rests like any Limit and is judged against the mark. A Market order never rests
    ///      and pays the taker rate, so it reserves nothing here.
    function _fillDebitOf(
        BazaarTypes.OrderType ot,
        bool isLong,
        uint256 size,
        uint256 limitPrice,
        uint256 triggerPrice,
        uint256 mark,
        address integrator
    ) internal pure returns (uint256 debit) {
        if (ot == BazaarTypes.OrderType.Market) return 0;
        uint256 limitNotional = Math.mulDiv(size, limitPrice, BazaarTypes.BAZAAR_SCALE);
        uint256 refNotional =
            Math.mulDiv(size, ot == BazaarTypes.OrderType.StopLimit ? triggerPrice : mark, BazaarTypes.BAZAAR_SCALE);
        if (isLong) {
            if (limitNotional > refNotional) debit = limitNotional - refNotional;
        } else if (refNotional > limitNotional) {
            debit = refNotional - limitNotional;
        }
        uint256 feeEbp = BazaarTypes.MAKER_INSURANCE_FEE_EBP;
        if (integrator != address(0)) feeEbp += BazaarTypes.MAKER_INTEGRATOR_FEE_EBP;
        debit += Math.mulDiv(limitNotional, feeEbp, BazaarTypes.EBP_SCALE);
    }

    /// @notice The reservation one resting order carries against `mark`, as createOrder reserves
    ///         a new one: its notional for initial margin, at the price the order is valued at —
    ///         a Limit bid at the mark (its excess over the mark is its fill debit, which the
    ///         limit would count a second time), a Limit ask at the larger of its limit and the
    ///         mark, a StopLimit still waiting at the largest of its trigger, its limit and the
    ///         mark — and its share of the fill debit (_fillDebitOf). An armed StopLimit (in the
    ///         book) is the Limit it now is. Shared by the creation, amendment and withdrawal
    ///         tallies; BazaarPairLens mirrors it.
    /// @param o The order, live (neither canceled, filled nor expired)
    /// @param remaining The order's unfilled size
    /// @param mark The spot price the order is reserved against
    /// @return notional The order's exposure for initial margin
    /// @return debit The order's share of the fill gate's debit
    function _orderReserve(BazaarTypes.Order storage o, uint256 remaining, uint256 mark)
        internal
        view
        returns (uint256 notional, uint256 debit)
    {
        BazaarTypes.OrderType ot = o.inBook ? BazaarTypes.OrderType.Limit : o.orderType;
        uint256 valuation = mark;
        if (ot == BazaarTypes.OrderType.StopLimit) {
            if (o.triggerPrice > valuation) valuation = o.triggerPrice;
            if (o.limitPrice > valuation) valuation = o.limitPrice;
        } else if (!o.isLong && o.limitPrice > valuation) {
            valuation = o.limitPrice;
        }
        notional = Math.mulDiv(remaining, valuation, BazaarTypes.BAZAAR_SCALE);
        debit = _fillDebitOf(ot, o.isLong, remaining, o.limitPrice, o.triggerPrice, mark, o.integrator);
    }

    /// @dev Full-width accumulator for the tallies the exact sweep rewrites
    ///      (BazaarTypes.RestingTally); narrowed, saturating, once the set has been read.
    struct TallyAcc {
        uint256 bidSize;
        uint256 askSize;
        uint256 bidLimitNotional;
        uint256 askLimitNotional;
        uint256 highestBid;
        uint256 lowestAsk;
        uint256 stopCount;
    }

    /// @dev `RestingTally.stopCount` once a subtraction would have taken a field below zero: the
    ///      tally no longer describes its set, and the gates sweep until a sweep rewrites it.
    uint32 internal constant TALLY_INVALID = type(uint32).max;

    /// @notice An upper bound, from the tally alone, on what _sweepRestingReserve would find for
    ///         the set `t` describes at `mark`. `bounded` is false when the tally cannot stand in
    ///         for the sweep: a waiting StopLimit is counted (its reservation keys off its
    ///         trigger), a field is pinned at its maximum, or the tally is marked invalid.
    /// @dev A bid is reserved at the mark, so the bids' exposure is their total size at the mark.
    ///      An ask is reserved at the larger of its limit and the mark: at or above the mark that
    ///      is its limit notional, below it the limit notional plus the shortfall to the mark,
    ///      and `lowestAsk` bounds every ask's shortfall by the lowest one's. The fill debit is
    ///      the maker fee on each limit notional — at the integrator-carrying rate for every
    ///      order, since the tally does not record which carry one — plus the loss a bid above
    ///      the mark or an ask below it books, bounded through `highestBid` and `lowestAsk` the
    ///      same way. The sweep floors each order's figures on its own while the bound floors
    ///      whole-side products, and RESTING_BOUND_SLACK covers what that can leave short. A
    ///      tally of zeros describes an empty set and bounds it exactly, from its first slot.
    function _restingBound(BazaarTypes.RestingTally storage t, uint256 mark)
        internal
        view
        returns (bool bounded, uint256 longExposure, uint256 shortExposure, uint256 fillDebit)
    {
        uint256 bidSize = t.bidSize;
        uint256 askSize = t.askSize;
        uint256 stops = t.stopCount;
        if (bidSize == 0 && askSize == 0 && stops == 0) return (true, 0, 0, 0);
        if (stops != 0 || bidSize == type(uint96).max || askSize == type(uint96).max) return (false, 0, 0, 0);
        uint256 bidNotional = t.bidLimitNotional;
        uint256 askNotional = t.askLimitNotional;
        if (bidNotional == type(uint128).max || askNotional == type(uint128).max) return (false, 0, 0, 0);

        longExposure = Math.mulDiv(bidSize, mark, BazaarTypes.BAZAAR_SCALE);
        shortExposure = askNotional + BazaarTypes.RESTING_BOUND_SLACK;
        fillDebit =
            Math.mulDiv(
                    bidNotional + askNotional,
                    BazaarTypes.MAKER_INSURANCE_FEE_EBP + BazaarTypes.MAKER_INTEGRATOR_FEE_EBP,
                    BazaarTypes.EBP_SCALE
                ) + BazaarTypes.RESTING_BOUND_SLACK;
        uint256 highestBid = t.highestBid;
        if (highestBid > mark) fillDebit += Math.mulDiv(bidSize, highestBid - mark, BazaarTypes.BAZAAR_SCALE);
        uint256 lowestAsk = t.lowestAsk;
        if (askSize != 0 && lowestAsk < mark) {
            uint256 shortfall = Math.mulDiv(askSize, mark - lowestAsk, BazaarTypes.BAZAAR_SCALE);
            shortExposure += shortfall;
            fillDebit += shortfall;
        }
        bounded = true;
    }

    /// @notice The live orders of `orderSet` reserved against `mark` (_orderReserve): per side,
    ///         and the fill debit summed over both sides — a bid above the mark and an ask below
    ///         it each book their loss when they fill, whatever the position nets to, and the
    ///         fill gate charges the first fill's loss as the held loss on the second. Canceled,
    ///         filled and expired entries are skipped. The set's tally is rewritten from the same
    ///         read, so every sweep tightens the bound back onto the live set.
    function _sweepRestingReserve(
        EnumerableSet.UintSet storage orderSet,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        BazaarTypes.RestingTally storage tally,
        uint64 currentBlock,
        uint256 mark
    ) internal returns (uint256 longExposure, uint256 shortExposure, uint256 fillDebit) {
        TallyAcc memory acc;
        uint256 len = orderSet.length();
        for (uint256 i; i < len; ++i) {
            BazaarTypes.Order storage o = orders[orderSet.at(i)];
            if (o.canceledBlock != 0 || o.filledBlock != 0 || currentBlock > o.expiryBlock) continue;
            uint256 remaining = o.size - o.filledSize;
            (uint256 notional, uint256 debit) = _orderReserve(o, remaining, mark);
            fillDebit += debit;
            uint256 limit = o.limitPrice;
            uint256 limitNotional = Math.mulDiv(remaining, limit, BazaarTypes.BAZAAR_SCALE);
            if (o.isLong) {
                longExposure += notional;
                acc.bidSize += remaining;
                acc.bidLimitNotional += limitNotional;
                if (limit > acc.highestBid) acc.highestBid = limit;
            } else {
                shortExposure += notional;
                acc.askSize += remaining;
                acc.askLimitNotional += limitNotional;
                if (acc.lowestAsk == 0 || limit < acc.lowestAsk) acc.lowestAsk = limit;
            }
            if (!o.inBook && o.orderType == BazaarTypes.OrderType.StopLimit) ++acc.stopCount;
        }
        tally.bidSize = _sat96(acc.bidSize);
        tally.askSize = _sat96(acc.askSize);
        // At most the set's size, which the creation cap holds under 2^32.
        tally.stopCount = uint32(acc.stopCount);
        tally.bidLimitNotional = _sat128(acc.bidLimitNotional);
        tally.askLimitNotional = _sat128(acc.askLimitNotional);
        // Limits are stored as uint128 (BazaarTypes.Order).
        tally.highestBid = uint128(acc.highestBid);
        tally.lowestAsk = uint128(acc.lowestAsk);
    }

    /// @notice Record a leg joining the set `t` describes — a created order's whole size, or the
    ///         remaining leg an amendment leaves — at `limit` on its side, and one more waiting
    ///         StopLimit when it is one. `limit` fits uint128: callers pass a stored limit.
    function _tallyAdd(BazaarTypes.RestingTally storage t, bool isLong, bool waitingStop, uint256 size, uint256 limit)
        internal
    {
        uint256 limitNotional = Math.mulDiv(size, limit, BazaarTypes.BAZAAR_SCALE);
        if (isLong) {
            t.bidSize = _sat96(uint256(t.bidSize) + size);
            t.bidLimitNotional = _sat128(uint256(t.bidLimitNotional) + limitNotional);
            if (limit > t.highestBid) t.highestBid = uint128(limit);
        } else {
            t.askSize = _sat96(uint256(t.askSize) + size);
            t.askLimitNotional = _sat128(uint256(t.askLimitNotional) + limitNotional);
            uint256 lowest = t.lowestAsk;
            if (lowest == 0 || limit < lowest) t.lowestAsk = uint128(limit);
        }
        if (waitingStop) {
            uint32 stops = t.stopCount;
            if (stops != TALLY_INVALID) t.stopCount = stops + 1;
        }
    }

    /// @notice Record a leg leaving the set `t` describes — a canceled order's remaining leg, or
    ///         the old leg of an amendment — at `limit` on its side, and one waiting StopLimit
    ///         fewer when it was one. A field at its maximum stays there, since how far above
    ///         the set it sits is unknown; a subtraction that would take a field below zero marks
    ///         the tally invalid instead of writing it.
    function _tallySub(
        BazaarTypes.RestingTally storage t,
        bool isLong,
        bool waitingStop,
        uint256 remaining,
        uint256 limit
    ) internal {
        uint256 limitNotional = Math.mulDiv(remaining, limit, BazaarTypes.BAZAAR_SCALE);
        bool ok;
        if (isLong) {
            (ok, t.bidSize, t.bidLimitNotional) = _subLeg(t.bidSize, t.bidLimitNotional, remaining, limitNotional);
        } else {
            (ok, t.askSize, t.askLimitNotional) = _subLeg(t.askSize, t.askLimitNotional, remaining, limitNotional);
        }
        if (ok && waitingStop) {
            uint32 stops = t.stopCount;
            if (stops == 0) ok = false;
            else if (stops != TALLY_INVALID) t.stopCount = stops - 1;
        }
        if (!ok) t.stopCount = TALLY_INVALID;
    }

    /// @dev One side's size and limit notional less a leg, each left alone at its maximum; `ok`
    ///      is false, and nothing changes, when either would go below zero.
    function _subLeg(uint96 size, uint128 notional, uint256 dSize, uint256 dNotional)
        private
        pure
        returns (bool ok, uint96 newSize, uint128 newNotional)
    {
        newSize = size;
        newNotional = notional;
        if (size != type(uint96).max) {
            if (size < dSize) return (false, size, notional);
            newSize = uint96(size - dSize);
        }
        if (notional != type(uint128).max) {
            if (notional < dNotional) return (false, size, notional);
            newNotional = uint128(notional - dNotional);
        }
        ok = true;
    }

    function _sat96(uint256 v) private pure returns (uint96) {
        return v > type(uint96).max ? type(uint96).max : uint96(v);
    }

    function _sat128(uint256 v) private pure returns (uint128) {
        return v > type(uint128).max ? type(uint128).max : uint128(v);
    }

    /// @dev Initial margin on the worst-case notional (_worstCaseNotional) plus the fill gate's
    ///      debit across the resting set: what the position-aware gates require of the orders.
    function _orderImrRequirement(
        uint256 imrBp,
        bool posIsLong,
        uint256 posNotional,
        uint256 longExposure,
        uint256 shortExposure,
        uint256 fillDebit
    ) internal pure returns (uint256) {
        uint256 worst = _worstCaseNotional(posIsLong, posNotional, longExposure, shortExposure);
        return Math.mulDiv(imrBp, worst, BazaarTypes.BP_SCALE) + fillDebit;
    }

    /// @dev Soft-fail USDC transfer (BAZAAR precision in, 6dp out).
    function _trySendUsdc(address usdc, address to, uint256 amountBazaar) internal returns (bool) {
        if (usdc == address(0) || to == address(0)) return false;
        uint256 usdcAmount = amountBazaar / 1e12;
        if (usdcAmount == 0) return false;
        (bool callOk, bytes memory data) = usdc.call(abi.encodeWithSelector(0xa9059cbb, to, usdcAmount));
        if (!callOk) return false;
        if (data.length == 0) return true;
        return abi.decode(data, (bool));
    }

    // ================================================================
    //                        Withdraw Logic
    // ================================================================

    /// @notice Processes a collateral withdrawal: validates, handles the terminal branch, updates the bucket.
    /// @dev Called via DELEGATECALL from BazaarPair. Does NOT handle the USDC transfer or ETH refund.
    /// @return withdrawAmount The cash to send, in BAZAAR precision. Equals `params.amount` on a
    ///         live pair; on a terminated pair it is the amount scaled by the frozen principal
    ///         ratio, which is below 100% only when cash could not cover principal. On a
    ///         terminated pair with positions still open, an amount beyond the principal ledger
    ///         reverts CollateralLib__LedgerShortfall carrying what the ledger can pay.
    function withdrawCollateral(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        mapping(address => uint256) storage terminalProfitClaim,
        BazaarTypes.TerminalSettlement storage ts,
        EnumerableSet.UintSet storage orderSet,
        mapping(uint256 => BazaarTypes.Order) storage orders,
        mapping(address => BazaarTypes.RestingTally) storage restingTallies,
        BazaarTypes.CollateralWithdrawParams memory params,
        address caller
    ) external returns (uint256 withdrawAmount) {
        if (params.amount == 0) {
            revert CollateralLib__ZeroWithdrawalAmount();
        }

        if (params.pendingTermination) {
            revert CollateralLib__PairScheduledForTermination();
        }

        // ------------------------------------------------------------------
        // Terminated: pay principal and the registered claim at the frozen ratios
        // ------------------------------------------------------------------
        if (params.isPairTerminated) {
            BazaarTypes.PositionBucket storage termBucket = positionBuckets[caller];

            // A position finalize did not wait for settles here, against the frozen ledgers.
            if (termBucket.size > 0) {
                _settleOne(
                    positionBuckets,
                    pairVault,
                    terminalProfitClaim,
                    ts,
                    BazaarTypes.TerminalSettleParams({
                        settlementPrice: params.settlementPrice,
                        currentFundingIndex: params.currentFundingIndex,
                        postFinalize: true,
                        pairId: params.pairId
                    }),
                    caller
                );
            }

            // Registered claim: credited once, at the frozen profit ratio, into the bucket and
            // the principal ledger — finalize kept that cash out of the insurers' residual. The
            // tally drops to the claims still unpaid, which is what a re-freeze of the ratios
            // reserves for.
            uint256 claim = terminalProfitClaim[caller];
            if (claim > 0) {
                terminalProfitClaim[caller] = 0;
                ts.totalProfitClaims -= claim;
                uint256 pay = Math.mulDiv(claim, ts.profitRatio, BazaarTypes.BAZAAR_SCALE);
                if (pay > 0) {
                    termBucket.collateral = SafeCast.toUint128(uint256(termBucket.collateral) + pay);
                    pairVault.totalCollateralDeposited += pay;
                }
            }

            if (params.amount > termBucket.collateral) {
                revert CollateralLib__InsufficientCollateral(params.amount, termBucket.collateral);
            }
            termBucket.collateral -= uint128(params.amount);
            BucketLib.emitBucketUpdate(caller, termBucket, params.currentFundingIndex, params.marginReqs, params.pairId);

            // The ledger sits below the sum of the buckets by rounding dust once every position
            // is settled, and until then by the loss of each bankrupt position finalize did not
            // wait for: cash the ledger receives only when that position settles, which a draw
            // past the ledger would otherwise take from the fee escrow or from the holders still
            // in, at ratios the settlement is about to lower. So the dust is floored, and while
            // any position is open a draw past the ledger is refused with what the ledger can
            // pay, as _debitLedger refuses it on a live pair; settling the open positions
            // (permissionless, tipped) releases the rest at the ratios their shortfall leaves.
            uint256 ledger = pairVault.totalCollateralDeposited;
            if (params.amount > ledger) {
                if (pairVault.totalLongOI != 0 || pairVault.totalShortOI != 0) {
                    revert CollateralLib__LedgerShortfall(params.amount, ledger);
                }
                ledger = params.amount;
            }
            pairVault.totalCollateralDeposited = ledger - params.amount;

            withdrawAmount = Math.mulDiv(params.amount, ts.principalRatio, BazaarTypes.BAZAAR_SCALE);
            emit BazaarTypes.CollateralWithdrawn(params.pairId, caller, withdrawAmount);
            return withdrawAmount;
        }
        // ------------------------------------------------------------------
        // Normal Operation: position-aware withdrawal with margin checks
        // ------------------------------------------------------------------
        BazaarTypes.PositionBucket memory bucket = positionBuckets[caller];

        // The resting set's reservation, as createOrder reserves it (_orderReserve): per side at
        // the price each order is valued at, plus the fill gate's debit summed over both sides.
        // Taken here against the spot of the price the pair resolved, not in the pair's sweep:
        // the sweep runs before any price is read, since what it leaves decides whether a price
        // is needed at all. The tally's bound stands in for the set first; the gates below read
        // the set itself only when the bound fails them, or cannot be taken.
        (bool bounded, uint256 longOrderExposure, uint256 shortOrderExposure, uint256 fillDebit) =
            _restingBound(restingTallies[caller], params.spotPrice);
        if (!bounded) {
            (longOrderExposure, shortOrderExposure, fillDebit) =
                _sweepRestingReserve(orderSet, orders, restingTallies[caller], params.currentBlock, params.spotPrice);
        }

        // An unhealthy verdict other than the ADL latch (reasons 2, 3 and 4) fixes the settlement
        // price in this same transaction, which schedules the cutoff the pendingTermination check
        // above refuses on: the pair reads that flag after the verdict, so a position holder and
        // an account with only resting orders, which it prices and judges alike, are refused there
        // in the transaction that finds the shortfall (the refusal rolls the fix back with it, and
        // the next priced flow that completes fixes it for good). This gate is what refuses the
        // one account the pair judges without a price: a flat account, for which it runs only the
        // books-vs-cash comparison and reports a short balance as reason 3 without fixing a
        // settlement price it does not have. It also stands behind the cutoff check for a verdict
        // that found no price to fix one at. None of them is paid ahead of the pro-rata settlement.
        if (!params.isVaultHealthy && params.vaultHealthReason != 1) {
            revert CollateralLib__WithdrawalBlockedVaultUnhealthy();
        }

        bool exposurePresent = bucket.size != 0;

        if (exposurePresent) {
            // Price update is required when there's exposure
            // (caller must have already obtained currentPrice from oracle)
            if (params.currentPrice == 0) {
                revert CollateralLib__NoPriceUpdateDataProvided();
            }

            // Position-holder equity is released only against a price the oracle can currently
            // attest. Around a market closure, off-chain venues (pre-market, 24/7 books) print
            // the reopen hours before this contract can, so a holder who is already dead at the
            // real price could otherwise withdraw down to an IMR computed at the frozen mark —
            // converting their own loss into vault deficit that the termination waterfall passes
            // to the winning side. No margin rate closes that channel (a rate cannot price
            // information the oracle has not seen); withholding release does. Deposits stay open
            // while stale — adding collateral is always safe for the vault — and order-only
            // accounts keep the flat path below: they hold no position whose frozen mark could
            // hide a loss, and their resting exposure keeps its order-IMR reserve.
            if (params.isOracleStale) {
                revert CollateralLib__WithdrawalRequiresFreshPrice();
            }

            // Reason 1 = liquidation exposure exceeds insurance. The ADL window is then either
            // open — possibly opened by the isVaultHealthy call in THIS tx, after the pair-level
            // freeze guard was already evaluated (it reads isAdlPending before the health check
            // can set it) — or withheld because the price was too stale to open one against.
            // Gating on the reason rather than on the latch closes the one-withdrawal gap in the
            // window-opening transaction, and keeps a vault that is already over its insurance
            // from being exited on a mark the protocol declined to act on. Flat users are exempt
            // by placement: this branch only runs when the caller holds a position.
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

            // An account holding a position must retain margin in COLLATERAL proper — cash, not
            // equity. The margin check below is EQUITY-based (collateral + unrealized PnL), so
            // without a cash floor a profitable position could withdraw its entire deposit and
            // carry the margin on paper profit alone. That state fails two ways:
            // - Every trading fee is charged against bucket collateral:
            //   MatchingEngineLib._checkMargin rejects any fill whose fee exceeds it and the
            //   caller AUTO-CANCELS the order — the holder could not close through the book
            //   until they re-deposited. Either floor rate covers the worst-case closing fee
            //   with multiples to spare (mmrBp never sits below 4x the taker insurance fee's
            //   hard cap).
            // - Paper profit is only as good as the mark, and it evaporates in the same adverse
            //   move it would need to buffer.
            // The retained rate follows how the pair can move against that buffer:
            // - Continuously traded pairs retain mmrBp: price walks, liquidation can interpose
            //   at the maintenance line, so cash beyond it buys little.
            // - Non-continuously traded pairs retain imrBp: price jumps the session gap where no
            //   liquidation can interpose and the mark the profit is measured at is frozen, so
            //   the cash must carry the position through a reopen on its own. imrBp — at least
            //   twice the demonstrated reopen gap — does that with the full IMR-MMR band to
            //   spare, with no help from the profit the same gap may have erased.
            // The pair's CURRENT rates apply, not the lagged rate liquidation judges by: the lag
            // exists so a rising requirement cannot liquidate a position before the rise has
            // held; a withdrawal is a new voluntary release of equity and prices the requirement
            // as it stands. An account whose collateral already sits below the floor (the rate
            // ratcheted since an earlier withdrawal) can withdraw nothing further until it
            // deposits, partially closes (which realizes PnL into collateral and shrinks the
            // floor), or goes flat — the flat path below has no floor.
            {
                uint256 floorRateBp = params.isContinuouslyTraded ? params.marginReqs.mmrBp : params.marginReqs.imrBp;
                uint256 minRetained = Math.mulDiv(floorRateBp, currentState.currentNotional, BazaarTypes.BP_SCALE);
                uint256 remaining = currentState.effectiveCollateral - params.amount;
                if (remaining < minRetained) {
                    revert CollateralLib__MustRetainMinimumCollateral(remaining, minRetained);
                }
            }

            // Initial margin on the worst-case notional, plus what the fill gate debits across
            // the resting orders ahead of its own margin test (_fillDebitOf): a withdrawal that
            // left less would walk the owner into an order that can only ever be auto-canceled.
            // A bound that refuses is not a verdict: the set is then read and judged as it is.
            uint256 imrRequirement = _orderImrRequirement(
                params.marginReqs.imrBp,
                bucket.isLong,
                currentState.currentNotional,
                longOrderExposure,
                shortOrderExposure,
                fillDebit
            );
            if (bounded && currentState.availableEquity < imrRequirement + params.amount) {
                (longOrderExposure, shortOrderExposure, fillDebit) = _sweepRestingReserve(
                    orderSet, orders, restingTallies[caller], params.currentBlock, params.spotPrice
                );
                imrRequirement = _orderImrRequirement(
                    params.marginReqs.imrBp,
                    bucket.isLong,
                    currentState.currentNotional,
                    longOrderExposure,
                    shortOrderExposure,
                    fillDebit
                );
            }
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

            _debitLedger(pairVault, params.amount);

            emit BazaarTypes.CollateralWithdrawn(params.pairId, caller, params.amount);
            return params.amount;
        }

        // ------------------------------------------------------------------
        // No position exposure: collateral withdrawal with order margin check
        // ------------------------------------------------------------------
        if (bucket.collateral < params.amount) {
            revert CollateralLib__InsufficientCollateral(params.amount, bucket.collateral);
        }

        // If user has outstanding limit orders, ensure enough margin remains: initial margin on
        // the larger side (no position, so the worst case is max(longOrders, shortOrders)) plus
        // the fill gate's debit across the set (_fillDebitOf). With no position the worst case
        // of _worstCaseNotional is that larger side, and an empty set requires nothing. A bound
        // that refuses is not a verdict: the set is then read and judged as it is.
        {
            uint256 orderImrReq = _orderImrRequirement(
                params.marginReqs.imrBp, false, 0, longOrderExposure, shortOrderExposure, fillDebit
            );
            if (bounded && bucket.collateral - params.amount < orderImrReq) {
                (longOrderExposure, shortOrderExposure, fillDebit) = _sweepRestingReserve(
                    orderSet, orders, restingTallies[caller], params.currentBlock, params.spotPrice
                );
                orderImrReq = _orderImrRequirement(
                    params.marginReqs.imrBp, false, 0, longOrderExposure, shortOrderExposure, fillDebit
                );
            }
            if (bucket.collateral - params.amount < orderImrReq) {
                revert CollateralLib__InsufficientMarginAfterWithdrawal(params.amount, orderImrReq);
            }
        }

        // Persist updated collateral (keep same position fields)
        BazaarTypes.PositionBucket storage noExpBucket = positionBuckets[caller];
        // Guarded above: params.amount <= bucket.collateral (uint128).
        noExpBucket.collateral = uint128(uint256(bucket.collateral) - params.amount);
        BucketLib.emitBucketUpdate(caller, noExpBucket, params.currentFundingIndex, params.marginReqs, params.pairId);

        _debitLedger(pairVault, params.amount);
        emit BazaarTypes.CollateralWithdrawn(params.pairId, caller, params.amount);
        return params.amount;
    }

    /// @notice Debits the deposits ledger for a withdrawal off a live pair.
    /// @dev Inter-user realized PnL never reaches this ledger: a winner closing against a fresh
    ///      opener is credited into their bucket while the counterparty carrying the other side
    ///      of that move still holds it unrealized. `Σ bucket.collateral - totalCollateralDeposited`
    ///      is therefore the open book's aggregate unrealized loss, and a ledger below the sum of
    ///      buckets is an ordinary state rather than a corrupted one — a caller's own bucket
    ///      balance is no bound on what the ledger can fund, and every gate above bounds them by
    ///      that balance alone.
    ///
    ///      The vault's inherited inventory is part of that open book, and its loss is the ordinary
    ///      way a solvent pair reaches the revert. A seizure moves the estate's whole collateral
    ///      into the insurance fund (RiskParamsLib.collectFromLedger), including the part that
    ///      already covers the counterparties' gains, and that part returns only when the
    ///      inventory settles at a loss (RiskParamsLib.fundLedger). Until then the ledger sits
    ///      below the claims on it by the inventory's loss at the mark, and a winner who realized
    ///      against the estate can be refused the tail of a balance the fund holds in full,
    ///      earmarked as `pendingLiqSeized`. Any exit pays it back — an unload, an opposing
    ///      netting, an ADL close — and a winner still holding the position is itself a
    ///      counterparty the permissionless `unloadVault` can fill. A ledger short by more than
    ///      that loss means the open book no longer backs the claims against it: a solvent
    ///      trader's collateral covers the unrealized loss it contributes, so only bad debt opens
    ///      the rest of the gap.
    ///
    ///      Either way the withdrawal is refused rather than paid down to the ledger or advanced
    ///      out of the inventory's earmark. A live pair has no frozen ratio to pay a partial claim
    ///      at: settling this caller short would pick a rate for them alone and rank them ahead of
    ///      everyone still in the book, and paying the inventory's loss at the mark before an exit
    ///      realizes it would hand the first claimant, in full, cash the fund may yet need for
    ///      every claimant. Dividing a ledger too small for its claims is the terminated branch's
    ///      job, where every withdrawal is scaled by the principal ratio then in force. The
    ///      revert carries what the ledger can pay now, so a caller can take that much and return
    ///      for the rest.
    /// @param pairVault The pair's vault aggregates.
    /// @param amount The withdrawal to debit, in BAZAAR precision.
    function _debitLedger(BazaarTypes.Vault storage pairVault, uint256 amount) private {
        uint256 available = pairVault.totalCollateralDeposited;
        if (amount > available) revert CollateralLib__LedgerShortfall(amount, available);
        unchecked {
            pairVault.totalCollateralDeposited = available - amount;
        }
    }
}
