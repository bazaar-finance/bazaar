// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

// -------------------- Imports --------------------
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarOracle} from "./BazaarOracle.sol";
import {BazaarSequencer} from "./BazaarSequencer.sol";
import {BazaarTypes} from "./libraries/BazaarTypes.sol";
import {BazaarMathLib} from "./libraries/BazaarMathLib.sol";
import {BucketLib} from "./libraries/BucketLib.sol";
import {MmrSampleLib} from "./libraries/MmrSampleLib.sol";
import {MatchingEngineLib} from "./libraries/MatchingEngineLib.sol";
import {OrderManagementLib} from "./libraries/OrderManagementLib.sol";
import {CollateralLib} from "./libraries/CollateralLib.sol";
import {LiquidationLib} from "./libraries/LiquidationLib.sol";
import {InsuranceVaultLib} from "./libraries/InsuranceVaultLib.sol";
import {AdlLib} from "./libraries/AdlLib.sol";
import {VaultHealthLib} from "./libraries/VaultHealthLib.sol";
import {MetaTxLib} from "./libraries/MetaTxLib.sol";
import {RiskParamsLib} from "./libraries/RiskParamsLib.sol";
import {FundingLib} from "./libraries/FundingLib.sol";
import {TerminationLib} from "./libraries/TerminationLib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IArbSys} from "./interfaces/IArbSys.sol";

// -------------------- Minimal IBazaarTerminator --------------------
interface IBazaarTerminator {
    function getLockedShares(address pair, address user) external view returns (uint256);
}

/**
 * @title Bazaar
 * @notice This contract allows users to enter long/short perpetual bets on the price of an asset pair with leverage against the Vault, using USDC as collateral.
 * @dev this contract is designed to be cloned for different asset pairs, each with its own configuration and state.
 * The contract uses the Pyth oracle for price feeds and supports features like order creation, position management, funding rate, corporate actions, and settlements.
 */

// ================================================================
//                          BazaarPair
// Single trading pair instance (for minimal clones)
// ================================================================
contract BazaarPair is Initializable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IERC20;

    // ╔══════════════════════════════════════════════════════════════╗
    // ║           SECTION 0: CROSS-CUTTING (SHARED) ITEMS            ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- Shared Errors --------------------
    error BazaarPair__TransferFailed(uint256 amount, address to, address from);
    error BazaarPair__PairScheduledForTermination(uint256 scheduledTs);
    error BazaarPair__EthRefundFailed();
    error BazaarPair__TradingHalted();
    error BazaarPair__TradingFrozenAdlPending();
    error BazaarPair__NoMatchesProvided();
    error BazaarPair__ExceedsMaxCancelsPerCall(uint256 count, uint256 max);
    error BazaarPair__NoVolumeCapacity();
    error BazaarPair__AdlNotPending();
    error BazaarPair__RewardTransferFailed();
    error BazaarPair__MarketOrderBlockedOracleStale();
    error BazaarPair__InsufficientCollateralForRelayerFee(uint256 collateral, uint256 relayerFee);
    error BazaarPair__AmountLteRelayerFee(uint256 amount, uint256 relayerFee);
    error BazaarPair__AlreadyTerminated();
    error BazaarPair__NoPriceUpdatesProvided();
    error BazaarPair__InsufficientPythFee(); // no args: EIP-170 headroom

    // -------------------- Shared Constants --------------------
    int32 internal constant USDC_EXPONENT = BazaarTypes.USDC_EXPONENT;
    uint256 internal constant USDC_SCALE = BazaarTypes.USDC_SCALE; // 1e6
    int32 internal constant BAZAAR_EXPONENT = BazaarTypes.BAZAAR_EXPONENT;
    uint32 internal constant BAZAAR_DECIMALS = BazaarTypes.BAZAAR_DECIMALS; // 18
    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 internal constant BP_SCALE = BazaarTypes.BP_SCALE; // basis points scale (1 BP = 0.01%)
    uint256 internal constant EBP_SCALE = BazaarTypes.EBP_SCALE; // extended BP scale (1 EBP = 0.0001% = 0.01 bps)
    uint256 internal constant MAX_PRICE_STALENESS = 2 seconds; // max age of oracle price for bot-submitted transactions (match, liquidate, ADL)
    uint256 internal constant MAX_PRICE_STALENESS_USER = 10 seconds; // max age of oracle price for user-submitted transactions (deposit, withdraw, create order)
    uint256 internal constant STALE_MARGIN_MULTIPLIER = BazaarTypes.STALE_MARGIN_MULTIPLIER; // 2x IMR during stale oracle periods
    uint256 internal constant MAX_STALE_DEVIATION_BP = BazaarTypes.MAX_STALE_DEVIATION_BP; // 10% max deviation from last oracle price during stale periods

    // -------------------- Shared State Variables --------------------
    mapping(uint256 => BazaarTypes.Order) public orders; // orderId => Order
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets; // userAddress => PositionBucket
    // Tracks whether a terminal collateral haircut was applied per user. Shared by BOTH the
    // emergency haircut and the rung-4 normal-termination principal haircut: a pair is only ever
    // emergency XOR normal terminated (single writer _terminatePair, reverts on re-termination),
    // so the two haircut paths can never both consume this flag for the same user.
    mapping(address => bool) internal terminalHaircutApplied;
    mapping(address => EnumerableSet.UintSet) internal userActiveLimitOrders; // user => set of active limit order IDs

    /// @notice Scalar state variables shared with MatchingEngineLib via DELEGATECALL
    BazaarTypes.MatchingState public matchingState;

    BazaarTypes.Vault public pairVault; // vault aggregates for the pair

    int256 public currentFundingIndex = 0; // price units (1e18-scaled USD per unit of size), not a dimensionless rate
    uint256 internal lastFundingUpdateTs = 0;

    uint256 private nextOrderId;

    // -------------------- Pair Config (set in initialize) --------------------
    bytes32 public pairId;
    bytes32 public baseFeedId; // Pyth base (e.g. AAPL/USD) or BazaarOracle composite ID (non-USD-quoted assets)
    IERC20 public usdc;
    BazaarOracle public oracle;
    bool public isContinuouslyTraded; // if false, IMR is 1.5x to account for price gaps in non-trading hours
    address internal bugBountyAddress; // recipient for bug bounty share of trading fees
    BazaarSequencer public sequencerContract; // volume capacity enforcement

    // -------------------- Pair State --------------------
    bool public isAdlPending = false; // if true, all trading and order creation is frozen until ADL settles and Check 1 passes
    uint256 public adlPendingSince = 0; // timestamp when ADL was first triggered (0 if not pending)
    uint256 internal adlSnapshotPrice = 0; // price snapshot when ADL was triggered, used for consistent ranking across batches
    bool internal adlLongs = false; // locked direction: true if ADL'ing long winners, set when ADL triggers
    bool public isPairTerminatedEmergency = false; // if true, no deposits/orders/matching, only collateral
    bool public isPairTerminatedNormal = false; // if true, no deposits/orders/matching, only collateral withdrawals + PnL settlements
    // isOracleStale removed — staleness is now determined locally per function call
    uint256 public scheduledTerminationTs; // set when UMA accepts a termination proposal

    // -------------------- Insurance Depositor Shares --------------------
    // Per-depositor RAW share count. Generational: valid only while shareEpochOf[user] ==
    // shareEpoch (see the insuranceShares(address) getter, which resolves stale balances to 0).
    // Epoch state is declared at the END of storage (append-only layout).
    mapping(address => uint256) internal rawInsuranceShares;
    uint256 public totalInsuranceShares; // Total shares issued across all depositors (current epoch)

    /// @notice Per-deposit lots tracking the maturity timestamp of insurance shares.
    /// @dev Only IMMATURE deposits are meaningfully tracked here. Mature shares are
    ///      derived as `insuranceShares[user] - sum(active immature lots)`. Withdrawals
    ///      never mutate lots — the mature-only withdrawal policy preserves the
    ///      invariant `sum(active lots) <= insuranceShares[user]`. Old lots are pruned
    ///      on each deposit using LOT_RETENTION_PERIOD (long enough that pruned lots
    ///      are guaranteed mature for any still-active insurer-termination proposal).
    mapping(address => BazaarTypes.DepositLot[]) internal insuranceDepositLots;
    mapping(address => uint256) internal insuranceLotsHead;

    /// @notice Per-user, per-day count of insurance deposits, used to rate-limit deposits
    ///         to MAX_DEPOSITS_PER_WINDOW within a rolling INSURER_SHARE_MATURITY_PERIOD.
    /// @dev key = block.timestamp / 1 days. Bounds the worst-case tail walk in
    ///      `getSharesAsOf` since the active lot list cannot grow faster than this cap.
    mapping(address => mapping(uint256 => uint16)) internal insuranceDepositsPerDay;

    // -------------------- Price & Margin State --------------------
    BazaarTypes.PairPrice public lastPairPrice; // last normalized price
    BazaarTypes.LiquidationGapEma public liquidationGapEma; // rolling EMA of liquidation gaps
    BazaarTypes.MarginRequirements public marginRequirements; // current IMR/MMR

    // -------------------- Warmup State --------------------
    uint256 internal pairCreatedTs; // timestamp when the pair was initialized
    uint256 internal priceUpdateCount; // number of price updates received since launch

    // -------------------- EIP-712 Meta-Transaction State --------------------
    bytes32 public DOMAIN_SEPARATOR;
    uint256 private _cachedChainId;
    mapping(address => uint256) public metaTxNonces;

    // ╔══════════════════════════════════════════════════════════════╗
    // ║         SECTION 0.5: META-TX & RELAYER HELPERS               ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice Resolves the acting user: verifies EIP-712 meta-tx signature or falls back to msg.sender
    function _resolveUser(
        bytes32 structHash,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature
    ) internal returns (address user, uint256 effectiveRelayerFee, bool isMetaTx) {
        if (signature.length > 0) {
            user = MetaTxLib.verifyAndConsume(
                DOMAIN_SEPARATOR,
                _cachedChainId,
                address(this),
                structHash,
                signature,
                nonce,
                deadline,
                relayerFee,
                metaTxNonces
            );
            effectiveRelayerFee = relayerFee;
            isMetaTx = true;
        } else {
            user = msg.sender;
            effectiveRelayerFee = 0;
            isMetaTx = false;
        }
    }

    /// @notice Sends relayer fee from contract to msg.sender and emits MetaTransactionExecuted.
    function _payRelayer(address user, uint256 relayerFee, bytes32 typehash, uint256 nonce) internal {
        _sendUsdc(address(this), msg.sender, relayerFee);
        emit BazaarTypes.MetaTransactionExecuted(pairId, user, msg.sender, typehash, nonce, relayerFee);
    }

    /// @notice Charge a relayer fee against a user's bucket collateral, keeping the solvency ledger
    ///         consistent. The fee must be debited from BOTH the bucket AND totalCollateralDeposited
    function _chargeRelayerFee(address user, uint256 fee) internal {
        BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
        if (bucket.collateral < fee) revert BazaarPair__InsufficientCollateralForRelayerFee(bucket.collateral, fee);
        bucket.collateral -= fee;
        pairVault.totalCollateralDeposited -= fee;
    }

    /// @notice Refunds unused ETH to msg.sender
    function _refundEth(uint256 amount) internal {
        if (amount > 0) {
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            if (!ok) revert BazaarPair__EthRefundFailed();
        }
    }

    /// @notice Returns the current Arbitrum L2 block number via the ArbSys precompile.
    ///         Solidity's block.number on Arbitrum tracks L1 (~12s cadence); this returns
    ///         the true L2 block counter (~250ms cadence) needed for FIFO ordering and
    ///         observation-age validation.
    function _l2Block() internal view returns (uint64) {
        return uint64(IArbSys(address(0x64)).arbBlockNumber());
    }

    /// @notice Sends USDC to user (minus relayer fee if applicable), pays relayer, emits event
    function _sendWithRelayerFee(address user, uint256 amount, uint256 relayerFee, bytes32 typehash, uint256 nonce)
        internal
    {
        if (relayerFee > 0) {
            if (amount <= relayerFee) revert BazaarPair__AmountLteRelayerFee(amount, relayerFee);
            _sendUsdc(address(this), user, amount - relayerFee);
            _payRelayer(user, relayerFee, typehash, nonce);
        } else {
            _sendUsdc(address(this), user, amount);
        }
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║         SECTION 1: INITIALIZATION & Termination              ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- Errors --------------------
    error BazaarPair__OnlyUma();
    error BazaarPair__ZeroAddress(); // any zero address in InitParams (single error: EIP-170 headroom)
    error BazaarPair__SeedBelowMinimum(); // no args: EIP-170 headroom (min is the public constant)
    error BazaarPair__TerminationAlreadyScheduled();

    // -------------------- Constants --------------------
    // UMA proposer reward constants (0.1% = 10 bps, $100 cap) live in InsuranceVaultLib.payUmaProposerReward.
    uint256 internal constant MIN_INSURANCE_SEED = 3_000 * BAZAAR_SCALE; // min 3000 USDC seed deposit at deployment

    // -------------------- State Variables --------------------
    address public umaContract; // BazaarPairTerminator contract for UMA governance
    bool internal umaProposerRewardPaid = false; // ensures reward is only paid once per pair lifetime

    // -------------------- Modifiers --------------------
    modifier onlyUma() {
        if (msg.sender != umaContract) revert BazaarPair__OnlyUma();
        _;
    }

    // -------------------- Functions --------------------

    /// @notice Implementation contract constructor — disables initialize() on the implementation itself
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize a cloned pair instance with pair-specific configuration
    /// @dev Called once by the factory immediately after cloning. Cannot be called again.
    /// @dev Bundled init params — flattens the call site to keep via_ir stack happy.
    struct InitParams {
        bytes32 pairId;
        address oracle;
        address usdc;
        address sequencer;
        address bugBountyAddress;
        bytes32 baseFeedId;
        address umaContract;
        bool isContinuouslyTraded;
        address deployer;
        uint256 seedAmount;
    }

    function initialize(InitParams calldata p) external initializer {
        if (
            p.oracle == address(0) || p.usdc == address(0) || p.sequencer == address(0)
                || p.bugBountyAddress == address(0) || p.umaContract == address(0) || p.deployer == address(0)
        ) revert BazaarPair__ZeroAddress();
        if (p.seedAmount < MIN_INSURANCE_SEED) revert BazaarPair__SeedBelowMinimum();

        pairId = p.pairId;
        oracle = BazaarOracle(p.oracle);
        usdc = IERC20(p.usdc);
        sequencerContract = BazaarSequencer(p.sequencer);
        bugBountyAddress = p.bugBountyAddress;
        baseFeedId = p.baseFeedId;
        umaContract = p.umaContract;
        isContinuouslyTraded = p.isContinuouslyTraded;
        pairCreatedTs = block.timestamp;

        // Set initial margin requirements — use warmup floor (5x max leverage) until pair matures
        uint256 initialImr = RiskParamsLib.WARMUP_MIN_IMR_BP;
        if (!p.isContinuouslyTraded) {
            uint256 scaled =
                RiskParamsLib.WARMUP_MIN_IMR_BP * RiskParamsLib.NON_CONTINUOUSLY_TRADED_IMR_MULTIPLIER_BP / BP_SCALE;
            if (scaled > initialImr) initialImr = scaled;
        }
        marginRequirements = BazaarTypes.MarginRequirements({
            imrBp: initialImr,
            mmrBp: initialImr / 2,
            lastUpdateTs: 0,
            laggedMmrBp: 0 // transient per-batch field; never persisted to storage
        });

        // Initialize ID counters at 1
        matchingState.nextBatchId = 1;
        nextOrderId = 1;
        nextAdlId = 1;

        // Record insurance fund seed (USDC transfer handled by factory).
        // shareEpochOf[deployer] stays 0 == the initial shareEpoch, so no stamp is needed.
        rawInsuranceShares[p.deployer] = p.seedAmount;
        totalInsuranceShares = p.seedAmount;
        pairVault.insuranceFundBalance = p.seedAmount;

        // EIP-712 domain separator for meta-transactions
        _cachedChainId = block.chainid;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                MetaTxLib.EIP712_DOMAIN_TYPEHASH,
                MetaTxLib.NAME_HASH,
                MetaTxLib.VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Set the scheduled termination timestamp (called by BazaarPairTerminator on an
    ///         accepted scheduled or post-cessation proposal; for the latter, lastTradingTs is
    ///         already in the past so trading halts immediately)
    function setScheduledTermination(uint256 lastTradingTs, address proposer) external onlyUma {
        if (scheduledTerminationTs != 0) revert BazaarPair__TerminationAlreadyScheduled();
        scheduledTerminationTs = lastTradingTs;
        _payUmaProposerReward(proposer);
    }

    event InsurerBondForfeitedToInsurance(bytes32 indexed pairId, uint256 amountBazaarPrecision);

    /// @notice Credits a forfeited insurer-termination bond to the insurance fund.
    /// @dev Pure bookkeeping. Caller (Terminator) must have already transferred matching
    ///      USDC. Mismatched amounts get caught by isVaultHealthy reason 3.
    function creditInsuranceFromTerminator(uint256 amountBazaarPrecision) external onlyUma {
        pairVault.insuranceFundBalance += amountBazaarPrecision;
        emit InsurerBondForfeitedToInsurance(pairId, amountBazaarPrecision);
    }

    error BazaarPair__OnlySequencer();
    event InsuranceCreditedFromSequencer(bytes32 indexed pairId, uint256 amountBazaarPrecision);

    /// @notice Credits a stale-batch-challenge slash share into the insurance fund.
    /// @dev Pure bookkeeping, callable only by the registered sequencer. The sequencer transfers
    ///      the matching USDC immediately before calling this (same pattern as
    ///      creditInsuranceFromTerminator), so the contract's USDC balance and the insurance
    ///      accounting stay in sync; mismatches are caught by isVaultHealthy reason 3.
    function creditInsuranceFromSequencer(uint256 amountBazaarPrecision) external {
        if (msg.sender != address(sequencerContract)) revert BazaarPair__OnlySequencer();
        pairVault.insuranceFundBalance += amountBazaarPrecision;
        emit InsuranceCreditedFromSequencer(pairId, amountBazaarPrecision);
    }

    /// @notice One-time-per-pair reward to the UMA proposer: 0.1% (10 bps) of insurance fund, capped at
    ///         $100. Math + soft-fail transfer live in InsuranceVaultLib (EIP-170 relief); only
    ///         the once-flag is kept here so the reward can't be retried.
    function _payUmaProposerReward(address proposer) internal {
        if (umaProposerRewardPaid || proposer == address(0)) return;
        umaProposerRewardPaid = true;
        InsuranceVaultLib.payUmaProposerReward(pairVault, address(usdc), proposer);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║         SECTION 2: BUCKET MANAGEMENT & CHECKPOINTS           ║
    // ╚══════════════════════════════════════════════════════════════╝

    // checkBucketSolvency → moved to BazaarPairLens

    /// @notice Returns the current margin requirements with this batch's 24h-lagged MMR resolved.
    /// @dev The walk-back over the sample ring is done ONCE here, per external call (per batch),
    ///      not per position — callers pass the result down so every per-position solvency check
    ///      reuses it. The lagged value lives only in this in-memory copy; storage is untouched.
    function _marginReqsWithLag() internal view returns (BazaarTypes.MarginRequirements memory mr) {
        mr = marginRequirements;
        mr.laggedMmrBp = MmrSampleLib.laggedMmr(mmrBuffer);
    }

    /// @notice The current 24h-lagged MMR (newest sample >= MMR_GRACE_PERIOD old; 0 if none yet).
    /// @dev Exposed so BazaarPairLens / liquidation bots evaluate solvency with the same effective
    ///      MMR the pair applies on-chain.
    function getLaggedMmrBp() external view returns (uint256) {
        return MmrSampleLib.laggedMmr(mmrBuffer);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║              SECTION 3: COLLATERAL MANAGEMENT                ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- Errors --------------------
    error BazaarPair__RelayerFeeExceedsDeposit(uint256 relayerFee, uint256 amount);
    error BazaarPair__WithdrawalsFrozenAdlPending();

    // -------------------- Functions --------------------

    /// @notice Deposits collateral for a user into their position bucket.
    /// @dev No price update needed — deposit simply adds to stored collateral.
    ///      PnL and funding adjustments are computed lazily at match/withdrawal/liquidation time.
    /// @param amount The amount of collateral to deposit (in BAZAAR_EXPONENT precision)
    function depositCollateral(
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature, // leave empty for direct calls, provide EIP-712 signature for meta-transactions
        bytes calldata permitData // optional permit data for gasless approval (encoded as abi.encode(uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s))
    ) external nonReentrant {
        bytes32 structHash =
            keccak256(abi.encode(MetaTxLib.DEPOSIT_COLLATERAL_TYPEHASH, amount, nonce, deadline, relayerFee));
        (address user, uint256 effRelayerFee,) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);
        // Round down to USDC (6-dp) granularity so the credited amount exactly matches the USDC
        // actually pulled (which is floored); avoids crediting unbacked sub-µUSDC dust.
        amount -= amount % 1e12;
        if (effRelayerFee >= amount) revert BazaarPair__RelayerFeeExceedsDeposit(effRelayerFee, amount);

        CollateralLib.depositCollateral(
            positionBuckets,
            BazaarTypes.DepositParams({
                amount: amount,
                currentFundingIndex: currentFundingIndex,
                marginReqs: marginRequirements,
                pairId: pairId,
                currentBlock: _l2Block(),
                isPairTerminatedEmergency: isPairTerminatedEmergency,
                isPairTerminatedNormal: isPairTerminatedNormal,
                scheduledTerminationTs: scheduledTerminationTs
            }),
            user
        );

        // Execute ERC-2612 permit if provided (allows gasless USDC approval)
        if (permitData.length > 0) {
            _executePermit(user, permitData);
        }

        // Transfer USDC from user to contract (deposit + relayer fee)
        uint256 totalPull = amount + effRelayerFee;
        _sendUsdc(user, address(this), totalPull);
        pairVault.totalCollateralDeposited += amount;

        // Epoch-tag deposits made during a live ADL window: the deposit fully protects the
        // bucket and counts at settlement, but ADL scoring subtracts it (AdlLib._scoreCollateral)
        // so a mid-auction top-up cannot re-rank the queue.
        if (isAdlPending) {
            if (adlDepositEpoch[user] != adlEpoch) {
                adlDepositEpoch[user] = adlEpoch;
                adlWindowDeposits[user] = amount;
            } else {
                adlWindowDeposits[user] += amount;
            }
        }

        // Pay relayer fee
        if (effRelayerFee > 0) {
            _payRelayer(user, effRelayerFee, MetaTxLib.DEPOSIT_COLLATERAL_TYPEHASH, nonce);
        }
    }

    /// @notice Withdraws collateral from the user's position bucket.
    /// @dev Requires a fresh price update when the user has an open position or pending gains.
    ///      Ensures sufficient margin remains after withdrawal.
    /// @param amount The amount of collateral to withdraw (in BAZAAR_EXPONENT precision)
    /// @param priceUpdate The signed price update messages (required if user has exposure)
    function withdrawCollateral(
        uint256 amount,
        bytes[] calldata priceUpdate,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature
    ) external payable nonReentrant {
        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.WITHDRAW_COLLATERAL_TYPEHASH, amount, nonce, deadline, relayerFee)
        );
        (address user, uint256 effRelayerFee, bool isMetaTx) =
            _resolveUser(structHash, nonce, deadline, relayerFee, signature);

        // Position-holders' withdrawals are frozen while ADL is pending. With trading frozen,
        // a withdrawal has no legitimate use for an open position: it can only strip margin or
        // reorder-grief pending keeper submissions (a submitted winners[] must stay descending
        // in adlScore, and a winner's score RISES as their cash falls — one small withdrawal
        // reverts a whole executeAdl batch). Flat users (collateral only, no position) are
        // unaffected: they have no ADL score and no margin role. Terminated pairs are exempt —
        // _terminatePair also clears isAdlPending, so the explicit flags here are defense in
        // depth against a future termination path forgetting to.
        if (isAdlPending && !isPairTerminatedEmergency && !isPairTerminatedNormal && positionBuckets[user].size != 0) {
            revert BazaarPair__WithdrawalsFrozenAdlPending();
        }

        // ALL collateral withdrawals (flat users included) are frozen during the terminal sweep
        // window: winners must not realize anything before the sweep determines the payout
        // ratios, and the rung-4 principal-haircut denominator must stay stable.
        _requireNoSweepWindow();

        // Clean up expired limit orders and get directional exposure
        (uint256 longOrderExposure, uint256 shortOrderExposure) = _cleanupExpiredLimitOrders(user, _l2Block());

        // Get price and vault health when user has exposure
        uint256 currentPrice;
        uint256 refundBudget;
        bool vaultHealthy = true;
        uint8 vaultHealthReason;

        bool hasExposure = positionBuckets[user].size != 0 || longOrderExposure > 0 || shortOrderExposure > 0;
        bool _isOracleStale;
        if (hasExposure && !isPairTerminatedEmergency && !isPairTerminatedNormal) {
            uint256 staleness = isMetaTx ? MAX_PRICE_STALENESS : MAX_PRICE_STALENESS_USER;
            (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool isStale) =
                _getCurrentPairPrice(priceUpdate, msg.value, staleness);
            // Conservative price for the user's bucket: long → low, short → high.
            // Flat with only orders → use spot (worst exposure side is bounded by limit prices).
            BazaarTypes.PositionBucket storage b = positionBuckets[user];
            if (b.size == 0) {
                currentPrice = priceStruct.spotPrice;
            } else {
                currentPrice = b.isLong ? priceStruct.lowPrice : priceStruct.highPrice;
            }
            refundBudget = ethRefund;
            _isOracleStale = isStale;
            (vaultHealthy, vaultHealthReason) = isVaultHealthy(priceStruct.spotPrice);
        } else {
            refundBudget = msg.value;
        }

        BazaarTypes.CollateralWithdrawResult memory result = CollateralLib.withdrawCollateral(
            positionBuckets,
            terminalHaircutApplied,
            pairVault,
            BazaarTypes.CollateralWithdrawParams({
                amount: amount,
                currentPrice: currentPrice,
                currentFundingIndex: currentFundingIndex,
                marginReqs: _marginReqsWithLag(),
                pairId: pairId,
                currentBlock: _l2Block(),
                isPairTerminatedEmergency: isPairTerminatedEmergency,
                isPairTerminatedNormal: isPairTerminatedNormal,
                pendingTermination: scheduledTerminationTs != 0 && block.timestamp > scheduledTerminationTs
                    && !isPairTerminatedNormal && !isPairTerminatedEmergency,
                emergencyHaircutBp: emergencyTerminalCollateralWithdrawalRatioBp,
                isOracleStale: _isOracleStale,
                normalTerminationPrice: normalTerminationPrice,
                normalTerminalWinnersPayoutRatioBp: normalTerminalWinnersPayoutRatioBp,
                normalTerminalCollateralRatioBp: normalTerminalCollateralRatioBp,
                isVaultHealthy: vaultHealthy,
                vaultHealthReason: vaultHealthReason,
                outstandingLongOrderExposure: longOrderExposure,
                outstandingShortOrderExposure: shortOrderExposure
            }),
            user
        );

        // Update vault OI if position was closed during normal termination
        if (result.positionClosed) {
            if (result.isLong) {
                pairVault.totalLongOI -= result.closedSize;
                pairVault.longWeightedEntrySum -= result.closedEntryValue;
            } else {
                pairVault.totalShortOI -= result.closedSize;
                pairVault.shortWeightedEntrySum -= result.closedEntryValue;
            }
        }

        // Transfer USDC to user (minus relayer fee)
        _sendWithRelayerFee(user, result.withdrawAmount, effRelayerFee, MetaTxLib.WITHDRAW_COLLATERAL_TYPEHASH, nonce);

        _refundEth(refundBudget);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║              SECTION 4: INSURANCE MANAGEMENT                 ║
    // ╚══════════════════════════════════════════════════════════════╝
    // Share-based model: depositors receive shares proportional to their deposit relative to
    // the current fund balance. As fees flow into insuranceFundBalance, share price increases.
    // Bad debt events reduce insuranceFundBalance, lowering share price for all depositors equally.
    //
    // sharePrice = insuranceFundBalance / totalInsuranceShares
    // deposit:  shares = amount / sharePrice
    // withdraw: amount = shares × sharePrice

    // -------------------- State Variables --------------------
    BazaarTypes.InsuranceWithdrawalRateLimitState public insuranceWithdrawalRateLimit;
    mapping(address => uint256) public insuranceWithdrawalRequestTs;
    mapping(address => uint256) public insuranceWithdrawalRequestShareAmount;

    // Maturity / pruning constants + lot bookkeeping (prune, rate limit, lot append) moved to
    // InsuranceVaultLib (EIP-170 headroom). The read side (getSharesAsOf) stays here.

    // -------------------- Functions --------------------

    /// @notice A user's insurance share balance, epoch-resolved: balances written before the
    ///         last drained-fund reset (see InsuranceVaultLib share-epoch accounting) read as 0.
    ///         Same ABI as a public mapping getter — every consumer (Terminator votes, Lens,
    ///         maturity math) gets generational semantics through this single point.
    function insuranceShares(address user) public view returns (uint256) {
        return shareEpochOf[user] == shareEpoch ? rawInsuranceShares[user] : 0;
    }

    /// @notice Deposit USDC into the insurance fund. Receives shares proportional to deposit / share price.
    /// @param amount Amount to deposit (in BAZAAR_EXPONENT precision)
    function depositToInsurance(
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature,
        bytes calldata permitData
    ) external nonReentrant {
        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.DEPOSIT_TO_INSURANCE_TYPEHASH, amount, nonce, deadline, relayerFee)
        );
        (address user, uint256 effRelayerFee,) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);
        // Round down to USDC (6-dp) granularity so the credited amount exactly matches the USDC
        // actually pulled (which is floored); avoids crediting unbacked sub-µUSDC dust.
        amount -= amount % 1e12;
        if (effRelayerFee >= amount) revert BazaarPair__RelayerFeeExceedsDeposit(effRelayerFee, amount);

        // sharesGained comes from the lib (not a total-supply delta): when recapitalizing an
        // LP-less fund the lib also mints locked orphan shares to address(0), which must not
        // leak into this user's deposit lot below.
        (uint256 sharesGained, uint256 newTotalShares, uint256 newEpoch) = InsuranceVaultLib.depositToInsurance(
            rawInsuranceShares,
            shareEpochOf,
            shareEpoch,
            insuranceDepositLots,
            insuranceLotsHead,
            insuranceDepositsPerDay,
            totalInsuranceShares,
            pairVault,
            amount,
            isPairTerminatedEmergency,
            isPairTerminatedNormal,
            scheduledTerminationTs,
            user
        );
        totalInsuranceShares = newTotalShares;
        shareEpoch = newEpoch;

        emit BazaarTypes.InsuranceDeposited(pairId, user, amount, sharesGained);

        // Execute ERC-2612 permit if provided (allows gasless USDC approval)
        if (permitData.length > 0) {
            _executePermit(user, permitData);
        }

        // Transfer USDC from user to contract (deposit + relayer fee)
        uint256 totalPull = amount + effRelayerFee;
        _sendUsdc(user, address(this), totalPull);

        // Pay relayer fee
        if (effRelayerFee > 0) {
            _payRelayer(user, effRelayerFee, MetaTxLib.DEPOSIT_TO_INSURANCE_TYPEHASH, nonce);
        }
    }

    /// @notice Request withdrawal of insurance shares. Starts a 20-day cooldown.
    /// @param shareAmount Number of shares to withdraw
    function requestInsuranceWithdrawal(
        uint256 shareAmount,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature,
        bytes calldata permitData
    ) external nonReentrant {
        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.REQUEST_INSURANCE_WITHDRAWAL_TYPEHASH, shareAmount, nonce, deadline, relayerFee)
        );
        (address user, uint256 effRelayerFee,) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);

        InsuranceVaultLib.requestInsuranceWithdrawal(
            rawInsuranceShares,
            shareEpochOf,
            shareEpoch,
            insuranceWithdrawalRequestTs,
            insuranceWithdrawalRequestShareAmount,
            shareAmount,
            user
        );

        emit BazaarTypes.InsuranceWithdrawalRequested(pairId, user, shareAmount);

        // Pull relayer fee from user's wallet and forward to relayer
        if (effRelayerFee > 0) {
            if (permitData.length > 0) {
                _executePermit(user, permitData);
            }
            _sendUsdc(user, address(this), effRelayerFee);
            _payRelayer(user, effRelayerFee, MetaTxLib.REQUEST_INSURANCE_WITHDRAWAL_TYPEHASH, nonce);
        }
    }

    /// @notice Execute a previously requested insurance withdrawal after cooldown.
    /// @param priceUpdate Pyth price update data (needed to calculate insurance ratio)
    function executeInsuranceWithdrawal(
        bytes[] calldata priceUpdate,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature
    ) external payable nonReentrant {
        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.EXECUTE_INSURANCE_WITHDRAWAL_TYPEHASH, nonce, deadline, relayerFee)
        );
        (address user, uint256 effRelayerFee, bool isMetaTx) =
            _resolveUser(structHash, nonce, deadline, relayerFee, signature);

        // Frozen during the terminal sweep window: finalizeTermination charges swept bad debt
        // (pendingLiq settlement + deficit) to the insurance fund — LPs must not exit ahead of it.
        _requireNoSweepWindow();

        // Update price feed first (needed for rate-limit calculations)
        uint256 staleness = isMetaTx ? MAX_PRICE_STALENESS : MAX_PRICE_STALENESS_USER;
        (, uint256 ethRefund,) = _getCurrentPairPrice(priceUpdate, msg.value, staleness);

        uint256 prevTotalShares = totalInsuranceShares;
        (uint256 withdrawAmount, uint256 newTotalShares) = InsuranceVaultLib.executeInsuranceWithdrawal(
            rawInsuranceShares,
            shareEpochOf,
            shareEpoch,
            totalInsuranceShares,
            pairVault,
            insuranceWithdrawalRequestTs,
            insuranceWithdrawalRequestShareAmount,
            insuranceWithdrawalRateLimit,
            BazaarTypes.InsuranceWithdrawParams({
                isPairTerminatedEmergency: isPairTerminatedEmergency,
                isPairTerminatedNormal: isPairTerminatedNormal,
                scheduledTerminationTs: scheduledTerminationTs,
                adlPendingSince: adlPendingSince,
                spotPrice: lastPairPrice.spotPrice,
                emaVarianceBp: lastPairPrice.emaVarianceBp,
                emaGapBp: liquidationGapEma.emaGapBp,
                lockedShares: IBazaarTerminator(umaContract).getLockedShares(address(this), user)
            }),
            user
        );
        totalInsuranceShares = newTotalShares;

        uint256 sharesBurned = prevTotalShares - newTotalShares;
        // Lots are not mutated by withdrawal. The lot list is a snipe-vote defense
        // (see getSharesAsOf / Terminator.voteForInsurerTermination); it bounds the
        // user's voting power at vote time but doesn't track ownership precisely.
        // The next deposit will prune any lots aged past LOT_RETENTION_PERIOD.

        emit BazaarTypes.InsuranceWithdrawalExecuted(pairId, user, sharesBurned, withdrawAmount);

        // Transfer USDC to depositor (minus relayer fee)
        _sendWithRelayerFee(user, withdrawAmount, effRelayerFee, MetaTxLib.EXECUTE_INSURANCE_WITHDRAWAL_TYPEHASH, nonce);

        _refundEth(ethRefund);
    }

    // _pruneOldInsuranceLots / _checkAndRecordInsuranceDeposit → moved into
    // InsuranceVaultLib.depositToInsurance (EIP-170 headroom).

    /// @dev Sums the user's currently-held shares that were deposited STRICTLY AFTER
    ///      `atTs` (immature relative to that cutoff). Walks the lot list from the
    ///      newest tail backward and stops at the first lot with ts <= cutoff
    ///      (lots are appended in timestamp order, so everything before that point
    ///      is also mature).
    function _sumImmatureLotsAfter(address user, uint64 atTs) internal view returns (uint256 sum) {
        BazaarTypes.DepositLot[] storage lots = insuranceDepositLots[user];
        uint256 head = insuranceLotsHead[user];
        uint256 i = lots.length;
        while (i > head) {
            unchecked {
                --i;
            }
            BazaarTypes.DepositLot storage lot = lots[i];
            if (lot.ts <= atTs) break;
            unchecked {
                sum += lot.shares;
            }
        }
    }

    /// @dev mature_as_of(cutoff) = totalShares - immature_after(cutoff). Uses the epoch-resolved
    ///      balance, so a wiped (pre-epoch-bump) holder has 0 mature shares automatically, and a
    ///      post-bump depositor's mature count grows only as their NEW lots age — stale lots
    ///      can't revive voting power because they are only ever subtracted, never added.
    function _matureSharesAsOf(address user, uint64 atTs) internal view returns (uint256) {
        uint256 total = insuranceShares(user);
        uint256 immature = _sumImmatureLotsAfter(user, atTs);
        // Pruning never makes `immature` exceed `total`: active lots only ever sum
        // to a subset of the user's current holdings (withdrawals do not touch lots,
        // but they only consume mature shares, so the invariant holds).
        return total > immature ? total - immature : 0;
    }

    // View functions (getInsuranceSharePrice, getInsuranceDepositValue) moved to BazaarPairLens.

    /// @notice Returns the sum of this user's currently-held shares that are mature
    ///         as of `atTs` (i.e. were deposited at or before `atTs`).
    /// @dev Computed as `insuranceShares[user] - sum(active lots with ts > atTs)`.
    ///      Bounded iteration: the active lot list is capped by the deposit rate
    ///      limit (MAX_DEPOSITS_PER_WINDOW per INSURER_SHARE_MATURITY_PERIOD)
    ///      across the INSURER_LOT_RETENTION_PERIOD pruning window.
    function getSharesAsOf(address user, uint64 atTs) external view returns (uint256) {
        return _matureSharesAsOf(user, atTs);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║                   SECTION 5: LIQUIDATION                     ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- Errors --------------------
    error BazaarPair__EmptyLiquidationList();

    // -------------------- Constants --------------------
    /// @notice Liquidator reward floor per liquidation (0.10 USDC in BAZAAR scale).
    ///         Actual reward = max(this, LIQUIDATION_FEE_EBP of notional), paid from insurance.
    uint256 internal constant MIN_LIQUIDATOR_REWARD = BazaarTypes.MIN_LIQUIDATOR_REWARD;

    // -------------------- Functions --------------------

    /// @notice Allows anyone to liquidate underwater positions
    /// @dev For each address, LiquidationLib.processLiquidations checks solvency via
    ///      BucketLib.calculateState (using this batch's 24h-lagged MMR). If underwater, it
    ///      transfers assets to the vault at bankruptcy price and creates a liquidation order.
    /// @param usersToLiquidate Array of addresses to check and potentially liquidate
    /// @param priceUpdate The signed price update messages for current price
    /// @return liquidatedCount Number of positions successfully liquidated
    function liquidate(address[] calldata usersToLiquidate, bytes[] calldata priceUpdate)
        external
        payable
        nonReentrant
        returns (uint256 liquidatedCount)
    {
        if (usersToLiquidate.length == 0) {
            revert BazaarPair__EmptyLiquidationList();
        }
        // A terminated pair settles via the withdraw path only — never liquidate post-termination
        // (matchBatch/createOrder guard the same way). Without this, processLiquidations would mutate
        // terminated state, and the post-fix isVaultHealthy deficit check would revert mid-liquidation.
        if (isPairTerminatedEmergency || isPairTerminatedNormal) revert BazaarPair__TradingHalted();
        // Terminal sweep mode: settlement price fixed, finalize pending. Solvency runs at the
        // FIXED settlement price with zeroed margin requirements (effectiveMmr resolves to 0),
        // i.e. only equity <= 0 positions are liquidatable — price risk is gone, so an MMR
        // threshold would confiscate solvent holders' residual equity. No oracle read either:
        // freshness is meaningless once the settlement price is final, and the dead-feed paths
        // (post-cessation, 21-day stale) have no fresh price at all.
        bool isTerminalSweep = settlementPriceFixedTs != 0;
        if (!isTerminalSweep && scheduledTerminationTs != 0 && block.timestamp > scheduledTerminationTs) {
            revert BazaarPair__TradingHalted(); // limbo before the price is fixed (no-arg: EIP-170)
        }

        uint256 currentPrice;
        uint256 ethRefund;
        BazaarTypes.MarginRequirements memory liqMarginReqs; // stays zeroed in sweep mode
        if (isTerminalSweep) {
            currentPrice = fixedSettlementPrice;
            ethRefund = msg.value;
        } else {
            BazaarTypes.PairPrice memory priceStruct;
            (priceStruct, ethRefund,) = _getCurrentPairPrice(priceUpdate, msg.value, MAX_PRICE_STALENESS);
            currentPrice = priceStruct.spotPrice;
            liqMarginReqs = _marginReqsWithLag();
        }

        // Liquidation uses plain oracle price. The 2% confidence-ratio cap at the oracle
        // layer is the conservatism gate; per-direction polarity here adds no clean win.
        BazaarTypes.LiquidateResult memory result = LiquidationLib.processLiquidations(
            usersToLiquidate,
            orders,
            positionBuckets,
            pairVault,
            BazaarTypes.LiquidateParams({
                currentPrice: currentPrice,
                currentFundingIndex: currentFundingIndex,
                marginReqs: liqMarginReqs,
                pairId: pairId,
                currentBlock: _l2Block(),
                usdc: address(usdc)
            })
        );

        // Reward (max(floor, 2bps × notional) per position) is paid inside processLiquidations
        // (insurance-debited, soft-fail) — moved to the lib for EIP-170 relief.
        liquidatedCount = result.liquidatedCount;

        // Re-evaluate vault health after liquidations. Suppressed in sweep mode: a netting
        // deficit must not auto-terminate mid-window (unswept positions would escape the
        // waterfall through the side door) — finalizeTermination consumes pairVault.deficit.
        if (liquidatedCount > 0 && !isTerminalSweep) {
            isVaultHealthy(currentPrice);
            // Refresh IMR/MMR + sample the curve so a mass liquidation (which burns insurance via
            // collateral seizure and liquidator rewards) feeds the instantaneous insurance
            // multiplier immediately, rather than waiting for the next matchBatch. The helper
            // skips if the health re-eval just terminated the pair.
            _refreshMarginCurve(currentPrice);
        }

        _refundEth(ethRefund);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║            SECTION 6: AUTO-DELEVERAGING (ADL)                ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- Constants --------------------
    /// @notice Dutch auction duration: ADL score threshold decays from max to 0 over this period
    uint256 internal constant ADL_AUCTION_DURATION = BazaarTypes.ADL_AUCTION_DURATION;
    /// @notice Reward for ADL executor as basis points of closed notional (paid from insurance fund)
    uint256 internal constant ADL_EXECUTOR_REWARD_BP = 10; // 0.1%

    // -------------------- State Variables --------------------
    uint256 internal nextAdlId;

    // -------------------- Events --------------------
    /// @notice Emitted when an ADL auction window opens (false→true trigger). Carries the frozen
    ///         ranking basis — adlSnapshotPrice and adlSnapshotFundingIndex — so keepers score
    ///         winners against the same values the contract ranks with; adlEpoch identifies the
    ///         window. A mid-auction side flip re-snapshots within the same window without a new
    ///         event; auxState() always reflects the current basis (including adlLongs and the
    ///         auction clock), so keepers re-read it before each submission rather than depending on
    ///         this event alone. Kept lean to hold the pair under the EIP-170 code-size limit.
    event AdlTriggered(
        bytes32 indexed pairId, uint64 indexed adlEpoch, uint256 adlSnapshotPrice, int256 adlSnapshotFundingIndex
    );

    event AdlExecuted(
        bytes32 indexed pairId,
        uint256 indexed adlId,
        bool adlLongs,
        address indexed submitter,
        uint256 highestBankruptcyPrice,
        uint256 lowestBankruptcyPrice,
        uint256 highestAdlScore,
        uint256 lowestAdlScore,
        uint256 adlSnapshotPrice,
        uint256 timestamp
    );

    event UserAdld(
        bytes32 indexed pairId,
        address indexed user,
        bool isLong,
        uint256 closedSize,
        int256 realizedPnl,
        uint256 remainingCollateral,
        uint256 adlScore,
        uint256 adlSettlementPrice
    );

    event AdlExecutorRewarded(bytes32 indexed pairId, address indexed executor, uint256 reward);

    // -------------------- Functions --------------------

    /// @param priceUpdate Pyth price update data (can be empty for non-continuously traded pairs)
    function executeAdl(address[] calldata winners, bytes[] calldata priceUpdate) external payable nonReentrant {
        // A terminated pair has its pendingLiq zeroed and settles via withdrawals only — never
        // ADL. Same once the settlement price is fixed: only sweep-mode liquidations (at that
        // price) may mutate positions — an ADL at a live oracle price would corrupt the book.
        if (isPairTerminatedEmergency || isPairTerminatedNormal || settlementPriceFixedTs != 0) {
            revert BazaarPair__TradingHalted();
        }
        if (!isAdlPending) revert BazaarPair__AdlNotPending();

        (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund,) =
            _getCurrentPairPrice(priceUpdate, msg.value, MAX_PRICE_STALENESS);
        uint256 currentPrice = priceStruct.spotPrice;

        // ADL uses plain oracle. Settlement and ranking use frozen prices already; the only
        // bracket-affected hook is the mid-batch vault-health re-check, which is an aggregate
        // decision where the 2% confidence-ratio cap is the real safety gate.
        // executeAdlCore emits AdlExecuted (declared here for the ABI, emitted in AdlLib via
        // DELEGATECALL to keep this contract under the code-size limit), so it needs the adlId.
        BazaarTypes.AdlResult memory r = AdlLib.executeAdlCore(
            orders,
            positionBuckets,
            pairVault,
            winners,
            BazaarTypes.AdlParams({
                adlLongs: adlLongs,
                adlSnapshotPrice: adlSnapshotPrice,
                adlSnapshotFundingIndex: adlSnapshotFundingIndex,
                adlPendingSince: adlPendingSince,
                currentPrice: priceStruct.spotPrice,
                currentFundingIndex: currentFundingIndex,
                marginRequirements: _marginReqsWithLag(),
                pairId: pairId,
                adlId: nextAdlId++,
                currentBlock: _l2Block()
            }),
            adlEpoch,
            adlDepositEpoch,
            adlWindowDeposits
        );

        // Reward executor based on averted bad debt. Loss direction is keyed to the side
        // the vault holds (the liquidated side) — the opposite of adlLongs (winner side).
        {
            uint256 avertedLoss;
            if (pairVault.pendingLiqIsLong) {
                avertedLoss = currentPrice < r.settlementPrice
                    ? Math.mulDiv(r.totalLiqSize, r.settlementPrice - currentPrice, BAZAAR_SCALE)
                    : 0;
            } else {
                avertedLoss = currentPrice > r.settlementPrice
                    ? Math.mulDiv(r.totalLiqSize, currentPrice - r.settlementPrice, BAZAAR_SCALE)
                    : 0;
            }
            uint256 reward = Math.mulDiv(avertedLoss, ADL_EXECUTOR_REWARD_BP, BP_SCALE);
            if (reward > 0 && pairVault.insuranceFundBalance >= reward) {
                pairVault.insuranceFundBalance -= reward;
                if (_trySendUsdcReward(msg.sender, reward)) {
                    emit AdlExecutorRewarded(pairId, msg.sender, reward);
                } else {
                    pairVault.insuranceFundBalance += reward;
                }
            }
        }

        // Re-evaluate vault health (this updates isAdlPending: false once the deficit is resolved)
        isVaultHealthy(currentPrice);

        // On ADL completion (no longer pending and the pair survived), refresh IMR/MMR + sample so
        // the post-ADL insurance level feeds the margin curve immediately, not only on the next
        // matchBatch. While ADL is still pending the state is mid-resolution, so we wait.
        if (!isAdlPending) {
            _refreshMarginCurve(currentPrice);
        }

        _refundEth(ethRefund);
    }

    // getAdlScoreThreshold → moved to BazaarPairLens

    // ╔══════════════════════════════════════════════════════════════╗
    // ║                      SECTION 7: ORDERS                       ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- Errors --------------------
    error BazaarPair__RequestorIsNotOrderOwner(uint256 orderId, address requestor);

    // -------------------- Constants --------------------
    uint256 internal constant MIN_ORDER_AMOUNT = BazaarTypes.MIN_ORDER_AMOUNT; // min order size (5 USDC)
    uint256 internal constant MAX_SLIPPAGE_BP = BazaarTypes.MAX_SLIPPAGE_BP; // 5% max slippage for market-type orders
    uint256 internal constant MAX_CANCELS_PER_CALL = 200;

    // -------------------- State Variables --------------------
    /// @notice Mapping from batch ID to batch info hash
    /// @dev Full BatchInfo preimage emitted in BatchRecorded event; stored hash is rehashed
    ///      during omission challenges to authenticate the supplied preimage.
    mapping(uint256 => bytes32) public batchHashes;

    // -------------------- Functions --------------------

    /// @notice Creates a new order (delegates to OrderManagementLib)
    function createOrder(
        BazaarTypes.OrderType orderType,
        uint256 triggerPrice,
        uint256 limitPrice,
        uint256 maxSlippageBp,
        uint256 size,
        bool isLong,
        bool isPostOnly,
        uint64 expirationBlock,
        address integrator,
        bytes[] calldata priceUpdate,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature
    ) external payable nonReentrant {
        bytes32 structHash = keccak256(
            abi.encode(
                MetaTxLib.CREATE_ORDER_TYPEHASH,
                orderType,
                triggerPrice,
                limitPrice,
                maxSlippageBp,
                size,
                isLong,
                isPostOnly,
                expirationBlock,
                integrator,
                nonce,
                deadline,
                relayerFee
            )
        );
        (address user, uint256 effRelayerFee, bool isMetaTx) =
            _resolveUser(structHash, nonce, deadline, relayerFee, signature);

        if (isPairTerminatedEmergency || isPairTerminatedNormal || isAdlPending) revert BazaarPair__TradingHalted();
        if (scheduledTerminationTs != 0 && block.timestamp > scheduledTerminationTs) {
            revert BazaarPair__PairScheduledForTermination(scheduledTerminationTs);
        }

        // Deduct relayer fee from collateral before margin check so the check accounts for it.
        // Debits both the bucket and D (see _chargeRelayerFee); the USDC leaves via _payRelayer below.
        if (effRelayerFee > 0) {
            _chargeRelayerFee(user, effRelayerFee);
        }

        uint256 staleness = isMetaTx ? MAX_PRICE_STALENESS : MAX_PRICE_STALENESS_USER;
        (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool _isOracleStale) =
            _getCurrentPairPrice(priceUpdate, msg.value, staleness);

        if (_isOracleStale && orderType == BazaarTypes.OrderType.Market) {
            revert BazaarPair__MarketOrderBlockedOracleStale();
        }

        uint64 currentBlock = _l2Block();

        // Clean up expired limit orders and get directional exposure for margin calculation
        (uint256 longOrderExposure, uint256 shortOrderExposure) = _cleanupExpiredLimitOrders(user, currentBlock);

        // Path-1 conservatism: when the user already has an open position, value it at the
        // bracket-conservative price (long → low, short → high) so the bucket leg of the
        // margin check uses worst-case mark. With an empty bucket there's no existing
        // exposure to value, so spot is fine.
        uint256 effectivePrice;
        {
            BazaarTypes.PositionBucket storage userBucket = positionBuckets[user];
            if (userBucket.size > 0) {
                effectivePrice = userBucket.isLong ? priceStruct.lowPrice : priceStruct.highPrice;
            } else {
                effectivePrice = priceStruct.spotPrice;
            }
        }
        uint256 newNextOrderId = OrderManagementLib.createOrder(
            orders,
            positionBuckets,
            userActiveLimitOrders,
            BazaarTypes.CreateOrderParams({
                pairId: pairId,
                isLong: isLong,
                size: size,
                triggerPrice: triggerPrice,
                limitPrice: limitPrice,
                maxSlippageBp: maxSlippageBp,
                orderType: orderType,
                expirationBlock: expirationBlock,
                isPostOnly: isPostOnly,
                integrator: integrator,
                currentPrice: effectivePrice,
                currentFundingIndex: currentFundingIndex,
                // createOrder gates on IMR over worst-case notional and on effectiveCollateral;
                // it never reads the MMR-derived minRequiredCollateral, so the lagged walk-back
                // would be computed and discarded. Pass the plain (un-lagged) requirements.
                marginReqs: marginRequirements,
                isOracleStale: _isOracleStale,
                nextOrderId: nextOrderId,
                outstandingLongOrderExposure: longOrderExposure,
                outstandingShortOrderExposure: shortOrderExposure,
                currentBlock: currentBlock
            }),
            user
        );

        nextOrderId = newNextOrderId;

        // Send relayer fee from contract balance (already deducted from user's collateral above)
        if (effRelayerFee > 0) {
            _payRelayer(user, effRelayerFee, MetaTxLib.CREATE_ORDER_TYPEHASH, nonce);
        }

        _refundEth(ethRefund);
    }

    /// @notice Cancel one or more orders - can only be called by order creator or via meta-tx
    function cancelOrders(
        uint256[] calldata orderIds,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature
    ) external nonReentrant {
        bytes32 structHash = keccak256(
            abi.encode(
                MetaTxLib.CANCEL_ORDERS_TYPEHASH, keccak256(abi.encodePacked(orderIds)), nonce, deadline, relayerFee
            )
        );
        (address user, uint256 effRelayerFee,) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);

        if (orderIds.length > MAX_CANCELS_PER_CALL) {
            revert BazaarPair__ExceedsMaxCancelsPerCall(orderIds.length, MAX_CANCELS_PER_CALL);
        }

        uint64 currentBlock = _l2Block();
        for (uint256 i; i < orderIds.length; ++i) {
            if (orders[orderIds[i]].creator != user) {
                revert BazaarPair__RequestorIsNotOrderOwner(orderIds[i], user);
            }
            OrderManagementLib.cancelOrder(
                orders, positionBuckets, userActiveLimitOrders, orderIds[i], pairId, currentBlock
            );
        }

        // Deduct relayer fee from collateral (bucket and D) and send the USDC to the relayer.
        if (effRelayerFee > 0) {
            _chargeRelayerFee(user, effRelayerFee);
            _payRelayer(user, effRelayerFee, MetaTxLib.CANCEL_ORDERS_TYPEHASH, nonce);
        }
    }

    /// @notice Returns active (non-expired, non-canceled, non-filled) limit orders for a user.
    ///         Cleans up expired orders from the set before returning.
    /// @param user The address to query
    /// @return orderIds Array of active limit order IDs (after cleanup)
    /// @return count Number of active limit orders
    /// @return longExposure Sum of notional exposure for active long limit orders
    /// @return shortExposure Sum of notional exposure for active short limit orders
    function getUserActiveLimitOrders(address user)
        external
        returns (uint256[] memory orderIds, uint256 count, uint256 longExposure, uint256 shortExposure)
    {
        (longExposure, shortExposure) = _cleanupExpiredLimitOrders(user, _l2Block());
        orderIds = userActiveLimitOrders[user].values();
        count = orderIds.length;
    }

    /// @notice Iterates through a user's active limit order set, cancels expired orders,
    ///         removes them from the set, and returns directional notional exposure of remaining active orders.
    /// @param user The address whose limit orders to clean up
    /// @return longExposure Sum of remaining notional for active long orders
    /// @return shortExposure Sum of remaining notional for active short orders
    function _cleanupExpiredLimitOrders(address user, uint64 currentBlock)
        internal
        returns (uint256 longExposure, uint256 shortExposure)
    {
        // Sweep logic lives in OrderManagementLib (EIP-170 extraction).
        return
            OrderManagementLib.cleanupExpiredLimitOrders(
                userActiveLimitOrders[user], orders, pairId, user, currentBlock
            );
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║                  SECTION 8: ORDER MATCHING                   ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- Constants --------------------
    // Sequencer fees in EBP (paid directly to sequencer, before bug bounty tax)
    uint256 internal constant MAKER_SEQUENCER_FEE_EBP = BazaarTypes.MAKER_SEQUENCER_FEE_EBP; // 0.25 bps
    uint256 internal constant TAKER_SEQUENCER_FEE_EBP = BazaarTypes.TAKER_SEQUENCER_FEE_EBP; // 0.75 bps

    // Integrator fees in EBP (paid directly to integrator, before bug bounty tax)
    uint256 internal constant MAKER_INTEGRATOR_FEE_EBP = BazaarTypes.MAKER_INTEGRATOR_FEE_EBP; // 0.25 bps
    uint256 internal constant TAKER_INTEGRATOR_FEE_EBP = BazaarTypes.TAKER_INTEGRATOR_FEE_EBP; // 0.25 bps

    // Liquidation fee in EBP
    uint256 internal constant LIQUIDATION_FEE_EBP = BazaarTypes.LIQUIDATION_FEE_EBP; // 2 bps — secondary liquidator reward (applied in LiquidationLib)

    // Insurance fees in EBP (extended basis points, 1 EBP = 0.0001%)
    // Maker: flat 0.5 bps always
    // Taker base (f_base): scales linearly with target ratio from 0.5 bps (2% target) to 2 bps (10% target)
    // Taker deficit scaling: fee = f_base × (1 + 49 × δ²), capped at 45 bps
    //   where δ = (target - current) / target, quadratic convexity
    // Taker surplus scaling: f_base × (1 - surplus/target) down to 0 when fund is 2x target
    uint256 internal constant MAKER_INSURANCE_FEE_EBP = BazaarTypes.MAKER_INSURANCE_FEE_EBP; // 0.5 bps flat
    // Taker insurance fee curve constants live in RiskParamsLib.

    // Bug bounty tax: deducted from sequencer, integrator, and insurance totals at batch end
    uint256 internal constant BUG_BOUNTY_TAX_BP = BazaarTypes.BUG_BOUNTY_TAX_BP; // 1% of all fees

    uint256 internal constant MAX_OBSERVATION_BLOCK_AGE = 12; // max age of sequencer's observation block relative to _l2Block() (~4s on Arbitrum)

    // -------------------- Functions --------------------

    /// @notice Matches orders on-chain via three-pass walk over sequencer-provided sorted lists.
    /// @dev List sort orders (verified inline during the walk):
    ///        longLimits   — limitPrice DESC, orderId ASC
    ///        shortLimits  — limitPrice ASC,  orderId ASC
    ///        longMarkets  — maxSlippageBp DESC, orderId ASC
    ///        shortMarkets — maxSlippageBp DESC, orderId ASC
    ///      Pass A: vault liquidations vs limits.
    ///      Pass B: markets vs limits (long-markets first, then short-markets).
    ///      Pass C: limits vs limits.
    ///      `maxMatches` is the sequencer's gas-safety circuit breaker — walk halts when
    ///      `successCount >= maxMatches`. There is no protocol ceiling on maxMatches or on
    ///      calldata length (totalIds): the effective bound for both is the L2 transaction
    ///      gas limit, which rises with chain upgrades instead of being frozen here forever.
    ///      Engine buffers are sized from min(maxMatches, totalIds), so an oversized
    ///      maxMatches cannot inflate allocations.
    error BazaarPair__ObservationBlockTooOld(uint64 observationBlock, uint64 currentBlock);
    error BazaarPair__ObservationBlockInFuture(uint64 observationBlock, uint64 currentBlock);
    error BazaarPair__InvalidMaxMatches();

    function matchBatch(
        BazaarTypes.OrderLists calldata lists,
        uint256 maxMatches,
        bytes[] calldata priceUpdate,
        uint64 observationBlock
    ) external payable nonReentrant returns (uint256 successCount) {
        uint64 currentBlock = _l2Block();
        if (observationBlock >= currentBlock) {
            revert BazaarPair__ObservationBlockInFuture(observationBlock, currentBlock);
        }
        if (currentBlock - observationBlock > MAX_OBSERVATION_BLOCK_AGE) {
            revert BazaarPair__ObservationBlockTooOld(observationBlock, currentBlock);
        }
        if (isPairTerminatedEmergency || isPairTerminatedNormal) revert BazaarPair__TradingHalted();
        if (isAdlPending) revert BazaarPair__TradingFrozenAdlPending();
        if (scheduledTerminationTs != 0 && block.timestamp > scheduledTerminationTs) {
            revert BazaarPair__PairScheduledForTermination(scheduledTerminationTs);
        }

        if (maxMatches == 0) revert BazaarPair__InvalidMaxMatches();

        uint256 totalIds =
            lists.longLimits.length + lists.shortLimits.length + lists.longMarkets.length + lists.shortMarkets.length;
        if (totalIds == 0) revert BazaarPair__NoMatchesProvided();

        // Get current price: prefer freshest available.
        BazaarTypes.PairPrice memory priceStruct;
        uint256 ethRefund;
        bool _isOracleStale;
        (priceStruct, ethRefund, _isOracleStale) = _getCurrentPairPrice(priceUpdate, msg.value, MAX_PRICE_STALENESS);

        uint256 cachedPrice = priceStruct.spotPrice;

        _calculateIMRandMMR(cachedPrice);
        // Sample the (possibly just-updated) MMR into the ring buffer; self-gated to at most once
        // per MMR_SAMPLE_INTERVAL. matchBatch is the only writer of MMR, so this is the only place
        // the curve needs to be captured — quiet periods leave gaps that laggedMmr() tolerates.
        MmrSampleLib.record(mmrBuffer, marginRequirements.mmrBp);

        (, uint256 remainingCapacity) = sequencerContract.checkVolumeCapacity(msg.sender, 0);
        if (remainingCapacity == 0) revert BazaarPair__NoVolumeCapacity();
        uint256 takerSeqFeeEbp = sequencerContract.getDynamicTakerSequencerFee();

        BazaarTypes.MatchContext memory ctx;
        ctx.cachedPrice = cachedPrice;
        ctx.cachedLow = priceStruct.lowPrice;
        ctx.cachedHigh = priceStruct.highPrice;
        ctx.cachedFundingIdx = currentFundingIndex;
        ctx.insuranceFeeEbp =
            RiskParamsLib.getTakerInsuranceFeeEbp(pairVault, lastPairPrice, liquidationGapEma, cachedPrice);
        ctx.takerSequencerFeeEbp = takerSeqFeeEbp;
        ctx.remainingCapacity = remainingCapacity;
        ctx.closingFeeEbp = RiskParamsLib.getClosingFeeEbp(lastPairPrice, liquidationGapEma);
        ctx.isOracleStale = _isOracleStale;
        ctx.marginReqs = _marginReqsWithLag();
        ctx.pairId = pairId;
        ctx.observationBlock = observationBlock;
        ctx.currentBlock = currentBlock;
        ctx.usdc = address(usdc);
        ctx.bugBountyAddress = bugBountyAddress;
        ctx.sequencer = msg.sender;
        ctx.bugBountyTaxBp = BUG_BOUNTY_TAX_BP;
        ctx.maxMatches = maxMatches;

        BazaarTypes.BatchResult memory batchResult = MatchingEngineLib.executeBatch(
            orders, positionBuckets, batchHashes, matchingState, userActiveLimitOrders, pairVault, lists, ctx
        );

        successCount = batchResult.successCount;

        // Record matched volume with sequencer contract
        if (batchResult.totalMatchedVolume > 0) {
            sequencerContract.recordVolume(msg.sender, batchResult.totalMatchedVolume);
        }

        if (successCount != 0) {
            if (batchResult.totalFillSize > 0) {
                // totalMatchedVolume IS Σ(price × size): exact VWAP numerator and exact total
                // notional (the old vwap-roundtrip re-derivation only lost rounding dust).
                uint256 vwap = Math.mulDiv(batchResult.totalMatchedVolume, BAZAAR_SCALE, batchResult.totalFillSize);
                _updateMarkPrice(vwap, batchResult.totalMatchedVolume, cachedPrice);
            }

            // Pass A liquidation gap EMA update
            if (batchResult.liqCount != 0) {
                RiskParamsLib.updateLiquidationGapEmaBatch(
                    liquidationGapEma,
                    batchResult.sumLiqGapTimesSize,
                    batchResult.totalLiqFillSize,
                    batchResult.liqCount
                );
            }

            // Re-evaluate vault health
            isVaultHealthy(cachedPrice);
        }

        _refundEth(ethRefund);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       SECTION 9: IMR/MMR & MARGIN CALCULATIONS               ║
    // ╚══════════════════════════════════════════════════════════════╝

    // Risk-parameter constants and math (IMR/MMR curve, variance EMA, liquidation-gap EMA,
    // insurance targets and taker insurance fee curves) live in RiskParamsLib — an external
    // library, like MatchingEngineLib et al. — to keep this contract under the EIP-170 limit.

    /// @notice Updates IMR/MMR
    function _calculateIMRandMMR(uint256 currentPrice) internal {
        RiskParamsLib.calculateIMRandMMR(
            marginRequirements,
            lastPairPrice,
            liquidationGapEma,
            pairVault,
            currentPrice,
            isContinuouslyTraded,
            pairCreatedTs,
            priceUpdateCount
        );
    }

    /// @notice Recomputes IMR/MMR from `currentPrice` and records the result into the 24h-lagged
    ///         MMR sample ring; no-op once the pair is halted (margin params are moot then).
    /// @dev Shared by liquidate / executeAdl / refreshPrice so every path that refreshes the
    ///      margin curve also advances the ring. Spam-safe: both callees self-gate
    ///      (IMR_UPDATE_COOLDOWN / MMR_SAMPLE_INTERVAL), so redundant calls are no-ops.
    function _refreshMarginCurve(uint256 currentPrice) internal {
        if (isPairTerminatedEmergency || isPairTerminatedNormal) return;
        _calculateIMRandMMR(currentPrice);
        MmrSampleLib.record(mmrBuffer, marginRequirements.mmrBp);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║          SECTION 10: FUNDING RATE & MARK PRICE               ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- Constants --------------------
    // Funding constants (FUNDING_INTERVAL, MAX_FUNDING_RATE/AGE/GAP, MARK_DECAY_PERIOD)
    // live in FundingLib together with the mark/funding math (EIP-170 extraction).

    // -------------------- State Variables --------------------
    uint256 public markPrice;
    uint256 internal lastMarkUpdateTs;
    uint256 internal rollingVolume;

    // -------------------- Functions --------------------

    /// @notice Updates mark price. The EMA math (volume-scaled alpha, decay-to-index) lives
    ///         in FundingLib.updateMarkPrice; this wrapper owns the scalar storage writes.
    function _updateMarkPrice(uint256 execPrice, uint256 fillNotional, uint256 indexPrice) internal {
        FundingLib.MarkState memory s = FundingLib.updateMarkPrice(
            FundingLib.MarkState({
                markPrice: markPrice, lastMarkUpdateTs: lastMarkUpdateTs, rollingVolume: rollingVolume
            }),
            execPrice,
            fillNotional,
            indexPrice
        );
        markPrice = s.markPrice;
        lastMarkUpdateTs = s.lastMarkUpdateTs;
        rollingVolume = s.rollingVolume;
    }

    /// @notice Updates funding index. The accrual math (staleness-gated window, premium
    ///         dampening/clamp, price-unit accumulation) lives in FundingLib.updateFundingIndex.
    function _updateFundingIndex(uint256 indexPrice, uint256 oracleUpdateTs) internal {
        (currentFundingIndex, lastFundingUpdateTs) = FundingLib.updateFundingIndex(
            markPrice, lastMarkUpdateTs, currentFundingIndex, lastFundingUpdateTs, indexPrice, oracleUpdateTs
        );
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║              SECTION 11: PAIR TERMINATION                    ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- State Variables --------------------
    uint256 internal normalTerminationPrice = 0; // set at settlement for normal termination, used for final PnL calculation
    uint256 internal emergencyTerminalCollateralWithdrawalRatioBp = 0; // used to limit collateral withdrawals to a percentage of original collateral
    uint256 internal normalTerminalWinnersPayoutRatioBp = 0; // used to limit payout to winning side
    uint256 internal normalTerminalCollateralRatioBp = 0; // deep-insolvency principal haircut on normal termination (0 = none)

    // 24h-lagged-MMR ring buffer. Declared LAST so all existing storage slots keep their indices
    // (append-only is required for the upgradeable/proxy layout). See MmrSampleLib + MMR_* constants.
    BazaarTypes.MmrSampleBuffer internal mmrBuffer;

    // Insurance share-epoch state (append-only layout: added after mmrBuffer). A drained-fund
    // recap bumps shareEpoch; rawInsuranceShares entries stamped with an older shareEpochOf
    // read as 0 via the insuranceShares(address) getter. See InsuranceVaultLib.
    uint256 internal shareEpoch;
    mapping(address => uint256) internal shareEpochOf;

    // -------------------- Constants --------------------
    /// @notice Minimum delay between fixing the settlement price and finalizing termination.
    ///         During the window liquidate() runs in sweep mode: negative-equity-at-settlement
    ///         positions enter pendingLiq at bankruptcy price, so their bad debt reaches the
    ///         insurance/haircut waterfall instead of silently truncating (which would pay
    ///         winners 100% against a pot that cannot cover them — first-come-first-served drain).
    uint256 internal constant TERMINAL_SWEEP_WINDOW = 1 hours;

    // -------------------- Errors --------------------
    // (No pair-side event here: BazaarPairTerminator emits SettlementPriceFixed on every fix
    //  path — the pair is at the EIP-170 ceiling and the terminator initiates every fix.
    //  One shared error for every window-blocked action, finalize-too-early included.)
    error BazaarPair__SweepWindowActive();

    // -------------------- Functions --------------------

    /// @notice Stage 1 of normal termination: pin the settlement price and open the sweep
    ///         window. Callable only by BazaarPairTerminator (every normal-termination path:
    ///         scheduled, post-cessation, insurer-vote, 21-day stale). Also stamps
    ///         scheduledTerminationTs when unset (insurer-vote / stale paths) so all existing
    ///         limbo guards — matching, orders, deposits, price-storage freeze — engage at once.
    /// @dev Emergency and insolvency terminations (_terminateOnInsolvency) bypass the window:
    ///      they fire mid-transaction and cannot wait.
    function fixSettlementPrice(uint256 settlementPrice) external onlyUma {
        // Already-fixed reuses AlreadyTerminated: to every caller the pair is equally claimed.
        // The zero check must live HERE (not only in TerminationLib): a stored 0 would make
        // finalize revert forever with withdrawals frozen — fail at stage 1, where the
        // terminator can retry, never after the window state is latched.
        if (isPairTerminatedEmergency || isPairTerminatedNormal || settlementPriceFixedTs != 0) {
            revert BazaarPair__AlreadyTerminated();
        }
        if (settlementPrice == 0) revert BazaarPair__NoPriceUpdatesProvided();
        fixedSettlementPrice = settlementPrice;
        settlementPriceFixedTs = block.timestamp;
        if (scheduledTerminationTs == 0) scheduledTerminationTs = block.timestamp;
    }

    /// @notice Stage 2: anyone may finalize once the sweep window has elapsed, settling the
    ///         book at the fixed price. Deliberately unconditional on sweep completeness — an
    ///         unliquidatable straggler must never brick settlement; unswept positions settle
    ///         exactly as they would have without the window (strictly no worse).
    function finalizeTermination() external {
        // No nonReentrant: the only external interaction is TerminationLib's STATICCALL
        // balanceOf, no value moves, and re-entry lands on _terminatePair's AlreadyTerminated
        // guard. The single error covers both "nothing fixed" and "window still open" — with
        // nothing fixed, fixedSettlementPrice is 0 and TerminationLib would revert anyway.
        if (settlementPriceFixedTs == 0 || block.timestamp < settlementPriceFixedTs + TERMINAL_SWEEP_WINDOW) {
            revert BazaarPair__SweepWindowActive();
        }
        _terminatePair(false, fixedSettlementPrice);
    }

    /// @dev Shared freeze for user-facing withdrawals during the terminal sweep window
    ///      (settlement price fixed, finalize pending). Lifts the moment the pair terminates.
    function _requireNoSweepWindow() internal view {
        if (settlementPriceFixedTs != 0 && !isPairTerminatedEmergency && !isPairTerminatedNormal) {
            revert BazaarPair__SweepWindowActive();
        }
    }

    /// @dev Terminate on a detected insolvency, settling via the equity path at the live price so
    ///      winners/losers settle fairly (rung-4 distributes the remaining USDC pro-rata). The
    ///      `currentPrice == 0` arm is unreachable in practice — every isVaultHealthy caller sources
    ///      currentPrice from _getCurrentPairPrice, which floors prices to >=1 wei and reverts rather
    ///      than returning 0 — so the emergency fallback exists only as defense against a future
    ///      zero-price path; it must never silently brick the terminate by reverting on price 0.
    function _terminateOnInsolvency(uint256 currentPrice) internal {
        if (currentPrice > 0) {
            _terminatePair(false, currentPrice);
        } else {
            _terminatePair(true, 0);
        }
    }

    /// @notice Terminates the pair, settling pending liquidation obligations and setting withdrawal parameters
    /// @dev Delegates to TerminationLib via DELEGATECALL. Writes back scalar state from the result.
    /// @param isEmergency If true, emergency termination (Check 3 failure); if false, normal termination (delisting/acquisition)
    /// @param terminationPrice The price to settle at (only used for normal termination)
    function _terminatePair(bool isEmergency, uint256 terminationPrice) internal {
        if (isPairTerminatedEmergency || isPairTerminatedNormal) revert BazaarPair__AlreadyTerminated();

        BazaarTypes.TerminationResult memory result = TerminationLib.executeTermination(
            pairVault,
            BazaarTypes.TerminationParams({
                isEmergency: isEmergency, terminationPrice: terminationPrice, usdc: address(usdc), pairId: pairId
            })
        );

        // Write back scalar state from result
        if (result.isEmergency) {
            isPairTerminatedEmergency = true;
            emergencyTerminalCollateralWithdrawalRatioBp = result.emergencyCollateralRatioBp;
        } else if (result.isNormal) {
            isPairTerminatedNormal = true;
            normalTerminationPrice = result.normalTerminationPrice;
            normalTerminalWinnersPayoutRatioBp = result.winnersPayoutRatioBp;
            normalTerminalCollateralRatioBp = result.normalCollateralRatioBp;
        }

        // A terminated pair can never run ADL again — clear the pending state. The ADL-timeout
        // path reaches here with isAdlPending freshly re-set to true (VaultHealthLib keeps it
        // pending in the timeout branch), and anything keyed on the flag — most importantly the
        // position-holder withdrawal freeze — must not outlive termination, or terminal
        // settlement withdrawals would be bricked.
        isAdlPending = false;
        adlPendingSince = 0;
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║              SECTION 12: VAULT HEALTH                        ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- Constants --------------------
    /// @notice Tolerance for USDC balance vs bookkeeping comparison (in bp)
    uint256 internal constant USDC_BALANCE_TOLERANCE_BP = 10; // 0.1%

    // -------------------- Functions --------------------

    /// @notice Checks if the vault is in a healthy state
    /// @dev Unhealthy if any condition is true:
    ///      1. Liquidation exposure (real-time gap on pending liquidations) exceeds insurance (→ ADL)
    ///      2. ADL auction timeout expired (→ emergency termination)
    ///      3. Actual USDC balance shortfall vs bookkeeping (→ emergency termination)
    /// @param currentPrice The current price for OI notional calculation (BAZAAR_SCALE precision)
    /// @return healthy True if vault passes all health checks
    /// @return reason 0 = healthy,
    ///                1 = liquidation exposure exceeds insurance (triggers/extends ADL, not termination),
    ///                2 = ADL auction timeout expired (terminates the pair),
    ///                3 = actual USDC balance shortfall vs bookkeeping (emergency-terminates the pair),
    ///                4 = realized bad debt (insolvency) — terminates the pair
    function isVaultHealthy(uint256 currentPrice) internal returns (bool healthy, uint8 reason) {
        // Check 0: realized bad debt. A non-zero deficit means a prior loss overran the insurance
        // fund and the overrun was dropped (insurance floored at 0) — the pair is provably insolvent
        // and cannot honor all claims. Terminate immediately via the equity path (rung-4 distributes
        // the remaining USDC pro-rata) at the live price. This catches floored bad debt that the
        // books-vs-USDC check (reason 3) can miss, closing the pre-termination first-come-first-served
        // withdrawal window. Falls back to emergency collateral-refund only if no price is available.
        if (pairVault.deficit > 0) {
            _terminateOnInsolvency(currentPrice);
            return (false, 4);
        }

        // Check 1: liquidation exposure vs insurance fund (delegated to VaultHealthLib)
        VaultHealthLib.LiqExposureResult memory result = VaultHealthLib.checkLiqExposure(
            pairVault,
            currentPrice,
            isAdlPending,
            adlPendingSince,
            adlSnapshotPrice,
            adlLongs,
            currentFundingIndex,
            adlSnapshotFundingIndex
        );

        // Apply ADL state changes. A false→true transition opens a new ADL window: bump the epoch
        // (so deposit tags from prior windows stop subtracting from ADL scores) and announce the
        // frozen ranking basis from the result struct so keepers can score against the same values
        // the contract ranks with.
        if (result.newIsAdlPending && !isAdlPending) {
            unchecked {
                ++adlEpoch;
            }
            emit AdlTriggered(pairId, adlEpoch, result.newAdlSnapshotPrice, result.newAdlSnapshotFundingIndex);
        }
        isAdlPending = result.newIsAdlPending;
        adlPendingSince = result.newAdlPendingSince;
        adlSnapshotPrice = result.newAdlSnapshotPrice;
        adlSnapshotFundingIndex = result.newAdlSnapshotFundingIndex;
        adlLongs = result.newAdlLongs;

        if (result.adlTimeoutExpired) {
            // Price-driven insolvency: the vault could not deleverage a real move within the auction
            // window. Settle via the equity path at the live price so winners and losers settle
            // fairly, rather than refunding collateral (which would hand losers a windfall).
            _terminateOnInsolvency(currentPrice);
            return (false, 2);
        }

        if (!result.healthy) {
            return (false, 1);
        }

        // Check 2: actual USDC held by contract vs vault accounting
        uint256 expectedBalance = uint256(
            BazaarMathLib.convertExponent(
                int256(pairVault.insuranceFundBalance + pairVault.totalCollateralDeposited),
                BAZAAR_EXPONENT,
                USDC_EXPONENT
            )
        );

        uint256 tolerance = expectedBalance * USDC_BALANCE_TOLERANCE_BP / BP_SCALE;
        if (expectedBalance > usdc.balanceOf(address(this)) + tolerance) {
            _terminatePair(true, 0);
            return (false, 3);
        }

        return (true, 0);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║               SECTION 13: ORACLE / PRICE                     ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- Events --------------------
    /// @notice Emitted when a new price update is added to the pair prices mapping.
    event NewPriceUpdateAdded(
        bytes32 indexed pairId, uint256 indexed targetPublishTs, uint256 spotPrice, int32 exponent
    );

    // -------------------- Functions --------------------

    /// @notice Returns the ETH fee required to post the given Pyth price updates
    function getPythFee(bytes[] calldata priceUpdate) public view returns (uint256 fee) {
        fee = oracle.getUpdateFee(priceUpdate);
    }

    /// @notice Permissionless price + margin-curve refresher. Pushes the supplied Pyth update
    ///         (or relies on Pyth's on-chain cache), writes the result to lastPairPrice, then
    ///         recomputes IMR/MMR and records a 24h-lagged MMR ring sample from it.
    /// @dev    Pays the Pyth fee from msg.value and refunds any unused ETH. The margin leg exists
    ///         so the sample ring keeps advancing through trading gaps — matchBatch (the normal
    ///         writer) needs fills and liquidate() only resamples after a successful liquidation,
    ///         so a quiet pair would otherwise freeze laggedMmr() at an arbitrarily old value.
    ///         On a halted pair only the price refresh runs (margin params are moot then).
    function refreshPrice(bytes[] calldata priceUpdate) external payable nonReentrant {
        (BazaarTypes.PairPrice memory priceStruct, uint256 unusedEth,) =
            _getCurrentPairPrice(priceUpdate, msg.value, MAX_PRICE_STALENESS);
        _refreshMarginCurve(priceStruct.spotPrice);
        _refundEth(unusedEth);
    }

    /// @notice Internal function that updates Pyth price feeds and returns the pair price plus unused ETH
    /// @dev Does not refund ETH - caller is responsible for handling the returned unusedEth.
    ///      Optimizes by checking if fresh prices already exist on-chain before paying for updates.
    ///      If only one feed is stale, only that feed's update is paid for.
    /// @param priceUpdate The signed price update messages (bytes[])
    /// @param ethBudget The ETH budget provided for the oracle update
    /// @return priceStruct The current pair price struct containing spotPrice and updateTs
    /// @return unusedEth The amount of ETH not used for the oracle update (to be refunded by caller)
    /// @notice Fetches the current pair price for non-matching functions.
    ///         Returns a local isStale flag — no global state is written.
    ///         Flow: (1) Pyth on-chain cache → (2) user priceData → (3) stale fallback / revert
    function _getCurrentPairPrice(bytes[] calldata priceUpdate, uint256 ethBudget, uint256 maxStaleness)
        internal
        returns (BazaarTypes.PairPrice memory priceStruct, uint256 unusedEth, bool isStale)
    {
        uint256 budget = ethBudget;

        // Step 1: Pyth on-chain cache — fresh AND confidence-checked (free read).
        // tryReadFreshPrice enforces both freshness (≤ MAX_PRICE_STALENESS) and the 2%
        // confidence cap (per-leg for composites). A fresh, in-confidence price is used directly.
        // A stale price returns found=false; a fresh-but-over-confidence (or invalid) price
        // reverts inside and is caught here — both fall through to the user-update / stale paths,
        // so the confidence cap is never bypassed on the fresh hot path (fills, liquidation, ADL).
        try oracle.tryReadFreshPrice(baseFeedId, MAX_PRICE_STALENESS) returns (
            bool found, uint256 spot, uint256 low, uint256 high, uint256 pubTime
        ) {
            if (found) {
                (priceStruct,) = _buildAndStorePairPrice(spot, low, high, pubTime, 0);
                return (priceStruct, budget, false);
            }
        } catch {}

        // Step 2: Try user-provided priceData (updateAndFetchPrice is confidence-checked).
        if (priceUpdate.length > 0) {
            uint256 fee = getPythFee(priceUpdate);
            if (fee > budget) revert BazaarPair__InsufficientPythFee();

            (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime) =
                oracle.updateAndFetchPrice{value: fee}(baseFeedId, priceUpdate, maxStaleness);
            budget -= fee;

            (priceStruct,) = _buildAndStorePairPrice(spotPrice, lowPrice, highPrice, publishTime, 0);
            return (priceStruct, budget, false);
        }

        // Step 3: No fresh/priceData — stale fallback for non-continuously traded pairs.
        // Confidence-gated ladder: spot price (if conf ≤ 2%) → EMA price (if conf ≤ 2%) → last
        // stored price. The fallback still accepts STALE data, but never a price wider than the
        // 2% confidence cap — so liquidations/valuations here run on a trustworthy price or the
        // last recorded (conf-checked-when-recorded) one, never on a low-confidence read.
        if (!isContinuouslyTraded) {
            bool hasLocal = lastPairPrice.spotPrice > 0;
            try oracle.tryReadStalePrice(baseFeedId) returns (
                bool found, uint256 spot, uint256 low, uint256 high, uint256 pubTime
            ) {
                // Use the (spot-or-EMA) cache if it cleared the cap and is more recent than local.
                if (found && (!hasLocal || pubTime >= lastPairPrice.updateTs)) {
                    return (
                        BazaarTypes.PairPrice({
                            spotPrice: spot,
                            emaVarianceBp: lastPairPrice.emaVarianceBp,
                            updateTs: pubTime,
                            lowPrice: low,
                            highPrice: high
                        }),
                        budget,
                        true
                    );
                }
            } catch {}
            if (hasLocal) {
                return (lastPairPrice, budget, true);
            }
        }

        // Step 4: No fresh data available — revert
        revert BazaarPair__NoPriceUpdatesProvided();
    }

    /// @notice Builds the BazaarTypes.PairPrice struct from oracle results, stores, and emits event
    function _buildAndStorePairPrice(
        uint256 spotPrice,
        uint256 lowPrice,
        uint256 highPrice,
        uint256 publishTime,
        uint256 remainingBudget
    ) internal returns (BazaarTypes.PairPrice memory priceStruct, uint256 unusedEth) {
        // Update lastPairPrice and variance EMA if more recent
        // Do not update past scheduled termination timestamp (freeze price at termination time)
        if (
            publishTime > lastPairPrice.updateTs
                && (scheduledTerminationTs == 0 || publishTime <= scheduledTerminationTs)
        ) {
            // Update variance EMA before overwriting lastPairPrice
            uint256 emaVarianceBp = RiskParamsLib.calculateVariance(lastPairPrice, spotPrice);

            // Sync the lastPairPrice
            priceStruct.spotPrice = spotPrice;
            priceStruct.emaVarianceBp = emaVarianceBp;
            priceStruct.updateTs = publishTime;
            priceStruct.lowPrice = lowPrice;
            priceStruct.highPrice = highPrice;

            lastPairPrice = priceStruct;
            unchecked {
                ++priceUpdateCount;
            }

            // Update funding index with the fresh price
            _updateFundingIndex(spotPrice, publishTime);
        } else {
            // Caller's data isn't newer — return what we already have so the price flow
            // never propagates a zero priceStruct.
            priceStruct = lastPairPrice;
        }

        // Emit event
        emit NewPriceUpdateAdded(pairId, publishTime, spotPrice, BAZAAR_EXPONENT);

        return (priceStruct, remainingBudget);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║                   SECTION 14: HELPERS                        ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice Emitted when a permit call fails (already approved, front-run, etc).
    ///         Doesn't block the parent flow — the subsequent transferFrom will revert if
    ///         allowance is actually insufficient — but provides observability.
    event PermitExecutionFailed(address indexed owner);

    /// @notice Execute an ERC-2612 permit to set USDC allowance via signature.
    function _executePermit(address owner, bytes calldata permitData) private {
        (uint256 value, uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s) =
            abi.decode(permitData, (uint256, uint256, uint8, bytes32, bytes32));
        try IERC20Permit(address(usdc)).permit(owner, address(this), value, permitDeadline, v, r, s) {}
        catch {
            emit PermitExecutionFailed(owner);
        }
    }

    /// @notice Reverts on failure. Use for user-owed funds (collateral, withdrawals).
    function _sendUsdc(address from, address to, uint256 amountBazaarPrecision) internal {
        if (from == address(0) || to == address(0)) revert BazaarPair__TransferFailed(amountBazaarPrecision, from, to);
        uint256 usdcAmount =
            uint256(BazaarMathLib.convertExponent(int256(amountBazaarPrecision), BAZAAR_EXPONENT, USDC_EXPONENT));
        if (from == address(this)) {
            usdc.safeTransfer(to, usdcAmount);
        } else {
            usdc.safeTransferFrom(from, to, usdcAmount);
        }
    }

    /// @notice Does not revert on failure. Use for reward payouts where the receiver is
    ///         outside the protocol's trust boundary; callers must handle a false return.
    function _trySendUsdcReward(address to, uint256 amountBazaarPrecision) internal returns (bool) {
        if (to == address(0) || amountBazaarPrecision == 0) return false;
        uint256 usdcAmount =
            uint256(BazaarMathLib.convertExponent(int256(amountBazaarPrecision), BAZAAR_EXPONENT, USDC_EXPONENT));
        if (usdcAmount == 0) return false;
        (bool callOk, bytes memory data) =
            address(usdc).call(abi.encodeWithSelector(IERC20.transfer.selector, to, usdcAmount));
        if (!callOk) return false;
        if (data.length == 0) return true; // non-compliant token that doesn't return bool
        return abi.decode(data, (bool));
    }

    // ----------------------------------------------------------
    //  Aggregate state getter (read by BazaarPairLens / frontends)
    // ----------------------------------------------------------

    /// @notice Returns auxiliary state vars not covered by individual public getters.
    /// @dev Single batch getter is more bytecode-efficient than ~12 auto-generated getters.
    function auxState() external view returns (BazaarTypes.AuxState memory s) {
        s.lastFundingUpdateTs = lastFundingUpdateTs;
        s.lastMarkUpdateTs = lastMarkUpdateTs;
        s.rollingVolume = rollingVolume;
        s.pairCreatedTs = pairCreatedTs;
        s.priceUpdateCount = priceUpdateCount;
        s.adlSnapshotPrice = adlSnapshotPrice;
        s.adlSnapshotFundingIndex = adlSnapshotFundingIndex;
        s.adlLongs = adlLongs;
        s.normalTerminationPrice = normalTerminationPrice;
        s.emergencyTerminalCollateralWithdrawalRatioBp = emergencyTerminalCollateralWithdrawalRatioBp;
        s.normalTerminalWinnersPayoutRatioBp = normalTerminalWinnersPayoutRatioBp;
        s.bugBountyAddress = bugBountyAddress;
    }

    // ----------------------------------------------------------
    //  ADL window-deposit tracking (declared LAST: appending here
    //  preserves the storage slots of all earlier state)
    // ----------------------------------------------------------

    /// @notice ADL window counter — increments on each false→true isAdlPending transition.
    ///         (Distinct from nextAdlId, which numbers individual executeAdl installments;
    ///         one pending window can span several.) Deposits made during a live window are
    ///         epoch-tagged so ADL scoring ranks on the pre-window book: a mid-auction top-up
    ///         cannot dodge the queue, while still fully counting for liquidation protection
    ///         and ADL settlement. Tags from older windows fail the epoch check and are
    ///         ignored — lazy invalidation, no cleanup pass.
    uint64 public adlEpoch;
    mapping(address => uint64) internal adlDepositEpoch; // window the user's tagged deposits belong to
    mapping(address => uint256) internal adlWindowDeposits; // collateral added during that window

    /// @notice Funding index frozen when the current ADL window opened (and re-frozen on a
    ///         mid-auction side flip), paired with adlSnapshotPrice. ADL ranking scores against
    ///         this frozen value so the descending-order check stays deterministic across batches;
    ///         a funding move between the keeper's off-chain sort and on-chain execution can no
    ///         longer reorder the queue and revert the batch. Settlement still uses the live index.
    ///         (Appended last to preserve the storage slots of all earlier state.)
    int256 internal adlSnapshotFundingIndex = 0;

    /// @notice Terminal-sweep settlement state (appended last to preserve earlier slots).
    ///         fixSettlementPrice pins the verified settlement tick and opens a
    ///         TERMINAL_SWEEP_WINDOW during which liquidate() runs in sweep mode (fixed price,
    ///         equity <= 0 threshold, no oracle read) so positions with negative equity at the
    ///         settlement price fold into pendingLiq — and thus into the insurance/haircut
    ///         waterfall — before finalizeTermination settles the book.
    uint256 internal fixedSettlementPrice;
    uint256 public settlementPriceFixedTs;
}
