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

    /// @notice Minimum collateral deposit, and the absolute floor a position-holding account must
    ///         retain on withdrawal. Matches the insurance-fund minimum so both entry points speak
    ///         the same "$5 minimum" rule.
    uint256 internal constant MIN_COLLATERAL_AMOUNT = 5 * BazaarTypes.BAZAAR_SCALE;

    /// @notice Notional-proportional component of the retained-collateral floor: a position-holding
    ///         account must keep at least max(MIN_RETAINED_COLLATERAL_BP of notional,
    ///         MIN_COLLATERAL_AMOUNT). Fees scale with notional, so a flat floor alone leaves large
    ///         positions unable to pay the fee that closes them; 50 bp covers the worst-case
    ///         closing fee (the taker insurance fee tops out at 50 bp only when the fund is far
    ///         below target, and is typically a small fraction of that) with room to spare.
    uint256 internal constant MIN_RETAINED_COLLATERAL_BP = 50; // 0.5%
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
    error CollateralLib__MustRetainMinimumCollateral(uint256 remaining, uint256 minimum);

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

        // Block deposits if pair is at or past scheduled termination
        if (params.scheduledTerminationTs != 0 && block.timestamp >= params.scheduledTerminationTs) {
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
    //                 Terminal Settlement (two-stage termination)
    // ================================================================

    /// @notice Settle positions at the fixed terminal price. Permissionless and harmless to the
    ///         settled user: entitlements are identical before and after (pure accounting at a
    ///         frozen price). During the 48h window (postFinalize=false) winner PnL registers
    ///         into ts.totalProfitClaims and uncovered losses into ts.terminalBadDebt; after
    ///         finalize (postFinalize=true) late winners get an immediate clipped credit from
    ///         the unreserved surplus and late bad debt charges whatever insurance remains.
    ///         Loser losses always release from the principal ledger (D) into the surplus.
    ///         A max(MIN_LIQUIDATOR_REWARD, LIQUIDATION_FEE_EBP of notional) bounty pays the caller,
    ///         charged to the settled position itself: cash from its collateral first, then — for a
    ///         window-settled winner — a transfer out of its registered profit claim, collected
    ///         pro-rata after finalize; only positions with neither left fall back to the
    ///         insurance fund.
    function settleTerminalPositions(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        mapping(address => uint256) storage terminalProfitClaim,
        BazaarTypes.TerminalSettlement storage ts,
        uint256 settlementPrice,
        int256 currentFundingIndex,
        bool postFinalize,
        bytes32 pairId,
        address usdc,
        address[] calldata users
    ) external returns (uint256 settledCount) {
        BazaarTypes.TerminalSettleParams memory p = BazaarTypes.TerminalSettleParams({
            settlementPrice: settlementPrice,
            currentFundingIndex: currentFundingIndex,
            postFinalize: postFinalize,
            payBounty: true,
            pairId: pairId,
            usdc: usdc
        });
        uint256 directBounty = 0; // charged to the settled positions' own collateral
        uint256 insuranceBounty = 0; // only positions with nothing of their own left
        for (uint256 i = 0; i < users.length; i++) {
            (bool settled, uint256 direct, uint256 fromInsurance) =
                _settleOne(positionBuckets, pairVault, terminalProfitClaim, ts, p, users[i]);
            if (settled) {
                unchecked {
                    ++settledCount;
                }
                directBounty += direct;
                insuranceBounty += fromInsurance;
            }
        }
        // Direct bounties were debited from each settled position's own collateral AND from the
        // principal ledger in the same step, so this cash is backed by that D decrement — paying
        // it can never reach another user's reserved principal. Unconditional (a soft-fail just
        // strands it as surplus). The insurance portion is debit-if-covered with a soft-restore.
        if (directBounty > 0) {
            _trySendUsdc(p.usdc, msg.sender, directBounty);
        }
        if (insuranceBounty > 0 && pairVault.insuranceFundBalance >= insuranceBounty) {
            pairVault.insuranceFundBalance -= insuranceBounty;
            if (!_trySendUsdc(p.usdc, msg.sender, insuranceBounty)) {
                pairVault.insuranceFundBalance += insuranceBounty;
            }
        }
    }

    /// @dev Settle a single position at the terminal price. Returns (settled, directBounty,
    ///      insuranceBounty). Losers: loss (price + funding) reduces bucket AND the principal
    ///      ledger D — the release that feeds the profit surplus; uncovered loss registers as
    ///      bad debt. Winners: PnL becomes a profit claim (registered during the window; clipped
    ///      junior credit after finalize). The settlement bounty is charged to the settled
    ///      position: cash from its remaining collateral first, then any remainder transfers from
    ///      its registered profit claim to the settler (claim units, not cash); only positions
    ///      with neither left charge insurance. Vault OI aggregates are updated here directly.
    function _settleOne(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        BazaarTypes.Vault storage pairVault,
        mapping(address => uint256) storage terminalProfitClaim,
        BazaarTypes.TerminalSettlement storage ts,
        BazaarTypes.TerminalSettleParams memory p,
        address user
    ) internal returns (bool settled, uint256 directBounty, uint256 insuranceBounty) {
        BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
        uint256 size = bucket.size;
        if (size == 0) return (false, 0, 0);

        BazaarTypes.MarginRequirements memory zeroReqs; // settlement ignores margins
        BazaarTypes.BucketState memory state =
            BucketLib.calculateState(bucket, p.settlementPrice, p.currentFundingIndex, zeroReqs);

        // Remove from OI aggregates (floored, mirroring LiquidationLib).
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
        if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            uint256 covered = loss < bucket.collateral ? loss : bucket.collateral;
            bucket.collateral -= covered;
            // Release the realized loss from the principal ledger — this is what frees the
            // surplus that backs winner profits. Floored defensively.
            pairVault.totalCollateralDeposited =
                pairVault.totalCollateralDeposited > covered ? pairVault.totalCollateralDeposited - covered : 0;
            uint256 uncovered = loss - covered;
            if (uncovered > 0) {
                if (!p.postFinalize) {
                    ts.terminalBadDebt += uncovered;
                } else {
                    // Late-discovered bad debt: charge whatever insurance remains.
                    uint256 take =
                        uncovered < pairVault.insuranceFundBalance ? uncovered : pairVault.insuranceFundBalance;
                    pairVault.insuranceFundBalance -= take;
                }
            }
        } else if (pnl > 0) {
            uint256 claimable = uint256(pnl);
            if (claimable > 0) {
                if (!p.postFinalize) {
                    terminalProfitClaim[user] += claimable;
                    ts.totalProfitClaims += claimable;
                } else {
                    // Junior path: immediate credit clipped to the unreserved surplus; the credit
                    // moves into the principal ledger so it becomes reserved (and withdrawable).
                    uint256 avail = _unreservedSurplus(pairVault, ts, p.usdc);
                    uint256 pay = claimable < avail ? claimable : avail;
                    if (pay > 0) {
                        bucket.collateral += pay;
                        pairVault.totalCollateralDeposited += pay;
                    }
                }
            }
        }

        // Settlement bounty — charged to the settled position itself, from whatever collateral it
        // has left AFTER its own PnL is booked. Winners and losers are treated identically, and
        // this is the same idiom every other fee in the protocol uses (cf. _chargeRelayerFee):
        // debit the bucket AND the principal ledger together, so the D decrement exactly backs the
        // USDC that leaves. That makes it impossible for a bounty to dip into another user's
        // reserved principal or the insurers' remainder — no surplus check required. Only a
        // position with nothing left (a loser wiped out by its own loss) falls back to insurance,
        // so wiped positions still have someone paid to settle them.
        if (p.payBounty) {
            uint256 want = _bountyFor(size, p.settlementPrice);

            // 1) Collateral first — debiting the bucket AND the principal ledger together means
            //    the D decrement backs the USDC leaving, so this can never reach another user's
            //    reserved principal.
            uint256 fromCollateral = want < bucket.collateral ? want : bucket.collateral;
            if (fromCollateral > 0) {
                bucket.collateral -= fromCollateral;
                pairVault.totalCollateralDeposited = pairVault.totalCollateralDeposited > fromCollateral
                    ? pairVault.totalCollateralDeposited - fromCollateral
                    : 0;
                directBounty = fromCollateral;
            }
            uint256 rest = want - fromCollateral;

            // 2) A winner whose collateral doesn't cover the bounty pays the remainder out of the
            //    profit claim registered above — transferred to the settler as claim units, never
            //    cash. The retained-collateral floor is enforced only at withdrawal time, so a
            //    position can still arrive here nearly bare: relayer fees are charged straight
            //    from collateral with no floor check, and the bounty scales with settlement-time
            //    notional while the floor was sized at the last withdrawal. Paying this leg in
            //    cash would spend a full unit of surplus to retire a claim unit worth less than
            //    that whenever the book is underwater, diluting every other winner's frozen
            //    ratio. A claim transfer moves no cash and leaves ts.totalProfitClaims unchanged,
            //    so the ratio is untouched: the settler simply joins the winners at the same
            //    pro-rata terms, collected via withdrawal after finalize. No budget or cap is
            //    needed — nothing leaves the pot here. A self-settling winner transfers to
            //    themselves, a harmless no-op.
            if (rest > 0) {
                uint256 claim = terminalProfitClaim[user];
                uint256 fromClaim = rest < claim ? rest : claim;
                if (fromClaim > 0) {
                    terminalProfitClaim[user] = claim - fromClaim;
                    terminalProfitClaim[msg.sender] += fromClaim;
                    rest -= fromClaim;
                }
            }

            // 3) Neither collateral nor claim left — a loser wiped out by its own loss, or a
            //    solvent position whose entire equity was smaller than the bounty and consumed by
            //    leg 1. Insurance covers the remainder so these positions still have someone paid
            //    to settle them.
            if (rest > 0 && bucket.collateral == 0 && terminalProfitClaim[user] == 0) {
                insuranceBounty = rest;
            }
        }

        // Zero the position (keep collateral).
        bucket.size = 0;
        bucket.entryValue = 0;
        bucket.entryFundingIndex = 0;
        bucket.entryMmrBp = 0;
        bucket.mmrUpdateTs = 0;
        BucketLib.emitBucketUpdate(user, bucket, p.currentFundingIndex, zeroReqs, p.pairId);
        return (true, directBounty, insuranceBounty);
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

    /// @dev Surplus not reserved for principal (D), insurers (I), or registered claims.
    function _unreservedSurplus(
        BazaarTypes.Vault storage pairVault,
        BazaarTypes.TerminalSettlement storage ts,
        address usdc
    ) internal view returns (uint256) {
        (bool ok, bytes memory data) = usdc.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (!ok || data.length < 32) return 0;
        uint256 cashBazaar = abi.decode(data, (uint256)) * 1e12; // USDC 6dp -> BAZAAR 18dp
        uint256 reserved = pairVault.totalCollateralDeposited + pairVault.insuranceFundBalance + ts.profitReserve;
        return cashBazaar > reserved ? cashBazaar - reserved : 0;
    }

    /// @dev Settlement bounty per position: max(MIN_LIQUIDATOR_REWARD, LIQUIDATION_FEE_EBP of
    ///      notional) — the same reward formula as live liquidation in LiquidationLib.
    function _bountyFor(uint256 size, uint256 price) internal pure returns (uint256) {
        uint256 notional = Math.mulDiv(size, price, BazaarTypes.BAZAAR_SCALE);
        uint256 bps = Math.mulDiv(notional, BazaarTypes.LIQUIDATION_FEE_EBP, BazaarTypes.EBP_SCALE);
        return bps > BazaarTypes.MIN_LIQUIDATOR_REWARD ? bps : BazaarTypes.MIN_LIQUIDATOR_REWARD;
    }

    /// @dev Soft-fail USDC transfer (BAZAAR precision in, 6dp out). Mirrors LiquidationLib.
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

    /// @notice Processes withdraw collateral logic: validates, handles all termination states, updates bucket.
    /// @dev Called via DELEGATECALL from BazaarPair. Does NOT handle USDC transfer or ETH refund.
    function withdrawCollateral(
        mapping(address => BazaarTypes.PositionBucket) storage positionBuckets,
        mapping(address => bool) storage terminalHaircutApplied,
        BazaarTypes.Vault storage pairVault,
        mapping(address => uint256) storage terminalProfitClaim,
        BazaarTypes.TerminalSettlement storage ts,
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

            // Still-open position: settle it inline via the shared terminal-settlement path
            // (post-finalize semantics: loss releases from D / late bad debt charges insurance /
            // late winner PnL becomes a clipped junior credit). No bounty for self-settlement.
            // Vault OI aggregates are updated inside _settleOne, so positionClosed stays false
            // (the pair-side writeback must not double-decrement them).
            if (termBucket.size > 0) {
                _settleOne(
                    positionBuckets,
                    pairVault,
                    terminalProfitClaim,
                    ts,
                    BazaarTypes.TerminalSettleParams({
                        settlementPrice: params.normalTerminationPrice,
                        currentFundingIndex: params.currentFundingIndex,
                        postFinalize: true,
                        payBounty: false,
                        pairId: params.pairId,
                        usdc: params.usdcToken
                    }),
                    caller
                );
            }

            // Registered profit claim (settled during the window): credit claim x frozen ratio
            // into the bucket once. The credit moves into the principal ledger so it is reserved
            // and withdrawable like principal from here on.
            uint256 claim = terminalProfitClaim[caller];
            if (claim > 0) {
                terminalProfitClaim[caller] = 0;
                uint256 pay = Math.mulDiv(claim, ts.profitRatioBp, BazaarTypes.BP_SCALE);
                if (pay > 0) {
                    termBucket.collateral += pay;
                    pairVault.totalCollateralDeposited += pay;
                    ts.profitReserve = ts.profitReserve > pay ? ts.profitReserve - pay : 0;
                }
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
            // normal-operation withdrawal from slipping through. Reason 2 (ADL timeout)
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

            // An account holding a position must retain max(0.5% of notional, $5) of COLLATERAL.
            // The margin check below is EQUITY-based (collateral + unrealized PnL), so a profitable
            // position could otherwise withdraw its entire deposit and carry the margin on profit
            // alone — leaving zero collateral. That state is a trap: every fee in the protocol is
            // charged against bucket collateral, so MatchingEngineLib._checkMargin rejects any fill
            // whose fee exceeds it and the caller AUTO-CANCELS the order, and _chargeRelayerFee
            // reverts. The holder could not close through the book (nor use meta-transactions)
            // until they re-deposited, with their orders silently vanishing.
            // The floor is notional-PROPORTIONAL because fees are: a flat minimum is ample for a
            // $100 position but nowhere near the fee on a $100k one, which would leave exactly the
            // large positions stuck (a partial close does not help either — the remainder must
            // still meet IMR out of collateral, so only a full close escapes, and that needs the
            // whole fee up front).
            {
                uint256 minRetained =
                    Math.mulDiv(MIN_RETAINED_COLLATERAL_BP, currentState.currentNotional, BazaarTypes.BP_SCALE);
                if (minRetained < MIN_COLLATERAL_AMOUNT) minRetained = MIN_COLLATERAL_AMOUNT;
                uint256 remaining = currentState.effectiveCollateral - params.amount;
                if (remaining < minRetained) {
                    revert CollateralLib__MustRetainMinimumCollateral(remaining, minRetained);
                }
            }

            // Check IMR requirement (2x during stale oracle periods)
            uint256 effectiveImrBp = params.marginReqs.imrBp;
            if (params.isOracleStale) {
                effectiveImrBp = effectiveImrBp * STALE_MARGIN_MULTIPLIER;
            }
            uint256 imrRequirement = Math.mulDiv(
                effectiveImrBp,
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
