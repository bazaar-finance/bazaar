// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

// -------------------- Imports --------------------
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarOracle} from "./BazaarOracle.sol";
import {BazaarTypes} from "./libraries/BazaarTypes.sol";
import {BazaarMathLib} from "./libraries/BazaarMathLib.sol";
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
 * @title BazaarPair
 * @notice A single trading pair: users take leveraged long/short perpetual positions on an asset
 *         price against the Vault, collateralized in USDC.
 * @dev Deployed as a minimal clone, one instance per asset pair with its own configuration and
 *      state. Prices come from the Pyth oracle via BazaarOracle. Covers order creation and
 *      matching, position and collateral management, funding, liquidation, ADL, the insurance
 *      vault, and termination settlement.
 */
contract BazaarPair is Initializable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;
    using SafeERC20 for IERC20;

    // ╔══════════════════════════════════════════════════════════════╗
    // ║           SECTION 0: CROSS-CUTTING (SHARED) ITEMS            ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- Shared Errors --------------------
    error BazaarPair__TransferFailed();
    error BazaarPair__PairScheduledForTermination();
    error BazaarPair__EthRefundFailed();
    error BazaarPair__TradingHalted();
    error BazaarPair__TradingFrozenAdlPending();
    error BazaarPair__ExceedsMaxCancelsPerCall();
    error BazaarPair__AdlNotPending();
    error BazaarPair__AdlRetargetPending();
    error BazaarPair__RewardTransferFailed();
    error BazaarPair__InsufficientCollateralForRelayerFee();
    error BazaarPair__AmountLteRelayerFee();
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
    uint256 internal constant MAX_PRICE_STALENESS = 2 seconds; // max age of a caller-supplied oracle price, on every entry point
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

    /// @notice The resting order book's heads and per-side counts. The lists themselves are
    ///         threaded through `orders` via Order.prevInBook/nextInBook (see OrderBookLib).
    BazaarTypes.OrderBook public book;

    BazaarTypes.Vault public pairVault; // vault aggregates for the pair

    int256 public currentFundingIndex = 0; // price units (1e18-scaled USD per unit of size), not a dimensionless rate
    uint256 internal lastFundingUpdateTs = 0;

    uint256 private nextOrderId;

    // -------------------- Pair Config (set in initialize) --------------------
    bytes32 public pairId;
    bytes32 public baseFeedId; // Pyth base (e.g. AAPL/USD) or BazaarOracle composite ID (non-USD-quoted assets)
    IERC20 public usdc;
    BazaarOracle public oracle;
    bool public isContinuouslyTraded; // if false, IMR is 2x the larger of the vol curve and the observed reopen gap (jumps across non-trading hours)
    address internal bugBountyAddress; // recipient for bug bounty share of trading fees

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
    ///      invariant `sum(active lots) <= insuranceShares[user]`. Old lots are pruned on each
    ///      deposit using InsuranceVaultLib.INSURER_LOT_RETENTION_PERIOD (long enough that pruned
    ///      lots are guaranteed mature for any still-active insurer-termination proposal).
    mapping(address => BazaarTypes.DepositLot[]) internal insuranceDepositLots;
    mapping(address => uint256) internal insuranceLotsHead;

    /// @notice Per-user, per-day count of insurance deposits, used to rate-limit deposits
    ///         to MAX_DEPOSITS_PER_WINDOW within a rolling INSURER_SHARE_MATURITY_PERIOD.
    /// @dev key = block.timestamp / 1 days. Bounds the worst-case tail walk in
    ///      `getSharesAsOf` since the active lot list cannot grow faster than this cap.
    mapping(address => mapping(uint256 => uint16)) internal insuranceDepositsPerDay;

    // -------------------- Price & Margin State --------------------
    BazaarTypes.PairPrice public lastPairPrice; // last normalized price
    BazaarTypes.VarianceSample internal varianceSample; // observation the variance EMA advances from
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
    ) internal returns (address user, uint256 effectiveRelayerFee) {
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
        } else {
            user = msg.sender;
            effectiveRelayerFee = 0;
        }
    }

    /// @notice Sends relayer fee from contract to msg.sender and emits MetaTransactionExecuted.
    function _payRelayer(address user, uint256 relayerFee, bytes32 typehash, uint256 nonce) internal {
        _sendUsdc(address(this), msg.sender, relayerFee);
        emit BazaarTypes.MetaTransactionExecuted(pairId, user, msg.sender, typehash, nonce, relayerFee);
    }

    /// @notice Charge a relayer fee against a user's bucket collateral, debiting BOTH the bucket
    ///         and totalCollateralDeposited so the solvency ledger stays consistent.
    /// @dev A collateral-funded fee IS a withdrawal, so it clears the same lifecycle gates: halted
    ///      (terminated or ADL pending) and terminal sweep window. Gating the debit here rather
    ///      than at the call sites (createOrder / cancelOrders) means every fee-charging caller
    ///      inherits them; ungated, a relayed call could strip margin, move adlScore mid-ADL, or
    ///      escape the terminal haircut. Only relayed calls are affected: both sites call this
    ///      inside `effRelayerFee > 0`, and a self-submitted call carries no signature and hence
    ///      no fee, so users can always cancel by paying their own gas. Matching is halted in
    ///      all these states, so nothing fillable is trapped.
    function _chargeRelayerFee(address user, uint256 fee) internal {
        _requireNotHalted();
        _requireNoSweepWindow();
        BazaarTypes.PositionBucket storage bucket = positionBuckets[user];
        if (bucket.collateral < fee) revert BazaarPair__InsufficientCollateralForRelayerFee();
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
            if (amount <= relayerFee) revert BazaarPair__AmountLteRelayerFee();
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
    // Declared in BazaarTypes so the factory's up-front check and initialize's check below read one
    // value and cannot drift apart.
    uint256 internal constant MIN_INSURANCE_SEED = BazaarTypes.MIN_INSURANCE_SEED;

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

    /// @notice Bundled initialize() params — a single struct keeps the call site within via_ir's
    ///         stack limit.
    struct InitParams {
        bytes32 pairId;
        address oracle;
        address usdc;
        address bugBountyAddress;
        bytes32 baseFeedId;
        address umaContract;
        bool isContinuouslyTraded;
        address deployer;
        uint256 seedAmount;
    }

    /// @notice Initialize a cloned pair instance with pair-specific configuration.
    /// @dev Called once by the factory immediately after cloning. Cannot be called again.
    function initialize(InitParams calldata p) external initializer {
        if (
            p.oracle == address(0) || p.usdc == address(0) || p.bugBountyAddress == address(0)
                || p.umaContract == address(0) || p.deployer == address(0)
        ) revert BazaarPair__ZeroAddress();
        if (p.seedAmount < MIN_INSURANCE_SEED) revert BazaarPair__SeedBelowMinimum();

        pairId = p.pairId;
        oracle = BazaarOracle(p.oracle);
        usdc = IERC20(p.usdc);
        bugBountyAddress = p.bugBountyAddress;
        baseFeedId = p.baseFeedId;
        umaContract = p.umaContract;
        isContinuouslyTraded = p.isContinuouslyTraded;
        pairCreatedTs = block.timestamp;

        // Set initial margin requirements — use warmup floor until pair matures (20% IMR = 5x
        // max leverage; 40% = 2.5x for non-continuously traded, which have no reopen-gap
        // history yet)
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

    error BazaarPair__UnauthorizedInsuranceCreditor();

    /// @notice Externally transferred USDC was credited into the insurance fund bookkeeping.
    ///         `from` identifies the source (the terminator books forfeited insurer-termination
    ///         bonds).
    event InsuranceCredited(bytes32 indexed pairId, address indexed from, uint256 amountBazaarPrecision);

    /// @notice Credits already-transferred USDC into the insurance fund bookkeeping.
    /// @dev Pure bookkeeping, callable only by the terminator, which transfers the matching USDC
    ///      immediately before calling so the contract's USDC balance and the insurance
    ///      accounting stay in sync; mismatched amounts get caught by isVaultHealthy reason 3.
    function creditInsurance(uint256 amountBazaarPrecision) external {
        if (msg.sender != umaContract) {
            revert BazaarPair__UnauthorizedInsuranceCreditor();
        }
        pairVault.insuranceFundBalance += amountBazaarPrecision;
        emit InsuranceCredited(pairId, msg.sender, amountBazaarPrecision);
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
    error BazaarPair__RelayerFeeExceedsDeposit();
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
        (address user, uint256 effRelayerFee) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);
        // Round down to USDC (6-dp) granularity so the credited amount exactly matches the USDC
        // actually pulled (which is floored); avoids crediting unbacked sub-µUSDC dust.
        amount -= amount % 1e12;
        if (effRelayerFee >= amount) revert BazaarPair__RelayerFeeExceedsDeposit();

        // No new principal once the settlement price is fixed: matching is halted, so the
        // deposit could only sit frozen until finalize, and the terminal settlement's principal
        // denominator must stay stable once the window opens.
        _requireNoSweepWindow();

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
    /// @dev A position holder must be priced FRESH: the stale fallback is rejected for them
    ///      (equity is never released against a mark the oracle cannot currently attest — see
    ///      CollateralLib.withdrawCollateral for the rationale), while flat accounts read no
    ///      price at all and order-only accounts may value against the fallback.
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
        (address user, uint256 effRelayerFee) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);

        // Position-holders' withdrawals are frozen while ADL is pending. With trading frozen,
        // a withdrawal has no legitimate use for an open position: it can only strip margin or
        // reorder-grief pending keeper submissions (a submitted winners[] must stay descending
        // in adlScore, and a winner's score RISES as their cash falls — one small withdrawal
        // reverts a whole executeAdl batch). Flat users (collateral only, no position) are
        // unaffected: they have no ADL score and no margin role. Terminated pairs are exempt —
        // _terminatePair also clears isAdlPending, so the explicit flags here are defense in
        // depth against a future termination path forgetting to.
        if (isAdlPending && !_isTerminated() && positionBuckets[user].size != 0) {
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
        if (hasExposure && !_isTerminated()) {
            (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool isStale) =
                _getCurrentPairPrice(priceUpdate, msg.value);
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
            (vaultHealthy, vaultHealthReason) = isVaultHealthy(priceStruct.spotPrice, isStale);
        } else {
            refundBudget = msg.value;
        }

        BazaarTypes.CollateralWithdrawResult memory result = CollateralLib.withdrawCollateral(
            positionBuckets,
            terminalHaircutApplied,
            pairVault,
            terminalProfitClaim,
            terminalState,
            BazaarTypes.CollateralWithdrawParams({
                amount: amount,
                currentPrice: currentPrice,
                currentFundingIndex: currentFundingIndex,
                marginReqs: _marginReqsWithLag(),
                pairId: pairId,
                currentBlock: _l2Block(),
                isPairTerminatedEmergency: isPairTerminatedEmergency,
                isPairTerminatedNormal: isPairTerminatedNormal,
                pendingTermination: scheduledTerminationTs != 0 && block.timestamp >= scheduledTerminationTs
                    && !_isTerminated(),
                emergencyHaircutBp: emergencyTerminalCollateralWithdrawalRatioBp,
                isOracleStale: _isOracleStale,
                normalTerminationPrice: normalTerminationPrice,
                normalTerminalCollateralRatioBp: normalTerminalCollateralRatioBp,
                isVaultHealthy: vaultHealthy,
                vaultHealthReason: vaultHealthReason,
                outstandingLongOrderExposure: longOrderExposure,
                outstandingShortOrderExposure: shortOrderExposure,
                usdcToken: address(usdc),
                isContinuouslyTraded: isContinuouslyTraded
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
    /// @dev Epoch-stamped: `shareEpoch << 64 | timestamp` (epoch 0 reads as a plain timestamp).
    ///      A share-epoch bump (fund recap) voids pending requests — InsuranceVaultLib checks
    ///      the stamp on execute, so a ripe pre-recap request can't skip the cooldown.
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
        (address user, uint256 effRelayerFee) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);
        // Round down to USDC (6-dp) granularity so the credited amount exactly matches the USDC
        // actually pulled (which is floored); avoids crediting unbacked sub-µUSDC dust.
        amount -= amount % 1e12;
        if (effRelayerFee >= amount) revert BazaarPair__RelayerFeeExceedsDeposit();

        // No new LP principal once the settlement price is fixed: finalizeTermination charges
        // swept bad debt (pendingLiq settlement + deficit) to the insurance fund, so shares
        // minted mid-window would buy into a charge that predates the deposit.
        _requireNoSweepWindow();

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
        (address user, uint256 effRelayerFee) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);

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
        (address user, uint256 effRelayerFee) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);

        // Frozen during the terminal sweep window: finalizeTermination charges swept bad debt
        // (pendingLiq settlement + deficit) to the insurance fund — LPs must not exit ahead of it.
        _requireNoSweepWindow();

        // Update price feed first (needed for rate-limit calculations)
        (, uint256 ethRefund,) = _getCurrentPairPrice(priceUpdate, msg.value);

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
                reopenGapBp: isContinuouslyTraded ? 0 : uint256(reopenGapEma.gapEmaBp),
                lockedShares: IBazaarTerminator(umaContract).getLockedShares(address(this), user)
            }),
            user
        );
        totalInsuranceShares = newTotalShares;

        uint256 sharesBurned = prevTotalShares - newTotalShares;
        // Lots are not mutated by withdrawal. The lot list is a snipe-vote defense
        // (see getSharesAsOf / Terminator.voteForInsurerTermination); it bounds the
        // user's voting power at vote time but doesn't track ownership precisely.
        // The next deposit will prune any lots aged past INSURER_LOT_RETENTION_PERIOD.

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
            // CHECKED on purpose. `lot.shares` is full-width (see BazaarTypes.DepositLot), so this
            // sum is not structurally bounded away from 2^256. A wrap would UNDERSTATE immature
            // shares and therefore OVERSTATE mature voting power — fail-open on the anti-snipe
            // check. Reverting is the safe direction.
            sum += lot.shares;
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
        // Emergency-terminated pairs refund raw collateral only; nothing to settle or liquidate.
        if (isPairTerminatedEmergency) revert BazaarPair__TradingHalted();

        // Terminal settlement mode: once the settlement price is fixed (window open) or the pair
        // has normal-terminated (post-finalize), this SAME entry point marks positions to the
        // frozen price — pure accounting, no oracle read — reusing liquidate's calldata handling
        // and nonReentrant guard instead of a second external function (EIP-170 relief). priceUpdate
        // is ignored; any ETH is refunded. isPairTerminatedNormal selects the junior/late path.
        if (settlementPriceFixedTs != 0) {
            liquidatedCount = CollateralLib.settleTerminalPositions(
                positionBuckets,
                pairVault,
                terminalProfitClaim,
                terminalState,
                fixedSettlementPrice,
                currentFundingIndex,
                isPairTerminatedNormal,
                pairId,
                address(usdc),
                usersToLiquidate
            );
            _refundEth(msg.value);
            return liquidatedCount;
        }

        // Live liquidation path: halted once terminated or at/past the scheduled cutoff.
        if (isPairTerminatedNormal || (scheduledTerminationTs != 0 && block.timestamp >= scheduledTerminationTs)) {
            revert BazaarPair__TradingHalted();
        }

        (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool isPriceStale) =
            _getCurrentPairPrice(priceUpdate, msg.value);
        uint256 currentPrice = priceStruct.spotPrice;
        BazaarTypes.MarginRequirements memory liqMarginReqs = _marginReqsWithLag();

        // Liquidation uses plain oracle price. The 2% confidence-ratio cap at the oracle
        // layer is the conservatism gate; per-direction polarity here adds no clean win.
        BazaarTypes.LiquidateResult memory result = LiquidationLib.processLiquidations(
            usersToLiquidate,
            orders,
            book,
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

        if (liquidatedCount > 0) {
            // Cross the freshly seized inventory into the book BEFORE judging vault health, so
            // exposure the book can absorb right now never false-latches an ADL window. Bounded
            // by a fixed node budget to keep the liquidator's gas predictable; the
            // permissionless unloadVault finishes anything deeper. Skipped while ADL is already
            // pending — matching is frozen then and executeAdl owns the resolution.
            if (!isAdlPending) {
                BazaarTypes.WalkSummary memory sum = MatchingEngineLib.unloadBook(
                    orders,
                    positionBuckets,
                    userActiveLimitOrders,
                    pairVault,
                    book,
                    BazaarTypes.LIQ_INLINE_UNLOAD_STEPS,
                    false,
                    _buildArrivalCtx(currentPrice, isPriceStale, liqMarginReqs)
                );
                _postWalk(sum, currentPrice);
            }
            // Re-evaluate vault health after liquidations (live pair only; terminal settlement
            // never routes here). Exactly one health call per transaction — see _postWalk.
            isVaultHealthy(currentPrice, isPriceStale);
            // Refresh IMR/MMR + sample the curve so a mass liquidation (which burns insurance via
            // collateral seizure and liquidator rewards) feeds the instantaneous insurance
            // multiplier immediately. The helper skips if the health re-eval just terminated the
            // pair.
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

    // (No AdlExecutorRewarded event — the executor payout is observable as the USDC Transfer in
    //  the same transaction as AdlExecuted. Removed for EIP-170 headroom.)

    // -------------------- Functions --------------------

    /// @param priceUpdate Pyth price update data (can be empty for non-continuously traded pairs)
    function executeAdl(address[] calldata winners, bytes[] calldata priceUpdate) external payable nonReentrant {
        // A terminated pair has its pendingLiq zeroed and settles via withdrawals only — never
        // ADL. Same once the settlement price is fixed: only sweep-mode liquidations (at that
        // price) may mutate positions — an ADL at a live oracle price would corrupt the book.
        if (_isTerminalOrFixed()) {
            revert BazaarPair__TradingHalted();
        }
        if (!isAdlPending) revert BazaarPair__AdlNotPending();

        (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool isPriceStale) =
            _getCurrentPairPrice(priceUpdate, msg.value);
        uint256 currentPrice = priceStruct.spotPrice;

        // Re-validate the latch against the LIVE price BEFORE closing anyone
        (, uint8 healthReason) = isVaultHealthy(currentPrice, isPriceStale);

        if (healthReason == 1) {
            // An auction whose target side equals the side the vault itself holds has not been
            // re-targeted after a mid-auction flip — the re-target is withheld when the mark is
            // stale. Executing in that state would deleverage accounts that do not offset the
            // vault's exposure at all: eligibility only requires positive PnL against each
            // account's own entry, so profitable positions exist on both sides and the caller picks
            // which to submit, while _applyAdlVaultUpdate and the pendingLiq decrement would book
            // the closes as though they offset. Gated inside this branch so it never intercepts the
            // termination paths, which need no target side. A fresh mark re-targets in the
            // isVaultHealthy call above, so a caller supplying one clears this in the same
            // transaction.
            if (adlLongs == pairVault.pendingLiqIsLong) revert BazaarPair__AdlRetargetPending();

            // ADL uses plain oracle. Settlement and ranking use frozen prices already; the only
            // bracket-affected hook is the mid-batch vault-health re-check, which is an aggregate
            // decision where the 2% confidence-ratio cap is the real safety gate.
            // executeAdlCore emits AdlExecuted (declared here for the ABI, emitted in AdlLib via
            // DELEGATECALL to keep this contract under the code-size limit), so it needs the adlId.
            BazaarTypes.AdlResult memory r = AdlLib.executeAdlCore(
                orders,
                book,
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
                    // No dedicated event (EIP-170 headroom): the payout is already observable as
                    // the USDC Transfer to msg.sender in the same tx as AdlExecuted, which carries
                    // the adlId/submitter context an indexer needs to attribute it.
                    if (!_trySendUsdcReward(msg.sender, reward)) {
                        pairVault.insuranceFundBalance += reward;
                    }
                }
            }

            // Re-evaluate vault health (this updates isAdlPending: false once the deficit is resolved)
            isVaultHealthy(currentPrice, isPriceStale);
        }

        // On ADL completion (no longer pending and the pair survived), refresh IMR/MMR + sample so
        // the post-ADL insurance level feeds the margin curve immediately, not only on the next
        // arrival. While ADL is still pending the state is mid-resolution, so we wait.
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
    error BazaarPair__RequestorIsNotOrderOwner();

    // -------------------- Constants --------------------
    uint256 internal constant MIN_ORDER_AMOUNT = BazaarTypes.MIN_ORDER_AMOUNT; // min order size (5 USDC)
    uint256 internal constant MAX_SLIPPAGE_BP = BazaarTypes.MAX_SLIPPAGE_BP; // 10% max slippage for market-type orders
    uint256 internal constant MAX_CANCELS_PER_CALL = 200;

    // -------------------- Functions --------------------

    /// @notice Creates a new order and matches it against the book in the same transaction:
    ///         the arrival walk fills whatever crosses at each resting maker's price, then rests
    ///         the remainder (GTC limits, positioned by `hints`) or cancels it (Market/IOC,
    ///         post-only violation, self-match, step-cap, dust). Untriggered stops rest outside
    ///         the book awaiting executeTriggeredOrders.
    /// @param spec The signed order intent (covered by the EIP-712 payload).
    /// @param hints Execution aids — insertion predecessors and the walk's node budget. Outside
    ///        the signature (like priceUpdate): a relayer attaches fresh ones at submission, and
    ///        every hint is verified on-chain against the actual neighbors before linking.
    function createOrder(
        BazaarTypes.OrderSpec calldata spec,
        BazaarTypes.MatchHints calldata hints,
        bytes[] calldata priceUpdate,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature
    ) external payable nonReentrant {
        bytes32 structHash = keccak256(
            abi.encode(
                MetaTxLib.CREATE_ORDER_TYPEHASH,
                spec.orderType,
                spec.triggerPrice,
                spec.limitPrice,
                spec.maxSlippageBp,
                spec.size,
                spec.isLong,
                spec.isPostOnly,
                spec.isIoc,
                spec.expirationBlock,
                spec.integrator,
                nonce,
                deadline,
                relayerFee
            )
        );
        (address user, uint256 effRelayerFee) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);

        _requireLiveTrading();

        // Deduct relayer fee from collateral before margin check so the check accounts for it.
        // Debits both the bucket and D (see _chargeRelayerFee); the USDC leaves via _payRelayer below.
        if (effRelayerFee > 0) {
            _chargeRelayerFee(user, effRelayerFee);
        }

        (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool _isOracleStale) =
            _getCurrentPairPrice(priceUpdate, msg.value);

        // Refresh the margin curve + MMR sample ring on every arrival (both callees self-gate),
        // so the creation gate and the walk both judge against current parameters and the
        // 24h-lagged liquidation threshold keeps getting fed.
        _refreshMarginCurve(priceStruct.spotPrice);

        uint64 currentBlock = _l2Block();

        // Clean up expired limit orders and get directional exposure for margin calculation
        (uint256 longOrderExposure, uint256 shortOrderExposure) = _cleanupExpiredLimitOrders(user, currentBlock);

        uint256 orderId = nextOrderId;
        nextOrderId = OrderManagementLib.createOrder(
            orders,
            positionBuckets,
            userActiveLimitOrders,
            BazaarTypes.CreateOrderParams({
                pairId: pairId,
                spec: spec,
                // Spot values both legs the order is judged on: the existing bucket's notional and,
                // for a market order, the estimated execution price. A bracket edge would value the
                // position at a mark no other gate uses — the fill-time check and every later
                // solvency read measure it against spot — so the order gate would answer a
                // different question than the fill gate it is meant to anticipate.
                currentPrice: priceStruct.spotPrice,
                currentFundingIndex: currentFundingIndex,
                // createOrder gates on IMR over worst-case notional and on effectiveCollateral;
                // it never reads the MMR-derived minRequiredCollateral, so the lagged walk-back
                // would be computed and discarded. Pass the plain (un-lagged) requirements.
                marginReqs: marginRequirements,
                nextOrderId: orderId,
                outstandingLongOrderExposure: longOrderExposure,
                outstandingShortOrderExposure: shortOrderExposure,
                currentBlock: currentBlock
            }),
            user
        );

        BazaarTypes.MatchHints memory execHints = hints;
        // A relayer supplies the hints for a signature it did not produce. Predecessor hints are
        // harmless (verified against the real neighbours before linking), but the step budget
        // decides how much of the order executes — hitting the cap mid-cross cancels the
        // remainder. Only the signer may bound their own order, so a relayed call always runs
        // the protocol default; a self-submitted caller sets its own gas budget.
        if (signature.length > 0) execHints.maxSteps = 0;

        BazaarTypes.WalkSummary memory sum = MatchingEngineLib.executeArrival(
            orders,
            positionBuckets,
            userActiveLimitOrders,
            pairVault,
            book,
            orderId,
            execHints,
            _buildArrivalCtx(priceStruct.spotPrice, _isOracleStale, _marginReqsWithLag())
        );
        _postWalk(sum, priceStruct.spotPrice);
        if (sum.totalFillSize > 0) isVaultHealthy(priceStruct.spotPrice, _isOracleStale);

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
        (address user, uint256 effRelayerFee) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);

        // Reject an EMPTY list. With no order consumed the loop below is a no-op, so a relayed
        // cancelOrders([], …, relayerFee, sig) would be a standalone collateral-extraction
        // primitive: repeatable with fresh nonces until the bucket is empty, stripping every
        // dollar of margin from an open position with no health check. Requiring a live,
        // cancelable order per call bounds the below-margin overshoot to the per-user order cap,
        // since cancelOrder rejects already-canceled/filled/expired ids. The empty case reuses
        // the too-many-cancels error rather than declaring a second one.
        if (orderIds.length == 0 || orderIds.length > MAX_CANCELS_PER_CALL) {
            revert BazaarPair__ExceedsMaxCancelsPerCall();
        }

        uint64 currentBlock = _l2Block();
        for (uint256 i; i < orderIds.length; ++i) {
            if (orders[orderIds[i]].creator != user) {
                revert BazaarPair__RequestorIsNotOrderOwner();
            }
            OrderManagementLib.cancelOrder(
                orders, positionBuckets, userActiveLimitOrders, book, orderIds[i], pairId, currentBlock
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
                userActiveLimitOrders[user], orders, book, pairId, user, currentBlock
            );
    }

    /// @notice Permissionless expiry janitor: cancels + unlinks any of the given orders that
    ///         expired without reaching a terminal state; every other id is skipped silently.
    ///         The walk removes expired makers on contact and owners sweep their own during
    ///         create/withdraw — this lets anyone clear dead nodes from the book proactively.
    function sweepExpired(uint256[] calldata orderIds) external nonReentrant {
        // Gated like every other book mutation; the guard-free cancelOrders path remains the
        // owner's terminal-state escape hatch.
        _requireLiveTrading();
        OrderManagementLib.sweepExpired(orders, userActiveLimitOrders, book, orderIds, pairId, _l2Block());
    }

    /// @notice Read-only twin of _cleanupExpiredLimitOrders: a user's live limit-order exposure
    ///         per side, without the lazy pruning — safe to eth_call. Read by
    ///         BazaarPairLens.getMaxWithdrawable for off-chain withdrawal margin math.
    function outstandingOrderExposure(address user)
        external
        view
        returns (uint256 longExposure, uint256 shortExposure)
    {
        return OrderManagementLib.outstandingOrderExposure(userActiveLimitOrders[user], orders, _l2Block());
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║                  SECTION 8: ORDER MATCHING                   ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- Functions --------------------

    /// @dev Snapshot the tx-wide matching context: price, funding index, both insurance fee
    ///      rates, stale flag, and margin requirements (with the 24h-lagged MMR resolved by the
    ///      caller). Built once per entry point so every fill in the transaction judges against
    ///      the same basis.
    function _buildArrivalCtx(uint256 spot, bool stale, BazaarTypes.MarginRequirements memory mr)
        internal
        returns (BazaarTypes.ArrivalContext memory ctx)
    {
        ctx.cachedPrice = spot;
        ctx.cachedFundingIdx = currentFundingIndex;
        uint256 reopenGapBp = isContinuouslyTraded ? 0 : uint256(reopenGapEma.gapEmaBp);
        ctx.insuranceFeeEbp =
            RiskParamsLib.getTakerInsuranceFeeEbp(pairVault, lastPairPrice, liquidationGapEma, spot, reopenGapBp);
        ctx.closingFeeEbp = RiskParamsLib.getClosingFeeEbp(lastPairPrice, liquidationGapEma, reopenGapBp);
        ctx.isOracleStale = stale;
        ctx.marginReqs = mr;
        ctx.pairId = pairId;
        ctx.currentBlock = _l2Block();
        ctx.usdc = address(usdc);
        ctx.bugBountyAddress = bugBountyAddress;
    }

    /// @dev Shared prologue for the matching entry points: trading not halted (terminated or ADL
    ///      pending), not at/past the scheduled termination cutoff, no terminal sweep window.
    function _requireLiveTrading() internal view {
        _requireNotHalted();
        if (scheduledTerminationTs != 0 && block.timestamp >= scheduledTerminationTs) {
            revert BazaarPair__PairScheduledForTermination();
        }
        _requireNoSweepWindow();
    }

    /// @dev Post-walk bookkeeping shared by every matching entry point, all fill-gated: fold the
    ///      walk's VWAP into the mark price and its liquidation fills into the gap EMA.
    /// @dev Deliberately does NOT re-evaluate vault health — each entry point does that exactly
    ///      once itself. `_terminatePair` reverts on re-entry (`AlreadyTerminated`), so a second
    ///      health call in the same transaction would turn the very insolvency the check exists
    ///      to catch into a revert of the whole call.
    function _postWalk(BazaarTypes.WalkSummary memory sum, uint256 spot) internal {
        if (sum.totalFillSize == 0) return;
        // totalMatchedVolume IS Σ(price × size): exact VWAP numerator and exact total
        // notional, so no re-derivation through an average price is needed.
        uint256 vwap = Math.mulDiv(sum.totalMatchedVolume, BAZAAR_SCALE, sum.totalFillSize);
        _updateMarkPrice(vwap, sum.totalMatchedVolume, spot);
        if (sum.liqCount != 0) {
            RiskParamsLib.updateLiquidationGapEmaBatch(
                liquidationGapEma, sum.sumLiqGapTimesSize, sum.totalLiqFillSize, sum.liqCount
            );
        }
    }

    /// @notice Permissionless keeper entry point: fire triggered StopLimit/StopLoss orders
    ///         against a fresh oracle price. Each fired stop pays the caller TRIGGER_TIP from
    ///         its owner's collateral; owners who cannot cover it have the stop auto-canceled.
    ///         Ineligible ids (untriggered, dead, wrong type, already armed) are skipped
    ///         silently so racing keepers never revert each other.
    function executeTriggeredOrders(BazaarTypes.TriggerExec[] calldata execs, bytes[] calldata priceUpdate)
        external
        payable
        nonReentrant
        returns (uint256 executedCount)
    {
        _requireLiveTrading();

        // Staleness is rejected inside the walk library (trigger evaluation and StopLoss pricing
        // are oracle-derived), so the ctx carries the flag through unmodified.
        (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool _isOracleStale) =
            _getCurrentPairPrice(priceUpdate, msg.value);

        _refreshMarginCurve(priceStruct.spotPrice);

        BazaarTypes.WalkSummary memory sum;
        (executedCount, sum) = MatchingEngineLib.executeTriggers(
            orders,
            positionBuckets,
            userActiveLimitOrders,
            pairVault,
            book,
            execs,
            _buildArrivalCtx(priceStruct.spotPrice, _isOracleStale, _marginReqsWithLag())
        );
        _postWalk(sum, priceStruct.spotPrice);
        if (sum.totalFillSize > 0) isVaultHealthy(priceStruct.spotPrice, _isOracleStale);

        _refundEth(ethRefund);
    }

    /// @notice Permissionless keeper entry point: cross the vault's pending liquidation
    ///         inventory into the book within the liquidation band. The caller's reward —
    ///         max(MIN_LIQUIDATOR_REWARD, LIQUIDATION_FEE_EBP of unloaded notional) from
    ///         insurance, gated by UNLOAD_BOUNTY_MIN_NOTIONAL — is paid inside the walk library.
    /// @param maxSteps Node budget for the walk (0 = protocol default; clamped to
    ///        MAX_WALK_STEPS).
    function unloadVault(uint256 maxSteps, bytes[] calldata priceUpdate)
        external
        payable
        nonReentrant
        returns (uint256 unloadedSize)
    {
        _requireLiveTrading();

        // The stale fallback is allowed: liquidation flow is forced, and the unload band
        // (min(LIQ_MAX_SLIPPAGE_BP, MMR) around the reference price) sits inside the stale
        // fill band.
        (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool _isOracleStale) =
            _getCurrentPairPrice(priceUpdate, msg.value);

        _refreshMarginCurve(priceStruct.spotPrice);

        BazaarTypes.WalkSummary memory sum = MatchingEngineLib.unloadBook(
            orders,
            positionBuckets,
            userActiveLimitOrders,
            pairVault,
            book,
            maxSteps,
            true,
            _buildArrivalCtx(priceStruct.spotPrice, _isOracleStale, _marginReqsWithLag())
        );
        unloadedSize = sum.totalFillSize;
        _postWalk(sum, priceStruct.spotPrice);
        if (unloadedSize > 0) isVaultHealthy(priceStruct.spotPrice, _isOracleStale);

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
            reopenGapEma,
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
        if (_isTerminated()) return;
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
    uint256 internal emergencyTerminalCollateralWithdrawalRatioBp = 0; // caps emergency-termination collateral withdrawals to a share of original collateral
    uint256 internal normalTerminalCollateralRatioBp = 0; // deep-insolvency principal haircut on normal termination (BP_SCALE = no haircut)
    // The frozen profit ratio is not a slot here: it lives in terminalState.profitRatioBp and is
    // surfaced through auxState().

    // 24h-lagged-MMR ring buffer. Declared LAST so all existing storage slots keep their indices
    // (append-only is required for the upgradeable/proxy layout). See MmrSampleLib + MMR_* constants.
    BazaarTypes.MmrSampleBuffer internal mmrBuffer;

    // Insurance share-epoch state (append-only layout: added after mmrBuffer). A drained-fund
    // recap bumps shareEpoch; rawInsuranceShares entries stamped with an older shareEpochOf
    // read as 0 via the insuranceShares(address) getter. See InsuranceVaultLib.
    uint256 internal shareEpoch;
    mapping(address => uint256) internal shareEpochOf;

    // -------------------- Constants --------------------
    /// @notice Settlement window between fixing the price and finalizing. During it, deposits
    ///         and all withdrawals are frozen while permissionless settleTerminalPositions marks
    ///         every position to the fixed price — registering winner profit claims and bad
    ///         debt. Finalize then charges bad debt to insurance and freezes the profit ratio.
    uint256 internal constant TERMINAL_SETTLEMENT_WINDOW = 48 hours;

    // -------------------- Errors --------------------
    // No pair-side event: the terminator initiates every fix path and emits SettlementPriceFixed
    // itself, which keeps that bytecode out of the pair's EIP-170 budget. One shared error covers
    // every window-blocked action, finalize-too-early included.
    error BazaarPair__SweepWindowActive();

    // -------------------- Functions --------------------

    /// @notice Stage 1 of normal termination: pin the settlement price and open the sweep
    ///         window. Callable only by BazaarPairTerminator (every normal-termination path:
    ///         scheduled, post-cessation, insurer-vote, 21-day stale). Also stamps
    ///         scheduledTerminationTs — setting it when unset (insurer-vote / stale paths) and
    ///         pulling a still-future scheduled cutoff back to now — so every limbo guard —
    ///         matching, orders, deposits, price-storage freeze — engages at once.
    /// @dev The autonomous insolvency path opens the same window by calling _fixSettlement
    ///      directly rather than through this entry point; only emergency termination skips the
    ///      window, since it fires mid-transaction and cannot wait.
    function fixSettlementPrice(uint256 settlementPrice) external onlyUma {
        // Already-fixed reuses AlreadyTerminated: to every caller the pair is equally claimed.
        // The zero check must live HERE (not only in TerminationLib): a stored 0 would make
        // finalize revert forever with withdrawals frozen — fail at stage 1, where the
        // terminator can retry, never after the window state is latched.
        if (_isTerminalOrFixed()) {
            revert BazaarPair__AlreadyTerminated();
        }
        if (settlementPrice == 0) revert BazaarPair__NoPriceUpdatesProvided();
        _fixSettlement(settlementPrice);
    }

    /// @dev Latch the settlement price and open the 48h settlement window. Shared by the external
    ///      terminator entry point and the autonomous insolvency path — routing insolvency here
    ///      (rather than terminating mid-transaction) gives those positions the same settlement
    ///      window, and freezing withdrawals instantly is exactly what the Check-0 deficit guard
    ///      wants. Stamps scheduledTerminationTs — setting it when unset, and pulling a
    ///      still-future scheduled cutoff back to now — so all limbo guards (matching, orders,
    ///      deposits, price storage) engage at once. The pull-back is required because fixing the
    ///      price IS the end of trading: an accepted scheduled-termination proposal leaves a
    ///      future cutoff in place, and if insolvency or an insurer vote then fixed the price
    ///      without clamping it, every cutoff-keyed guard would keep matching, orders and
    ///      deposits live at the oracle price for the whole sweep window while liquidate settles
    ///      anyone on demand at the frozen price — a free exit from every losing position.
    ///      The guards compare with >=, NOT >: the stamp IS block.timestamp here, so a strict >
    ///      would leave the stamping second open — and since both terminator entry points are
    ///      permissionless, a contract could fix the price and then trade/deposit against it in
    ///      the SAME transaction (Arbitrum's shared block timestamps widen it further). Inclusive
    ///      is also correct on the scheduled path: lastTradingTs is the second whose Pyth tick
    ///      settles the pair, so trading must already be halted there.
    function _fixSettlement(uint256 settlementPrice) internal {
        fixedSettlementPrice = settlementPrice;
        settlementPriceFixedTs = block.timestamp;
        if (scheduledTerminationTs == 0 || scheduledTerminationTs > block.timestamp) {
            scheduledTerminationTs = block.timestamp;
        }
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
        if (settlementPriceFixedTs == 0 || block.timestamp < settlementPriceFixedTs + TERMINAL_SETTLEMENT_WINDOW) {
            revert BazaarPair__SweepWindowActive();
        }
        _terminatePair(false, fixedSettlementPrice);
    }

    /// @dev True once the pair is terminated in either mode.
    function _isTerminated() internal view returns (bool) {
        return isPairTerminatedEmergency || isPairTerminatedNormal;
    }

    /// @dev True once any terminal latch is set: terminated in either mode, or the settlement
    ///      price is fixed (sweep window open).
    function _isTerminalOrFixed() internal view returns (bool) {
        return _isTerminated() || settlementPriceFixedTs != 0;
    }

    /// @dev Shared terminated-or-ADL halt, used by createOrder and _chargeRelayerFee.
    function _requireNotHalted() internal view {
        if (_isTerminated() || isAdlPending) revert BazaarPair__TradingHalted();
    }

    /// @dev Shared freeze for user-facing entry points — matching, orders, deposits, withdrawals —
    ///      during the terminal sweep window (settlement price fixed, finalize pending). Lifts
    ///      the moment the pair terminates.
    function _requireNoSweepWindow() internal view {
        if (settlementPriceFixedTs != 0 && !_isTerminated()) {
            revert BazaarPair__SweepWindowActive();
        }
    }

    /// @dev Autonomous insolvency response (Check-0 deficit, ADL-timeout). Rather than terminating
    ///      mid-transaction, this FIXES the settlement price at the live price and opens the 48h
    ///      window: bots settle every underwater position into bad debt, finalize charges it to
    ///      insurance and freezes the profit ratio from real cash. Withdrawals freeze immediately
    ///      (what the deficit guard needs) and the insolvency path gets the same fair, per-user
    ///      settlement as every other normal path.
    ///      The `currentPrice == 0` arm goes straight to emergency termination (raw collateral,
    ///      no window): a zero settlement price cannot open a coherent window, and this arm exists
    ///      only as defense against a future zero-price path — it must never brick the terminate.
    ///      If a window is already open (double-detection across calls) this is a no-op.
    function _terminateOnInsolvency(uint256 currentPrice) internal {
        if (currentPrice > 0) {
            if (settlementPriceFixedTs == 0) _fixSettlement(currentPrice);
        } else {
            _terminatePair(true, 0);
        }
    }

    /// @notice Terminates the pair, settling pending liquidation obligations and setting withdrawal parameters
    /// @dev Delegates to TerminationLib via DELEGATECALL. Writes back scalar state from the result.
    /// @param isEmergency If true, emergency termination (Check 3 failure); if false, normal termination (delisting/acquisition)
    /// @param terminationPrice The price to settle at (only used for normal termination)
    function _terminatePair(bool isEmergency, uint256 terminationPrice) internal {
        if (_isTerminated()) revert BazaarPair__AlreadyTerminated();

        BazaarTypes.TerminationResult memory result = TerminationLib.executeTermination(
            pairVault,
            terminalState,
            BazaarTypes.TerminationParams({
                isEmergency: isEmergency,
                terminationPrice: terminationPrice,
                usdc: address(usdc),
                pairId: pairId,
                currentFundingIndex: currentFundingIndex
            })
        );

        // Write back scalar state from result
        if (result.isEmergency) {
            isPairTerminatedEmergency = true;
            emergencyTerminalCollateralWithdrawalRatioBp = result.emergencyCollateralRatioBp;
        } else if (result.isNormal) {
            isPairTerminatedNormal = true;
            normalTerminationPrice = result.normalTerminationPrice;
            // The frozen profit ratio is written by the lib into terminalState.profitRatioBp;
            // what lands here is the deep-insolvency principal haircut (BP_SCALE = none).
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
    /// @param isPriceStale True when currentPrice came from the stale fallback rather than a fresh
    ///        oracle read. Blocks opening a NEW ADL window; every other check is unaffected.
    /// @return healthy True if vault passes all health checks
    /// @return reason 0 = healthy,
    ///                1 = liquidation exposure exceeds insurance (triggers/extends ADL, not termination),
    ///                2 = ADL auction timeout expired (terminates the pair),
    ///                3 = actual USDC balance shortfall vs bookkeeping (emergency-terminates the pair),
    ///                4 = realized bad debt (insolvency) — terminates the pair
    function isVaultHealthy(uint256 currentPrice, bool isPriceStale) internal returns (bool healthy, uint8 reason) {
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

        // Opening a NEW window is gated on a fresh price. Everything an auction is judged by is
        // frozen at the instant it opens — which side is deleveraged, the ranking snapshot, and the
        // 24h clock — and a stale mark is whichever real tick someone last recorded, not the book's
        // exposure now. Opening on one deleverages profitable counterparties in response to stress
        // that may no longer exist, and they are not in breach of anything. The verdict is still
        // reported (reason 1), so callers that gate on vault health stay conservative; only the
        // irreversible latch is withheld. Extending and clearing a window already opened against a
        // fresh price are untouched, so an in-flight auction still resolves while the feed is quiet.
        if (result.newIsAdlPending && !isAdlPending && isPriceStale) {
            return (false, 1);
        }

        // A mid-auction side flip is the one path that moves adlSnapshotPrice after the window
        // opened, so it needs the same freshness gate. That snapshot is not merely a sort key:
        // AdlLib's eligibility scan skips every account whose PnL measured at it is non-positive,
        // so the snapshot decides who can be deleveraged at all. Re-snapshotting from a stale mark
        // would let whoever triggers the flip choose a price at which an account underwater at the
        // live market shows a paper profit, and close it as a winner — in the same transaction,
        // since liquidating the opposing side both causes the flip and lands here.
        //
        // Withholding the re-target leaves adlLongs pointing at the side the vault itself holds,
        // which is not a safe state to execute in — eligibility only requires positive PnL against
        // an account's own entry, so profitable positions exist on both sides. executeAdl refuses
        // outright while the target and the vault's side agree; that guard, not any property of the
        // eligible set, is what makes withholding safe. Any fresh-priced call re-targets and
        // resumes the auction, and the timeout cannot terminate the pair meanwhile because it too
        // requires a fresh price.
        bool staleRetarget =
            isPriceStale && isAdlPending && result.newIsAdlPending && adlLongs == pairVault.pendingLiqIsLong;

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
        if (!staleRetarget) {
            adlSnapshotPrice = result.newAdlSnapshotPrice;
            adlSnapshotFundingIndex = result.newAdlSnapshotFundingIndex;
            adlLongs = result.newAdlLongs;
        }

        if (result.adlTimeoutExpired && !isPriceStale) {
            // Price-driven insolvency: the vault could not deleverage a real move within the auction
            // window. Settle via the equity path at the live price so winners and losers settle
            // fairly, rather than refunding collateral (which would hand losers a windfall).
            //
            // Requiring a fresh price fixes the whole book's settlement to a mark the oracle just
            // confirmed, rather than to whichever real tick someone last recorded. The expired
            // clock is not lost by deferring: it stays expired, so the first caller carrying a
            // fresh price terminates. Nor can withholding freshness stall termination — anyone who
            // wants it can permissionlessly refresh the price and fire it, and a feed dead long
            // enough to make that impossible is what BazaarPairTerminator.terminateStalePair is
            // for. Meanwhile ADL stays callable on a stale mark, so the exposure this clock is
            // counting can still be resolved while the feed is quiet.
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

    /// @notice Permissionless price + margin-curve refresher. Pushes the supplied Pyth update
    ///         (or relies on Pyth's on-chain cache), writes the result to lastPairPrice, then
    ///         recomputes IMR/MMR and records a 24h-lagged MMR ring sample from it. A caller
    ///         whose refresh ends a stale gap on an active pair may earn a small insurance-funded
    ///         bounty (RiskParamsLib.payRefreshBounty holds the gates and amount).
    /// @dev    Pays the Pyth fee from msg.value and refunds any unused ETH. The margin leg exists
    ///         so the sample ring keeps advancing through trading gaps — the matching entry
    ///         points only resample on arrivals and liquidate() after a successful liquidation,
    ///         so a quiet pair would otherwise freeze laggedMmr() at an arbitrarily old value.
    ///         On a halted pair only the price refresh runs (margin params are moot then), and
    ///         the bounty is withheld from the moment any terminal latch is set — terminated
    ///         either way, or the settlement price fixed (sweep window open): from then on the
    ///         insurance fund backs settlement claims, and freshness no longer protects anyone.
    function refreshPrice(bytes[] calldata priceUpdate) external payable nonReentrant {
        uint256 prevUpdateTs = lastPairPrice.updateTs;
        (BazaarTypes.PairPrice memory priceStruct, uint256 unusedEth,) =
            _getCurrentPairPrice(priceUpdate, msg.value);
        _refreshMarginCurve(priceStruct.spotPrice);
        if (!_isTerminalOrFixed()) {
            RiskParamsLib.payRefreshBounty(pairVault, lastPairPrice, address(usdc), prevUpdateTs);
        }
        _refundEth(unusedEth);
    }

    /// @notice Fetches the current pair price, paying for a Pyth update only when the on-chain
    ///         cache cannot serve a fresh, confidence-checked price.
    /// @dev Resolution order: (1) Pyth on-chain cache → (2) caller-supplied priceUpdate →
    ///      (3) the pair's last stored price (non-continuously-traded pairs only) → revert. Steps 1
    ///      and 2 store the result in lastPairPrice; step 3 only reads it. Both freshness gates use
    ///      MAX_PRICE_STALENESS whoever submits, so a caller that cannot land an update inside
    ///      that window must either ride a cache someone else already refreshed or sign a
    ///      meta-transaction: priceUpdate sits outside every EIP-712 payload, so a relayer can
    ///      attach a fresh one to a signature minted much earlier. Does NOT refund ETH — the
    ///      caller must handle the returned unusedEth.
    /// @param priceUpdate The signed Pyth price update messages (may be empty)
    /// @param ethBudget The ETH available to pay the Pyth update fee
    /// @return priceStruct The resolved pair price
    /// @return unusedEth The ETH not spent on the oracle update, for the caller to refund
    /// @return isStale True when the price came from the step-3 stale fallback
    function _getCurrentPairPrice(bytes[] calldata priceUpdate, uint256 ethBudget)
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
            uint256 fee = oracle.getUpdateFee(priceUpdate);
            if (fee > budget) revert BazaarPair__InsufficientPythFee();

            (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime) =
                oracle.updateAndFetchPrice{value: fee}(baseFeedId, priceUpdate, MAX_PRICE_STALENESS);
            budget -= fee;

            (priceStruct,) = _buildAndStorePairPrice(spotPrice, lowPrice, highPrice, publishTime, 0);
            return (priceStruct, budget, false);
        }

        // Step 3: No fresh price and no caller update — fall back to the pair's own last stored
        // price, for non-continuously traded pairs only. lastPairPrice is written only by steps 1
        // and 2, so whatever it holds cleared both the freshness gate and the 2% confidence cap at
        // the moment it was recorded: the fallback ages, but it is never a mark nobody validated.
        //
        // Pyth's own cache is deliberately not read here even though it may carry a more recent
        // tick. That cache is permissionlessly writable to any published update, so consulting it
        // would let whoever submits the call select which historical mark their liquidation, ADL
        // or valuation is judged against — the price would become an attacker input on exactly the
        // paths that move the most value. Reading only lastPairPrice removes the choice: the sole
        // way to advance this mark is refreshPrice (or any priced entry point), and those can only
        // ever store a price that is fresh at the time they run.
        if (!isContinuouslyTraded && lastPairPrice.spotPrice > 0) {
            return (lastPairPrice, budget, true);
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
            // Advance the variance EMA first: it reads the prior EMA out of lastPairPrice, which
            // the store below overwrites.
            uint256 emaVarianceBp =
                RiskParamsLib.calculateVariance(lastPairPrice, varianceSample, reopenGapEma, spotPrice, publishTime);

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
        if (from == address(0) || to == address(0)) revert BazaarPair__TransferFailed();
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
        s.normalTerminalWinnersPayoutRatioBp = terminalState.profitRatioBp; // frozen profit ratio
        s.bugBountyAddress = bugBountyAddress;
    }

    /// @notice The window-deposit amount ADL ranking subtracts from `user`'s collateral: their
    ///         deposits epoch-tagged to the CURRENT ADL window, 0 when the tag is absent or
    ///         stale. Read by BazaarPairLens.getAdlScore and by keepers pre-sorting executeAdl
    ///         batches, so score previews apply the same epoch check the on-chain ranking does.
    function adlScoreDeposit(address user) external view returns (uint256) {
        return adlDepositEpoch[user] == adlEpoch ? adlWindowDeposits[user] : 0;
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

    /// @notice Per-user registered profit claims + aggregate terminal-settlement state for the
    ///         frozen-ratio termination design (appended last to preserve earlier slots).
    ///         The claim mapping is public: winners and bounty-holding settlers read their
    ///         registered claim through it (BazaarPairLens.getTerminalEntitlement).
    mapping(address => uint256) public terminalProfitClaim;
    BazaarTypes.TerminalSettlement internal terminalState;

    /// @notice Terminal-sweep settlement state (appended last to preserve earlier slots).
    ///         fixSettlementPrice pins the verified settlement tick and opens a
    ///         TERMINAL_SWEEP_WINDOW during which liquidate() runs in sweep mode (fixed price,
    ///         equity <= 0 threshold, no oracle read) so positions with negative equity at the
    ///         settlement price fold into pendingLiq — and thus into the insurance/haircut
    ///         waterfall — before finalizeTermination settles the book.
    uint256 public fixedSettlementPrice; // public: sweep keepers price bounties against it
    uint256 public settlementPriceFixedTs;

    /// @notice Peak-hold reopen-gap floor for non-continuously traded pairs (appended last to
    ///         preserve earlier slots). Written by RiskParamsLib.calculateVariance when a stored
    ///         price ends a gap of at least REOPEN_GAP_MIN_STALENESS; read by
    ///         RiskParamsLib.calculateIMRandMMR as an IMR floor.
    BazaarTypes.ReopenGapEma internal reopenGapEma;
}
