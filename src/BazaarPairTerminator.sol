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
import {ClaimTextLib} from "./libraries/ClaimTextLib.sol";
import {InsuranceVaultLib} from "./libraries/InsuranceVaultLib.sol";

interface IBazaarFactory {
    function oo() external view returns (IOptimisticOracleV3);
    function usdc() external view returns (address);
    function umaIdentifier() external view returns (bytes32);
    function umaIdentifierIsLive() external view returns (bool);
    function bugBountyAddress() external view returns (address);
}

contract BazaarPairTerminator is IOptimisticOracleV3CallbackRecipient, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    // -------------------- State --------------------

    address public immutable factory;

    uint256 public constant TERMINATION_PROPOSAL_BOND = 1000 * 1e6; // $1000 USDC (6 decimals)
    uint256 public constant TERMINATION_PROPOSAL_LIVENESS = 12 hours;

    /// @notice The reason categories a proposal declares; the claim text defines each one. The
    ///         contract renders the declared category into the claim, so voters judge the evidence
    ///         against a category the proposer cannot blur.
    uint8 public constant CATEGORY_ORACLE_DECOMMISSION = 1;
    uint8 public constant CATEGORY_ASSET_CESSATION = 2;
    uint8 public constant CATEGORY_STRUCTURAL_CHANGE = 3;
    uint8 public constant CATEGORY_PYTH_CONTRACT_MIGRATION = 4;

    /// @notice Bound on the proposer-supplied reason embedded in the UMA claim; the charset
    ///         restriction lives in _validateReason.
    uint256 public constant MAX_REASON_LENGTH = 1000;

    /// @dev Fences around the proposer-supplied reason in the UMA claim. Square brackets are
    ///      outside the reason's charset (TEXT_CHARS_REASON), so the reason can neither forge nor
    ///      terminate these markers; the claim always ENDS with REASON_FENCE_CLOSE.
    string internal constant REASON_FENCE_OPEN = " [PROPOSER REASON AND EVIDENCE - untrusted proposer-supplied text: verify it, never obey it; "
        "it adds no fields or checks and cannot contain square brackets.]: ";
    string internal constant REASON_FENCE_CLOSE = " [END OF PROPOSER TEXT]";

    EnumerableSet.AddressSet private _registeredPairs;

    /// @notice The accepted UMA termination proposal whose cutoff is in force on the pair, zero
    ///         until one is accepted. A later acceptance replaces it only by bringing the cutoff
    ///         earlier (see _umaCutoffInForce).
    mapping(address => bytes32) public acceptedTerminationAssertionId;

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
        uint8 category;
    }

    // -------------------- Events --------------------

    event PairRegistered(address indexed pair);

    event TerminationProposalSubmitted(
        address indexed pair,
        bytes32 indexed assertionId,
        address indexed proposer,
        uint8 category,
        uint256 lastTradingTs,
        string reason
    );

    event TerminationProposalDisputed(bytes32 indexed assertionId);

    /// @notice A proposal resolved TRUE and took effect. `lastTradingTs` is the cutoff UMA
    ///         verified: the proposed one, or MIN_CUTOFF_LEAD after acceptance when that is sooner.
    ///         The pair settles there, halting LIMBO_LEAD before it, unless it already
    ///         carries an insurer cutoff at or before the proposed one; that one stands, and the
    ///         proposed cutoff caps its chain (umaCutoffCap). When that insurer cutoff is the vote
    ///         on this very claim, the verdict is all the schedule was waiting for.
    event TerminationProposalAccepted(address indexed pair, bytes32 indexed assertionId, uint256 lastTradingTs);

    /// @notice A proposal resolved TRUE but the pair refused the schedule. The assertion still
    ///         settles and the bond returns; the pair keeps whatever cutoff it holds.
    event TerminationScheduleRefused(address indexed pair, bytes32 indexed assertionId);

    /// @notice A proposal resolved TRUE but had nothing left to do: its cutoff is not earlier than
    ///         the UMA cutoff already in force on the pair, the pair's settlement price was
    ///         already fixed, or the cutoff precedes an insurer cutoff the pair had already halted
    ///         at when the proposal resolved. The assertion still settles and the bond returns; the
    ///         pair is unchanged.
    event TerminationProposalSuperseded(address indexed pair, bytes32 indexed assertionId);

    /// @notice A proposal resolved FALSE: a dispute was upheld. The pair is unchanged.
    event TerminationProposalRejected(address indexed pair, bytes32 indexed assertionId);

    // -------------------- Errors --------------------

    error BazaarPairTerminator__ZeroAddress();
    error BazaarPairTerminator__OnlyFactory();
    error BazaarPairTerminator__OnlyUmaOracle();
    error BazaarPairTerminator__ScheduleOutOfGas();
    error BazaarPairTerminator__PairNotRegistered();
    error BazaarPairTerminator__AlreadyTerminated();
    error BazaarPairTerminator__SettlementAlreadyFixed();
    error BazaarPairTerminator__CutoffNotEarlier(uint256 lastTradingTs, uint256 umaCutoff);
    error BazaarPairTerminator__LastTradingTsTooSoon(uint256 lastTradingTs, uint256 minimum);
    error BazaarPairTerminator__InvalidReason(uint256 length);
    error BazaarPairTerminator__InvalidCategory(uint8 category);
    error BazaarPairTerminator__UnknownAssertion();
    error BazaarPairTerminator__AlreadyResolved();
    error BazaarPairTerminator__NoScheduledTermination();
    error BazaarPairTerminator__TerminationTimeNotReached(uint256 scheduledTs, uint256 currentTs);
    error BazaarPairTerminator__OracleNotStaleEnough(uint256 lastUpdate, uint256 threshold);
    error BazaarPairTerminator__InsufficientPythFee(uint256 provided, uint256 required);
    error BazaarPairTerminator__EthRefundFailed();
    error BazaarPairTerminator__UmaIdentifierNotLive();
    error BazaarPairTerminator__OracleBusy();
    error BazaarPairTerminator__InsurerScheduleSettlesPair();

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

    /// @dev Bounds and sanitizes the reason, the one proposer-supplied text in the UMA claim: the
    ///      contract identifies the pair itself, by pair ID and feed IDs. The reason is restricted
    ///      to a conservative ASCII subset so crafted text cannot escape a delimiter, open a fake
    ///      numbered check, or smuggle invisible/homoglyph text past the humans who verify these
    ///      claims: letters, digits, space, . , & / - and the URL set : ? = # % _ ~ + so evidence
    ///      URLs survive. The colon the URL set admits could imitate the claim's "Field: value"
    ///      syntax, so it is defused structurally, not lexically: the reason is spliced as the
    ///      claim's clearly labeled FINAL section, between square-bracket fences the charset makes
    ///      unforgeable, after every contract-authored field and instruction block.
    function _validateReason(string calldata reason) internal pure {
        uint256 reasonLen = bytes(reason).length;
        if (reasonLen == 0 || reasonLen > MAX_REASON_LENGTH || !_charsOk(bytes(reason))) {
            revert BazaarPairTerminator__InvalidReason(reasonLen);
        }
    }

    /// @dev The reason's charset as a 256-bit bitmap (bit N set = byte value N allowed), folded at
    ///      compile time; one shift+mask per byte keeps the check small.
    ///      Base set: letters, digits, space, and . , & / -
    ///      URL set, added for the reason: : ? = # % _ ~ +
    uint256 internal constant TEXT_CHARS_BASE = ((2 ** 26 - 1) << 97) // a-z
        | ((2 ** 26 - 1) << 65) // A-Z
        | ((2 ** 10 - 1) << 48) // 0-9
        | (1 << 32) | (1 << 46) | (1 << 44) | (1 << 38) | (1 << 47) | (1 << 45); // space . , & / -
    uint256 internal constant TEXT_CHARS_REASON = TEXT_CHARS_BASE | (1 << 58) | (1 << 63) | (1 << 61) | (1 << 35)
        | (1 << 37) | (1 << 95) | (1 << 126) | (1 << 43); // : ? = # % _ ~ +

    function _charsOk(bytes calldata s) internal pure returns (bool) {
        for (uint256 i = 0; i < s.length; i++) {
            // Bytes >= 128 (every non-ASCII lead/continuation byte) shift into the bitmap's
            // always-zero upper region, so they are rejected by the same test.
            if ((TEXT_CHARS_REASON >> uint8(s[i])) & 1 == 0) return false;
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

    /// @dev The claim's name for a declared category. proposeTermination has already rejected
    ///      anything outside CATEGORY_ORACLE_DECOMMISSION..CATEGORY_PYTH_CONTRACT_MIGRATION.
    function _categoryName(uint8 category) internal pure returns (string memory) {
        if (category == CATEGORY_ORACLE_DECOMMISSION) return "ORACLE DECOMMISSION";
        if (category == CATEGORY_ASSET_CESSATION) return "ASSET CESSATION";
        if (category == CATEGORY_STRUCTURAL_CHANGE) return "STRUCTURAL CHANGE";
        return "PYTH CONTRACT MIGRATION";
    }

    /// @dev The contract-written opening of the claim: the pair's identity, the declared category
    ///      and the proposed cutoff.
    function _claimHead(IBazaarPair p, uint8 category, uint256 lastTradingTs) internal view returns (bytes memory) {
        return abi.encodePacked(
            "Termination proposal for the Bazaar trading pair with pair ID ",
            Strings.toHexString(uint256(p.pairId())),
            " on Arbitrum (chain ID ",
            Strings.toString(block.chainid),
            ").",
            " Pyth oracle: ",
            Strings.toHexString(address(BazaarOracle(p.oracle()).pyth())),
            _feedIdSection(p),
            ". Declared reason category: (",
            Strings.toString(category),
            ") ",
            _categoryName(category),
            ". Proposed last trading timestamp: ",
            Strings.toString(lastTradingTs),
            "."
        );
    }

    /// @dev The claim's verification steps. Every figure is passed to ClaimTextLib from the
    ///      constant that enforces it, so the text cannot drift from the contract.
    function _claimHowToValidate() internal pure returns (bytes memory) {
        uint256 liveness = TERMINATION_PROPOSAL_LIVENESS / 1 hours;
        uint256 voteLead = INSURER_TERMINATION_MIN_LEAD / 1 hours;
        uint256 halt = BazaarTypes.LIMBO_LEAD;
        uint256 window = BazaarTypes.MAX_PRICE_STALENESS;
        uint256 lead = BazaarTypes.MIN_CUTOFF_LEAD;
        uint256 grace = SCHEDULED_TERMINATION_GRACE / 1 hours;
        uint256 verdictGrace = CLAIM_VERDICT_GRACE / 1 days;
        uint256 voterLock = INSURER_POST_FIX_LOCK / 1 days;
        uint256 levyFloor = INSURER_LEVY_FLOOR_BP / 100;
        return ClaimTextLib.terminationHowToValidate(
            liveness,
            voteLead,
            halt,
            window,
            lead,
            grace,
            verdictGrace,
            voterLock,
            levyFloor,
            SETTLEMENT_SAMPLE_COUNT,
            SETTLEMENT_SAMPLE_SPACING / 1 minutes
        );
    }

    /// @notice Propose terminating a pair through UMA, which also opens the insurers' vote on the
    ///         same cutoff. What an accepted proposal does to the pair's schedule is described at
    ///         _handleTerminationResolution; once a UMA cutoff is in force, a proposal must name an
    ///         earlier one. The vote is the emergency route: holders of 60% of the share snapshot
    ///         may latch the cutoff before the claim resolves (executeInsurerTermination), after
    ///         which the pair settles under the verdict (see terminateScheduledPair).
    /// @dev The claim identifies the pair by its pair ID and feed IDs and names the declared
    ///      category, both written by the contract, so the fenced reason is the only
    ///      proposer-supplied text in it. The cutoff may sit as near as INSURER_TERMINATION_MIN_LEAD
    ///      because the vote's latch, which closes INSURER_TERMINATION_LATCH_LEAD before the cutoff,
    ///      is price-blind. An undisputed claim is accepted only when the liveness ends, so a
    ///      cutoff nearer than that is met as proposed only through the vote; without the vote,
    ///      the claim is accepted after its cutoff and takes effect as any late acceptance does
    ///      (_handleTerminationResolution).
    /// @param pair The registered pair to terminate
    /// @param category The reason category claimed, CATEGORY_ORACLE_DECOMMISSION through
    ///        CATEGORY_PYTH_CONTRACT_MIGRATION; the claim text defines each one
    /// @param lastTradingTs The proposed cutoff, at least INSURER_TERMINATION_MIN_LEAD from now and
    ///        earlier than the UMA cutoff in force, if any
    /// @param reason The grounds and evidence, 1 to MAX_REASON_LENGTH bytes in the charset
    ///        _validateReason enforces
    /// @return assertionId The UMA assertion tracking the proposal, and the id of its vote
    function proposeTermination(address pair, uint8 category, uint256 lastTradingTs, string calldata reason)
        external
        nonReentrant
        returns (bytes32 assertionId)
    {
        if (!_registeredPairs.contains(pair)) revert BazaarPairTerminator__PairNotRegistered();
        IBazaarPair p = IBazaarPair(pair);
        if (p.isPairTerminated()) revert BazaarPairTerminator__AlreadyTerminated();
        if (p.settlementPriceFixedTs() != 0) revert BazaarPairTerminator__SettlementAlreadyFixed();
        // An accepted cutoff only ever moves earlier, so a proposal that cannot beat the one in
        // force is refused before its bond moves.
        (bool umaCutoffSet, uint256 umaCutoff) = _umaCutoffInForce(pair, p);
        if (umaCutoffSet && lastTradingTs >= umaCutoff) {
            revert BazaarPairTerminator__CutoffNotEarlier(lastTradingTs, umaCutoff);
        }
        if (category == 0 || category > CATEGORY_PYTH_CONTRACT_MIGRATION) {
            revert BazaarPairTerminator__InvalidCategory(category);
        }
        // A cutoff this near is met only through the vote, whose latch is price-blind (see the
        // function doc); acceptance alone comes after it and moves it out like any late one.
        uint256 minLastTradingTs = block.timestamp + INSURER_TERMINATION_MIN_LEAD;
        if (lastTradingTs < minLastTradingTs) {
            revert BazaarPairTerminator__LastTradingTsTooSoon(lastTradingTs, minLastTradingTs);
        }
        _validateReason(reason);

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
            _claimHead(p, category, lastTradingTs),
            ClaimTextLib.terminationReasons(),
            _claimHowToValidate(),
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
            resolved: false,
            category: category
        });

        emit TerminationProposalSubmitted(pair, assertionId, msg.sender, category, lastTradingTs, reason);
        _openInsurerProposal(assertionId, pair, msg.sender, lastTradingTs, true);
    }

    function settleTerminationProposal(bytes32 assertionId) external {
        // Settle on the OO recorded for this assertion at proposal time.
        assertionOo[assertionId].settleAndGetAssertionResult(assertionId);
    }

    // -------------------- Direct termination --------------------

    uint256 internal constant ORACLE_DEAD_THRESHOLD = 21 days;
    /// @notice How long ONLY the precise tick settles a pair under UMA's rule, counted from
    ///         scheduledTs or, for a pair a vote halted, from when its claim's verdict became known
    ///         if that is later (_windowGraceEnd). After it elapses, terminateScheduledPair falls
    ///         back to the pair's last stored price if no valid tick is supplied.
    /// @dev Sized to match TERMINATION_PROPOSAL_LIVENESS, because the two answer the same
    ///      question: how long an interested party needs to notice a termination and act on it.
    ///      The window has to carry that whole burden on its own, since the incentives run the
    ///      wrong way — posting the precise tick costs gas plus the Pyth fee and pays nothing,
    ///      while waiting the window out and calling with empty calldata costs only gas. So the
    ///      side the stale-price fallback happens to favor has the strictly cheaper action, and
    ///      this window is the only thing giving the other side room to answer. It cannot simply
    ///      be made long, though: limbo freezes withdrawals, matching and liquidation until the
    ///      price is fixed, so the ceiling is how long the book can sit frozen, not how long an
    ///      inattentive keeper might take. The tick cannot settle a pair a vote halted before the
    ///      verdict on its claim, so the grace starts no earlier than that verdict is known
    ///      (_windowGraceEnd). Supplying the tick ends limbo as soon as the rule applies, so the
    ///      length only ever delays the fallback — never the accurate settlement it exists to
    ///      protect.
    uint256 internal constant SCHEDULED_TERMINATION_GRACE = 12 hours;

    /// @notice How many prints settle a pair under the chain rule, the rule of every insurer-vote
    ///         schedule whose claim UMA has not upheld: the median of this many samples chained
    ///         from the cutoff (BazaarOracle.fetchChainedMedian). Odd, so the median is a sample
    ///         and moving it means moving more than half of them.
    uint256 public constant SETTLEMENT_SAMPLE_COUNT = 5;
    /// @notice How far after one chain sample's publish time the next sample's target lies. The
    ///         last of SETTLEMENT_SAMPLE_COUNT samples is therefore published at least
    ///         (SETTLEMENT_SAMPLE_COUNT - 1) times this after the first, so one print cannot be the
    ///         whole set, and a cutoff placed at a session's close is settled on prints from the
    ///         reopen's first stretch rather than on its opening print alone.
    uint256 public constant SETTLEMENT_SAMPLE_SPACING = 10 minutes;

    /// @notice settlementRule's answers: what terminateScheduledPair needs to settle a pair.
    uint8 public constant SETTLE_NOTHING = 0;
    uint8 public constant SETTLE_WINDOW = 1;
    uint8 public constant SETTLE_CHAIN = 2;
    uint8 public constant SETTLE_AWAIT_VERDICT = 3;

    /// @notice Settlement price of a pair that never stored a price: the smallest one
    ///         fixSettlementPrice accepts. See _lastStoredPrice.
    uint256 internal constant NEVER_PRICED_SETTLEMENT_PRICE = 1;

    /// @notice Emitted when terminateStalePair settles a pair whose feed is dead, just before the
    ///         SettlementPriceFixed that every governed path emits.
    /// @param pair The pair
    /// @param terminationPrice The settlement price: the pair's last stored spot price, or
    ///        NEVER_PRICED_SETTLEMENT_PRICE when it never stored one
    /// @param oracleLastUpdateTs That stored price's publish time, or the pair's creation time when
    ///        it never stored one; more than ORACLE_DEAD_THRESHOLD before the call
    event StalePairTerminated(address indexed pair, uint256 terminationPrice, uint256 oracleLastUpdateTs);

    /// @notice Emitted whenever a governed termination path pins a pair's settlement price, opening
    ///         its terminal sweep window. Declared here rather than in BazaarPair — every governed
    ///         path routes through this contract, so the pair's EIP-170 budget stays free of it.
    ///         The pair's own insolvency path emits BazaarPair.InsolvencySettlementFixed instead.
    ///         Keepers should sweep negative-equity positions via BazaarPair.liquidate (no price
    ///         update needed) and call BazaarPair.finalizeTermination after the window.
    event SettlementPriceFixed(address indexed pair, uint256 settlementPrice);

    /// @dev Single home for stage-1 fixes so every path emits the canonical event.
    function _fixSettlement(IBazaarPair p, address pair, uint256 price) internal {
        p.fixSettlementPrice(price);
        emit SettlementPriceFixed(pair, price);
    }

    /// @notice Stage 1 of a scheduled termination: pin the settlement price for the scheduled
    ///         cutoff. Anyone can call this once scheduledTs has passed. A pair scheduled by a
    ///         UMA acceptance, or by a vote whose claim UMA upheld, settles under UMA's rule: the
    ///         first Pyth tick published in [scheduledTs - MAX_PRICE_STALENESS, scheduledTs], the
    ///         window the pair's limbo already covers, supplied via priceUpdate and verified
    ///         on-chain, and its stored price once SCHEDULED_TERMINATION_GRACE has passed without
    ///         one, counted from scheduledTs or, for a vote, from when its claim's verdict became
    ///         known if that is later. A pair scheduled by any other vote settles under the
    ///         chain rule: the median of SETTLEMENT_SAMPLE_COUNT prints chained from scheduledTs,
    ///         each the first print at least SETTLEMENT_SAMPLE_SPACING after the one before
    ///         (BazaarOracle.fetchChainedMedian), every one published no later than the UMA cutoff
    ///         the schedule met, if any (umaCutoffCap). settlementRule reports which rule applies
    ///         and what to fetch. Fixing the price opens the pair's terminal sweep window
    ///         (liquidations at the fixed price only); after it elapses anyone may call
    ///         BazaarPair.finalizeTermination to settle.
    /// @dev A vote-scheduled pair first has its outcome stamped (_stampInsurerOutcome). For a
    ///      claim-backed vote that means the claim's verdict: TRUE puts the pair under UMA's rule
    ///      above, since every category UMA upholds is a break in the feed's continuity after
    ///      which the next print is no price at all, so the last one before the cutoff is the
    ///      honest settlement; FALSE, or no verdict by CLAIM_VERDICT_GRACE, leaves it under the
    ///      chain rule. A verdict still pending inside the grace reverts, and the pair waits in
    ///      limbo for it: settling first at the pre-event price and penalizing the voters later
    ///      could never make the traders whole whom that print shortchanged if the claim proved
    ///      false.
    ///
    ///      The chain rule reads only prints published at or after the cutoff. The cutoff was
    ///      latched at least INSURER_TERMINATION_LATCH_LEAD before it arrived and trading halts
    ///      LIMBO_LEAD before it, so none of them is a price anyone could have traded
    ///      against, and Pyth proves each supplied sample is the first print at or after its own
    ///      target, so whoever settles cannot choose which prints count
    ///      (BazaarOracle.fetchChainedMedian). Taking the median of several prints rather than the
    ///      first one alone makes the settlement cost several prints to move instead of one, which
    ///      matters on a thin feed whose proposer picked the cutoff. The rule has no grace and,
    ///      until its last resort opens (_insurerSettlementBounds: ORACLE_DEAD_THRESHOLD after the
    ///      cutoff, or SCHEDULED_TERMINATION_GRACE after a capping UMA cutoff when that is sooner),
    ///      no stored-price fallback. A prompt fallback would hand
    ///      the fund the very choice the cutoff denies it: pick a cutoff inside a closed session,
    ///      wait out a grace, settle at the last close after news that moved the market. So a
    ///      cutoff that falls while the feed is quiet settles on prints from the reopen, unless UMA
    ///      has judged the event real. Once the last resort opens, a call that brings no valid
    ///      chain, an empty one included, settles at the stored price: whoever calls first then
    ///      chooses between a chain and the stored price, but by then anyone who wanted the chain
    ///      has had that long to post it, and without the fallback a sample that can no longer be
    ///      verified on-chain (an expired Wormhole guardian set, an archival gap) or a feed that
    ///      went dark before printing them all would freeze every balance on the pair for good;
    ///      terminateStalePair cannot be relied on, since Pyth's cache stays fresh for as long as
    ///      anyone keeps pushing updates to it.
    ///
    ///      A UMA cutoff the schedule met bounds every sample (_insurerSettlementBounds): each must
    ///      be published no later than it, and once it is SCHEDULED_TERMINATION_GRACE old a call
    ///      that brings no such chain settles at the stored price, as it would have at UMA's own
    ///      cutoff. UMA has verified an event the market can see coming, so a reopen print
    ///      published after that cutoff can carry a move whose direction was public when the
    ///      insurer cutoff was voted; capped, the earlier cutoff only moves the halt, never the
    ///      settlement past the cutoff UMA verified.
    ///
    ///      Under UMA's rule, Pyth proves the supplied tick is the window's first print, so the
    ///      settlement price is the same whoever calls: a later print inside the window is refused
    ///      like one outside it, and for a composite each leg is pinned on its own. Until the grace
    ///      ends (_windowGraceEnd) that precise tick is the ONLY acceptable price: if it isn't
    ///      supplied the call reverts (no last-price fallback). This gives anyone who wants the
    ///      accurate price a window to post it, and crucially means bad/empty data can't be used
    ///      to force a fallback while a real tick may exist. The grace can never be pre-elapsed
    ///      when an acceptance starts it: a proposal accepted after its cutoff (a disputed one
    ///      resolving late at the DVM) is scheduled MIN_CUTOFF_LEAD past the acceptance instant, so
    ///      scheduledTs is never in the past when it is set. A vote sets its cutoff before the
    ///      verdict, and the call reverts while the verdict is pending, so for a vote-scheduled
    ///      pair the grace counts from when the verdict became known whenever that is later than
    ///      the cutoff: the end of the claim's liveness if it is undisputed, else the moment the
    ///      verdict is recorded, by this call or by any settle of the assertion. A grace counted
    ///      from the cutoff alone would let whoever settles first after a late verdict choose
    ///      between the tick and the stored price. A disputed verdict this call records itself
    ///      starts the grace at once, so the call must then fetch the tick or revert, and the
    ///      revert takes the recording with it: nobody can record such a verdict and fall back in
    ///      one transaction.
    ///
    ///      After the grace elapses, the precise tick is still preferred, but if the precise fetch
    ///      reverts (no tick in the window, or no/invalid data supplied) the pair settles at
    ///      its last stored price instead: capped at scheduledTs, confidence-checked, and frozen
    ///      since matching is halted in limbo, so it's non-manipulable. This guarantees a scheduled
    ///      termination always completes rather than stranding the pair (and the funds backing its
    ///      open positions) indefinitely when the feed had no tick in the settlement window (or the
    ///      archived tick's Wormhole guardian set has expired and can no longer verify on-chain).
    ///      On both paths a pair that never stored a price settles at
    ///      NEVER_PRICED_SETTLEMENT_PRICE instead (see _lastStoredPrice).
    /// @param pair The pair whose cutoff has passed
    /// @param priceUpdate Under UMA's rule, the window's first print, one update per leg; under the
    ///        chain rule, the sample set, one update per leg for each sample in turn; empty for
    ///        the stored-price fallback once it is open
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

        // A vote-scheduled pair settles under its stamped outcome: UMA's rule when the claim
        // behind the vote was upheld, the chain rule otherwise.
        bytes32 scheduleId = insurerScheduleId[pair];
        bool chainRule;
        if (scheduleId != bytes32(0)) {
            chainRule = !_stampInsurerOutcome(pair, scheduleId, insurerProposals[scheduleId]);
        }

        BazaarOracle oracleContract = BazaarOracle(p.oracle());
        bytes32 feedId = p.baseFeedId();
        uint256 refundAmount;

        if (chainRule) {
            refundAmount = _settleByChain(p, pair, oracleContract, feedId, priceUpdate, scheduledTs);
        } else {
            // Only query the fee when update data is supplied: getUpdateFee is a call into the Pyth
            // contract OUTSIDE the try/catch below, so an unconditional call would make even the
            // empty-calldata fallback path revert if the Pyth contract itself is bricked/migrated —
            // stranding the pair until the 21-day stale path instead of settling after the grace.
            uint256 fee = priceUpdate.length > 0 ? oracleContract.getUpdateFee(priceUpdate) : 0;

            // Read after the stamp, so a verdict the stamp has just recorded counts.
            if (block.timestamp <= _windowGraceEnd(scheduleId, scheduledTs)) {
                // Within grace: precise price only, revert on any failure.
                uint256 terminationPrice = oracleContract.fetchFirstPriceAtOrAfter{value: fee}(
                    feedId, priceUpdate, uint64(scheduledTs - BazaarTypes.MAX_PRICE_STALENESS), uint64(scheduledTs)
                );
                _fixSettlement(p, pair, terminationPrice);
                refundAmount = msg.value - fee;
            } else {
                // After grace: prefer precise, fall back to the last stored price on revert.
                try oracleContract.fetchFirstPriceAtOrAfter{value: fee}(
                    feedId, priceUpdate, uint64(scheduledTs - BazaarTypes.MAX_PRICE_STALENESS), uint64(scheduledTs)
                ) returns (
                    uint256 terminationPrice
                ) {
                    _fixSettlement(p, pair, terminationPrice);
                    refundAmount = msg.value - fee;
                } catch {
                    (uint256 lastPrice,) = _lastStoredPrice(p);
                    _fixSettlement(p, pair, lastPrice);
                    refundAmount = msg.value; // precise fetch reverted → no Pyth fee consumed
                }
            }
        }

        if (refundAmount > 0) {
            (bool ok,) = payable(msg.sender).call{value: refundAmount}("");
            if (!ok) revert BazaarPairTerminator__EthRefundFailed();
        }
    }

    /// @dev The chain rule's settlement of `pair`, whose cutoff is `scheduledTs`; returns the ETH
    ///      to refund. Until the last resort opens only a complete chain fixes the price, and any
    ///      failure reverts. From then on the chain is still preferred, and when it cannot be
    ///      fetched (no data, a short set, a sample that will not verify) the stored price stands
    ///      in. The fee is queried only when update data is supplied, for the same reason as on
    ///      UMA's rule: it is a call into Pyth outside the try/catch.
    function _settleByChain(
        IBazaarPair p,
        address pair,
        BazaarOracle oracleContract,
        bytes32 feedId,
        bytes[] calldata priceUpdate,
        uint256 scheduledTs
    ) private returns (uint256 refundAmount) {
        uint256 setFee = priceUpdate.length > 0 ? oracleContract.getSampleSetFee(feedId, priceUpdate) : 0;
        if (msg.value < setFee) revert BazaarPairTerminator__InsufficientPythFee(msg.value, setFee);
        (uint64 latestPublishTs, uint256 lastResortTs) = _insurerSettlementBounds(pair, scheduledTs);
        if (block.timestamp <= lastResortTs) {
            _fixSettlement(
                p,
                pair,
                oracleContract.fetchChainedMedian{value: setFee}(
                    feedId,
                    priceUpdate,
                    uint64(scheduledTs),
                    latestPublishTs,
                    uint64(SETTLEMENT_SAMPLE_SPACING),
                    SETTLEMENT_SAMPLE_COUNT
                )
            );
            return msg.value - setFee;
        }
        try oracleContract.fetchChainedMedian{value: setFee}(
            feedId,
            priceUpdate,
            uint64(scheduledTs),
            latestPublishTs,
            uint64(SETTLEMENT_SAMPLE_SPACING),
            SETTLEMENT_SAMPLE_COUNT
        ) returns (
            uint256 settlementPrice
        ) {
            _fixSettlement(p, pair, settlementPrice);
            refundAmount = msg.value - setFee;
        } catch {
            (uint256 lastPrice,) = _lastStoredPrice(p);
            _fixSettlement(p, pair, lastPrice);
            refundAmount = msg.value; // the fetch reverted, so no Pyth fee was spent
        }
    }

    /// @notice How terminateScheduledPair settles `pair` if called now, so a keeper knows what to
    ///         fetch. `rule` is one of:
    ///         - SETTLE_NOTHING: the pair carries no cutoff, or its price is already fixed.
    ///         - SETTLE_WINDOW: UMA's rule, one print per leg: the first published at or after
    ///           `firstTarget`, which must be published no later than `latestPublishTs`, the cutoff.
    ///           Its grace counts from the cutoff or, for a vote, from when the verdict on its claim
    ///           became known if that is later, and `lastResortTs` is where it ends.
    ///         - SETTLE_CHAIN: the chain rule, SETTLEMENT_SAMPLE_COUNT samples: the first print at
    ///           or after `firstTarget`, the cutoff, then each the first print at or after
    ///           SETTLEMENT_SAMPLE_SPACING past the sample before, every one published no later
    ///           than `latestPublishTs` (BazaarOracle.fetchChainedMedian).
    ///         - SETTLE_AWAIT_VERDICT: the vote that set the cutoff waits for the verdict on its
    ///           claim, and settlement reverts until UMA resolves the claim or `verdictDeadline`
    ///           passes, whichever comes first.
    ///         A verdict the DVM has reached but nobody has recorded reads here as no verdict:
    ///         SETTLE_AWAIT_VERDICT before `verdictDeadline` and SETTLE_CHAIN after it, while
    ///         terminateScheduledPair records it and settles under it, UMA's rule for TRUE. For a
    ///         claim-backed vote, call settleTerminationProposal first: it records a verdict UMA
    ///         can give, and this view then reports the rule that will apply.
    ///         Under SETTLE_WINDOW and SETTLE_CHAIN a call with no price data settles at the
    ///         stored price once `lastResortTs` has passed.
    /// @dev Reads the state terminateScheduledPair branches on, with the verdict peeked rather
    ///      than settled (_peekVerdict); the call itself also requires the cutoff to have passed.
    /// @param pair The pair
    /// @return rule SETTLE_NOTHING, SETTLE_WINDOW, SETTLE_CHAIN or SETTLE_AWAIT_VERDICT
    /// @return firstTarget The first (or only) print's target; zero unless WINDOW or CHAIN
    /// @return latestPublishTs The latest publish time any print may carry; zero unless WINDOW or CHAIN
    /// @return lastResortTs The instant after which an empty call settles at the stored price;
    ///         zero unless WINDOW or CHAIN, and the uint256 maximum when that lies past the uint256
    ///         range
    /// @return verdictDeadline When a pending verdict stops being waited for; zero unless AWAIT_VERDICT
    function settlementRule(address pair)
        external
        view
        returns (
            uint8 rule,
            uint256 firstTarget,
            uint256 latestPublishTs,
            uint256 lastResortTs,
            uint256 verdictDeadline
        )
    {
        IBazaarPair p = IBazaarPair(pair);
        uint256 scheduledTs = p.scheduledTerminationTs();
        if (scheduledTs == 0 || p.settlementPriceFixedTs() != 0) return (SETTLE_NOTHING, 0, 0, 0, 0);
        bytes32 id = insurerScheduleId[pair];
        bool chain = id != bytes32(0);
        if (chain && insurerProposals[id].claimBacked) {
            uint8 verdict = _peekVerdict(id, insurerProposals[id]);
            if (verdict == VERDICT_TRUE) {
                chain = false;
            } else if (verdict == VERDICT_PENDING) {
                uint256 deadline = terminationProposals[id].proposalTs + CLAIM_VERDICT_GRACE;
                if (block.timestamp < deadline) return (SETTLE_AWAIT_VERDICT, 0, 0, 0, deadline);
            }
        }
        if (chain) {
            (uint64 latest, uint256 lastResort) = _insurerSettlementBounds(pair, scheduledTs);
            return (SETTLE_CHAIN, scheduledTs, latest, lastResort, 0);
        }
        return (
            SETTLE_WINDOW,
            scheduledTs - BazaarTypes.MAX_PRICE_STALENESS,
            scheduledTs,
            _windowGraceEnd(id, scheduledTs),
            0
        );
    }

    /// @notice Terminate a pair whose oracle has been stale for more than ORACLE_DEAD_THRESHOLD
    ///         (21 days). This is the ONLY condition under which this method terminates — staleness
    ///         is objective on-chain proof and needs no UMA proposal. It must never terminate for
    ///         any other reason (e.g. a transient oracle revert or non-positive price); for those,
    ///         use the UMA termination flow. A pair whose vote-set cutoff has already passed is
    ///         refused: terminateScheduledPair settles it, with the vote's outcome stamped.
    /// @dev Anyone can call this.
    function terminateStalePair(address pair) external nonReentrant {
        if (!_registeredPairs.contains(pair)) revert BazaarPairTerminator__PairNotRegistered();
        IBazaarPair p = IBazaarPair(pair);
        if (p.settlementPriceFixedTs() != 0) {
            revert BazaarPairTerminator__AlreadyTerminated();
        }
        // A pair whose vote-set cutoff has passed settles through terminateScheduledPair, which
        // stamps the vote's outcome; its own stored-price fallback (settlementRule's lastResortTs)
        // reaches the same stored price, so this path would only let the voters settle without the
        // lock and the levy their outcome carries.
        if (insurerScheduleId[pair] != bytes32(0) && block.timestamp > p.scheduledTerminationTs()) {
            revert BazaarPairTerminator__InsurerScheduleSettlesPair();
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
        // Settlement itself always uses the pair's last stored price (or, for a pair that never
        // stored one, NEVER_PRICED_SETTLEMENT_PRICE). Pyth's cache is permissionlessly writable
        // to any published tick, so settling at it would let whoever calls this pick the
        // book-wide settlement price out of the ticks published before the feed went quiet.
        // lastPairPrice can only ever hold a mark that cleared both the freshness gate and the
        // confidence cap at the moment it was recorded.
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
    ///      as a side door to terminate it. A pair that never stored a price is aged from its
    ///      creation instead, which shuts the same door on a new listing: the oracle probe alone
    ///      would pass at once for a feed whose cached tick was already old when the pair listed.
    function _terminateAtLastStoredPrice(address pair, IBazaarPair p) private {
        (uint256 price, uint256 asOfTs) = _lastStoredPrice(p);
        if (block.timestamp - asOfTs <= ORACLE_DEAD_THRESHOLD) {
            revert BazaarPairTerminator__OracleNotStaleEnough(asOfTs, ORACLE_DEAD_THRESHOLD);
        }
        emit StalePairTerminated(pair, price, asOfTs);
        _fixSettlement(p, pair, price);
    }

    /// @dev The chain rule's limits for an insurer-scheduled pair whose cutoff is `scheduledTs`.
    ///      `latestPublishTs` is the latest publish time any of its samples may carry: the UMA
    ///      cutoff the schedule met (umaCutoffCap), or no limit when it met none. `lastResortTs`
    ///      is the instant after which the stored price stands in for a chain that cannot be
    ///      fetched: ORACLE_DEAD_THRESHOLD after the insurer cutoff, or
    ///      SCHEDULED_TERMINATION_GRACE after that UMA cutoff when that comes first. A UMA cutoff is
    ///      proposer-chosen with no upper bound, so it is clamped to the oracle's uint64 range and
    ///      compared by subtracting the grace from the threshold's end; adding the grace to it
    ///      could overflow and make the pair unsettleable.
    function _insurerSettlementBounds(address pair, uint256 scheduledTs)
        private
        view
        returns (uint64 latestPublishTs, uint256 lastResortTs)
    {
        latestPublishTs = type(uint64).max;
        lastResortTs = scheduledTs + ORACLE_DEAD_THRESHOLD;
        uint256 umaCutoff = umaCutoffCap[pair];
        if (umaCutoff == 0) return (latestPublishTs, lastResortTs);
        if (umaCutoff < latestPublishTs) latestPublishTs = uint64(umaCutoff);
        if (umaCutoff < lastResortTs - SCHEDULED_TERMINATION_GRACE) {
            lastResortTs = umaCutoff + SCHEDULED_TERMINATION_GRACE;
        }
    }

    /// @dev When UMA's rule stops waiting for the precise tick on a pair whose cutoff is
    ///      `scheduledTs`: SCHEDULED_TERMINATION_GRACE after the cutoff or, for a pair the vote on
    ///      claim `scheduleId` halted, after the verdict on that claim became known when that is
    ///      later (_verdictKnownTs). A vote settles under UMA's rule only once its claim is upheld,
    ///      so a non-zero `scheduleId` here is always a claim's: a bare vote's id has no oracle, and
    ///      reading one would revert outside _verdictKnownTs's catch, since a call to an address
    ///      with no code returns nothing to decode. An accepted UMA cutoff has no upper bound, so
    ///      the end saturates rather than overflowing.
    function _windowGraceEnd(bytes32 scheduleId, uint256 scheduledTs) private view returns (uint256) {
        uint256 start = scheduledTs;
        if (scheduleId != bytes32(0)) {
            uint256 knownTs = _verdictKnownTs(scheduleId);
            if (knownTs > start) start = knownTs;
        }
        return start > type(uint256).max - SCHEDULED_TERMINATION_GRACE
            ? type(uint256).max
            : start + SCHEDULED_TERMINATION_GRACE;
    }

    /// @dev When the TRUE verdict on claim `id` became known. Undisputed, it is the end of the
    ///      claim's liveness: from then on OOv3 can resolve it no other way, and settlement reads it
    ///      as upheld. Disputed, it is when the verdict was recorded while the claim's vote held the
    ///      pair's cutoff (verdictRecordedTs): nothing on-chain marks when the DVM ruled, and no
    ///      settlement can apply the verdict before it is recorded. For a disputed verdict recorded
    ///      before the vote latched the cutoff it is zero, and the cutoff, which lies after the
    ///      recording, starts the grace. An oracle that cannot answer falls back to the recorded
    ///      time.
    function _verdictKnownTs(bytes32 id) private view returns (uint256) {
        try assertionOo[id].getAssertion(id) returns (IOptimisticOracleV3.Assertion memory a) {
            if (a.disputer == address(0)) return a.expirationTime;
        } catch {}
        return verdictRecordedTs[id];
    }

    /// @dev The price the stored-price fallbacks settle at and the time it dates from: the pair's
    ///      last stored price and its publish time or, for a pair that never stored one,
    ///      NEVER_PRICED_SETTLEMENT_PRICE and the pair's creation time. Every price a pair
    ///      resolves is either one it stores or the one it already holds, so a pair with nothing
    ///      stored has only ever been marked at zero, and the smallest settlement price values its
    ///      book as its own mark always has. Reverting instead would leave every exit waiting on a
    ///      price a dead feed never delivers: a live pair pays insurers only against a fresh
    ///      price, so the fund, the listing seed included, could never be released.
    function _lastStoredPrice(IBazaarPair p) private view returns (uint256 price, uint256 asOfTs) {
        (price,, asOfTs,,) = p.lastPairPrice();
        if (price == 0) {
            price = NEVER_PRICED_SETTLEMENT_PRICE;
            asOfTs = p.auxState().pairCreatedTs;
        }
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

    /// @dev An accepted proposal only schedules the pair, at lastTradingTs or MIN_CUTOFF_LEAD after
    ///      acceptance when lastTradingTs is sooner (a disputed assertion resolving late at the
    ///      DVM, or an expired one nobody settled at its cutoff, whose limbo then starts a second
    ///      after acceptance), or caps the settlement print of an insurer schedule already in
    ///      place, or, when the vote on this very claim already holds the pair's cutoff, records
    ///      the verdict, the claim as the acceptance in force with its cutoff as the cap, and the
    ///      moment it was recorded, and schedules nothing. Settlement happens in a
    ///      separate, retryable terminateScheduledPair transaction; nothing price-dependent runs
    ///      inside this UMA callback, and a refusal the pair reports is caught, so no pair-side
    ///      rule can revert the settle and lock the bond. A failure that carries no revert data is
    ///      the pair running out of gas, and that one is re-raised: it is the caller's gas, not the
    ///      pair's state, so more of it is all a retry needs, whereas catching it would let a
    ///      settle sent with too little gas consume the accepted assertion without scheduling
    ///      anything.
    ///
    ///      Every resolution emits exactly one UMA event, so an indexer can tell a resolved
    ///      proposal from a pending one without reading storage: TerminationProposalAccepted,
    ///      TerminationScheduleRefused, TerminationProposalSuperseded (TRUE, but its cutoff is not
    ///      earlier than the UMA cutoff in force, the price is already fixed, or the cutoff precedes
    ///      an insurer cutoff the pair has already halted at) or TerminationProposalRejected (FALSE).
    ///
    ///      The verdict is recorded on the claim's vote either way. FALSE before the vote has
    ///      scheduled the pair ends the vote (InsurerTerminationRejected); FALSE after it leaves
    ///      the schedule standing and costs its yes-voters at the fix (_stampInsurerOutcome).
    ///
    ///      A TRUE proposal takes effect only when its cutoff is earlier than the UMA cutoff in
    ///      force (_umaCutoffInForce). An accepted cutoff therefore never moves later and is never
    ///      cancelled, and a later proposal can still bring it forward. Two proposals settled while
    ///      both their cutoffs are still ahead resolve to the earlier one whichever settles first;
    ///      one settled after its own cutoff takes effect MIN_CUTOFF_LEAD after the settle, as a
    ///      first acceptance would, and only if that still beats the cutoff in force. Under a
    ///      first-accepted-wins rule, a far-off cutoff for one event would refuse every UMA proposal
    ///      for an earlier one, and the market would trade through it. A cutoff nearer than the
    ///      liveness is always accepted late, since an undisputed claim resolves only when the
    ///      liveness ends; unless its own vote holds the schedule, it is handled as any other late
    ///      acceptance. The cutoff then lands MIN_CUTOFF_LEAD after the settle, and a cap is the
    ///      proposed cutoff, which lay at least INSURER_TERMINATION_MIN_LEAD ahead at filing, so it
    ///      can only rule out prints nobody had seen when the claim was filed.
    function _handleTerminationResolution(bytes32 assertionId, bool assertedTruthfully) internal {
        TerminationProposal storage proposal = terminationProposals[assertionId];
        if (proposal.proposer == address(0)) revert BazaarPairTerminator__UnknownAssertion();
        if (proposal.resolved) revert BazaarPairTerminator__AlreadyResolved();
        proposal.resolved = true;

        InsurerTerminationProposal storage vote = insurerProposals[assertionId];
        if (!assertedTruthfully) {
            vote.verdict = VERDICT_FALSE;
            if (!vote.resolved) {
                vote.resolved = true;
                emit InsurerTerminationRejected(proposal.pair, assertionId);
            }
            emit TerminationProposalRejected(proposal.pair, assertionId);
            return;
        }
        vote.verdict = VERDICT_TRUE;

        IBazaarPair p = IBazaarPair(proposal.pair);
        // The vote on this claim holds the pair's cutoff, which is this claim's own: the verdict is
        // what the settlement was waiting for, and the schedule needs nothing else. Recorded as the
        // acceptance in force, with its cutoff as the cap, so a later claim must beat it too, and
        // with the moment it was recorded, from which a disputed claim's grace counts
        // (_verdictKnownTs).
        if (insurerScheduleId[proposal.pair] == assertionId && p.settlementPriceFixedTs() == 0) {
            acceptedTerminationAssertionId[proposal.pair] = assertionId;
            umaCutoffCap[proposal.pair] = proposal.lastTradingTs;
            verdictRecordedTs[assertionId] = block.timestamp;
            emit TerminationProposalAccepted(proposal.pair, assertionId, proposal.lastTradingTs);
            return;
        }
        // The cutoff the pair will store: a proposed cutoff sooner than MIN_CUTOFF_LEAD from now
        // lands that far out, since the market traded at live prices while the window's print
        // was public, or a trade sequenced ahead of this call could see it (see
        // BazaarPair.setScheduledTermination, which applies the same floor).
        uint256 earliest = block.timestamp + BazaarTypes.MIN_CUTOFF_LEAD;
        uint256 cutoffTs = proposal.lastTradingTs > earliest ? proposal.lastTradingTs : earliest;
        // A fixed price ends the pair, and a cutoff that does not beat the UMA cutoff in force
        // changes nothing.
        (bool umaCutoffSet, uint256 umaCutoff) = _umaCutoffInForce(proposal.pair, p);
        if ((!umaCutoffSet || cutoffTs < umaCutoff) && p.settlementPriceFixedTs() == 0) {
            // The pair may already carry a cutoff: a UMA one, or an insurer one voted ahead of
            // time. A verified cutoff EARLIER than it pulls it in. For an insurer schedule this is
            // what keeps a 60% coalition from parking a late cutoff that no other path can
            // correct, which would let the market trade through the event UMA just confirmed;
            // from then on the cutoff is UMA's, and settles under UMA's rules (the precise tick,
            // the grace, the stored-price fallback). A pair that refuses the schedule for any
            // other reason is reported rather than allowed to revert this callback, which would
            // brick the UMA settle and lock the bond. Every refusal the pair can raise carries a
            // custom error; a revert with no data is the call running out of gas, which is
            // re-raised so the settle fails whole and can be retried with more, instead of
            // consuming the assertion with the pair unscheduled. The pair pays the listing bounty
            // once, to the first acceptance that schedules it: a pull-in after a scheduling
            // acceptance earns nothing, while one after an acceptance that only capped an
            // insurer schedule is the first to schedule the pair, and earns it. The cap is
            // cleared because the pair now settles under UMA's rule, which never reads it.
            uint256 existing = p.scheduledTerminationTs();
            if (existing == 0 || cutoffTs < existing) {
                try p.setScheduledTermination(cutoffTs, proposal.proposer) {
                    acceptedTerminationAssertionId[proposal.pair] = assertionId;
                    delete insurerScheduleId[proposal.pair];
                    delete umaCutoffCap[proposal.pair];
                    emit TerminationProposalAccepted(proposal.pair, assertionId, cutoffTs);
                } catch (bytes memory reason) {
                    if (reason.length == 0) revert BazaarPairTerminator__ScheduleOutOfGas();
                    emit TerminationScheduleRefused(proposal.pair, assertionId);
                }
                return;
            }
            // A verified cutoff at or after an insurer schedule leaves that schedule in place,
            // since the pair never moves a cutoff later, and caps its chain instead
            // (umaCutoffCap): every sample must be published no later than the cutoff UMA
            // verified. Without the cap, a coalition that voted its cutoff in while the UMA
            // proposal sat in liveness would settle the pair at prints published after the cutoff
            // UMA verified. The cap is the proposed cutoff itself, not MIN_CUTOFF_LEAD past a late
            // acceptance: the pair has not traded since the insurer cutoff, so the floor that
            // keeps a late acceptance from halting the pair in the past protects nothing here, and
            // a cap that moved with the moment the claim is settled would let whoever settles it
            // decide, with the chain's first samples in sight, whether the rest may still count. A
            // proposed cutoff before the insurer cutoff caps nothing: the pair traded through that
            // event before it halted, so no price on the near side of it is left to keep, and the
            // acceptance is superseded. The cutoff beat the UMA cutoff in force, so the cap only
            // ever tightens. The listing bounty is not paid on this path; the pair pays it only
            // when it schedules. Any schedule at or before the cutoff that is not an insurer's is
            // UMA's own, which the cutoff already beat, so the pull-in above has covered it.
            if (insurerScheduleId[proposal.pair] != bytes32(0) && proposal.lastTradingTs >= existing) {
                acceptedTerminationAssertionId[proposal.pair] = assertionId;
                umaCutoffCap[proposal.pair] = proposal.lastTradingTs;
                emit TerminationProposalAccepted(proposal.pair, assertionId, proposal.lastTradingTs);
                return;
            }
        }
        emit TerminationProposalSuperseded(proposal.pair, assertionId);
    }

    /// @dev The UMA cutoff in force on `pair`, and whether there is one: there is none until a UMA
    ///      proposal is accepted. It is a flag rather than a sentinel timestamp because every
    ///      value up to type(uint256).max is a cutoff a proposal may name. While an insurer vote
    ///      holds the schedule, umaCutoffCap holds the UMA cutoff that schedule met; otherwise the
    ///      pair's schedule is UMA's own. A price fix also stamps a schedule, and both callers
    ///      refuse a fixed pair before relying on this.
    function _umaCutoffInForce(address pair, IBazaarPair p) internal view returns (bool set, uint256 umaCutoff) {
        if (acceptedTerminationAssertionId[pair] == bytes32(0)) return (false, 0);
        return (true, insurerScheduled(pair) ? umaCutoffCap[pair] : p.scheduledTerminationTs());
    }

    // ========================================================
    //  Insurer-vote pair termination
    // ========================================================

    /// @notice How long before a proposal's cutoff its voting and its latch close. The print at the
    ///         cutoff is unknowable this far ahead, so neither the proposer nor whoever schedules
    ///         the pair can pick the settlement price; it is also the notice every trader gets.
    uint256 internal constant INSURER_TERMINATION_LATCH_LEAD = 1 hours;
    /// @notice Earliest a cutoff may sit after the proposal that names it, for a bare proposal and
    ///         a UMA termination claim alike. It exceeds INSURER_TERMINATION_LATCH_LEAD by the
    ///         shortest voting window a proposal gets: a cutoff only the latch lead away would
    ///         close the vote in the proposal's own second, so only a single holder of the
    ///         threshold could ever pass it.
    uint256 internal constant INSURER_TERMINATION_MIN_LEAD = 2 hours;
    /// @notice The vote window: votes on a proposal open this long before its cutoff, or at the
    ///         proposal when that is later, and a bare proposal's cutoff may sit no further out.
    ///         Bounds how long voted shares stay locked and how long an unresolved bond can sit
    ///         here. Also what keeps the pair's deposit-lot pruning honest: a lot too young to vote
    ///         on a proposal is younger than INSURER_LOT_RETENTION_PERIOD for the whole vote.
    uint256 internal constant INSURER_TERMINATION_MAX_LEAD = 14 days;
    uint256 internal constant INSURER_TERMINATION_THRESHOLD_BP = 6_000; // 60%
    /// @notice The bond a bare proposal posts, held here until the proposal resolves: the same
    ///         figure as the UMA termination bond's floor, TERMINATION_PROPOSAL_BOND.
    uint256 internal constant INSURER_TERMINATION_BOND_USDC = TERMINATION_PROPOSAL_BOND;
    uint256 internal constant BP_SCALE_INSURER = BazaarTypes.BP_SCALE;
    /// @notice Shares must be held for this duration before they can vote on an insurer
    ///         termination proposal. Prevents "deposit then snipe" attacks where an attacker
    ///         acquires majority and proposes in the same window.
    uint256 internal constant INSURER_SHARE_MATURITY_PERIOD = 4 days;
    /// @notice Most live proposals one voter may hold votes on at once. Bounds the walk
    ///         getLockedShares does inside every insurance withdrawal.
    uint256 internal constant INSURER_MAX_LIVE_VOTES = 8;
    /// @notice The share of a yes-voter's stake forfeited at redemption when the vote's claim
    ///         resolves FALSE. An unjudged outcome, a bare vote or a claim with no verdict in
    ///         time, forfeits this share scaled by the dissent fraction, the part of the snapshot
    ///         that did not vote yes, so a bare 60% pays a fifth, and never less than
    ///         INSURER_LEVY_FLOOR_BP. The flat rate exceeds the scaled one at every consensus
    ///         level, so filing a claim the proposer expects to fail is never cheaper than filing
    ///         none.
    uint256 internal constant INSURER_LEVY_BP = 5_000; // 50%
    /// @notice The least an unjudged outcome forfeits of every yes-voted share. The dissent
    ///         scaling alone would let a holder of the whole fund end a market for nothing but the
    ///         post-fix lock; the floor is the base price of ending a market with no judge, which
    ///         only a claim UMA upholds escapes. A bare 60% still pays the scaled fifth; the floor
    ///         binds from 80% of the snapshot up.
    uint256 internal constant INSURER_LEVY_FLOOR_BP = 1_000; // 10%
    /// @notice How long after a claim is filed its vote-scheduled pair waits for the verdict before
    ///         settling unjudged. Sized like BazaarFactory.DVM_DISPUTE_GRACE: a dispute filed in
    ///         the last second of liveness can take the DVM up to 12 days, and past that UMA
    ///         deletes the request, so a verdict that has not arrived by then is not coming.
    uint256 internal constant CLAIM_VERDICT_GRACE = 14 days;
    /// @notice How long after the price fix the yes-voters of a costed vote stay locked: the
    ///         withdrawal cooldown a redemption on the live pair would have served, so ending the
    ///         pair is never a faster exit than leaving it.
    uint256 internal constant INSURER_POST_FIX_LOCK = InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN;
    /// @dev BazaarPair storage slot of `shareEpoch`, read through `extsload` because the pair has
    ///      no getter for it (a public one would cost the pair's EIP-170 budget). From
    ///      `forge inspect BazaarPair storage-layout`; every pair is a clone of one
    ///      implementation, so it holds for every pair, and a layout change needs it re-read. The
    ///      insurer-vote epoch tests pin it against the pair's own recap behaviour.
    uint256 internal constant PAIR_SLOT_SHARE_EPOCH = 92;

    /// @notice A claim-backed vote's UMA verdict: none yet, TRUE, or FALSE.
    uint8 public constant VERDICT_PENDING = 0;
    uint8 public constant VERDICT_TRUE = 1;
    uint8 public constant VERDICT_FALSE = 2;
    /// @notice What a vote-scheduled pair settled under, stamped when its price is fixed: nothing
    ///         yet, a claim UMA upheld, a claim UMA rejected, or no verdict at all (a bare vote, or
    ///         a claim with no verdict by CLAIM_VERDICT_GRACE).
    uint8 public constant OUTCOME_NONE = 0;
    uint8 public constant OUTCOME_TRUE = 1;
    uint8 public constant OUTCOME_FALSE = 2;
    uint8 public constant OUTCOME_UNJUDGED = 3;

    /// @notice One insurer-termination proposal, keyed by id: a UMA termination claim's assertion
    ///         id, since every claim opens a vote the moment it is filed, or the hash of (pair,
    ///         proposer, timestamp) for a bare proposal, which names a cutoff with no claim behind
    ///         it. Proposals are independent: any number may be live on a pair at once, and one
    ///         that never reaches the threshold blocks nothing. Voting runs from `windowOpenTs`
    ///         until the latch deadline, INSURER_TERMINATION_LATCH_LEAD before the cutoff; the
    ///         proposal schedules the pair the moment the threshold is met, and expires if the
    ///         deadline arrives first.
    struct InsurerTerminationProposal {
        address pair;
        address proposer; // the bare proposer owed the bond, or the claim's UMA proposer
        uint64 proposalTs; // when the proposal was filed
        uint64 shareEpoch; // the pair's share generation at the snapshot; see _insurerEpochCurrent
        uint256 cutoffTs; // trading cutoff the proposal asks for; votes and the latch close LATCH_LEAD before it
        uint256 windowOpenTs; // when voting opens: INSURER_TERMINATION_MAX_LEAD before the cutoff, or the filing
        uint256 yesShares; // sum of locked yes-voted shares
        uint256 snapshotTotalShares; // the frozen denominator; see _takeSnapshot
        bool snapshotTaken; // the snapshot is taken at the first touch with the window open
        bool claimBacked; // the id is a UMA assertion id and UMA holds the bond
        bool resolved; // true once the vote is over (scheduled, failed, preempted, voided, or its claim rejected)
        bool scheduled; // true if this proposal scheduled the pair
        bool costed; // stamped at the fix: the yes-voters owe the post-fix lock and the levy
        uint8 verdict; // claim-backed only: VERDICT_PENDING, VERDICT_TRUE or VERDICT_FALSE
        uint8 outcome; // stamped at the fix of a pair this proposal scheduled: OUTCOME_*
        uint16 levyBp; // stamped with the outcome: the share of each yes-voted share forfeited at redemption
    }

    /// @notice One voter's stake in one proposal.
    struct InsurerVote {
        bytes32 id;
        uint256 amount;
    }

    /// @notice id => the proposal.
    mapping(bytes32 => InsurerTerminationProposal) public insurerProposals;
    /// @notice pair => voter => the voter's records on live proposals, at most
    ///         INSURER_MAX_LIVE_VOTES long; dead records are dropped as votes are cast.
    mapping(address => mapping(address => InsurerVote[])) internal insurerVotes;
    /// @notice pair => the proposal whose vote holds the pair's cutoff, zero while no vote does.
    ///         While set, terminateScheduledPair stamps that proposal's outcome and settles under
    ///         it: a claim UMA upheld settles under UMA's own rule at the cutoff, anything else
    ///         under the chain rule, every sample published no later than umaCutoffCap when that
    ///         is set, with the stored price as a last resort only once the cutoff is
    ///         ORACLE_DEAD_THRESHOLD old or the capping UMA cutoff is SCHEDULED_TERMINATION_GRACE
    ///         old. Cleared when a verified UMA cutoff pulls the schedule earlier, since that
    ///         cutoff settles under UMA's rules.
    mapping(address => bytes32) public insurerScheduleId;
    /// @notice The latest publish time any sample of a chain-rule settlement may carry: the cutoff
    ///         of a UMA termination accepted for the pair. It is recorded where
    ///         the two schedules meet, whichever comes second: a vote that pulls a UMA schedule
    ///         earlier records that schedule, and a UMA acceptance at or after an insurer schedule
    ///         records its own cutoff, which must beat any cap already recorded, so the cap only
    ///         ever tightens. Zero while the pair's insurer schedule has met none, the samples
    ///         then being unbounded, and cleared when a verified UMA cutoff pulls
    ///         the schedule in, since the pair then settles under UMA's rule. A vote that met a
    ///         verified cutoff within INSURER_TERMINATION_MAX_LEAD of its own is not costed: UMA has
    ///         confirmed the event it moved the halt ahead of (_metNearVerifiedCutoff).
    /// @dev The earlier insurer cutoff halts trading either way; the cap keeps the settlement on
    ///      the near side of the cutoff UMA verified. UMA has verified an event the market can see
    ///      coming, so the reopen print after it can carry a move whose direction was public when
    ///      the insurer cutoff was voted, and a coalition that voted one into the closed session
    ///      ahead of the event would settle the pair at that print rather than at the stored
    ///      pre-event price UMA's own rule falls back to.
    mapping(address => uint256) public umaCutoffCap;
    /// @dev claim id => when the claim's TRUE verdict was recorded while its own vote held the
    ///      pair's cutoff, zero if it never was. For a disputed claim this is when its verdict is
    ///      taken to be known, and the grace of UMA's rule counts from it when that is later than
    ///      the cutoff (_verdictKnownTs).
    mapping(bytes32 => uint256) internal verdictRecordedTs;

    /// @notice True while the pair's cutoff is one an insurer vote set.
    function insurerScheduled(address pair) public view returns (bool) {
        return insurerScheduleId[pair] != bytes32(0);
    }

    // Every insurer event names its proposal by id, so each log stands alone.
    event InsurerTerminationProposed(
        address indexed pair,
        bytes32 indexed id,
        address indexed proposer,
        uint256 cutoffTs,
        uint256 windowOpenTs,
        bool claimBacked
    );
    /// @notice The proposal's denominator was frozen: the pair's live share supply, less the
    ///         orphan shares at address(0), in share generation `shareEpoch`.
    event InsurerTerminationSnapshot(
        address indexed pair, bytes32 indexed id, uint256 snapshotTotalShares, uint64 shareEpoch
    );
    event InsurerTerminationVoted(
        address indexed pair, bytes32 indexed id, address indexed voter, uint256 amount, uint256 totalYesShares
    );
    /// @notice The proposal reached its threshold and the pair is now scheduled to stop trading
    ///         at `cutoffTs`; a bare proposal's bond went back to the proposer, or to the pair's
    ///         insurance fund if they could not receive it.
    event InsurerTerminationScheduled(
        address indexed pair, bytes32 indexed id, uint256 cutoffTs, uint256 yesShares, uint256 totalShares
    );
    /// @notice The proposal's latch deadline passed without it scheduling the pair.
    ///         `thresholdMet` reports whether consensus was reached anyway (a bare bond refunded)
    ///         or not (a bare bond forfeited to the pair's insurance fund).
    event InsurerTerminationFailed(
        address indexed pair,
        bytes32 indexed id,
        uint256 cutoffTs,
        uint256 yesShares,
        uint256 totalShares,
        bool thresholdMet
    );
    event InsurerTerminationBondRefundFailed(
        address indexed pair, bytes32 indexed id, address proposer, uint256 amount
    );
    /// @notice Emitted when a proposal is resolved because the pair is already headed for a
    ///         cutoff no later than the one it asked for: its price fixed by another path, or a
    ///         schedule at or before its cutoff already in place. A bare bond is refunded (not
    ///         forfeited) and the pair's schedule is untouched.
    event InsurerTerminationPreempted(address indexed pair, bytes32 indexed id);
    /// @notice Emitted when a proposal is resolved because the insurance fund was drained and
    ///         recapitalized after its snapshot: its votes and snapshot belong to a generation of
    ///         shares that no longer exists. A bare bond is refunded and the pair is left alone.
    event InsurerTerminationVoided(address indexed pair, bytes32 indexed id);
    /// @notice The claim behind the proposal resolved FALSE before the vote scheduled the pair:
    ///         the vote is over and its votes lock nothing further.
    event InsurerTerminationRejected(address indexed pair, bytes32 indexed id);
    /// @notice The pair's settlement price is being fixed under the proposal that scheduled it.
    ///         `outcome` is one of OUTCOME_TRUE, OUTCOME_FALSE and OUTCOME_UNJUDGED; `costed`
    ///         says whether the yes-voters owe the post-fix lock, and `levyBp` the share of each
    ///         yes-voted share they forfeit at redemption.
    event InsurerTerminationOutcome(
        address indexed pair, bytes32 indexed id, uint8 outcome, bool costed, uint16 levyBp
    );
    /// @notice A yes-voter's redemption drew on `votedShares` of their voted stake and forfeited
    ///         `levyShares` of them to `recipient`, the factory's bug bounty address.
    event InsurerLevyCharged(
        address indexed pair,
        bytes32 indexed id,
        address indexed voter,
        uint256 votedShares,
        uint256 levyShares,
        address recipient
    );

    error BazaarPairTerminator__InsurerActiveProposal();
    error BazaarPairTerminator__InsurerCutoffTooSoon(uint64 cutoffTs, uint64 minCutoffTs);
    error BazaarPairTerminator__InsurerCutoffTooLate(uint64 cutoffTs, uint64 maxCutoffTs);
    error BazaarPairTerminator__InsurerCutoffNotEarlier(uint256 scheduledTs);
    error BazaarPairTerminator__InsurerNoMatureShares();
    error BazaarPairTerminator__InsurerNoActiveProposal();
    error BazaarPairTerminator__InsurerVoteNotOpen(uint256 windowOpenTs);
    error BazaarPairTerminator__InsurerVotingClosed();
    error BazaarPairTerminator__InsurerThresholdNotMet(uint256 yesShares, uint256 required);
    error BazaarPairTerminator__InsurerInsufficientUnlockedShares(uint256 unlocked, uint256 requested);
    error BazaarPairTerminator__InsurerZeroVoteAmount();
    error BazaarPairTerminator__InsurerTooManyLiveVotes(uint256 max);
    error BazaarPairTerminator__InsurerVerdictPending(uint256 deadline);
    error BazaarPairTerminator__OnlyPair();

    /// @notice Propose that the pair stop trading at `cutoffTs` with no UMA claim behind it. Any
    ///         insurer whose shares are mature enough to vote on the proposal can file one,
    ///         posting a 1,000 USDC bond that is returned if the vote reaches the threshold and
    ///         forfeited to the pair's insurance fund if it does not. A vote with no claim settles
    ///         unjudged: its yes-voters stay locked through the withdrawal cooldown after the fix
    ///         and forfeit INSURER_LEVY_BP of the dissent fraction of their voted stake at
    ///         redemption. A claim UMA can judge is filed through proposeTermination, which opens
    ///         its vote itself.
    /// @dev The cutoff is bounded on both sides: at least INSURER_TERMINATION_MIN_LEAD out, which
    ///      leaves the vote a window before its latch deadline and keeps the price there
    ///      unknowable both when the proposal is filed and when it is scheduled (never later than
    ///      INSURER_TERMINATION_LATCH_LEAD before the cutoff); and at most
    ///      INSURER_TERMINATION_MAX_LEAD out so locked votes and unresolved bonds are bounded. A
    ///      cutoff at or after one the pair already carries could never take effect, so it is
    ///      refused up front rather than left to forfeit a bond. The id hashes the filing second,
    ///      so a second proposal by the same address in the same second is refused: consecutive
    ///      Arbitrum blocks share timestamps, and two records under one id would merge their
    ///      votes.
    /// @param pair The pair to terminate
    /// @param cutoffTs Trading cutoff; the vote must reach the threshold and be executed at least
    ///        INSURER_TERMINATION_LATCH_LEAD before it
    /// @return id The proposal's id, which votes and the execute call name
    function proposeInsurerTermination(address pair, uint64 cutoffTs) external nonReentrant returns (bytes32 id) {
        if (!_registeredPairs.contains(pair)) revert BazaarPairTerminator__PairNotRegistered();
        IBazaarPair p = IBazaarPair(pair);
        if (p.settlementPriceFixedTs() != 0) {
            revert BazaarPairTerminator__AlreadyTerminated();
        }

        uint64 ts = uint64(block.timestamp);
        uint64 minCutoff = ts + uint64(INSURER_TERMINATION_MIN_LEAD);
        uint64 maxCutoff = ts + uint64(INSURER_TERMINATION_MAX_LEAD);
        if (cutoffTs < minCutoff) revert BazaarPairTerminator__InsurerCutoffTooSoon(cutoffTs, minCutoff);
        if (cutoffTs > maxCutoff) revert BazaarPairTerminator__InsurerCutoffTooLate(cutoffTs, maxCutoff);
        uint256 existing = p.scheduledTerminationTs();
        if (existing != 0 && existing <= cutoffTs) revert BazaarPairTerminator__InsurerCutoffNotEarlier(existing);

        id = keccak256(abi.encode(pair, msg.sender, ts));
        if (insurerProposals[id].proposalTs != 0) revert BazaarPairTerminator__InsurerActiveProposal();

        // The proposer is held to the same maturity cutoff the vote applies to this proposal:
        // shares younger than INSURER_SHARE_MATURITY_PERIOD can neither vote nor open the vote.
        if (p.getSharesAsOf(msg.sender, _insurerMaturityCutoff(ts)) == 0) {
            revert BazaarPairTerminator__InsurerNoMatureShares();
        }

        IERC20(address(_bondToken())).safeTransferFrom(msg.sender, address(this), INSURER_TERMINATION_BOND_USDC);
        _openInsurerProposal(id, pair, msg.sender, cutoffTs, false);
    }

    /// @dev Records a proposal and opens its vote. The window opens INSURER_TERMINATION_MAX_LEAD
    ///      before the cutoff, or now when the cutoff is nearer than that; a bare proposal's always
    ///      opens now. The snapshot is taken at once when the window is open and otherwise at the
    ///      first vote, so a claim whose cutoff lies months out is counted against the supply of
    ///      the fortnight before it, not the supply the day it was filed.
    function _openInsurerProposal(bytes32 id, address pair, address proposer, uint256 cutoffTs, bool claimBacked)
        internal
    {
        uint256 windowOpenTs = block.timestamp;
        if (cutoffTs > INSURER_TERMINATION_MAX_LEAD && cutoffTs - INSURER_TERMINATION_MAX_LEAD > windowOpenTs) {
            windowOpenTs = cutoffTs - INSURER_TERMINATION_MAX_LEAD;
        }
        InsurerTerminationProposal storage prop = insurerProposals[id];
        prop.pair = pair;
        prop.proposer = proposer;
        prop.proposalTs = uint64(block.timestamp);
        prop.cutoffTs = cutoffTs;
        prop.windowOpenTs = windowOpenTs;
        prop.claimBacked = claimBacked;
        emit InsurerTerminationProposed(pair, id, proposer, cutoffTs, windowOpenTs, claimBacked);
        if (windowOpenTs == block.timestamp) _takeSnapshot(id, prop, IBazaarPair(pair));
    }

    /// @dev Freezes the proposal's denominator for the 60% threshold, so deposits made after it
    ///      can neither dilute the vote nor, being too young to vote, be counted against it. The
    ///      permanently locked orphan shares at address(0) (minted by InsuranceVaultLib when
    ///      recapitalizing an LP-less fund) are excluded: they can never vote, so
    ///      counting them could deadlock the threshold. The share generation is recorded with it;
    ///      see _insurerEpochCurrent.
    function _takeSnapshot(bytes32 id, InsurerTerminationProposal storage prop, IBazaarPair p) internal {
        uint256 snapshot = p.totalInsuranceShares() - p.insuranceShares(address(0));
        uint256 epoch = _pairShareEpoch(p);
        prop.snapshotTotalShares = snapshot;
        prop.shareEpoch = uint64(epoch);
        prop.snapshotTaken = true;
        emit InsurerTerminationSnapshot(prop.pair, id, snapshot, uint64(epoch));
    }

    /// @notice Vote yes on proposal `id` by locking `amount` shares. Locked shares cannot be
    ///         withdrawn from the insurance fund until the proposal fails, or until the pair's
    ///         cutoff arrives; the yes-voters of the proposal that schedules the pair stay locked
    ///         INSURER_POST_FIX_LOCK after its price is fixed unless UMA upheld the claim behind it
    ///         (getLockedShares). A voter may back several proposals with the same shares, each is a
    ///         separate cutoff they find acceptable, which is why votes are never withdrawn:
    ///         nothing has to be moved to support a different cutoff.
    /// @dev Voting opens at the proposal's window and closes at the latch deadline,
    ///      INSURER_TERMINATION_LATCH_LEAD before the cutoff, because a vote that lands later
    ///      could no longer schedule anything. Eligible shares are the voter's currently held
    ///      shares deposited at or before INSURER_SHARE_MATURITY_PERIOD before the window opened:
    ///      a deposit made inside the window, before or after the proposal, does not vote. No vote
    ///      lands once the pair's price is fixed, so the records of the proposal that scheduled it
    ///      stay where the post-fix lock and the levy read them. A proposal from a wiped share
    ///      generation is no longer active (see _insurerEpochCurrent).
    /// @param pair The pair
    /// @param id The proposal's id, as emitted in InsurerTerminationProposed
    /// @param amount Shares to add to the yes count
    function voteForInsurerTermination(address pair, bytes32 id, uint256 amount) external nonReentrant {
        if (amount == 0) revert BazaarPairTerminator__InsurerZeroVoteAmount();
        InsurerTerminationProposal storage prop = insurerProposals[id];
        if (prop.proposalTs == 0 || prop.pair != pair || prop.resolved) {
            revert BazaarPairTerminator__InsurerNoActiveProposal();
        }
        if (block.timestamp < prop.windowOpenTs) revert BazaarPairTerminator__InsurerVoteNotOpen(prop.windowOpenTs);
        if (block.timestamp + INSURER_TERMINATION_LATCH_LEAD > prop.cutoffTs) {
            revert BazaarPairTerminator__InsurerVotingClosed();
        }
        IBazaarPair p = IBazaarPair(pair);
        if (p.settlementPriceFixedTs() != 0) revert BazaarPairTerminator__InsurerNoActiveProposal();
        if (!prop.snapshotTaken) _takeSnapshot(id, prop, p);
        uint256 epoch = _pairShareEpoch(p);
        if (!_insurerEpochCurrent(prop, epoch)) revert BazaarPairTerminator__InsurerNoActiveProposal();

        InsurerVote[] storage votes = insurerVotes[pair][msg.sender];
        uint256 idx = _pruneAndFindVote(pair, votes, id, p.scheduledTerminationTs(), epoch);
        if (idx == votes.length) {
            if (votes.length >= INSURER_MAX_LIVE_VOTES) {
                revert BazaarPairTerminator__InsurerTooManyLiveVotes(INSURER_MAX_LIVE_VOTES);
            }
            votes.push(InsurerVote({id: id, amount: 0}));
        }
        InsurerVote storage vote = votes[idx];

        // windowOpenTs is at most block.timestamp here, so the narrowing cast is exact.
        uint256 eligibleShares = p.getSharesAsOf(msg.sender, _insurerMaturityCutoff(uint64(prop.windowOpenTs)));
        uint256 unlocked = eligibleShares > vote.amount ? eligibleShares - vote.amount : 0;
        if (amount > unlocked) {
            revert BazaarPairTerminator__InsurerInsufficientUnlockedShares(unlocked, amount);
        }
        vote.amount += amount;
        prop.yesShares += amount;

        emit InsurerTerminationVoted(pair, id, msg.sender, amount, prop.yesShares);
    }

    /// @dev Maturity cutoff for a vote whose window opened at `windowOpenTs`: shares deposited at
    ///      or before it are eligible, younger ones are not. Shared by the bare proposal's
    ///      proposer gate and the vote so the proposer is held to exactly the rule their
    ///      proposal's voters are.
    function _insurerMaturityCutoff(uint64 windowOpenTs) internal pure returns (uint64) {
        return
            windowOpenTs > uint64(INSURER_SHARE_MATURITY_PERIOD)
                ? windowOpenTs - uint64(INSURER_SHARE_MATURITY_PERIOD)
                : 0;
    }

    /// @notice Resolve proposal `id`. Anyone may call it.
    ///         - Before the latch deadline (INSURER_TERMINATION_LATCH_LEAD before the cutoff) with
    ///           the threshold met: the pair is scheduled to stop trading at the cutoff (or its
    ///           existing schedule is pulled earlier to it) and a bare bond is refunded. From then
    ///           on the pair is settled through terminateScheduledPair, which stamps the
    ///           proposal's outcome: a claim UMA upholds settles under UMA's rule at the cutoff,
    ///           anything else under the chain rule from it.
    ///         - Before the latch deadline without the threshold: reverts; voting is still open.
    ///         - At or after the latch deadline, never scheduled: a bare bond is refunded if the
    ///           threshold was met (consensus was real) and forfeited to the pair's insurance fund
    ///           otherwise; the pair is left alone either way.
    ///         - The pair's price already fixed, or a schedule at or before this cutoff already
    ///           in place: preempted, a bare bond refunded, nothing changes.
    ///         - The insurance fund drained and recapitalized since the snapshot: voided, a bare
    ///           bond refunded, nothing changes.
    ///         A claim-backed proposal's bond is UMA's to settle, so none of these moves one.
    /// @dev The latch deadline is what makes the cutoff print unknowable when the pair is
    ///      scheduled. Latching is voluntary and declining it costs nothing (a passed proposal's
    ///      bond comes back either way), so if the latch were allowed up to the cutoff a
    ///      coalition could file staggered proposals, vote them all, and at each cutoff decide
    ///      with the print in sight whether to settle, a free option on the fund's inventory.
    ///      Holding the latch a full latch lead ahead of the cutoff leaves nothing to look at.
    ///
    ///      The preempted refund is unconditional rather than threshold-based: this is the only
    ///      function that releases a bare bond, and a proposal cannot be deemed frivolous when
    ///      the pair did in fact wind down. Every fixing path stamps the price latch first, so
    ///      the latch is the whole "already fixed" check. A schedule the vote pulls in that no
    ///      vote set is UMA's, and the cutoff UMA verified caps the settlement print of the
    ///      earlier one this vote sets (umaCutoffCap).
    /// @param pair The pair
    /// @param id The proposal to resolve
    function executeInsurerTermination(address pair, bytes32 id) external nonReentrant {
        InsurerTerminationProposal storage prop = insurerProposals[id];
        if (prop.proposalTs == 0 || prop.pair != pair || prop.resolved) {
            revert BazaarPairTerminator__InsurerNoActiveProposal();
        }

        IBazaarPair p = IBazaarPair(pair);
        if (p.settlementPriceFixedTs() != 0) {
            prop.resolved = true;
            _releaseInsurerBond(id, prop, true);
            emit InsurerTerminationPreempted(pair, id);
            return;
        }

        if (prop.snapshotTaken && !_insurerEpochCurrent(prop, _pairShareEpoch(p))) {
            _voidInsurerProposal(id, prop);
            return;
        }

        if (block.timestamp + INSURER_TERMINATION_LATCH_LEAD > prop.cutoffTs) {
            _resolveExpiredInsurerProposal(id, prop);
            return;
        }

        uint256 required = _insurerThresholdShares(prop);
        if (!prop.snapshotTaken || prop.snapshotTotalShares == 0 || prop.yesShares < required) {
            revert BazaarPairTerminator__InsurerThresholdNotMet(prop.yesShares, required);
        }

        prop.resolved = true;
        uint256 existing = p.scheduledTerminationTs();
        if (existing != 0 && existing <= prop.cutoffTs) {
            _releaseInsurerBond(id, prop, true);
            emit InsurerTerminationPreempted(pair, id);
            return;
        }

        prop.scheduled = true;
        if (existing != 0 && insurerScheduleId[pair] == bytes32(0)) umaCutoffCap[pair] = existing;
        insurerScheduleId[pair] = id;
        p.setScheduledTermination(prop.cutoffTs, address(0));
        _releaseInsurerBond(id, prop, true);
        emit InsurerTerminationScheduled(pair, id, prop.cutoffTs, prop.yesShares, prop.snapshotTotalShares);
    }

    /// @dev Yes-shares needed to meet the threshold against the snapshot.
    function _insurerThresholdShares(InsurerTerminationProposal storage prop) internal view returns (uint256) {
        return prop.snapshotTotalShares * INSURER_TERMINATION_THRESHOLD_BP / BP_SCALE_INSURER;
    }

    /// @dev True when the proposal's yes-voted shares meet the 60% threshold of its snapshot.
    function _insurerThresholdMet(InsurerTerminationProposal storage prop) internal view returns (bool) {
        return prop.snapshotTaken && prop.snapshotTotalShares > 0 && prop.yesShares >= _insurerThresholdShares(prop);
    }

    /// @dev Single home for releasing a bare proposal's bond, shared by every resolution path
    ///      (scheduled, expired, preempted, voided). A claim-backed proposal holds no bond here:
    ///      UMA settles the claim's. `refundProposer` = true refunds the proposer, soft-failing
    ///      into the insurance route if they can't receive USDC (e.g., blacklisted): resolution
    ///      must never be blockable by an unreachable refund target. Otherwise (or on that
    ///      soft-fail) the bond is transferred to the pair and credited to its insurance
    ///      bookkeeping so the fund stays fully backed.
    function _releaseInsurerBond(bytes32 id, InsurerTerminationProposal storage prop, bool refundProposer) internal {
        if (prop.claimBacked) return;
        if (refundProposer && _tryRefundBond(prop.proposer, INSURER_TERMINATION_BOND_USDC)) return;

        IERC20(address(_bondToken())).safeTransfer(prop.pair, INSURER_TERMINATION_BOND_USDC);
        uint256 bondBazaar = INSURER_TERMINATION_BOND_USDC * (BazaarTypes.BAZAAR_SCALE / 1e6);
        IBazaarPair(prop.pair).creditInsurance(bondBazaar);
        if (refundProposer) {
            emit InsurerTerminationBondRefundFailed(prop.pair, id, prop.proposer, INSURER_TERMINATION_BOND_USDC);
        }
    }

    /// @dev Resolves a proposal whose latch deadline passed without it scheduling the pair:
    ///      consensus reached, a bare bond is refunded, otherwise forfeited to the pair's
    ///      insurance fund. Never schedules the pair: the latch is closed by construction.
    function _resolveExpiredInsurerProposal(bytes32 id, InsurerTerminationProposal storage prop) internal {
        prop.resolved = true;
        bool thresholdMet = _insurerThresholdMet(prop);
        _releaseInsurerBond(id, prop, thresholdMet);
        emit InsurerTerminationFailed(
            prop.pair, id, prop.cutoffTs, prop.yesShares, prop.snapshotTotalShares, thresholdMet
        );
    }

    /// @dev True while the pair's share generation is the one `prop` took its snapshot in. A
    ///      drained-fund recap wipes every balance and starts a new generation; a proposal from
    ///      the old one then counts votes and a snapshot of shares that no longer exist, while the
    ///      new owners' shares are too young to vote on it. Such a proposal is dead: it must not
    ///      be scheduled by holders who own nothing, and its votes must not lock anything.
    ///      Compared at full width, so a stored value truncated from an epoch past 2^64 never
    ///      matches: the proposal voids rather than revives.
    function _insurerEpochCurrent(InsurerTerminationProposal storage prop, uint256 epoch) internal view returns (bool) {
        return uint256(prop.shareEpoch) == epoch;
    }

    /// @dev The pair's current insurance share generation (see PAIR_SLOT_SHARE_EPOCH).
    function _pairShareEpoch(IBazaarPair p) internal view returns (uint256) {
        return uint256(p.extsload(bytes32(PAIR_SLOT_SHARE_EPOCH)));
    }

    /// @dev Resolves a proposal from a wiped share generation. A bare bond is refunded rather
    ///      than judged against the threshold: the vote was ended by the drain, not by the
    ///      insurers, and forfeiting it would hand it to whoever recapitalized the fund.
    function _voidInsurerProposal(bytes32 id, InsurerTerminationProposal storage prop) internal {
        prop.resolved = true;
        _releaseInsurerBond(id, prop, true);
        emit InsurerTerminationVoided(prop.pair, id);
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

    // -------------------- The verdict and the outcome --------------------

    /// @dev keccak256 of the revert reason OOv3 gives a call made while it holds its reentrancy
    ///      lock (UMA's Lockable).
    bytes32 internal constant OO_REENTRANT_CALL = keccak256("ReentrancyGuard: reentrant call");

    /// @dev The verdict of the claim behind a claim-backed vote, settling the assertion itself
    ///      when that is what it is waiting on: a settle reaches this contract's callback, which
    ///      records the verdict. What the settle leaves undecided is read as _peekVerdict reads
    ///      it, and recorded. A settle refused because OOv3 is mid-call is re-raised rather than
    ///      read as no verdict: a caller inside an OOv3 callback would otherwise see a dispute the
    ///      DVM has already ruled on as still pending, and past CLAIM_VERDICT_GRACE settle the pair
    ///      unjudged in place of the verdict.
    function _claimVerdict(bytes32 id, InsurerTerminationProposal storage prop) internal returns (uint8 verdict) {
        if (prop.verdict != VERDICT_PENDING) return prop.verdict;
        try assertionOo[id].settleAndGetAssertionResult(id) returns (bool) {}
        catch Error(string memory reason) {
            if (keccak256(bytes(reason)) == OO_REENTRANT_CALL) revert BazaarPairTerminator__OracleBusy();
        } catch {}
        verdict = _peekVerdict(id, prop);
        prop.verdict = verdict;
    }

    /// @dev The verdict of the claim behind a claim-backed vote as it stands, without settling
    ///      anything: the recorded one, else the assertion's own resolution once settled. An
    ///      assertion that is undisputed and past its liveness is TRUE even while unsettled, since
    ///      that is the only way OOv3 can ever resolve it and only a bricked oracle keeps it from
    ///      doing so; a disputed one reads pending until it is settled on OOv3, even once the DVM
    ///      has ruled. Reading the assertion is itself attempted, so an oracle that cannot even
    ///      answer leaves the verdict pending rather than reverting the caller.
    function _peekVerdict(bytes32 id, InsurerTerminationProposal storage prop) internal view returns (uint8 verdict) {
        verdict = prop.verdict;
        if (verdict != VERDICT_PENDING) return verdict;
        try assertionOo[id].getAssertion(id) returns (IOptimisticOracleV3.Assertion memory a) {
            if (a.settled) return a.settlementResolution ? VERDICT_TRUE : VERDICT_FALSE;
            if (a.disputer == address(0) && block.timestamp >= a.expirationTime) return VERDICT_TRUE;
        } catch {}
    }

    /// @dev Stamps what a vote-scheduled pair settles under, just before its price is fixed, and
    ///      returns whether that is UMA's own rule. A claim UMA upheld costs its voters nothing:
    ///      the event is real, the pre-event price is the honest one, and the lock drops with the
    ///      verdict. A claim UMA rejected forfeits INSURER_LEVY_BP of every yes-voted share. No
    ///      verdict, a bare vote or a claim the DVM never ruled on inside CLAIM_VERDICT_GRACE,
    ///      forfeits that share scaled by the dissent fraction and never less than
    ///      INSURER_LEVY_FLOOR_BP, unless the vote met a cutoff UMA had verified for the pair
    ///      within the vote window of its own (_metNearVerifiedCutoff), which confirms the event
    ///      it moved the halt ahead of. The levy is a share of the voted stake rather than a sum,
    ///      so it needs no price and no pot: the forfeited shares are credited at redemption to
    ///      the factory's bug bounty address, which redeems them like any holder, so the price
    ///      every other holder redeems at is untouched. The post-fix lock follows every costed
    ///      outcome, so a unanimous bare vote still serves the cooldown it bypassed.
    ///      A verdict still pending inside the grace reverts, holding the pair in limbo for it; a
    ///      revert also undoes any settle _claimVerdict made, so the next attempt sees the same
    ///      assertion. The stamp lands in the same transaction as the fix: before the rule's
    ///      stored-price fallback opens, a fetch that fails afterwards reverts the call and rolls
    ///      the stamp back; once the fallback is open, the failed fetch is caught and the stamp
    ///      stands with the stored-price fix.
    function _stampInsurerOutcome(address pair, bytes32 id, InsurerTerminationProposal storage prop)
        internal
        returns (bool umaRule)
    {
        uint8 outcome;
        if (prop.claimBacked) {
            uint8 verdict = _claimVerdict(id, prop);
            if (verdict == VERDICT_PENDING) {
                uint256 deadline = terminationProposals[id].proposalTs + CLAIM_VERDICT_GRACE;
                if (block.timestamp < deadline) revert BazaarPairTerminator__InsurerVerdictPending(deadline);
                outcome = OUTCOME_UNJUDGED;
            } else {
                outcome = verdict == VERDICT_TRUE ? OUTCOME_TRUE : OUTCOME_FALSE;
            }
        } else {
            outcome = OUTCOME_UNJUDGED;
        }

        bool costed;
        uint256 levyBp;
        if (outcome == OUTCOME_FALSE) {
            costed = true;
            levyBp = INSURER_LEVY_BP;
        } else if (outcome == OUTCOME_UNJUDGED && !_metNearVerifiedCutoff(pair, prop.cutoffTs)) {
            costed = true;
            uint256 snapshot = prop.snapshotTotalShares;
            uint256 dissent = snapshot > prop.yesShares ? snapshot - prop.yesShares : 0;
            levyBp = snapshot == 0 ? 0 : INSURER_LEVY_BP * dissent / snapshot;
            if (levyBp < INSURER_LEVY_FLOOR_BP) levyBp = INSURER_LEVY_FLOOR_BP;
        }
        prop.outcome = outcome;
        prop.costed = costed;
        prop.levyBp = uint16(levyBp);
        emit InsurerTerminationOutcome(pair, id, outcome, costed, uint16(levyBp));
        return outcome == OUTCOME_TRUE;
    }

    /// @dev True when the vote's schedule met a cutoff UMA verified that lies within
    ///      INSURER_TERMINATION_MAX_LEAD of the vote's own: UMA has confirmed the event the vote
    ///      moved the halt ahead of, and by no more than the window a vote may act in. A verified
    ///      cutoff months out vouches for nothing about a halt tomorrow, so a vote that pulls a far
    ///      schedule in is costed like one that met no cutoff at all. The cap only ever tightens,
    ///      so the distance read at the fix is the smallest the schedule met.
    function _metNearVerifiedCutoff(address pair, uint256 cutoffTs) internal view returns (bool) {
        uint256 cap = umaCutoffCap[pair];
        return cap != 0 && cap >= cutoffTs && cap - cutoffTs <= INSURER_TERMINATION_MAX_LEAD;
    }

    /// @notice Shares `user` has voted into live proposals on `pair`: the amount the insurance
    ///         withdrawal gate refuses to release. The same shares voted into several proposals
    ///         count once per proposal; the gate compares the sum against the balance, so any
    ///         overlap only ever locks more of it, never less.
    /// @dev Until the pair's settlement price is fixed the lock holds a yes-voter in until the
    ///      settlement they called for. From the fix on, only the proposal whose vote set the
    ///      cutoff the pair settled under can still lock, and only when its outcome was costed:
    ///      its yes-voters then wait INSURER_POST_FIX_LOCK after the fix, the cooldown a
    ///      redemption on the live pair would have served. A pair fixed by any other path, or
    ///      under a claim UMA upheld, locks nothing: a voter into a proposal whose cutoff lies
    ///      weeks out would otherwise stay locked after another path fixed and finalized the
    ///      pair, while every other insurer could already redeem. A record from a wiped share
    ///      generation locks nothing either: the stake it counted is gone, and a re-depositor's
    ///      new shares were never voted.
    function getLockedShares(address pair, address user) external view returns (uint256 locked) {
        IBazaarPair p = IBazaarPair(pair);
        InsurerVote[] storage votes = insurerVotes[pair][user];
        uint256 n = votes.length;
        uint256 fixedTs = p.settlementPriceFixedTs();
        if (fixedTs != 0) {
            bytes32 id = insurerScheduleId[pair];
            if (id == bytes32(0)) return 0;
            InsurerTerminationProposal storage prop = insurerProposals[id];
            if (!prop.costed || block.timestamp >= fixedTs + INSURER_POST_FIX_LOCK) return 0;
            if (!_insurerEpochCurrent(prop, _pairShareEpoch(p))) return 0;
            for (uint256 i = 0; i < n; i++) {
                if (votes[i].id == id) return votes[i].amount;
            }
            return 0;
        }
        uint256 pairSchedule = p.scheduledTerminationTs();
        uint256 pairEpoch = _pairShareEpoch(p);
        for (uint256 i = 0; i < n; i++) {
            if (_voteLive(pair, votes[i], pairSchedule, pairEpoch)) locked += votes[i].amount;
        }
    }

    /// @notice Draws `shareAmount` of `user`'s redemption on the pair calling against their voted
    ///         stake in the proposal that scheduled the pair, and returns the shares of it the
    ///         levy forfeits and who receives them: the factory's bug bounty address, which
    ///         already takes the bug bounty tax on trading fees and can neither vote, propose nor
    ///         dispute, so no voter or abstainer recaptures a forfeit. The unvoted part of the
    ///         balance leaves first: a redemption draws on the voted stake only past it, so
    ///         redeeming what was never locked neither pays the levy nor shrinks the lock, which
    ///         reads the voted stake. Nothing is owed on a pair no vote scheduled, on one whose
    ///         outcome was not costed, on a record from a wiped share generation, or once the
    ///         voted stake has been drawn down.
    /// @dev Called by BazaarPair from InsuranceVaultLib.executeInsuranceWithdrawal on a terminated
    ///      pair, after the lock has been checked and before the shares are burned, so the balance
    ///      read here is the one the lock was judged against. A bounty address that voted itself
    ///      would be paid its own forfeit, so that one case sinks the shares at address(0) instead.
    /// @param user The redeeming insurer
    /// @param shareAmount The shares the redemption burns
    /// @return levyShares The shares of `shareAmount` the pair credits to `recipient` instead of
    ///         paying out
    /// @return recipient Who receives them; address(0) when nothing is owed
    function consumeInsurerLevy(address user, uint256 shareAmount)
        external
        returns (uint256 levyShares, address recipient)
    {
        address pair = msg.sender;
        if (!_registeredPairs.contains(pair)) revert BazaarPairTerminator__OnlyPair();
        bytes32 id = insurerScheduleId[pair];
        if (id == bytes32(0)) return (0, address(0));
        InsurerTerminationProposal storage prop = insurerProposals[id];
        IBazaarPair p = IBazaarPair(pair);
        if (!prop.costed || !_insurerEpochCurrent(prop, _pairShareEpoch(p))) return (0, address(0));
        InsurerVote[] storage votes = insurerVotes[pair][user];
        uint256 n = votes.length;
        for (uint256 i = 0; i < n; i++) {
            InsurerVote storage vote = votes[i];
            if (vote.id != id) continue;
            uint256 balance = p.insuranceShares(user);
            uint256 unvoted = balance > vote.amount ? balance - vote.amount : 0;
            if (shareAmount <= unvoted) return (0, address(0));
            uint256 charged = shareAmount - unvoted;
            if (charged > vote.amount) charged = vote.amount;
            if (charged == 0) return (0, address(0));
            vote.amount -= charged;
            levyShares = charged * prop.levyBp / BP_SCALE_INSURER;
            if (levyShares == 0) return (0, address(0));
            recipient = IBazaarFactory(factory).bugBountyAddress();
            if (recipient == user) recipient = address(0);
            emit InsurerLevyCharged(pair, id, user, charged, levyShares, recipient);
            return (levyShares, recipient);
        }
    }

    /// @notice Shares `voter` has voted into proposal `id` on `pair`, or 0 if the record is dead
    ///         or absent. After the fix of a pair the proposal scheduled, the voted stake still to
    ///         be drawn on by the levy.
    function getInsurerVote(address pair, address voter, bytes32 id) external view returns (uint256) {
        InsurerVote[] storage votes = insurerVotes[pair][voter];
        uint256 pairSchedule = IBazaarPair(pair).scheduledTerminationTs();
        uint256 pairEpoch = _pairShareEpoch(IBazaarPair(pair));
        uint256 n = votes.length;
        for (uint256 i = 0; i < n; i++) {
            InsurerVote storage vote = votes[i];
            if (vote.id == id) {
                return _voteLive(pair, vote, pairSchedule, pairEpoch) ? vote.amount : 0;
            }
        }
        return 0;
    }

    /// @dev A vote record holds its shares while its proposal is pending, or has scheduled the
    ///      pair, and the cutoff has not yet arrived. The record of the proposal whose vote holds
    ///      the pair's cutoff stays live past it: from the cutoff on, a scheduled pair refuses
    ///      insurance withdrawals itself until it terminates, and after the fix the record is what
    ///      the post-fix lock and the levy read, so it must survive the pruning a vote on another
    ///      proposal runs. A proposal resolved without scheduling the pair, preempted by an
    ///      earlier or equal cutoff the pair carries, failed at the latch deadline, or ended by
    ///      a FALSE verdict, holds its voters until the earlier of its own cutoff and the pair's
    ///      (`pairSchedule`): they voted to settle, and releasing them because a settlement comes
    ///      sooner would let a yes-voter exit ahead of it. With no cutoff on the pair it releases
    ///      at once. A failed proposal therefore locks at most INSURER_TERMINATION_LATCH_LEAD past
    ///      its latch deadline, as does one nobody resolves, which stays pending until its cutoff.
    ///      A proposal from a wiped share generation (`pairEpoch` has moved past it) releases at
    ///      once.
    function _voteLive(address pair, InsurerVote storage vote, uint256 pairSchedule, uint256 pairEpoch)
        internal
        view
        returns (bool)
    {
        InsurerTerminationProposal storage prop = insurerProposals[vote.id];
        if (!_insurerEpochCurrent(prop, pairEpoch)) return false;
        if (vote.id == insurerScheduleId[pair]) return true;
        if (block.timestamp >= prop.cutoffTs) return false;
        if (!prop.resolved || prop.scheduled) return true;
        return pairSchedule != 0 && block.timestamp < pairSchedule;
    }

    /// @dev Drops the voter's dead records (swap-remove) and returns the index of their record
    ///      for `id`, or `votes.length` if there is none. A removal only ever moves the last
    ///      record into a slot at or past the cursor, so an index found earlier in the walk stays
    ///      valid.
    function _pruneAndFindVote(
        address pair,
        InsurerVote[] storage votes,
        bytes32 id,
        uint256 pairSchedule,
        uint256 pairEpoch
    ) internal returns (uint256 idx) {
        idx = type(uint256).max;
        uint256 i = 0;
        while (i < votes.length) {
            InsurerVote storage vote = votes[i];
            if (!_voteLive(pair, vote, pairSchedule, pairEpoch)) {
                votes[i] = votes[votes.length - 1];
                votes.pop();
                continue; // re-examine the record that just moved into slot i
            }
            if (vote.id == id) idx = i;
            i++;
        }
        if (idx == type(uint256).max) idx = votes.length;
    }
}
