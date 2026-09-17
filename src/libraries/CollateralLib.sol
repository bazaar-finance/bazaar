// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {BucketLib} from "./BucketLib.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";

/// @title CollateralLib
/// @notice External library for deposit and withdrawal collateral logic.
///         Runs via DELEGATECALL — has direct access to BazaarPair storage.
library CollateralLib {
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

        // Block deposits if pair is at or past scheduled termination
        if (params.scheduledTerminationTs != 0 && block.timestamp >= params.scheduledTerminationTs) {
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

    /// @notice Vault-health Check 2: does the contract still hold the USDC its books promise?
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
            // total is the sum of all claimable balances.
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
    ///         someone else credits the caller's escrow with TERMINAL_SETTLEMENT_TIP, funded as
    ///         _paySettlementTip describes; settling one's own position pays nothing.
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
            (bool settled, bool bankrupt) = _settleOne(positionBuckets, pairVault, terminalProfitClaim, ts, p, user);
            if (!settled) continue;
            unchecked {
                ++settledCount;
            }
            if (user != msg.sender) _paySettlementTip(positionBuckets, pairVault, feeEscrow, p, user, bankrupt);
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
    ///      withdrawals stay covered. Whatever the residual cannot fund stays out of the ledger
    ///      and leaves the last withdrawals short by that amount — the case the completeness
    ///      gate on finalize exists to prevent.
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
                // Insurance funds the shortfall as far as it goes, and only that much moves into
                // the principal ledger — the same rule the live protocol applies to a vault loss
                // insurance cannot cover. An unfunded remainder is recorded in the tally, never
                // credited to the ledger: the books must not claim cash the pot does not hold.
                uint256 take = shortfall < pairVault.insuranceFundBalance ? shortfall : pairVault.insuranceFundBalance;
                pairVault.insuranceFundBalance -= take;
                pairVault.totalCollateralDeposited += take;
            }
        }

        // Zero the position (keep collateral).
        bucket.size = 0;
        bucket.entryValue = 0;
        bucket.entryFundingIndex = 0;
        bucket.entryMmrBp = 0;
        bucket.mmrUpdateTs = 0;
        BucketLib.emitBucketUpdate(user, bucket, p.currentFundingIndex, zeroReqs, p.pairId);
        settled = true;
    }

    /// @dev Credit the settler's escrow with TERMINAL_SETTLEMENT_TIP, or as much of it as its
    ///      sources can fund. Settlement must never revert, so every leg is capped at its source.
    ///
    ///      Before finalize the settled position pays first, from whatever collateral its own
    ///      settlement left it, charged like a trading fee: the bucket and the deposits ledger
    ///      drop together, so the total finalize derives from the ledger falls by exactly what
    ///      left the pot and the insurers' residual is untouched. Insurance covers the rest,
    ///      all-or-nothing on coverage like every other insurance-funded reward. Its balance at
    ///      this point is the nominal one that finalize rewrites from the pot, so it is the
    ///      escrow credit, shrinking the pot, that actually charges the residual — the right
    ///      payer for a cost no trader can be charged, since it is junior to every trader. This
    ///      split is what keeps the tip unfarmable: a position with collateral pays its own tip,
    ///      and driving one to bankruptcy costs more than the tip pays.
    ///
    ///      After finalize a solvent straggler harms nobody (finalize reserved its equity in
    ///      full), so only a bankrupt one pays, from whatever residual the funding of its own
    ///      shortfall left: that settlement is the one the insurers' sweep gate waits for and the
    ///      one nobody is otherwise motivated to run.
    function _paySettlementTip(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        BazaarTypes.TerminalSettleParams memory p,
        address user,
        bool bankrupt
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
        if (remainder <= pairVault.insuranceFundBalance) {
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
    ///         ratio, which is below 100% only when cash could not cover principal.
    function withdrawCollateral(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        mapping(address => uint256) storage terminalProfitClaim,
        BazaarTypes.TerminalSettlement storage ts,
        BazaarTypes.CollateralWithdrawParams memory params,
        address caller
    ) external returns (uint256 withdrawAmount) {
        if (params.amount == 0) revert CollateralLib__ZeroWithdrawalAmount();

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
            // the principal ledger — finalize kept that cash out of the insurers' residual.
            uint256 claim = terminalProfitClaim[caller];
            if (claim > 0) {
                terminalProfitClaim[caller] = 0;
                uint256 pay = Math.mulDiv(claim, ts.profitRatioBp, BazaarTypes.BP_SCALE);
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

            // Floored: the ledger is the total finalize derived, which can sit below the sum of
            // buckets by rounding dust and, after an escape-hatch finalize, by the part of a
            // bankrupt position's shortfall that insurance could not fund.
            pairVault.totalCollateralDeposited = pairVault.totalCollateralDeposited > params.amount
                ? pairVault.totalCollateralDeposited - params.amount
                : 0;

            withdrawAmount = Math.mulDiv(params.amount, ts.principalRatioBp, BazaarTypes.BP_SCALE);
            emit BazaarTypes.CollateralWithdrawn(params.pairId, caller, withdrawAmount);
            return withdrawAmount;
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

            // Defensive backstop: an unhealthy verdict other than the ADL latch (reasons 2, 3
            // and 4) opens the settlement window in this same transaction, and the window check
            // above reverts on the very next call. Reaching here should therefore be impossible;
            // the guard keeps a future health path from letting a withdrawal through anyway.
            if (!params.isVaultHealthy && params.vaultHealthReason != 1) {
                revert CollateralLib__WithdrawalBlockedVaultUnhealthy();
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
            // The pair's CURRENT rates apply, not the per-position lagged effectiveMmr: the lag
            // exists so a rising requirement cannot liquidate a position that predates it; a
            // withdrawal is a new voluntary release of equity and prices the requirement as it
            // stands. An account whose collateral already sits below the floor (the rate
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

            // Check IMR requirement
            uint256 imrRequirement = Math.mulDiv(
                params.marginReqs.imrBp,
                _worstCaseNotional(
                    bucket.isLong,
                    currentState.currentNotional,
                    params.outstandingLongOrderExposure,
                    params.outstandingShortOrderExposure
                ),
                BazaarTypes.BP_SCALE
            );
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

        // If user has outstanding limit orders, ensure enough margin remains
        // No position → worst case is max(longOrders, shortOrders)
        {
            uint256 maxOrderExposure = params.outstandingLongOrderExposure > params.outstandingShortOrderExposure
                ? params.outstandingLongOrderExposure
                : params.outstandingShortOrderExposure;
            if (maxOrderExposure > 0) {
                uint256 orderImrReq = Math.mulDiv(params.marginReqs.imrBp, maxOrderExposure, BazaarTypes.BP_SCALE);
                if (bucket.collateral - params.amount < orderImrReq) {
                    revert CollateralLib__InsufficientMarginAfterWithdrawal(params.amount, orderImrReq);
                }
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
    ///      Solvent positions alone cannot drive the ledger short: a bucket is solvent only while
    ///      its equity covers its maintenance requirement, so its collateral covers the unrealized
    ///      loss it contributes. Reaching the revert means the open book no longer backs the claims
    ///      against it. The withdrawal is refused rather than paid down to the ledger, because a
    ///      live pair has no frozen ratio to pay a partial claim at: settling this caller short
    ///      would pick a rate for them alone and rank them ahead of everyone still in the book.
    ///      Dividing a ledger too small for its claims is the terminated branch's job, where every
    ///      withdrawal is scaled by the one `principalRatioBp` finalize froze.
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
