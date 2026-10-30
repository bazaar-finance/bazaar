// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {FeeEscrowLib} from "./FeeEscrowLib.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";

/// @notice The slice of BazaarPairTerminator a redemption consults: the shares a holder has
///         committed to an insurer-termination vote that still locks them, and, on a terminated
///         pair, the share of a yes-voter's redemption the vote's levy forfeits.
interface IInsurerShareLocks {
    function getLockedShares(address pair, address user) external view returns (uint256);
    function consumeInsurerLevy(address user, uint256 shareAmount)
        external
        returns (uint256 levyShares, address recipient);
}

/// @title InsuranceVaultLib
/// @notice External library for insurance vault deposit, withdrawal, and share accounting.
///         Runs via DELEGATECALL — has direct access to BazaarPair storage through passed storage pointers.
library InsuranceVaultLib {
    // -------------------- Constants --------------------

    uint256 internal constant BP_SCALE = BazaarTypes.BP_SCALE;
    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;

    uint256 internal constant MIN_INSURANCE_DEPOSIT = 5 * BAZAAR_SCALE; // $5
    /// @dev A single deposit is bounded to the width of a collateral bucket. The pair pulls
    ///      exactly what it credits, so nothing larger could ever be funded; the bound turns an
    ///      absurd amount into a plain revert before the share and balance arithmetic sees it.
    uint256 internal constant MAX_INSURANCE_DEPOSIT = type(uint128).max;

    // Vote-maturity lot bookkeeping (mirrors the BazaarPairTerminator constants; lives here
    // rather than in BazaarPair for EIP-170 headroom). Lots older than RETENTION can be pruned
    // on deposit: a vote's window opens no earlier than
    // BazaarPairTerminator.INSURER_TERMINATION_MAX_LEAD (14d) before its cutoff and votes close
    // before the cutoff, so every vote still taking votes has windowOpenTs >= now - 14d and its
    // maturity cutoff (windowOpenTs - MATURITY) >= now - 18d — any pruned lot is guaranteed mature
    // for every vote still open.
    uint256 internal constant INSURER_SHARE_MATURITY_PERIOD = 4 days;
    uint256 internal constant INSURER_LOT_RETENTION_PERIOD = INSURER_SHARE_MATURITY_PERIOD + 14 days;
    uint16 internal constant MAX_DEPOSITS_PER_WINDOW = 100;

    /// @notice How long a withdrawal request waits before its execution window opens. The share
    ///         price and the lock-then-claim rule charge a leaver the losses the chain can already
    ///         price; the cooldown covers what it cannot. Capital stays committed through news that
    ///         has not reached the oracle yet, and a deposit placed to catch one realization carries
    ///         the fund's risk long after it. Longer than BazaarFactory.IDENTIFIER_UPGRADE_TIMELOCK, so the
    ///         fund stays through the notice period an approved identifier upgrade gives traders to
    ///         unwind: a request filed at approval ripens only after activation.
    uint256 internal constant INSURANCE_WITHDRAWAL_COOLDOWN = 13 days;
    uint256 internal constant INSURANCE_WITHDRAWAL_WINDOW = 3 days;
    /// @notice How long after a live-pair redemption's lock its paying call opens. The share price
    ///         learns of a position that a move carried past bankruptcy only when a keeper seizes
    ///         it, so a redemption priced at a single moment the LP picks can land in between and
    ///         leave at the pre-loss value. Pricing it at the lower of two moments this far apart
    ///         leaves keepers that long to book such a loss before the second one, and on a pair
    ///         with active keepers a seizure normally follows the revealing price within seconds.
    ///         A price jump stored while the lock waits restarts the same delay (claimOpensAt).
    uint256 internal constant INSURANCE_WITHDRAWAL_CLAIM_DELAY = 5 minutes;
    /// @notice How long after the last stored price that ended a discontinuity (a gap of at least
    ///         RiskParamsLib.REOPEN_GAP_MIN_STALENESS without a store) a paying call opens. Nothing
    ///         can be liquidated while no fresh price exists, so a lock made before a closure spends
    ///         its delay while no loss can be booked. At the reopen every gapped position reprices at
    ///         once, and on a shared venue so does every other pair's, so the liquidations queue.
    uint256 internal constant INSURANCE_WITHDRAWAL_REOPEN_CLAIM_DELAY = 30 minutes;
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
    error InsuranceVaultLib__DepositAboveMaximum(uint256 amount, uint256 maximum);
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
    /// @notice The paying call of a live-pair redemption came before `claimOpensTs`.
    error InsuranceVaultLib__ClaimNotOpen(uint256 claimOpensTs);
    /// @notice A lock made now could only be claimed at `claimOpensTs`, after the request's window
    ///         closes at `windowEndTs`.
    error InsuranceVaultLib__LockTooLate(uint256 claimOpensTs, uint256 windowEndTs);
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
    // `insuranceShares(user)` getter applies this). When a bad-debt cascade wipes what the fund
    // holds outright (its balance plus the ledger's arrears to it) below $1 while shares exist,
    // the next deposit bumps the epoch: pre-drain stakes truly
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
    ///
    ///      Capped at the fund's free capital, like every other payout it draws from. The rest of
    ///      the balance is the collateral seized alongside inventory the vault still holds, and
    ///      that earmark is what settles the inventory: both the opposing-netting affordability
    ///      test and an auction slice's settlement count it as cash the fund has. A reward taken
    ///      out of it would leave the fund short of a settlement those two already committed to,
    ///      and the gap surfaces as `deficit` on the next netting or close — which fixes the
    ///      settlement price and ends the pair, for a payout worth at most the cap. The pair sets
    ///      its once-flag before calling, so a reward the free capital cannot cover is skipped
    ///      rather than deferred: the proposer is paid out of what the pair can spare at the
    ///      moment their proposal settles, or not at all.
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
        uint256 reward = Math.mulDiv(vault.insuranceFundBalance, 10, BP_SCALE); // 10 bps = 0.1%
        uint256 cap = 100 * BAZAAR_SCALE; // $100
        if (reward > cap) reward = cap;
        uint256 free = RiskParamsLib.insuranceFreeCapital(vault);
        if (reward > free) reward = free;
        if (reward == 0) return;

        vault.insuranceFundBalance -= reward;
        FeeEscrowLib.credit(feeEscrow, pairId, proposer, reward);
    }

    // ================================================================
    //                         Deposit Logic
    // ================================================================

    /// @notice Shares a deposit of `amount` mints into a pool of `totalShares` priced at `basis`:
    ///         1:1 into a pool with no live shares or one a realized wipe is about to reset (less
    ///         than $1 held outright), pro-rata otherwise. Zero when the basis is zero, where
    ///         depositToInsurance reverts rather than divide by it.
    /// @dev Pure so a quote can run the same arithmetic without the pair's storage.
    ///      mulDiv: at extreme-but-legitimate supplies the raw amount x totalShares product can
    ///      exceed uint256 even when the fair share count is small.
    /// @param amount Deposit amount in BAZAAR precision
    /// @param totalShares Live share supply before the deposit
    /// @param fund What the fund holds outright before the deposit: its raw balance plus the
    ///        ledger's arrears to it
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
        if (amount > MAX_INSURANCE_DEPOSIT) {
            revert InsuranceVaultLib__DepositAboveMaximum(amount, MAX_INSURANCE_DEPOSIT);
        }
        if (isPairTerminated) revert InsuranceVaultLib__PairTerminated();
        // Limbo begins LIMBO_LEAD before the cutoff (the pair's _pastTradingCutoff rule).
        if (scheduledTerminationTs != 0 && block.timestamp + BazaarTypes.LIMBO_LEAD >= scheduledTerminationTs) {
            revert InsuranceVaultLib__PairScheduledForTermination(scheduledTerminationTs);
        }
        // Refused where a health check at this mark would open an ADL window on the inventory leg:
        // the inventory's loss exceeds free capital above the reserve. The share price leaves that
        // excess out because the auction charges it to winners, closing them at the estates'
        // bankruptcy price; shares minted before the auction would take part of that recovery from
        // the incumbents, and the capital would shrink it or, large enough, keep the window shut
        // and leave the LPs the loss the winners would have paid. The deferred leg (a listed
        // account the fund cannot afford to net, VaultHealthLib.checkLiqExposure) is not tested
        // here, so a deposit can still land just before a window that leg opens. The pair refuses
        // outright while a window is already open.
        if (
            vault.pendingLiqSize != 0
                && RiskParamsLib.lossPastHeadroom(vault, lastPairPrice.spotPrice, currentFundingIndex)
        ) {
            revert InsuranceVaultLib__AdlBlocking();
        }

        newEpoch = epoch;
        // Dead pool: live shares exist but bad debt wiped what the fund holds below $1. Start a new
        // share generation — pre-drain balances lazily read as 0 (their stake truly went
        // to zero) and the supply restarts, so the rescuer below is minted 1:1 against
        // only their own contribution in a single transaction, with no holder enumeration
        // and no multiplicative supply blow-up.
        //
        // Deliberately what the fund holds outright, not the mark-to-market basis the share price
        // uses: this wipes live balances, and it may only do so against debt that has actually
        // been realized. A fund whose every dollar is merely earmarked against open inventory,
        // or whose inventory is merely underwater at today's mark, has lost nothing yet — the
        // inventory can still close whole — so it must block pricing (below) rather than burn
        // stakes. What it holds outright is the raw balance plus the ledger's arrears to it, a
        // receivable that settlement nets and finalize pays into the insurers' residual. A
        // settlement pays its loss out of its own seizure ahead of the arrears
        // (RiskParamsLib.fundLedgerFrom), so the raw balance alone can fall below $1 while the
        // fund's value sits in them.
        if (totalInsuranceShares != 0 && vault.insuranceFundBalance + vault.ledgerArrears < BAZAAR_SCALE) {
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
            // Live pool holding $1 or more outright (dead pools were reset above), so a zero basis
            // is never an empty fund: every dollar is earmarked against inventory the vault holds
            // or owed to the fund as backing for it, or, with no reserve to stop at, the
            // inventory's loss at the mark consumes all of them.
            // The shares still have worth once the inventory unwinds, and pricing a deposit
            // against zero would divide by it.
            revert InsuranceVaultLib__FundCommittedToInventory();
        }
        uint256 shares =
            sharesForDeposit(amount, totalInsuranceShares, vault.insuranceFundBalance + vault.ledgerArrears, basis);
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
        uint256 windowDays = INSURER_SHARE_MATURITY_PERIOD / 1 days; // 4
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

    /// @notice Executes a previously requested insurance withdrawal after cooldown. On a live pair
    ///         it takes two calls inside the request's window: the first locks what the requested
    ///         shares are worth and pays nothing; the second, once claimOpensAt allows, burns them
    ///         and pays the lower of the locked amount and what they are worth then, or, while the
    ///         vault holds inventory, as much of that as the fund's headroom allows, leaving the
    ///         rest requested for a later call in the window. On a terminated pair one call pays at
    ///         once.
    /// @dev Called via DELEGATECALL. Does NOT handle USDC transfer or oracle calls.
    ///      Caller must resolve a fresh price and judge vault health against it before calling, and
    ///      handle the USDC transfer after. Every gate runs on both live calls; only the paying
    ///      call draws on the rate-limit budget, so a lock that is never claimed spends nothing and
    ///      simply lapses with the window, leaving the shares in the pool. While the vault holds
    ///      inventory the paying call pays no more than the fund's headroom, free capital less the
    ///      reserve and the cost of finishing the inventory, valued together at whichever edge of
    ///      the unload band makes their sum larger (RiskParamsLib.redemptionHeadroom), since the
    ///      caller's verdict is judged before the payout and cannot see what the payout itself
    ///      does: a larger claim is paid up to it, the rest of the request stays open under the
    ///      same lock, and a claim the headroom cannot pay any of is refused. On a terminated pair
    ///      the live gates give way to the sweep gate: no redemption while a position finalize did
    ///      not wait for is open, until the grace elapses.
    /// @param insuranceShares Storage mapping of per-user RAW share balances
    /// @param shareEpochOf Storage mapping of the epoch each user's raw balance belongs to
    /// @param epoch Current share epoch
    /// @param totalInsuranceShares Current total shares issued (current epoch)
    /// @param vault Storage reference to the pair vault
    /// @param withdrawalRequestTs Storage mapping of per-user epoch-stamped request slots
    ///        (`epoch << 64 | timestamp`)
    /// @param withdrawalRequestShareAmount Storage mapping of per-user requested share amounts
    /// @param withdrawalLock Storage mapping of per-user redemption locks
    ///        (`lockedAmount << 64 | lockTs`); a lock counts only for the request whose window it
    ///        was made in
    /// @param rateLimitState Storage reference to withdrawal rate-limit state
    /// @param lastPairPrice The pair's stored mark: the price the caller just resolved on a live
    ///        pair, the frozen one on a terminated pair. Values the inventory and the coverage
    ///        ratio; its variance EMA feeds the fund target
    /// @param liquidationGapEma The pair's liquidation-outcome EMAs; its drift leg is one of the
    ///        two estimators the fund target takes the worse of, and its slippage leg reaches
    ///        the target through the stress move
    /// @param reopenGapEma The pair's reopen-gap EMA, a leg of the fund target on
    ///        non-continuously traded pairs; its `lastObsTs` and `lastJumpTs` also hold the paying
    ///        call back after a storage gap or a price jump
    /// @param marginRequirements The pair's stored margin requirements; the headroom derives its
    ///        unload band from their maintenance rate
    /// @param params Withdrawal parameters (pair state flags, the vault-health verdict judged for
    ///        this call, the funding index, the settlement-fix timestamp, the pair id for events)
    /// @param caller The withdrawing user
    /// @return withdrawAmount Amount to transfer to user (BAZAAR precision); 0 on a lock
    /// @return newTotalShares Updated total insurance shares; unchanged on a lock
    function executeInsuranceWithdrawal(
        mapping(address => uint256) storage insuranceShares,
        mapping(address => uint256) storage shareEpochOf,
        uint256 epoch,
        uint256 totalInsuranceShares,
        BazaarTypes.Vault storage vault,
        mapping(address => uint256) storage withdrawalRequestTs,
        mapping(address => uint256) storage withdrawalRequestShareAmount,
        mapping(address => uint256) storage withdrawalLock,
        BazaarTypes.InsuranceWithdrawalRateLimitState storage rateLimitState,
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        BazaarTypes.ReopenGapEma storage reopenGapEma,
        BazaarTypes.MarginRequirements storage marginRequirements,
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
            // Limbo begins LIMBO_LEAD before the cutoff (the pair's _pastTradingCutoff rule).
            if (
                params.scheduledTerminationTs != 0
                    && block.timestamp + BazaarTypes.LIMBO_LEAD >= params.scheduledTerminationTs
            ) {
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
        // Locked (voted) shares back live insurer-termination proposals and cannot be drained
        // until each proposal fails, is preempted, or reaches its cutoff; after the fix of a pair
        // an insurer vote scheduled, the yes-voters' stake stays locked through the cooldown a
        // redemption on the live pair would have served.
        uint256 lockedShares = IInsurerShareLocks(params.umaContract).getLockedShares(address(this), caller);
        if (shareAmount + lockedShares > insuranceShares[caller]) {
            revert InsuranceVaultLib__SharesLockedForVoting();
        }

        // On a terminated pair a yes-voter into the vote that scheduled it may owe the levy: the
        // forfeited share of their voted stake is credited to the recipient the terminator names,
        // the factory's bug bounty address, instead of being paid out. Moving shares rather than
        // cash keeps the price every other redemption sees untouched, whatever order the holders
        // redeem in, and the recipient redeems them like any holder. The rest of the request is an
        // ordinary redemption. A recipient of address(0) is the orphan balance, which nothing can
        // call as, so those shares never leave.
        if (params.isPairTerminated) {
            (uint256 levyShares, address levyRecipient) =
                IInsurerShareLocks(params.umaContract).consumeInsurerLevy(caller, shareAmount);
            if (levyShares != 0) {
                _settle(insuranceShares, shareEpochOf, epoch, levyRecipient);
                insuranceShares[levyRecipient] += levyShares;
                insuranceShares[caller] -= levyShares;
                shareAmount -= levyShares;
            }
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
        // The shares this call redeems: the whole request unless the headroom trims the payout.
        uint256 paidShares = shareAmount;

        if (!params.isPairTerminated) {
            // Forward pricing: the first call inside the window only records this amount, and the
            // second pays the lower of it and the amount then (INSURANCE_WITHDRAWAL_CLAIM_DELAY).
            // A terminated pair's residual is final, so its redemption needs no second moment.
            bool isLock;
            (isLock, withdrawAmount) = _lockOrClaim(
                withdrawalLock, caller, requestTs, reopenGapEma, shareAmount, withdrawAmount, params.pairId
            );
            if (isLock) return (0, totalInsuranceShares);

            // The verdict the caller judged saw the fund before this payout, so while the vault
            // holds inventory the payout is held to the fund's headroom
            // (RiskParamsLib.redemptionHeadroom): free capital less the reserve and the cost of
            // finishing the inventory, valued together at whichever edge of the unload band makes
            // their sum larger. A payout that took part of the reserve would leave an auction batch
            // sized to restore it and keeper rewards capped at the smaller free capital, so winners
            // and keepers would carry what the leaver took. One held only to the reserve and the
            // inventory's loss at the mark would leave the fund exactly where the ADL gate opens,
            // and the refresh bounty, the inventory's funding or the first tick against it would
            // open a window. Held to the headroom, the fund opens none on a move of the mark inside
            // the band that leaves open interest and the fund target where they were; on longs
            // whose reserve and inventory are about the same size, the slack it leaves at the mark
            // itself is small, so the bounty or the inventory's funding can still open one there. A
            // larger claim is paid up to the headroom at its own amount per share, and the shares
            // that payment does not redeem stay requested, under the same lock, for a later call in
            // the window once the inventory has unloaded, the mark has moved back or new capital
            // has come in to leave room. A claim the headroom cannot pay any of is refused. A
            // terminated pair holds no inventory, so nothing is held back there.
            if (vault.pendingLiqSize != 0) {
                uint256 headroom = RiskParamsLib.redemptionHeadroom(
                    vault, lastPairPrice.spotPrice, params.currentFundingIndex, marginRequirements.mmrBp
                );
                if (withdrawAmount > headroom) {
                    paidShares = Math.mulDiv(shareAmount, headroom, withdrawAmount);
                    withdrawAmount = Math.mulDiv(withdrawAmount, paidShares, shareAmount);
                    if (withdrawAmount == 0) revert InsuranceVaultLib__AdlBlocking();
                }
            }

            // Only the paying call is rate-limited, on what it pays.
            _enforceRateLimit(
                rateLimitState, vault, lastPairPrice, liquidationGapEma, reopenGapEma, params, withdrawAmount
            );
        }

        if (paidShares == shareAmount) {
            // Clear the request and its lock. A terminated pair's redemption pays in one call, so
            // it can find a lock made before the pair finalized; the lock has no bearing on that
            // payout.
            withdrawalRequestTs[caller] = 0;
            withdrawalRequestShareAmount[caller] = 0;
            withdrawalLock[caller] = 0;
        } else {
            // The rest of the request keeps its window and its lock, scaled to the shares left so
            // they stay locked at the amount per share the lock recorded.
            uint256 restShares = shareAmount - paidShares;
            withdrawalRequestShareAmount[caller] = restShares;
            uint256 lock = withdrawalLock[caller];
            withdrawalLock[caller] = (Math.mulDiv(lock >> 64, restShares, shareAmount) << 64) | uint64(lock);
        }

        // Update share tracking
        insuranceShares[caller] -= paidShares;
        newTotalShares = totalInsuranceShares - paidShares;
        vault.insuranceFundBalance -= withdrawAmount;
        emit BazaarTypes.InsuranceWithdrawalExecuted(params.pairId, caller, paidShares, withdrawAmount);
    }

    /// @dev The forward-pricing step of a live-pair redemption. Without a lock from the current
    ///      request's window, records one at `amountNow` and reports it as a lock; otherwise
    ///      requires the claim to be open and returns the lower of the locked amount and
    ///      `amountNow`.
    ///
    ///      A lock counts only if it was made once the request's window had opened. Filing a new
    ///      request moves that opening, a cooldown after the request, past every earlier lock, so
    ///      a new request always starts unlocked and a lock left in an expired window can never be
    ///      claimed under a later one.
    /// @param withdrawalLock Storage mapping of per-user redemption locks
    ///        (`lockedAmount << 64 | lockTs`)
    /// @param caller The redeeming user
    /// @param requestTs The request's timestamp (low 64 bits of its epoch-stamped slot)
    /// @param reopenGapEma The pair's discontinuity record: the last storage gap and price jump
    /// @param shareAmount The requested shares, reported by the lock event
    /// @param amountNow What the requested shares are worth in this call
    /// @param pairId The pair id carried by the lock event
    /// @return isLock Whether this call recorded the lock, in which case it pays nothing
    /// @return amount What this call pays when it is the claim
    function _lockOrClaim(
        mapping(address => uint256) storage withdrawalLock,
        address caller,
        uint256 requestTs,
        BazaarTypes.ReopenGapEma storage reopenGapEma,
        uint256 shareAmount,
        uint256 amountNow,
        bytes32 pairId
    ) private returns (bool isLock, uint256 amount) {
        uint256 windowOpensTs = requestTs + INSURANCE_WITHDRAWAL_COOLDOWN;
        uint256 lock = withdrawalLock[caller];
        uint256 lockTs = uint256(uint64(lock));
        uint256 lastGapTs = reopenGapEma.lastObsTs;
        uint256 lastJumpTs = reopenGapEma.lastJumpTs;
        if (lockTs < windowOpensTs) {
            uint256 opensTs = claimOpensAt(block.timestamp, lastGapTs, lastJumpTs);
            uint256 windowEndTs = windowOpensTs + INSURANCE_WITHDRAWAL_WINDOW;
            // A lock whose claim could only open after the window closes would just lapse with
            // it, so it is refused with the reason instead of being recorded.
            if (opensTs > windowEndTs) revert InsuranceVaultLib__LockTooLate(opensTs, windowEndTs);
            withdrawalLock[caller] = (uint256(SafeCast.toUint192(amountNow)) << 64) | block.timestamp;
            emit BazaarTypes.InsuranceWithdrawalLocked(pairId, caller, shareAmount, amountNow, opensTs);
            return (true, 0);
        }
        uint256 claimTs = claimOpensAt(lockTs, lastGapTs, lastJumpTs);
        if (block.timestamp < claimTs) revert InsuranceVaultLib__ClaimNotOpen(claimTs);
        uint256 lockedAmount = lock >> 64;
        amount = lockedAmount < amountNow ? lockedAmount : amountNow;
    }

    // ================================================================
    //                        Redemption Timing
    // ================================================================

    /// @notice When the paying call of a redemption locked at `lockTs` opens: a claim delay after
    ///         the lock and after the last price jump, and a reopen delay after the last stored
    ///         price that ended a storage gap, whichever is latest. Shared by
    ///         executeInsuranceWithdrawal and BazaarPairLens, so the opening a frontend is shown is
    ///         the one execution enforces.
    /// @dev The lock's delay covers losses already caused when it ran. The two discontinuity legs
    ///      cover those caused while it waits, read at the time of each call: a closure or a jump
    ///      after the lock pushes the opening back, since a loss behind either may not be booked
    ///      yet. The paying call's own price store counts too, so a claim can never be the store
    ///      that ends a gap or carries a jump: that store has to have landed in an earlier call, a
    ///      full delay before the claim.
    /// @param lockTs When the redemption was locked
    /// @param lastGapTs `ReopenGapEma.lastObsTs`: publish time of the last stored price that ended
    ///        a gap of at least RiskParamsLib.REOPEN_GAP_MIN_STALENESS (0 if none yet)
    /// @param lastJumpTs `ReopenGapEma.lastJumpTs`: publish time of the last stored price at least
    ///        RiskParamsLib.MIN_STRESS_MOVE_BP from the variance sample (0 if none yet)
    /// @return opensTs The first timestamp at which the paying call is accepted
    function claimOpensAt(uint256 lockTs, uint256 lastGapTs, uint256 lastJumpTs)
        internal
        pure
        returns (uint256 opensTs)
    {
        opensTs = (lockTs > lastJumpTs ? lockTs : lastJumpTs) + INSURANCE_WITHDRAWAL_CLAIM_DELAY;
        uint256 afterGap = lastGapTs + INSURANCE_WITHDRAWAL_REOPEN_CLAIM_DELAY;
        if (afterGap > opensTs) opensTs = afterGap;
    }

    /// @dev Charges a paying call to the period budget (withdrawalCapOf) and refuses it past the
    ///      budget. One source for the coverage reading, shared with the fee and margin curves: a
    ///      second copy of the formula here would drift from them silently. The floored notional
    ///      is what gates the limit, not the raw operands — dust OI at an extreme low price can
    ///      floor the product to 0, and dividing by it would brick the withdrawal. OI that rounds
    ///      to zero notional needs no rate-limit protection.
    ///
    ///      The period's OI snapshot is an instant's reading, and open interest counts matched
    ///      positions of one owner, so the held term bounds it by the open interest the pair has
    ///      carried for the whole trailing day, read at this call rather than at the snapshot:
    ///      matched positions opened for the call that rolls the period and closed before the one
    ///      that spends it widen nothing. The coverage ratio keeps reading live open interest:
    ///      inflating it can only push the fund below target, into the stricter regime.
    /// @param rateLimitState Storage reference to withdrawal rate-limit state
    /// @param vault Storage reference to the pair vault
    /// @param lastPairPrice The pair's stored mark, which the caller resolved fresh
    /// @param liquidationGapEma The pair's liquidation-outcome EMAs, a leg of the fund target
    /// @param reopenGapEma The pair's reopen-gap EMA, a leg of the fund target on
    ///        non-continuously traded pairs
    /// @param params Withdrawal parameters (the funding index and the trading-hours flag are read)
    /// @param withdrawAmount What the paying call pays (BAZAAR precision)
    function _enforceRateLimit(
        BazaarTypes.InsuranceWithdrawalRateLimitState storage rateLimitState,
        BazaarTypes.Vault storage vault,
        BazaarTypes.PairPrice storage lastPairPrice,
        BazaarTypes.LiquidationGapEma storage liquidationGapEma,
        BazaarTypes.ReopenGapEma storage reopenGapEma,
        BazaarTypes.InsuranceWithdrawParams memory params,
        uint256 withdrawAmount
    ) private {
        (uint256 currentRatioBp,, uint256 totalOINotional) =
            RiskParamsLib.getInsuranceFundToOIRatio(vault, lastPairPrice.spotPrice, params.currentFundingIndex);
        if (totalOINotional == 0) return;
        (int256 slippageBp, int256 driftBp) = RiskParamsLib.fadedLiquidationGapsBp(liquidationGapEma, lastPairPrice);
        uint256 targetRatioBp = RiskParamsLib.getTargetInsuranceRatio(
            RiskParamsLib.stressMoveBp(
                lastPairPrice.emaVarianceBp, slippageBp, reopenGapEma.gapEmaBp, params.isContinuouslyTraded
            ),
            driftBp
        );

        // Reset period tracker if period has elapsed
        if (block.timestamp >= rateLimitState.periodStart + INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD) {
            rateLimitState.withdrawnThisPeriod = 0;
            rateLimitState.periodStart = block.timestamp;
            rateLimitState.periodCap = (totalOINotional * INSURANCE_WITHDRAWAL_RATE_LIMIT_BP) / BP_SCALE;
        }

        // One cumulative period budget governs both regimes (withdrawalCapOf).
        uint256 heldCap =
            heldOiTermOf(RiskParamsLib.openInterestSize(vault), vault.trailingOiSize, lastPairPrice.spotPrice);
        uint256 applicableCap = withdrawalCapOf(
            rateLimitState.periodCap, heldCap, vault.insuranceFundBalance, currentRatioBp < targetRatioBp
        );
        if (rateLimitState.withdrawnThisPeriod + withdrawAmount > applicableCap) {
            revert InsuranceVaultLib__RateLimitExceeded();
        }
        rateLimitState.withdrawnThisPeriod += withdrawAmount;
    }

    // ================================================================
    //                    Withdrawal Rate-Limit Arithmetic
    // ================================================================

    /// @notice The cumulative period budget an insurance withdrawal is checked against. Shared by
    ///         executeInsuranceWithdrawal and BazaarPairLens, so the budget a frontend is shown is
    ///         the one execution enforces.
    /// @dev A single cumulative budget governs BOTH regimes, so the limit can't be sidestepped by
    ///      straddling the target boundary or by splitting withdrawals across Sybil accounts
    ///      (which share no per-withdrawal budget).
    ///
    ///      Below target the budget is the STRICTER of 0.5% of OI or 5% of the fund. The OI term
    ///      alone would not do: it is denominated in what the fund protects, not in the fund, so
    ///      as the fund depletes it becomes an ever larger share of what remains and stops binding
    ///      once the fund is under 0.5% of OI, the very regime the limit exists for. The fund term
    ///      bounds each period's outflow to a fraction of what is left.
    ///
    ///      Above target it is the MORE PERMISSIVE of 1% of OI or 10% of the fund: there the fund
    ///      term is a floor that keeps a fund dwarfing OI from being trapped behind a tiny OI-based
    ///      cap (a $1,000 fund on $100 of OI would otherwise cap at $1).
    ///
    ///      The OI term is the snapshotted periodCap, and above target no more than `heldCap`, the
    ///      same rate on the open interest held for the whole trailing day (heldOiTermOf). The
    ///      snapshot is an instant's reading of a figure that counts matched positions of one
    ///      owner, so on its own it could be set by positions opened for the withdrawal that rolls
    ///      the period and closed before the paying call that spends it; above target the OI term
    ///      is the permissive one, so the budget would follow it. Open interest widens the budget
    ///      only once held for a day, which is also when the fund's reserve admits it. Below target
    ///      the snapshot stands alone: the fund term already caps the budget at 5% of the fund
    ///      whatever open interest reads, and the held figure is one unit of size for a day after
    ///      a flat stretch, which would hold a thin fund's exits at nothing there. Both fund terms
    ///      read the live fund, so withdrawals earlier in the period shrink the ceiling and only
    ///      inflows widen it.
    /// @param periodCap The period's OI snapshot term: INSURANCE_WITHDRAWAL_RATE_LIMIT_BP of OI
    ///        notional when the period opened
    /// @param heldCap The held OI term: INSURANCE_WITHDRAWAL_RATE_LIMIT_BP of the notional of the
    ///        open interest held for the whole trailing day, at the paying call (heldOiTermOf)
    /// @param fundBalance The live insurance fund balance
    /// @param belowTarget Whether the fund's coverage ratio is below its target ratio
    /// @return The period budget, cumulative across every withdrawal in the period
    function withdrawalCapOf(uint256 periodCap, uint256 heldCap, uint256 fundBalance, bool belowTarget)
        internal
        pure
        returns (uint256)
    {
        if (belowTarget) {
            uint256 fundCeiling = (fundBalance * INSURANCE_WITHDRAWAL_BELOW_TARGET_FUND_CAP_BP) / BP_SCALE;
            return periodCap < fundCeiling ? periodCap : fundCeiling;
        }
        uint256 oiTerm = heldCap < periodCap ? heldCap : periodCap;
        uint256 oiCap = (oiTerm * INSURANCE_WITHDRAWAL_ABOVE_TARGET_RATE_LIMIT_BP) / INSURANCE_WITHDRAWAL_RATE_LIMIT_BP;
        uint256 fundCap = (fundBalance * INSURANCE_WITHDRAWAL_ABOVE_TARGET_FUND_CAP_BP) / BP_SCALE;
        return oiCap > fundCap ? oiCap : fundCap;
    }

    /// @notice The held OI term of the period budget: INSURANCE_WITHDRAWAL_RATE_LIMIT_BP of the
    ///         notional, at `price`, of the open interest the pair has held for the whole trailing
    ///         day — the lower of live per-side open interest and its trailing minimum, the figure
    ///         the fund's reserve is sized on (RiskParamsLib.reserveOiSizeOf), or live open
    ///         interest alone while no sampled interval is a full MMR_GRACE_PERIOD old.
    /// @dev The trailing minimum is the cache a margin refresh keeps (Vault.trailingOiSize). Between
    ///      refreshes it can sit below the true minimum and never above it, so a stale cache only
    ///      tightens the budget.
    /// @param liveOiSize Live per-side open interest (RiskParamsLib.openInterestSize)
    /// @param trailingOiSize The cached trailing minimum; 0 when there is none
    /// @param price The mark the notional is valued at (BAZAAR_SCALE)
    /// @return The held OI term, in BAZAAR_SCALE precision
    function heldOiTermOf(uint256 liveOiSize, uint256 trailingOiSize, uint256 price) internal pure returns (uint256) {
        uint256 heldNotional =
            Math.mulDiv(RiskParamsLib.reserveOiSizeOf(liveOiSize, trailingOiSize), price, BAZAAR_SCALE);
        return (heldNotional * INSURANCE_WITHDRAWAL_RATE_LIMIT_BP) / BP_SCALE;
    }
}
