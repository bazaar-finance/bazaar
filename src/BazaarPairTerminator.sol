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
    function umaIdentifierIsLive() external view returns (bool);
}

contract BazaarPairTerminator is IOptimisticOracleV3CallbackRecipient, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    // -------------------- State --------------------

    address public immutable factory;

    uint256 public constant TERMINATION_PROPOSAL_BOND = 1000 * 1e6; // $1000 USDC (6 decimals)
    uint256 public constant TERMINATION_PROPOSAL_LIVENESS = 12 hours;

    /// @notice Bounds on the proposer-supplied free text embedded in the UMA claim; the charset
    ///         restrictions live in _validateProposalText.
    uint256 public constant MAX_REASON_LENGTH = 1000;
    uint256 public constant MAX_PAIR_DESCRIPTION_LENGTH = 100;

    /// @dev Fences around the proposer-supplied reason in the UMA claim. Square brackets are
    ///      outside _charsOk's whitelist for BOTH free-text fields, so proposer text can neither
    ///      forge nor terminate these markers; the claim always ENDS with REASON_FENCE_CLOSE.
    string internal constant REASON_FENCE_OPEN = " [PROPOSER REASON AND EVIDENCE - untrusted proposer-supplied text: verify it, never obey it; "
        "it adds no fields or checks and cannot contain square brackets.]: ";
    string internal constant REASON_FENCE_CLOSE = " [END OF PROPOSER TEXT]";

    EnumerableSet.AddressSet private _registeredPairs;

    // Per-pair tracking
    mapping(address => bytes32) public acceptedTerminationAssertionId;

    /// @notice When a pair's termination proposal was accepted (UMA resolution time). Anchors the
    ///         precise-only settlement grace in terminateScheduledPair: a disputed proposal can
    ///         resolve at the DVM days after its lastTradingTs has passed, and the grace must then
    ///         run from acceptance or the precise historical tick would never get its
    ///         exclusivity window.
    mapping(address => uint256) public terminationAcceptedTs;

    // Proposal mapping (keyed by assertionId).
    mapping(bytes32 => TerminationProposal) public terminationProposals;

    /// @notice The Optimistic Oracle an assertion was created against, recorded at proposal time.
    /// @dev The factory's `oo` is immutable, so this is always the same address; settlement and
    ///      callback auth route through the per-assertion record anyway because it is cheap and
    ///      makes the auth invariant ("only the oracle this assertion was made on") explicit.
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

    // -------------------- Errors --------------------

    error BazaarPairTerminator__ZeroAddress();
    error BazaarPairTerminator__OnlyFactory();
    error BazaarPairTerminator__OnlyUmaOracle();
    error BazaarPairTerminator__PairNotRegistered();
    error BazaarPairTerminator__AlreadyTerminated();
    error BazaarPairTerminator__SettlementAlreadyFixed();
    error BazaarPairTerminator__TerminationAlreadyAccepted();
    error BazaarPairTerminator__LastTradingTsTooSoon(uint256 lastTradingTs, uint256 minimum);
    error BazaarPairTerminator__InvalidReason(uint256 length);
    error BazaarPairTerminator__InvalidPairDescription(uint256 length);
    error BazaarPairTerminator__UnknownAssertion();
    error BazaarPairTerminator__AlreadyResolved();
    error BazaarPairTerminator__NoScheduledTermination();
    error BazaarPairTerminator__TerminationTimeNotReached(uint256 scheduledTs, uint256 currentTs);
    error BazaarPairTerminator__OracleNotStaleEnough(uint256 lastUpdate, uint256 threshold);
    error BazaarPairTerminator__NoStoredPrice();
    error BazaarPairTerminator__InsufficientPythFee(uint256 provided, uint256 required);
    error BazaarPairTerminator__EthRefundFailed();
    error BazaarPairTerminator__UmaIdentifierNotLive();

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

    /// @notice USDC a termination proposal must post as its UMA bond.
    /// @dev TERMINATION_PROPOSAL_BOND is a floor, not the figure. UMA derives its own minimum from
    ///      the final fee — an owner-settable parameter — so a bond pinned below it would make
    ///      `assertTruth` revert with "Bond amount too low" and close the UMA termination path with
    ///      no on-chain recovery. Taking the max tracks UMA upward while keeping the floor for spam
    ///      resistance and for the cold-cache case, where OOv3 reports a minimum of 0. Quote this
    ///      before approving: the amount is not a constant.
    function requiredTerminationBond() public view returns (uint256) {
        uint256 umaMin = _oo().getMinimumBond(address(_bondToken()));
        return umaMin > TERMINATION_PROPOSAL_BOND ? umaMin : TERMINATION_PROPOSAL_BOND;
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

    /// @dev Bounds and sanitizes the free-text fields embedded in the UMA claim. Both fields
    ///      are restricted to conservative ASCII subsets (same rationale as
    ///      BazaarFactory._isValidDescription: crafted text must not escape a delimiter, imitate
    ///      the claim's "Field: value" syntax, open a fake numbered check, or smuggle
    ///      invisible/homoglyph text past the humans who verify these claims):
    ///      - pairDescription: letters, digits, space, and . , & / -
    ///      - reason: the same set plus : ? = # % _ ~ + so evidence URLs survive. The colon this
    ///        re-admits is defused structurally, not lexically: the reason is spliced as the
    ///        claim's clearly labeled FINAL section, between square-bracket fences the charset
    ///        makes unforgeable, after every contract-authored field and instruction block.
    function _validateProposalText(string calldata reason, string calldata pairDescription) internal pure {
        uint256 reasonLen = bytes(reason).length;
        if (reasonLen == 0 || reasonLen > MAX_REASON_LENGTH || !_charsOk(bytes(reason), true)) {
            revert BazaarPairTerminator__InvalidReason(reasonLen);
        }
        uint256 descriptionLen = bytes(pairDescription).length;
        if (
            descriptionLen == 0 || descriptionLen > MAX_PAIR_DESCRIPTION_LENGTH
                || !_charsOk(bytes(pairDescription), false)
        ) {
            revert BazaarPairTerminator__InvalidPairDescription(descriptionLen);
        }
    }

    /// @dev Charset whitelists as 256-bit bitmaps (bit N set = byte value N allowed), folded at
    ///      compile time; one shift+mask per byte keeps the check small.
    ///      Base set (both fields): letters, digits, space, and . , & / -
    ///      The reason field additionally gets the URL set : ? = # % _ ~ +
    uint256 internal constant TEXT_CHARS_BASE = ((2 ** 26 - 1) << 97) // a-z
        | ((2 ** 26 - 1) << 65) // A-Z
        | ((2 ** 10 - 1) << 48) // 0-9
        | (1 << 32) | (1 << 46) | (1 << 44) | (1 << 38) | (1 << 47) | (1 << 45); // space . , & / -
    uint256 internal constant TEXT_CHARS_REASON = TEXT_CHARS_BASE | (1 << 58) | (1 << 63) | (1 << 61) | (1 << 35)
        | (1 << 37) | (1 << 95) | (1 << 126) | (1 << 43); // : ? = # % _ ~ +

    function _charsOk(bytes calldata s, bool allowUrlChars) internal pure returns (bool) {
        uint256 mask = allowUrlChars ? TEXT_CHARS_REASON : TEXT_CHARS_BASE;
        for (uint256 i = 0; i < s.length; i++) {
            // Bytes >= 128 (every non-ASCII lead/continuation byte) shift into the bitmap's
            // always-zero upper region, so they are rejected by the same test.
            if ((mask >> uint8(s[i])) & 1 == 0) return false;
        }
        return true;
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
        if (p.isPairTerminated()) revert BazaarPairTerminator__AlreadyTerminated();
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

        // Fail closed while the protocol's identifier is off UMA's live whitelist — an assertion
        // made now would be undisputable (auto-TRUE after liveness), and termination proposals
        // pin settlement semantics. Non-UMA termination paths (insurer vote, stale price,
        // insolvency) remain available; this path resumes after the identifier upgrade.
        if (!IBazaarFactory(factory).umaIdentifierIsLive()) revert BazaarPairTerminator__UmaIdentifierNotLive();

        IOptimisticOracleV3 oo = _oo();
        IERC20Minimal bondToken = _bondToken();

        uint256 bondUsdc = requiredTerminationBond();
        IERC20(address(bondToken)).safeTransferFrom(msg.sender, address(this), bondUsdc);
        IERC20(address(bondToken)).forceApprove(address(oo), bondUsdc);

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
                "."
            ),
            abi.encodePacked(
                " VALID TERMINATION REASONS (proposal must match exactly one): "
                "(1) ORACLE DECOMMISSION: The Pyth feed(s) listed above have ceased publishing updates, are scheduled to be decommissioned, or will cease publishing updates. For a composite (two-leg) feed, decommissioning of EITHER leg - the base leg or the quote/FX leg - is sufficient grounds, since the pair cannot be priced in USD without both legs. "
                "(2) ASSET CESSATION: The underlying asset has been or will be delisted from the exchange tracked by the oracle feed, rendering the feed invalid (even if the asset continues trading OTC). Includes: exchange delisting, merger/acquisition (cash or stock conversion), bankruptcy, or indefinite regulatory halt. "
                "(3) STRUCTURAL CHANGE: The asset or index will undergo a corporate, administrative, or methodological event that makes its price series discontinuous - the price published after the event is not comparable to the price before it. "
                "Examples (non-exhaustive): splits, reverse splits, spinoffs, rights offerings, special dividends or other one-time distributions exceeding 5% of the asset's price, "
                "token redenominations or migrations, index re-basings or methodology changes to the published level, and redenomination of the quote currency of a composite pair. "
                "NOT valid: regular cash dividends, and market-driven price moves of ANY expected size (e.g., earnings, court rulings, regulatory news, macroeconomic events) - anticipated volatility is tradeable risk, not a structural discontinuity. "
                "(4) PYTH CONTRACT MIGRATION: The Pyth oracle contract at the address listed above has been deprecated or is migrating to a new contract address, rendering the pair unable to fetch prices."
            ),
            abi.encodePacked(
                " HOW TO VALIDATE: "
                "Uma should verify the proposer's evidence (the bracket-fenced final section) by checking official sources: "
                "(1) For oracle issues, check the Pyth Network status page and feed registry for the feed IDs listed above. "
                "(2) For asset cessation, verify with official exchange notices or regulatory filings. "
                "(3) For structural changes, verify with the company's investor relations page, the index provider's or token project's official announcements, exchange bulletins, or regulatory filings. "
                "(4) For Pyth contract migration, verify via Pyth Network official announcements that the oracle contract is being deprecated or migrated. "
                "(5) Confirm the proposed last trading timestamp is reasonable: it should be at or right before the last moment the asset can trade under existing (pre-event) conditions, but not unnecessarily early. "
                "If the event has already occurred, the earliest timestamp the contract accepts (12 hours after submission) is the reasonable choice; the pair then settles at the Pyth price update published within the 2 seconds at or before that timestamp, or at its own last stored price if no such update exists. "
                "Assertion is INVALID if: the reason does not match any category above, evidence is fabricated or unverifiable, or the timestamp is unreasonable. "
            ),
            abi.encodePacked(REASON_FENCE_OPEN, reason, REASON_FENCE_CLOSE)
        );

        assertionId = oo.assertTruth(
            claim,
            msg.sender,
            address(this),
            address(0),
            uint64(TERMINATION_PROPOSAL_LIVENESS),
            bondToken,
            bondUsdc,
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

    function settleTerminationProposal(bytes32 assertionId) external {
        // Settle on the OO recorded for this assertion at proposal time.
        assertionOo[assertionId].settleAndGetAssertionResult(assertionId);
    }

    // -------------------- Direct termination --------------------

    uint256 internal constant ORACLE_DEAD_THRESHOLD = 21 days;
    uint256 internal constant MAX_PRICE_STALENESS = 2 seconds;
    /// @notice Window after the grace anchor — the later of scheduledTs and UMA acceptance —
    ///         during which ONLY the precise historical price settles a scheduled termination.
    ///         After it elapses, terminateScheduledPair falls back to the pair's last stored price
    ///         if no valid in-window tick is supplied.
    /// @dev Sized to match TERMINATION_PROPOSAL_LIVENESS, because the two answer the same
    ///      question: how long an interested party needs to notice a termination and act on it.
    ///      The window has to carry that whole burden on its own, since the incentives run the
    ///      wrong way — posting the precise tick costs gas plus the Pyth fee and pays nothing,
    ///      while waiting the window out and calling with empty calldata costs only gas. So the
    ///      side the stale-price fallback happens to favor has the strictly cheaper action, and
    ///      this window is the only thing giving the other side room to answer. It cannot simply
    ///      be made long, though: limbo freezes withdrawals, matching and liquidation until the
    ///      price is fixed, so the ceiling is how long the book can sit frozen, not how long an
    ///      inattentive keeper might take. Supplying the tick ends limbo immediately at any point
    ///      after the cutoff, so the length only ever delays the fallback — never the accurate
    ///      settlement it exists to protect.
    uint256 internal constant SCHEDULED_TERMINATION_GRACE = 12 hours;

    event StalePairTerminated(address indexed pair, uint256 terminationPrice, uint256 oracleLastUpdateTs);

    /// @notice Emitted whenever a normal-termination path pins a pair's settlement price, opening
    ///         its terminal sweep window. Declared here rather than in BazaarPair — every fix path
    ///         routes through this contract, so the pair's EIP-170 budget stays free of it.
    ///         Keepers should sweep negative-equity positions via BazaarPair.liquidate (no price
    ///         update needed) and call BazaarPair.finalizeTermination after the window.
    event SettlementPriceFixed(address indexed pair, uint256 settlementPrice);

    /// @dev Single home for stage-1 fixes so every path emits the canonical event.
    function _fixSettlement(IBazaarPair p, address pair, uint256 price) internal {
        p.fixSettlementPrice(price);
        emit SettlementPriceFixed(pair, price);
    }

    /// @notice Stage 1 of a scheduled termination: pin the settlement price as of the scheduled
    ///         timestamp. Anyone can call this once scheduledTs has passed. The settlement price
    ///         is the Pyth tick in [scheduledTs - MAX_PRICE_STALENESS, scheduledTs] supplied via
    ///         priceUpdate and verified on-chain. Fixing the price opens the pair's terminal
    ///         sweep window (liquidations at the fixed price only); after it elapses anyone may
    ///         call BazaarPair.finalizeTermination to settle.
    /// @dev For the first SCHEDULED_TERMINATION_GRACE after the grace anchor — the LATER of
    ///      scheduledTs and UMA acceptance — that precise tick is the ONLY acceptable price: if it
    ///      isn't supplied the call reverts (no last-price fallback). This gives anyone who wants
    ///      the accurate price a window to post it, and crucially means bad/empty data can't be
    ///      used to force a fallback while a real tick may exist. Anchoring at acceptance matters
    ///      when a disputed proposal resolves late: lastTradingTs may sit only the 12-hour
    ///      liveness out while the DVM takes days, so scheduledTs can already be past at
    ///      acceptance — anchored at scheduledTs alone, the grace would be pre-elapsed and an
    ///      immediate empty-calldata call could settle at the last stored price instead of the
    ///      true tick.
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
        if (p.settlementPriceFixedTs() != 0) {
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
        if (p.settlementPriceFixedTs() != 0) {
            revert BazaarPairTerminator__AlreadyTerminated();
        }

        BazaarOracle oracleContract = BazaarOracle(p.oracle());
        bytes32 feedId = p.baseFeedId();

        // The oracle read is a liveness probe, not a price source. tryReadStalePrice returns the
        // latest confidence-cleared tick (spot when every leg is within the 2% cap, else the
        // smoothed EMA) regardless of age; it returns found=false when no rung clears the cap, and
        // reverts only if the oracle contract itself is dead/migrated. Its publishTime is the
        // strictest available proof that the feed is dead, because Pyth's cache can never be older
        // than the pair's own stored price — recording one requires reading a fresh tick through
        // Pyth first. Any tick newer than ORACLE_DEAD_THRESHOLD therefore blocks termination
        // outright, so this method can only ever terminate a genuinely dead oracle.
        //
        // Settlement itself always uses the pair's last stored price. Pyth's cache is
        // permissionlessly writable to any published tick, so settling at it would let whoever
        // calls this pick the book-wide settlement price out of the ticks published before the
        // feed went quiet. lastPairPrice can only ever hold a mark that cleared both the freshness
        // gate and the confidence cap at the moment it was recorded.
        try oracleContract.tryReadStalePrice(feedId) returns (
            bool found, uint256, uint256, uint256, uint256 publishTime
        ) {
            if (found && block.timestamp - publishTime <= ORACLE_DEAD_THRESHOLD) {
                revert BazaarPairTerminator__OracleNotStaleEnough(publishTime, ORACLE_DEAD_THRESHOLD);
            }
            _terminateAtLastStoredPrice(pair, p);
        } catch {
            // Oracle read reverted (dead/migrated Pyth contract). Same stored-price settlement.
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

    /// @dev An accepted proposal only schedules the pair at lastTradingTs (already past when a
    ///      disputed assertion resolves late, in which case trading halts at once). Settlement
    ///      then happens in a separate, retryable terminateScheduledPair transaction; nothing
    ///      price-dependent runs inside this UMA callback, so a bad proposal cannot revert it,
    ///      brick settlement, and lock the bond.
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
            if (p.scheduledTerminationTs() == 0) {
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
    error BazaarPairTerminator__InsurerNoMatureShares();
    error BazaarPairTerminator__InsurerNoActiveProposal();
    error BazaarPairTerminator__InsurerVotingClosed();
    error BazaarPairTerminator__InsurerExecutionTooEarly(uint64 votingEndTs);
    error BazaarPairTerminator__InsurerInsufficientUnlockedShares(uint256 unlocked, uint256 requested);
    error BazaarPairTerminator__InsurerZeroVoteAmount();

    /// @notice Any insurer whose shares are mature enough to vote on the proposal can propose to
    ///         terminate the pair. Requires a 500 USDC bond (returned on success, forfeited to
    ///         insurance on fail). A 14-day cooldown applies after each proposal, regardless of
    ///         outcome.
    function proposeInsurerTermination(address pair) external nonReentrant {
        if (!_registeredPairs.contains(pair)) revert BazaarPairTerminator__PairNotRegistered();
        IBazaarPair p = IBazaarPair(pair);
        if (p.settlementPriceFixedTs() != 0) {
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

        // The proposer is held to the same maturity cutoff the vote applies to this proposal:
        // shares younger than INSURER_SHARE_MATURITY_PERIOD can neither vote nor open the vote.
        // Without this an immature holder could file a proposal no share of theirs can support
        // and start the 14-day proposal cooldown on it.
        uint64 ts = uint64(block.timestamp);
        if (p.getSharesAsOf(msg.sender, _insurerMaturityCutoff(ts)) == 0) {
            revert BazaarPairTerminator__InsurerNoMatureShares();
        }

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
        uint256 eligibleShares = IBazaarPair(pair).getSharesAsOf(msg.sender, _insurerMaturityCutoff(prop.proposalTs));
        uint256 unlocked = eligibleShares > lock.amount ? eligibleShares - lock.amount : 0;
        if (amount > unlocked) {
            revert BazaarPairTerminator__InsurerInsufficientUnlockedShares(unlocked, amount);
        }

        lock.amount += amount;
        prop.yesShares += amount;

        emit InsurerTerminationVoted(pair, msg.sender, amount, prop.yesShares);
    }

    /// @dev Maturity cutoff for a proposal filed at `proposalTs`: shares deposited at or before it
    ///      are eligible, younger ones are not. Shared by propose and vote so the proposer is held
    ///      to exactly the rule their proposal's voters are.
    function _insurerMaturityCutoff(uint64 proposalTs) internal pure returns (uint64) {
        return
            proposalTs > uint64(INSURER_SHARE_MATURITY_PERIOD) ? proposalTs - uint64(INSURER_SHARE_MATURITY_PERIOD) : 0;
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

        // If another path (autonomous insolvency, UMA scheduled, or stale termination) fixed
        // the pair's settlement price during this proposal's window, the
        // proposal is moot — but the bond must still be released here. This is the ONLY function
        // that releases it, and proposeInsurerTermination reverts on a claimed pair, so reverting
        // would strand the bond permanently. Resolve the proposal and refund the proposer (their
        // concern was validated by the pair actually winding down) without attempting to
        // terminate again. Unconditional refund, not the threshold logic: the proposal can't be
        // deemed frivolous when the pair did in fact need terminating, and an autonomous
        // insolvency termination can't be faked (the vault must genuinely be insolvent). Every
        // path fixes the price first, so the latch is the whole check: fixSettlementPrice would
        // revert on the pair, and this branch is the only bond release.
        if (p.settlementPriceFixedTs() != 0) {
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
        IBazaarPair(pair).creditInsurance(bondBazaar);
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

    /// @dev Soft-fail USDC transfer in raw USDC units (no BAZAAR→USDC conversion). Returns
    ///      false instead of reverting when the recipient can't receive (e.g., USDC blacklist).
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
