// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";

/// @title InsuranceVaultLib
/// @notice External library for insurance vault deposit, withdrawal, and share accounting.
///         Runs via DELEGATECALL — has direct access to BazaarPair storage through passed storage pointers.
library InsuranceVaultLib {
    // -------------------- Constants --------------------

    uint256 internal constant BP_SCALE = BazaarTypes.BP_SCALE;
    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;

    uint256 internal constant MIN_INSURANCE_DEPOSIT = 5 * BAZAAR_SCALE; // $5

    // Vote-maturity lot bookkeeping (mirrors the BazaarPairTerminator constants; lives here
    // rather than in BazaarPair for EIP-170 headroom). Lots older than RETENTION can be pruned
    // on deposit: the oldest live termination proposal has proposalTs >= now - 14d (7d vote +
    // 7d execute), so its maturity cutoff (proposalTs - MATURITY) >= now - 21d — any pruned
    // lot is guaranteed mature for every still-active proposal.
    uint256 internal constant INSURER_SHARE_MATURITY_PERIOD = 7 days;
    uint256 internal constant INSURER_LOT_RETENTION_PERIOD = INSURER_SHARE_MATURITY_PERIOD + 14 days;
    uint16 internal constant MAX_DEPOSITS_PER_WINDOW = 100;

    uint256 internal constant INSURANCE_WITHDRAWAL_COOLDOWN = 20 days;
    uint256 internal constant INSURANCE_WITHDRAWAL_WINDOW = 3 days;
    uint256 internal constant INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD = 6 hours;
    uint256 internal constant INSURANCE_WITHDRAWAL_RATE_LIMIT_BP = 50; // 0.5% of OI per period (below target)
    uint256 internal constant INSURANCE_WITHDRAWAL_ABOVE_TARGET_RATE_LIMIT_BP = 100; // 1% of OI per period (above target)
    uint256 internal constant INSURANCE_WITHDRAWAL_ABOVE_TARGET_FUND_CAP_BP = 1000; // 10% of fund per period (above-target floor, so tiny OI can't trap a large fund)

    // -------------------- Errors --------------------

    error InsuranceVaultLib__ZeroDeposit();
    error InsuranceVaultLib__DepositBelowMinimum(uint256 amount, uint256 minimum);
    error InsuranceVaultLib__PairTerminated();
    error InsuranceVaultLib__PairScheduledForTermination(uint256 scheduledTs);
    error InsuranceVaultLib__DepositTooSmall();
    error InsuranceVaultLib__ZeroShares();
    error InsuranceVaultLib__ExceedsShares();
    error InsuranceVaultLib__NoWithdrawalRequest();
    error InsuranceVaultLib__WithdrawalRequestStaleEpoch();
    error InsuranceVaultLib__AdlBlocking();
    error InsuranceVaultLib__CooldownNotElapsed();
    error InsuranceVaultLib__WithdrawalWindowExpired();
    error InsuranceVaultLib__RateLimitExceeded();
    error InsuranceVaultLib__SharesLockedForVoting();
    error InsuranceVaultLib__TooManyRecentInsuranceDeposits(uint256 windowCount, uint16 cap);

    // -------------------- Structs --------------------

    // -------------------- Events --------------------

    /// @notice A drained-fund recap started a new share generation: every pre-drain balance
    ///         now lazily reads as 0. Emitted from the pair's address (DELEGATECALL).
    event InsuranceShareEpochBumped(uint256 newEpoch);

    // ================================================================
    //                      Share-Epoch Accounting
    // ================================================================
    // Share balances are generational: `shareEpochOf[user]` records the epoch a user's raw
    // balance was written in, and a balance from an older epoch reads as 0 (the pair's
    // `insuranceShares(user)` getter applies this). When a bad-debt cascade wipes the fund
    // below $1 while shares exist, the next deposit bumps the epoch: pre-drain stakes truly
    // went to zero, so their balances are lazily invalidated (a mapping cannot be iterated
    // to zero them eagerly) and the supply restarts from the rescuer's own contribution —
    // a one-transaction rescue with no holder enumeration, and no multiplicative share inflation
    // compounding per wipe+rescue cycle. The reset only fires BELOW $1, though: drains that stop
    // just above the floor still inflate the supply, which is why the deposit lot stores `shares`
    // full-width rather than behind a narrow overflow guard that inflation could eventually trip.

    /// @dev Roll `user`'s raw balance into `epoch`: a stale balance is a wiped stake, so it
    ///      resets to 0 before the epoch stamp is updated. Must be called before ANY write
    ///      to `insuranceShares[user]`.
    function _settle(
        mapping(address => uint256) storage insuranceShares,
        mapping(address => uint256) storage shareEpochOf,
        uint256 epoch,
        address user
    ) private {
        if (shareEpochOf[user] != epoch) {
            insuranceShares[user] = 0;
            shareEpochOf[user] = epoch;
        }
    }

    // ================================================================
    //                     UMA Proposer Reward
    // ================================================================

    /// @notice One-time-per-pair reward to the UMA termination proposer: 0.1% (10 bps) of the insurance
    ///         fund, capped at $100. Lives here (DELEGATECALL) for BazaarPair EIP-170 headroom;
    ///         the once-flag stays in the pair. Soft-fails the transfer so a blacklisted
    ///         proposer can't DoS the parent termination flow — the deduction is restored and
    ///         the pair's flag stays set so the reward can't be retried.
    function payUmaProposerReward(BazaarTypes.Vault storage vault, address usdc, address proposer) external {
        uint256 reward = (vault.insuranceFundBalance * 10) / BP_SCALE; // 10 bps = 0.1%
        uint256 cap = 100 * BAZAAR_SCALE; // $100
        if (reward > cap) reward = cap;
        if (reward == 0) return;

        vault.insuranceFundBalance -= reward;
        uint256 usdcAmount = reward / (BAZAAR_SCALE / BazaarTypes.USDC_SCALE);
        bool sent;
        if (usdcAmount > 0) {
            (bool callOk, bytes memory data) =
                usdc.call(
                    abi.encodeWithSelector(0xa9059cbb, proposer, usdcAmount) // transfer(address,uint256)
                );
            sent = callOk && (data.length == 0 || abi.decode(data, (bool)));
        }
        if (!sent) {
            vault.insuranceFundBalance += reward;
        }
    }

    // ================================================================
    //                         Deposit Logic
    // ================================================================

    /// @notice Processes insurance deposit: validates, calculates shares, updates state.
    /// @dev Called via DELEGATECALL from BazaarPair. Does NOT handle USDC transfer.
    /// @param insuranceShares Storage mapping of per-user RAW share balances
    /// @param shareEpochOf Storage mapping of the epoch each user's raw balance belongs to
    /// @param epoch Current share epoch
    /// @param totalInsuranceShares Current total shares issued (current epoch)
    /// @param vault Storage reference to the pair vault
    /// @param amount Deposit amount in BAZAAR precision
    /// @param isPairTerminatedEmergency Whether pair is emergency-terminated
    /// @param isPairTerminatedNormal Whether pair is normal-terminated
    /// @param scheduledTerminationTs Scheduled termination timestamp (0 if none)
    /// @param insuranceDepositLots Storage mapping of per-user vote-maturity lots
    /// @param insuranceLotsHead Storage mapping of per-user lot-list heads (prune cursor)
    /// @param insuranceDepositsPerDay Storage mapping backing the per-user deposit rate limit
    /// @param caller The depositing user (msg.sender from BazaarPair)
    /// @return sharesIssued Shares credited to the depositor (excludes any orphan lock mint)
    /// @return newTotalShares Updated total insurance shares
    /// @return newEpoch Share epoch after this deposit (== epoch unless a dead pool was reset)
    function depositToInsurance(
        mapping(address => uint256) storage insuranceShares,
        mapping(address => uint256) storage shareEpochOf,
        uint256 epoch,
        mapping(address => BazaarTypes.DepositLot[]) storage insuranceDepositLots,
        mapping(address => uint256) storage insuranceLotsHead,
        mapping(address => mapping(uint256 => uint16)) storage insuranceDepositsPerDay,
        uint256 totalInsuranceShares,
        BazaarTypes.Vault storage vault,
        uint256 amount,
        bool isPairTerminatedEmergency,
        bool isPairTerminatedNormal,
        uint256 scheduledTerminationTs,
        address caller
    ) external returns (uint256 sharesIssued, uint256 newTotalShares, uint256 newEpoch) {
        if (amount == 0) revert InsuranceVaultLib__ZeroDeposit();
        if (amount < MIN_INSURANCE_DEPOSIT) {
            revert InsuranceVaultLib__DepositBelowMinimum(amount, MIN_INSURANCE_DEPOSIT);
        }
        if (isPairTerminatedEmergency || isPairTerminatedNormal) revert InsuranceVaultLib__PairTerminated();
        if (scheduledTerminationTs != 0 && block.timestamp >= scheduledTerminationTs) {
            revert InsuranceVaultLib__PairScheduledForTermination(scheduledTerminationTs);
        }

        newEpoch = epoch;
        // Dead pool: live shares exist but bad debt wiped the fund below $1. Start a new
        // share generation — pre-drain balances lazily read as 0 (their stake truly went
        // to zero) and the supply restarts, so the rescuer below is minted 1:1 against
        // only their own contribution in a single transaction, with no holder enumeration
        // and no multiplicative supply blow-up.
        if (totalInsuranceShares != 0 && vault.insuranceFundBalance < BAZAAR_SCALE) {
            unchecked {
                newEpoch = epoch + 1;
            }
            totalInsuranceShares = 0;
            emit InsuranceShareEpochBumped(newEpoch);
        }

        // Calculate shares to issue
        uint256 shares;
        if (totalInsuranceShares == 0) {
            // Orphaned-balance guard: value sitting in the fund while no (live) shares
            // exist — fees/seized collateral accrued after every LP exited, or sub-$1 dust
            // surviving an epoch reset. Price it into permanently locked shares at
            // address(0) — nothing can call as address(0), so the orphan stays in the fund
            // as buffer forever and the depositor is priced only against their own
            // contribution. Without this, the first depositor's shares would own 100% of
            // the pre-existing fund for the price of `amount`. Minting 1:1 keeps the share
            // price at exactly 1.
            uint256 orphan = vault.insuranceFundBalance;
            if (orphan > 0) {
                _settle(insuranceShares, shareEpochOf, newEpoch, address(0));
                insuranceShares[address(0)] += orphan;
                totalInsuranceShares = orphan;
            }
            shares = amount;
        } else {
            // Live pool with fund >= $1 (dead pools were reset above), priced pro-rata.
            // mulDiv: at extreme-but-legitimate supplies the raw amount x totalShares product
            // can exceed uint256 even when the fair share count is small.
            shares = Math.mulDiv(amount, totalInsuranceShares, vault.insuranceFundBalance);
        }
        if (shares == 0) revert InsuranceVaultLib__DepositTooSmall();

        _settle(insuranceShares, shareEpochOf, newEpoch, caller);
        insuranceShares[caller] += shares;
        sharesIssued = shares;
        newTotalShares = totalInsuranceShares + shares;
        vault.insuranceFundBalance += amount;

        _recordDepositLot(insuranceDepositLots, insuranceLotsHead, insuranceDepositsPerDay, caller, shares);
    }

    /// @dev Deposit-lot bookkeeping for the vote-maturity (anti-snipe) system. Prunes lots aged
    ///      past INSURER_LOT_RETENTION_PERIOD (see the constant doc for why pruned lots are
    ///      guaranteed mature to every still-active proposal), enforces the
    ///      per-user deposit rate limit across the rolling maturity window, then appends this
    ///      deposit's lot. Pruned lots' share counts remain in insuranceShares, so the pair's
    ///      `mature = total - sum(active immature lots)` stays correct.
    function _recordDepositLot(
        mapping(address => BazaarTypes.DepositLot[]) storage insuranceDepositLots,
        mapping(address => uint256) storage insuranceLotsHead,
        mapping(address => mapping(uint256 => uint16)) storage insuranceDepositsPerDay,
        address caller,
        uint256 shares
    ) private {
        // Prune: advance the head past lots older than the retention period.
        if (block.timestamp > INSURER_LOT_RETENTION_PERIOD) {
            uint64 cutoff = uint64(block.timestamp - INSURER_LOT_RETENTION_PERIOD);
            BazaarTypes.DepositLot[] storage lots = insuranceDepositLots[caller];
            uint256 head = insuranceLotsHead[caller];
            uint256 len = lots.length;
            while (head < len && lots[head].ts <= cutoff) {
                unchecked {
                    ++head;
                }
            }
            insuranceLotsHead[caller] = head;
        }

        // Rate limit: at most MAX_DEPOSITS_PER_WINDOW deposits per user across the last
        // INSURER_SHARE_MATURITY_PERIOD, which also bounds the active lot list length.
        uint256 today = block.timestamp / 1 days;
        uint256 windowDays = INSURER_SHARE_MATURITY_PERIOD / 1 days; // 7
        uint256 lookback = today < windowDays ? today + 1 : windowDays;
        uint256 count;
        for (uint256 i = 0; i < lookback; i++) {
            count += insuranceDepositsPerDay[caller][today - i];
        }
        if (count >= MAX_DEPOSITS_PER_WINDOW) {
            revert InsuranceVaultLib__TooManyRecentInsuranceDeposits(count, MAX_DEPOSITS_PER_WINDOW);
        }
        unchecked {
            insuranceDepositsPerDay[caller][today] += 1;
        }

        // Append the lot. `shares` is stored full-width, so no value a legitimate deposit can
        // mint is rejectable here — a narrower field would brick deposits outright once the
        // supply inflated past it, a far worse failure than a wide slot.
        insuranceDepositLots[caller].push(BazaarTypes.DepositLot(uint64(block.timestamp), shares));
    }

    // ================================================================
    //                       Withdrawal Request
    // ================================================================

    /// @notice Records a withdrawal request, starting the cooldown period.
    /// @param insuranceShares Storage mapping of per-user RAW share balances
    /// @param shareEpochOf Storage mapping of the epoch each user's raw balance belongs to
    /// @param epoch Current share epoch
    /// @param withdrawalRequestTs Storage mapping of per-user epoch-stamped request slots
    ///        (`epoch << 64 | timestamp`)
    /// @param withdrawalRequestShareAmount Storage mapping of per-user requested share amounts
    /// @param shareAmount Number of shares to withdraw
    /// @param caller The requesting user
    function requestInsuranceWithdrawal(
        mapping(address => uint256) storage insuranceShares,
        mapping(address => uint256) storage shareEpochOf,
        uint256 epoch,
        mapping(address => uint256) storage withdrawalRequestTs,
        mapping(address => uint256) storage withdrawalRequestShareAmount,
        uint256 shareAmount,
        address caller
    ) external {
        if (shareAmount == 0) revert InsuranceVaultLib__ZeroShares();
        // Epoch-resolved read (no settle write needed): a stale balance is a wiped stake = 0.
        uint256 held = shareEpochOf[caller] == epoch ? insuranceShares[caller] : 0;
        if (held < shareAmount) revert InsuranceVaultLib__ExceedsShares();

        // Epoch-stamped (high 192 bits epoch, low 64 timestamp): a share-epoch bump voids the
        // request. The stake it committed was wiped, so its cooldown must not carry over to
        // fresh post-recap shares (executeInsuranceWithdrawal enforces the stamp match).
        withdrawalRequestTs[caller] = (epoch << 64) | block.timestamp;
        withdrawalRequestShareAmount[caller] = shareAmount;
    }

    // ================================================================
    //                     Withdrawal Execution
    // ================================================================

    /// @notice Executes a previously requested insurance withdrawal after cooldown.
    /// @dev Called via DELEGATECALL. Does NOT handle USDC transfer or oracle calls.
    ///      Caller must update price feed before calling and handle USDC transfer after.
    /// @param insuranceShares Storage mapping of per-user RAW share balances
    /// @param shareEpochOf Storage mapping of the epoch each user's raw balance belongs to
    /// @param epoch Current share epoch
    /// @param totalInsuranceShares Current total shares issued (current epoch)
    /// @param vault Storage reference to the pair vault
    /// @param withdrawalRequestTs Storage mapping of per-user epoch-stamped request slots
    ///        (`epoch << 64 | timestamp`)
    /// @param withdrawalRequestShareAmount Storage mapping of per-user requested share amounts
    /// @param rateLimitState Storage reference to withdrawal rate-limit state
    /// @param params Withdrawal parameters (pair state flags, price data)
    /// @param caller The withdrawing user
    /// @return withdrawAmount Amount to transfer to user (BAZAAR precision)
    /// @return newTotalShares Updated total insurance shares
    function executeInsuranceWithdrawal(
        mapping(address => uint256) storage insuranceShares,
        mapping(address => uint256) storage shareEpochOf,
        uint256 epoch,
        uint256 totalInsuranceShares,
        BazaarTypes.Vault storage vault,
        mapping(address => uint256) storage withdrawalRequestTs,
        mapping(address => uint256) storage withdrawalRequestShareAmount,
        BazaarTypes.InsuranceWithdrawalRateLimitState storage rateLimitState,
        BazaarTypes.InsuranceWithdrawParams memory params,
        address caller
    ) external returns (uint256 withdrawAmount, uint256 newTotalShares) {
        uint256 packedRequest = withdrawalRequestTs[caller];
        uint256 requestTs = uint256(uint64(packedRequest));
        if (requestTs == 0) revert InsuranceVaultLib__NoWithdrawalRequest();
        // A request stamped in an earlier share epoch committed a stake that a recap has since
        // wiped. Honoring its already-elapsed cooldown would let a re-depositor exit fresh
        // shares instantly — precisely while the fund is recovering from the wipe. Void it;
        // a new request serves the full cooldown against the new stake.
        if (packedRequest >> 64 != epoch) revert InsuranceVaultLib__WithdrawalRequestStaleEpoch();
        // Settle the caller into the current epoch before any balance check or write: a
        // wiped balance must read as 0, never burn current-epoch supply.
        _settle(insuranceShares, shareEpochOf, epoch, caller);
        // Active-pair gates: block during the "scheduled but not yet executed" limbo
        // and during ADL, enforce cooldown + window. Terminated pairs bypass all of these
        // so insurance LPs can pull funds without waiting (the scheduledTerminationTs check
        // would otherwise revert forever after a successful normal termination because the
        // field is never cleared).
        if (!params.isPairTerminatedEmergency && !params.isPairTerminatedNormal) {
            if (params.scheduledTerminationTs != 0 && block.timestamp >= params.scheduledTerminationTs) {
                revert InsuranceVaultLib__PairScheduledForTermination(params.scheduledTerminationTs);
            }
            if (params.adlPendingSince != 0) revert InsuranceVaultLib__AdlBlocking();
            if (block.timestamp < requestTs + INSURANCE_WITHDRAWAL_COOLDOWN) {
                revert InsuranceVaultLib__CooldownNotElapsed();
            }
            if (block.timestamp > requestTs + INSURANCE_WITHDRAWAL_COOLDOWN + INSURANCE_WITHDRAWAL_WINDOW) {
                revert InsuranceVaultLib__WithdrawalWindowExpired();
            }
        }

        uint256 shareAmount = withdrawalRequestShareAmount[caller];
        if (shareAmount > insuranceShares[caller]) revert InsuranceVaultLib__ExceedsShares();
        // Locked (voted) shares are reserved for an active insurer-termination proposal
        // and cannot be drained until the proposal resolves or its window expires.
        if (shareAmount + params.lockedShares > insuranceShares[caller]) {
            revert InsuranceVaultLib__SharesLockedForVoting();
        }

        // Calculate USDC value of shares at current share price. mulDiv's 512-bit
        // intermediate keeps shareAmount x fund from overflowing at recap-inflated
        // share magnitudes (supplies inflated by repeated drain-and-recap cycles).
        withdrawAmount = Math.mulDiv(shareAmount, vault.insuranceFundBalance, totalInsuranceShares);

        // Rate-limit withdrawals when pair is active
        if (!params.isPairTerminatedEmergency && !params.isPairTerminatedNormal) {
            uint256 totalOISize = vault.totalLongOI + vault.totalShortOI;
            uint256 currentPrice = params.spotPrice;
            // Gate on the floored notional, not the raw operands: dust OI at an extreme low
            // price can floor the product to 0, and dividing by it below would brick the
            // withdrawal. OI that rounds to zero notional needs no rate-limit protection.
            uint256 totalOINotional = Math.mulDiv(totalOISize, currentPrice, BAZAAR_SCALE);
            if (totalOINotional > 0) {
                uint256 currentRatioBp = (vault.insuranceFundBalance * BP_SCALE) / totalOINotional;
                uint256 targetRatioBp = RiskParamsLib.getTargetInsuranceRatio(params.emaVarianceBp, params.emaGapBp);

                // Reset period tracker if period has elapsed
                if (block.timestamp >= rateLimitState.periodStart + INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD) {
                    rateLimitState.withdrawnThisPeriod = 0;
                    rateLimitState.periodStart = block.timestamp;
                    rateLimitState.periodCap = (totalOINotional * INSURANCE_WITHDRAWAL_RATE_LIMIT_BP) / BP_SCALE;
                }

                // A single cumulative period budget governs BOTH regimes, so the limit can't be
                // sidestepped by straddling the target boundary or by splitting withdrawals across
                // Sybil accounts (which share no per-withdrawal budget). Below target the budget is a
                // strict 0.5% of OI (periodCap). Above target it is the MORE PERMISSIVE of 1% of OI or
                // 10% of the fund: the fund term keeps a fund that dwarfs OI from being trapped behind
                // a tiny OI-based cap (e.g. a $1,000 fund on $100 of OI would otherwise cap at $1). The
                // OI term is derived from the snapshotted periodCap; the fund term uses the live fund
                // (it can only shrink within a period, which conservatively tightens the budget).
                uint256 applicableCap;
                if (currentRatioBp < targetRatioBp) {
                    applicableCap = rateLimitState.periodCap; // 0.5% of snapshot OI
                } else {
                    uint256 oiCap = (rateLimitState.periodCap * INSURANCE_WITHDRAWAL_ABOVE_TARGET_RATE_LIMIT_BP)
                        / INSURANCE_WITHDRAWAL_RATE_LIMIT_BP; // 1% of snapshot OI
                    uint256 fundCap =
                        (vault.insuranceFundBalance * INSURANCE_WITHDRAWAL_ABOVE_TARGET_FUND_CAP_BP) / BP_SCALE; // 10% of fund
                    applicableCap = oiCap > fundCap ? oiCap : fundCap;
                }
                if (rateLimitState.withdrawnThisPeriod + withdrawAmount > applicableCap) {
                    revert InsuranceVaultLib__RateLimitExceeded();
                }
                rateLimitState.withdrawnThisPeriod += withdrawAmount;
            }
        }

        // Clear request
        withdrawalRequestTs[caller] = 0;
        withdrawalRequestShareAmount[caller] = 0;

        // Update share tracking
        insuranceShares[caller] -= shareAmount;
        newTotalShares = totalInsuranceShares - shareAmount;
        vault.insuranceFundBalance -= withdrawAmount;
    }
}
