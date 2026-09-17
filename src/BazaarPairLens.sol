// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./libraries/BazaarTypes.sol";
import {BucketLib} from "./libraries/BucketLib.sol";
import {MetaTxLib} from "./libraries/MetaTxLib.sol";
import {CollateralLib} from "./libraries/CollateralLib.sol";
import {InsuranceVaultLib} from "./libraries/InsuranceVaultLib.sol";
import {RiskParamsLib} from "./libraries/RiskParamsLib.sol";
import {VaultHealthLib} from "./libraries/VaultHealthLib.sol";
import {AdlLib} from "./libraries/AdlLib.sol";

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
            uint64 stopLossOrderId,
            uint32 entryMmrBp,
            uint64 mmrUpdateTs
        );
    function currentFundingIndex() external view returns (int256);
    function lastPairPrice()
        external
        view
        returns (uint256 spotPrice, uint256 emaVarianceBp, uint256 updateTs, uint256 lowPrice, uint256 highPrice);
    function marginRequirements()
        external
        view
        returns (uint256 imrBp, uint256 mmrBp, uint256 lastUpdateTs, uint256 laggedMmrBp, uint256 laggedMmrTs);
    function getLaggedMmr() external view returns (uint256 mmrBp, uint256 sampleTs);
    function isContinuouslyTraded() external view returns (bool);
    function pairId() external view returns (bytes32);
    function insuranceShares(address user) external view returns (uint256);
    function claimableFees(address recipient) external view returns (uint256 owed, uint256 total);
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
            uint256 pendingLiqSeized
        );
    function isAdlPending() external view returns (bool);
    function adlPendingSince() external view returns (uint256);
    function adlAuctionStartTs() external view returns (uint256);
    function adlScoreDeposit(address user) external view returns (uint256);
    function terminalProfitClaim(address user) external view returns (uint256);
    function fixedSettlementPrice() external view returns (uint256);
    function settlementPriceFixedTs() external view returns (uint256);
    function outstandingOrderExposure(address user)
        external
        view
        returns (uint256 longExposure, uint256 shortExposure, uint256 longSize, uint256 shortSize);
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
            uint64 creationBlock,
            uint64 filledBlock,
            uint64 prevInBook,
            uint64 nextInBook
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
            bucket.stopLossOrderId,
            bucket.entryMmrBp,
            bucket.mmrUpdateTs
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
            bucket.stopLossOrderId,
            bucket.entryMmrBp,
            bucket.mmrUpdateTs
        ) = IBazaarPairLens(pair).positionBuckets(user);

        int256 fundingIdx = IBazaarPairLens(pair).currentFundingIndex();

        BazaarTypes.MarginRequirements memory marginReqs;
        (marginReqs.imrBp, marginReqs.mmrBp, marginReqs.lastUpdateTs,,) = IBazaarPairLens(pair).marginRequirements();
        // Use the pair's own lagged MMR so this view applies the threshold liquidate() and the
        // matching walk apply on-chain; without it, an old position would display against
        // entryMmrBp. The sample timestamp comes with it because effectiveMmr adopts the lagged
        // rate only for positions stamped at or before that sample. The pair measures the grace
        // period back from its stored mark, so a caller passing a currentPrice newer than that
        // mark is describing two instants at once: the threshold shifts to match once their own
        // price update actually lands.
        (marginReqs.laggedMmrBp, marginReqs.laggedMmrTs) = IBazaarPairLens(pair).getLaggedMmr();

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

    /// @dev Free capital, the raw balance and the inventory size, read from the pair's vault.
    function _insuranceFund(address pair) internal view returns (uint256 free, uint256 fund, uint256 inventory) {
        (,,,,, uint256 balance, uint256 size,,,,,,, uint256 seized) = IBazaarPairLens(pair).pairVault();
        free = balance > seized ? balance - seized : 0;
        fund = balance;
        inventory = size;
    }

    /// @dev The inventory's net position at `price` and the reserve the unload walk keeps, read
    ///      from the pair's vault: the two mark-dependent inputs of the share-pricing bases.
    function _inventoryNetAndReserve(address pair, uint256 price) internal view returns (int256 net, uint256 reserve) {
        (
            uint256 longOI,
            uint256 shortOI,,,,,
            uint256 size,
            uint256 entryNotional,,
            int256 entryFundingIndex,
            bool isLong,,
            uint256 targetInsuranceRatioBp,
            uint256 seized
        ) = IBazaarPairLens(pair).pairVault();
        net = int256(seized)
            + RiskParamsLib.inventoryPnl(
                size, entryNotional, entryFundingIndex, isLong, price, IBazaarPairLens(pair).currentFundingIndex()
            );
        reserve = RiskParamsLib.adlReserveOf(
            RiskParamsLib.openInterestSizeOf(longOI, shortOI, size, isLong), price, targetInsuranceRatioBp
        );
    }

    /// @dev The basis a redemption is priced against at `price` (RiskParamsLib.insuranceRedemptionBasis).
    function _redemptionBasis(address pair, uint256 price) internal view returns (uint256) {
        (uint256 free,, uint256 inventory) = _insuranceFund(pair);
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
    ///         per-user rate limit) and its freshness requirement — quote against a live price,
    ///         since the pair refuses a stale one while the vault holds inventory.
    /// @param pair The pair
    /// @param amount Deposit amount in BAZAAR precision
    /// @param price The mark the vault's inventory would be valued at (BAZAAR_SCALE precision)
    /// @return Shares the deposit would mint
    function quoteInsuranceDeposit(address pair, uint256 amount, uint256 price) external view returns (uint256) {
        (uint256 free, uint256 fund, uint256 inventory) = _insuranceFund(pair);
        uint256 basis = free;
        if (inventory != 0) {
            (int256 net, uint256 reserve) = _inventoryNetAndReserve(pair, price);
            basis = RiskParamsLib.insuranceNavOf(free, net, reserve);
        }
        return InsuranceVaultLib.sharesForDeposit(amount, IBazaarPairLens(pair).totalInsuranceShares(), fund, basis);
    }

    /// @notice USDC (BAZAAR precision) a redemption of `shareAmount` would pay if the pair
    ///         resolved `price` as the mark. 0 while no shares exist, and 0 where the redemption
    ///         would revert for a fund whose value at the mark is nil. Ignores the redemption's
    ///         own gates (cooldown, window, health, rate limit).
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

    /// @notice ADL auction score for `user`, computed with the same inputs the on-chain ranking
    ///         uses: PnL at the frozen snapshot (price + funding index) over the window-deposit-
    ///         adjusted collateral (AdlLib._scoreCollateral). Keepers sort executeAdl candidates
    ///         by this score DESCENDING — a submission that disagrees with it reverts on-chain
    ///         (AdlLib__NotDescendingAdlScoreOrder).
    /// @param pair The BazaarPair to read
    /// @param user The candidate winner
    /// @return adlScore The ranking score; 0 when the user cannot be a candidate at all (no ADL
    ///         pending, flat, wrong side, or non-positive snapshot PnL)
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
            bucket.stopLossOrderId,
            bucket.entryMmrBp,
            bucket.mmrUpdateTs
        ) = IBazaarPairLens(pair).positionBuckets(user);
        if (bucket.size == 0 || bucket.isLong != aux.adlLongs) return (0, false);

        BazaarTypes.MarginRequirements memory marginReqs;
        (marginReqs.imrBp, marginReqs.mmrBp, marginReqs.lastUpdateTs,,) = IBazaarPairLens(pair).marginRequirements();
        (marginReqs.laggedMmrBp, marginReqs.laggedMmrTs) = IBazaarPairLens(pair).getLaggedMmr();

        // Rank at the frozen snapshot, exactly like AdlLib's scan pass — the live price and
        // funding index play no part in queue position.
        BazaarTypes.BucketState memory state =
            BucketLib.calculateState(bucket, aux.adlSnapshotPrice, aux.adlSnapshotFundingIndex, marginReqs);
        if (state.totalPnl <= 0) return (0, false);

        adlScore = Math.mulDiv(
            uint256(state.totalPnl),
            BAZAAR_SCALE,
            AdlLib._scoreCollateral(state.effectiveCollateral, IBazaarPairLens(pair).adlScoreDeposit(user))
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
    ///      100% only when cash could not cover principal.
    /// @param pair The BazaarPair to read
    /// @param user The account to query
    /// @return collateral The user's current bucket collateral
    /// @return registeredClaim The user's registered profit claim
    /// @return principalRatioBp Cash paid per unit of collateral (0 before finalize)
    /// @return profitRatioBp Cash paid per unit of registered claim (0 before finalize)
    /// @return payout collateral x principalRatioBp + registeredClaim x profitRatioBp
    function getTerminalEntitlement(address pair, address user)
        external
        view
        returns (
            uint256 collateral,
            uint256 registeredClaim,
            uint256 principalRatioBp,
            uint256 profitRatioBp,
            uint256 payout
        )
    {
        (,,, collateral,,,,,) = IBazaarPairLens(pair).positionBuckets(user);
        registeredClaim = IBazaarPairLens(pair).terminalProfitClaim(user);
        BazaarTypes.AuxState memory aux = IBazaarPairLens(pair).auxState();
        principalRatioBp = aux.terminalPrincipalRatioBp;
        profitRatioBp = aux.terminalProfitRatioBp;
        payout = Math.mulDiv(collateral, principalRatioBp, BazaarTypes.BP_SCALE)
            + Math.mulDiv(registeredClaim, profitRatioBp, BazaarTypes.BP_SCALE);
    }

    /// @notice The largest collateral withdrawal that would succeed for `user` right now, under
    ///         the same checks the normal-operation withdrawal path enforces.
    /// @dev Previews the FRESH-price path. While the pair's price is stale, a position holder's
    ///      withdrawal reverts outright (CollateralLib__WithdrawalRequiresFreshPrice) regardless
    ///      of the bound returned here; flat and order-only accounts are unaffected.
    ///      Normal operation only: returns 0 while withdrawals are frozen or rerouted — terminal
    ///      settlement mode (price fixed; post-termination entitlements are the
    ///      getTerminalEntitlement domain), ADL pending for a position holder, or an insolvent
    ///      position. For a position holder the bound is
    ///      the tightest of: raw collateral, the retained-collateral floor (position notional x
    ///      mmrBp for continuously traded pairs / imrBp for session-bound pairs, held in
    ///      collateral proper), and the equity
    ///      the IMR leaves free, where worst-case notional folds in resting-order exposure
    ///      (CollateralLib._worstCaseNotional) — each exactly as the on-chain check applies it.
    ///      A flat user is bounded by collateral less the order-IMR reserve on their larger
    ///      resting side. Evaluated at the pair's stored funding index.
    /// @param pair The BazaarPair to read
    /// @param user The account to query
    /// @param currentPrice The price to evaluate at (BAZAAR 1e18). Pass the CONSERVATIVE bracket
    ///        the withdrawal path itself applies: spot − confidence for a long, spot + confidence
    ///        for a short (a flat user's order check uses spot, and this parameter is ignored).
    ///        Passing plain spot for a position holder overstates the bound by the confidence
    ///        band and the on-chain check will reject the difference.
    /// @return maxAmount The largest amount `withdrawCollateral` would accept, in BAZAAR (1e18)
    function getMaxWithdrawable(address pair, address user, uint256 currentPrice)
        external
        view
        returns (uint256 maxAmount)
    {
        if (IBazaarPairLens(pair).settlementPriceFixedTs() != 0) return 0;

        BazaarTypes.PositionBucket memory bucket;
        (
            bucket.isLong,
            bucket.size,
            bucket.entryValue,
            bucket.collateral,
            bucket.entryFundingIndex,
            bucket.takeProfitOrderId,
            bucket.stopLossOrderId,
            bucket.entryMmrBp,
            bucket.mmrUpdateTs
        ) = IBazaarPairLens(pair).positionBuckets(user);

        (uint256 longExposure, uint256 shortExposure, uint256 longSize, uint256 shortSize) =
            IBazaarPairLens(pair).outstandingOrderExposure(user);
        // Mirror the withdrawal gate: order exposure is reserved at no less than the mark.
        {
            uint256 atMark = Math.mulDiv(longSize, currentPrice, BazaarTypes.BAZAAR_SCALE);
            if (atMark > longExposure) longExposure = atMark;
            atMark = Math.mulDiv(shortSize, currentPrice, BazaarTypes.BAZAAR_SCALE);
            if (atMark > shortExposure) shortExposure = atMark;
        }

        BazaarTypes.MarginRequirements memory marginReqs;
        (marginReqs.imrBp, marginReqs.mmrBp, marginReqs.lastUpdateTs,,) = IBazaarPairLens(pair).marginRequirements();
        (marginReqs.laggedMmrBp, marginReqs.laggedMmrTs) = IBazaarPairLens(pair).getLaggedMmr();

        if (bucket.size == 0) {
            // Flat: collateral less the order-IMR reserve on the larger resting side
            // (zero position notional reduces _worstCaseNotional to exactly that max).
            uint256 orderImrReq = Math.mulDiv(
                marginReqs.imrBp,
                CollateralLib._worstCaseNotional(true, 0, longExposure, shortExposure),
                BazaarTypes.BP_SCALE
            );
            return bucket.collateral > orderImrReq ? bucket.collateral - orderImrReq : 0;
        }

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

        // Ceiling 3: the equity the IMR leaves free.
        uint256 imrRequirement = Math.mulDiv(
            marginReqs.imrBp,
            CollateralLib._worstCaseNotional(bucket.isLong, state.currentNotional, longExposure, shortExposure),
            BazaarTypes.BP_SCALE
        );
        uint256 imrSlack = state.availableEquity > imrRequirement ? state.availableEquity - imrRequirement : 0;
        if (imrSlack < maxAmount) maxAmount = imrSlack;
    }

    /// @notice Returns pending liquidation exposure (single-direction aggregate)
    /// @dev Includes the entry funding index so a caller can reproduce the vault PnL the
    ///      protocol itself values this inventory at — price leg against `pendingLiqEntryNotional`
    ///      plus the funding leg from `pendingLiqEntryFundingIndex` to the pair's live index.
    ///      Without it only the price half is derivable, and a reader would systematically
    ///      understate the fund's claim on a vault holding the funding-paying side.
    function getPendingLiquidationExposure(address pair)
        external
        view
        returns (
            uint256 pendingLiqSize,
            uint256 pendingLiqEntryNotional,
            uint256 pendingLiqBankruptcyNotional,
            int256 pendingLiqEntryFundingIndex,
            bool pendingLiqIsLong
        )
    {
        (
            ,,,,,,
            pendingLiqSize,
            pendingLiqEntryNotional,
            pendingLiqBankruptcyNotional,
            pendingLiqEntryFundingIndex,
            pendingLiqIsLong,,,
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
            bytes32 requestInsuranceWithdrawal
        )
    {
        return (
            MetaTxLib.DEPOSIT_COLLATERAL_TYPEHASH,
            MetaTxLib.WITHDRAW_COLLATERAL_TYPEHASH,
            MetaTxLib.DEPOSIT_TO_INSURANCE_TYPEHASH,
            MetaTxLib.EXECUTE_INSURANCE_WITHDRAWAL_TYPEHASH,
            MetaTxLib.CREATE_ORDER_TYPEHASH,
            MetaTxLib.CANCEL_ORDERS_TYPEHASH,
            MetaTxLib.REQUEST_INSURANCE_WITHDRAWAL_TYPEHASH
        );
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

    /// @notice Returns the per-position liquidator reward constants: reward =
    ///         max(minReward, notional * feeEbp / ebpScale), debited from insurance at
    ///         liquidation time and accrued to the liquidator's claimable balance.
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
            (owed[i],) = IBazaarPairLens(pairs[i]).claimableFees(who);
        }
    }

    // ---- Order book views ----

    /// @dev limitPrice + book links of one order, read through the pair's public getter.
    function _bookNode(address pair, uint64 id) internal view returns (uint256 price, uint64 next) {
        (,,,,,,,,,,, uint128 p,,,,,, uint64 nxt) = IBazaarPairLens(pair).orders(id);
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

    /// @notice Hint helper for MatchHints.pred: the orderId a new (limitPrice, orderId) entry
    ///         should rest directly behind on its side (0 = it belongs at the head). The new
    ///         order's id is always larger than every resting id, so equal prices queue it last.
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
            // Strictly better-priced nodes stay ahead; equal price keeps FIFO (new id is newest).
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
