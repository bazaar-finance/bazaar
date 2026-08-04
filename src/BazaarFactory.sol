// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BazaarPair} from "./BazaarPair.sol";
import {BazaarTypes} from "./libraries/BazaarTypes.sol";
import {BazaarOracle} from "./BazaarOracle.sol";
import {BazaarSequencer} from "./BazaarSequencer.sol";
import {BazaarPairLens} from "./BazaarPairLens.sol";
import {BazaarPairTerminator} from "./BazaarPairTerminator.sol";
import {
    IOptimisticOracleV3,
    IOptimisticOracleV3CallbackRecipient,
    IERC20Minimal
} from "./interfaces/IUmaOptimisticOracleV3.sol";

contract BazaarFactory is IOptimisticOracleV3CallbackRecipient, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    // -------------------- Types --------------------
    struct PairDeploymentProposal {
        address deployer;
        bytes32 baseFeedId;
        bool isContinuouslyTraded;
        uint256 seedAmount; // BAZAAR_SCALE (1e18), full amount including bond
        uint256 seedAmountUsdc; // seed in USDC decimals (1e6), held in factory until deployment
        string description; // e.g. "AAPL on NASDAQ"
        bytes32 pairId;
        uint256 proposalTs;
        bool resolved;
        bool deployed;
    }

    struct UmaIdentifierUpgradeProposal {
        address proposer;
        bytes32 newIdentifier;
        uint256 proposalTs;
        bool resolved;
        bool settlementResolution;
        /// @dev Recorded from assertionDisputedCallback. A disputed assertion is unsettleable until
        ///      the DVM votes, and that state is NOT queryable from here — VotingV2 gates
        ///      hasPrice/getPrice behind onlyRegisteredContract and the factory is not registered.
        ///      This flag is what lets expireStuckIdentifierUpgradeProposal tell "not ready yet"
        ///      apart from "will never settle". Packs with the two bools above; no extra slot.
        bool disputed;
    }

    /// @notice An APPROVED identifier upgrade waiting out its activation timelock.
    ///         effectiveTs == 0 means nothing is queued.
    struct QueuedIdentifierUpgrade {
        bytes32 assertionId;
        bytes32 newIdentifier;
        uint256 effectiveTs;
    }

    // -------------------- Events --------------------
    event PairDeployed(bytes32 indexed pairId, address indexed pairAddress, bytes32 baseFeedId);

    event PairDeploymentProposed(
        bytes32 indexed pairId,
        bytes32 indexed assertionId,
        address indexed deployer,
        bytes32 baseFeedId,
        string description,
        uint256 seedAmount
    );

    event PairDeploymentProposalDisputed(bytes32 indexed assertionId);

    event PairDeploymentProposalResolved(bytes32 indexed assertionId, bool assertedTruthfully, bool deployed);

    /// @notice A pending deployment proposal whose assertion can no longer be settled was
    ///         discarded, releasing the pairId so the asset can be listed again. The escrowed seed
    ///         is credited to `seedRefundOwed`; the assertion itself is untouched on the OO.
    event PairDeploymentProposalExpired(bytes32 indexed assertionId, address indexed deployer);

    /// @notice Escrowed seed became claimable by its deployer (proposal rejected or expired).
    event SeedRefundCredited(bytes32 indexed assertionId, address indexed deployer, uint256 amountUsdc);

    event SeedRefundClaimed(address indexed deployer, uint256 amountUsdc);

    event UmaIdentifierUpgradeProposed(bytes32 indexed assertionId, address indexed proposer, bytes32 newIdentifier);

    event UmaIdentifierUpgradeDisputed(bytes32 indexed assertionId);

    /// @notice An upgrade proposal was approved and queued; it activates at effectiveTs. This
    ///         event is the user-facing exit signal: the identifier decides how UMA voters
    ///         adjudicate every future listing and termination, so anyone who distrusts the
    ///         incoming one has until effectiveTs to close positions and withdraw.
    event UmaIdentifierUpgradeQueued(bytes32 indexed assertionId, bytes32 newIdentifier, uint256 effectiveTs);

    event UmaIdentifierUpgraded(bytes32 indexed assertionId, bytes32 oldIdentifier, bytes32 newIdentifier);

    /// @notice A queued upgrade was dropped at activation because the incoming identifier is no
    ///         longer on UMA's live IdentifierWhitelist. The incumbent identifier stays in place;
    ///         governance keeps working and a corrected upgrade can be proposed.
    event UmaIdentifierUpgradeCanceled(bytes32 indexed assertionId, bytes32 newIdentifier);

    /// @notice A pending upgrade proposal whose assertion can no longer be settled was discarded,
    ///         releasing the single proposal slot. The assertion itself is untouched on the OO.
    event UmaIdentifierUpgradeExpired(bytes32 indexed assertionId, address indexed proposer);

    // -------------------- Errors --------------------
    error Factory__ZeroAddress();
    error Factory__WiringMismatch();
    error Factory__PairAlreadyExists(bytes32 pairId);
    error Factory__ProposalAlreadyPending(bytes32 pairId);
    error Factory__OnlyUmaOracle();
    error Factory__ProposalNotFound(bytes32 assertionId);
    error Factory__ProposalAlreadyResolved(bytes32 assertionId);
    error Factory__SeedBelowMinimum();
    error Factory__DescriptionInvalid();
    error Factory__CompositePairMustBeNonContinuous();
    error Factory__IdentifierUpgradeStillPending();
    error Factory__IdentifierUpgradeNoChange();
    error Factory__InvalidIdentifier();
    error Factory__IdentifierNotWhitelisted(bytes32 identifier);
    error Factory__IdentifierNotAssertTruth(bytes32 identifier);
    error Factory__NoQueuedIdentifierUpgrade();
    error Factory__IdentifierUpgradeTimelocked(uint256 effectiveTs);
    error Factory__NoPendingIdentifierUpgrade();
    error Factory__IdentifierUpgradeNotExpired(uint256 expiryTs);
    error Factory__NoPendingDeployment(bytes32 pairId);
    error Factory__DeploymentNotExpired(uint256 expiryTs);
    error Factory__NoSeedRefund();

    // -------------------- Constants --------------------
    uint256 public constant MIN_DEPLOYMENT_AMOUNT = 4_000 * 1e18; // 4000 USDC in BAZAAR_SCALE (1k bond + 3k+ seed)
    uint256 public constant DEPLOYMENT_BOND_USDC = 1_000 * 1e6; // 1000 USDC bond for pair-deployment assertion
    uint64 public constant DEPLOYMENT_LIVENESS = 48 hours;

    // The bond is 5x pair deployment's because the UMA identifier is protocol-wide governance —
    // it decides how voters adjudicate every future listing and termination. The liveness window
    // is the ONLY defense against adopting a wrong-but-whitelisted identifier: the whitelist
    // check merely narrows the input to ~265 UMA-approved values, most of them price feeds that
    // are absurd here, and the activation timelock is an exit window, not a veto. If such an
    // identifier ever activates, every DVM vote returns a non-`numericalTrue` price, so every
    // disputed assertion resolves FALSE — disputes become a profitable unconditional veto, and
    // recovery is contested. 2 days matches pair deployment's window — the same watchers review
    // both tracks — and sits well inside the ~7.7-day coexistence window UMA left between
    // whitelisting a successor identifier and retiring its predecessor (the only observed
    // migration), so a migration proposed when the successor appears finishes disputing while
    // both are still live.
    uint256 public constant IDENTIFIER_UPGRADE_BOND_USDC = 5_000 * 1e6;
    uint64 public constant IDENTIFIER_UPGRADE_LIVENESS = 2 days;
    /// @notice Delay between an upgrade proposal being APPROVED and the new identifier taking
    ///         effect. The dispute window defends against bad proposals; this timelock is the
    ///         second line: if a bad upgrade somehow survives liveness/DVM, users get 14 days'
    ///         notice to close positions and exit before the new identifier governs anything.
    ///         (Insurance-LP withdrawals remain subject to their 20-day cooldown, which outlasts
    ///         the timelock.)
    uint256 public constant IDENTIFIER_UPGRADE_TIMELOCK = 14 days;
    /// @notice Extra wait, on top of an assertion's own liveness, before a DISPUTED proposal that
    ///         still cannot settle may be discarded. Shared by the deployment and identifier tracks:
    ///         the bound is a property of the DVM, not of what is being proposed. Only disputed
    ///         proposals need it — their unsettleability is expected while the DVM votes, and the
    ///         factory cannot query whether that vote has finished.
    ///         Derived from mainnet VotingV2 (0x004395edb43EFca9885CEdad51EC9fAf93Bd34ac):
    ///         phaseLength = 24h — so a commit+reveal round is 48h — and maxRolls = 4. Deletion
    ///         triggers on `rollCount > maxRolls`, so a request gets 5 rounds (initial + 4 rolls)
    ///         before the DVM drops it: 5 x 48h = 10 days, plus up to one round of enqueue lead =
    ///         12 days from dispute to last possible resolution. The clock here starts at
    ///         proposalTs, but a dispute may be filed as late as the final second of liveness, so
    ///         the grace alone must cover those 12 days. 14 leaves margin for UMA changing either
    ///         parameter (both are owner-settable). Below 12, a dispute filed late in liveness
    ///         whose vote rolls several times could be discarded while still resolvable — costing
    ///         a re-proposal, not funds (bonds settle on UMA regardless).
    ///         Undisputed proposals need no grace at all.
    uint256 public constant DVM_DISPUTE_GRACE = 14 days;

    /// @notice Every adjudication identifier must begin with ASCII "ASSERT_TRUTH".
    /// @dev UMA's IdentifierWhitelist is a "some UMIP defines this" list, NOT a "safe to adjudicate
    ///      truth assertions" list, so the whitelist check alone cannot reject a price feed. That
    ///      matters because OOv3 resolves an assertion TRUE on a DVM price of exactly `numericalTrue`
    ///      (1e18), and the whitelist carries identifiers that can return it: UMIP-29's EURUSD and
    ///      CHFUSD are 18-decimal-scaled, 5-decimal-rounded FX feeds off a live source whose voters
    ///      never read ancillary data — at parity they resolve to exactly 1e18. Adopting one decides
    ///      every dispute in advance, in whichever direction the feed happens to sit: at exactly
    ///      1e18 every disputed assertion auto-approves, and anywhere else every dispute wins,
    ///      making disputes a profitable veto on listings, terminations, and repair proposals. Others
    ///      (dead-source feeds like FEIUSD/DSDUSD) are unvotable, so the DVM request rolls, is
    ///      deleted at maxRolls, and `settleAssertion` reverts forever.
    ///
    ///      Restricting to UMA's own truth-assertion naming makes that class unrepresentable while
    ///      staying forward-compatible: UMA versions these identifiers by suffix (ASSERT_TRUTH ->
    ///      ASSERT_TRUTH2, declared a one-for-one replacement), so a conventionally-named successor
    ///      is adoptable with no code change.
    ///      ACCEPTED TRADEOFF: if UMA ever names a successor off-convention, this gate rejects it
    ///      and adopting it requires a factory redeploy — the same DR path already accepted for an
    ///      OOv3-contract-level death. That is deliberate: a wrong adjudicator is unrecoverable and
    ///      silent, whereas a rejected-but-correct successor is loud, monitored, and planned for.
    bytes32 internal constant ASSERT_TRUTH_PREFIX = bytes32("ASSERT_TRUTH");
    /// @dev Selects the first 12 bytes — the length of "ASSERT_TRUTH".
    bytes32 internal constant ASSERT_TRUTH_PREFIX_MASK = bytes32(uint256(type(uint96).max) << 160);

    // -------------------- Storage --------------------
    address public immutable usdc;
    BazaarOracle public immutable oracle;
    address public immutable bugBountyAddress;
    address public immutable pairImplementation;
    BazaarSequencer public sequencer;
    BazaarPairLens public immutable lens;
    BazaarPairTerminator public pairTerminator;

    /// @notice The UMA Optimistic Oracle V3. IMMUTABLE by design: OOv3 generations at new
    ///         addresses have always been ABI-breaking (v1→v2→v3), so no upgrade path could adopt
    ///         one anyway, and a mutable pointer's worst case — a malicious oracle activating
    ///         through an unwatched governance slot — is protocol-wide adjudication capture.
    ///         What UMA actually churns is the identifier whitelist, and THAT is what the
    ///         governance track below upgrades. An OOv3-contract-level death (deregistration,
    ///         DVM abandoning the generation — never happened to any UMA oracle generation)
    ///         means a factory redeploy; existing pairs keep their non-UMA termination paths.
    IOptimisticOracleV3 public immutable oo;

    /// @notice The UMA identifier every assertion is made under. Set at construction (validated
    ///         against UMA's live IdentifierWhitelist) and changed only by the identifier-upgrade
    ///         governance track below.
    bytes32 public umaIdentifier;

    // pairId => deployed pair address
    mapping(bytes32 => address) public pairAddressById;

    // assertionId => deployment proposal
    mapping(bytes32 => PairDeploymentProposal) public deploymentProposals;

    // pairId => pending assertionId (only cleared when claim is rejected)
    mapping(bytes32 => bytes32) public pendingDeploymentByPairId;

    /// @notice Whether a deployment assertion was disputed, recorded from assertionDisputedCallback.
    /// @dev Keyed by assertionId rather than held in PairDeploymentProposal so the struct's public
    ///      getter keeps a stable tuple shape for consumers. Read only by
    ///      expireStuckDeploymentProposal, to tell "the DVM is still voting" from "this can never
    ///      settle".
    mapping(bytes32 => bool) public deploymentDisputed;

    /// @notice USDC (6dp) a deployer may claim back because their proposal did not deploy a pair.
    /// @dev Credited rather than pushed: the credit happens inside OOv3's resolve callback, and a
    ///      transfer that reverts there (a USDC-blacklisted deployer) would revert settleAssertion
    ///      itself, leaving the assertion unsettleable and the pairId occupied forever.
    mapping(address => uint256) public seedRefundOwed;

    // assertionId => identifier upgrade proposal
    mapping(bytes32 => UmaIdentifierUpgradeProposal) public identifierUpgradeProposals;

    /// @notice The Optimistic Oracle an assertion was created against, recorded at proposal time.
    /// @dev With `oo` immutable this is always the same address; kept because callback auth and
    ///      settlement routing through a per-assertion record is cheap and makes the auth
    ///      invariant ("only the oracle this assertion was made on") explicit.
    mapping(bytes32 => IOptimisticOracleV3) public assertionOo;

    // pending identifier upgrade assertion (only one at a time)
    bytes32 public pendingIdentifierUpgradeAssertionId;

    // approved identifier upgrade waiting out IDENTIFIER_UPGRADE_TIMELOCK (only one at a time)
    QueuedIdentifierUpgrade public queuedIdentifierUpgrade;

    // set of all pair addresses (O(1) membership checks)
    EnumerableSet.AddressSet private _allPairs;

    // -------------------- Constructor --------------------
    /// @dev `_sequencer` and `_pairTerminator` are deployed by the deploy script with THIS
    ///      factory's (CREATE-predicted) address baked into their immutable `factory` fields —
    ///      deploying them inline here would push the factory's initcode past EIP-3860.
    ///      The script asserts the prediction matched after construction.
    constructor(
        address _usdc,
        address _oracle,
        address _lens,
        address _bugBountyAddress,
        address _optimisticOracleV3,
        address _pairImplementation,
        address _sequencer,
        address _pairTerminator,
        bytes32 _umaIdentifier
    ) {
        if (_usdc == address(0)) revert Factory__ZeroAddress();
        if (_oracle == address(0)) revert Factory__ZeroAddress();
        if (_lens == address(0)) revert Factory__ZeroAddress();
        if (_bugBountyAddress == address(0)) revert Factory__ZeroAddress();
        if (_optimisticOracleV3 == address(0)) revert Factory__ZeroAddress();
        if (_pairImplementation == address(0)) revert Factory__ZeroAddress();
        if (_sequencer == address(0)) revert Factory__ZeroAddress();
        if (_pairTerminator == address(0)) revert Factory__ZeroAddress();
        if (_umaIdentifier == bytes32(0)) revert Factory__InvalidIdentifier();
        // Wiring consistency: both must have been constructed pointing at this factory.
        if (BazaarSequencer(_sequencer).factory() != address(this)) revert Factory__WiringMismatch();
        if (BazaarPairTerminator(_pairTerminator).factory() != address(this)) revert Factory__WiringMismatch();
        usdc = _usdc;
        oracle = BazaarOracle(_oracle);
        lens = BazaarPairLens(_lens);
        bugBountyAddress = _bugBountyAddress;
        pairImplementation = _pairImplementation;
        sequencer = BazaarSequencer(_sequencer);
        oo = IOptimisticOracleV3(_optimisticOracleV3);
        pairTerminator = BazaarPairTerminator(_pairTerminator);

        // Deploy-time gate: the genesis identifier must be on UMA's LIVE IdentifierWhitelist.
        // This is not hypothetical — on the live Arbitrum/mainnet OOv3, its own `defaultIdentifier`
        // constant ("ASSERT_TRUTH") is NOT whitelisted; UMA deprecated it in favour of
        // "ASSERT_TRUTH2" on the same oracle. A wrong genesis value would revert every assertTruth
        // — listings, terminations, and the identifier-upgrade path that repairs them — from block
        // one. Failing deployment is the only acceptable place to discover that.
        if (!_identifierWhitelisted(_optimisticOracleV3, _umaIdentifier)) {
            revert Factory__IdentifierNotWhitelisted(_umaIdentifier);
        }
        // Genesis must also satisfy the truth-identifier rule the upgrade path enforces — the
        // whitelist gate above cannot catch a deploy-script typo naming a whitelisted PRICE feed
        // (EURUSD is whitelisted; ASSERT_TRUTH is not). See ASSERT_TRUTH_PREFIX.
        if (!_isAssertTruthIdentifier(_umaIdentifier)) {
            revert Factory__IdentifierNotAssertTruth(_umaIdentifier);
        }
        umaIdentifier = _umaIdentifier;

        // Warm OOv3's identifier cache so the first assertion doesn't pay the whitelist lookup.
        // NOTE this is a gas nicety, NOT a liveness guarantee: syncUmaParams is public and
        // OVERWRITES the cache with the live whitelist value, so after a de-whitelisting anyone
        // can flip the cache to false and hard-revert assertions under the dead identifier.
        // Bazaar never relies on the cache: submissions under a dead identifier are prevented
        // upstream — listings/terminations gate on umaIdentifierIsLive(), and the upgrade path
        // routes its assertion under the proposed live identifier. Best-effort: real OOv3
        // exposes this; minimal mocks may not.
        try IOptimisticOracleV3(_optimisticOracleV3).syncUmaParams(_umaIdentifier, _usdc) {} catch {}
    }

    // -------------------- Phase 1: Propose Pair Deployment --------------------

    /// @notice Propose a new pair deployment. Requires minimum 4000 USDC: 1k UMA bond + 3k+ seed.
    /// @param baseFeedId Pyth price feed ID for the base asset, or a composite feed ID registered
    ///        on the BazaarOracle (for assets quoted in a non-USD currency).
    /// @param isContinuouslyTraded True if asset trades 24/7 (crypto), false for assets with trading hours (stocks).
    ///        Must be false for composite (non-USD-quoted) pairs — FX rates are not live 24/7.
    /// @param totalAmount Total deposit in BAZAAR_SCALE (1e18). Minimum 4000 USDC. 1k goes to UMA bond, rest is seed.
    /// @param description Human-readable asset description, e.g. "AAPL on NASDAQ". 1-200 bytes,
    ///        restricted to letters, digits, space, and . , & / - (see _isValidDescription).
    /// @return assertionId The UMA assertion ID for tracking this proposal.
    function proposePairDeployment(
        bytes32 baseFeedId,
        bool isContinuouslyTraded,
        uint256 totalAmount,
        string calldata description
    ) external nonReentrant returns (bytes32 assertionId) {
        if (totalAmount < MIN_DEPLOYMENT_AMOUNT) revert Factory__SeedBelowMinimum();
        if (!_isValidDescription(bytes(description))) revert Factory__DescriptionInvalid();

        // Composite (non-USD-quoted) pairs depend on an FX leg that does not tick 24/7,
        // so they can never be continuously traded
        (bytes32 compositeBaseLeg,,) = oracle.composites(baseFeedId);
        if (compositeBaseLeg != bytes32(0) && isContinuouslyTraded) {
            revert Factory__CompositePairMustBeNonContinuous();
        }

        // Fail closed while the protocol's identifier is off UMA's live whitelist: disputes on new
        // assertions are impossible in that state (VotingV2 re-checks the live list on every
        // dispute), so a submission here would be adjudicated by nobody and auto-approve after
        // liveness. Reverting keeps junk listings out of an undisputable pipeline; listings resume
        // once the identifier-upgrade track (which stays open — see proposeUmaIdentifierUpgrade)
        // has moved to a live identifier.
        if (!umaIdentifierIsLive()) revert Factory__IdentifierNotWhitelisted(umaIdentifier);

        bytes32 pairId = baseFeedId;

        // If there's a pending proposal for this pairId, try to settle it first
        if (pendingDeploymentByPairId[pairId] != bytes32(0)) {
            try this.settleDeploymentProposal(pendingDeploymentByPairId[pairId]) {}
            catch {
                revert Factory__ProposalAlreadyPending(pairId);
            }
        }

        // Check no active (non-terminated) pair exists
        address existing = pairAddressById[pairId];
        if (existing != address(0)) {
            BazaarPair existingPair = BazaarPair(payable(existing));
            if (!existingPair.isPairTerminatedEmergency() && !existingPair.isPairTerminatedNormal()) {
                revert Factory__PairAlreadyExists(pairId);
            }
        }

        // Pull total from deployer. The bond goes to UMA (the deployer is the asserter and gets it
        // back on success); the remainder is escrowed here and transferred to the pair on deployment.
        uint256 totalAmountUsdc = totalAmount / 1e12;
        uint256 bondUsdc = requiredDeploymentBond();
        if (totalAmountUsdc <= bondUsdc) revert Factory__SeedBelowMinimum();
        uint256 seedAmountUsdc = totalAmountUsdc - bondUsdc;
        // µUSDC-aligned: the seed credited to the pair exactly matches the USDC escrowed (no
        // sub-µUSDC dust retained in the 1e18 bookkeeping vs the floored 1e6 amount held).
        uint256 seedAmount = seedAmountUsdc * 1e12;
        // Enforce the seed floor on the SEED, which is what BazaarPair.initialize will check, rather
        // than inferring it from the total. The two are only equivalent while the bond is fixed, and
        // it is not: a bond that rises to track UMA silently eats into the seed. Inferring would let
        // an under-funded proposal escrow its money, run the full liveness window, and then revert
        // inside the resolve callback — unsettleable forever, seed stranded, pairId never reusable.
        if (seedAmount < BazaarTypes.MIN_INSURANCE_SEED) revert Factory__SeedBelowMinimum();
        IERC20Minimal usdcToken = IERC20Minimal(usdc);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), totalAmountUsdc);
        IERC20(usdc).forceApprove(address(oo), bondUsdc);

        // Build claim and submit to UMA
        bytes memory claim = _buildDeploymentClaim(baseFeedId, isContinuouslyTraded, description);

        assertionId = oo.assertTruth(
            claim,
            msg.sender, // asserter = deployer (bond refunded directly to them on success)
            address(this), // callbackRecipient = factory
            address(0), // no escalation manager
            DEPLOYMENT_LIVENESS,
            usdcToken,
            bondUsdc,
            umaIdentifier,
            bytes32(0)
        );

        // Store proposal. Record the OO this assertion was created against so settlement and
        // callback auth route through that exact oracle.
        assertionOo[assertionId] = oo;
        pendingDeploymentByPairId[pairId] = assertionId;
        deploymentProposals[assertionId] = PairDeploymentProposal({
            deployer: msg.sender,
            baseFeedId: baseFeedId,
            isContinuouslyTraded: isContinuouslyTraded,
            seedAmount: seedAmount,
            seedAmountUsdc: seedAmountUsdc,
            description: description,
            pairId: pairId,
            proposalTs: block.timestamp,
            resolved: false,
            deployed: false
        });

        emit PairDeploymentProposed(pairId, assertionId, msg.sender, baseFeedId, description, seedAmount);
    }

    // -------------------- UMA Identifier Upgrade --------------------

    /// @notice Propose switching the protocol to a different UMA identifier. The oracle address is
    ///         immutable — the identifier is the axis UMA actually changes (whitelist entries come
    ///         and go by governance vote; OOv3 generations at new addresses have always been
    ///         ABI-breaking, so no on-chain path could adopt one anyway).
    /// @dev The candidate must begin with "ASSERT_TRUTH" (see ASSERT_TRUTH_PREFIX — this is what
    ///      keeps a whitelisted PRICE feed out of the adjudicator slot) and is validated against
    ///      UMA's LIVE IdentifierWhitelist before the bond moves, so a poisoned (non-whitelisted)
    ///      identifier can never enter the pipeline — that validation is what makes an
    ///      attacker-chosen brick value unrepresentable. The assertion
    ///      itself runs under the CURRENT identifier while it is live, and under the PROPOSED
    ///      (validated-live) identifier once the incumbent has been de-whitelisted — so this path
    ///      works in both modes without ever submitting under a dead identifier, and stays
    ///      disputable in both. See the routing comment below.
    function proposeUmaIdentifierUpgrade(bytes32 newIdentifier) external nonReentrant returns (bytes32 assertionId) {
        if (newIdentifier == bytes32(0)) revert Factory__InvalidIdentifier();

        // If there's a pending upgrade, try to settle it first
        if (pendingIdentifierUpgradeAssertionId != bytes32(0)) {
            try this.settleIdentifierUpgradeProposal(pendingIdentifierUpgradeAssertionId) {}
            catch {
                revert Factory__IdentifierUpgradeStillPending();
            }
        }

        // An approved upgrade waiting out its timelock blocks new proposals; once the timelock
        // has elapsed, activate it now rather than leaving it stranded.
        if (queuedIdentifierUpgrade.effectiveTs != 0) {
            if (block.timestamp < queuedIdentifierUpgrade.effectiveTs) {
                revert Factory__IdentifierUpgradeStillPending();
            }
            activateIdentifierUpgrade();
        }

        if (newIdentifier == umaIdentifier) revert Factory__IdentifierUpgradeNoChange();

        // Truth-identifier rule first: a pure check, so a doomed candidate never reaches the
        // external whitelist calls. Not re-checked at activation (unlike the whitelist, which
        // guards a mutable external fact) — the stored candidate cannot change, and this is a
        // pure function of it.
        if (!_isAssertTruthIdentifier(newIdentifier)) {
            revert Factory__IdentifierNotAssertTruth(newIdentifier);
        }

        if (!_identifierWhitelisted(address(oo), newIdentifier)) {
            revert Factory__IdentifierNotWhitelisted(newIdentifier);
        }

        // Which identifier carries the assertion itself. Normally the incumbent — proposers must
        // not get to choose the adjudication identifier while governance is healthy. But if the
        // incumbent has been de-whitelisted, an assertion under it would be undisputable (the DVM
        // rejects dispute price requests against the live whitelist), turning this into
        // first-proposer-wins governance. Routing the assertion under the PROPOSED identifier —
        // just validated live above — keeps the recovery proposal disputable. This is the one
        // UMA submission that must never gate on the incumbent being live: it is the repair path.
        bytes32 assertionIdentifier = umaIdentifierIsLive() ? umaIdentifier : newIdentifier;

        IERC20Minimal usdcToken = IERC20Minimal(usdc);
        uint256 bondUsdc = requiredIdentifierUpgradeBond();
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), bondUsdc);
        IERC20(usdc).forceApprove(address(oo), bondUsdc);

        bytes memory claim = bytes.concat(
            abi.encodePacked(
                "UMA identifier upgrade proposal for Bazaar protocol on Arbitrum (chain ID 42161).",
                " Oracle (fixed): ",
                Strings.toHexString(address(oo)),
                ". Current identifier: ",
                Strings.toHexString(uint256(umaIdentifier)),
                ". Proposed new identifier: ",
                Strings.toHexString(uint256(newIdentifier)),
                "."
            ),
            abi.encodePacked(
                " HOW TO VALIDATE: "
                "NOTE: Identifiers are displayed as hex-encoded bytes32 values. To verify, convert the hex to a UTF-8 string. "
                "UMA voters should verify that: "
                "(1) The proposed identifier is approved and active on UMA's IdentifierWhitelist, and is appropriate for "
                "adjudicating free-form truth assertions of the kind Bazaar submits (pair listings and market terminations). "
                "(2) The upgrade is necessary: the current identifier is deprecated, de-whitelisted, scheduled for removal, "
                "or otherwise unsuitable for those assertions. "
                "Assertion is INVALID if: the proposed identifier is not approved, is not suited to truth assertions, "
                "or there is no need for the change (the current identifier remains functional and appropriate)."
            )
        );

        assertionId = oo.assertTruth(
            claim,
            msg.sender,
            address(this),
            address(0),
            IDENTIFIER_UPGRADE_LIVENESS,
            usdcToken,
            bondUsdc,
            assertionIdentifier,
            bytes32(0)
        );

        assertionOo[assertionId] = oo;
        pendingIdentifierUpgradeAssertionId = assertionId;

        identifierUpgradeProposals[assertionId] = UmaIdentifierUpgradeProposal({
            proposer: msg.sender,
            newIdentifier: newIdentifier,
            proposalTs: block.timestamp,
            resolved: false,
            settlementResolution: false,
            disputed: false
        });

        emit UmaIdentifierUpgradeProposed(assertionId, msg.sender, newIdentifier);
    }

    // -------------------- Phase 2: UMA Callbacks & Settlement --------------------

    /// @notice settle a deployment proposal after liveness expires (fallback to callback).
    function settleDeploymentProposal(bytes32 assertionId) external {
        PairDeploymentProposal storage p = deploymentProposals[assertionId];
        if (p.deployer == address(0)) revert Factory__ProposalNotFound(assertionId);
        if (p.resolved) revert Factory__ProposalAlreadyResolved(assertionId);

        assertionOo[assertionId].settleAndGetAssertionResult(assertionId);
    }

    /// @notice settle an identifier upgrade proposal after liveness expires.
    function settleIdentifierUpgradeProposal(bytes32 assertionId) external {
        UmaIdentifierUpgradeProposal storage p = identifierUpgradeProposals[assertionId];
        if (p.proposer == address(0)) revert Factory__ProposalNotFound(assertionId);
        if (p.resolved) revert Factory__ProposalAlreadyResolved(assertionId);

        assertionOo[assertionId].settleAndGetAssertionResult(assertionId);
    }

    /// @notice Release a pairId whose deployment assertion can no longer be settled, and make the
    ///         escrowed seed claimable by its deployer. Permissionless.
    /// @dev OOv3 pays the winning party BEFORE firing the resolve callback (`settleAssertion`), so a
    ///      payout that reverts takes settlement down with it and the callback never fires. Every
    ///      outcome has such a party: the deployer receives the bond when undisputed or ruled TRUE,
    ///      and the disputer receives it when ruled FALSE, so a USDC blacklisting on either side
    ///      wedges the corresponding branch. A dispute the DVM never resolves wedges it too — past
    ///      maxRolls the request is deleted and getPrice reverts forever. Without a timeout the seed
    ///      stays escrowed and the pairId stays occupied, so that asset could never be listed again.
    ///
    ///      Settlement is attempted first, so this is a no-op whenever the proposal can still
    ///      resolve normally — only a genuinely unsettleable proposal is discarded. The assertion is
    ///      left alone on the OO: if it ever becomes settleable, the winning party can still settle
    ///      directly to collect their bond, and the factory then ignores the outcome.
    ///
    ///      UNDISPUTED proposals need no grace beyond liveness, because a failure there is proof
    ///      rather than a guess. `proposalTs + DEPLOYMENT_LIVENESS` is exactly the assertion's
    ///      `expirationTime` (the factory supplies that liveness itself), and past it OOv3's
    ///      undisputed branch has only two statements left: the bond payout and this contract's
    ///      resolve callback, which cannot revert. So a failed settlement can only be a blocked
    ///      payout — the condition being expired for.
    ///
    ///      DISPUTED proposals wait out DVM_DISPUTE_GRACE on top, because being unsettleable is
    ///      expected while the DVM votes and whether that vote finished is not queryable from here.
    ///      Without it a disputer could discard the proposal the instant liveness ended regardless
    ///      of how the DVM later voted, turning one bond into a guaranteed veto on any listing.
    /// @param pairId The asset whose pending proposal should be released.
    function expireStuckDeploymentProposal(bytes32 pairId) external nonReentrant {
        bytes32 assertionId = pendingDeploymentByPairId[pairId];
        if (assertionId == bytes32(0)) revert Factory__NoPendingDeployment(pairId);

        PairDeploymentProposal storage p = deploymentProposals[assertionId];
        uint256 expiryTs = p.proposalTs + DEPLOYMENT_LIVENESS;
        if (deploymentDisputed[assertionId]) expiryTs += DVM_DISPUTE_GRACE;
        if (block.timestamp < expiryTs) revert Factory__DeploymentNotExpired(expiryTs);

        // Prefer the real outcome. On success the resolve callback releases the pairId and either
        // deploys the pair or credits the refund, so there is nothing left to expire.
        try this.settleDeploymentProposal(assertionId) {
            return;
        } catch {}

        p.resolved = true; // makes any late resolve callback a silent no-op
        delete pendingDeploymentByPairId[pairId];
        _creditSeedRefund(assertionId, p);

        emit PairDeploymentProposalExpired(assertionId, p.deployer);
    }

    /// @notice Withdraw seed escrow owed to you from a rejected or expired deployment proposal.
    /// @dev Only ever pays the caller: an address that cannot receive USDC must not be able to
    ///      stall anyone else, nor to redirect its own credit elsewhere.
    function claimSeedRefund() external nonReentrant {
        uint256 amount = seedRefundOwed[msg.sender];
        if (amount == 0) revert Factory__NoSeedRefund();
        seedRefundOwed[msg.sender] = 0;
        IERC20(usdc).safeTransfer(msg.sender, amount);
        emit SeedRefundClaimed(msg.sender, amount);
    }

    /// @notice Release the single pending-upgrade slot when its assertion can no longer be settled.
    /// @dev OOv3 pays the bond BEFORE firing the resolve callback (`settleAssertion`, undisputed
    ///      branch), so if the payout reverts — a proposer USDC-blacklisted after proposing, say —
    ///      settlement reverts wholesale, the callback never fires, and this slot stays occupied
    ///      forever. With no timeout that permanently blocks every future identifier upgrade.
    ///
    ///      Settlement is attempted first, so this is a no-op whenever the proposal can still
    ///      resolve normally — only a genuinely unsettleable proposal is discarded. The assertion
    ///      is left alone on the OO: if it ever becomes settleable, the winning party can still
    ///      settle directly to collect their bond (the factory then ignores the outcome).
    ///
    ///      UNDISPUTED proposals need no grace beyond liveness, because a failure there is proof
    ///      rather than a guess. `proposalTs + IDENTIFIER_UPGRADE_LIVENESS` is exactly the
    ///      assertion's `expirationTime` (the factory supplies that liveness itself), and past it
    ///      OOv3's undisputed branch has only two statements left: the bond payout and this
    ///      contract's resolve callback, which cannot revert. So a failed settlement can only be a
    ///      blocked payout — the condition being expired for. No oracle round-trip is needed.
    ///
    ///      DISPUTED proposals are the one case a timer is unavoidable: being unsettleable is
    ///      expected while the DVM votes, and whether that vote has finished is not queryable from
    ///      here (VotingV2 gates hasPrice/getPrice behind onlyRegisteredContract). Waiting out
    ///      DVM_DISPUTE_GRACE keeps a dispute from becoming a cheap veto: without
    ///      it, any disputer could discard the proposal the moment liveness ended, regardless of
    ///      how the DVM later voted.
    function expireStuckIdentifierUpgradeProposal() external nonReentrant {
        bytes32 assertionId = pendingIdentifierUpgradeAssertionId;
        if (assertionId == bytes32(0)) revert Factory__NoPendingIdentifierUpgrade();

        UmaIdentifierUpgradeProposal storage p = identifierUpgradeProposals[assertionId];
        uint256 expiryTs = p.proposalTs + IDENTIFIER_UPGRADE_LIVENESS;
        if (p.disputed) expiryTs += DVM_DISPUTE_GRACE;
        if (block.timestamp < expiryTs) revert Factory__IdentifierUpgradeNotExpired(expiryTs);

        // Prefer the real outcome. On success the resolve callback clears the slot and queues the
        // upgrade if it was approved, so there is nothing left to expire.
        try this.settleIdentifierUpgradeProposal(assertionId) {
            return;
        } catch {}

        p.resolved = true; // makes any late resolve callback a silent no-op
        pendingIdentifierUpgradeAssertionId = bytes32(0);

        emit UmaIdentifierUpgradeExpired(assertionId, p.proposer);
    }

    /// @notice Called by UMA oracle when assertion is resolved (after liveness or DVM vote).
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external override {
        // Auth against the OO this assertion was created on (recorded at proposal time).
        if (msg.sender != address(assertionOo[assertionId])) revert Factory__OnlyUmaOracle();

        if (deploymentProposals[assertionId].deployer != address(0)) {
            _handleDeploymentResolution(assertionId, assertedTruthfully);
            return;
        }

        _handleIdentifierUpgradeResolution(assertionId, assertedTruthfully);
    }

    /// @notice Called by UMA oracle when assertion is disputed. Proposal stays pending during DVM voting.
    /// @dev Records the dispute against the matching track and nothing else. Both branches are plain
    ///      storage writes: this callback runs inside OOv3.disputeAssertion with no try/catch, so it
    ///      must never revert or disputes themselves become impossible. The flag is what lets the
    ///      expiry paths tell "the DVM has not finished voting" from "this can never settle".
    function assertionDisputedCallback(bytes32 assertionId) external override {
        if (msg.sender != address(assertionOo[assertionId])) revert Factory__OnlyUmaOracle();

        if (deploymentProposals[assertionId].deployer != address(0)) {
            deploymentDisputed[assertionId] = true;
            emit PairDeploymentProposalDisputed(assertionId);
            return;
        }

        identifierUpgradeProposals[assertionId].disputed = true;

        emit UmaIdentifierUpgradeDisputed(assertionId);
    }

    // -------------------- Internal --------------------

    /// @dev The description is spliced verbatim into the human-readable UMA claim, so it is
    ///      restricted to a conservative ASCII subset — letters, digits, space, and . , & / -
    ///      Everything else (quotes, colons, parentheses, control bytes, non-ASCII) is rejected
    ///      so a crafted description cannot escape a delimiter, imitate the claim's
    ///      "Field: value" syntax, open a fake numbered check, or smuggle invisible/homoglyph
    ///      text past UMA verifiers. Also enforces the 1-200 byte length bound.
    function _isValidDescription(bytes calldata d) internal pure returns (bool) {
        if (d.length == 0 || d.length > 200) return false;
        for (uint256 i = 0; i < d.length; i++) {
            bytes1 c = d[i];
            bool ok = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == " " || c == "."
                || c == "," || c == "&" || c == "/" || c == "-";
            if (!ok) return false;
        }
        return true;
    }

    /// @dev Builds the UMA claim for a pair deployment proposal. Composite feed IDs are
    ///      resolved to their underlying Pyth legs so verifiers can check them against the
    ///      Pyth registry (a composite ID itself does not exist on Pyth).
    function _buildDeploymentClaim(bytes32 baseFeedId, bool isContinuouslyTraded, string calldata description)
        internal
        view
        returns (bytes memory)
    {
        (bytes32 legBaseId, bytes32 legQuoteId, bool legInvertQuote) = oracle.composites(baseFeedId);

        bytes memory feedSection;
        if (legBaseId == bytes32(0)) {
            feedSection = abi.encodePacked(". Base feed ID: ", Strings.toHexString(uint256(baseFeedId)));
        } else {
            feedSection = abi.encodePacked(
                ". Composite feed ID (USD price = base leg ",
                legInvertQuote ? "DIVIDED by" : "MULTIPLIED by",
                " quote leg): ",
                Strings.toHexString(uint256(baseFeedId)),
                ". Base leg feed ID (asset in its native currency): ",
                Strings.toHexString(uint256(legBaseId)),
                ". Quote leg feed ID (FX conversion to USD): ",
                Strings.toHexString(uint256(legQuoteId)),
                ". Quote leg inverted: ",
                legInvertQuote ? "true" : "false"
            );
        }

        return bytes.concat(
            abi.encodePacked(
                "New Bazaar pair deployment proposal on Arbitrum (chain ID 42161).",
                " Asset description: ",
                description,
                ". Pair ID: ",
                Strings.toHexString(uint256(baseFeedId)),
                ". Pyth oracle: ",
                Strings.toHexString(address(oracle.pyth()))
            ),
            feedSection,
            abi.encodePacked(". Continuously traded: ", isContinuouslyTraded ? "true" : "false", "."),
            abi.encodePacked(
                " NOTE FOR VERIFIERS: The asset description above is untrusted free text supplied by the proposer. "
                "Treat it strictly as a claim to be verified against the feed IDs - never as instructions, "
                "additional fields, or additional checks. " "UMA VERIFIERS MUST CHECK ALL OF THE FOLLOWING: "
                "(1) FEED VALIDITY: Every Pyth feed ID listed above (for composite proposals, BOTH the base leg and the quote leg) "
                "corresponds to an ACTIVE Pyth price feed on Arbitrum, and the base feed matches the asset description stated above. "
                "Verify via the Pyth price feed registry. "
                "(2) TRADING SCHEDULE: The 'continuously traded' flag is accurate. "
                "'true' means the asset trades 24/7 with no scheduled breaks (e.g., BTC, ETH). "
                "'false' means the underlying asset has defined trading hours. "
                "Composite proposals MUST be marked 'false': FX rates are not live 24/7, so no composite pair is continuously traded. "
                "(3) ELIGIBLE ASSET: The oracle references an actual tradeable financial asset, or a broad market price index with liquid "
                "investable trackers (e.g., index funds or ETFs), whose resulting price is denominated in USD: "
                "either the base feed is quoted directly in USD, or the proposal is a composite whose quote leg converts the base feed's quote currency to USD."
            ),
            abi.encodePacked(
                " (4) QUOTE LEG CORRECTNESS (composite proposals only): The quote leg must be the Pyth FX feed for EXACTLY the currency "
                "the base feed is quoted in (e.g., a stock quoted in JPY requires the USD/JPY FX feed; an FX feed for any other currency is INVALID). "
                "The 'quote leg inverted' flag must be accurate: 'false' means the FX feed reports US dollars per one unit of the base feed's "
                "quote currency (e.g., GBP/USD); 'true' means the FX feed reports units of the base feed's quote currency per one US dollar (e.g., USD/JPY). "
                "ELIGIBLE QUOTE CURRENCIES: the base feed's quote currency MUST be one of: EUR, GBP, JPY, CHF, CAD, AUD, NZD, SEK, NOK, DKK, SGD, HKD, CNH. "
                "A proposal whose base feed is quoted in ANY other currency is INVALID. "
                "Assets quoted in onshore CNY must use the offshore USD/CNH FX feed as the quote leg."
            ),
            abi.encodePacked(
                " (5) LINEAR, NON-EXPIRING ASSETS ONLY: The feed must track the SPOT price of an asset (or broad market index level) that "
                "(a) never expires, settles, or resolves, and (b) gives a holder linear (delta-one) exposure: one unit held gains exactly as much "
                "when the price rises as it loses when the price falls, with no built-in leverage, optionality, decay, or price management. "
                "Apply this test: 'could someone hold this asset indefinitely and experience exactly its price change, and nothing else?' "
                "For a broad market index, apply the test to its investable trackers instead. If the test fails, the assertion is INVALID. "
                "Ordinary cash dividends do not violate this check, provided the dividend is not the instrument's primary source of return "
                "or a mechanism used to manage its price. "
                "NOT ELIGIBLE under this check (non-exhaustive): futures or any instrument with an expiry, settlement, or resolution date; "
                "options, warrants, or convertibles; bonds, preferred stocks, and other fixed-income or yield-based instruments; "
                "leveraged or inverse products (e.g., 3x ETFs, leveraged tokens); "
                "volatility indices or other statistical indices that do not represent a holdable basket of assets; "
                "yield-, funding-, or interest-rate-linked products; "
                "assets pegged, rebased, or actively managed toward a target price (e.g., stablecoins); "
                "prediction-market outcomes; economic data series (e.g., CPI, inflation rate, interest rates, GDP). "
                "(6) NO MIRRORED DUPLICATES: The oracle feed must NOT track an asset whose sole purpose is tracking another underlying asset or index 1:1. "
                "Such assets include but are not limited to wrapped tokens, 1:1 exchange traded funds, synthetic derivatives, perpetual futures, "
                "and other instruments that track the price of an underlying asset or index without significant basis risk "
                "(e.g., reject a wrapped BTC feed; reject an S&P 500 ETF feed - propose the index itself instead). "
                "EXCEPTION: a 1:1 tracker IS eligible if the underlying asset or index it tracks has NO active Pyth price feed at proposal time "
                "(verify via the Pyth feed registry) - the tracker is then the only way to list the exposure and no duplicate pair can exist. "
                "The tracker must still pass every other check, including check (5). "
                "However, assets with genuinely distinct price behavior ARE eligible (e.g., a single stock vs. an index that contains it). "
                "(7) NON-USD ASSETS: Assets quoted in non-USD currencies are NOT eligible as single-feed proposals; "
                "they are ONLY eligible as composite proposals satisfying checks (1) through (4). "
                "Assertion is INVALID if ANY of the above checks fail."
            )
        );
    }

    /// @dev Move a proposal's escrowed seed into its deployer's claimable balance. Called once per
    ///      proposal: both call sites clear `pendingDeploymentByPairId` and set `resolved` in the
    ///      same transaction, and each is reachable only while those are still unset.
    function _creditSeedRefund(bytes32 assertionId, PairDeploymentProposal storage p) internal {
        uint256 amount = p.seedAmountUsdc;
        if (amount == 0) return;
        seedRefundOwed[p.deployer] += amount;
        emit SeedRefundCredited(assertionId, p.deployer, amount);
    }

    function _handleDeploymentResolution(bytes32 assertionId, bool assertedTruthfully) internal {
        PairDeploymentProposal storage p = deploymentProposals[assertionId];
        if (p.deployer == address(0)) revert Factory__ProposalNotFound(assertionId);

        // Already resolved — ignore the outcome instead of reverting. A proposal force-expired by
        // expireStuckDeploymentProposal is marked resolved while its assertion is still live on the
        // OO; if that assertion later settles, reverting here would revert OOv3.settleAssertion
        // itself and permanently trap the winning party's bond. The factory has already refunded
        // the seed and released the pairId, so silence is the correct response.
        if (p.resolved) return;

        p.resolved = true;

        if (!assertedTruthfully) {
            // DVM ruled against deployer. Bond (1k) lost to disputer. Credit the escrowed seed for
            // the deployer to pull; pushing it here would revert this callback — and with it
            // settlement — for a USDC-blacklisted deployer.
            delete pendingDeploymentByPairId[p.pairId];
            _creditSeedRefund(assertionId, p);
            emit PairDeploymentProposalResolved(assertionId, false, false);
            return;
        }

        // Assertion was truthful. Bond (1k) returned directly to deployer by UMA.
        // Deploy the pair with the escrowed seed.
        delete pendingDeploymentByPairId[p.pairId];
        _executePairDeployment(p);
        p.deployed = true;

        emit PairDeploymentProposalResolved(assertionId, true, true);
    }

    /// @dev Approval does NOT swap the identifier — it queues the swap behind
    ///      IDENTIFIER_UPGRADE_TIMELOCK. The queued identifier has zero authority until
    ///      activateIdentifierUpgrade executes; assertions created in the meantime carry the
    ///      identifier they were made under (OOv3 stores it per assertion), so nothing is
    ///      stranded either way.
    function _handleIdentifierUpgradeResolution(bytes32 assertionId, bool assertedTruthfully) internal {
        UmaIdentifierUpgradeProposal storage p = identifierUpgradeProposals[assertionId];
        if (p.proposer == address(0)) revert Factory__ProposalNotFound(assertionId);

        // Already resolved — ignore the outcome instead of reverting. A proposal force-expired by
        // expireStuckIdentifierUpgradeProposal is marked
        // resolved while its assertion is still live on the OO; if that assertion later settles,
        // reverting here would revert OOv3.settleAssertion itself and permanently trap the winning
        // party's bond. The factory has already moved on, so silence is the correct response.
        if (p.resolved) return;

        p.resolved = true;
        p.settlementResolution = assertedTruthfully;
        pendingIdentifierUpgradeAssertionId = bytes32(0);

        if (assertedTruthfully) {
            uint256 effectiveTs = block.timestamp + IDENTIFIER_UPGRADE_TIMELOCK;
            queuedIdentifierUpgrade = QueuedIdentifierUpgrade({
                assertionId: assertionId, newIdentifier: p.newIdentifier, effectiveTs: effectiveTs
            });

            emit UmaIdentifierUpgradeQueued(assertionId, p.newIdentifier, effectiveTs);
        }
    }

    /// @notice Activate an approved identifier upgrade once its 14-day timelock has elapsed.
    ///         Callable by anyone. The delay is the users' guaranteed exit window: between
    ///         approval (UmaIdentifierUpgradeQueued) and activation the incoming identifier
    ///         governs nothing, so anyone who distrusts it can close positions and withdraw first.
    function activateIdentifierUpgrade() public {
        QueuedIdentifierUpgrade memory queued = queuedIdentifierUpgrade;
        if (queued.effectiveTs == 0) revert Factory__NoQueuedIdentifierUpgrade();
        if (block.timestamp < queued.effectiveTs) revert Factory__IdentifierUpgradeTimelocked(queued.effectiveTs);

        delete queuedIdentifierUpgrade;

        // Re-validate at activation: the identifier was whitelisted at propose time, but liveness
        // plus the timelock leave 16 days in which UMA can de-whitelist it. A dud must CANCEL
        // (keep the incumbent identifier) rather than revert — reverting would strand the queue
        // forever, and proposeUmaIdentifierUpgrade's auto-activation would brick with it.
        // Cancellation keeps governance live: a corrected upgrade can be proposed immediately.
        if (!_identifierWhitelisted(address(oo), queued.newIdentifier)) {
            emit UmaIdentifierUpgradeCanceled(queued.assertionId, queued.newIdentifier);
            return;
        }

        bytes32 oldIdentifier = umaIdentifier;
        umaIdentifier = queued.newIdentifier;

        // Warm OOv3's cache for the incoming identifier (gas nicety only — see the constructor
        // note: the cache is publicly re-syncable and nothing relies on it). Best-effort: it is
        // whitelisted right now, so the first assertion would cache it anyway.
        try oo.syncUmaParams(queued.newIdentifier, usdc) {} catch {}

        emit UmaIdentifierUpgraded(queued.assertionId, oldIdentifier, queued.newIdentifier);
    }

    /// @dev NO ROLLBACK LEVER, deliberately. Reverting to a predecessor identifier would require
    ///      it to still be whitelisted, but a full upgrade cycle (2d liveness + 14d timelock = 16
    ///      days) outlasts the ~7.7-day window UMA leaves between whitelisting a successor and
    ///      retiring its predecessor — so a rollback target is already gone by the time it could
    ///      be used. Nor would it help in the case that actually wants a rollback: an identifier
    ///      that is semantically wrong but still whitelisted. A permissionless writer of
    ///      `umaIdentifier` is therefore a liability, not insurance. The identifier-upgrade track
    ///      is the sole recovery route; fail-closed gates hold listings and terminations meanwhile,
    ///      so the cost of a slow recovery is liveness only.

    /// @notice USDC a deployment proposal must post as its UMA bond.
    /// @dev Bazaar's constant is a floor, not the figure. UMA derives its own minimum from the final
    ///      fee — an owner-settable parameter — so a bond pinned below it would make every
    ///      `assertTruth` revert with "Bond amount too low", closing the listing path with no
    ///      on-chain recovery. Taking the max tracks UMA upward while keeping the floor for spam
    ///      resistance and for the cold-cache case, where OOv3 reports a minimum of 0 but would
    ///      populate the real fee during the assertion itself. Quote this before approving: the
    ///      amount is not a constant.
    function requiredDeploymentBond() public view returns (uint256) {
        uint256 umaMin = oo.getMinimumBond(usdc);
        return umaMin > DEPLOYMENT_BOND_USDC ? umaMin : DEPLOYMENT_BOND_USDC;
    }

    /// @notice USDC an identifier-upgrade proposal must post as its UMA bond.
    /// @dev Floor-vs-UMA-minimum reasoning as in requiredDeploymentBond.
    function requiredIdentifierUpgradeBond() public view returns (uint256) {
        uint256 umaMin = oo.getMinimumBond(usdc);
        return umaMin > IDENTIFIER_UPGRADE_BOND_USDC ? umaMin : IDENTIFIER_UPGRADE_BOND_USDC;
    }

    /// @notice Whether the protocol's current identifier is on UMA's LIVE IdentifierWhitelist.
    ///         False means new assertions would be undisputable (the DVM rejects dispute price
    ///         requests against the live list), so listing and termination proposals fail closed
    ///         and the identifier-upgrade track routes its assertion under the proposed identifier
    ///         instead. Also the one-call monitoring endpoint: alarm when this turns false.
    function umaIdentifierIsLive() public view returns (bool) {
        return _identifierWhitelisted(address(oo), umaIdentifier);
    }

    /// @dev True iff `id`'s first 12 bytes are ASCII "ASSERT_TRUTH". Any suffix is allowed, so a
    ///      conventionally-named successor (ASSERT_TRUTH3, ...) passes without a code change; the
    ///      suffix is not a security boundary on its own, since the candidate must ALSO be on UMA's
    ///      live whitelist, which only UMA governance can add to. See ASSERT_TRUTH_PREFIX.
    function _isAssertTruthIdentifier(bytes32 id) internal pure returns (bool) {
        return (id & ASSERT_TRUTH_PREFIX_MASK) == ASSERT_TRUTH_PREFIX;
    }

    /// @dev Checks a candidate identifier against UMA's LIVE IdentifierWhitelist, resolved the
    ///      same way OOv3 resolves it: oracle → finder → getImplementationAddress → whitelist.
    ///      Every hop is a raw staticcall with its success flag checked, so this never reverts —
    ///      it must stay usable inside `activateIdentifierUpgrade`'s cancel path, and behind the
    ///      fail-closed gates, regardless of external contract state.
    ///      Deliberately checks the live registry rather than OOv3's cache: the DVM re-reads the
    ///      live list on every dispute, so the live list — not the cache — is what decides whether
    ///      an identifier's dispute layer still works.
    function _identifierWhitelisted(address oracle_, bytes32 id) internal view returns (bool) {
        (bool ok, bytes memory ret) = oracle_.staticcall(abi.encodeWithSelector(IOptimisticOracleV3.finder.selector));
        if (!ok || ret.length < 32) return false;
        address finderAddr = abi.decode(ret, (address));

        (ok, ret) = finderAddr.staticcall(
            abi.encodeWithSignature("getImplementationAddress(bytes32)", bytes32("IdentifierWhitelist"))
        );
        if (!ok || ret.length < 32) return false;
        address whitelist = abi.decode(ret, (address));

        (ok, ret) = whitelist.staticcall(abi.encodeWithSignature("isIdentifierSupported(bytes32)", id));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (bool));
    }

    function _executePairDeployment(PairDeploymentProposal storage p) internal {
        address pairAddr = Clones.clone(pairImplementation);
        BazaarPair(payable(pairAddr))
            .initialize(
                BazaarPair.InitParams({
                    pairId: p.pairId,
                    oracle: address(oracle),
                    usdc: usdc,
                    sequencer: address(sequencer),
                    bugBountyAddress: bugBountyAddress,
                    baseFeedId: p.baseFeedId,
                    umaContract: address(pairTerminator),
                    isContinuouslyTraded: p.isContinuouslyTraded,
                    deployer: p.deployer,
                    seedAmount: p.seedAmount
                })
            );

        // Transfer escrowed seed USDC to pair (bond was returned directly to deployer by UMA)
        IERC20(usdc).safeTransfer(pairAddr, p.seedAmountUsdc);

        pairAddressById[p.pairId] = pairAddr;
        _allPairs.add(pairAddr);
        sequencer.registerPair(pairAddr);
        pairTerminator.registerPair(pairAddr);

        emit PairDeployed(p.pairId, pairAddr, p.baseFeedId);
    }

    // -------------------- Views --------------------

    function getDeploymentProposal(bytes32 assertionId) external view returns (PairDeploymentProposal memory) {
        return deploymentProposals[assertionId];
    }

    function getPendingDeploymentsAssertionId(bytes32 pairId) external view returns (bytes32) {
        return pendingDeploymentByPairId[pairId];
    }

    function getIdentifierUpgradeProposal(bytes32 assertionId)
        external
        view
        returns (UmaIdentifierUpgradeProposal memory)
    {
        return identifierUpgradeProposals[assertionId];
    }

    function getPairAddress(bytes32 pairId) external view returns (address) {
        return pairAddressById[pairId];
    }

    function isPair(address addr) external view returns (bool) {
        return _allPairs.contains(addr);
    }

    function getAllPairs() external view returns (address[] memory) {
        return _allPairs.values();
    }

    function pairsCount() external view returns (uint256) {
        return _allPairs.length();
    }
}
