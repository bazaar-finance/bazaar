// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IOptimisticOracleV3,
    IOptimisticOracleV3CallbackRecipient,
    IERC20Minimal
} from "./interfaces/IUmaOptimisticOracleV3.sol";
import {IBazaarPair} from "./interfaces/IBazaarPair.sol";
import {BazaarOracle} from "./BazaarOracle.sol";
import {BazaarTypes} from "./libraries/BazaarTypes.sol";

interface IBazaarFactory {
    function oo() external view returns (IOptimisticOracleV3);
    function usdc() external view returns (address);
    function umaIdentifier() external view returns (bytes32);
}

contract BazaarPairTerminator is IOptimisticOracleV3CallbackRecipient, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    // -------------------- State --------------------

    address public immutable factory;

    uint256 public constant TERMINATION_PROPOSAL_BOND = 1000 * 1e6; // $1000 USDC (6 decimals)
    uint256 public constant TERMINATION_PROPOSAL_LIVENESS = 12 hours;
    /// @notice Dispute window for post-cessation proposals — longer than the scheduled path's
    ///         12 hours because acceptance halts the market instantly (the timestamp is already
    ///         past), so no exit window exists after approval; all scrutiny must happen before
    ///         it. 72 hours gives watchers three days to verify the feed is genuinely dead and
    ///         dispute if it is still publishing.
    uint256 public constant POST_CESSATION_PROPOSAL_LIVENESS = 72 hours;

    /// @notice Bounds on the proposer-supplied free text embedded in the UMA claim.
    uint256 public constant MAX_REASON_LENGTH = 1000;
    uint256 public constant MAX_PAIR_DESCRIPTION_LENGTH = 100;

    EnumerableSet.AddressSet private _registeredPairs;

    // Per-pair tracking
    mapping(address => bytes32) public acceptedTerminationAssertionId;

    /// @notice When a pair's termination proposal was accepted (UMA resolution time). Anchors the
    ///         precise-only settlement grace in terminateScheduledPair: post-cessation proposals
    ///         schedule an already-past timestamp, so the grace must run from acceptance or the
    ///         precise historical tick would never get its exclusivity window.
    mapping(address => uint256) public terminationAcceptedTs;

    // Proposal mapping (keyed by assertionId) — shared by scheduled AND post-cessation
    // proposals; for post-cessation, `lastTradingTs` is the (past) cessation timestamp.
    mapping(bytes32 => TerminationProposal) public terminationProposals;

    /// @notice The Optimistic Oracle an assertion was created against, recorded at proposal time.
    /// @dev Settlement and callback auth route through this per-assertion OO instead of the
    ///      factory's mutable `oo`, so a factory oracle upgrade can't strand in-flight
    ///      termination assertions (their bonds) created against the previous oracle.
    mapping(bytes32 => IOptimisticOracleV3) public assertionOo;

    // -------------------- Structs --------------------

    struct TerminationProposal {
        address pair;
        address proposer;
        uint256 lastTradingTs;
        string reason;
        uint256 proposalTs;
        bool resolved;
    }

    // -------------------- Events --------------------

    event PairRegistered(address indexed pair);

    event TerminationProposalSubmitted(
        address indexed pair,
        bytes32 indexed assertionId,
        address indexed proposer,
        uint256 lastTradingTs,
        string reason
    );

    event TerminationProposalDisputed(bytes32 indexed assertionId);

    event TerminationProposalAccepted(address indexed pair, bytes32 indexed assertionId, uint256 lastTradingTs);

    event PostCessationProposalSubmitted(
        address indexed pair,
        bytes32 indexed assertionId,
        address indexed proposer,
        uint256 priceTimestamp,
        string reason
    );

    // -------------------- Errors --------------------

    error BazaarPairTerminator__ZeroAddress();
    error BazaarPairTerminator__OnlyFactory();
    error BazaarPairTerminator__OnlyUmaOracle();
    error BazaarPairTerminator__PairNotRegistered();
    error BazaarPairTerminator__AlreadyTerminated();
    error BazaarPairTerminator__SettlementAlreadyFixed();
    error BazaarPairTerminator__TerminationAlreadyAccepted();
    error BazaarPairTerminator__LastTradingTsTooSoon(uint256 lastTradingTs, uint256 minimum);
    error BazaarPairTerminator__InvalidReasonLength(uint256 length);
    error BazaarPairTerminator__InvalidPairDescriptionLength(uint256 length);
    error BazaarPairTerminator__InvalidPriceTimestamp(uint256 priceTimestamp);
    error BazaarPairTerminator__UnknownAssertion();
    error BazaarPairTerminator__AlreadyResolved();
    error BazaarPairTerminator__NoScheduledTermination();
    error BazaarPairTerminator__TerminationTimeNotReached(uint256 scheduledTs, uint256 currentTs);
    error BazaarPairTerminator__OracleNotStaleEnough(uint256 lastUpdate, uint256 threshold);
    error BazaarPairTerminator__NoStoredPrice();
    error BazaarPairTerminator__InsufficientPythFee(uint256 provided, uint256 required);
    error BazaarPairTerminator__EthRefundFailed();

    // -------------------- Modifiers --------------------

    modifier onlyFactory() {
        if (msg.sender != factory) revert BazaarPairTerminator__OnlyFactory();
        _;
    }

    // -------------------- Constructor --------------------

    constructor(address _factory) {
        if (_factory == address(0)) revert BazaarPairTerminator__ZeroAddress();
        factory = _factory;
    }

    // -------------------- Internal helpers (read UMA config from Factory) --------------------

    function _oo() internal view returns (IOptimisticOracleV3) {
        return IBazaarFactory(factory).oo();
    }

    function _bondToken() internal view returns (IERC20Minimal) {
        return IERC20Minimal(IBazaarFactory(factory).usdc());
    }

    function _umaIdentifier() internal view returns (bytes32) {
        return IBazaarFactory(factory).umaIdentifier();
    }

    // -------------------- Factory functions --------------------

    function registerPair(address pair) external onlyFactory {
        if (pair == address(0)) revert BazaarPairTerminator__ZeroAddress();
        _registeredPairs.add(pair);
        emit PairRegistered(pair);
    }

    function isPair(address addr) external view returns (bool) {
        return _registeredPairs.contains(addr);
    }

    // -------------------- Proposal functions --------------------

    /// @dev Bounds the free-text fields that get embedded in the UMA claim. Shared by both
    ///      proposal entry points so the limits can only ever diverge deliberately.
    function _validateProposalText(string calldata reason, string calldata pairDescription) internal pure {
        uint256 reasonLen = bytes(reason).length;
        if (reasonLen == 0 || reasonLen > MAX_REASON_LENGTH) {
            revert BazaarPairTerminator__InvalidReasonLength(reasonLen);
        }
        uint256 descriptionLen = bytes(pairDescription).length;
        if (descriptionLen == 0 || descriptionLen > MAX_PAIR_DESCRIPTION_LENGTH) {
            revert BazaarPairTerminator__InvalidPairDescriptionLength(descriptionLen);
        }
    }

    /// @dev Claim-text fragment describing the pair's price feed(s). Composite feed IDs are
    ///      resolved to their underlying Pyth legs so UMA verifiers can check them against the
    ///      Pyth registry (a composite ID itself does not exist on Pyth).
    function _feedIdSection(IBazaarPair p) internal view returns (bytes memory) {
        bytes32 feedId = p.baseFeedId();
        (bytes32 legBaseId, bytes32 legQuoteId, bool legInvertQuote) = BazaarOracle(p.oracle()).composites(feedId);

        if (legBaseId == bytes32(0)) {
            return abi.encodePacked(". Base feed ID: ", Strings.toHexString(uint256(feedId)));
        }
        return abi.encodePacked(
            ". Composite feed ID (USD price = base leg ",
            legInvertQuote ? "DIVIDED by" : "MULTIPLIED by",
            " quote leg): ",
            Strings.toHexString(uint256(feedId)),
            ". Base leg feed ID: ",
            Strings.toHexString(uint256(legBaseId)),
            ". Quote leg feed ID (FX): ",
            Strings.toHexString(uint256(legQuoteId))
        );
    }

    function proposeTermination(
        address pair,
        string calldata pairDescription,
        uint256 lastTradingTs,
        string calldata reason
    ) external nonReentrant returns (bytes32 assertionId) {
        if (!_registeredPairs.contains(pair)) revert BazaarPairTerminator__PairNotRegistered();
        IBazaarPair p = IBazaarPair(pair);
        if (p.isPairTerminatedEmergency() || p.isPairTerminatedNormal()) {
            revert BazaarPairTerminator__AlreadyTerminated();
        }
        if (p.settlementPriceFixedTs() != 0) revert BazaarPairTerminator__SettlementAlreadyFixed();
        if (acceptedTerminationAssertionId[pair] != bytes32(0)) {
            revert BazaarPairTerminator__TerminationAlreadyAccepted();
        }
        // Tied to the liveness so the trading cutoff can never land before the dispute window
        // ends — the earliest possible acceptance can't halt a market that still has time left.
        uint256 minLastTradingTs = block.timestamp + TERMINATION_PROPOSAL_LIVENESS;
        if (lastTradingTs < minLastTradingTs) {
            revert BazaarPairTerminator__LastTradingTsTooSoon(lastTradingTs, minLastTradingTs);
        }
        _validateProposalText(reason, pairDescription);

        IOptimisticOracleV3 oo = _oo();
        IERC20Minimal bondToken = _bondToken();

        IERC20(address(bondToken)).safeTransferFrom(msg.sender, address(this), TERMINATION_PROPOSAL_BOND);
        IERC20(address(bondToken)).forceApprove(address(oo), TERMINATION_PROPOSAL_BOND);

        bytes memory claim = bytes.concat(
            abi.encodePacked(
                "Termination proposal for Bazaar trading pair ",
                pairDescription,
                " (pair ID: ",
                Strings.toHexString(uint256(p.pairId())),
                ") on Arbitrum (chain ID 42161).",
                " Pyth oracle: ",
                Strings.toHexString(address(BazaarOracle(p.oracle()).pyth())),
                _feedIdSection(p),
                ". Proposed last trading timestamp: ",
                Strings.toString(lastTradingTs),
                "." " Proposer's Reason and Evidence: ",
                reason
            ),
            abi.encodePacked(
                ". VALID TERMINATION REASONS (proposal must match exactly one): "
                "(1) ORACLE DECOMMISSION: The Pyth feed(s) listed above are scheduled to be decommissioned or will cease publishing updates. For a composite (two-leg) feed, decommissioning of EITHER leg - the base leg or the quote/FX leg - is sufficient grounds, since the pair cannot be priced in USD without both legs. "
                "(2) ASSET CESSATION: The underlying asset will be delisted from the exchange tracked by the oracle feed, rendering the feed invalid (even if the asset continues trading OTC). Includes: exchange delisting, merger/acquisition (cash or stock conversion), bankruptcy, or indefinite regulatory halt. "
                "(3) STRUCTURAL CHANGE: The asset or index will undergo a corporate, administrative, or methodological event that makes its price series discontinuous - the price published after the event is not comparable to the price before it. "
                "Examples (non-exhaustive): splits, reverse splits, spinoffs, rights offerings, special dividends or other one-time distributions exceeding 5% of the asset's price, "
                "token redenominations or migrations, index re-basings or methodology changes to the published level, and redenomination of the quote currency of a composite pair. "
                "NOT valid: regular cash dividends, and market-driven price moves of ANY expected size (e.g., earnings, court rulings, regulatory news, macroeconomic events) - anticipated volatility is tradeable risk, not a structural discontinuity. "
                "(4) PYTH CONTRACT MIGRATION: The Pyth oracle contract at the address listed above has been deprecated or is migrating to a new contract address, rendering the pair unable to fetch prices."
            ),
            abi.encodePacked(
                " HOW TO VALIDATE: " "Uma should verify the proposer's evidence by checking official sources: "
                "(1) For oracle issues, check the Pyth Network status page and feed registry for the feed IDs listed above. "
                "(2) For asset cessation, verify with official exchange notices or regulatory filings. "
                "(3) For structural changes, verify with the company's investor relations page, the index provider's or token project's official announcements, exchange bulletins, or regulatory filings. "
                "(4) For Pyth contract migration, verify via Pyth Network official announcements that the oracle contract is being deprecated or migrated. "
                "(5) Confirm the proposed last trading timestamp is reasonable: it should be at or right before the last moment the asset can trade under existing (pre-event) conditions, but not unnecessarily early. "
                "Assertion is INVALID if: the reason does not match any category above, evidence is fabricated or unverifiable, or the timestamp is unreasonable. "
            )
        );

        assertionId = oo.assertTruth(
            claim,
            msg.sender,
            address(this),
            address(0),
            uint64(TERMINATION_PROPOSAL_LIVENESS),
            bondToken,
            TERMINATION_PROPOSAL_BOND,
            _umaIdentifier(),
            bytes32(0)
        );

        // Record the OO this assertion was created on so it settles there even if the factory
        // later upgrades its oracle.
        assertionOo[assertionId] = oo;
        terminationProposals[assertionId] = TerminationProposal({
            pair: pair,
            proposer: msg.sender,
            lastTradingTs: lastTradingTs,
            reason: reason,
            proposalTs: block.timestamp,
            resolved: false
        });

        emit TerminationProposalSubmitted(pair, assertionId, msg.sender, lastTradingTs, reason);
    }

    /// @notice Propose termination of a pair whose cessation event ALREADY happened. The proposer
    ///         supplies only the cessation TIMESTAMP — never a price. On acceptance the pair is
    ///         scheduled at that (past) timestamp, halting trading immediately, and then settles
    ///         through terminateScheduledPair at the Pyth tick in
    ///         [priceTimestamp - MAX_PRICE_STALENESS, priceTimestamp], verified on-chain from its
    ///         signed Pyth payload — so the settlement value is cryptographically bound to Pyth
    ///         data rather than trusted from the proposal text.
    function proposePostCessationTermination(
        address pair,
        string calldata pairDescription,
        uint256 priceTimestamp,
        string calldata reason
    ) external nonReentrant returns (bytes32 assertionId) {
        if (!_registeredPairs.contains(pair)) revert BazaarPairTerminator__PairNotRegistered();
        IBazaarPair p = IBazaarPair(pair);
        if (p.isPairTerminatedEmergency() || p.isPairTerminatedNormal()) {
            revert BazaarPairTerminator__AlreadyTerminated();
        }
        if (p.settlementPriceFixedTs() != 0) revert BazaarPairTerminator__SettlementAlreadyFixed();
        if (acceptedTerminationAssertionId[pair] != bytes32(0)) {
            revert BazaarPairTerminator__TerminationAlreadyAccepted();
        }
        if (priceTimestamp == 0 || priceTimestamp > block.timestamp) {
            revert BazaarPairTerminator__InvalidPriceTimestamp(priceTimestamp);
        }
        _validateProposalText(reason, pairDescription);

        IOptimisticOracleV3 oo = _oo();
        IERC20Minimal bondToken = _bondToken();

        IERC20(address(bondToken)).safeTransferFrom(msg.sender, address(this), TERMINATION_PROPOSAL_BOND);
        IERC20(address(bondToken)).forceApprove(address(oo), TERMINATION_PROPOSAL_BOND);

        bytes memory claim = bytes.concat(
            abi.encodePacked(
                "Post-cessation termination proposal for Bazaar trading pair ",
                pairDescription,
                " (pair ID: ",
                Strings.toHexString(uint256(p.pairId())),
                ") on Arbitrum (chain ID 42161).",
                " Pyth oracle: ",
                Strings.toHexString(address(BazaarOracle(p.oracle()).pyth())),
                _feedIdSection(p),
                ". Proposed cessation timestamp (last trading timestamp): ",
                Strings.toString(priceTimestamp),
                ". SETTLEMENT: no price is proposed or trusted here. If accepted, the pair settles at the "
                "Pyth price update published within the 2 seconds at or before the proposed timestamp, "
                "verified on-chain from its signed Pyth payload."
            ),
            abi.encodePacked(
                " Proposer's Reason and Evidence: ",
                reason,
                ". VALID REASONS (the event must have ALREADY OCCURRED, not just been announced): "
                "(1) ORACLE DECOMMISSIONED: The Pyth feed(s) listed above have been decommissioned or are indefinitely stale with no expected resumption of updates. For a composite (two-leg) feed, decommissioning or indefinite staleness of EITHER leg - the base leg or the quote/FX leg - is sufficient grounds, since the pair cannot be priced in USD without both legs. "
                "(2) ASSET CEASED TRADING: The underlying asset has been permanently delisted from the oracle's tracked exchange. "
            ),
            abi.encodePacked(
                " HOW TO VALIDATE: " "UMA voters must verify THREE things: "
                "(1) TERMINATION REASON: Check official sources (Pyth status page, exchange notices, regulatory filings) to confirm the cessation event has actually occurred. "
                "(2) TIMESTAMP PLACEMENT: The proposed timestamp should correspond to the last valid price right at/before the cessation event - not unnecessarily early, and not after the feed stopped publishing meaningful prices. "
                "(3) TICK AVAILABILITY: Query the Pyth Hermes/Benchmarks API and confirm a price update EXISTS for the base feed ID with publish time within the 2 seconds at or before the proposed timestamp. For composite feeds, BOTH legs must have updates in that window (settlement composes them on-chain). "
                "Assertion is INVALID if: the reason does not match any category above, the event has not actually occurred yet, "
                "the timestamp is unreasonable, or no Pyth update exists in the 2-second settlement window. "
            )
        );

        assertionId = oo.assertTruth(
            claim,
            msg.sender,
            address(this),
            address(0),
            uint64(POST_CESSATION_PROPOSAL_LIVENESS),
            bondToken,
            TERMINATION_PROPOSAL_BOND,
            _umaIdentifier(),
            bytes32(0)
        );

        assertionOo[assertionId] = oo;
        terminationProposals[assertionId] = TerminationProposal({
            pair: pair,
            proposer: msg.sender,
            lastTradingTs: priceTimestamp,
            reason: reason,
            proposalTs: block.timestamp,
            resolved: false
        });

        emit PostCessationProposalSubmitted(pair, assertionId, msg.sender, priceTimestamp, reason);
    }

    function settleTerminationProposal(bytes32 assertionId) external {
        // Settle on the OO the assertion was created against, not the factory's current `oo`.
        assertionOo[assertionId].settleAndGetAssertionResult(assertionId);
    }

    // -------------------- Direct termination (moved from BazaarPair) --------------------

    uint256 internal constant ORACLE_DEAD_THRESHOLD = 21 days;
    uint256 internal constant MAX_PRICE_STALENESS = 2 seconds;
    /// @notice Window after scheduledTs during which ONLY the precise historical price settles a
    ///         scheduled termination. After it elapses, terminateScheduledPair falls back to the
    ///         pair's last stored price if no valid in-window tick is supplied.
    uint256 internal constant SCHEDULED_TERMINATION_GRACE = 3 hours;

    event StalePairTerminated(address indexed pair, uint256 terminationPrice, uint256 oracleLastUpdateTs);

    /// @notice Emitted whenever a normal-termination path pins a pair's settlement price,
    ///         opening its terminal sweep window. Emitted here rather than in BazaarPair
    ///         (which sits at the EIP-170 ceiling); every fix path routes through this contract.
    ///         Keepers should sweep negative-equity positions via BazaarPair.liquidate (no
    ///         price update needed) and call BazaarPair.finalizeTermination after the window.
    event SettlementPriceFixed(address indexed pair, uint256 settlementPrice);

    /// @dev Single home for stage-1 fixes so every path emits the canonical event.
    function _fixSettlement(IBazaarPair p, address pair, uint256 price) internal {
        p.fixSettlementPrice(price);
        emit SettlementPriceFixed(pair, price);
    }

    /// @notice Stage 1 of a scheduled or post-cessation termination: pin the settlement price
    ///         as of the scheduled timestamp. Anyone can call this once scheduledTs has passed.
    ///         The settlement price is the Pyth tick in [scheduledTs - MAX_PRICE_STALENESS,
    ///         scheduledTs] supplied via priceUpdate and verified on-chain. Fixing the price
    ///         opens the pair's terminal sweep window (liquidations at the fixed price only);
    ///         after it elapses anyone may call BazaarPair.finalizeTermination to settle.
    /// @dev For the first SCHEDULED_TERMINATION_GRACE after the grace anchor — the LATER of
    ///      scheduledTs and UMA acceptance — that precise tick is the ONLY acceptable price: if it
    ///      isn't supplied the call reverts (no last-price fallback). This gives anyone who wants
    ///      the accurate price a window to post it, and crucially means bad/empty data can't be
    ///      used to force a fallback while a real tick may exist. Anchoring at acceptance matters
    ///      for post-cessation proposals, whose scheduledTs is already in the past at acceptance:
    ///      anchored at scheduledTs alone, the grace would be pre-elapsed and an immediate
    ///      empty-calldata call could settle at the last stored price instead of the true tick.
    ///
    ///      After the grace elapses, a valid in-window tick is still preferred, but if the precise
    ///      fetch reverts (no tick in the window, or no/invalid data supplied) the pair settles at
    ///      its last stored price instead — capped at scheduledTs, confidence-checked, and frozen
    ///      since matching is halted in limbo, so it's non-manipulable. This guarantees a scheduled
    ///      termination always completes rather than stranding the pair (and the funds backing its
    ///      open positions) indefinitely when the feed had no tick in the 2-second window (or the
    ///      archived tick's Wormhole guardian set has expired and can no longer verify on-chain).
    function terminateScheduledPair(address pair, bytes[] calldata priceUpdate) external payable nonReentrant {
        if (!_registeredPairs.contains(pair)) revert BazaarPairTerminator__PairNotRegistered();
        IBazaarPair p = IBazaarPair(pair);
        if (p.isPairTerminatedEmergency() || p.isPairTerminatedNormal() || p.settlementPriceFixedTs() != 0) {
            revert BazaarPairTerminator__AlreadyTerminated();
        }

        uint256 scheduledTs = p.scheduledTerminationTs();
        if (scheduledTs == 0) revert BazaarPairTerminator__NoScheduledTermination();
        if (block.timestamp <= scheduledTs) {
            revert BazaarPairTerminator__TerminationTimeNotReached(scheduledTs, block.timestamp);
        }

        BazaarOracle oracleContract = BazaarOracle(p.oracle());
        bytes32 feedId = p.baseFeedId();
        // Only query the fee when update data is supplied: getUpdateFee is a call into the Pyth
        // contract OUTSIDE the try/catch below, so an unconditional call would make even the
        // empty-calldata fallback path revert if the Pyth contract itself is bricked/migrated —
        // stranding the pair until the 21-day stale path instead of settling after the grace.
        uint256 fee = priceUpdate.length > 0 ? oracleContract.getUpdateFee(priceUpdate) : 0;
        uint256 refundAmount;

        uint256 acceptedTs = terminationAcceptedTs[pair];
        uint256 graceAnchor = scheduledTs > acceptedTs ? scheduledTs : acceptedTs;

        if (block.timestamp <= graceAnchor + SCHEDULED_TERMINATION_GRACE) {
            // Within grace: precise price only, revert on any failure.
            uint256 terminationPrice = oracleContract.fetchHistoricalPrice{value: fee}(
                feedId, priceUpdate, uint64(scheduledTs - MAX_PRICE_STALENESS), uint64(scheduledTs)
            );
            _fixSettlement(p, pair, terminationPrice);
            refundAmount = msg.value - fee;
        } else {
            // After grace: prefer precise, fall back to the last stored price on revert.
            try oracleContract.fetchHistoricalPrice{value: fee}(
                feedId, priceUpdate, uint64(scheduledTs - MAX_PRICE_STALENESS), uint64(scheduledTs)
            ) returns (
                uint256 terminationPrice
            ) {
                _fixSettlement(p, pair, terminationPrice);
                refundAmount = msg.value - fee;
            } catch {
                (uint256 lastPrice,,,,) = p.lastPairPrice();
                if (lastPrice == 0) revert BazaarPairTerminator__NoStoredPrice();
                _fixSettlement(p, pair, lastPrice);
                refundAmount = msg.value; // historical fetch reverted → no Pyth fee consumed
            }
        }

        if (refundAmount > 0) {
            (bool ok,) = payable(msg.sender).call{value: refundAmount}("");
            if (!ok) revert BazaarPairTerminator__EthRefundFailed();
        }
    }

    /// @notice Terminate a pair whose oracle has been stale for more than ORACLE_DEAD_THRESHOLD
    ///         (21 days). This is the ONLY condition under which this method terminates — staleness
    ///         is objective on-chain proof and needs no UMA proposal. It must never terminate for
    ///         any other reason (e.g. a transient oracle revert or non-positive price); for those,
    ///         use the UMA termination flow.
    /// @dev Anyone can call this.
    function terminateStalePair(address pair) external nonReentrant {
        if (!_registeredPairs.contains(pair)) revert BazaarPairTerminator__PairNotRegistered();
        IBazaarPair p = IBazaarPair(pair);
        if (p.isPairTerminatedEmergency() || p.isPairTerminatedNormal() || p.settlementPriceFixedTs() != 0) {
            revert BazaarPairTerminator__AlreadyTerminated();
        }

        BazaarOracle oracleContract = BazaarOracle(p.oracle());
        bytes32 feedId = p.baseFeedId();

        // Try the oracle first. tryReadStalePrice returns the latest confidence-cleared price
        // (spot when every leg is within the 2% cap, else the smoothed EMA) regardless of age.
        // It returns found=false when no rung clears the cap, and reverts only if the oracle
        // contract itself is dead/migrated. In both the "no confident price" and "revert" cases
        // we fall back to the pair's last stored price — but always still requiring 21-day
        // staleness, so this method can only ever terminate a genuinely dead oracle.
        try oracleContract.tryReadStalePrice(feedId) returns (
            bool found, uint256 spotPrice, uint256, uint256, uint256 publishTime
        ) {
            if (found) {
                if (block.timestamp - publishTime <= ORACLE_DEAD_THRESHOLD) {
                    revert BazaarPairTerminator__OracleNotStaleEnough(publishTime, ORACLE_DEAD_THRESHOLD);
                }
                emit StalePairTerminated(pair, spotPrice, publishTime);
                _fixSettlement(p, pair, spotPrice);
                return;
            }
            // No rung cleared the confidence cap → settle at the last stored price.
            _terminateAtLastStoredPrice(pair, p);
        } catch {
            // Oracle read reverted (dead/migrated Pyth contract). Same last-stored-price fallback.
            _terminateAtLastStoredPrice(pair, p);
        }
    }

    /// @dev Fallback termination at the pair's last stored (confidence-checked-when-recorded)
    ///      price, still gated on 21-day staleness using that price's recorded age. Shared by the
    ///      "no confident oracle rung" and "oracle read reverted" branches of terminateStalePair,
    ///      so a transient revert / wide-confidence read on a recently-active pair cannot be used
    ///      as a side door to terminate it.
    function _terminateAtLastStoredPrice(address pair, IBazaarPair p) private {
        (uint256 spotPrice,, uint256 updateTs,,) = p.lastPairPrice();
        if (spotPrice == 0) revert BazaarPairTerminator__NoStoredPrice();
        if (block.timestamp - updateTs <= ORACLE_DEAD_THRESHOLD) {
            revert BazaarPairTerminator__OracleNotStaleEnough(updateTs, ORACLE_DEAD_THRESHOLD);
        }
        emit StalePairTerminated(pair, spotPrice, 0);
        _fixSettlement(p, pair, spotPrice);
    }

    // -------------------- UMA Callbacks --------------------

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external override {
        // Auth against the OO this assertion was created on, so a callback from the original
        // oracle still authenticates after a factory oracle upgrade.
        if (msg.sender != address(assertionOo[assertionId])) revert BazaarPairTerminator__OnlyUmaOracle();
        _handleTerminationResolution(assertionId, assertedTruthfully);
    }

    function assertionDisputedCallback(bytes32 assertionId) external override {
        if (msg.sender != address(assertionOo[assertionId])) revert BazaarPairTerminator__OnlyUmaOracle();
        emit TerminationProposalDisputed(assertionId);
    }

    // -------------------- Internal --------------------

    /// @dev Shared by scheduled and post-cessation proposals — both resolve into "schedule the
    ///      pair at lastTradingTs" (for post-cessation that timestamp is already in the past, so
    ///      trading halts immediately). Settlement then happens in a separate, retryable
    ///      terminateScheduledPair transaction; nothing price-dependent runs inside this UMA
    ///      callback, so a bad proposal can't brick settlement and lock the bond (the H6 pattern).
    function _handleTerminationResolution(bytes32 assertionId, bool assertedTruthfully) internal {
        TerminationProposal storage proposal = terminationProposals[assertionId];
        if (proposal.proposer == address(0)) revert BazaarPairTerminator__UnknownAssertion();
        if (proposal.resolved) revert BazaarPairTerminator__AlreadyResolved();
        proposal.resolved = true;

        if (assertedTruthfully && acceptedTerminationAssertionId[proposal.pair] == bytes32(0)) {
            IBazaarPair p = IBazaarPair(proposal.pair);
            // scheduledTerminationTs != 0 means another path claimed the pair while this
            // assertion was live (an insurer-vote or stale-path fixSettlementPrice stamps it) —
            // setScheduledTermination would revert and brick the UMA settle + bond. Skip.
            if (!p.isPairTerminatedEmergency() && !p.isPairTerminatedNormal() && p.scheduledTerminationTs() == 0) {
                acceptedTerminationAssertionId[proposal.pair] = assertionId;
                terminationAcceptedTs[proposal.pair] = block.timestamp;
                p.setScheduledTermination(proposal.lastTradingTs, proposal.proposer);
                emit TerminationProposalAccepted(proposal.pair, assertionId, proposal.lastTradingTs);
            }
        }
    }

    // ========================================================
    //  Insurer-vote pair termination (no UMA, on-chain consensus)
    // ========================================================

    uint256 internal constant INSURER_TERMINATION_VOTING_PERIOD = 7 days;
    uint256 internal constant INSURER_TERMINATION_EXECUTION_WINDOW = 7 days;
    uint256 internal constant INSURER_TERMINATION_PROPOSAL_COOLDOWN = 14 days;
    uint256 internal constant INSURER_TERMINATION_THRESHOLD_BP = 6_000; // 60%
    uint256 internal constant INSURER_TERMINATION_BOND_USDC = 500 * 1e6; // 500 USDC
    uint256 internal constant BP_SCALE_INSURER = BazaarTypes.BP_SCALE;
    /// @notice Shares must be held for this duration before they can vote on an insurer
    ///         termination proposal. Prevents "deposit then snipe" attacks where an attacker
    ///         acquires majority and proposes in the same window.
    uint256 internal constant INSURER_SHARE_MATURITY_PERIOD = 7 days;

    struct InsurerTerminationProposal {
        address proposer;
        uint64 proposalTs; // when the proposal was made
        uint64 votingEndTs; // proposalTs + VOTING_PERIOD
        uint64 windowEndTs; // votingEndTs + EXECUTION_WINDOW
        uint256 yesShares; // sum of locked yes-voted shares
        uint256 snapshotTotalShares; // totalInsuranceShares at proposalTs — frozen denominator
        bool resolved; // true after execute (success or fail)
        bool executed; // true if termination actually fired
    }

    struct UserLock {
        uint64 proposalTs; // matches the proposal this lock is for
        uint256 amount; // shares locked
    }

    mapping(address => InsurerTerminationProposal) public insurerProposals;
    mapping(address => mapping(address => UserLock)) public userLocks;

    event InsurerTerminationProposed(
        address indexed pair, address indexed proposer, uint64 proposalTs, uint64 votingEndTs, uint64 windowEndTs
    );
    event InsurerTerminationVoted(address indexed pair, address indexed voter, uint256 amount, uint256 totalYesShares);
    event InsurerTerminationExecuted(
        address indexed pair, uint256 yesShares, uint256 totalShares, uint256 settlementPrice
    );
    event InsurerTerminationFailed(address indexed pair, uint256 yesShares, uint256 totalShares);
    event InsurerTerminationBondRefundFailed(address indexed pair, address indexed proposer, uint256 amount);
    /// @notice Emitted when an insurer-termination proposal is resolved because the pair was
    ///         already terminated by another path during the window. The bond is refunded to the
    ///         proposer (not forfeited) and the pair is not re-terminated.
    event InsurerTerminationPreempted(address indexed pair, address indexed proposer);

    error BazaarPairTerminator__InsurerActiveProposal();
    error BazaarPairTerminator__InsurerCooldownActive(uint256 nextProposalTs);
    error BazaarPairTerminator__InsurerNoShares();
    error BazaarPairTerminator__InsurerNoActiveProposal();
    error BazaarPairTerminator__InsurerVotingClosed();
    error BazaarPairTerminator__InsurerExecutionTooEarly(uint64 votingEndTs);
    error BazaarPairTerminator__InsurerInsufficientUnlockedShares(uint256 unlocked, uint256 requested);
    error BazaarPairTerminator__InsurerZeroVoteAmount();

    /// @notice Anyone holding insurance shares can propose to terminate the pair.
    ///         Requires a 500 USDC bond (returned on success, forfeited to insurance on fail).
    ///         A 14-day cooldown applies after each proposal, regardless of outcome.
    function proposeInsurerTermination(address pair) external nonReentrant {
        if (!_registeredPairs.contains(pair)) revert BazaarPairTerminator__PairNotRegistered();
        IBazaarPair p = IBazaarPair(pair);
        if (p.isPairTerminatedEmergency() || p.isPairTerminatedNormal() || p.settlementPriceFixedTs() != 0) {
            revert BazaarPairTerminator__AlreadyTerminated();
        }

        InsurerTerminationProposal storage prop = insurerProposals[pair];

        // Reject if there's an existing active proposal still within its window
        if (prop.proposalTs != 0 && !prop.resolved && block.timestamp <= prop.windowEndTs) {
            revert BazaarPairTerminator__InsurerActiveProposal();
        }

        // Cooldown: 14 days from previous proposal's proposalTs (regardless of outcome)
        if (prop.proposalTs != 0 && block.timestamp < uint256(prop.proposalTs) + INSURER_TERMINATION_PROPOSAL_COOLDOWN)
        {
            revert BazaarPairTerminator__InsurerCooldownActive(uint256(prop.proposalTs)
                    + INSURER_TERMINATION_PROPOSAL_COOLDOWN);
        }

        // Proposer must hold at least one insurance share for this pair
        if (p.insuranceShares(msg.sender) == 0) revert BazaarPairTerminator__InsurerNoShares();

        // A prior proposal that expired without anyone calling executeInsurerTermination still
        // holds its bond, and the overwrite below would discard the only reference to it —
        // stranding the USDC in this contract forever. Settle it first with the same threshold
        // outcome execute would have applied. The pair is known not-terminated here (checked
        // above), so execute's preempted branch cannot apply.
        if (prop.proposalTs != 0 && !prop.resolved) {
            _settleExpiredInsurerProposal(pair, prop);
        }

        // Take the bond
        IERC20Minimal bondToken = _bondToken();
        IERC20(address(bondToken)).safeTransferFrom(msg.sender, address(this), INSURER_TERMINATION_BOND_USDC);

        uint64 ts = uint64(block.timestamp);
        uint64 votingEnd = ts + uint64(INSURER_TERMINATION_VOTING_PERIOD);
        uint64 windowEnd = votingEnd + uint64(INSURER_TERMINATION_EXECUTION_WINDOW);

        // Snapshot totalShares — frozen denominator for the 60% threshold so subsequent
        // deposits can't dilute it. Excludes the permanently locked orphan shares at
        // address(0) (minted by InsuranceVaultLib when recapitalizing an LP-less fund):
        // they can never vote, so counting them could deadlock the threshold.
        prop.proposer = msg.sender;
        prop.proposalTs = ts;
        prop.votingEndTs = votingEnd;
        prop.windowEndTs = windowEnd;
        prop.yesShares = 0;
        prop.snapshotTotalShares = p.totalInsuranceShares() - p.insuranceShares(address(0));
        prop.resolved = false;
        prop.executed = false;

        emit InsurerTerminationProposed(pair, msg.sender, ts, votingEnd, windowEnd);
    }

    /// @notice Vote yes on the active proposal by locking N shares.
    ///         Locked shares cannot be withdrawn from the insurance fund until the
    ///         proposal is resolved or its execution window expires (auto-unlock).
    function voteForInsurerTermination(address pair, uint256 amount) external nonReentrant {
        if (amount == 0) revert BazaarPairTerminator__InsurerZeroVoteAmount();
        InsurerTerminationProposal storage prop = insurerProposals[pair];
        if (prop.proposalTs == 0 || prop.resolved) revert BazaarPairTerminator__InsurerNoActiveProposal();
        if (block.timestamp >= prop.votingEndTs) revert BazaarPairTerminator__InsurerVotingClosed();

        UserLock storage lock = userLocks[pair][msg.sender];

        // If the user has a stale lock from a prior proposal, reset it now.
        // (Stale locks are functionally already 0 via getLockedShares, but we need
        // an accurate on-chain value before adding this round's vote.)
        if (lock.proposalTs != prop.proposalTs) {
            lock.proposalTs = prop.proposalTs;
            lock.amount = 0;
        }

        // Eligible voting shares = the user's currently-held shares that have been mature
        // for at least INSURER_SHARE_MATURITY_PERIOD as of the proposal timestamp. Fresh
        // deposits made within the maturity window before (or after) the proposal don't vote.
        uint64 cutoffTs = prop.proposalTs > uint64(INSURER_SHARE_MATURITY_PERIOD)
            ? prop.proposalTs - uint64(INSURER_SHARE_MATURITY_PERIOD)
            : 0;
        uint256 eligibleShares = IBazaarPair(pair).getSharesAsOf(msg.sender, cutoffTs);
        uint256 unlocked = eligibleShares > lock.amount ? eligibleShares - lock.amount : 0;
        if (amount > unlocked) {
            revert BazaarPairTerminator__InsurerInsufficientUnlockedShares(unlocked, amount);
        }

        lock.amount += amount;
        prop.yesShares += amount;

        emit InsurerTerminationVoted(pair, msg.sender, amount, prop.yesShares);
    }

    /// @notice Execute the proposal.
    ///         - If threshold met AND within execution window → terminate pair at fresh oracle price,
    ///           refund bond to proposer. Caller must supply a Pyth priceUpdate ≤ MAX_PRICE_STALENESS.
    ///         - If threshold met BUT window expired → bond refunded to proposer (consensus succeeded
    ///           on-chain), but pair not terminated. priceUpdate is unused; msg.value fully refunded.
    ///         - If threshold NOT met → bond forfeited to pair's insurance fund. priceUpdate unused.
    function executeInsurerTermination(address pair, bytes[] calldata priceUpdate) external payable nonReentrant {
        InsurerTerminationProposal storage prop = insurerProposals[pair];
        if (prop.proposalTs == 0 || prop.resolved) revert BazaarPairTerminator__InsurerNoActiveProposal();
        if (block.timestamp < prop.votingEndTs) {
            revert BazaarPairTerminator__InsurerExecutionTooEarly(prop.votingEndTs);
        }

        IBazaarPair p = IBazaarPair(pair);

        // If the pair was already terminated by another path (autonomous emergency termination,
        // UMA scheduled/post-cessation, or stale termination) during this proposal's window, the
        // proposal is moot — but the bond must still be released here. This is the ONLY function
        // that releases it, and proposeInsurerTermination reverts on an already-terminated pair,
        // so reverting would strand the bond permanently. Resolve the proposal and refund the
        // proposer (their concern was validated by the pair actually terminating) without
        // attempting to terminate again. Unconditional refund, not the threshold logic: the
        // proposal can't be deemed frivolous when the pair did in fact need terminating, and an
        // emergency termination can't be faked (the vault must genuinely be insolvent).
        // A fixed settlement price counts as preempted too: fixSettlementPrice would revert
        // (SettlementAlreadyFixed), and this branch is the only bond release.
        if (p.isPairTerminatedEmergency() || p.isPairTerminatedNormal() || p.settlementPriceFixedTs() != 0) {
            prop.resolved = true;
            _releaseInsurerBond(pair, prop.proposer, true);
            emit InsurerTerminationPreempted(pair, prop.proposer);
            if (msg.value > 0) {
                (bool ok,) = payable(msg.sender).call{value: msg.value}("");
                if (!ok) revert BazaarPairTerminator__EthRefundFailed();
            }
            return;
        }

        prop.resolved = true;

        bool windowExpired = block.timestamp > prop.windowEndTs;
        uint256 totalShares = prop.snapshotTotalShares; // frozen at proposal time
        bool thresholdMet = _insurerThresholdMet(prop);

        // Successful consensus → bond back to proposer; failure → forfeit to insurance.
        _releaseInsurerBond(pair, prop.proposer, thresholdMet);

        uint256 ethRefund = msg.value;

        if (thresholdMet && !windowExpired) {
            // Success: fix the settlement price at a fresh oracle tick (≤ MAX_PRICE_STALENESS
            // old), opening the pair's terminal sweep window; anyone finalizes after it elapses.
            // Reverts if priceUpdate is missing/stale or msg.value insufficient for Pyth fee.
            prop.executed = true;
            BazaarOracle oracleContract = BazaarOracle(p.oracle());
            uint256 fee = oracleContract.getUpdateFee(priceUpdate);
            if (msg.value < fee) revert BazaarPairTerminator__InsufficientPythFee(msg.value, fee);
            (uint256 settlementPrice,,,) =
                oracleContract.updateAndFetchPrice{value: fee}(p.baseFeedId(), priceUpdate, MAX_PRICE_STALENESS);
            ethRefund = msg.value - fee;
            _fixSettlement(p, pair, settlementPrice);
            emit InsurerTerminationExecuted(pair, prop.yesShares, totalShares, settlementPrice);
        } else {
            // Either insufficient consensus or expired-after-consensus — pair NOT terminated.
            emit InsurerTerminationFailed(pair, prop.yesShares, totalShares);
        }

        if (ethRefund > 0) {
            (bool ok,) = payable(msg.sender).call{value: ethRefund}("");
            if (!ok) revert BazaarPairTerminator__EthRefundFailed();
        }
    }

    /// @dev True when the proposal's yes-voted shares meet the 60% threshold of the snapshot
    ///      denominator frozen at proposal time.
    function _insurerThresholdMet(InsurerTerminationProposal storage prop) internal view returns (bool) {
        uint256 totalShares = prop.snapshotTotalShares;
        return totalShares > 0 && prop.yesShares >= totalShares * INSURER_TERMINATION_THRESHOLD_BP / BP_SCALE_INSURER;
    }

    /// @dev Single home for releasing the insurer-termination bond, shared by every resolution
    ///      path (execute, preempted, lazy settlement on overwrite). `refundProposer` = true
    ///      refunds the proposer, soft-failing into the insurance route if they can't receive
    ///      USDC (e.g., blacklisted) — resolution must never be blockable by an unreachable
    ///      refund target. Otherwise (or on that soft-fail) the bond is transferred to the pair
    ///      and credited to its insurance bookkeeping so the fund stays fully backed.
    function _releaseInsurerBond(address pair, address proposer, bool refundProposer) internal {
        if (refundProposer && _tryRefundBond(proposer, INSURER_TERMINATION_BOND_USDC)) return;

        IERC20(address(_bondToken())).safeTransfer(pair, INSURER_TERMINATION_BOND_USDC);
        uint256 bondBazaar = INSURER_TERMINATION_BOND_USDC * (BazaarTypes.BAZAAR_SCALE / 1e6);
        IBazaarPair(pair).creditInsuranceFromTerminator(bondBazaar);
        if (refundProposer) {
            emit InsurerTerminationBondRefundFailed(pair, proposer, INSURER_TERMINATION_BOND_USDC);
        }
    }

    /// @dev Settles a proposal whose execution window expired with nobody calling
    ///      executeInsurerTermination, applying the same threshold outcome execute would have:
    ///      consensus reached → refund the proposer, otherwise forfeit to the pair's insurance
    ///      fund. Called from proposeInsurerTermination right before the struct is overwritten,
    ///      so an unresolved bond can never be orphaned by a new proposal. Never terminates the
    ///      pair — the execution window is over by construction.
    function _settleExpiredInsurerProposal(address pair, InsurerTerminationProposal storage prop) internal {
        prop.resolved = true;
        _releaseInsurerBond(pair, prop.proposer, _insurerThresholdMet(prop));
        emit InsurerTerminationFailed(pair, prop.yesShares, prop.snapshotTotalShares);
    }

    /// @dev Soft-fail USDC transfer. Returns false instead of reverting when the recipient
    ///      can't receive (e.g., USDC blacklist). Mirrors BazaarPair._trySendUsdcReward
    ///      but operates on raw USDC units (no BAZAAR→USDC conversion).
    function _tryRefundBond(address to, uint256 amount) internal returns (bool) {
        if (to == address(0) || amount == 0) return false;
        (bool callOk, bytes memory data) =
            address(_bondToken()).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!callOk) return false;
        if (data.length == 0) return true; // non-compliant token that returns nothing
        return abi.decode(data, (bool));
    }

    /// @notice Returns the user's locked shares for the active proposal on this pair.
    ///         Auto-unlocks (returns 0) when the proposal is resolved, expired,
    ///         or the user's lock is stale (from a prior proposal).
    function getLockedShares(address pair, address user) external view returns (uint256) {
        InsurerTerminationProposal storage prop = insurerProposals[pair];
        if (prop.proposalTs == 0 || prop.resolved) return 0;
        if (block.timestamp > prop.windowEndTs) return 0;

        UserLock storage lock = userLocks[pair][user];
        if (lock.proposalTs != prop.proposalTs) return 0;

        return lock.amount;
    }
}
