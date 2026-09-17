// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

// -------------------- Imports --------------------
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BazaarOracle} from "./BazaarOracle.sol";
import {BazaarTypes} from "./libraries/BazaarTypes.sol";
import {BazaarMathLib} from "./libraries/BazaarMathLib.sol";
import {MmrSampleLib} from "./libraries/MmrSampleLib.sol";
import {MatchingEngineLib} from "./libraries/MatchingEngineLib.sol";
import {OrderManagementLib} from "./libraries/OrderManagementLib.sol";
import {CollateralLib} from "./libraries/CollateralLib.sol";
import {FeeEscrowLib} from "./libraries/FeeEscrowLib.sol";
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
    error BazaarPair__AdlPriceStale();
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
    bool public isPairTerminated = false; // finalized: no deposits/orders/matching, only terminal withdrawals
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

    /// @notice Accrues a relayer fee to msg.sender's claimable balance and emits
    ///         MetaTransactionExecuted. The USDC backing it is already in the contract — pulled
    ///         from the signer's wallet by the caller, or withheld from a payout the signer is
    ///         owed — and the relayer pulls it via claimFees like every other third-party payout.
    function _accrueRelayerFee(address user, uint256 relayerFee, bytes32 typehash, uint256 nonce) internal {
        FeeEscrowLib.credit(feeEscrow, pairId, msg.sender, relayerFee);
        emit BazaarTypes.MetaTransactionExecuted(pairId, user, msg.sender, typehash, nonce, relayerFee);
    }

    /// @notice Funds a relayed fee from the signer's wallet — executing an optional ERC-2612
    ///         permit first — and accrues it to msg.sender. For relayed calls that move no USDC
    ///         of their own (createOrder, cancelOrders, requestInsuranceWithdrawal).
    /// @dev The fee is never drawn from bucket collateral. Collateral backs an open position and
    ///      leaves only through withdrawCollateral, which prices the bucket and enforces the
    ///      solvency, retained-cash and IMR gates; a fee debited from the bucket here would be a
    ///      second exit that skips all of them, and since a user may relay their own signed call,
    ///      it would be a collateral-to-wallet pump repeatable regardless of margin. A wallet pull
    ///      touches neither the bucket nor totalCollateralDeposited, so the fee needs no lifecycle
    ///      gate of its own and a relayed cancel stays available in every state a self-submitted
    ///      one is. Without an allowance (or a valid permit) the pull reverts; there is no
    ///      collateral fallback.
    function _pullRelayerFee(address user, uint256 fee, bytes calldata permitData, bytes32 typehash, uint256 nonce)
        internal
    {
        if (permitData.length > 0) _executePermit(user, permitData);
        _sendUsdc(user, address(this), fee);
        _accrueRelayerFee(user, fee, typehash, nonce);
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

    /// @notice Pays `user` the `amount` they are owed less the relayer fee, which stays in the
    ///         contract and accrues to the relayer.
    function _sendWithRelayerFee(address user, uint256 amount, uint256 relayerFee, bytes32 typehash, uint256 nonce)
        internal
    {
        if (relayerFee > 0) {
            if (amount <= relayerFee) revert BazaarPair__AmountLteRelayerFee();
            _sendUsdc(address(this), user, amount - relayerFee);
            _accrueRelayerFee(user, relayerFee, typehash, nonce);
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
            // transient per-batch fields; never persisted to storage
            laggedMmrBp: 0,
            laggedMmrTs: 0
        });

        // Initialize ID counters at 1
        nextOrderId = 1;
        nextAdlId = 1;

        // Record insurance fund seed (USDC transfer handled by factory).
        // shareEpochOf[deployer] stays 0 == the initial shareEpoch, so no stamp is needed.
        rawInsuranceShares[p.deployer] = p.seedAmount;
        totalInsuranceShares = p.seedAmount;
        pairVault.insuranceFundBalance = p.seedAmount;
        // The seed carries a deposit lot like every other deposit. Maturity is computed as
        // total shares minus immature lots, so a lot-less seed would read as mature at every
        // cutoff and let the deployer propose and vote the full seed the moment the pair
        // exists rather than after INSURER_SHARE_MATURITY_PERIOD. Appended directly rather
        // than through the deposit path: the per-window deposit counter is for user deposits,
        // and as the list's first entry the lot keeps the timestamp order the maturity walk
        // relies on.
        insuranceDepositLots[p.deployer].push(BazaarTypes.DepositLot(uint64(block.timestamp), p.seedAmount));

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
    ///         accepted termination proposal; lastTradingTs is already past when a disputed
    ///         proposal resolves late, and trading then halts immediately)
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
    ///         $100, accrued to the proposer's claimable balance. Math + escrow credit live in
    ///         InsuranceVaultLib (EIP-170 relief); only the once-flag is kept here so the reward
    ///         can't be retried.
    function _payUmaProposerReward(address proposer) internal {
        if (umaProposerRewardPaid || proposer == address(0)) return;
        umaProposerRewardPaid = true;
        InsuranceVaultLib.payUmaProposerReward(pairVault, feeEscrow, pairId, proposer);
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
        (mr.laggedMmrBp, mr.laggedMmrTs) = _laggedMmr();
    }

    /// @notice The lagged MMR the pair currently judges positions against, and the timestamp it was
    ///         sampled at; (0, 0) when the ring holds nothing old enough.
    /// @dev The MMR_GRACE_PERIOD lookback is measured back from lastPairPrice.updateTs — the mark
    ///      positions are valued against — rather than from the calling block, so both legs of a
    ///      solvency test describe the same instant. The two diverge whenever a call resolves the
    ///      stale fallback: measuring from the block would judge a position on a price from one
    ///      moment against a threshold from another, and the gap is schedulable rather than
    ///      incidental. Sample timestamps are readable from storage, so the instant the cutoff
    ///      admits a newer (possibly higher) sample is public knowledge; anchoring to the block
    ///      would let a caller record an adverse mark and then wait for that instant to arrive,
    ///      choosing price and threshold independently. Anchored to the mark, one choice fixes
    ///      both. updateTs is clamped to the block because Pyth publish times may run slightly
    ///      ahead of it, and a mark stamped in the future must not shorten the grace.
    /// @return mmrBp    The lagged MMR in basis points.
    /// @return sampleTs The timestamp that sample was recorded at.
    function _laggedMmr() internal view returns (uint256 mmrBp, uint256 sampleTs) {
        uint256 refTs = lastPairPrice.updateTs;
        if (refTs > block.timestamp) refTs = block.timestamp;
        return MmrSampleLib.laggedMmr(mmrBuffer, refTs);
    }

    /// @notice The lagged MMR and its sample timestamp, as _laggedMmr resolves them.
    /// @dev Exposed so BazaarPairLens / liquidation bots evaluate solvency against the threshold
    ///      the pair applies. Both halves are needed: BucketLib.effectiveMmr adopts the lagged rate
    ///      only for positions whose mmrUpdateTs is at or before `sampleTs`, so a consumer holding
    ///      the rate alone cannot reproduce the on-chain threshold. What this returns is resolved
    ///      against the stored mark, so a consumer simulating a call that carries its own fresh
    ///      priceUpdate should expect the threshold to move with the mark that update writes.
    /// @return mmrBp    The lagged MMR in basis points.
    /// @return sampleTs The timestamp that sample was recorded at.
    function getLaggedMmr() external view returns (uint256 mmrBp, uint256 sampleTs) {
        return _laggedMmr();
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
        // deposit could only sit frozen until finalize, and the total owed that finalize derives
        // from the ledgers must not move once the window opens.
        _requireNoSweepWindow();

        CollateralLib.depositCollateral(
            positionBuckets,
            BazaarTypes.DepositParams({
                amount: amount,
                currentFundingIndex: currentFundingIndex,
                marginReqs: marginRequirements,
                pairId: pairId,
                currentBlock: _l2Block(),
                isPairTerminated: isPairTerminated,
                scheduledTerminationTs: scheduledTerminationTs
            }),
            user
        );

        // Execute ERC-2612 permit if provided (allows gasless USDC approval)
        if (permitData.length > 0) {
            _executePermit(user, permitData);
        }

        // Transfer USDC from user to contract (deposit + relayer fee); the fee stays here,
        // accrued to the relayer below
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

        if (effRelayerFee > 0) {
            _accrueRelayerFee(user, effRelayerFee, MetaTxLib.DEPOSIT_COLLATERAL_TYPEHASH, nonce);
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
        if (isAdlPending && !isPairTerminated && positionBuckets[user].size != 0) {
            revert BazaarPair__WithdrawalsFrozenAdlPending();
        }

        // ALL collateral withdrawals (flat users included) are frozen while the settlement
        // window is open: nothing may leave before finalize freezes the payout ratios.
        _requireNoSweepWindow();

        // Clean up expired limit orders and get directional exposure
        (uint256 longOrderExposure, uint256 shortOrderExposure, uint256 longOrderSize, uint256 shortOrderSize) =
            _cleanupExpiredLimitOrders(user, _l2Block());

        // Get price and vault health when user has exposure
        uint256 currentPrice;
        uint256 refundBudget;
        // The verdict is carried by the reason code alone (0 = healthy) and the bool is derived
        // at the struct literal below: this function sits at the via-IR stack limit, and a
        // second local held live across the exposure branch is one slot too many.
        uint8 vaultHealthReason;

        bool hasExposure = positionBuckets[user].size != 0 || longOrderSize > 0 || shortOrderSize > 0;
        bool _isOracleStale;
        if (hasExposure && !isPairTerminated) {
            (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool isStale) =
                _getCurrentPairPrice(priceUpdate, msg.value);
            // Conservative price for the user's bucket: long → low, short → high.
            // Flat with only orders → spot (the order tally below reserves at no less than it).
            BazaarTypes.PositionBucket storage b = positionBuckets[user];
            if (b.size == 0) {
                currentPrice = priceStruct.spotPrice;
            } else {
                currentPrice = b.isLong ? priceStruct.lowPrice : priceStruct.highPrice;
            }
            // Order exposure is reserved at no less than the mark, mirroring createOrder's
            // reservation rule: a resting bid below the mark tallied at its own limit would let
            // a withdrawal leave less collateral than any fill of that bid will demand, walking
            // the owner into an order that can only ever be auto-canceled at the fill gate.
            {
                uint256 atMark = Math.mulDiv(longOrderSize, priceStruct.spotPrice, BazaarTypes.BAZAAR_SCALE);
                if (atMark > longOrderExposure) longOrderExposure = atMark;
                atMark = Math.mulDiv(shortOrderSize, priceStruct.spotPrice, BazaarTypes.BAZAAR_SCALE);
                if (atMark > shortOrderExposure) shortOrderExposure = atMark;
            }
            refundBudget = ethRefund;
            _isOracleStale = isStale;
            (, vaultHealthReason) = isVaultHealthy(priceStruct.spotPrice, isStale);
        } else {
            refundBudget = msg.value;
        }

        uint256 withdrawAmount = CollateralLib.withdrawCollateral(
            positionBuckets,
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
                isPairTerminated: isPairTerminated,
                pendingTermination: scheduledTerminationTs != 0 && block.timestamp >= scheduledTerminationTs
                    && !isPairTerminated,
                isOracleStale: _isOracleStale,
                settlementPrice: fixedSettlementPrice,
                isVaultHealthy: vaultHealthReason == 0,
                vaultHealthReason: vaultHealthReason,
                outstandingLongOrderExposure: longOrderExposure,
                outstandingShortOrderExposure: shortOrderExposure,
                isContinuouslyTraded: isContinuouslyTraded
            }),
            user
        );

        // Transfer USDC to user (minus relayer fee)
        _sendWithRelayerFee(user, withdrawAmount, effRelayerFee, MetaTxLib.WITHDRAW_COLLATERAL_TYPEHASH, nonce);

        _refundEth(refundBudget);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║              SECTION 4: INSURANCE MANAGEMENT                 ║
    // ╚══════════════════════════════════════════════════════════════╝
    // Share-based model: depositors receive shares proportional to their deposit relative to
    // the current fund balance. As fees flow into insuranceFundBalance, share price increases.

    // -------------------- Errors --------------------
    error BazaarPair__InsuranceWithdrawalRequiresFreshPrice();
    error BazaarPair__InsuranceDepositRequiresFreshPrice();
    // Bad debt events reduce insuranceFundBalance, lowering share price for all depositors equally.
    //
    // Shares are priced off the fund's value at the mark, built from free capital
    // (insuranceFundBalance − seizure earmarked against open inventory) and the inventory's
    // unrealized result: a deposit counts both legs, a redemption counts the loss the fund will
    // bear and never a gain. Both sides require a FRESH mark while the vault holds inventory. The
    // rule and its reasons live in RiskParamsLib's insurance share pricing section.
    //
    // deposit:  shares = amount × totalInsuranceShares / depositBasis
    // withdraw: amount = shares × redemptionBasis / totalInsuranceShares

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

    /// @notice Deposit USDC into the insurance fund for shares priced at the fund's value at the
    ///         mark.
    /// @dev While the vault holds inherited inventory the deposit resolves a price like every other
    ///      priced entry point, and the mark must be FRESH: it values the inventory in full, its
    ///      unrealized gain raising the basis and its loss lowering it as far as the fund itself
    ///      will bear that loss. The stale fallback is refused as it is for a redemption, and for
    ///      the mirror-image reason — off-chain venues print the reopen hours before the oracle
    ///      can, so shares priced against a frozen mark hand the difference to whoever can see it,
    ///      and inventory upside has no ceiling to charge conservatively against. Nothing is lost
    ///      by waiting: a closed venue freezes the machinery the capital would fund (ADL refuses a
    ///      stale mark, liquidation refuses one past MAX_LIQUIDATION_PRICE_AGE), and the loss it
    ///      would cover realizes at the reopen, where a fresh mark prices the deposit correctly.
    ///      With no inventory held the basis is free capital, no price is read, and `priceUpdate`
    ///      may be empty — so recapitalizing a fund drained by ordinary bad debt is never gated on
    ///      market hours.
    /// @param amount Amount to deposit (in BAZAAR_EXPONENT precision)
    /// @param priceUpdate Pyth price update data (read only while the vault holds inventory)
    /// @param nonce Meta-transaction nonce (relayed calls only)
    /// @param deadline Meta-transaction deadline (relayed calls only)
    /// @param relayerFee Relayer fee, taken out of the pulled amount (relayed calls only)
    /// @param signature EIP-712 signature over the request; empty for a direct call
    /// @param permitData Optional ERC-2612 permit for the USDC pull
    function depositToInsurance(
        uint256 amount,
        bytes[] calldata priceUpdate,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature,
        bytes calldata permitData
    ) external payable nonReentrant {
        bytes32 structHash = keccak256(
            abi.encode(MetaTxLib.DEPOSIT_TO_INSURANCE_TYPEHASH, amount, nonce, deadline, relayerFee)
        );
        (address user, uint256 effRelayerFee) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);
        // Round down to USDC (6-dp) granularity so the credited amount exactly matches the USDC
        // actually pulled (which is floored); avoids crediting unbacked sub-µUSDC dust.
        amount -= amount % 1e12;
        if (effRelayerFee >= amount) revert BazaarPair__RelayerFeeExceedsDeposit();

        // No new LP principal once the settlement price is fixed: finalize sizes the insurers'
        // residual from the bad debt the settlement tallies, so shares minted mid-window would
        // buy into a charge that predates the deposit.
        _requireNoSweepWindow();

        // The mark is read only while inventory is held, so a plain deposit needs no oracle update
        // and no ETH. A fresh resolution stores the mark in lastPairPrice and advances the funding
        // index the inventory is then valued with, so the library reads both from storage.
        uint256 ethRefund = msg.value;
        if (pairVault.pendingLiqSize != 0) {
            (, uint256 unusedEth, bool isStale) = _getCurrentPairPrice(priceUpdate, msg.value);
            if (isStale) revert BazaarPair__InsuranceDepositRequiresFreshPrice();
            ethRefund = unusedEth;
        }

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
            lastPairPrice,
            amount,
            isPairTerminated,
            scheduledTerminationTs,
            currentFundingIndex,
            user
        );
        totalInsuranceShares = newTotalShares;
        shareEpoch = newEpoch;

        emit BazaarTypes.InsuranceDeposited(pairId, user, amount, sharesGained);

        // Execute ERC-2612 permit if provided (allows gasless USDC approval)
        if (permitData.length > 0) {
            _executePermit(user, permitData);
        }

        // Transfer USDC from user to contract (deposit + relayer fee); the fee stays here,
        // accrued to the relayer
        uint256 totalPull = amount + effRelayerFee;
        _sendUsdc(user, address(this), totalPull);

        if (effRelayerFee > 0) {
            _accrueRelayerFee(user, effRelayerFee, MetaTxLib.DEPOSIT_TO_INSURANCE_TYPEHASH, nonce);
        }

        _refundEth(ethRefund);
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

        // Relayed call: the fee is pulled from the wallet into the escrow (the request itself
        // moves no USDC)
        if (effRelayerFee > 0) {
            _pullRelayerFee(user, effRelayerFee, permitData, MetaTxLib.REQUEST_INSURANCE_WITHDRAWAL_TYPEHASH, nonce);
        }
    }

    /// @notice Execute a previously requested insurance withdrawal after cooldown.
    /// @dev On a live pair the price must be FRESH — the stale fallback is rejected here as it is
    ///      for position holders. Around a market closure, off-chain venues print the reopen
    ///      hours before this contract can, and the fund is sized to absorb exactly that gap
    ///      (the reopen-gap leg of its target), so a redemption judged at the frozen mark would
    ///      let an LP leave ahead of the loss the fund exists to take. Deposits stay open while
    ///      stale, and a pair whose feed has died releases its LPs once
    ///      BazaarPairTerminator.terminateStalePair settles it — the same lock position holders
    ///      carry. The vault's health is then judged against that fresh price, before any share
    ///      is redeemed, and the verdict is what the library gates on — never the ADL latch. The
    ///      latch is set only by health checks, and every other entry point runs one only after
    ///      real activity (a fill, a liquidation, an unload, a collateral withdrawal against
    ///      exposure); on a book too thin to produce any it sits at zero while the vault's
    ///      inherited inventory drifts into a loss the fund is about to absorb, and a redemption
    ///      shrinks the loss-absorbing buffer directly. Reason 1 blocks the redemption. Reasons
    ///      2–4 fix the settlement price inside the health call, which the repeated freeze check
    ///      then catches: the whole call reverts, so the redemption that discovers the
    ///      insolvency is frozen along with everyone else's. On a terminated pair the library
    ///      gates on the sweep instead: after an escape-hatch finalize the redemption waits until
    ///      every position finalize did not wait for is settled, or until the sweep grace
    ///      elapses, so the residual is priced after a straggler's shortfall, not before it.
    /// @param priceUpdate Pyth price update data (resolves the fresh price the health verdict and
    ///        the insurance ratio are judged against on a live pair; ignored once the pair is
    ///        terminated)
    /// @param nonce Meta-transaction nonce (relayed calls only)
    /// @param deadline Meta-transaction deadline (relayed calls only)
    /// @param relayerFee Relayer fee, deducted from the payout (relayed calls only)
    /// @param signature EIP-712 signature over the request; empty for a direct call
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

        // Frozen while the settlement window is open: the insurers' residual is only known at
        // finalize, and LPs must not exit ahead of it.
        _requireNoSweepWindow();

        // Live pair: resolve a fresh price, then judge vault health against it. The price feeds
        // the rate-limit calculation; the verdict is the crisis gate. Skipped once the pair is
        // terminated: the rate limit no longer applies, the stored price is frozen at the
        // termination cutoff so a fetch could not update it anyway, and a pair whose feed has
        // died has no fresh price left to resolve — requiring one would strand the insurers'
        // residual behind an oracle that no longer prints.
        uint256 ethRefund = msg.value;
        uint8 healthReason;
        if (!isPairTerminated) {
            (BazaarTypes.PairPrice memory priceStruct, uint256 unusedEth, bool isStale) =
                _getCurrentPairPrice(priceUpdate, msg.value);
            // The stale fallback (non-continuously traded pairs, venue closed) is refused: the
            // frozen mark cannot see the reopen the fund is about to absorb.
            if (isStale) revert BazaarPair__InsuranceWithdrawalRequiresFreshPrice();
            ethRefund = unusedEth;
            (, healthReason) = isVaultHealthy(priceStruct.spotPrice, isStale);
            // Reasons 2–4 fixed the settlement price inside the call above, after the freeze
            // check already ran; repeat it so the redemption that discovers the insolvency is
            // frozen along with everyone else's.
            _requireNoSweepWindow();
        }

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
            lastPairPrice,
            liquidationGapEma,
            reopenGapEma,
            BazaarTypes.InsuranceWithdrawParams({
                isPairTerminated: isPairTerminated,
                scheduledTerminationTs: scheduledTerminationTs,
                vaultHealthReason: healthReason,
                isContinuouslyTraded: isContinuouslyTraded,
                umaContract: umaContract,
                currentFundingIndex: currentFundingIndex,
                settlementPriceFixedTs: settlementPriceFixedTs
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
    error BazaarPair__LiquidationPriceTooOld();

    // -------------------- Constants --------------------
    /// @notice Liquidator reward floor per liquidation (0.10 USDC in BAZAAR scale).
    ///         Actual reward = max(this, LIQUIDATION_FEE_EBP of notional), paid from insurance.
    uint256 internal constant MIN_LIQUIDATOR_REWARD = BazaarTypes.MIN_LIQUIDATOR_REWARD;
    /// @notice Oldest stale-fallback price liquidate() will judge solvency against.
    ///         The fallback carries no expiry of its own — it stays authoritative until some
    ///         call stores a newer one — and seizure takes a position's entire bucket rather
    ///         than its shortfall. Without this ceiling an account that breached maintenance
    ///         margin for a single tick would stay seizable at that tick for as long as the pair
    ///         went untouched, long after the market traded back through it. Past the ceiling the
    ///         position is still liquidatable by a caller who supplies priceUpdate and pays the
    ///         oracle fee out of msg.value, so the ceiling redirects liquidation onto a fresh
    ///         price rather than withdrawing the power. Deliberately its own constant rather than
    ///         a reference to the refresh bounty's gap: that one sizes keeper upkeep, this one
    ///         bounds how old a mark may be and still confiscate collateral.
    uint256 internal constant MAX_LIQUIDATION_PRICE_AGE = 10 minutes;

    // -------------------- Functions --------------------

    /// @notice Allows anyone to liquidate underwater positions
    /// @dev For each address, LiquidationLib.processLiquidations checks solvency via
    ///      BucketLib.calculateState (using this batch's 24h-lagged MMR). If underwater, it
    ///      seizes the bucket and aggregates the position into the vault's pending-liquidation
    ///      inventory at the bankruptcy price. Reverts when solvency would be judged against a
    ///      stale fallback price older than MAX_LIQUIDATION_PRICE_AGE — supplying priceUpdate
    ///      resolves a fresh price and lifts that restriction. Once a settlement price is fixed
    ///      the same entry point settles positions at it instead, and the caller earns
    ///      BazaarTypes.TERMINAL_SETTLEMENT_TIP per position settled for someone else
    ///      (CollateralLib.settleTerminalPositions describes who funds it).
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
        // Terminal settlement mode: once the settlement price is fixed, this SAME entry point
        // marks positions to the frozen price — pure accounting, no oracle read — reusing
        // liquidate's calldata handling and nonReentrant guard instead of a second external
        // function (EIP-170 relief). priceUpdate is ignored; any ETH is refunded. Before finalize
        // the settlement tallies claims and bad debt; after it, positions realize against the
        // frozen ledgers.
        if (settlementPriceFixedTs != 0) {
            liquidatedCount = CollateralLib.settleTerminalPositions(
                positionBuckets,
                pairVault,
                terminalProfitClaim,
                terminalState,
                feeEscrow,
                fixedSettlementPrice,
                currentFundingIndex,
                isPairTerminated,
                pairId,
                usersToLiquidate
            );
            _refundEth(msg.value);
            return liquidatedCount;
        }

        // Live liquidation path: halted at/past the scheduled cutoff (every termination fixes
        // the price, so a terminated pair is handled above).
        if (scheduledTerminationTs != 0 && block.timestamp >= scheduledTerminationTs) {
            revert BazaarPair__TradingHalted();
        }

        (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool isPriceStale) =
            _getCurrentPairPrice(priceUpdate, msg.value);
        // Age-bound the stale fallback before it can decide a seizure. Compared by adding the
        // ceiling to the mark rather than subtracting the mark from now: updateTs is a Pyth
        // publish time, which may sit slightly ahead of the block, and a future-dated mark is
        // not an old one — the subtraction would panic on exactly that input.
        if (isPriceStale && priceStruct.updateTs + MAX_LIQUIDATION_PRICE_AGE < block.timestamp) {
            revert BazaarPair__LiquidationPriceTooOld();
        }
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
            feeEscrow,
            BazaarTypes.LiquidateParams({
                currentPrice: currentPrice,
                currentFundingIndex: currentFundingIndex,
                marginReqs: liqMarginReqs,
                pairId: pairId,
                currentBlock: _l2Block()
            })
        );

        // The liquidator's reward (max(floor, 2bps × notional) per position) is debited from
        // insurance and accrued to its claimable balance inside processLiquidations.
        liquidatedCount = result.liquidatedCount;

        if (liquidatedCount > 0) {
            // Cross the freshly seized inventory into the book BEFORE judging vault health, so
            // exposure the book can absorb right now never false-latches an ADL window. Judging
            // after the walk is safe because the walk (MatchingEngineLib._planUnload) spends at
            // most the fund's headroom — free capital above the reserve, less the loss the
            // remaining inventory carries at the mark — so it can neither take the fund below its
            // reserve nor carry the pair over the trigger. Bounded by a fixed node budget to keep the
            // liquidator's gas predictable; the permissionless unloadVault finishes anything
            // deeper. Skipped while ADL is already pending — matching is frozen then and
            // executeAdl owns the resolution.
            if (!isAdlPending) {
                BazaarTypes.WalkSummary memory sum = MatchingEngineLib.unloadBook(
                    orders,
                    positionBuckets,
                    userActiveLimitOrders,
                    pairVault,
                    feeEscrow,
                    book,
                    BazaarTypes.LIQ_INLINE_UNLOAD_STEPS,
                    false,
                    _buildArrivalCtx(currentPrice, isPriceStale, liqMarginReqs, _l2Block())
                );
                _postWalk(sum, currentPrice);
            }
            // Re-evaluate vault health after liquidations (live pair only; terminal settlement
            // never routes here). Exactly one health call per transaction — see _postWalk.
            isVaultHealthy(currentPrice, isPriceStale);
            // Refresh IMR/MMR + sample the curve so a mass liquidation (which moves insurance —
            // seized collateral in, liquidator rewards out) feeds the instantaneous insurance
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
    /// @notice Reward for the ADL executor, in basis points of the bad debt the batch averted;
    ///         debited from insurance and accrued to the executor's claimable balance.
    uint256 internal constant ADL_EXECUTOR_REWARD_BP = BazaarTypes.ADL_EXECUTOR_REWARD_BP;

    // -------------------- State Variables --------------------
    uint256 internal nextAdlId;

    // -------------------- Events --------------------
    /// @notice Emitted whenever an ADL cohort is set: a window opening (false→true trigger) and a
    ///         mid-auction side flip that re-targets one both qualify. Carries the frozen ranking
    ///         basis — adlSnapshotPrice and adlSnapshotFundingIndex — so keepers score winners
    ///         against the same values the contract ranks with; adlEpoch identifies the ranking
    ///         epoch, which is what deposit tags and the decay gate are keyed to, so one pending
    ///         window spans several when it flips. A re-target withheld for staleness emits
    ///         nothing, since it leaves the basis untouched. auxState() always reflects the current
    ///         basis (including adlLongs and the auction clock), so keepers re-read it before each
    ///         submission rather than depending on this event alone. Kept lean to hold the pair
    ///         under the EIP-170 code-size limit.
    event AdlTriggered(
        bytes32 indexed pairId, uint64 indexed adlEpoch, uint256 adlSnapshotPrice, int256 adlSnapshotFundingIndex
    );

    /// @notice Emitted when a timed-out auction's termination deadline is fixed, which happens once
    ///         per window on the first price stored past the timeout.
    /// @dev Fires at most once per ADL window, so a second event for the same epoch would mean the
    ///      clear-on-resolve path was missed. Keepers watch it to learn when the pair becomes
    ///      terminable, and how much fresh-priced runway is left to finish deleveraging instead.
    /// @param pairId The pair
    /// @param adlTerminationTs The instant from which the timeout may terminate the pair
    event AdlTerminationArmed(bytes32 indexed pairId, uint256 adlTerminationTs);

    // -------------------- Functions --------------------

    /// @notice Deleverages profitable counterparties against the vault's liquidation inventory.
    /// @dev Requires a price the oracle currently attests: the stale fallback is refused, so on a
    ///      non-continuously traded pair whose market is shut the auction waits for the reopen. The
    ///      timeout waits with it — it needs a fresh price too, and then ADL_TERMINATION_GRACE more
    ///      (see adlTerminationTs) — so waiting cannot cost the pair its chance to deleverage.
    /// @param winners Candidate accounts on the side opposite the vault's inventory, sorted by
    ///        DESCENDING ADL score; AdlLib rejects a batch that is out of order. Preview a score
    ///        with BazaarPairLens.getAdlScore, which ranks against the same frozen snapshot.
    /// @param priceUpdate Signed Pyth price update messages. May be empty only when the on-chain
    ///        Pyth cache is already fresh within MAX_PRICE_STALENESS; otherwise the call reverts
    ///        rather than falling back to the pair's stored price.
    function executeAdl(address[] calldata winners, bytes[] calldata priceUpdate) external payable nonReentrant {
        // Once the settlement price is fixed only settlement at that price may mutate
        // positions — an ADL at a live oracle price would corrupt the book — and a finalized
        // pair has its inventory retired and settles via withdrawals only.
        if (settlementPriceFixedTs != 0) {
            revert BazaarPair__TradingHalted();
        }
        if (!isAdlPending) revert BazaarPair__AdlNotPending();

        (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool isPriceStale) =
            _getCurrentPairPrice(priceUpdate, msg.value);
        // Four decisions downstream read this price, and a stale mark corrupts each: the
        // healthReason == 1 gate below (an auction the live market has already healed stays
        // executable), AdlLib's batch sizing (the size that restores health is measured against
        // it), the settlement price (the mark replaces the estates' bankruptcy price whenever it
        // sits on the fund's favorable side, so a stale one would close winners at a price the
        // market has left), and the executor reward (avertedLoss is the gap between it and the
        // settlement price, which is the bankruptcy price whenever a reward is due at all — so
        // the payout is steerable through this leg alone). Ranking is immune, being frozen at
        // the snapshot, but that is not enough to let the rest run on a mark nobody just
        // confirmed. A caller who cannot resolve a fresh
        // price supplies priceUpdate; while the feed is genuinely down, the auction waits, and
        // the timeout cannot claim the pair out from under it either — see adlTerminationTs.
        if (isPriceStale) revert BazaarPair__AdlPriceStale();
        uint256 currentPrice = priceStruct.spotPrice;

        // Re-validate the latch against the LIVE price BEFORE closing anyone
        (, uint8 healthReason) = isVaultHealthy(currentPrice, isPriceStale);

        if (healthReason == 1) {
            // The auction is guaranteed to be aimed away from the side the vault itself holds, and
            // nothing here re-checks it. The freshness gate above admits only a non-stale
            // resolution, which is precisely the condition under which the isVaultHealthy call
            // applies a flipped auction's re-target instead of withholding it — so any flip is
            // already corrected by the time execution begins. Withholding keys off staleness
            // alone, not off whether the price was newer than the stored one, so even a fresh mark
            // that stores nothing re-targets.
            //
            // Accepting anything but a fresh price here would break that: the entry points that do
            // take the stale mark can leave a flip un-retargeted, and executing in that state
            // deleverages accounts that do not offset the vault's exposure at all — eligibility
            // only requires positive PnL against each account's own entry, so profitable positions
            // exist on both sides and the caller picks which to submit, while _applyAdlVaultUpdate
            // and the pendingLiq decrement book the closes as though they offset.

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
                    adlAuctionStartTs: adlAuctionStartTs,
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
                // Capped at free capital: the earmark left against unclosed inventory settles that
                // inventory, so a reward drawn from it would come out of a later winner's funding
                // income or an unload fill's backing.
                uint256 free = RiskParamsLib.insuranceFreeCapital(pairVault);
                if (reward > free) reward = free;
                if (reward > 0) {
                    pairVault.insuranceFundBalance -= reward;
                    FeeEscrowLib.credit(feeEscrow, pairId, msg.sender, reward);
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
    ///         post-only violation, self-match, step-cap, dust). A fill-or-kill order does
    ///         neither: anything short of a complete fill reverts the transaction. Untriggered
    ///         stops rest outside the book awaiting executeTriggeredOrders.
    /// @param spec The signed order intent (covered by the EIP-712 payload).
    /// @param hints Execution aids — insertion predecessors and the walk's node budget. Outside
    ///        the signature (like priceUpdate): a relayer attaches fresh ones at submission, and
    ///        every hint is verified on-chain against the actual neighbors before linking.
    /// @param priceUpdate Pyth update data; may be empty when the on-chain price is fresh.
    /// @param nonce The signer's meta-tx nonce (ignored for a self-submitted call).
    /// @param deadline Signature expiry timestamp (ignored for a self-submitted call).
    /// @param relayerFee USDC owed to msg.sender for a relayed call (ignored when unsigned).
    /// @param signature EIP-712 signature over the order; empty for a self-submitted call.
    /// @param permitData Optional ERC-2612 permit (abi-encoded value, deadline, v, r, s), executed
    ///        before a relayed call's fee is pulled from the signer's wallet.
    function createOrder(
        BazaarTypes.OrderSpec calldata spec,
        BazaarTypes.MatchHints calldata hints,
        bytes[] calldata priceUpdate,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature,
        bytes calldata permitData
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
                spec.tif,
                spec.expirationBlock,
                spec.integrator,
                nonce,
                deadline,
                relayerFee
            )
        );
        (address user, uint256 effRelayerFee) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);

        _requireLiveTrading();

        (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool _isOracleStale) =
            _getCurrentPairPrice(priceUpdate, msg.value);

        // Refresh the margin curve + MMR sample ring on every arrival (both callees self-gate),
        // so the creation gate and the walk both judge against current parameters and the
        // 24h-lagged liquidation threshold keeps getting fed.
        _refreshMarginCurve(priceStruct.spotPrice);

        uint64 currentBlock = _l2Block();

        // Clean up expired limit orders and get directional exposure for margin calculation
        (uint256 longOrderExposure, uint256 shortOrderExposure, uint256 longOrderSize, uint256 shortOrderSize) =
            _cleanupExpiredLimitOrders(user, currentBlock);
        // Outstanding exposure is reserved at no less than the mark (per side), matching the new
        // order's own reservation rule in createOrder.
        {
            uint256 atMark = Math.mulDiv(longOrderSize, priceStruct.spotPrice, BazaarTypes.BAZAAR_SCALE);
            if (atMark > longOrderExposure) longOrderExposure = atMark;
            atMark = Math.mulDiv(shortOrderSize, priceStruct.spotPrice, BazaarTypes.BAZAAR_SCALE);
            if (atMark > shortOrderExposure) shortOrderExposure = atMark;
        }

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
            feeEscrow,
            book,
            orderId,
            execHints,
            _buildArrivalCtx(priceStruct.spotPrice, _isOracleStale, _marginReqsWithLag(), currentBlock)
        );
        _postWalk(sum, priceStruct.spotPrice);
        if (sum.totalFillSize > 0) isVaultHealthy(priceStruct.spotPrice, _isOracleStale);

        // Relayed call: the fee is pulled from the wallet into the escrow, never from the bucket
        // or the vault.
        if (effRelayerFee > 0) {
            _pullRelayerFee(user, effRelayerFee, permitData, MetaTxLib.CREATE_ORDER_TYPEHASH, nonce);
        }

        _refundEth(ethRefund);
    }

    /// @notice Cancels one or more of the caller's (or, when relayed, the signer's) orders.
    /// @param orderIds The orders to cancel; each must be live and owned by the acting user.
    /// @param nonce The signer's meta-tx nonce (ignored for a self-submitted call).
    /// @param deadline Signature expiry timestamp (ignored for a self-submitted call).
    /// @param relayerFee USDC owed to msg.sender for a relayed call (ignored when unsigned).
    /// @param signature EIP-712 signature over the id list; empty for a self-submitted call.
    /// @param permitData Optional ERC-2612 permit (abi-encoded value, deadline, v, r, s), executed
    ///        before a relayed call's fee is pulled from the signer's wallet.
    function cancelOrders(
        uint256[] calldata orderIds,
        uint256 nonce,
        uint256 deadline,
        uint256 relayerFee,
        bytes calldata signature,
        bytes calldata permitData
    ) external nonReentrant {
        bytes32 structHash = keccak256(
            abi.encode(
                MetaTxLib.CANCEL_ORDERS_TYPEHASH, keccak256(abi.encodePacked(orderIds)), nonce, deadline, relayerFee
            )
        );
        (address user, uint256 effRelayerFee) = _resolveUser(structHash, nonce, deadline, relayerFee, signature);

        // Reject an EMPTY list: with no order consumed the loop below is a no-op, and a relayed
        // one would still consume the signer's nonce and pay the relayer fee for nothing. The
        // upper bound keeps the loop's gas predictable. The empty case reuses the
        // too-many-cancels error rather than declaring a second one.
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

        // Relayed call: the fee is pulled from the wallet into the escrow, never from the bucket
        // or the vault.
        if (effRelayerFee > 0) {
            _pullRelayerFee(user, effRelayerFee, permitData, MetaTxLib.CANCEL_ORDERS_TYPEHASH, nonce);
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
        (longExposure, shortExposure,,) = _cleanupExpiredLimitOrders(user, _l2Block());
        orderIds = userActiveLimitOrders[user].values();
        count = orderIds.length;
    }

    /// @notice Iterates through a user's active limit order set, cancels expired orders,
    ///         removes them from the set, and returns directional exposure of remaining active
    ///         orders, both limit-priced and as raw size.
    /// @param user The address whose limit orders to clean up
    /// @return longExposure Sum of remaining limit-priced notional for active long orders
    /// @return shortExposure Sum of remaining limit-priced notional for active short orders
    /// @return longSize Sum of remaining size for active long orders
    /// @return shortSize Sum of remaining size for active short orders
    function _cleanupExpiredLimitOrders(address user, uint64 currentBlock)
        internal
        returns (uint256 longExposure, uint256 shortExposure, uint256 longSize, uint256 shortSize)
    {
        // Sweep logic lives in OrderManagementLib (EIP-170 extraction).
        return OrderManagementLib.cleanupExpiredLimitOrders(
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
    ///         per side (limit-priced notional and raw size), without the lazy pruning — safe to
    ///         eth_call. Read by BazaarPairLens.getMaxWithdrawable for off-chain withdrawal
    ///         margin math, which reserves at the larger of the notional and the size valued at
    ///         the mark, exactly as the withdrawal gate does.
    function outstandingOrderExposure(address user)
        external
        view
        returns (uint256 longExposure, uint256 shortExposure, uint256 longSize, uint256 shortSize)
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
    ///      the same basis. `currentBlock` is passed in rather than read here so a caller that
    ///      already resolved the L2 block number does not pay the ArbSys call twice.
    function _buildArrivalCtx(uint256 spot, bool stale, BazaarTypes.MarginRequirements memory mr, uint64 currentBlock)
        internal
        view
        returns (BazaarTypes.ArrivalContext memory ctx)
    {
        ctx.cachedPrice = spot;
        ctx.cachedFundingIdx = currentFundingIndex;
        // One call for both rates: they share the target-ratio and base-fee curves, so asking
        // separately recomputes the same intermediate twice across two delegatecalls.
        (ctx.insuranceFeeEbp, ctx.closingFeeEbp) = RiskParamsLib.getInsuranceFeeRates(
            pairVault, lastPairPrice, liquidationGapEma, reopenGapEma, spot, isContinuouslyTraded, currentFundingIndex
        );
        ctx.isOracleStale = stale;
        ctx.marginReqs = mr;
        ctx.pairId = pairId;
        ctx.currentBlock = currentBlock;
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
    ///      Deliberately does NOT re-evaluate vault health — each entry point does that exactly
    ///      once itself, after its walk, so the verdict is judged on the book the walk left
    ///      behind and paid for once. A repeat call in the same transaction is idempotent
    ///      (_terminateOnInsolvency is a no-op once a settlement price is fixed, and the ADL
    ///      transition happens only on the first evaluation) but re-reads the vault aggregates
    ///      and the USDC balance for nothing.
    function _postWalk(BazaarTypes.WalkSummary memory sum, uint256 spot) internal {
        if (sum.totalFillSize == 0) return;
        _updateMarkPrice(sum.totalMatchedVolume, sum.totalFillSize, spot);
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
            feeEscrow,
            book,
            execs,
            _buildArrivalCtx(priceStruct.spotPrice, _isOracleStale, _marginReqsWithLag(), _l2Block())
        );
        _postWalk(sum, priceStruct.spotPrice);
        if (sum.totalFillSize > 0) isVaultHealthy(priceStruct.spotPrice, _isOracleStale);

        _refundEth(ethRefund);
    }

    /// @notice Permissionless keeper entry point: cross the vault's pending liquidation
    ///         inventory into the book down to the unload bound — the looser of the estates'
    ///         fund-neutral price and the liquidation band — for as long as the insurance fund's
    ///         headroom above its reserve lasts. The caller
    ///         earns LIQUIDATION_FEE_EBP of the notional it unloads, from insurance, floored at
    ///         UNLOAD_BOUNTY_MIN only when the call moved at least UNLOAD_BOUNTY_MIN_NOTIONAL
    ///         or emptied the inventory. The walk library accrues it to the caller's claimable
    ///         balance, pulled via claimFees.
    /// @param maxSteps Node budget for the walk (0 = protocol default; clamped to
    ///        MAX_WALK_STEPS).
    function unloadVault(uint256 maxSteps, bytes[] calldata priceUpdate)
        external
        payable
        nonReentrant
        returns (uint256 unloadedSize)
    {
        _requireLiveTrading();

        // The stale fallback is allowed: liquidation flow is forced. The band leg of the unload
        // bound (min(LIQ_MAX_SLIPPAGE_BP, MMR) around the stored mark) sits inside the stale fill
        // band, and the neutral-price leg reads no price at all, so a stale mark widens neither.
        // The headroom is judged at the same mark the fills are: a stale mark that understates
        // the loss lets the walk spend room a fresh mark would not have shown, but never the
        // reserve as valued at that mark, and the next fresh verdict opens the auction for
        // whatever that leaves uncovered.
        (BazaarTypes.PairPrice memory priceStruct, uint256 ethRefund, bool _isOracleStale) =
            _getCurrentPairPrice(priceUpdate, msg.value);

        _refreshMarginCurve(priceStruct.spotPrice);

        BazaarTypes.WalkSummary memory sum = MatchingEngineLib.unloadBook(
            orders,
            positionBuckets,
            userActiveLimitOrders,
            pairVault,
            feeEscrow,
            book,
            maxSteps,
            true,
            _buildArrivalCtx(priceStruct.spotPrice, _isOracleStale, _marginReqsWithLag(), _l2Block())
        );
        unloadedSize = sum.totalFillSize;
        _postWalk(sum, priceStruct.spotPrice);
        // Judged even when nothing filled. A walk the bound refused outright is the verdict's
        // main case: the book cannot absorb the inventory at any price the fund will pay, and
        // this call is what opens the auction rather than leaving it to the next refresh.
        isVaultHealthy(priceStruct.spotPrice, _isOracleStale);

        _refundEth(ethRefund);
    }

    // -------------------- Fee escrow --------------------

    /// @notice Unclaimed third-party payouts — integrator fees, the bug-bounty share, keeper
    ///         tips and rewards, the UMA proposer reward, relayer fees — in BAZAAR precision.
    /// @dev One getter for both figures rather than two: BazaarPair sits at the EIP-170 ceiling,
    ///      and a second external function costs a selector, its dispatch and its return
    ///      encoding for a value callers almost always want alongside the first.
    /// @param recipient The address to report an owed balance for (address(0) for the total only).
    /// @return owed The amount `recipient` may claim.
    /// @return total The sum across all recipients — a liability against the contract's USDC,
    ///         reserved by every books-vs-cash figure alongside the deposits ledger and insurance.
    function claimableFees(address recipient) external view returns (uint256 owed, uint256 total) {
        return (feeEscrow.claimable[recipient], feeEscrow.total);
    }

    /// @notice Withdraw the caller's escrowed fee balance. The amount paid is reported by the
    ///         FeesClaimed event.
    /// @dev Permissionless and always available — deliberately not gated on trading liveness or
    ///      termination. These fees were earned before whatever state the pair is now in, their
    ///      USDC is reserved out of every books-vs-cash figure rather than distributed to
    ///      traders or insurers, and blocking the claim would strand it permanently.
    ///
    ///      Guarded like every other entry point that moves value, even though the payout
    ///      itself is strict checks-effects-interactions (both escrow balances are cleared
    ///      before the transfer, so a re-entrant claim finds nothing to pay). The guard is for
    ///      the rest of the contract, not for this function: without it the token transfer is a
    ///      window in which an unguarded call frame can enter any other entry point, and the
    ///      safety of that depends on the payout token never calling back — a property of a
    ///      contract the protocol does not control and can be upgraded underneath it.
    function claimFees() external nonReentrant {
        CollateralLib.claimFees(feeEscrow, address(usdc), pairId);
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
            priceUpdateCount,
            currentFundingIndex
        );
    }

    /// @notice Recomputes IMR/MMR from `currentPrice` and records the result into the 24h-lagged
    ///         MMR sample ring; no-op once the pair is halted (margin params are moot then).
    /// @dev Shared by liquidate / executeAdl / refreshPrice so every path that refreshes the
    ///      margin curve also advances the ring. Spam-safe: both callees self-gate
    ///      (IMR_UPDATE_COOLDOWN / MMR_SAMPLE_INTERVAL), so redundant calls are no-ops.
    function _refreshMarginCurve(uint256 currentPrice) internal {
        if (isPairTerminated) return;
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

    /// @notice Updates mark price. The EMA math (walk VWAP, volume-scaled alpha with its
    ///         open-interest floor, band clamp, decay-to-index) lives in
    ///         FundingLib.updateMarkPrice; this wrapper owns the scalar storage writes.
    function _updateMarkPrice(uint256 fillNotional, uint256 fillSize, uint256 indexPrice) internal {
        FundingLib.MarkState memory s = FundingLib.updateMarkPrice(
            FundingLib.MarkState({
                markPrice: markPrice, lastMarkUpdateTs: lastMarkUpdateTs, rollingVolume: rollingVolume
            }),
            fillNotional,
            fillSize,
            indexPrice,
            // Liquidation, ADL and settlement each move size off a single leg, and a floor that
            // fell with them would make the mark more sensitive per fill exactly while the vault
            // unloads the inventory those moves created.
            RiskParamsLib.openInterestSize(pairVault)
        );
        markPrice = s.markPrice;
        lastMarkUpdateTs = s.lastMarkUpdateTs;
        rollingVolume = s.rollingVolume;
    }

    /// @notice Updates funding index. The accrual math (staleness-gated window, premium
    ///         dampening/clamp, price-unit accumulation) lives in FundingLib.updateFundingIndex.
    function _updateFundingIndex(uint256 indexPrice, uint256 oracleUpdateTs) internal {
        (currentFundingIndex, lastFundingUpdateTs) = FundingLib.updateFundingIndex(
            markPrice,
            lastMarkUpdateTs,
            currentFundingIndex,
            lastFundingUpdateTs,
            indexPrice,
            oracleUpdateTs,
            isContinuouslyTraded
        );
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║              SECTION 11: PAIR TERMINATION                    ║
    // ╚══════════════════════════════════════════════════════════════╝

    // -------------------- State Variables --------------------
    // The settlement tallies and the frozen payout ratios live in terminalState (declared with
    // the other terminal state at the end of storage) and are surfaced through auxState().

    // 24h-lagged-MMR ring buffer. Declared LAST so all existing storage slots keep their indices
    // (append-only is required for the upgradeable/proxy layout). See MmrSampleLib + MMR_* constants.
    BazaarTypes.MmrSampleBuffer internal mmrBuffer;

    // Insurance share-epoch state (append-only layout: added after mmrBuffer). A drained-fund
    // recap bumps shareEpoch; rawInsuranceShares entries stamped with an older shareEpochOf
    // read as 0 via the insuranceShares(address) getter. See InsuranceVaultLib.
    uint256 internal shareEpoch;
    mapping(address => uint256) internal shareEpochOf;

    // -------------------- Constants --------------------
    /// @notice Escape hatch for finalize. Finalize normally waits for every position to be
    ///         settled at the fixed price (open interest reaching zero); once this much time has
    ///         passed since the price was fixed it proceeds regardless, so an unsettled position
    ///         can delay settlement but never block it. Long enough that a live book never
    ///         reaches it by accident: a bankrupt position still unsettled at that point
    ///         understates bad debt, which the insurers' residual absorbs when it is settled —
    ///         and their exit waits for that settlement, or for BazaarTypes.INSURER_SWEEP_GRACE
    ///         beyond this point (InsuranceVaultLib.executeInsuranceWithdrawal).
    uint256 internal constant TERMINAL_SETTLEMENT_ESCAPE = BazaarTypes.TERMINAL_SETTLEMENT_ESCAPE;

    // -------------------- Errors --------------------
    // No pair-side event for the fix: the terminator emits SettlementPriceFixed for the paths it
    // initiates, which keeps that bytecode out of the pair's EIP-170 budget; the autonomous
    // insolvency path leaves its latch readable through settlementPriceFixedTs. One shared error
    // covers every window-blocked action, finalize-too-early included.
    error BazaarPair__SweepWindowActive();

    // -------------------- Functions --------------------

    /// @notice Stage 1 of termination: pin the settlement price and open the settlement
    ///         window. Callable only by BazaarPairTerminator (every governed termination path:
    ///         scheduled, insurer-vote, 21-day stale). Also stamps
    ///         scheduledTerminationTs — setting it when unset (insurer-vote / stale paths) and
    ///         pulling a still-future scheduled cutoff back to now — so every limbo guard —
    ///         matching, orders, deposits, price-storage freeze — engages at once.
    /// @dev The autonomous insolvency paths open the same window by calling _fixSettlement
    ///      directly rather than through this entry point. Every termination passes through the
    ///      window; the latch below is therefore also the "already terminated" check.
    function fixSettlementPrice(uint256 settlementPrice) external onlyUma {
        // Already-fixed reuses AlreadyTerminated: to every caller the pair is equally claimed.
        // The zero check must live HERE (not only in TerminationLib): a stored 0 would make
        // finalize revert forever with withdrawals frozen — fail at stage 1, where the
        // terminator can retry, never after the window state is latched.
        if (settlementPriceFixedTs != 0) {
            revert BazaarPair__AlreadyTerminated();
        }
        if (settlementPrice == 0) revert BazaarPair__NoPriceUpdatesProvided();
        _fixSettlement(settlementPrice);
    }

    /// @dev Latch the settlement price and open the settlement window. Shared by the external
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

    /// @notice Stage 2: settle the book at the fixed price and freeze the payout ratios. Anyone
    ///         may call it once every position has been settled (open interest is zero), or —
    ///         the escape hatch — once TERMINAL_SETTLEMENT_ESCAPE has elapsed since the fix.
    /// @dev Gating on completeness rather than on time is what makes the ratios exact: the total
    ///      owed to traders is derived from the ledgers on the assumption that no unrealized PnL
    ///      remains. Settling is permissionless, pure arithmetic and cannot revert for a position
    ///      that exists, so the gate cannot be held hostage; the escape hatch only bounds the case
    ///      where nobody settles at all. No nonReentrant: the only external interaction is
    ///      TerminationLib's STATICCALL balanceOf, no value moves, and re-entry lands on
    ///      _terminatePair's AlreadyTerminated guard. The single error covers "nothing fixed",
    ///      "positions still open" and "escape not yet elapsed".
    function finalizeTermination() external {
        if (settlementPriceFixedTs == 0) revert BazaarPair__SweepWindowActive();
        bool sweepComplete = pairVault.totalLongOI == 0 && pairVault.totalShortOI == 0;
        if (!sweepComplete && block.timestamp < settlementPriceFixedTs + TERMINAL_SETTLEMENT_ESCAPE) {
            revert BazaarPair__SweepWindowActive();
        }
        _terminatePair(sweepComplete);
    }

    /// @dev Terminated-or-ADL halt; the first gate of _requireLiveTrading.
    function _requireNotHalted() internal view {
        if (isPairTerminated || isAdlPending) revert BazaarPair__TradingHalted();
    }

    /// @dev Shared freeze for user-facing entry points — matching, orders, deposits, withdrawals —
    ///      while the settlement window is open (price fixed, finalize pending). Lifts the
    ///      moment the pair terminates.
    function _requireNoSweepWindow() internal view {
        if (settlementPriceFixedTs != 0 && !isPairTerminated) {
            revert BazaarPair__SweepWindowActive();
        }
    }

    /// @dev Autonomous insolvency response (realized deficit, ADL timeout, books-vs-balance
    ///      shortfall). Fixes the settlement price at `currentPrice` and opens the settlement
    ///      window rather than terminating mid-transaction: withdrawals freeze immediately, which
    ///      is what the insolvency checks need, and the positions get the same per-user
    ///      settlement as a planned wind-down — a cash shortfall simply surfaces in the frozen
    ///      ratios. Falls back to the last stored price when none is supplied, and is a no-op
    ///      when there is no price at all (a pair that never traded has nothing to settle) or
    ///      when a window is already open (double-detection across calls).
    function _terminateOnInsolvency(uint256 currentPrice) internal {
        if (settlementPriceFixedTs != 0) return;
        uint256 price = currentPrice != 0 ? currentPrice : lastPairPrice.spotPrice;
        if (price == 0) return;
        _fixSettlement(price);
    }

    /// @notice Finalizes the termination: retires the vault's inherited inventory and freezes the
    ///         payout ratios (TerminationLib.executeTermination via DELEGATECALL).
    /// @param sweepComplete True when no trader position was left open, recorded in the event
    function _terminatePair(bool sweepComplete) internal {
        if (isPairTerminated) revert BazaarPair__AlreadyTerminated();

        TerminationLib.executeTermination(
            pairVault,
            terminalState,
            BazaarTypes.TerminationParams({
                settlementPrice: fixedSettlementPrice,
                usdc: address(usdc),
                pairId: pairId,
                currentFundingIndex: currentFundingIndex,
                claimableFeesTotal: feeEscrow.total,
                sweepComplete: sweepComplete
            })
        );
        isPairTerminated = true;

        // A terminated pair can never run ADL again — clear the pending state. The ADL-timeout
        // path reaches here with isAdlPending freshly re-set to true (VaultHealthLib keeps it
        // pending in the timeout branch), and anything keyed on the flag — most importantly the
        // position-holder withdrawal freeze — must not outlive termination, or terminal
        // settlement withdrawals would be bricked.
        //
        // Both auction clocks go with it. Neither can be read again — executeAdl refuses a pair
        // with a fixed settlement price, the arming and decay-restart blocks are gated on the
        // flag, and the lens checks it before either ADL getter — so this is for legibility, not
        // safety: leaving them set while adlPendingSince is zeroed would show a window that both
        // has and has not ended. The timeout path makes that the common case rather than a corner
        // one, since reaching it requires adlTerminationTs to have been armed and elapsed.
        isAdlPending = false;
        adlPendingSince = 0;
        adlTerminationTs = 0;
        adlAuctionStartTs = 0;
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
    ///      2. ADL auction timeout expired (→ settlement window at the live price)
    ///      3. Actual USDC balance shortfall vs bookkeeping (→ settlement window at the live price)
    /// @param currentPrice The current price for OI notional calculation (BAZAAR_SCALE precision)
    /// @param isPriceStale True when currentPrice came from the stale fallback rather than a fresh
    ///        oracle read. Blocks opening a NEW ADL window; every other check is unaffected.
    /// @return healthy True if vault passes all health checks
    /// @return reason 0 = healthy,
    ///                1 = liquidation exposure exceeds insurance (triggers/extends ADL, not termination),
    ///                2 = ADL auction timeout expired (opens the settlement window),
    ///                3 = actual USDC balance shortfall vs bookkeeping (opens the settlement window),
    ///                4 = realized bad debt (insolvency) — opens the settlement window
    function isVaultHealthy(uint256 currentPrice, bool isPriceStale) internal returns (bool healthy, uint8 reason) {
        // Check 0: realized bad debt. A non-zero deficit means a prior loss overran the insurance
        // fund and the overrun went unfunded — the pair is provably insolvent and cannot honor
        // all claims. Fix the settlement price at the live price now: withdrawals freeze at once,
        // closing the pre-termination first-come-first-served window, and finalize folds the
        // deficit into what traders are owed. This catches unfunded bad debt that the
        // books-vs-USDC check (reason 3) cannot see, since the ledgers stay balanced.
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
            adlSnapshotFundingIndex,
            marginRequirements.mmrBp
        );

        // Opening a NEW window is gated on a fresh price. Everything an auction is judged by is
        // frozen at the instant it opens — which side is deleveraged, the ranking snapshot, and the
        // 24h clock — and a stale mark is whichever real tick someone last recorded, not the book's
        // exposure now. Opening on one deleverages profitable counterparties in response to stress
        // that may no longer exist, and they are not in breach of anything. The verdict is still
        // reported (reason 1), so callers that gate on vault health stay conservative; only the
        // irreversible latch is withheld. Extending and clearing a window already opened against a
        // fresh price are untouched: executing the auction needs a fresh mark, but the paths that
        // shrink the exposure without one — a stale-priced unloadVault or liquidate — still release
        // the latch here when they carry it back under the release level, so a quiet feed cannot
        // strand a pair that has already recovered.
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
        // an account's own entry, so profitable positions exist on both sides. What makes
        // withholding safe is that the state is unreachable from executeAdl at all: it admits only
        // a fresh price, and a fresh price takes the re-targeting path here rather than this one,
        // so execution never begins against a flip this branch left standing. The timeout cannot
        // claim the pair meanwhile either, since it requires a fresh price on the same terms.
        //
        // The flip condition is derived here rather than reported by checkLiqExposure: the target
        // side it compares against is this contract's own state, already read on this line, so
        // naming it costs nothing where widening the result struct would. Must be computed before
        // the adlLongs write below, which is what it tests.
        bool sideFlipped = isAdlPending && result.newIsAdlPending && adlLongs == pairVault.pendingLiqIsLong;
        bool staleRetarget = isPriceStale && sideFlipped;

        // Apply ADL state changes. Opening a window and a side flip that re-targets one are the
        // same event for everything scoped to the cohort being deleveraged, because a flip replaces
        // that cohort wholesale — every account newly in range was, an instant earlier, on the side
        // the vault was inheriting from.
        //
        // The epoch bump re-bases the deposit tags. A tag exists to stop a top-up made while its
        // owner was in range from improving their queue position; after a flip the live tags belong
        // to the side that was NOT in range, whose deposits were defending against liquidation, not
        // against a ranking they were never subject to. Subtracting those would rank the newly
        // targeted cohort as though it had no collateral at all — a bump restores the rule the
        // mechanism means: a deposit discounts your score only if you made it while your own side
        // was the one being deleveraged. It cannot cost anything but queue position, since the
        // deposit is already booked to the bucket and the ledger and counts in full at settlement.
        //
        // Restarting the decay gives the new cohort the auction it never had. The gate narrows from
        // ADL_MAX_SCORE only as an auction fails to turn up eligible accounts, so inherited decay
        // means a flip ten minutes in exposes every profitable account on the new side at once,
        // with no ranking protection. The two termination clocks are deliberately left standing:
        // adlPendingSince and the runway armed off it stay monotone, so a caller who can induce
        // flips — liquidating the opposing side both causes one and lands here — cannot defer the
        // deadline that resolves a stuck auction. A pair that keeps flipping therefore keeps
        // restarting the decay and may stay out of executeAdl's reach, and still terminates on
        // schedule underneath.
        //
        // Both are withheld when the re-target itself is (staleRetarget): the snapshot does not
        // move, so the cohort does not either, and spending a fresh epoch and a fresh gate on an
        // unchanged target would void honest tags and re-arm the gate for nothing. The two arms are
        // mutually exclusive — one needs isAdlPending false, the other true — so the epoch advances
        // at most once per evaluation.
        if ((result.newIsAdlPending && !isAdlPending) || (sideFlipped && !staleRetarget)) {
            unchecked {
                ++adlEpoch;
            }
            adlAuctionStartTs = block.timestamp;
            emit AdlTriggered(pairId, adlEpoch, result.newAdlSnapshotPrice, result.newAdlSnapshotFundingIndex);
        }
        // Clear both auction clocks on the way out of a window. Reaching here with
        // newIsAdlPending false means the hysteresis released — the fund above its reserve can
        // finish the remaining inventory inside the band — since the timeout branch of
        // checkLiqExposure re-asserts the
        // latch rather than dropping it. Without this the termination deadline would outlive the
        // auction it was measured for, and the pair's next window would open already armed with an
        // instant in the past: terminable on its first block, with no runway at all. Reads the
        // pre-assignment flag, so it must precede the write below.
        if (isAdlPending && !result.newIsAdlPending) {
            adlTerminationTs = 0;
            adlAuctionStartTs = 0;
        }
        isAdlPending = result.newIsAdlPending;
        adlPendingSince = result.newAdlPendingSince;
        if (!staleRetarget) {
            adlSnapshotPrice = result.newAdlSnapshotPrice;
            adlSnapshotFundingIndex = result.newAdlSnapshotFundingIndex;
            adlLongs = result.newAdlLongs;
        }

        if (result.adlTimeoutExpired && !isPriceStale && adlTerminationTs != 0 && block.timestamp >= adlTerminationTs) {
            // Price-driven insolvency: the vault could not deleverage a real move within the auction
            // window. Settle via the equity path at the live price so winners and losers settle
            // fairly, rather than refunding collateral (which would hand losers a windfall).
            //
            // Requiring a fresh price fixes the whole book's settlement to a mark the oracle just
            // confirmed, rather than to whichever real tick someone last recorded. The expired
            // clock is not lost by deferring: it stays expired, so the first caller carrying a
            // fresh price terminates once the runway has run out. Nor can withholding freshness
            // stall termination — anyone who wants it can permissionlessly refresh the price and
            // fire it, and a feed dead long enough to make that impossible is what
            // BazaarPairTerminator.terminateStalePair is for.
            //
            // The adlTerminationTs legs add the runway itself. ADL requires a fresh price too, so a
            // closed market blocks the auction and this clock alike; both unblock together at the
            // first stored price, and without the delay they would race in that one block over a
            // pair the auction might still save. Deferring costs nothing that is not already spent:
            // the exposure has sat unresolved for a day, and half an hour of a market that is
            // demonstrably open is the cheapest possible test of whether it can be resolved at all.
            _terminateOnInsolvency(currentPrice);
            return (false, 2);
        }

        if (!result.healthy) {
            return (false, 1);
        }

        // Check 2: actual USDC held by contract vs vault accounting. Escrowed fees are a claim
        // on that USDC exactly like principal and insurance, so they belong in the expected
        // balance — omitting them would let the fund look solvent on cash already owed away.
        // The gap surfaces at finalize, where the pot is the actual balance: principal is paid
        // pro-rata on whatever cash is there, profits and insurers after it.
        if (CollateralLib.isBalanceShort(address(usdc), pairVault, feeEscrow.total, USDC_BALANCE_TOLERANCE_BP)) {
            _terminateOnInsolvency(currentPrice);
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

    /// @notice Permissionless price + margin-curve + vault-health refresher. Pushes the supplied
    ///         Pyth update (or relies on Pyth's on-chain cache), writes the result to
    ///         lastPairPrice, recomputes IMR/MMR and records a 24h-lagged MMR ring sample from
    ///         it, then judges vault health against the refreshed price. A caller whose refresh
    ///         ends a stale gap on an active pair may earn a small insurance-funded bounty
    ///         (RiskParamsLib.payRefreshBounty holds the gates and amount).
    /// @dev    Pays the Pyth fee from msg.value and refunds any unused ETH. The margin leg exists
    ///         so the sample ring keeps advancing through trading gaps — the matching entry
    ///         points only resample on arrivals and liquidate() after a successful liquidation,
    ///         so a quiet pair would otherwise freeze laggedMmr() at an arbitrarily old value.
    ///         The health leg exists for the same reason: every other entry point judges vault
    ///         health only after real activity (a fill, a liquidation, an unload, a withdrawal
    ///         against exposure), and the ADL latch that executeAdl requires is set nowhere
    ///         else. On a book too thin to trade, inventory the vault inherited from a
    ///         liquidation can drift past the ADL trigger with no auction opening and no
    ///         timeout clock running; this poke is the permissionless way to start both. It
    ///         carries the freshness rule of every health call — a stale mark reports the
    ///         exposure verdict but never opens an auction — and lives in this function's own
    ///         body rather than in the shared price helper, which the other entry points call
    ///         BEFORE their walks: judged there, the verdict would be taken on the book before
    ///         it absorbed anything, and taken twice. Like the bounty it runs only while no
    ///         settlement price is fixed: the auction state must not move once settlement has
    ///         begun, and a finalized pair (which always has one fixed) has nothing left to
    ///         judge. A verdict of realized bad debt, an expired auction or a books-vs-balance
    ///         shortfall fixes the settlement price inside the call, as it does from any other
    ///         entry point; the bounty is settled before that judgement, so the refresh that
    ///         opens the window is still paid for the fresh mark it stored and every later one
    ///         is not — from then on the insurance fund backs settlement claims, and freshness
    ///         no longer protects anyone.
    function refreshPrice(bytes[] calldata priceUpdate) external payable nonReentrant {
        uint256 prevUpdateTs = lastPairPrice.updateTs;
        (BazaarTypes.PairPrice memory priceStruct, uint256 unusedEth, bool isStale) =
            _getCurrentPairPrice(priceUpdate, msg.value);
        _refreshMarginCurve(priceStruct.spotPrice);
        if (settlementPriceFixedTs == 0) {
            RiskParamsLib.payRefreshBounty(pairVault, lastPairPrice, feeEscrow, pairId, prevUpdateTs);
            isVaultHealthy(priceStruct.spotPrice, isStale);
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
            uint256 prevUpdateTs = lastPairPrice.updateTs;
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

            // Start the timed-out auction's runway. Sited here because this branch is the only
            // writer of lastPairPrice and runs solely on a fresh, confidence-checked price, which
            // makes it the one place that observes the feed actually serving this pair — a price
            // the caller merely supplied but that fails the guard above stores nothing and arms
            // nothing. The adlPendingSince term also bounds how much runway a single window can
            // hand out: it is monotone across a mid-auction side flip, so re-targeting cannot
            // rewind the clock and buy another grace period.
            if (
                isAdlPending && adlTerminationTs == 0
                    && block.timestamp > adlPendingSince + VaultHealthLib.ADL_TIMEOUT_DURATION
            ) {
                adlTerminationTs = block.timestamp + BazaarTypes.ADL_TERMINATION_GRACE;
                emit AdlTerminationArmed(pairId, adlTerminationTs);
            }

            // Restart the auction's Dutch decay when a stored price ends a discontinuity. The
            // decay bounds which winners a keeper may submit and narrows as the auction fails to
            // turn up eligible ones — but a closure is not that failure: ADL cannot run without a
            // fresh price, so the threshold spent the gap descending against attempts nobody was
            // able to make. Left alone, the first keeper after a reopen meets a fully decayed gate
            // and may deleverage any profitable account, including ones a live auction would never
            // have reached. The bound is the pair's own discontinuity threshold, calibrated so the
            // refresh bounty's cadence separates a shut venue from ordinary call sparsity.
            //
            // Restarting rather than crediting only the gap forfeits whatever the auction had
            // already spent, which is bounded by the decay's own length; what it buys is a clock
            // that is a plain instant with no accumulated term to reason about. So on a pair quiet
            // enough to keep producing eligible gaps, the decay can keep restarting and the
            // auction stay out of reach — the termination clock runs underneath regardless and is
            // not affected by this, so such a pair still resolves rather than hanging.
            if (isAdlPending && publishTime - prevUpdateTs >= RiskParamsLib.REOPEN_GAP_MIN_STALENESS) {
                adlAuctionStartTs = block.timestamp;
            }
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
        s.settlementPrice = fixedSettlementPrice;
        s.terminalPrincipalRatioBp = terminalState.principalRatioBp;
        s.terminalProfitRatioBp = terminalState.profitRatioBp;
        s.terminalProfitClaims = terminalState.totalProfitClaims;
        s.terminalBadDebt = terminalState.terminalBadDebt;
        s.bugBountyAddress = bugBountyAddress;
    }

    /// @notice The window-deposit amount ADL ranking subtracts from `user`'s collateral: their
    ///         deposits epoch-tagged to the CURRENT ranking epoch, 0 when the tag is absent or
    ///         superseded — which a side flip does to every live tag. Read by
    ///         BazaarPairLens.getAdlScore and by keepers pre-sorting executeAdl batches, so score
    ///         previews apply the same epoch check the on-chain ranking does.
    function adlScoreDeposit(address user) external view returns (uint256) {
        return adlDepositEpoch[user] == adlEpoch ? adlWindowDeposits[user] : 0;
    }

    // ----------------------------------------------------------
    //  ADL window-deposit tracking (declared LAST: appending here
    //  preserves the storage slots of all earlier state)
    // ----------------------------------------------------------

    /// @notice ADL ranking-epoch counter — increments whenever a cohort is set: each false→true
    ///         isAdlPending transition, and each mid-auction side flip that re-targets the
    ///         auction. (Distinct from nextAdlId, which numbers individual executeAdl
    ///         installments; one pending window can span several of both.) Deposits made while a
    ///         window is live are epoch-tagged so ADL scoring ranks on the book as of the moment
    ///         the depositor's side came into range: a mid-auction top-up cannot dodge the queue,
    ///         while still fully counting for liquidation protection and ADL settlement. Tags from
    ///         superseded epochs fail the equality check and are ignored — lazy invalidation, no
    ///         cleanup pass, and the stale amount is overwritten by the depositor's next deposit.
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

    /// @notice Per-user registered profit claims and the aggregate terminal-settlement state
    ///         (the settlement tallies and the frozen payout ratios). The claim mapping is
    ///         public: winners read their registered claim through it
    ///         (BazaarPairLens.getTerminalEntitlement).
    mapping(address => uint256) public terminalProfitClaim;
    BazaarTypes.TerminalSettlement internal terminalState;

    /// @notice The fixed settlement price and the time it was fixed (0 while the pair is live).
    ///         Fixing the price opens the settlement window: liquidate() then settles positions
    ///         at this price with no oracle read, and finalizeTermination freezes the payout
    ///         ratios once every position is settled (or the escape hatch has elapsed).
    uint256 public fixedSettlementPrice;
    uint256 public settlementPriceFixedTs;

    /// @notice Peak-hold reopen-gap floor for non-continuously traded pairs (appended last to
    ///         preserve earlier slots). Written by RiskParamsLib.calculateVariance when a stored
    ///         price ends a gap of at least REOPEN_GAP_MIN_STALENESS; read by
    ///         RiskParamsLib.stressMoveBp, which carries it into both the margin curve and the
    ///         insurance target.
    BazaarTypes.ReopenGapEma internal reopenGapEma;

    /// @notice Pull-payment escrow for every USDC the pair owes a third party — integrators, the
    ///         bug-bounty recipient, keepers (trigger, unload, liquidation, ADL, refresh), the
    ///         UMA termination proposer and meta-tx relayers (appended last to preserve earlier
    ///         slots).
    /// @dev Accruing (FeeEscrowLib.credit) rather than transferring keeps token calls out of
    ///      every entry point that pays a third party, and removes the soft-fail-and-restore
    ///      bookkeeping a push payment needs — a recipient that cannot receive USDC simply never
    ///      claims, and the cash sits reserved. feeEscrow.total is a liability against the
    ///      pair's USDC: every books-vs-cash figure (the health check's expected balance, both
    ///      terminal surplus derivations) reserves it alongside D and I.
    BazaarTypes.FeeEscrow internal feeEscrow;

    /// @notice Instant from which a timed-out ADL auction may terminate the pair; 0 while unarmed
    ///         (appended last to preserve the storage slots of all earlier state).
    /// @dev Armed by _buildAndStorePairPrice — the sole writer of lastPairPrice, reached only from
    ///      a fresh confidence-checked price — on the first stored price past
    ///      adlPendingSince + VaultHealthLib.ADL_TIMEOUT_DURATION, and never re-armed while the
    ///      window lasts. Set
    ///      once is what makes it a deadline rather than a snooze button: refreshing on every
    ///      stored price would push termination out indefinitely, and the refresh bounty pays
    ///      keepers to hold live pairs to a ~10-minute cadence, so honest upkeep alone would keep a
    ///      failed auction pending forever. Cleared only when the auction resolves and the exposure
    ///      is back under the release level, so a later window on the same pair arms afresh
    ///      instead of inheriting a deadline already in the past.
    uint256 public adlTerminationTs;

    /// @notice Start of the ADL auction's current Dutch-decay run; 0 while no auction is open
    ///         (appended last to preserve the storage slots of all earlier state).
    /// @dev Set when a window opens, restarted on a mid-auction side flip that re-targets one, and
    ///      restarted by _buildAndStorePairPrice whenever a stored price ends a market
    ///      discontinuity. Deliberately separate from adlPendingSince: that one dates the window
    ///      and feeds the termination clock, which stays monotone so neither a closure nor a flip
    ///      can defer it, while this one measures only how far the eligibility threshold has
    ///      descended against a cohort that could actually be submitted, and may move forward.
    ///      AdlLib._getAdlScoreThreshold reads it, and 0 yields a threshold no score can reach.
    uint256 public adlAuctionStartTs;
}
