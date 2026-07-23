// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBazaarPair} from "./interfaces/IBazaarPair.sol";
import {IBazaarOracle} from "./interfaces/IBazaarOracle.sol";
import {BazaarTypes} from "./libraries/BazaarTypes.sol";
import {BazaarMathLib} from "./libraries/BazaarMathLib.sol";

contract BazaarSequencer is ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    address public immutable factory;

    uint256 public constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 public constant USDC_SCALE = BazaarTypes.USDC_SCALE;
    uint256 public constant USDC_TO_BAZAAR = BAZAAR_SCALE / USDC_SCALE; // 10^12
    uint256 public constant MIN_BOND = 1000 * BAZAAR_SCALE;
    uint256 public constant VOLUME_CAP_MULTIPLIER = 14;
    // Challenge deadline. Kept strictly below the volume-retention window (NUM_BUCKETS *
    // BUCKET_DURATION = 30 min) so a batch's bond stays in the withdrawal floor for the entire time
    // its challenge is valid.
    uint256 public constant SEQUENCER_WINDOW = 29 minutes;
    uint256 public constant BUCKET_DURATION = 1 minutes;
    uint256 public constant NUM_BUCKETS = 30;
    uint256 public constant BP_SCALE = BazaarTypes.BP_SCALE;
    uint256 public constant EBP_SCALE = BazaarTypes.EBP_SCALE;

    /// @notice Penalty for omission challenges: 7% of min(batchNotional, omittedOrderNotional),
    ///         with a $20 floor. Set above the 5% market-order slippage cap so skipping is never
    ///         profitable. Split 1% to the challenger / 6% to the pair's insurance fund (not the
    ///         victim, so a sequencer can't profit by self-censoring its own order).
    uint256 public constant OMISSION_PENALTY_BP = BazaarTypes.OMISSION_PENALTY_BP;
    uint256 public constant OMISSION_PENALTY_MIN = 20 * BAZAAR_SCALE; // $20 floor (mirrors stale)
    uint256 public constant STALE_MARGIN_MULTIPLIER = BazaarTypes.STALE_MARGIN_MULTIPLIER;

    // -------------------- Stale-batch challenge constants --------------------

    /// @notice Mirrors BazaarPair.MAX_PRICE_STALENESS — window before matchTimestamp inside which
    ///         a Pyth tick must exist for the sequencer to NOT mark the batch stale.
    uint256 public constant MAX_PRICE_STALENESS = 2 seconds;
    /// @notice Excludes ticks published in the final second before matchTimestamp from
    ///         falsely-stale challenges — the sequencer can't observe a tick mined in the
    ///         same window it built the batch.
    uint256 public constant STALE_CHALLENGE_GRACE = 1 seconds;
    /// @notice Stale-challenge penalty: 100 bps (1%) of total batch notional, with a $20 floor.
    ///         Split 50/50 between the challenger and the challenged pair's insurance fund.
    uint256 public constant STALE_PENALTY_BP = 100;
    uint256 public constant STALE_PENALTY_MIN = 20 * BAZAAR_SCALE;

    // Registered pair contracts (written by factory during deployment)
    EnumerableSet.AddressSet private _registeredPairs;

    // All bond values stored in BAZAAR_SCALE (1e18)
    mapping(address => uint256) public sequencerBonds;
    uint256 public totalSequencerBonds;

    // Global rolling volume tracking (mirrors per-sequencer bucket approach for accuracy)
    VolumeBucket[30] private _globalVolumeBuckets;

    // Dynamic taker sequencer fee constants (based on bond utilization)
    uint256 public constant UTILIZATION_HEALTHY_BP = 5_000;
    uint256 public constant UTILIZATION_CRITICAL_BP = 9_000;
    uint256 public constant TAKER_SEQ_FEE_BASE_EBP = 75; // 0.75 bps
    uint256 public constant TAKER_SEQ_FEE_MAX_EBP = 375; // 3.75 bps

    struct VolumeBucket {
        uint256 volume;
        uint256 epoch;
    }
    mapping(address => mapping(uint256 => VolumeBucket)) private _volumeBuckets;

    /// @dev Tracks (pair, omittedOrderId) pairs that already won a successful omission
    ///      challenge — each omitted order is good for one slash.
    EnumerableSet.Bytes32Set private _successfulChallenges;

    /// @dev Cumulative omission penalty already slashed per (pair, batchId). Caps the total at
    ///      OMISSION_PENALTY_BP of the batch's matched notional: an omission challenge charges on
    ///      the order's full size even if it was already partially filled, so without this cap
    ///      stacked challenges across orders could exceed the actually-censorable volume.
    mapping(address => mapping(uint256 => uint256)) private _omissionPaidPerBatch;

    // -------------------- Errors --------------------

    error Sequencer__ZeroAddress();
    error Sequencer__OnlyFactory();
    error Sequencer__OnlyPair();
    error Sequencer__PairNotRegistered();
    error Sequencer__ChallengeWindowExpired();
    error Sequencer__AlreadyChallenged();
    error Sequencer__InsufficientPythFee(uint256 provided, uint256 required);
    error Sequencer__EthRefundFailed();
    error Sequencer__ZeroAmount();
    error Sequencer__FirstDepositBelowMinBond(uint256 amount, uint256 minBond);
    error Sequencer__InsufficientBondBalance(uint256 requested, uint256 available);
    error Sequencer__RemainingBondBelowMinBond(uint256 remaining, uint256 minBond);
    error Sequencer__BondBelowRollingVolumeRequirement(uint256 remaining, uint256 required);
    error Sequencer__WithdrawalBelowUsdcGranularity();

    // -------------------- Events --------------------

    event PairRegistered(address indexed pair);
    event BondDeposited(address indexed sequencer, uint256 usdcAmount, uint256 newBalance);
    event BondWithdrawn(address indexed sequencer, uint256 usdcAmount, uint256 newBalance);
    event VolumeRecorded(address indexed sequencer, address indexed pair, uint256 volume);
    event OmissionChallengeSucceeded(
        address indexed pair,
        uint256 indexed batchId,
        uint256 indexed omittedOrderId,
        address sequencer,
        address challenger,
        uint256 penalty
    );
    event OmissionChallengeRejected(
        address indexed pair, uint256 indexed batchId, uint256 indexed omittedOrderId, uint8 reason
    );
    event StaleChallengeSucceeded(
        address indexed pair, uint256 indexed batchId, address indexed sequencer, address challenger, uint256 penalty
    );
    event StaleChallengeRejected(address indexed pair, uint256 indexed batchId, uint8 reason);
    // Stale-challenge reason codes:
    //   1 = batch hash mismatch / missing
    //   2 = batch was not labeled stale
    //   3 = no fresh price found in window (sequencer was correct)

    // Reason codes for OmissionChallengeRejected:
    //   1 = batch hash mismatch
    //   2 = omitted order does not exist
    //   3 = order out of price range (no in-range witness available)
    //   4 = order not live at observationBlock or executionBlock
    //   5 = order ineligible for stale batch (Market/StopLoss during stale)
    //   9 = order is in BatchInfo.staleSkippedIds (sequencer included it; walk skipped due to stale-only IMR failure)

    // -------------------- Modifiers --------------------

    modifier onlyFactory() {
        if (msg.sender != factory) revert Sequencer__OnlyFactory();
        _;
    }

    modifier onlyPair() {
        if (!_registeredPairs.contains(msg.sender)) revert Sequencer__OnlyPair();
        _;
    }

    constructor(address _usdc, address _factory) {
        if (_usdc == address(0) || _factory == address(0)) revert Sequencer__ZeroAddress();
        usdc = IERC20(_usdc);
        factory = _factory;
    }

    // -------------------- Factory functions --------------------

    function registerPair(address pair) external onlyFactory {
        if (pair == address(0)) revert Sequencer__ZeroAddress();
        _registeredPairs.add(pair);
        emit PairRegistered(pair);
    }

    function isPair(address addr) external view returns (bool) {
        return _registeredPairs.contains(addr);
    }

    // -------------------- Bond management --------------------

    function deposit(uint256 usdcAmount) external nonReentrant {
        if (usdcAmount == 0) revert Sequencer__ZeroAmount();
        uint256 bazaarAmount = usdcAmount * USDC_TO_BAZAAR;
        if (sequencerBonds[msg.sender] == 0 && bazaarAmount < MIN_BOND) {
            revert Sequencer__FirstDepositBelowMinBond(bazaarAmount, MIN_BOND);
        }
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        sequencerBonds[msg.sender] += bazaarAmount;
        totalSequencerBonds += bazaarAmount;
        emit BondDeposited(msg.sender, usdcAmount, sequencerBonds[msg.sender]);
    }

    function withdraw(uint256 bazaarAmount) external nonReentrant {
        if (bazaarAmount == 0) revert Sequencer__ZeroAmount();
        if (sequencerBonds[msg.sender] < bazaarAmount) {
            revert Sequencer__InsufficientBondBalance(bazaarAmount, sequencerBonds[msg.sender]);
        }
        uint256 newBalance = sequencerBonds[msg.sender] - bazaarAmount;
        if (newBalance < MIN_BOND && newBalance != 0) {
            revert Sequencer__RemainingBondBelowMinBond(newBalance, MIN_BOND);
        }
        uint256 rollingVolume = this.getRollingVolume(msg.sender);
        uint256 requiredBond = rollingVolume / VOLUME_CAP_MULTIPLIER;
        if (newBalance < requiredBond) {
            revert Sequencer__BondBelowRollingVolumeRequirement(newBalance, requiredBond);
        }
        sequencerBonds[msg.sender] = newBalance;
        totalSequencerBonds -= bazaarAmount;
        uint256 usdcAmount = bazaarAmount / USDC_TO_BAZAAR;
        if (usdcAmount == 0) revert Sequencer__WithdrawalBelowUsdcGranularity();
        usdc.safeTransfer(msg.sender, usdcAmount);
        emit BondWithdrawn(msg.sender, usdcAmount, sequencerBonds[msg.sender]);
    }

    // -------------------- Volume tracking --------------------

    function recordVolume(address sequencer, uint256 volume) external onlyPair {
        uint256 currentEpoch = block.timestamp / BUCKET_DURATION;
        uint256 bucketIndex = currentEpoch % NUM_BUCKETS;

        VolumeBucket storage bucket = _volumeBuckets[sequencer][bucketIndex];
        if (bucket.epoch == currentEpoch) {
            bucket.volume += volume;
        } else {
            bucket.volume = volume;
            bucket.epoch = currentEpoch;
        }

        VolumeBucket storage globalBucket = _globalVolumeBuckets[bucketIndex];
        if (globalBucket.epoch == currentEpoch) {
            globalBucket.volume += volume;
        } else {
            globalBucket.volume = volume;
            globalBucket.epoch = currentEpoch;
        }

        emit VolumeRecorded(sequencer, msg.sender, volume);
    }

    function getRollingVolume(address sequencer) external view returns (uint256 totalVolume) {
        uint256 currentEpoch = block.timestamp / BUCKET_DURATION;
        for (uint256 i = 0; i < NUM_BUCKETS; i++) {
            VolumeBucket storage bucket = _volumeBuckets[sequencer][i];
            if (currentEpoch - bucket.epoch < NUM_BUCKETS) {
                totalVolume += bucket.volume;
            }
        }
    }

    function _getGlobalRollingVolume() internal view returns (uint256 totalVolume) {
        uint256 currentEpoch = block.timestamp / BUCKET_DURATION;
        for (uint256 i = 0; i < NUM_BUCKETS; i++) {
            VolumeBucket storage bucket = _globalVolumeBuckets[i];
            if (currentEpoch - bucket.epoch < NUM_BUCKETS) {
                totalVolume += bucket.volume;
            }
        }
    }

    function getDynamicTakerSequencerFee() external view returns (uint256 feeEbp) {
        uint256 totalCapacity = totalSequencerBonds * VOLUME_CAP_MULTIPLIER;
        if (totalCapacity == 0) return TAKER_SEQ_FEE_MAX_EBP;

        uint256 currentVolume = _getGlobalRollingVolume();
        uint256 utilizationBp = currentVolume * BP_SCALE / totalCapacity;

        if (utilizationBp <= UTILIZATION_HEALTHY_BP) return TAKER_SEQ_FEE_BASE_EBP;
        if (utilizationBp >= UTILIZATION_CRITICAL_BP) return TAKER_SEQ_FEE_MAX_EBP;

        feeEbp = TAKER_SEQ_FEE_BASE_EBP + (TAKER_SEQ_FEE_MAX_EBP - TAKER_SEQ_FEE_BASE_EBP)
            * (utilizationBp - UTILIZATION_HEALTHY_BP) / (UTILIZATION_CRITICAL_BP - UTILIZATION_HEALTHY_BP);
    }

    function checkVolumeCapacity(address sequencer, uint256 additionalVolume)
        external
        view
        returns (bool hasCapacity, uint256 remainingCapacity)
    {
        uint256 bond = sequencerBonds[sequencer];
        if (bond < MIN_BOND) return (false, 0);

        uint256 maxVolume = bond * VOLUME_CAP_MULTIPLIER;
        uint256 currentVolume = this.getRollingVolume(sequencer);

        if (currentVolume + additionalVolume > maxVolume) {
            remainingCapacity = maxVolume > currentVolume ? maxVolume - currentVolume : 0;
            return (false, remainingCapacity);
        }

        remainingCapacity = maxVolume - currentVolume - additionalVolume;
        return (true, remainingCapacity);
    }

    function getBond(address sequencer) external view returns (uint256) {
        return sequencerBonds[sequencer];
    }

    // -------------------- Omission challenge --------------------

    /// @notice Challenge a batch for omitting an order that should have matched.
    ///         No challenger-supplied bucket-state preimage is required — soundness comes from:
    ///           (a) creation-time IMR enforcement bounding active-order exposure per user,
    ///           (b) auto-cancel of fresh-IMR margin failures during the walk,
    ///           (c) staleSkippedIds[] for stale-only IMR failures.
    ///         An order alive at execution + in matched range and not in staleSkippedIds was
    ///         definitively omitted by the sequencer.
    function challengeOmission(
        address pair,
        uint256 batchId,
        BazaarTypes.BatchInfo calldata info,
        uint256 omittedOrderId
    ) external nonReentrant {
        if (!_registeredPairs.contains(pair)) {
            revert Sequencer__PairNotRegistered();
        }

        // Challenge window: must be within SEQUENCER_WINDOW of the batch's matchTimestamp
        if (block.timestamp > uint256(info.matchTimestamp) + SEQUENCER_WINDOW) {
            revert Sequencer__ChallengeWindowExpired();
        }

        // Key per (batch, order) to prevent double-challenges on the same order.
        bytes32 challengeKey = keccak256(abi.encodePacked("om", pair, batchId, omittedOrderId));
        if (_successfulChallenges.contains(challengeKey)) revert Sequencer__AlreadyChallenged();

        IBazaarPair pairContract = IBazaarPair(pair);

        // === Step 1: verify BatchInfo preimage against stored hash ===
        bytes32 storedHash = pairContract.batchHashes(batchId);
        if (storedHash == bytes32(0) || keccak256(abi.encode(info)) != storedHash) {
            emit OmissionChallengeRejected(pair, batchId, omittedOrderId, 1);
            return;
        }

        // === Step 2: read omitted order ===
        OmittedOrder memory order = _readOrder(pairContract, omittedOrderId);
        if (order.creator == address(0)) {
            emit OmissionChallengeRejected(pair, batchId, omittedOrderId, 2);
            return;
        }

        // === Step 3: stale-batch eligibility — Market/StopLoss can't be challenged in stale batches
        if (
            info.isStale
                && (order.orderType == uint8(BazaarTypes.OrderType.Market)
                    || order.orderType == uint8(BazaarTypes.OrderType.StopLoss))
        ) {
            emit OmissionChallengeRejected(pair, batchId, omittedOrderId, 5);
            return;
        }

        // === Step 4: dual-block liveness ===
        if (
            order.creationBlock > info.observationBlock
                || (order.canceledBlock != 0 && order.canceledBlock <= info.executionBlock)
                || (order.filledBlock != 0 && order.filledBlock <= info.executionBlock)
                || order.expiryBlock < info.executionBlock
        ) {
            emit OmissionChallengeRejected(pair, batchId, omittedOrderId, 4);
            return;
        }

        // === Step 5: staleSkippedIds membership — sequencer demonstrably included this order
        //     and the walk skipped it due to stale-only IMR failure. Not omission.
        uint256 skippedLen = info.staleSkippedIds.length;
        for (uint256 i; i < skippedLen;) {
            if (info.staleSkippedIds[i] == omittedOrderId) {
                emit OmissionChallengeRejected(pair, batchId, omittedOrderId, 9);
                return;
            }
            unchecked {
                ++i;
            }
        }

        // === Step 5b: stop trigger gate — a StopLoss/StopLimit only matches once the batch oracle
        //     price has reached its trigger (buy stop: price >= trigger; sell stop: price <= trigger).
        //     If the trigger wasn't reached, the sequencer was CORRECT to omit it — not censorship.
        //     Mirrors the matching engine's settlement-price trigger check.
        if (
            (order.orderType == uint8(BazaarTypes.OrderType.StopLoss)
                    || order.orderType == uint8(BazaarTypes.OrderType.StopLimit))
                && !BazaarMathLib.stopTriggerReached(order.isLong, order.triggerPrice, info.oraclePrice)
        ) {
            emit OmissionChallengeRejected(pair, batchId, omittedOrderId, 10);
            return;
        }

        // === Step 6: in-range check (per omitted-order type) ===
        uint256 omittedEffectivePrice = _effectivePrice(order, info.oraclePrice);
        bool inRange = _isInRange(order, omittedOrderId, omittedEffectivePrice, info);
        if (!inRange) {
            emit OmissionChallengeRejected(pair, batchId, omittedOrderId, 3);
            return;
        }

        // === Step 7: penalty + payout ===
        // Reaching here means Step 4 already proved the order was NOT fully filled as of
        // info.executionBlock (a fill at/before the batch sets filledBlock and is rejected there),
        // so at match time it was a live, fillable order. There is no on-chain snapshot of how many
        // shares were already filled at that block — filledSize is a single running counter that
        // later batches keep mutating — so we make the sequencer-conservative assumption that the
        // ENTIRE order was unfilled and censorable at match time, and charge on order.size rather
        // than the current remainder. This is still bounded by totalMatchNotional below (a sequencer
        // can never be slashed for more than the liquidity that actually crossed in the batch).
        uint256 censoredNotional = Math.mulDiv(order.size, omittedEffectivePrice, BAZAAR_SCALE);
        uint256 penaltyBase = info.totalMatchNotional < censoredNotional ? info.totalMatchNotional : censoredNotional;
        uint256 penalty = Math.mulDiv(penaltyBase, OMISSION_PENALTY_BP, BP_SCALE);
        if (penalty < OMISSION_PENALTY_MIN) penalty = OMISSION_PENALTY_MIN; // $20 floor

        // Per-batch cap: cumulative omission penalties for this batch can't exceed
        // OMISSION_PENALTY_BP of its matched notional. Once exhausted, further challenges still
        // succeed (the omission is recorded and the (batch, order) key is locked) but slash 0.
        uint256 batchCap = Math.mulDiv(info.totalMatchNotional, OMISSION_PENALTY_BP, BP_SCALE);
        uint256 paid = _omissionPaidPerBatch[pair][batchId];
        uint256 capRoom = batchCap > paid ? batchCap - paid : 0;
        if (penalty > capRoom) penalty = capRoom;

        uint256 actualPenalty = 0;
        if (penalty > 0) {
            // 1/7 (1%) bounty to the challenger; 6/7 (6%) to the pair's insurance fund. Routing the
            // 6% to insurance (not order.creator) means a sequencer self-censoring its own order
            // can't recover it — self-omission costs the full 6%, removing the cap-evasion profit.
            actualPenalty = _slashToInsurance(info.sequencer, pair, penalty, 7);
            _omissionPaidPerBatch[pair][batchId] = paid + actualPenalty;
        }
        // Consume the (batch, order) key only when the challenge was truly satisfied: it collected a
        // penalty, or the per-batch cap was already exhausted (an intentional no-pay success — further
        // challenges on this batch can't pay regardless). A zero collected purely because the
        // sequencer's bond was drained leaves the key OPEN, so the proven omission can still be
        // charged if the sequencer ever re-bonds — rather than being permanently marked resolved.
        if (actualPenalty > 0 || capRoom == 0) {
            _successfulChallenges.add(challengeKey);
        }
        emit OmissionChallengeSucceeded(pair, batchId, omittedOrderId, info.sequencer, msg.sender, actualPenalty);
    }

    /// @dev In-range check: same-side cutoff with FIFO orderId tiebreak. For Market/StopLoss,
    ///      additionally tries Pass-C cross-side witness (always-on, catches selective censorship).
    function _isInRange(
        OmittedOrder memory order,
        uint256 omittedOrderId,
        uint256 omittedEff,
        BazaarTypes.BatchInfo calldata info
    ) internal pure returns (bool) {
        BazaarTypes.OrderType ot = BazaarTypes.OrderType(order.orderType);
        bool isMarketLike = (ot == BazaarTypes.OrderType.Market || ot == BazaarTypes.OrderType.StopLoss);

        if (order.isLong) {
            if (!isMarketLike) {
                if (info.lowestLongLimitPrice != 0) {
                    if (omittedEff > info.lowestLongLimitPrice) return true;
                    if (omittedEff == info.lowestLongLimitPrice && omittedOrderId < info.lowestLongLimitId) {
                        return true;
                    }
                }
                return false;
            }
            // Market/StopLoss: same-side market FIFO, then Pass-C cross-side fallback
            if (info.lowestLongMarketPrice != 0) {
                if (omittedEff > info.lowestLongMarketPrice) return true;
                if (omittedEff == info.lowestLongMarketPrice && omittedOrderId < info.lowestLongMarketId) return true;
            }
            if (info.lowestShortLimitPriceC != 0 && omittedEff >= info.lowestShortLimitPriceC) return true;
            return false;
        } else {
            if (!isMarketLike) {
                if (info.highestShortLimitPrice != 0) {
                    if (omittedEff < info.highestShortLimitPrice) return true;
                    if (omittedEff == info.highestShortLimitPrice && omittedOrderId < info.highestShortLimitId) {
                        return true;
                    }
                }
                return false;
            }
            if (info.highestShortMarketPrice != 0) {
                if (omittedEff < info.highestShortMarketPrice) return true;
                if (omittedEff == info.highestShortMarketPrice && omittedOrderId < info.highestShortMarketId) {
                    return true;
                }
            }
            if (info.highestLongLimitPriceC != 0 && omittedEff <= info.highestLongLimitPriceC) return true;
            return false;
        }
    }

    // -------------------- Stale-batch challenge --------------------

    /// @notice Challenge a batch that was wrongfully labeled as stale. If the challenger
    ///         supplies Pyth price data proving a fresh tick existed in
    ///         [matchTimestamp - MAX_PRICE_STALENESS, matchTimestamp - STALE_CHALLENGE_GRACE],
    ///         the sequencer had a fresh price available and is slashed.
    /// @dev    Payable because Pyth's parseUpdates charges a fee in ETH.
    /// @param pair      Pair contract that produced the batch
    /// @param batchId   Batch id whose hash is stored in pair.batchHashes
    /// @param info      Full BatchInfo preimage (rehashed and verified; isStale must be true)
    /// @param priceData Pyth price-update blob containing at least one fresh tick in the window
    function challengeStaleBatch(
        address pair,
        uint256 batchId,
        BazaarTypes.BatchInfo calldata info,
        bytes[] calldata priceData
    ) external payable nonReentrant {
        if (!_registeredPairs.contains(pair)) {
            revert Sequencer__PairNotRegistered();
        }
        if (block.timestamp > uint256(info.matchTimestamp) + SEQUENCER_WINDOW) {
            revert Sequencer__ChallengeWindowExpired();
        }

        bytes32 challengeKey = keccak256(abi.encodePacked("stale", pair, batchId));
        if (_successfulChallenges.contains(challengeKey)) revert Sequencer__AlreadyChallenged();

        IBazaarPair pairContract = IBazaarPair(pair);

        // Default to refunding the full msg.value: only a SUCCESSFUL challenge actually spends the
        // Pyth fee. Every reject/catch path leaves this untouched, and the single refund at the end
        // runs on all paths (no early returns) — so fee ETH is never stranded in the contract.
        uint256 refund = msg.value;

        // === Step 1: verify BatchInfo preimage against stored hash ===
        bytes32 storedHash = pairContract.batchHashes(batchId);
        if (storedHash == bytes32(0) || keccak256(abi.encode(info)) != storedHash) {
            emit StaleChallengeRejected(pair, batchId, 1);
        } else if (!info.isStale) {
            // === Step 2: batch must actually have been labeled stale ===
            emit StaleChallengeRejected(pair, batchId, 2);
        } else {
            // === Step 3: prove a fresh Pyth tick existed within the window ===
            uint64 matchTs = info.matchTimestamp;
            uint64 minPublishTime = matchTs > uint64(MAX_PRICE_STALENESS) ? matchTs - uint64(MAX_PRICE_STALENESS) : 0;
            uint64 maxPublishTime =
                matchTs > uint64(STALE_CHALLENGE_GRACE) ? matchTs - uint64(STALE_CHALLENGE_GRACE) : 0;

            IBazaarOracle oracle = IBazaarOracle(pairContract.oracle());
            uint256 fee = oracle.getUpdateFee(priceData);
            if (msg.value < fee) revert Sequencer__InsufficientPythFee(msg.value, fee);

            try oracle.fetchHistoricalPrice{value: fee}(
                pairContract.baseFeedId(), priceData, minPublishTime, maxPublishTime
            ) {
                // === Step 4: fresh price existed — slash sequencer ===
                uint256 scaledPenalty = Math.mulDiv(info.totalMatchNotional, STALE_PENALTY_BP, BP_SCALE);
                uint256 penalty = scaledPenalty > STALE_PENALTY_MIN ? scaledPenalty : STALE_PENALTY_MIN;

                // Half to the challenger (msg.sender), half credited to the challenged pair's
                // insurance fund.
                uint256 actualPenalty = _slashToInsurance(info.sequencer, pair, penalty, 2);
                // Only mark the batch resolved if the slash actually landed. A zero collected because
                // the sequencer's bond was drained leaves the challenge OPEN, so the proven stale-
                // labeling can still be charged if the sequencer re-bonds (mirrors challengeOmission).
                if (actualPenalty > 0) {
                    _successfulChallenges.add(challengeKey);
                }
                emit StaleChallengeSucceeded(pair, batchId, info.sequencer, msg.sender, actualPenalty);
                refund = msg.value - fee; // fee was actually paid to Pyth
            } catch {
                // No fresh tick: the batch was correctly labeled stale and fetchHistoricalPrice
                // reverted, so the fee was NOT consumed — refund stays the full msg.value.
                emit StaleChallengeRejected(pair, batchId, 3);
            }
        }

        // Refund unused ETH on every path. Done last so a malicious challenger contract can't
        // reenter into _successfulChallenges between the slash and the refund.
        if (refund > 0) {
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert Sequencer__EthRefundFailed();
        }
    }

    // -------------------- Internal helpers --------------------

    /// @dev Subset of Order fields needed for challenge processing. Read inline from the
    ///      pair's auto-generated `orders(uint256)` getter.
    struct OmittedOrder {
        address creator;
        uint8 orderType;
        uint256 triggerPrice;
        uint256 limitPrice;
        uint256 maxSlippageBp;
        uint256 size;
        uint256 filledSize;
        bool isLong;
        uint64 creationBlock;
        uint64 expiryBlock;
        uint64 canceledBlock;
        uint64 filledBlock;
    }

    function _readOrder(IBazaarPair pair, uint256 orderId) internal view returns (OmittedOrder memory o) {
        (
            address creator,, // integrator
            uint256 triggerPrice,
            uint256 limitPrice,
            uint256 maxSlippageBp,
            uint256 size,
            uint256 filledSize,
            uint8 orderType,
            bool isLong,, // isPostOnly (not relevant to omission challenge)
            uint64 creationBlock,
            uint64 expiryBlock,
            uint64 canceledBlock,
            uint64 filledBlock
        ) = pair.orders(orderId);

        o.creator = creator;
        o.orderType = orderType;
        o.triggerPrice = triggerPrice;
        o.limitPrice = limitPrice;
        o.maxSlippageBp = maxSlippageBp;
        o.size = size;
        o.filledSize = filledSize;
        o.isLong = isLong;
        o.creationBlock = creationBlock;
        o.expiryBlock = expiryBlock;
        o.canceledBlock = canceledBlock;
        o.filledBlock = filledBlock;
    }

    /// @dev Compute the omitted order's effective price using the batch oracle price.
    ///      Limit/TakeProfit use the configured limitPrice (TP is treated as limit-on-close).
    ///      Market/StopLoss derive the bound from oracle ± slippage.
    ///      StopLimit uses limitPrice once triggered (sequencer is responsible for confirming
    ///      the trigger; an omitted untriggered StopLimit would not have matched anyway).
    function _effectivePrice(OmittedOrder memory o, uint256 oraclePrice) internal pure returns (uint256) {
        return BazaarMathLib.effectivePrice(
            BazaarTypes.OrderType(o.orderType), o.limitPrice, o.isLong, o.maxSlippageBp, oraclePrice
        );
    }

    /// @dev Slash sequencer bond, paying a `1/challengerDivisor` bounty to the challenger
    ///      (msg.sender) and the remainder to the challenged pair's insurance fund. Shared by
    ///      omission (divisor 7 → 1% bounty / 6% insurance) and stale (divisor 2 → 50/50). Routing
    ///      the non-bounty share to insurance — not an offender-controllable victim — makes it
    ///      un-recoverable, so a sequencer can't profit by self-challenging its own order.
    ///      Returns the amount slashed (capped at remaining bond).
    /// @param sequencer        The slashed sequencer.
    /// @param pair             The challenged pair whose insurance fund receives the remainder.
    /// @param penalty          Requested penalty (BAZAAR precision); capped at the sequencer's bond.
    /// @param challengerDivisor The challenger receives penalty / challengerDivisor.
    function _slashToInsurance(address sequencer, address pair, uint256 penalty, uint256 challengerDivisor)
        internal
        returns (uint256)
    {
        uint256 bond = sequencerBonds[sequencer];
        if (penalty > bond) penalty = bond;
        if (penalty == 0) return 0;

        // Debit first (CEI). No best-effort re-credit: the challenger payout must land and the
        // insurance credit targets a trusted, factory-deployed pair, so neither share can be griefed.
        sequencerBonds[sequencer] -= penalty;
        totalSequencerBonds -= penalty;

        // Computed after the bond cap so the ratio is preserved even when penalty hit the cap.
        uint256 challengerReward = penalty / challengerDivisor;
        uint256 insuranceReward = penalty - challengerReward; // odd-wei goes to insurance

        uint256 challengerUsdc = challengerReward / USDC_TO_BAZAAR;
        uint256 insuranceUsdc = insuranceReward / USDC_TO_BAZAAR;

        if (challengerUsdc > 0) {
            usdc.safeTransfer(msg.sender, challengerUsdc);
        }

        // Push the USDC to the pair, then credit its insurance accounting by exactly the USDC
        // delivered (BAZAAR precision) so the fund stays fully backed (vault-health Check-3).
        if (insuranceUsdc > 0) {
            usdc.safeTransfer(pair, insuranceUsdc);
            IBazaarPair(pair).creditInsuranceFromSequencer(insuranceUsdc * USDC_TO_BAZAAR);
        }

        return penalty;
    }
}
