// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "./libraries/BazaarTypes.sol";
import {BucketLib} from "./libraries/BucketLib.sol";
import {MetaTxLib} from "./libraries/MetaTxLib.sol";
import {OrderManagementLib} from "./libraries/OrderManagementLib.sol";
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
            uint256 activeMarketOrderId,
            uint256 mmrUpdateTs
        );
    function currentFundingIndex() external view returns (int256);
    function marginRequirements()
        external
        view
        returns (uint256 imrBp, uint256 mmrBp, uint256 lastUpdateTs, uint256 laggedMmrBp);
    function getLaggedMmrBp() external view returns (uint256);
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
    function auxState() external view returns (BazaarTypes.AuxState memory);
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
            bucket.activeMarketOrderId,
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
            bucket.activeMarketOrderId,
            bucket.mmrUpdateTs
        ) = IBazaarPairLens(pair).positionBuckets(user);

        int256 fundingIdx = IBazaarPairLens(pair).currentFundingIndex();

        BazaarTypes.MarginRequirements memory marginReqs;
        (marginReqs.imrBp, marginReqs.mmrBp, marginReqs.lastUpdateTs,) = IBazaarPairLens(pair).marginRequirements();
        // Use the live 24h-lagged MMR so this view matches what liquidate()/matchBatch() apply
        // on-chain; without it, an old position would display against entryMmrBp instead.
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
        returns (uint64 minOrderLifetimeBlocks, uint64 marketOrderLifetimeBlocks, uint64 maxOrderLifetimeBlocks)
    {
        return (
            BazaarTypes.MIN_ORDER_LIFETIME_BLOCKS,
            BazaarTypes.MARKET_ORDER_LIFETIME_BLOCKS,
            BazaarTypes.MAX_ORDER_LIFETIME_BLOCKS
        );
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

    /// @notice Returns the flat sequencer fee per side
    function getSequencerFlatFeePerSide() external pure returns (uint256) {
        return BazaarTypes.SEQUENCER_FLAT_FEE_PER_SIDE;
    }

    // ---- Auxiliary BazaarPair state forwarders ----

    /// @notice Returns the full auxiliary state struct (funding/mark/ADL/termination/warmup vars).
    function getAuxState(address pair) external view returns (BazaarTypes.AuxState memory) {
        return IBazaarPairLens(pair).auxState();
    }
}
