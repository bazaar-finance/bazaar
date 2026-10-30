// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./libraries/BazaarTypes.sol";
import {BucketLib} from "./libraries/BucketLib.sol";
import {MetaTxLib} from "./libraries/MetaTxLib.sol";
import {CollateralLib} from "./libraries/CollateralLib.sol";
import {FundingLib} from "./libraries/FundingLib.sol";
import {InsuranceVaultLib} from "./libraries/InsuranceVaultLib.sol";
import {RiskParamsLib} from "./libraries/RiskParamsLib.sol";
import {VaultHealthLib} from "./libraries/VaultHealthLib.sol";
import {AdlLib} from "./libraries/AdlLib.sol";
import {IArbSys} from "./interfaces/IArbSys.sol";

/// @title IBazaarPairLens
/// @notice Minimal interface for reading BazaarPair state
interface IBazaarPairLens {
    // Return types mirror BazaarTypes.PositionBucket's packed field widths — the auto-generated
    // getter reports each field at its declared width.
    function positionBuckets(address user)
        external
        view
        returns (
            bool isLong,
            uint128 size,
            uint128 entryValue,
            uint128 collateral,
            int256 entryFundingIndex,
            uint64 takeProfitOrderId,
            uint64 stopLossOrderId
        );
    function currentFundingIndex() external view returns (int256);
    function extsload(bytes32 slot) external view returns (bytes32);
    function isPairTerminated() external view returns (bool);
    function scheduledTerminationTs() external view returns (uint256);
    function usdc() external view returns (address);
    function lastPairPrice()
        external
        view
        returns (uint256 spotPrice, uint256 emaVarianceBp, uint256 updateTs, uint256 lowPrice, uint256 highPrice);
    function marginRequirements()
        external
        view
        returns (uint256 imrBp, uint256 mmrBp, uint256 lastUpdateTs, uint256 laggedMmrBp);
    function getLaggedMmr() external view returns (uint256 mmrBp);
    function isContinuouslyTraded() external view returns (bool);
    function pairId() external view returns (bytes32);
    function insuranceShares(address user) external view returns (uint256);
    function insuranceWithdrawalRequestTs(address user) external view returns (uint256);
    function totalInsuranceShares() external view returns (uint256);
    function pairVault()
        external
        view
        returns (
            uint256 totalLongOI,
            uint256 totalShortOI,
            uint256 longWeightedEntrySum,
            uint256 shortWeightedEntrySum,
            uint256 totalCollateralDeposited,
            uint256 insuranceFundBalance,
            uint256 pendingLiqSize,
            uint256 pendingLiqEntryNotional,
            uint256 pendingLiqBankruptcyNotional,
            int256 pendingLiqEntryFundingIndex,
            bool pendingLiqIsLong,
            uint256 deficit,
            uint256 targetInsuranceRatioBp,
            uint256 pendingLiqSeized,
            uint256 ledgerArrears,
            uint64 pendingLiqSeizedTs,
            uint128 trailingOiSize
        );
    function isAdlPending() external view returns (bool);
    function adlPendingSince() external view returns (uint256);
    function adlAuctionStartTs() external view returns (uint256);
    function adlScoreDeposit(address user) external view returns (uint256);
    function terminalProfitClaim(address user) external view returns (uint256);
    function settlementPriceFixedTs() external view returns (uint256);
    function auxState() external view returns (BazaarTypes.AuxState memory);
    function book() external view returns (uint64 bidHead, uint64 askHead, uint64 bidCount, uint64 askCount);
    // Field order and widths mirror BazaarTypes.Order's packed declaration order.
    function orders(uint256 orderId)
        external
        view
        returns (
            address creator,
            uint64 canceledBlock,
            uint8 orderType,
            bool isLong,
            bool isPostOnly,
            uint8 tif,
            address integrator,
            uint64 expiryBlock,
            bool inBook,
            uint24 maxSlippageBp,
            uint128 triggerPrice,
            uint128 limitPrice,
            uint128 size,
            uint128 filledSize,
            uint48 prioritySeq,
            uint64 filledBlock,
            uint32 restedBlock,
            uint16 restedPremiumPpm,
            uint48 prevInBook,
            uint48 nextInBook
        );
}

/// @title IBazaarFactoryLens
/// @notice The one factory read the lens needs: the set of pairs it deployed.
interface IBazaarFactoryLens {
    function getAllPairs() external view returns (address[] memory);
}

/// @title BazaarPairLens
/// @notice Read-only companion contract for BazaarPair.
///         Provides computed views without adding to BazaarPair's bytecode.
contract BazaarPairLens {
    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;

    // BazaarPair storage slots for state the pair exposes only through `extsload`, from
    // `forge inspect BazaarPair storage-layout`. Every pair is a clone of one implementation, so
    // these hold for every pair that implementation deploys; a layout change needs them re-read,
    // and the budget view's tests pin them against the contract's own behaviour.
    uint256 internal constant SLOT_USER_ACTIVE_LIMIT_ORDERS = 2; // mapping(user => EnumerableSet.UintSet)
    uint256 internal constant SLOT_NEXT_ORDER_ID = 22; // the counter ids and queue positions are drawn from
    uint256 internal constant SLOT_MARK_PREMIUM_NOTIONAL = 63;
    uint256 internal constant SLOT_ADL_EPOCH = 94; // uint64 in the low bits
    uint256 internal constant SLOT_FEE_ESCROW_TOTAL = 106; // FeeEscrow.total
    uint256 internal constant SLOT_FEE_ESCROW_CLAIMABLE = 107; // FeeEscrow.claimable: mapping(recipient => owed)
    uint256 internal constant SLOT_ADL_TERMINATION_TS = 109;
    // +0 slippage line, +1 drift line, +2 their anchors and the weight's (low to high, 64 bits
    // each), +3 weight (BazaarTypes.LiquidationGapEma)
    uint256 internal constant SLOT_LIQUIDATION_GAP_EMA = 43;
    uint256 internal constant SLOT_INSURANCE_RATE_LIMIT = 57; // +0 withdrawn, +1 period start, +2 OI term
    uint256 internal constant SLOT_REOPEN_GAP_EMA = 105; // lastObsTs bits 0-63, gapEmaBp 64-191, lastJumpTs 192-255
    uint256 internal constant SLOT_TRIGGER_BOUNTY = 108; // FeeEscrow.bounty: mapping(orderId => held bounty)
    uint256 internal constant SLOT_INSURANCE_WITHDRAWAL_LOCK = 112; // mapping(user => lockedAmount << 64 | lockTs)

    error BazaarPairLens__ZeroAddress();

    /// @notice The factory whose pair set getClaimableFeesAll enumerates. The lens is deployed
    ///         per factory, ahead of it, against its CREATE-predicted address; the factory's
    ///         constructor re-checks that this points back at it, so a wrong prediction cannot
    ///         deploy a mis-wired system.
    address public immutable factory;

    constructor(address _factory) {
        if (_factory == address(0)) revert BazaarPairLens__ZeroAddress();
        factory = _factory;
    }

    /// @notice Returns a user's full position bucket as a memory struct
    function getPositionBucket(address pair, address user)
        external
        view
        returns (BazaarTypes.PositionBucket memory bucket)
    {
        (
            bucket.isLong,
            bucket.size,
            bucket.entryValue,
            bucket.collateral,
            bucket.entryFundingIndex,
            bucket.takeProfitOrderId,
            bucket.stopLossOrderId
        ) = IBazaarPairLens(pair).positionBuckets(user);
    }

    /// @notice Calculates the current solvency state of a user's position
    function checkBucketSolvency(address pair, address user, uint256 currentPrice)
        external
        view
        returns (BazaarTypes.BucketState memory result)
    {
        BazaarTypes.PositionBucket memory bucket;
        (
            bucket.isLong,
            bucket.size,
            bucket.entryValue,
            bucket.collateral,
            bucket.entryFundingIndex,
            bucket.takeProfitOrderId,
            bucket.stopLossOrderId
        ) = IBazaarPairLens(pair).positionBuckets(user);

        int256 fundingIdx = IBazaarPairLens(pair).currentFundingIndex();

        BazaarTypes.MarginRequirements memory marginReqs;
        (marginReqs.imrBp, marginReqs.mmrBp, marginReqs.lastUpdateTs,) = IBazaarPairLens(pair).marginRequirements();
        // Use the pair's own lagged MMR so this view applies the threshold liquidate() and the
        // matching walk apply on-chain; without it, every position would display against the
        // current rate alone. The pair measures the grace period back from its stored mark, so a
        // caller passing a currentPrice newer than that mark is describing two instants at once:
        // the threshold shifts to match once their own price update actually lands. liquidate()
        // can also judge below the stored current rate, at the curve its own price gives, so a
        // position shown here as seizable may still survive the call; simulating it tells.
        marginReqs.laggedMmrBp = IBazaarPairLens(pair).getLaggedMmr();

        result = BucketLib.calculateState(bucket, currentPrice, fundingIdx, marginReqs);
    }

    // ---- Insurance share pricing ----
    //
    // The pair prices shares off the fund's value at the mark rather than its balance
    // (RiskParamsLib's insurance share pricing section). The two views below value shares at the
    // pair's stored mark on the redemption basis; the two quotes take the mark from the caller,
    // who holds the live Pyth price the pair would resolve. A stored mark that has aged out is
    // still what these report, while the pair itself would refuse it and demand an update — so a
    // frontend pricing an actual deposit or redemption should quote against the live price.

    /// @dev Free capital, the raw balance, the inventory size and the ledger's arrears to the
    ///      fund, read from the pair's vault.
    function _insuranceFund(address pair)
        internal
        view
        returns (uint256 free, uint256 fund, uint256 inventory, uint256 arrears)
    {
        (,,,,, uint256 balance, uint256 size,,,,,,, uint256 seized, uint256 owed,,) = IBazaarPairLens(pair).pairVault();
        free = balance > seized ? balance - seized : 0;
        fund = balance;
        inventory = size;
        arrears = owed;
    }

    /// @dev The inventory's net position at `price` and the reserve the unload walk keeps, read
    ///      from the pair's vault: the two mark-dependent inputs of the share-pricing bases. The
    ///      backing is the seizure plus the ledger's arrears to the fund, as RiskParamsLib.inventoryNet
    ///      reads it, and the reserve is sized on live open interest capped at its trailing
    ///      minimum, as RiskParamsLib.adlReserve sizes it.
    function _inventoryNetAndReserve(address pair, uint256 price) internal view returns (int256 net, uint256 reserve) {
        (
            uint256 longOI,
            uint256 shortOI,,,,,
            uint256 size,
            uint256 entryNotional,,
            int256 entryFundingIndex,
            bool isLong,,
            uint256 targetInsuranceRatioBp,
            uint256 seized,
            uint256 arrears,,
            uint256 trailingOiSize
        ) = IBazaarPairLens(pair).pairVault();
        net = int256(seized + arrears)
            + RiskParamsLib.inventoryPnl(
                size, entryNotional, entryFundingIndex, isLong, price, IBazaarPairLens(pair).currentFundingIndex()
            );
        reserve = RiskParamsLib.adlReserveOf(
            RiskParamsLib.reserveOiSizeOf(
                RiskParamsLib.openInterestSizeOf(longOI, shortOI, size, isLong), trailingOiSize
            ),
            price,
            targetInsuranceRatioBp
        );
    }

    /// @dev The basis a redemption is priced against at `price` (RiskParamsLib.insuranceRedemptionBasis).
    function _redemptionBasis(address pair, uint256 price) internal view returns (uint256) {
        (uint256 free,, uint256 inventory,) = _insuranceFund(pair);
        if (inventory == 0) return free;
        (int256 net, uint256 reserve) = _inventoryNetAndReserve(pair, price);
        return RiskParamsLib.insuranceRedemptionBasisOf(free, net, reserve);
    }

    /// @notice What one insurance share redeems for at the pair's stored mark, in BAZAAR_SCALE
    ///         precision: free capital less the inventory loss the fund itself bears at that mark,
    ///         over the supply. 1.0 while no shares exist.
    function getInsuranceSharePrice(address pair) external view returns (uint256) {
        uint256 totalShares = IBazaarPairLens(pair).totalInsuranceShares();
        if (totalShares == 0) return BAZAAR_SCALE;
        (uint256 spotPrice,,,,) = IBazaarPairLens(pair).lastPairPrice();
        return Math.mulDiv(_redemptionBasis(pair, spotPrice), BAZAAR_SCALE, totalShares);
    }

    /// @notice What a depositor's insurance shares redeem for at the pair's stored mark, in
    ///         BAZAAR precision.
    function getInsuranceDepositValue(address pair, address user) external view returns (uint256 value) {
        uint256 totalShares = IBazaarPairLens(pair).totalInsuranceShares();
        if (totalShares == 0) return 0;
        uint256 userShares = IBazaarPairLens(pair).insuranceShares(user);
        (uint256 spotPrice,,,,) = IBazaarPairLens(pair).lastPairPrice();
        value = Math.mulDiv(userShares, _redemptionBasis(pair, spotPrice), totalShares);
    }

    /// @notice Shares a deposit of `amount` would mint if the pair resolved `price` as the mark.
    ///         Runs the pair's own arithmetic (InsuranceVaultLib.sharesForDeposit on
    ///         RiskParamsLib.insuranceNavOf); 0 where the deposit would revert for a fund whose
    ///         value at the mark is nil. Ignores the deposit's own gates (minimum, pair state,
    ///         per-user rate limit, the refusal where `price` would open an ADL window) and its
    ///         freshness requirement — quote against a live price, since the pair refuses a stale
    ///         one while the vault holds inventory.
    /// @param pair The pair
    /// @param amount Deposit amount in BAZAAR precision
    /// @param price The mark the vault's inventory would be valued at (BAZAAR_SCALE precision)
    /// @return Shares the deposit would mint
    function quoteInsuranceDeposit(address pair, uint256 amount, uint256 price) external view returns (uint256) {
        (uint256 free, uint256 fund, uint256 inventory, uint256 arrears) = _insuranceFund(pair);
        // Mirrors RiskParamsLib.insuranceDepositBasis: with no inventory the arrears are an
        // uncollected gain the deposit pays for; with inventory they are inside `net`.
        uint256 basis = free + arrears;
        if (inventory != 0) {
            (int256 net, uint256 reserve) = _inventoryNetAndReserve(pair, price);
            basis = RiskParamsLib.insuranceNavOf(free, net, reserve);
        }
        // The pair's dead-pool test reads what the fund holds outright: its balance plus the arrears.
        uint256 held = fund + arrears;
        return InsuranceVaultLib.sharesForDeposit(amount, IBazaarPairLens(pair).totalInsuranceShares(), held, basis);
    }

    /// @notice USDC (BAZAAR precision) a redemption of `shareAmount` would pay if the pair
    ///         resolved `price` as the mark. 0 while no shares exist, and 0 where the redemption
    ///         would revert for a fund whose value at the mark is nil. Ignores the redemption's
    ///         own gates (cooldown, window, health, rate limit, and the cap that holds a payout
    ///         to the fund's headroom while the vault holds inventory). On a live pair the
    ///         paying call of a locked redemption pays the lower of this and the amount its lock
    ///         recorded (getInsuranceWithdrawalLock).
    /// @param pair The pair
    /// @param shareAmount Shares to redeem
    /// @param price The mark the vault's inventory would be valued at (BAZAAR_SCALE precision)
    /// @return USDC the redemption would pay, in BAZAAR precision
    function quoteInsuranceWithdrawal(address pair, uint256 shareAmount, uint256 price)
        external
        view
        returns (uint256)
    {
        uint256 totalShares = IBazaarPairLens(pair).totalInsuranceShares();
        if (totalShares == 0) return 0;
        return Math.mulDiv(shareAmount, _redemptionBasis(pair, price), totalShares);
    }

    /// @notice Returns the current ADL score threshold
    /// @dev Delegates the decay math to AdlLib._getAdlScoreThreshold (inlined internal library
    ///      function) so the lens can never drift from the on-chain auction curve.
    function getAdlScoreThreshold(address pair) external view returns (uint256) {
        bool adlPending = IBazaarPairLens(pair).isAdlPending();
        uint256 auctionStartTs = IBazaarPairLens(pair).adlAuctionStartTs();
        if (!adlPending || auctionStartTs == 0) return type(uint256).max;
        return AdlLib._getAdlScoreThreshold(auctionStartTs);
    }

    /// @notice ADL auction score for `user`: PnL over the window-deposit-adjusted collateral
    ///         (AdlLib._scoreCollateral), priced the way the on-chain ranking prices the cohort
    ///         the user belongs to. Keepers sort executeAdl candidates by this score DESCENDING —
    ///         a submission that disagrees with the on-chain order reverts
    ///         (AdlLib__NotDescendingAdlScoreOrder).
    ///
    ///      Both sides can be candidates, and each cohort ranks at its own price. An account
    ///      opposite the vault's inventory closes against the inventory (submit it in `winners`)
    ///      and ranks at the window's frozen snapshot price and funding index, as AdlLib's scan
    ///      pass does. An account on the inventory's own side closes against the deferred
    ///      liquidations, is a candidate only while auxState reports some (submit it in
    ///      `deferredWinners`), and ranks at the price the transaction resolves and stores
    ///      (AdlLib._closeDeferred): a deferred account entered the window after the snapshot
    ///      was taken, so its counterparties' profit exists at the live price. The pair's last
    ///      stored price and live funding index stand in for that key here; they are the key
    ///      exactly when the transaction stores nothing newer. The pair reads the Pyth cache
    ///      before the caller's update, so a keeper cannot pin that price by what it submits;
    ///      a submission sorted at a tick the store overtakes reverts and is re-scored here at
    ///      the price it stored, and the funding that store accrues can move near-tied scores.
    ///      That cohort also ranks on its full collateral: window deposits are subtracted only
    ///      from the inventory's counterparties, whose score is pinned to the snapshot their
    ///      price is frozen at.
    /// @param pair The BazaarPair to read
    /// @param user The candidate winner
    /// @return adlScore The ranking score; 0 when the user cannot be a candidate at all (no ADL
    ///         pending, flat, on a side with nothing to close against, or non-positive PnL at
    ///         the cohort's ranking price)
    /// @return eligible True when the user would pass the eligibility scan right now:
    ///         adlScore > 0 and at or above the current (decaying) auction threshold
    function getAdlScore(address pair, address user) external view returns (uint256 adlScore, bool eligible) {
        if (!IBazaarPairLens(pair).isAdlPending()) return (0, false);
        BazaarTypes.AuxState memory aux = IBazaarPairLens(pair).auxState();

        BazaarTypes.PositionBucket memory bucket;
        (
            bucket.isLong,
            bucket.size,
            bucket.entryValue,
            bucket.collateral,
            bucket.entryFundingIndex,
            bucket.takeProfitOrderId,
            bucket.stopLossOrderId
        ) = IBazaarPairLens(pair).positionBuckets(user);
        if (bucket.size == 0) return (0, false);
        if (bucket.isLong != aux.adlLongs && aux.deferredCount == 0) return (0, false);

        BazaarTypes.MarginRequirements memory marginReqs;
        (marginReqs.imrBp, marginReqs.mmrBp, marginReqs.lastUpdateTs,) = IBazaarPairLens(pair).marginRequirements();
        marginReqs.laggedMmrBp = IBazaarPairLens(pair).getLaggedMmr();

        // Each cohort ranks at its own price and collateral, as AdlLib does: the inventory's
        // counterparties at the window's frozen snapshot less their window deposits, the deferred
        // cohort at the price the call attests, for which the last stored price and the live
        // funding index stand in, on its full collateral.
        uint256 rankPrice = aux.adlSnapshotPrice;
        int256 rankFundingIndex = aux.adlSnapshotFundingIndex;
        uint256 windowDeposit = IBazaarPairLens(pair).adlScoreDeposit(user);
        if (bucket.isLong != aux.adlLongs) {
            (rankPrice,,,,) = IBazaarPairLens(pair).lastPairPrice();
            rankFundingIndex = IBazaarPairLens(pair).currentFundingIndex();
            windowDeposit = 0;
        }
        BazaarTypes.BucketState memory state = BucketLib.calculateState(bucket, rankPrice, rankFundingIndex, marginReqs);
        if (state.totalPnl <= 0) return (0, false);

        adlScore = Math.mulDiv(
            uint256(state.totalPnl), BAZAAR_SCALE, AdlLib._scoreCollateral(state.effectiveCollateral, windowDeposit)
        );
        eligible = adlScore >= AdlLib._getAdlScoreThreshold(IBazaarPairLens(pair).adlAuctionStartTs());
    }

    /// @notice A user's terminal-settlement entitlement, decomposed: the cash their bucket
    ///         collateral redeems for plus the cash their registered profit claim redeems for.
    /// @dev Both ratios come from auxState and are 0 until finalizeTermination runs, so while the
    ///      settlement window is open the components are visible but the payout reads 0 ("not
    ///      frozen yet", not "worthless"). An unsettled position's PnL is NOT included: it
    ///      becomes a claim (settled before finalize) or realizes straight into collateral
    ///      (settled after) only when the position is settled. The principal ratio sits below
    ///      100% only when cash could not cover principal. Both ratios can fall after finalize:
    ///      a bankrupt position finalize did not wait for, settled with a shortfall the insurers'
    ///      residual cannot fund, re-derives them on the entitlements still unpaid
    ///      (TerminalRatiosRefrozen), so a quote read before such a settlement overstates the
    ///      payout by the holder's share of that gap; while any position is still open, a
    ///      withdrawal beyond what the principal ledger holds is refused with that figure
    ///      (CollateralLib__LedgerShortfall), and settling the open positions releases the rest.
    ///      withdrawCollateral takes its amount in collateral units, not this cash figure:
    ///      getMaxWithdrawable returns the largest amount it accepts.
    /// @param pair The BazaarPair to read
    /// @param user The account to query
    /// @return collateral The user's current bucket collateral
    /// @return registeredClaim The user's registered profit claim
    /// @return principalRatio Cash paid per unit of collateral, BAZAAR_SCALE = 100% (0 before finalize)
    /// @return profitRatio Cash paid per unit of registered claim, BAZAAR_SCALE = 100% (0 before finalize)
    /// @return payout collateral x principalRatio + registeredClaim x profitRatio
    function getTerminalEntitlement(address pair, address user)
        external
        view
        returns (
            uint256 collateral,
            uint256 registeredClaim,
            uint256 principalRatio,
            uint256 profitRatio,
            uint256 payout
        )
    {
        (,,, collateral,,,) = IBazaarPairLens(pair).positionBuckets(user);
        registeredClaim = IBazaarPairLens(pair).terminalProfitClaim(user);
        BazaarTypes.AuxState memory aux = IBazaarPairLens(pair).auxState();
        principalRatio = aux.terminalPrincipalRatio;
        profitRatio = aux.terminalProfitRatio;
        payout = Math.mulDiv(collateral, principalRatio, BazaarTypes.BAZAAR_SCALE)
            + Math.mulDiv(registeredClaim, profitRatio, BazaarTypes.BAZAAR_SCALE);
    }

    /// @notice The largest amount `withdrawCollateral` would accept from `user` right now, live or
    ///         after termination: one "max" for both, in the units the withdrawal takes.
    /// @dev On a live pair this previews the FRESH-price path. While the pair's price is stale, a
    ///      position holder's withdrawal reverts outright (CollateralLib__WithdrawalRequiresFreshPrice)
    ///      regardless of the bound returned here; flat and order-only accounts are unaffected.
    ///      Returns 0 while the pair refuses every withdrawal (limbo before a scheduled cutoff, and
    ///      the settlement window between the price fix and finalize), while ADL is pending for a
    ///      position holder, for an insolvent position, and when the vault-health verdict the
    ///      withdrawal runs would refuse it (_verdictRefuses). For a position holder the bound is
    ///      the tightest of: raw collateral, the retained-collateral floor (position notional x
    ///      mmrBp for continuously traded pairs / imrBp for session-bound pairs, held in
    ///      collateral proper), and the equity the IMR leaves free, where worst-case notional folds
    ///      in resting-order exposure (CollateralLib._worstCaseNotional) and the fill gate's debit
    ///      across the resting set comes off on top (CollateralLib._fillDebitOf) — each exactly as
    ///      the on-chain check applies it. A flat user is bounded by collateral less the order-IMR
    ///      reserve on their larger resting side and that debit. Evaluated at the pair's stored
    ///      funding index; the resting set is reserved at the pair's stored spot, as the withdrawal
    ///      reserves it at the spot of the price it resolves. Every bound is then capped at the
    ///      deposits ledger, which refuses a draw past what it holds (CollateralLib__LedgerShortfall):
    ///      winners can have withdrawn the cash a loser's later liquidation was to pay in.
    ///
    ///      One refusal is not reproduced. A position holder's withdrawal is also refused when the
    ///      vault's liquidation exposure exceeds what the fund can carry (verdict reason 1) before
    ///      an ADL window is latched: on the stale fallback, which withholds the latch, or in the
    ///      transaction whose own verdict opens the window. Judging that walks the deferred accounts
    ///      at the withdrawal's own price (VaultHealthLib.checkLiqExposure), which a view outside
    ///      the pair cannot run, so the bound returned can revert there.
    ///
    ///      After finalizeTermination the bound is the terminal withdrawal's (_terminalMaxWithdrawable),
    ///      in collateral units: the withdrawal pays it times the frozen principal ratio, the cash
    ///      figure getTerminalEntitlement reports. `currentPrice` is not read there.
    /// @param pair The BazaarPair to read
    /// @param user The account to query
    /// @param currentPrice The price the position is valued at (BAZAAR 1e18). Pass the
    ///        CONSERVATIVE bracket the withdrawal path itself applies: spot − confidence for a
    ///        long, spot + confidence for a short. A flat user's bound reads none of it. Passing
    ///        plain spot for a position holder overstates the bound by the confidence band and
    ///        the on-chain check will reject the difference.
    /// @return maxAmount The largest `amount` `withdrawCollateral` would accept, in BAZAAR (1e18)
    function getMaxWithdrawable(address pair, address user, uint256 currentPrice)
        external
        view
        returns (uint256 maxAmount)
    {
        if (IBazaarPairLens(pair).isPairTerminated()) return _terminalMaxWithdrawable(pair, user);
        if (IBazaarPairLens(pair).settlementPriceFixedTs() != 0) return 0;
        // Limbo begins LIMBO_LEAD before the cutoff (the pair's _pastTradingCutoff rule).
        uint256 cutoff = IBazaarPairLens(pair).scheduledTerminationTs();
        if (cutoff != 0 && block.timestamp + BazaarTypes.LIMBO_LEAD >= cutoff) return 0;

        BazaarTypes.PositionBucket memory bucket;
        (
            bucket.isLong,
            bucket.size,
            bucket.entryValue,
            bucket.collateral,
            bucket.entryFundingIndex,
            bucket.takeProfitOrderId,
            bucket.stopLossOrderId
        ) = IBazaarPairLens(pair).positionBuckets(user);

        // Mirror the withdrawal gate's reservation of the resting set, which it tallies at the
        // spot of the price it resolves: the pair's stored spot stands in for it here, so the
        // preview is exact while that store is the withdrawal's own tick.
        (uint256 longExposure, uint256 shortExposure, uint256 fillDebit) = _restingReserve(pair, user);
        if (_verdictRefuses(pair, bucket.size != 0 || longExposure != 0 || shortExposure != 0)) return 0;

        BazaarTypes.MarginRequirements memory marginReqs;
        (marginReqs.imrBp, marginReqs.mmrBp, marginReqs.lastUpdateTs,) = IBazaarPairLens(pair).marginRequirements();
        marginReqs.laggedMmrBp = IBazaarPairLens(pair).getLaggedMmr();

        if (bucket.size == 0) {
            // Flat: collateral less the order-IMR reserve on the larger resting side (zero
            // position notional reduces _worstCaseNotional to exactly that max) and the fill
            // gate's debit across the set.
            uint256 worst = CollateralLib._worstCaseNotional(true, 0, longExposure, shortExposure);
            uint256 orderImrReq = Math.mulDiv(marginReqs.imrBp, worst, BazaarTypes.BP_SCALE) + fillDebit;
            maxAmount = bucket.collateral > orderImrReq ? bucket.collateral - orderImrReq : 0;
        } else {
            if (IBazaarPairLens(pair).isAdlPending()) return 0; // position holders frozen during ADL

            BazaarTypes.BucketState memory state =
                BucketLib.calculateState(bucket, currentPrice, IBazaarPairLens(pair).currentFundingIndex(), marginReqs);
            if (!state.isSolvent) return 0;

            // Ceiling 1: raw collateral.
            maxAmount = state.effectiveCollateral;

            // Ceiling 2: the retained-collateral floor (margin held as cash — maintenance-level for
            // continuously traded pairs, initial-level for session-bound pairs, whose reopen jumps
            // liquidation cannot interpose against).
            uint256 floorRateBp = IBazaarPairLens(pair).isContinuouslyTraded() ? marginReqs.mmrBp : marginReqs.imrBp;
            uint256 minRetained = Math.mulDiv(floorRateBp, state.currentNotional, BazaarTypes.BP_SCALE);
            uint256 aboveFloor = state.effectiveCollateral > minRetained ? state.effectiveCollateral - minRetained : 0;
            if (aboveFloor < maxAmount) maxAmount = aboveFloor;

            // Ceiling 3: the equity the IMR leaves free, after the resting set's fill debit.
            uint256 worst =
                CollateralLib._worstCaseNotional(bucket.isLong, state.currentNotional, longExposure, shortExposure);
            uint256 imrRequirement = Math.mulDiv(marginReqs.imrBp, worst, BazaarTypes.BP_SCALE) + fillDebit;
            uint256 imrSlack = state.availableEquity > imrRequirement ? state.availableEquity - imrRequirement : 0;
            if (imrSlack < maxAmount) maxAmount = imrSlack;
        }

        // Ceiling 4: the deposits ledger.
        (,,,, uint256 ledger,,,,,,,,,,,,) = IBazaarPairLens(pair).pairVault();
        if (ledger < maxAmount) maxAmount = ledger;
    }

    /// @dev Whether the vault-health verdict withdrawCollateral runs would refuse the withdrawal,
    ///      from the checks a view can reproduce. An account with a position or live orders is
    ///      priced and judged in full, and realized bad debt (reason 4), a USDC balance short of
    ///      the books (3) or a timed-out ADL auction past its deadline (2) refuses it. An account
    ///      with neither reads no price and is judged on the balance alone. The deadline test is
    ///      the conservative side of reason 2: the pair also needs a fresh price and the exposure
    ///      still uncovered to fire it. Reason 1 is left to getMaxWithdrawable (see there).
    /// @param pair The BazaarPair to read
    /// @param priced Whether the account holds a position or live orders
    /// @return refused True when the withdrawal would be refused
    function _verdictRefuses(address pair, bool priced) internal view returns (bool refused) {
        if (_isBalanceShort(pair)) return true;
        if (!priced) return false;
        (,,,,,,,,,,, uint256 deficit,,,,,) = IBazaarPairLens(pair).pairVault();
        if (deficit != 0) return true;
        uint256 deadline = uint256(IBazaarPairLens(pair).extsload(bytes32(SLOT_ADL_TERMINATION_TS)));
        return IBazaarPairLens(pair).isAdlPending() && deadline != 0 && block.timestamp >= deadline;
    }

    /// @dev CollateralLib.isBalanceShort read from outside the pair: the USDC the pair holds against
    ///      the deposits ledger, the insurance fund and the fee escrow, with the same tolerance and
    ///      the same flooring, and an unreadable balance taken as no shortfall.
    /// @param pair The BazaarPair to read
    /// @return short True when the books promise materially more than the pair holds
    function _isBalanceShort(address pair) internal view returns (bool short) {
        (,,,, uint256 ledger, uint256 insurance,,,,,,,,,,,) = IBazaarPairLens(pair).pairVault();
        uint256 escrow = uint256(IBazaarPairLens(pair).extsload(bytes32(SLOT_FEE_ESCROW_TOTAL)));
        uint256 expected = (insurance + ledger + escrow) / 1e12;
        (bool ok, bytes memory data) = IBazaarPairLens(pair).usdc().staticcall(abi.encodeWithSelector(0x70a08231, pair));
        if (!ok || data.length < 32) return false;
        return expected
            > abi.decode(data, (uint256)) + (expected * CollateralLib.USDC_BALANCE_TOLERANCE_BP / BazaarTypes.BP_SCALE);
    }

    /// @dev getMaxWithdrawable after finalizeTermination: the largest amount the terminal branch of
    ///      withdrawCollateral accepts. That branch first settles a position finalize did not wait
    ///      for, at the fixed price and the frozen funding index: a solvent one realizes its PnL
    ///      into collateral, a bankrupt one leaves none. It then credits the registered claim at
    ///      the profit ratio into both the collateral and the deposits ledger, and accepts up to
    ///      the collateral. While any position is still open after that settlement, a draw past
    ///      the ledger is refused with what the ledger holds; once none is, the ledger's rounding
    ///      dust is floored instead. A bankrupt straggler's settlement can lower both ratios for
    ///      every other holder (getTerminalEntitlement), which this bound does not anticipate.
    /// @param pair The BazaarPair to read
    /// @param user The account to query
    /// @return amount The largest terminal `amount`, in collateral units (BAZAAR 1e18)
    function _terminalMaxWithdrawable(address pair, address user) internal view returns (uint256 amount) {
        BazaarTypes.PositionBucket memory bucket;
        (bucket.isLong, bucket.size, bucket.entryValue, bucket.collateral, bucket.entryFundingIndex,,) =
            IBazaarPairLens(pair).positionBuckets(user);
        (uint256 longOi, uint256 shortOi,,, uint256 ledger,,,,,,,,,,,,) = IBazaarPairLens(pair).pairVault();
        BazaarTypes.AuxState memory aux = IBazaarPairLens(pair).auxState();

        amount = bucket.collateral;
        if (bucket.size != 0) {
            BazaarTypes.MarginRequirements memory zeroReqs; // settlement ignores margins
            BazaarTypes.BucketState memory state = BucketLib.calculateState(
                bucket, aux.settlementPrice, IBazaarPairLens(pair).currentFundingIndex(), zeroReqs
            );
            int256 equity = int256(amount) + state.totalPnl;
            amount = equity > 0 ? uint256(equity) : 0;
            if (bucket.isLong) longOi = longOi > bucket.size ? longOi - bucket.size : 0;
            else shortOi = shortOi > bucket.size ? shortOi - bucket.size : 0;
        }

        uint256 claimPay =
            Math.mulDiv(IBazaarPairLens(pair).terminalProfitClaim(user), aux.terminalProfitRatio, BAZAAR_SCALE);
        amount += claimPay;
        ledger += claimPay;
        if (amount > ledger && (longOi != 0 || shortOi != 0)) amount = ledger;
    }

    /// @notice Returns pending liquidation exposure (single-direction aggregate)
    /// @dev Includes the entry funding index so a caller can reproduce the vault PnL the
    ///      protocol itself values this inventory at — price leg against `pendingLiqEntryNotional`
    ///      plus the funding leg from `pendingLiqEntryFundingIndex` to the pair's live index.
    ///      Without it only the price half is derivable, and a reader would systematically
    ///      understate the fund's claim on a vault holding the funding-paying side. The seizure
    ///      stamp is what the unload floor opens from: a keeper can tell from it how far the
    ///      floor has moved from the band edge toward the fund-neutral price over
    ///      UNLOAD_FLOOR_DECAY, and so when a bid beyond the band becomes fillable.
    function getPendingLiquidationExposure(address pair)
        external
        view
        returns (
            uint256 pendingLiqSize,
            uint256 pendingLiqEntryNotional,
            uint256 pendingLiqBankruptcyNotional,
            int256 pendingLiqEntryFundingIndex,
            bool pendingLiqIsLong,
            uint64 pendingLiqSeizedTs
        )
    {
        (
            ,,,,,,
            pendingLiqSize,
            pendingLiqEntryNotional,
            pendingLiqBankruptcyNotional,
            pendingLiqEntryFundingIndex,
            pendingLiqIsLong,,,,,
            pendingLiqSeizedTs,
        ) = IBazaarPairLens(pair).pairVault();
    }

    // ---- Library constant getters ----

    /// @notice Returns EIP-712 constants needed by off-chain signers
    function getEip712Constants()
        external
        pure
        returns (
            bytes32 domainTypehash,
            bytes32 nameHash,
            bytes32 versionHash,
            uint256 maxRelayerFee,
            uint256 maxDeadlineWindow
        )
    {
        return (
            MetaTxLib.EIP712_DOMAIN_TYPEHASH,
            MetaTxLib.NAME_HASH,
            MetaTxLib.VERSION_HASH,
            MetaTxLib.MAX_RELAYER_FEE,
            MetaTxLib.MAX_DEADLINE_WINDOW
        );
    }

    /// @notice Returns all EIP-712 type hashes for meta-transaction signing
    function getTypehashes()
        external
        pure
        returns (
            bytes32 depositCollateral,
            bytes32 withdrawCollateral,
            bytes32 depositToInsurance,
            bytes32 executeInsuranceWithdrawal,
            bytes32 createOrder,
            bytes32 cancelOrders,
            bytes32 requestInsuranceWithdrawal,
            bytes32 amendOrders
        )
    {
        return (
            MetaTxLib.DEPOSIT_COLLATERAL_TYPEHASH,
            MetaTxLib.WITHDRAW_COLLATERAL_TYPEHASH,
            MetaTxLib.DEPOSIT_TO_INSURANCE_TYPEHASH,
            MetaTxLib.EXECUTE_INSURANCE_WITHDRAWAL_TYPEHASH,
            MetaTxLib.CREATE_ORDER_TYPEHASH,
            MetaTxLib.CANCEL_ORDERS_TYPEHASH,
            MetaTxLib.REQUEST_INSURANCE_WITHDRAWAL_TYPEHASH,
            MetaTxLib.AMEND_ORDERS_TYPEHASH
        );
    }

    /// @notice The id the pair's next created order will take, which is also the next queue
    ///         position an amendment or a keeper arming a StopLimit draws: all come from one
    ///         counter, so ids have gaps where those consumed values. Read from the pair's storage.
    /// @param pair The pair
    /// @return The next counter value
    function nextOrderId(address pair) external view returns (uint256) {
        return uint256(IBazaarPairLens(pair).extsload(bytes32(SLOT_NEXT_ORDER_ID)));
    }

    /// @notice Returns order lifetime constants (block-based, derived from ~250ms Arbitrum blocks)
    function getOrderLifetimeConstants()
        external
        pure
        returns (uint64 minOrderLifetimeBlocks, uint64 maxOrderLifetimeBlocks)
    {
        return (BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS, BazaarTypes.MAX_ORDER_LIFETIME_BLOCKS);
    }

    /// @notice Returns the minimum collateral deposit amount
    function getMinCollateralAmount() external pure returns (uint256) {
        return CollateralLib.MIN_COLLATERAL_AMOUNT;
    }

    /// @notice Returns insurance withdrawal timing and rate-limit constants
    function getInsuranceWithdrawalConstants()
        external
        pure
        returns (
            uint256 cooldown,
            uint256 window,
            uint256 rateLimitPeriod,
            uint256 rateLimitBp,
            uint256 aboveTargetRateLimitBp,
            uint256 aboveTargetFundCapBp,
            uint256 belowTargetFundCapBp
        )
    {
        return (
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN,
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_WINDOW,
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD,
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_BP,
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_RATE_LIMIT_BP,
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_FUND_CAP_BP,
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_BELOW_TARGET_FUND_CAP_BP
        );
    }

    /// @notice The insurance withdrawal budget an execution submitted now would be checked
    ///         against: what is left of the pair's cumulative 6-hour budget, the budget itself,
    ///         and the coverage and target readings that decide which regime sets it.
    /// @dev Rebuilt from the same inputs and the same arithmetic executeInsuranceWithdrawal uses —
    ///      coverage from RiskParamsLib.insuranceFundToOIRatioOf, the target recomputed live from
    ///      the stored risk estimators rather than the vault's cached copy (which trails the live
    ///      curve between margin refreshes), and the cap from InsuranceVaultLib.withdrawalCapOf —
    ///      so a frontend is shown the number execution enforces.
    ///
    ///      The budget is shared across every insurer and first-come-first-served, and a
    ///      withdrawal executes a cooldown after its request, so this is a reading of the moment,
    ///      not a reservation. A period that has lapsed is reported as the fresh one the next
    ///      withdrawal would open: nothing spent, and the OI term re-snapshotted at `price`. Above
    ///      target that term is bounded by the open interest held for the whole trailing day,
    ///      valued at `price` from the vault's cached trailing minimum, as execution reads it
    ///      (InsuranceVaultLib.heldOiTermOf).
    ///
    ///      A terminated pair and a pair with no open interest are not rate-limited at all; both
    ///      report remaining, cap and resetsAt as type(uint256).max.
    /// @param pair The BazaarPair to read
    /// @param price The price to value open interest and inherited inventory at (BAZAAR_SCALE);
    ///        execution values them at the fresh price it stores
    /// @return remaining What the period budget still admits
    /// @return cap The period budget, cumulative across every withdrawal in the period
    /// @return resetsAt When the current period ends and the budget refills
    /// @return coverageRatioBp The fund's coverage ratio: free capital over OI notional, in bp
    /// @return targetRatioBp The live target ratio the coverage is judged against, in bp
    function getInsuranceWithdrawalBudget(address pair, uint256 price)
        external
        view
        returns (uint256 remaining, uint256 cap, uint256 resetsAt, uint256 coverageRatioBp, uint256 targetRatioBp)
    {
        uint256 oiNotional;
        uint256 heldCap;
        uint256 fund;
        (coverageRatioBp, oiNotional, heldCap, fund) = _coverage(pair, price);
        targetRatioBp = _liveTargetRatio(pair);
        if (IBazaarPairLens(pair).isPairTerminated() || oiNotional == 0) {
            return (type(uint256).max, type(uint256).max, type(uint256).max, coverageRatioBp, targetRatioBp);
        }

        (uint256 spent, uint256 periodStart, uint256 periodCap) = _rateLimitWindow(pair, oiNotional);
        cap = InsuranceVaultLib.withdrawalCapOf(periodCap, heldCap, fund, coverageRatioBp < targetRatioBp);
        remaining = cap > spent ? cap - spent : 0;
        resetsAt = periodStart + InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD;
    }

    /// @notice Where `user`'s insurance redemption stands in its two execute calls on a live pair:
    ///         whether the first call has locked it, the amount it locked, and when the paying
    ///         call opens and the window closes. The paying call pays the lower of `lockedAmount`
    ///         and what the requested shares are worth when it lands (quoteInsuranceWithdrawal),
    ///         held to the fund's headroom while the vault holds inventory; one that pays part of
    ///         the request leaves the rest requested under the lock scaled to it, as read here.
    /// @dev Rebuilt from the pair's storage with the timing rule execution enforces
    ///      (InsuranceVaultLib.claimOpensAt), so the opening shown is the one the paying call
    ///      checks. It reflects the discontinuities stored so far; one stored later pushes the
    ///      opening back. The paying call's own price store counts too: when the pair has gone
    ///      REOPEN_GAP_MIN_STALENESS or more without a store, that store would end a gap, so the
    ///      opening reported is no earlier than a reopen delay from now, and it is reached only if
    ///      a price is stored first (refreshPrice or any priced call). A price jump the next store
    ///      would carry cannot be foreseen here and pushes the opening back the same way. A lock
    ///      counts only for the request whose window it was made in, so one left from an earlier
    ///      request reads as unlocked. The share epoch is not consulted: a request a fund recap
    ///      has voided still reads here, and execution refuses it. A terminated pair redeems in
    ///      one call and reads as unlocked with no window.
    /// @param pair The BazaarPair to read
    /// @param user The redeeming LP
    /// @return isLocked Whether the current request's first call has run
    /// @return lockedAmount What the requested shares were worth at the lock (BAZAAR precision)
    /// @return lockTs When the lock was made
    /// @return claimOpensTs When the paying call opens
    /// @return windowEndTs When the request's window closes, after which neither call is
    ///         accepted; 0 without a request
    function getInsuranceWithdrawalLock(address pair, address user)
        external
        view
        returns (bool isLocked, uint256 lockedAmount, uint256 lockTs, uint256 claimOpensTs, uint256 windowEndTs)
    {
        IBazaarPairLens p = IBazaarPairLens(pair);
        uint256 requestTs = uint256(uint64(p.insuranceWithdrawalRequestTs(user)));
        if (requestTs == 0 || p.isPairTerminated()) return (false, 0, 0, 0, 0);
        uint256 windowOpensTs = requestTs + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN;
        windowEndTs = windowOpensTs + InsuranceVaultLib.INSURANCE_WITHDRAWAL_WINDOW;
        uint256 lock = uint256(p.extsload(keccak256(abi.encode(user, SLOT_INSURANCE_WITHDRAWAL_LOCK))));
        lockTs = uint256(uint64(lock));
        if (lockTs < windowOpensTs) return (false, 0, 0, 0, windowEndTs);
        uint256 discontinuities = uint256(p.extsload(bytes32(SLOT_REOPEN_GAP_EMA)));
        claimOpensTs = InsuranceVaultLib.claimOpensAt(lockTs, uint64(discontinuities), discontinuities >> 192);
        (,, uint256 storedTs,,) = p.lastPairPrice();
        if (block.timestamp >= storedTs + RiskParamsLib.REOPEN_GAP_MIN_STALENESS) {
            uint256 afterNextStore = block.timestamp + InsuranceVaultLib.INSURANCE_WITHDRAWAL_REOPEN_CLAIM_DELAY;
            if (afterNextStore > claimOpensTs) claimOpensTs = afterNextStore;
        }
        return (true, lock >> 64, lockTs, claimOpensTs, windowEndTs);
    }

    /// @dev The rate-limit window as the next withdrawal would find it. The pair only rolls a
    ///      lapsed period when a withdrawal lands in it, so the stored words can describe a period
    ///      that is already over; this reports the fresh one execution would open instead.
    /// @return spent Withdrawn so far in the period
    /// @return periodStart When the period opened
    /// @return periodCap The period's OI snapshot term
    function _rateLimitWindow(address pair, uint256 oiNotional)
        internal
        view
        returns (uint256 spent, uint256 periodStart, uint256 periodCap)
    {
        IBazaarPairLens p = IBazaarPairLens(pair);
        spent = uint256(p.extsload(bytes32(SLOT_INSURANCE_RATE_LIMIT)));
        periodStart = uint256(p.extsload(bytes32(SLOT_INSURANCE_RATE_LIMIT + 1)));
        periodCap = uint256(p.extsload(bytes32(SLOT_INSURANCE_RATE_LIMIT + 2)));
        if (block.timestamp >= periodStart + InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD) {
            spent = 0;
            periodStart = block.timestamp;
            periodCap = (oiNotional * InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_BP) / BazaarTypes.BP_SCALE;
        }
    }

    /// @dev The coverage reading the withdrawal rate limit judges by, rebuilt from the vault's
    ///      public fields with the contract's own arithmetic, and the held OI term that bounds the
    ///      budget's OI term above target.
    /// @return ratioBp Free capital over OI notional in bp; type(uint256).max at zero OI
    /// @return oiNotional Open interest notional at `price`
    /// @return heldCap The held OI term at `price` (InsuranceVaultLib.heldOiTermOf)
    /// @return fund The raw insurance fund balance, which the fund-side budget terms read
    function _coverage(address pair, uint256 price)
        internal
        view
        returns (uint256 ratioBp, uint256 oiNotional, uint256 heldCap, uint256 fund)
    {
        (
            uint256 longOI,
            uint256 shortOI,,,,
            uint256 balance,
            uint256 size,
            uint256 entryNotional,,
            int256 entryFundingIndex,
            bool isLong,,,,
            uint256 arrears,,
            uint256 trailingOiSize
        ) = IBazaarPairLens(pair).pairVault();
        fund = balance;
        // An unvaluable price reads as no OI notional, which execution does not rate-limit either.
        if (price == 0) return (0, 0, 0, fund);
        uint256 liveOiSize = RiskParamsLib.openInterestSizeOf(longOI, shortOI, size, isLong);
        oiNotional = Math.mulDiv(liveOiSize, price, BAZAAR_SCALE);
        heldCap = InsuranceVaultLib.heldOiTermOf(liveOiSize, trailingOiSize, price);
        int256 pnl = size == 0
            ? int256(0)
            : RiskParamsLib.inventoryPnl(
                size, entryNotional, entryFundingIndex, isLong, price, IBazaarPairLens(pair).currentFundingIndex()
            );
        (ratioBp,) = RiskParamsLib.insuranceFundToOIRatioOf(balance, pnl, pnl < 0 ? arrears : 0, oiNotional);
    }

    /// @dev The fund target recomputed live, as executeInsuranceWithdrawal computes it: the stress
    ///      move from the stored variance, faded slippage and reopen floor, with the faded drift
    ///      competing against it for the target.
    function _liveTargetRatio(address pair) internal view returns (uint256) {
        IBazaarPairLens p = IBazaarPairLens(pair);
        (, uint256 emaVarianceBp, uint256 lastPriceTs,,) = p.lastPairPrice();
        uint256 anchors = uint256(p.extsload(bytes32(SLOT_LIQUIDATION_GAP_EMA + 2)));
        (int256 slippageBp, int256 driftBp) = RiskParamsLib.fadedLiquidationGapsOf(
            uint256(p.extsload(bytes32(SLOT_LIQUIDATION_GAP_EMA))),
            uint64(anchors),
            uint256(p.extsload(bytes32(SLOT_LIQUIDATION_GAP_EMA + 1))),
            uint64(anchors >> 64),
            lastPriceTs
        );
        uint256 reopenGapBp = uint128(uint256(p.extsload(bytes32(SLOT_REOPEN_GAP_EMA))) >> 64);
        return RiskParamsLib.getTargetInsuranceRatio(
            RiskParamsLib.stressMoveBp(emaVarianceBp, slippageBp, reopenGapBp, p.isContinuouslyTraded()), driftBp
        );
    }

    /// @notice Returns the vault health / ADL constants: the share of the insurance target the
    ///         ADL gate and the unload walk keep out of the fund's free capital, the cap on the
    ///         oracle leg of the unload band, the ADL timeout, and the batch size.
    function getVaultHealthConstants()
        external
        pure
        returns (
            uint256 adlReserveBp,
            uint256 unloadBandCapBp,
            uint256 adlTimeoutDuration,
            uint256 maxAdlWinnersPerBatch
        )
    {
        return (
            BazaarTypes.ADL_RESERVE_BP,
            BazaarTypes.LIQ_MAX_SLIPPAGE_BP,
            VaultHealthLib.ADL_TIMEOUT_DURATION,
            AdlLib.MAX_ADL_WINNERS_PER_BATCH
        );
    }

    /// @notice Returns the liquidator reward constants. A liquidate() call earns, per account it
    ///         seizes or newly defers, minReward — or, when its position is worth less than
    ///         BazaarTypes.MIN_ORDER_AMOUNT, its own equity if that is smaller — and for a seizure
    ///         that nets against the vault's inventory the larger of that and
    ///         netted * feeEbp / ebpScale, `netted` being the overlap's notional at the
    ///         liquidation price. Its inline unload then adds whatever unloaded * feeEbp / ebpScale
    ///         exceeds what those rewards paid beyond the nettings' rate, `unloaded` being the
    ///         notional it sells into the book. Debited from insurance, capped at its free
    ///         capital, and accrued to the liquidator's claimable balance.
    /// @dev feeEbp is also the rate unloadVault pays its caller, but that bounty carries its
    ///      own floor (UNLOAD_BOUNTY_MIN) and earns it only on a qualifying unload, so
    ///      minReward does not apply there.
    function getLiquidationRewardConstants()
        external
        pure
        returns (uint256 minReward, uint256 feeEbp, uint256 ebpScale)
    {
        return (BazaarTypes.MIN_LIQUIDATOR_REWARD, BazaarTypes.LIQUIDATION_FEE_EBP, BazaarTypes.EBP_SCALE);
    }

    // ---- Fee escrow views ----

    /// @notice What `who` may claim on each of `pairs`, in BAZAAR (1e18) precision. Each entry is
    ///         collected with one `claimFees()` call on that pair.
    /// @dev A keeper or relayer earns on many pairs and claims per pair, so the question it needs
    ///      answered is which pairs hold a balance worth the gas. `who` is explicit because a view
    ///      has no meaningful caller; entries are unfiltered so the reader applies its own
    ///      threshold. Reverts if an entry is not a pair.
    /// @param pairs The pairs to read.
    /// @param who The prospective claimant.
    /// @return owed owed[i] is the unclaimed balance on pairs[i].
    function getClaimableFees(address[] memory pairs, address who) external view returns (uint256[] memory owed) {
        return _claimableOn(pairs, who);
    }

    /// @notice What `who` may claim on every pair the wired factory has deployed.
    /// @dev getClaimableFees over the factory's full pair set. A view, so the only cost is the
    ///      eth_call's gas, linear in the pair count.
    /// @param who The prospective claimant.
    /// @return pairs Every pair under the factory, in the factory's enumeration order.
    /// @return owed owed[i] is the unclaimed balance on pairs[i].
    function getClaimableFeesAll(address who) external view returns (address[] memory pairs, uint256[] memory owed) {
        pairs = IBazaarFactoryLens(factory).getAllPairs();
        owed = _claimableOn(pairs, who);
    }

    function _claimableOn(address[] memory pairs, address who) internal view returns (uint256[] memory owed) {
        owed = new uint256[](pairs.length);
        for (uint256 i; i < pairs.length; ++i) {
            (owed[i],) = _claimableFees(pairs[i], who);
        }
    }

    /// @notice What `recipient` may claim from `pair`'s fee escrow with claimFees, and the escrow's
    ///         total liability: the sum across all recipients plus every trigger bounty still held
    ///         against an order, which every books-vs-cash figure reserves alongside the deposits
    ///         ledger and insurance.
    /// @dev Read through `extsload`: the owed balance at keccak256(recipient . SLOT_FEE_ESCROW_CLAIMABLE),
    ///      the total at SLOT_FEE_ESCROW_TOTAL.
    function claimableFees(address pair, address recipient) external view returns (uint256 owed, uint256 total) {
        return _claimableFees(pair, recipient);
    }

    function _claimableFees(address pair, address recipient) internal view returns (uint256 owed, uint256 total) {
        IBazaarPairLens p = IBazaarPairLens(pair);
        owed = uint256(p.extsload(keccak256(abi.encode(recipient, SLOT_FEE_ESCROW_CLAIMABLE))));
        total = uint256(p.extsload(bytes32(SLOT_FEE_ESCROW_TOTAL)));
    }

    /// @notice The pair's mark price at this block: its last stored price carried by the premium
    ///         the mark reads now, the premium funding is charged on. 0 before any qualifying
    ///         print has formed a mark.
    /// @dev The pair stores the mark as two tallies on one fading line, anchored at
    ///      auxState().lastMarkUpdateTs: the admitted prints' weighted notional
    ///      (auxState().rollingVolume) and that notional times each print's premium over the index
    ///      (the raw slot read here), both as the line's values at that anchor, which can predate
    ///      the last print (FundingLib.MarkState). The premium is the second over the larger of
    ///      the first and the floor the pair's open interest sets; this view evaluates it through
    ///      FundingLib.currentMark, as the pair's funding accrual evaluates the line.
    /// @param pair The pair
    /// @return The mark at this block, BAZAAR_SCALE precision
    function markPrice(address pair) external view returns (uint256) {
        IBazaarPairLens p = IBazaarPairLens(pair);
        BazaarTypes.AuxState memory aux = p.auxState();
        if (aux.lastMarkUpdateTs == 0) return 0;
        int256 premiumNotional = int256(uint256(p.extsload(bytes32(SLOT_MARK_PREMIUM_NOTIONAL))));
        (uint256 spot,,,,) = p.lastPairPrice();
        (uint256 longOI, uint256 shortOI,,,,, uint256 size,,,, bool isLong,,,,,,) = p.pairVault();
        uint256 floorVolume =
            FundingLib.floorVolumeOf(RiskParamsLib.openInterestSizeOf(longOI, shortOI, size, isLong), spot);
        return FundingLib.currentMark(premiumNotional, aux.rollingVolume, aux.lastMarkUpdateTs, floorVolume, spot);
    }

    /// @notice The mark-price constants, for showing how much of a resting order's fills would
    ///         enter the mark and how far a print can move it.
    /// @return makerExposureBlocks L2 blocks a maker must have rested at its current price and
    ///         size for a fill against it to enter the mark at full weight; a younger maker's
    ///         fill enters pro rata, one placed in the same block not at all
    /// @return volumeFloorBp The floor on the volume the premium is read over, in basis points of
    ///         per-side open-interest notional
    /// @return maxAlphaBp The most volume one matching call may add, in basis points of the volume
    ///         it is weighed against, so that no call moves the reading more than a quarter of the
    ///         way to its print
    /// @return maxMarkDeviationBp The band around the index a print is clamped to before its
    ///         premium enters the mark, in basis points
    /// @return markDecayPeriod Seconds over which the mark's tallies run from their anchor to
    ///         zero; a print moves the anchor toward the present only by its share of the volume
    function getMarkConstants()
        external
        pure
        returns (
            uint256 makerExposureBlocks,
            uint256 volumeFloorBp,
            uint256 maxAlphaBp,
            uint256 maxMarkDeviationBp,
            uint256 markDecayPeriod
        )
    {
        return (
            FundingLib.MAKER_EXPOSURE_BLOCKS,
            FundingLib.VOLUME_FLOOR_BP,
            FundingLib.MAX_ALPHA,
            FundingLib.MAX_MARK_DEVIATION_BP,
            FundingLib.MARK_DECAY_PERIOD
        );
    }

    /// @notice The pair's ADL epoch: advanced each time a window opens and on each mid-auction
    ///         re-target, the tag window deposits are ranked by.
    function adlEpoch(address pair) external view returns (uint64) {
        return uint64(uint256(IBazaarPairLens(pair).extsload(bytes32(SLOT_ADL_EPOCH))));
    }

    /// @notice The instant from which a timed-out ADL auction may terminate the pair; 0 while
    ///         unarmed.
    function adlTerminationTs(address pair) external view returns (uint256) {
        return uint256(IBazaarPairLens(pair).extsload(bytes32(SLOT_ADL_TERMINATION_TS)));
    }

    /// @notice A user's live Limit and StopLimit orders on `pair` — the entries of the pair's
    ///         active-order set that have neither expired nor reached a terminal state — with the
    ///         limit-priced notional of their live remainders on each side.
    /// @dev A read-only view of what the pair's own sweeps prune lazily: an expired or terminal
    ///      id still in the set is left out here and removed on-chain by the next sweep that
    ///      touches it. The exposure is not what the pair's gates reserve: creation, amendment
    ///      and withdrawal value a bid at the mark, an ask at the larger of its limit and the
    ///      mark, and a waiting StopLimit at the largest of its trigger, its limit and the mark,
    ///      and add the fill gate's debit across the set (CollateralLib._orderReserve).
    ///      getMaxWithdrawable applies the gates' rule.
    /// @param pair The pair
    /// @param user The order owner
    /// @return orderIds The live order ids, in set order
    /// @return count Their number (orderIds.length)
    /// @return longExposure Limit-priced remainder notional of the live long orders
    /// @return shortExposure Limit-priced remainder notional of the live short orders
    function getUserActiveLimitOrders(address pair, address user)
        external
        view
        returns (uint256[] memory orderIds, uint256 count, uint256 longExposure, uint256 shortExposure)
    {
        uint256[] memory all = _activeOrderIds(pair, user);
        orderIds = new uint256[](all.length);
        uint64 currentBlock = _l2Block();
        for (uint256 i; i < all.length; ++i) {
            (bool live, bool isLong,, uint256 notional) = _orderLeg(pair, all[i], currentBlock);
            if (!live) continue;
            orderIds[count++] = all[i];
            if (isLong) longExposure += notional;
            else shortExposure += notional;
        }
        // Shrink to the live entries.
        assembly ("memory-safe") {
            mstore(orderIds, count)
        }
    }

    /// @notice A user's live limit-order exposure per side on `pair`, as limit-priced notional and
    ///         as raw size.
    /// @dev Neither is what the pair's gates reserve, and the gates' figure cannot be rebuilt
    ///      from these: creation, amendment and withdrawal value a bid at the mark, an ask at the
    ///      larger of its limit and the mark, and a waiting StopLimit at the largest of its
    ///      trigger, its limit and the mark, and add the fill gate's debit across the set
    ///      (CollateralLib._orderReserve). getMaxWithdrawable applies that reservation.
    /// @param pair The pair
    /// @param user The order owner
    /// @return longExposure Limit-priced remainder notional of the live long orders
    /// @return shortExposure Limit-priced remainder notional of the live short orders
    /// @return longSize Remaining size of the live long orders
    /// @return shortSize Remaining size of the live short orders
    function outstandingOrderExposure(address pair, address user)
        external
        view
        returns (uint256 longExposure, uint256 shortExposure, uint256 longSize, uint256 shortSize)
    {
        return _outstandingOrderExposure(pair, user);
    }

    /// @dev The resting set as the pair's withdrawal gate reserves it, at the pair's stored spot:
    ///      per side, each live order at the price the pair values it at (a Limit bid at the spot,
    ///      a Limit ask at the larger of its limit and the spot, a waiting StopLimit at the largest
    ///      of its trigger, its limit and the spot), and the collateral the fill gate debits across
    ///      all of them ahead of its margin test, summed over both sides. An armed StopLimit (in
    ///      the book) is reserved as the Limit it now is; one still waiting is bounded by its
    ///      trigger (CollateralLib._fillDebitOf).
    function _restingReserve(address pair, address user)
        internal
        view
        returns (uint256 longExposure, uint256 shortExposure, uint256 fillDebit)
    {
        (uint256 spot,,,,) = IBazaarPairLens(pair).lastPairPrice();
        uint256[] memory all = _activeOrderIds(pair, user);
        uint64 currentBlock = _l2Block();
        for (uint256 i; i < all.length; ++i) {
            (bool live, bool isLong, uint256 remaining,) = _orderLeg(pair, all[i], currentBlock);
            if (!live) continue;
            (uint256 notional, uint256 debit) = _orderReserve(pair, all[i], isLong, remaining, spot);
            if (isLong) {
                longExposure += notional;
            } else {
                shortExposure += notional;
            }
            fillDebit += debit;
        }
    }

    /// @dev One live order's reserved notional and fill debit at `spot`, from the fields
    ///      _orderLeg does not carry.
    function _orderReserve(address pair, uint256 orderId, bool isLong, uint256 remaining, uint256 spot)
        internal
        view
        returns (uint256 notional, uint256 debit)
    {
        (,, uint8 otRaw,,,, address integrator,, bool inBook,, uint128 triggerPrice, uint128 limitPrice,,,,,,,,) =
            IBazaarPairLens(pair).orders(orderId);
        BazaarTypes.OrderType ot = inBook ? BazaarTypes.OrderType.Limit : BazaarTypes.OrderType(otRaw);
        uint256 valuation = spot;
        if (ot == BazaarTypes.OrderType.StopLimit) {
            if (triggerPrice > valuation) valuation = triggerPrice;
            if (limitPrice > valuation) valuation = limitPrice;
        } else if (!isLong && limitPrice > valuation) {
            valuation = limitPrice;
        }
        notional = Math.mulDiv(remaining, valuation, BAZAAR_SCALE);
        debit = CollateralLib._fillDebitOf(ot, isLong, remaining, limitPrice, triggerPrice, spot, integrator);
    }

    function _outstandingOrderExposure(address pair, address user)
        internal
        view
        returns (uint256 longExposure, uint256 shortExposure, uint256 longSize, uint256 shortSize)
    {
        uint256[] memory all = _activeOrderIds(pair, user);
        uint64 currentBlock = _l2Block();
        for (uint256 i; i < all.length; ++i) {
            (bool live, bool isLong, uint256 remaining, uint256 notional) = _orderLeg(pair, all[i], currentBlock);
            if (!live) continue;
            if (isLong) {
                longExposure += notional;
                longSize += remaining;
            } else {
                shortExposure += notional;
                shortSize += remaining;
            }
        }
    }

    /// @dev The ids in `user`'s active-order set, read through `extsload`: the set is an
    ///      EnumerableSet.UintSet, whose values array has its length at the mapping entry's slot
    ///      and its elements from keccak256 of that slot.
    function _activeOrderIds(address pair, address user) internal view returns (uint256[] memory ids) {
        IBazaarPairLens p = IBazaarPairLens(pair);
        bytes32 base = keccak256(abi.encode(user, SLOT_USER_ACTIVE_LIMIT_ORDERS));
        uint256 len = uint256(p.extsload(base));
        ids = new uint256[](len);
        uint256 data = uint256(keccak256(abi.encode(base)));
        for (uint256 i; i < len; ++i) {
            ids[i] = uint256(p.extsload(bytes32(data + i)));
        }
    }

    /// @dev One order's liveness and remaining leg, as the pair's exposure tally reads it: live
    ///      when neither canceled, filled nor past its expiry block.
    function _orderLeg(address pair, uint256 orderId, uint64 currentBlock)
        internal
        view
        returns (bool live, bool isLong, uint256 remaining, uint256 notional)
    {
        (
            ,
            uint64 canceledBlock,,
            bool long_,,,,
            uint64 expiryBlock,,,,
            uint128 limitPrice,
            uint128 size,
            uint128 filledSize,,
            uint64 filledBlock,,,,
        ) = IBazaarPairLens(pair).orders(orderId);
        if (canceledBlock != 0 || filledBlock != 0 || currentBlock > expiryBlock) return (false, long_, 0, 0);
        remaining = size - filledSize;
        notional = Math.mulDiv(remaining, limitPrice, BAZAAR_SCALE);
        return (true, long_, remaining, notional);
    }

    /// @dev The L2 block number, as the pair stamps and expires orders by.
    function _l2Block() internal view returns (uint64) {
        return uint64(IArbSys(address(0x64)).arbBlockNumber());
    }

    /// @notice The keeper bounty a trigger order still holds in `pair`'s fee escrow: what the
    ///         executions that finish it will earn between them. Zero for an order that never
    ///         carried one, and once the last of it has been paid out or refunded.
    /// @dev Read from the escrow's per-order mapping through `extsload`, at the slot
    ///      keccak256(orderId . SLOT_TRIGGER_BOUNTY).
    function triggerBounty(address pair, uint256 orderId) external view returns (uint256) {
        return uint256(IBazaarPairLens(pair).extsload(keccak256(abi.encode(orderId, SLOT_TRIGGER_BOUNTY))));
    }

    // ---- Order book views ----

    /// @dev limitPrice + book links of one order, read through the pair's public getter.
    function _bookNode(address pair, uint64 id) internal view returns (uint256 price, uint64 next) {
        (,,,,,,,,,,, uint128 p,,,,,,,, uint48 nxt) = IBazaarPairLens(pair).orders(id);
        return (uint256(p), nxt);
    }

    /// @notice Head-to-tail page of one book side, for depth displays and hint computation.
    /// @param startId 0 = start at the side's head; otherwise resume from this order.
    /// @param maxN Maximum nodes returned.
    /// @return orderIds The visited orders in book order (array length = nodes actually visited).
    /// @return prices Their limit prices.
    /// @return nextId 0 when the side is exhausted; otherwise pass it as the next page's startId.
    function getBookDepth(address pair, bool isLong, uint64 startId, uint256 maxN)
        external
        view
        returns (uint256[] memory orderIds, uint256[] memory prices, uint64 nextId)
    {
        (uint64 bidHead, uint64 askHead,,) = IBazaarPairLens(pair).book();
        uint64 cur = startId != 0 ? startId : (isLong ? bidHead : askHead);
        uint256[] memory ids = new uint256[](maxN);
        uint256[] memory pxs = new uint256[](maxN);
        uint256 n;
        while (cur != 0 && n < maxN) {
            (uint256 p, uint64 nxt) = _bookNode(pair, cur);
            ids[n] = cur;
            pxs[n] = p;
            unchecked {
                ++n;
            }
            cur = nxt;
        }
        // Truncate both arrays to the visited count (shrinking a length in place is memory-safe).
        assembly ("memory-safe") {
            mstore(ids, n)
            mstore(pxs, n)
        }
        return (ids, pxs, cur);
    }

    /// @notice Packs one amendment's id word for BazaarPair.amendOrders: the order id in the low
    ///         64 bits and up to two predecessor hints above it — the order to rest directly
    ///         behind at the new price, as findPredecessor reports it, 0 for none. A requote by a
    ///         few ticks needs no hint; a jump across the book does.
    function amendIdWord(uint64 orderId, uint64 pred, uint64 pred2) external pure returns (uint256) {
        return uint256(orderId) | (uint256(pred) << 64) | (uint256(pred2) << 128);
    }

    /// @notice Hint helper for MatchHints.pred: the orderId an order entering the book at
    ///         limitPrice should rest directly behind on its side (0 = it belongs at the head).
    ///         Whatever enters — a new order, an amended one, or a StopLimit a keeper arms — takes
    ///         a queue position later than every resting order's, so equal prices queue it last.
    /// @param startId 0 = walk from the side's head; otherwise resume from this order.
    /// @param maxIter Node budget for this call.
    /// @return pred The predecessor when `found`, else the last node visited (resume point).
    /// @return found False when the budget ran out before the position was reached — call again
    ///         with startId = pred.
    function findPredecessor(address pair, bool isLong, uint256 limitPrice, uint64 startId, uint256 maxIter)
        external
        view
        returns (uint64 pred, bool found)
    {
        (uint64 bidHead, uint64 askHead,,) = IBazaarPairLens(pair).book();
        uint64 cur = startId != 0 ? startId : (isLong ? bidHead : askHead);
        pred = startId;
        for (uint256 i; i < maxIter; ++i) {
            if (cur == 0) return (pred, true); // tail reached: rest behind the last node
            (uint256 p,) = _bookNode(pair, cur);
            // Strictly better-priced nodes stay ahead; equal price keeps FIFO (the entrant is newest).
            bool nodeFirst = isLong ? p >= limitPrice : p <= limitPrice;
            if (!nodeFirst) return (pred, true);
            pred = cur;
            (, cur) = _bookNode(pair, cur);
        }
        return (pred, false);
    }

    // ---- Auxiliary BazaarPair state forwarders ----

    /// @notice Returns the full auxiliary state struct (funding/mark/ADL/termination/warmup vars).
    function getAuxState(address pair) external view returns (BazaarTypes.AuxState memory) {
        return IBazaarPairLens(pair).auxState();
    }
}
