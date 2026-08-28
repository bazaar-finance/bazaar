// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./libraries/BazaarTypes.sol";
import {BucketLib} from "./libraries/BucketLib.sol";
import {MetaTxLib} from "./libraries/MetaTxLib.sol";
import {CollateralLib} from "./libraries/CollateralLib.sol";
import {InsuranceVaultLib} from "./libraries/InsuranceVaultLib.sol";
import {VaultHealthLib} from "./libraries/VaultHealthLib.sol";
import {AdlLib} from "./libraries/AdlLib.sol";

/// @title IBazaarPairLens
/// @notice Minimal interface for reading BazaarPair state
interface IBazaarPairLens {
    function positionBuckets(address user)
        external
        view
        returns (
            bool isLong,
            uint256 size,
            uint256 entryValue,
            uint256 collateral,
            int256 entryFundingIndex,
            uint256 takeProfitOrderId,
            uint256 stopLossOrderId,
            uint256 entryMmrBp,
            uint256 mmrUpdateTs
        );
    function currentFundingIndex() external view returns (int256);
    function marginRequirements()
        external
        view
        returns (uint256 imrBp, uint256 mmrBp, uint256 lastUpdateTs, uint256 laggedMmrBp);
    function getLaggedMmrBp() external view returns (uint256);
    function isContinuouslyTraded() external view returns (bool);
    function pairId() external view returns (bytes32);
    function insuranceShares(address user) external view returns (uint256);
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
            uint256 deficit
        );
    function isAdlPending() external view returns (bool);
    function adlPendingSince() external view returns (uint256);
    function adlScoreDeposit(address user) external view returns (uint256);
    function terminalProfitClaim(address user) external view returns (uint256);
    function fixedSettlementPrice() external view returns (uint256);
    function settlementPriceFixedTs() external view returns (uint256);
    function isPairTerminatedEmergency() external view returns (bool);
    function outstandingOrderExposure(address user) external view returns (uint256 longExposure, uint256 shortExposure);
    function auxState() external view returns (BazaarTypes.AuxState memory);
    function book() external view returns (uint64 bidHead, uint64 askHead, uint64 bidCount, uint64 askCount);
    function orders(uint256 orderId)
        external
        view
        returns (
            address creator,
            address integrator,
            uint256 triggerPrice,
            uint256 limitPrice,
            uint256 maxSlippageBp,
            uint256 size,
            uint256 filledSize,
            uint8 orderType,
            bool isLong,
            bool isPostOnly,
            bool isIoc,
            bool inBook,
            uint64 creationBlock,
            uint64 expiryBlock,
            uint64 canceledBlock,
            uint64 filledBlock,
            uint64 prevInBook,
            uint64 nextInBook
        );
}

/// @title BazaarPairLens
/// @notice Read-only companion contract for BazaarPair.
///         Provides computed views without adding to BazaarPair's bytecode.
contract BazaarPairLens {
    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;

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
        (marginReqs.imrBp, marginReqs.mmrBp, marginReqs.lastUpdateTs,) = IBazaarPairLens(pair).marginRequirements();
        // Use the live 24h-lagged MMR so this view matches what liquidate() and the matching
        // walk apply on-chain; without it, an old position would display against entryMmrBp.
        marginReqs.laggedMmrBp = IBazaarPairLens(pair).getLaggedMmrBp();

        result = BucketLib.calculateState(bucket, currentPrice, fundingIdx, marginReqs);
    }

    /// @notice Returns the current insurance share price
    function getInsuranceSharePrice(address pair) external view returns (uint256) {
        uint256 totalShares = IBazaarPairLens(pair).totalInsuranceShares();
        if (totalShares == 0) return BAZAAR_SCALE;
        (,,,,, uint256 insuranceFundBalance,,,,,,) = IBazaarPairLens(pair).pairVault();
        return (insuranceFundBalance * BAZAAR_SCALE) / totalShares;
    }

    /// @notice Returns the current USDC value of a depositor's insurance shares
    function getInsuranceDepositValue(address pair, address user) external view returns (uint256 value) {
        uint256 totalShares = IBazaarPairLens(pair).totalInsuranceShares();
        if (totalShares == 0) return 0;
        uint256 userShares = IBazaarPairLens(pair).insuranceShares(user);
        (,,,,, uint256 insuranceFundBalance,,,,,,) = IBazaarPairLens(pair).pairVault();
        value = Math.mulDiv(userShares, insuranceFundBalance, totalShares);
    }

    /// @notice Returns the current ADL score threshold
    /// @dev Delegates the decay math to AdlLib._getAdlScoreThreshold (inlined internal library
    ///      function) so the lens can never drift from the on-chain auction curve.
    function getAdlScoreThreshold(address pair) external view returns (uint256) {
        bool adlPending = IBazaarPairLens(pair).isAdlPending();
        uint256 pendingSince = IBazaarPairLens(pair).adlPendingSince();
        if (!adlPending || pendingSince == 0) return type(uint256).max;
        return AdlLib._getAdlScoreThreshold(pendingSince);
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
        (marginReqs.imrBp, marginReqs.mmrBp, marginReqs.lastUpdateTs,) = IBazaarPairLens(pair).marginRequirements();
        marginReqs.laggedMmrBp = IBazaarPairLens(pair).getLaggedMmrBp();

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
        eligible = adlScore >= AdlLib._getAdlScoreThreshold(IBazaarPairLens(pair).adlPendingSince());
    }

    /// @notice A user's terminal-settlement entitlement components after a normal termination:
    ///         what a withdrawal would pay out, decomposed. Total ≈ collateral + claimPayout.
    /// @dev claimPayout uses the frozen ratio from auxState, which is 0 until finalizeTermination
    ///      runs — during the 48h window the claim is registered but its payout is not yet fixed
    ///      (profitRatioBp == 0 here means "not frozen yet", not "worthless"). An unsettled
    ///      position's PnL is NOT included: it becomes a claim (window) or a surplus-clipped
    ///      junior credit (post-finalize) only when the position is settled. In the deep-
    ///      insolvency black-swan case a pro-rata principal haircut can additionally reduce
    ///      collateral at first withdrawal.
    /// @param pair The BazaarPair to read
    /// @param user The account to query
    /// @return collateral The user's current bucket collateral (principal, reserved at all times)
    /// @return registeredClaim The user's registered profit claim (winner PnL settled during the
    ///         window, plus any settlement bounties received as claim transfers)
    /// @return profitRatioBp The frozen pro-rata payout ratio (0 before finalize)
    /// @return claimPayout registeredClaim x profitRatioBp — the cash the claim redeems for
    function getTerminalEntitlement(address pair, address user)
        external
        view
        returns (uint256 collateral, uint256 registeredClaim, uint256 profitRatioBp, uint256 claimPayout)
    {
        (,,, collateral,,,,,) = IBazaarPairLens(pair).positionBuckets(user);
        registeredClaim = IBazaarPairLens(pair).terminalProfitClaim(user);
        profitRatioBp = IBazaarPairLens(pair).auxState().normalTerminalWinnersPayoutRatioBp;
        claimPayout = Math.mulDiv(registeredClaim, profitRatioBp, BazaarTypes.BP_SCALE);
    }

    /// @notice The bounty a keeper earns for settling `user` through liquidate() while the pair
    ///         is in terminal-settlement mode, computed with the on-chain formula
    ///         (CollateralLib._bountyFor at the fixed settlement price).
    /// @dev How the bounty is funded follows the position's post-settlement state: cash from its
    ///      remaining collateral first, then a claim transfer out of a winner's registered
    ///      profit, then insurance-if-covered for positions with neither.
    /// @param pair The BazaarPair to read
    /// @param user The candidate position
    /// @return bounty The reward in BAZAAR (1e18) precision; 0 when there is nothing to settle
    /// @return settleable True when settlement mode is active (price fixed) and the user has an
    ///         open position
    function getTerminalSettlementBounty(address pair, address user)
        external
        view
        returns (uint256 bounty, bool settleable)
    {
        if (IBazaarPairLens(pair).settlementPriceFixedTs() == 0) return (0, false);
        (, uint256 size,,,,,,,) = IBazaarPairLens(pair).positionBuckets(user);
        if (size == 0) return (0, false);
        return (CollateralLib._bountyFor(size, IBazaarPairLens(pair).fixedSettlementPrice()), true);
    }

    /// @notice The largest collateral withdrawal that would succeed for `user` right now, under
    ///         the same checks the normal-operation withdrawal path enforces.
    /// @dev Previews the FRESH-price path. While the pair's price is stale, a position holder's
    ///      withdrawal reverts outright (CollateralLib__WithdrawalRequiresFreshPrice) regardless
    ///      of the bound returned here; flat and order-only accounts are unaffected.
    ///      Normal operation only: returns 0 while withdrawals are frozen or rerouted — terminal
    ///      settlement mode (price fixed; post-termination entitlements are the
    ///      getTerminalEntitlement / emergency-ratio domain), emergency termination, ADL pending
    ///      for a position holder, or an insolvent position. For a position holder the bound is
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
        if (IBazaarPairLens(pair).settlementPriceFixedTs() != 0 || IBazaarPairLens(pair).isPairTerminatedEmergency()) return 0;

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

        (uint256 longExposure, uint256 shortExposure) = IBazaarPairLens(pair).outstandingOrderExposure(user);

        BazaarTypes.MarginRequirements memory marginReqs;
        (marginReqs.imrBp, marginReqs.mmrBp, marginReqs.lastUpdateTs,) = IBazaarPairLens(pair).marginRequirements();
        marginReqs.laggedMmrBp = IBazaarPairLens(pair).getLaggedMmrBp();

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
        uint256 floorRateBp =
            IBazaarPairLens(pair).isContinuouslyTraded() ? marginReqs.mmrBp : marginReqs.imrBp;
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
    function getPendingLiquidationExposure(address pair)
        external
        view
        returns (
            uint256 pendingLiqSize,
            uint256 pendingLiqEntryNotional,
            uint256 pendingLiqBankruptcyNotional,
            bool pendingLiqIsLong
        )
    {
        (
            ,,,,,, pendingLiqSize, pendingLiqEntryNotional, pendingLiqBankruptcyNotional,, pendingLiqIsLong,
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

    /// @notice Returns insurance withdrawal timing constants
    function getInsuranceWithdrawalConstants()
        external
        pure
        returns (
            uint256 cooldown,
            uint256 window,
            uint256 rateLimitPeriod,
            uint256 rateLimitBp,
            uint256 aboveTargetRateLimitBp,
            uint256 aboveTargetFundCapBp
        )
    {
        return (
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN,
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_WINDOW,
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD,
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_BP,
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_RATE_LIMIT_BP,
            InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_FUND_CAP_BP
        );
    }

    /// @notice Returns vault health / ADL threshold constants
    function getVaultHealthConstants()
        external
        pure
        returns (
            uint256 adlTriggerThresholdBp,
            uint256 adlCancelThresholdBp,
            uint256 adlTimeoutDuration,
            uint256 maxAdlWinnersPerBatch
        )
    {
        return (
            VaultHealthLib.ADL_TRIGGER_THRESHOLD_BP,
            VaultHealthLib.ADL_CANCEL_THRESHOLD_BP,
            VaultHealthLib.ADL_TIMEOUT_DURATION,
            AdlLib.MAX_ADL_WINNERS_PER_BATCH
        );
    }


    /// @notice Returns the keeper reward constants shared by live liquidation and terminal
    ///         settlement: reward = max(minReward, notional * feeEbp / ebpScale).
    function getLiquidationRewardConstants()
        external
        pure
        returns (uint256 minReward, uint256 feeEbp, uint256 ebpScale)
    {
        return (BazaarTypes.MIN_LIQUIDATOR_REWARD, BazaarTypes.LIQUIDATION_FEE_EBP, BazaarTypes.EBP_SCALE);
    }

    // ---- Order book views ----

    /// @dev limitPrice + book links of one order, read through the pair's public getter.
    function _bookNode(address pair, uint64 id) internal view returns (uint256 price, uint64 next) {
        (,,, uint256 p,,,,,,,,,,,,,, uint64 nxt) = IBazaarPairLens(pair).orders(id);
        return (p, nxt);
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
