// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";

/// @notice The slice of BazaarPairTerminator a redemption consults: the shares a holder has
///         committed to an active insurer-termination vote.
interface IInsurerShareLocks {
    function getLockedShares(address pair, address user) external view returns (uint256);
}

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
    uint256 internal constant INSURANCE_WITHDRAWAL_BELOW_TARGET_FUND_CAP_BP = 500; // 5% of fund per period (below-target ceiling, so a thin fund can't be emptied in one period)
    // Sweep gate on a terminated pair: after an escape-hatch finalize, redemptions wait for every
    // position to be settled or for the grace to elapse, both measured from the settlement fix.
    uint256 internal constant TERMINAL_SETTLEMENT_ESCAPE = BazaarTypes.TERMINAL_SETTLEMENT_ESCAPE;
    uint256 internal constant INSURER_SWEEP_GRACE = BazaarTypes.INSURER_SWEEP_GRACE;

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
    /// @notice Finalize ran through its escape hatch and a position it did not wait for is still
    ///         open; the redemption is released when every such position is settled, or at
    ///         `releaseTs` regardless.
    error InsuranceVaultLib__SweepIncomplete(uint256 releaseTs);
    /// @notice The vault-health verdict judged for this redemption is unhealthy for a reason other
    ///         than liquidation exposure; the caller's settlement-window freeze catches these first.
    error InsuranceVaultLib__VaultUnhealthy(uint8 reason);
    error InsuranceVaultLib__CooldownNotElapsed();
    error InsuranceVaultLib__WithdrawalWindowExpired();
    error InsuranceVaultLib__RateLimitExceeded();
    error InsuranceVaultLib__SharesLockedForVoting();
    error InsuranceVaultLib__TooManyRecentInsuranceDeposits(uint256 windowCount, uint16 cap);
    /// @notice Every dollar in the fund is earmarked against inventory the vault still holds,
    ///         so shares have no value to price against until that inventory unwinds.
    error InsuranceVaultLib__FundCommittedToInventory();

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

    /// @notice One-time-per-pair reward to the UMA termination proposer: 0.1% (10 bps) of the
    ///         insurance fund, capped at $100, accrued to the proposer's claimable balance
    ///         (BazaarPair.claimFees pays it out).
    /// @dev Lives here (DELEGATECALL) so the pair's EIP-170 budget stays free of the math; the
    ///      once-flag stays in the pair. Runs inside the terminator's UMA settlement callback,
    ///      so it must never revert — the escrow credit is pure storage, with no token call for
    ///      a proposer's address to break.
    /// @param vault The pair vault (insurance fund source)
    /// @param feeEscrow The pair's fee escrow, credited with the reward
    /// @param pairId The pair id carried by the accrual event
    /// @param proposer The UMA asserter whose accepted proposal scheduled the termination
    function payUmaProposerReward(
        BazaarTypes.Vault storage vault,
        BazaarTypes.FeeEscrow storage feeEscrow,
        bytes32 pairId,
        address proposer
    ) external {
        uint256 reward = (vault.insuranceFundBalance * 10) / BP_SCALE; // 10 bps = 0.1%
        uint256 cap = 100 * BAZAAR_SCALE; // $100
        if (reward > cap) reward = cap;
        if (reward == 0) return;

        vault.insuranceFundBalance -= reward;
        FeeEscrowLib.credit(feeEscrow, pairId, proposer, reward);
    }

    // ================================================================
    //                         Deposit Logic
    // ================================================================

    /// @notice Shares a deposit of `amount` mints into a pool of `totalShares` priced at `basis`:
    ///         1:1 into a pool with no live shares or one a realized wipe is about to reset (fund
    ///         below $1), pro-rata otherwise. Zero when the basis is zero, where
    ///         depositToInsurance reverts rather than divide by it.
    /// @dev Pure so a quote can run the same arithmetic without the pair's storage.
    ///      mulDiv: at extreme-but-legitimate supplies the raw amount x totalShares product can
    ///      exceed uint256 even when the fair share count is small.
    /// @param amount Deposit amount in BAZAAR precision
    /// @param totalShares Live share supply before the deposit
    /// @param fund The raw insurance fund balance before the deposit
    /// @param basis The deposit basis (RiskParamsLib.insuranceDepositBasis)
    /// @return Shares the deposit mints
    function sharesForDeposit(uint256 amount, uint256 totalShares, uint256 fund, uint256 basis)
        internal
        pure
        returns (uint256)
    {
        if (totalShares == 0 || fund < BAZAAR_SCALE) return amount;
        if (basis == 0) return 0;
        return Math.mulDiv(amount, totalShares, basis);
    }

    /// @notice Processes insurance deposit: validates, calculates shares, updates state.
    /// @dev Called via DELEGATECALL from BazaarPair. Does NOT handle USDC transfer or the price
    ///      resolution: while the vault holds inventory the caller resolves a FRESH price first and
    ///      refuses the frozen fallback of a closed venue, so the mark read here is one the oracle
    ///      just confirmed. With no inventory held the mark is not read.
    /// @param insuranceShares Storage mapping of per-user RAW share balances
    /// @param shareEpochOf Storage mapping of the epoch each user's raw balance belongs to
    /// @param epoch Current share epoch
    /// @param insuranceDepositLots Storage mapping of per-user vote-maturity lots
    /// @param insuranceLotsHead Storage mapping of per-user lot-list heads (prune cursor)
    /// @param insuranceDepositsPerDay Storage mapping backing the per-user deposit rate limit
    /// @param totalInsuranceShares Current total shares issued (current epoch)
    /// @param vault Storage reference to the pair vault
    /// @param lastPairPrice The pair's stored mark, which the vault's inventory is valued at
    /// @param amount Deposit amount in BAZAAR precision
    /// @param isPairTerminated Whether the pair has finalized termination
    /// @param scheduledTerminationTs Scheduled termination timestamp (0 if none)
    /// @param currentFundingIndex The pair's live cumulative funding index, for valuing the
    ///        vault's inherited inventory
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
        BazaarTypes.PairPrice storage lastPairPrice,
        uint256 amount,
        bool isPairTerminated,
        uint256 scheduledTerminationTs,
        int256 currentFundingIndex,
        address caller
    ) external returns (uint256 sharesIssued, uint256 newTotalShares, uint256 newEpoch) {
        if (amount == 0) revert InsuranceVaultLib__ZeroDeposit();
        if (amount < MIN_INSURANCE_DEPOSIT) {
            revert InsuranceVaultLib__DepositBelowMinimum(amount, MIN_INSURANCE_DEPOSIT);
        }
        if (isPairTerminated) revert InsuranceVaultLib__PairTerminated();
        if (scheduledTerminationTs != 0 && block.timestamp >= scheduledTerminationTs) {
            revert InsuranceVaultLib__PairScheduledForTermination(scheduledTerminationTs);
        }

        newEpoch = epoch;
        // Dead pool: live shares exist but bad debt wiped the fund below $1. Start a new
        // share generation — pre-drain balances lazily read as 0 (their stake truly went
        // to zero) and the supply restarts, so the rescuer below is minted 1:1 against
        // only their own contribution in a single transaction, with no holder enumeration
        // and no multiplicative supply blow-up.
        //
        // Deliberately the RAW balance, not the mark-to-market basis the share price uses: this
        // wipes live balances, and it may only do so against debt that has actually been
        // realized. A fund whose every dollar is merely earmarked against open inventory, or
        // whose inventory is merely underwater at today's mark, has lost nothing yet — the
        // inventory can still close whole — so it must block pricing (below) rather than burn
        // stakes.
        if (totalInsuranceShares != 0 && vault.insuranceFundBalance < BAZAAR_SCALE) {
            unchecked {
                newEpoch = epoch + 1;
            }
            totalInsuranceShares = 0;
            emit InsuranceShareEpochBumped(newEpoch);
        }

        // The fund's value at the mark, which every share of this deposit is priced against: free
        // capital plus the inventory's unrealized gain, or less the part of its loss the fund
        // itself will bear. The rule and its reasons are in RiskParamsLib's insurance share
        // pricing section.
        uint256 basis = RiskParamsLib.insuranceDepositBasis(vault, lastPairPrice.spotPrice, currentFundingIndex);

        if (totalInsuranceShares == 0) {
            // Orphaned-balance guard: value sitting in the fund while no (live) shares
            // exist — fees/seized collateral accrued after every LP exited, or sub-$1 dust
            // surviving an epoch reset. Price it into permanently locked shares at
            // address(0) — nothing can call as address(0), so the orphan stays in the fund
            // as buffer forever and the depositor is priced only against their own
            // contribution. Without this, the first depositor's shares would own 100% of
            // the pre-existing fund for the price of `amount`. The orphan is the fund's value
            // at the mark, so the locked shares also own whatever the inventory is about to
            // realize; minting 1:1 against it keeps the share price at exactly 1.
            if (basis > 0) {
                _settle(insuranceShares, shareEpochOf, newEpoch, address(0));
                insuranceShares[address(0)] += basis;
                totalInsuranceShares = basis;
            }
        } else if (basis == 0) {
            // Live pool with fund >= $1 (dead pools were reset above), so a zero basis is never
            // an empty fund: every dollar is earmarked against inventory the vault holds, or,
            // with no reserve to stop at, the inventory's loss at the mark consumes all of them.
            // The shares still have worth once the inventory unwinds, and pricing a deposit
            // against zero would divide by it.
            revert InsuranceVaultLib__FundCommittedToInventory();
        }
        uint256 shares = sharesForDeposit(amount, totalInsuranceShares, vault.insuranceFundBalance, basis);
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
    ///      Caller must resolve a fresh price and judge vault health against it before calling,
    ///      and handle the USDC transfer after. On a terminated pair the live gates give way to
    ///      the sweep gate: no redemption while a position finalize did not wait for is open,
    ///      until the grace elapses.
    /// @param insuranceShares Storage mapping of per-user RAW share balances
    /// @param shareEpochOf Storage mapping of the epoch each user's raw balance belongs to
    /// @param epoch Current share epoch
    /// @param totalInsuranceShares Current total shares issued (current epoch)
    /// @param vault Storage reference to the pair vault
    /// @param withdrawalRequestTs Storage mapping of per-user epoch-stamped request slots
    ///        (`epoch << 64 | timestamp`)
    /// @param withdrawalRequestShareAmount Storage mapping of per-user requested share amounts
    /// @param rateLimitState Storage reference to withdrawal rate-limit state
    /// @param lastPairPrice The pair's stored mark: the price the caller just resolved on a live
    ///        pair, the frozen one on a terminated pair. Values the inventory and the coverage
    ///        ratio; its variance EMA feeds the fund target
    /// @param liquidationGapEma The pair's liquidation-gap EMA, a leg of the fund target
    /// @param reopenGapEma The pair's reopen-gap EMA, a leg of the fund target on
    ///        non-continuously traded pairs
    /// @param params Withdrawal parameters (pair state flags, the vault-health verdict judged for
    ///        this call, the funding index, the settlement-fix timestamp)
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
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        BazaarTypes.ReopenGapEma storage reopenGapEma,
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
        // Active-pair gates: block during the "scheduled but not yet executed" limbo and while
        // the vault is unhealthy, enforce cooldown + window. Terminated pairs bypass all of
        // these (the scheduledTerminationTs check would otherwise revert forever after
        // termination because the field is never cleared) and answer to the sweep gate in the
        // else-branch instead.
        if (!params.isPairTerminated) {
            if (params.scheduledTerminationTs != 0 && block.timestamp >= params.scheduledTerminationTs) {
                revert InsuranceVaultLib__PairScheduledForTermination(params.scheduledTerminationTs);
            }
            // Reason 1 = liquidation exposure exceeds insurance. The verdict is judged by the
            // caller in this transaction, against the price it just resolved, rather than read
            // from the ADL latch. The latch is set only by health checks, and every other entry
            // point runs one only after real activity — a fill, a liquidation, an unload, a
            // collateral withdrawal against exposure. On a book too thin to produce any it sits
            // at zero while the vault's inherited inventory drifts into a loss the fund is about
            // to absorb, and a redemption priced without that loss hands the exiting LP value
            // the remaining ones then eat. Gating on the verdict also keeps the check independent
            // of whether the latch write survives: this revert rolls it back, and the next
            // redemption judges afresh.
            if (params.vaultHealthReason == 1) revert InsuranceVaultLib__AdlBlocking();
            // Every other unhealthy verdict fixed the settlement price inside that same health
            // call, and the caller's freeze check catches it before reaching here. The backstop
            // keeps a future health path from letting a redemption through anyway.
            if (params.vaultHealthReason != 0) {
                revert InsuranceVaultLib__VaultUnhealthy(params.vaultHealthReason);
            }
            if (block.timestamp < requestTs + INSURANCE_WITHDRAWAL_COOLDOWN) {
                revert InsuranceVaultLib__CooldownNotElapsed();
            }
            if (block.timestamp > requestTs + INSURANCE_WITHDRAWAL_COOLDOWN + INSURANCE_WITHDRAWAL_WINDOW) {
                revert InsuranceVaultLib__WithdrawalWindowExpired();
            }
        } else if (vault.totalLongOI != 0 || vault.totalShortOI != 0) {
            // Finalize ran through its escape hatch with positions still open. Each of them was
            // counted inside the total owed to traders at collateral + PnL, so a bankrupt one
            // understates bad debt by its shortfall, and the residual these shares price against
            // is overstated by the same amount until it is settled. A redemption priced before
            // that would hand the exiting LP the shortfall and leave the last trader withdrawals
            // short. Settling is permissionless, reads no oracle, moves no USDC and cannot revert
            // for a position that exists, so an LP can release this gate themselves; the grace
            // bounds only the case where nobody does. Measured from the fix, where settlement
            // first became possible, so it needs no record of when finalize ran.
            uint256 releaseTs = params.settlementPriceFixedTs + TERMINAL_SETTLEMENT_ESCAPE + INSURER_SWEEP_GRACE;
            if (block.timestamp < releaseTs) revert InsuranceVaultLib__SweepIncomplete(releaseTs);
        }

        uint256 shareAmount = withdrawalRequestShareAmount[caller];
        if (shareAmount > insuranceShares[caller]) revert InsuranceVaultLib__ExceedsShares();
        // Locked (voted) shares are reserved for an active insurer-termination proposal
        // and cannot be drained until the proposal resolves or its window expires.
        uint256 lockedShares = IInsurerShareLocks(params.umaContract).getLockedShares(address(this), caller);
        if (shareAmount + lockedShares > insuranceShares[caller]) {
            revert InsuranceVaultLib__SharesLockedForVoting();
        }

        // Shares are valued against the fund's value at the mark the caller resolved: free
        // capital (the fund less the collateral seized alongside inventory the vault still holds,
        // which leaves again when that inventory unloads) less the inventory's unrealized loss as
        // far as the fund itself will bear it — and never more than free capital, so no
        // unrealized gain is paid out. The rule and its reasons are in RiskParamsLib's insurance
        // share pricing section. Because every share prices off the same reduced figure, draining
        // the entire supply still leaves the seizure and the priced-in loss in the fund — a
        // separate ceiling on the payout would be redundant. The mark can only lower the figure
        // from free capital, so the leaver's choice of moment inside the window can recover at
        // most what free capital would have paid, never more.
        // mulDiv's 512-bit intermediate keeps shareAmount x basis from overflowing at
        // recap-inflated share magnitudes (supplies inflated by repeated drain-and-recap cycles).
        // An empty fund is not the same as a committed one: a terminal sweep can write the
        // insurers' claim down to nothing, and that junior claim must settle for zero rather
        // than become unredeemable. Only a fund that still holds value none of which the basis
        // can price blocks — there the shares do have worth and paying zero for them would
        // confiscate it. On a terminated pair the inventory is retired, so the basis is free
        // capital and the frozen mark passed in is not read.
        uint256 basis =
            RiskParamsLib.insuranceRedemptionBasis(vault, lastPairPrice.spotPrice, params.currentFundingIndex);
        if (basis == 0 && vault.insuranceFundBalance != 0) {
            revert InsuranceVaultLib__FundCommittedToInventory();
        }
        withdrawAmount = Math.mulDiv(shareAmount, basis, totalInsuranceShares);

        // Rate-limit withdrawals when pair is active
        if (!params.isPairTerminated) {
            // One source for the coverage reading, shared with the fee and margin curves: a
            // second copy of the formula here would drift from them silently. The floored
            // notional is what gates the limit, not the raw operands — dust OI at an extreme
            // low price can floor the product to 0, and dividing by it below would brick the
            // withdrawal. OI that rounds to zero notional needs no rate-limit protection.
            (uint256 currentRatioBp,, uint256 totalOINotional) =
                RiskParamsLib.getInsuranceFundToOIRatio(vault, lastPairPrice.spotPrice, params.currentFundingIndex);
            if (totalOINotional > 0) {
                uint256 targetRatioBp = RiskParamsLib.getTargetInsuranceRatio(
                    RiskParamsLib.stressMoveBp(
                        lastPairPrice.emaVarianceBp,
                        liquidationGapEma.emaGapBp,
                        reopenGapEma.gapEmaBp,
                        params.isContinuouslyTraded
                    )
                );

                // Reset period tracker if period has elapsed
                if (block.timestamp >= rateLimitState.periodStart + INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD) {
                    rateLimitState.withdrawnThisPeriod = 0;
                    rateLimitState.periodStart = block.timestamp;
                    rateLimitState.periodCap = (totalOINotional * INSURANCE_WITHDRAWAL_RATE_LIMIT_BP) / BP_SCALE;
                }

                // A single cumulative period budget governs BOTH regimes, so the limit can't be
                // sidestepped by straddling the target boundary or by splitting withdrawals across
                // Sybil accounts (which share no per-withdrawal budget). Below target the budget is
                // the STRICTER of 0.5% of OI or 5% of the fund. The OI term alone would not do: it is
                // denominated in what the fund protects, not in the fund, so as the fund depletes it
                // becomes an ever larger share of what remains and stops binding once the fund is
                // under 0.5% of OI, the very regime the limit exists for. The fund term bounds each
                // period's outflow to a fraction of what is left. Above target it is the MORE
                // PERMISSIVE of 1% of OI or 10% of the fund: there the fund term is a floor that keeps
                // a fund dwarfing OI from being trapped behind a tiny OI-based cap (a $1,000 fund on
                // $100 of OI would otherwise cap at $1). The OI terms derive from the snapshotted
                // periodCap; both fund terms read the live fund, so withdrawals earlier in the period
                // shrink the ceiling and only inflows widen it.
                uint256 applicableCap;
                if (currentRatioBp < targetRatioBp) {
                    uint256 oiCap = rateLimitState.periodCap; // 0.5% of snapshot OI
                    uint256 fundCeiling =
                        (vault.insuranceFundBalance * INSURANCE_WITHDRAWAL_BELOW_TARGET_FUND_CAP_BP) / BP_SCALE; // 5% of fund
                    applicableCap = oiCap < fundCeiling ? oiCap : fundCeiling;
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
