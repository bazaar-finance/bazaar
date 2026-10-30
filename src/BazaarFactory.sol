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
import {ClaimTextLib} from "./libraries/ClaimTextLib.sol";
import {BazaarOracle} from "./BazaarOracle.sol";
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
        uint256 seedAmount; // BAZAAR_SCALE (1e18), the insurance seed: the deposit less the UMA bond
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
    /// @notice A listing was approved and its pair deployed and seeded. Carries everything an
    ///         indexer needs to register the pair, including the insurance shares the pair mints
    ///         to the deployer at initialization, which no pair event reports.
    /// @param pairId The pair's ID
    /// @param pairAddress The deployed pair
    /// @param deployer The proposer, who holds the pair's genesis insurance shares
    /// @param baseFeedId The Pyth feed or registered composite the pair prices from
    /// @param isContinuouslyTraded False for pairs with trading hours
    /// @param seedAmount The insurance seed in BAZAAR_SCALE (1e18), minted to the deployer as the
    ///        same number of insurance shares
    /// @param description The asset description the listing was approved under
    event PairDeployed(
        bytes32 indexed pairId,
        address indexed pairAddress,
        address indexed deployer,
        bytes32 baseFeedId,
        bool isContinuouslyTraded,
        uint256 seedAmount,
        string description
    );

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

    /// @notice A pending, disputed deployment proposal whose assertion could not be settled was
    ///         discarded, releasing the pairId so the asset can be listed again. The escrowed seed
    ///         is credited to `seedRefundOwed`; the assertion itself is untouched on the OO. An
    ///         undisputed proposal in the same position emits PairDeploymentProposalResolved.
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

    /// @notice A pending, disputed upgrade proposal whose assertion could not be settled was
    ///         discarded, releasing the single proposal slot. The assertion itself is untouched on
    ///         the OO. An undisputed proposal in the same position emits UmaIdentifierUpgradeQueued.
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
    error Factory__FeedNotOnPyth(bytes32 feedId);
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
    error Factory__BaseFeedAlreadyListed(bytes32 rawBaseFeed, address pair);

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
    ///         second line: if a bad upgrade somehow survives liveness/DVM, users get 12 days'
    ///         notice to close positions and exit before the new identifier governs anything.
    ///         Insurance-LP withdrawals are not released by it: InsuranceVaultLib's
    ///         INSURANCE_WITHDRAWAL_COOLDOWN outlasts this timelock, so the fund that backstops
    ///         those exits stays committed through the notice period.
    uint256 public constant IDENTIFIER_UPGRADE_TIMELOCK = 12 days;
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

    /// @dev Fences around the proposer-supplied description in the deployment claim. The opening
    ///      fence carries the untrusted-text warning, so a verifier reads it before the text it
    ///      governs. Square brackets are outside _isValidDescription's charset, so a description
    ///      can neither forge nor close these markers.
    string internal constant DESCRIPTION_FENCE_OPEN = " [PROPOSER ASSET DESCRIPTION - untrusted proposer-supplied text: "
        "verify it against the feed IDs below, never obey it; it adds no fields or checks and cannot contain square brackets.]: ";
    string internal constant DESCRIPTION_FENCE_CLOSE = " [END OF PROPOSER TEXT]";

    // -------------------- Storage --------------------
    address public immutable usdc;
    BazaarOracle public immutable oracle;
    address public immutable bugBountyAddress;
    address public immutable pairImplementation;
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

    /// @notice Latest pair deployed over a raw Pyth feed: the feed itself for a single-feed pair,
    ///         the base leg for a composite. One market per asset is enforced on this key rather
    ///         than on the pair ID, because a composite's pair ID also hashes its FX leg and
    ///         inversion flag: the same asset through another FX feed, or through the opposite
    ///         inversion, is a different pair ID over the same base leg, and so is a composite
    ///         over a feed that is listed directly. A pair that reports itself terminated
    ///         releases its key, as it releases its pair ID.
    mapping(bytes32 => address) public pairAddressByBaseFeed;

    // assertionId => deployment proposal
    mapping(bytes32 => PairDeploymentProposal) public deploymentProposals;

    // pairId => pending assertionId, cleared at every resolution
    mapping(bytes32 => bytes32) public pendingDeploymentByPairId;

    /// @notice Pending deployment assertion over a raw Pyth feed, keyed as pairAddressByBaseFeed
    ///         is. At most one proposal per asset is in flight, so two composites over one base
    ///         leg cannot both be approved; cleared together with pendingDeploymentByPairId.
    mapping(bytes32 => bytes32) public pendingDeploymentByBaseFeed;

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
    /// @dev `_pairTerminator` is deployed by the deploy script with THIS factory's
    ///      (CREATE-predicted) address baked into its immutable `factory` field — deploying it
    ///      inline here would push the factory's initcode past EIP-3860. The script asserts the
    ///      prediction matched after construction.
    constructor(
        address _usdc,
        address _oracle,
        address _lens,
        address _bugBountyAddress,
        address _optimisticOracleV3,
        address _pairImplementation,
        address _pairTerminator,
        bytes32 _umaIdentifier
    ) {
        if (_usdc == address(0)) revert Factory__ZeroAddress();
        if (_oracle == address(0)) revert Factory__ZeroAddress();
        if (_lens == address(0)) revert Factory__ZeroAddress();
        if (_bugBountyAddress == address(0)) revert Factory__ZeroAddress();
        if (_optimisticOracleV3 == address(0)) revert Factory__ZeroAddress();
        if (_pairImplementation == address(0)) revert Factory__ZeroAddress();
        if (_pairTerminator == address(0)) revert Factory__ZeroAddress();
        if (_umaIdentifier == bytes32(0)) revert Factory__InvalidIdentifier();
        // Wiring consistency: both must have been constructed pointing at this factory.
        if (BazaarPairTerminator(_pairTerminator).factory() != address(this)) revert Factory__WiringMismatch();
        if (BazaarPairLens(_lens).factory() != address(this)) revert Factory__WiringMismatch();
        usdc = _usdc;
        oracle = BazaarOracle(_oracle);
        lens = BazaarPairLens(_lens);
        bugBountyAddress = _bugBountyAddress;
        pairImplementation = _pairImplementation;
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
    ///        on the BazaarOracle (for assets quoted in a non-USD currency). A raw ID must already
    ///        hold a price in this chain's Pyth contract: post one update for a feed that has never
    ///        been pulled here before proposing. No other live pair may price the same raw feed,
    ///        directly or as a composite's base leg (see pairAddressByBaseFeed).
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
        if (compositeBaseLeg != bytes32(0)) {
            if (isContinuouslyTraded) revert Factory__CompositePairMustBeNonContinuous();
        } else {
            // An ID that is not a registered composite must be a feed Pyth has stored a price for
            // on this chain. The composite registry is permissionless and write-once, and the pair
            // resolves its feed ID through it on every read, so without this an unregistered
            // composite hash would pass here as a single feed: the claim would omit the FX leg and
            // its direction, the guard above would not run, and registering the legs after
            // approval would turn the deployed pair into a composite market UMA never reviewed.
            // A stored Pyth price rules that out, because a composite can only ever be registered
            // under the hash of its legs, never under a real feed ID. The same read rejects a
            // mistyped ID before the seed is escrowed against a pair that could never price.
            try oracle.pyth().getPriceUnsafe(baseFeedId) {}
            catch {
                revert Factory__FeedNotOnPyth(baseFeedId);
            }
        }

        // Fail closed while the protocol's identifier is off UMA's live whitelist: disputes on new
        // assertions are impossible in that state (VotingV2 re-checks the live list on every
        // dispute), so a submission here would be adjudicated by nobody and auto-approve after
        // liveness. Reverting keeps junk listings out of an undisputable pipeline; listings resume
        // once the identifier-upgrade track (which stays open — see proposeUmaIdentifierUpgrade)
        // has moved to a live identifier.
        if (!umaIdentifierIsLive()) revert Factory__IdentifierNotWhitelisted(umaIdentifier);

        bytes32 pairId = baseFeedId;
        // The asset the market prices: the feed itself, or the composite's base leg. Uniqueness
        // is enforced on this key (see pairAddressByBaseFeed): for a single-feed proposal it is
        // the pair ID, for a composite it also reaches every other composite over the same leg.
        bytes32 rawBaseFeed = compositeBaseLeg != bytes32(0) ? compositeBaseLeg : baseFeedId;

        // A proposal already in flight over this asset is settled first, so one whose liveness
        // has passed never blocks; one that cannot settle yet holds the slot. The slot is named by
        // the pending proposal's own pair ID, which differs from this one only for a composite
        // over a leg another composite is already proposing.
        bytes32 pendingId = pendingDeploymentByBaseFeed[rawBaseFeed];
        if (pendingId != bytes32(0)) {
            try this.settleDeploymentProposal(pendingId) {}
            catch {
                revert Factory__ProposalAlreadyPending(deploymentProposals[pendingId].pairId);
            }
        }

        // No live (non-terminated) pair under this pair ID ...
        address existing = pairAddressById[pairId];
        if (existing != address(0)) {
            BazaarPair existingPair = BazaarPair(payable(existing));
            if (!existingPair.isPairTerminated()) {
                revert Factory__PairAlreadyExists(pairId);
            }
        }
        // ... nor over the same asset under another pair ID: a composite through a different FX
        // leg or inversion, or a composite over a feed that is listed directly. While `existing`
        // is live it is also the holder, so a holder that differs is always another market.
        address holder = pairAddressByBaseFeed[rawBaseFeed];
        if (holder != address(0) && holder != existing && !BazaarPair(payable(holder)).isPairTerminated()) {
            revert Factory__BaseFeedAlreadyListed(rawBaseFeed, holder);
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
        pendingDeploymentByBaseFeed[rawBaseFeed] = assertionId;
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
                "UMA identifier upgrade proposal for Bazaar protocol on Arbitrum (chain ID ",
                Strings.toString(block.chainid),
                ").",
                " Oracle (fixed): ",
                Strings.toHexString(address(oo)),
                ". Current identifier: ",
                Strings.toHexString(uint256(umaIdentifier)),
                ". Proposed new identifier: ",
                Strings.toHexString(uint256(newIdentifier)),
                "."
            ),
            ClaimTextLib.identifierUpgradeHowToValidate()
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

    /// @notice Release a pairId whose deployment assertion cannot be settled on the OO. An
    ///         undisputed proposal is approved and its pair deployed; a disputed one is discarded
    ///         and its escrowed seed made claimable by the deployer. Permissionless.
    /// @dev OOv3 pays the winning party BEFORE firing the resolve callback (`settleAssertion`), so a
    ///      payout that reverts takes settlement down with it and the callback never fires. Every
    ///      outcome has such a party: the deployer receives the bond when undisputed or ruled TRUE,
    ///      and the disputer receives it when ruled FALSE, so a USDC blacklisting on either side
    ///      wedges the corresponding branch. A dispute the DVM never resolves wedges it too — past
    ///      maxRolls the request is deleted and getPrice reverts forever. Without this path the seed
    ///      stays escrowed and the pairId stays occupied, so that asset could never be listed again.
    ///
    ///      Settlement is attempted first, so this is a no-op whenever the proposal can still
    ///      resolve normally. The assertion is left alone on the OO either way: if it ever becomes
    ///      settleable, the winning party can still settle directly to collect their bond, and the
    ///      factory then ignores the outcome.
    ///
    ///      UNDISPUTED proposals are approved when that attempt fails, never discarded. A failed
    ///      attempt does not show the proposal is stuck: a caller can make it fail on a healthy
    ///      proposal by calling from inside one of OOv3's own callbacks, where the oracle's
    ///      reentrancy lock rejects the nested settlement, and discarding on that evidence would
    ///      give anyone a veto over every listing for the price of gas. The outcome is known
    ///      without settling (_approvalIsFixed), so the factory applies it here. Forcing the
    ///      failure then gains a caller nothing, and a deployer whose bond payout is blocked still
    ///      gets the listing the unchallenged liveness window earned; only the bond waits on the OO.
    ///
    ///      DISPUTED proposals wait out DVM_DISPUTE_GRACE on top of liveness, because being
    ///      unsettleable is expected while the DVM votes and whether that vote finished is not
    ///      queryable from here. Without it a disputer could discard the proposal the instant
    ///      liveness ended regardless of how the DVM later voted, turning one bond into a guaranteed
    ///      veto on any listing. Past the grace they are discarded: their outcome is the DVM's, and
    ///      nothing here can read it.
    /// @param pairId The asset whose pending proposal should be released.
    function expireStuckDeploymentProposal(bytes32 pairId) external nonReentrant {
        bytes32 assertionId = pendingDeploymentByPairId[pairId];
        if (assertionId == bytes32(0)) revert Factory__NoPendingDeployment(pairId);

        PairDeploymentProposal storage p = deploymentProposals[assertionId];
        uint256 expiryTs = p.proposalTs + DEPLOYMENT_LIVENESS;
        if (deploymentDisputed[assertionId]) expiryTs += DVM_DISPUTE_GRACE;
        if (block.timestamp < expiryTs) revert Factory__DeploymentNotExpired(expiryTs);

        // Prefer the real outcome. On success the resolve callback releases the pairId and either
        // deploys the pair or credits the refund, so there is nothing left to do.
        try this.settleDeploymentProposal(assertionId) {
            return;
        } catch {}

        // The verdict is passed on as the value read, not as a literal: a literal argument makes
        // the optimizer compile a second copy of the resolution path for this call site.
        bool approved = _approvalIsFixed(assertionId);
        if (approved) {
            _handleDeploymentResolution(assertionId, approved);
            return;
        }

        p.resolved = true; // makes any late resolve callback a silent no-op
        _releasePending(p);
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

    /// @notice Release the single pending-upgrade slot when its assertion cannot be settled on the
    ///         OO. An undisputed proposal is approved and its upgrade queued behind the timelock; a
    ///         disputed one is discarded. Permissionless.
    /// @dev OOv3 pays the bond BEFORE firing the resolve callback (`settleAssertion`), so if the
    ///      payout reverts — a proposer USDC-blacklisted after proposing, say — settlement reverts
    ///      wholesale, the callback never fires, and this slot stays occupied forever. Without
    ///      this path that permanently blocks every future identifier upgrade.
    ///
    ///      Settlement is attempted first, so this is a no-op whenever the proposal can still
    ///      resolve normally. The assertion is left alone on the OO either way: if it ever becomes
    ///      settleable, the winning party can still settle directly to collect their bond (the
    ///      factory then ignores the outcome).
    ///
    ///      UNDISPUTED proposals are approved when that attempt fails, never discarded, for the
    ///      reason given on expireStuckDeploymentProposal: a caller can force the failure from
    ///      inside one of OOv3's callbacks, and the outcome is known without settling
    ///      (_approvalIsFixed). Approval only queues the upgrade; it still waits out
    ///      IDENTIFIER_UPGRADE_TIMELOCK and the whitelist re-check at activation.
    ///
    ///      DISPUTED proposals are the one case a timer is unavoidable: being unsettleable is
    ///      expected while the DVM votes, and whether that vote has finished is not queryable from
    ///      here (VotingV2 gates hasPrice/getPrice behind onlyRegisteredContract). Waiting out
    ///      DVM_DISPUTE_GRACE keeps a dispute from becoming a cheap veto: without
    ///      it, any disputer could discard the proposal the moment liveness ended, regardless of
    ///      how the DVM later voted. Past the grace they are discarded.
    function expireStuckIdentifierUpgradeProposal() external nonReentrant {
        bytes32 assertionId = pendingIdentifierUpgradeAssertionId;
        if (assertionId == bytes32(0)) revert Factory__NoPendingIdentifierUpgrade();

        UmaIdentifierUpgradeProposal storage p = identifierUpgradeProposals[assertionId];
        uint256 expiryTs = p.proposalTs + IDENTIFIER_UPGRADE_LIVENESS;
        if (p.disputed) expiryTs += DVM_DISPUTE_GRACE;
        if (block.timestamp < expiryTs) revert Factory__IdentifierUpgradeNotExpired(expiryTs);

        // Prefer the real outcome. On success the resolve callback clears the slot and queues the
        // upgrade if it was approved, so there is nothing left to do.
        try this.settleIdentifierUpgradeProposal(assertionId) {
            return;
        } catch {}

        // Passed on as the value read, not as a literal (see expireStuckDeploymentProposal).
        bool approved = _approvalIsFixed(assertionId);
        if (approved) {
            _handleIdentifierUpgradeResolution(assertionId, approved);
            return;
        }

        p.resolved = true; // makes any late resolve callback a silent no-op
        pendingIdentifierUpgradeAssertionId = bytes32(0);

        emit UmaIdentifierUpgradeExpired(assertionId, p.proposer);
    }

    /// @dev Whether OOv3 can only ever resolve `assertionId` as truthful: it exists, nobody
    ///      disputed it, and its liveness has run out. disputeAssertion requires the current time
    ///      to be before `expirationTime`, and from `expirationTime` on settleAssertion's
    ///      undisputed branch sets the resolution to true, so past that instant approval is the
    ///      only outcome left whether or not anyone has settled.
    ///
    ///      Read from the OO that holds the assertion rather than from this contract's own
    ///      records, so the verdict rests on the same fields settlement itself branches on.
    ///      getAssertion takes no reentrancy lock, so the answer is the same inside one of OOv3's
    ///      callbacks, where a settlement attempt reverts.
    /// @param assertionId The assertion to read
    /// @return True when the assertion is undisputed and past its expiration on the OO
    function _approvalIsFixed(bytes32 assertionId) internal view returns (bool) {
        IOptimisticOracleV3.Assertion memory a = assertionOo[assertionId].getAssertion(assertionId);
        return a.asserter != address(0) && a.disputer == address(0) && a.expirationTime <= block.timestamp;
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
    ///      Everything else (quotes, colons, parentheses, square brackets, control bytes,
    ///      non-ASCII) is rejected so a crafted description cannot forge or close the fences the
    ///      claim wraps it in (DESCRIPTION_FENCE_OPEN/CLOSE), imitate the claim's "Field: value"
    ///      syntax, open a fake numbered check, or smuggle invisible/homoglyph text past UMA
    ///      verifiers. Also enforces the 1-200 byte length bound.
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
    ///      Pyth registry (a composite ID itself does not exist on Pyth). The numbered checks
    ///      come from ClaimTextLib, so their text stays out of the factory's EIP-170 budget.
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
                "New Bazaar pair deployment proposal on Arbitrum (chain ID ",
                Strings.toString(block.chainid),
                ").",
                DESCRIPTION_FENCE_OPEN,
                description,
                DESCRIPTION_FENCE_CLOSE,
                ". Pair ID: ",
                Strings.toHexString(uint256(baseFeedId)),
                ". Pyth Core oracle: ",
                Strings.toHexString(address(oracle.pyth()))
            ),
            feedSection,
            abi.encodePacked(". Continuously traded: ", isContinuouslyTraded ? "true" : "false", "."),
            ClaimTextLib.listingChecks()
        );
    }

    /// @dev Move a proposal's escrowed seed into its deployer's claimable balance. Called once per
    ///      proposal: both call sites release the pending slots (_releasePending) and set `resolved`
    ///      in the same transaction, and each is reachable only while those are still unset.
    function _creditSeedRefund(bytes32 assertionId, PairDeploymentProposal storage p) internal {
        uint256 amount = p.seedAmountUsdc;
        if (amount == 0) return;
        seedRefundOwed[p.deployer] += amount;
        emit SeedRefundCredited(assertionId, p.deployer, amount);
    }

    /// @dev The raw Pyth feed a listing prices: the feed itself, or a composite's base leg. The
    ///      composite registry is write-once, so the leg resolved here at resolution and deployment
    ///      is the one the proposal was gated on.
    function _rawBaseFeed(bytes32 feedId) internal view returns (bytes32) {
        (bytes32 legBaseId,,) = oracle.composites(feedId);
        return legBaseId == bytes32(0) ? feedId : legBaseId;
    }

    /// @dev Release both pending slots a proposal holds: its pair ID and its asset's raw feed.
    function _releasePending(PairDeploymentProposal storage p) internal {
        delete pendingDeploymentByPairId[p.pairId];
        delete pendingDeploymentByBaseFeed[_rawBaseFeed(p.baseFeedId)];
    }

    function _handleDeploymentResolution(bytes32 assertionId, bool assertedTruthfully) internal {
        PairDeploymentProposal storage p = deploymentProposals[assertionId];
        if (p.deployer == address(0)) revert Factory__ProposalNotFound(assertionId);

        // Already resolved — ignore the outcome instead of reverting. A proposal resolved by
        // expireStuckDeploymentProposal is marked resolved while its assertion is still live on the
        // OO; if that assertion later settles, reverting here would revert OOv3.settleAssertion
        // itself and permanently trap the winning party's bond. The factory has already released
        // the pairId and either deployed the pair or credited the seed, so silence is the correct
        // response.
        if (p.resolved) return;

        p.resolved = true;

        if (!assertedTruthfully) {
            // DVM ruled against deployer. Bond (1k) lost to disputer. Credit the escrowed seed for
            // the deployer to pull; pushing it here would revert this callback — and with it
            // settlement — for a USDC-blacklisted deployer.
            _releasePending(p);
            _creditSeedRefund(assertionId, p);
            emit PairDeploymentProposalResolved(assertionId, false, false);
            return;
        }

        // Assertion was truthful. The bond is UMA's to return to the deployer when the assertion
        // settles. Deploy the pair with the escrowed seed.
        _releasePending(p);
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

        // Already resolved — ignore the outcome instead of reverting. A proposal resolved by
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

    /// @notice Activate an approved identifier upgrade once its 12-day timelock has elapsed.
    ///         Callable by anyone. The delay is the users' guaranteed exit window: between
    ///         approval (UmaIdentifierUpgradeQueued) and activation the incoming identifier
    ///         governs nothing, so anyone who distrusts it can close positions and withdraw first.
    function activateIdentifierUpgrade() public {
        QueuedIdentifierUpgrade memory queued = queuedIdentifierUpgrade;
        if (queued.effectiveTs == 0) revert Factory__NoQueuedIdentifierUpgrade();
        if (block.timestamp < queued.effectiveTs) revert Factory__IdentifierUpgradeTimelocked(queued.effectiveTs);

        delete queuedIdentifierUpgrade;

        // Re-validate at activation: the identifier was whitelisted at propose time, but liveness
        // plus the timelock leave 14 days in which UMA can de-whitelist it. A dud must CANCEL
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
    ///      it to still be whitelisted, but a full upgrade cycle (2d liveness + 12d timelock = 14
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
                    bugBountyAddress: bugBountyAddress,
                    baseFeedId: p.baseFeedId,
                    umaContract: address(pairTerminator),
                    isContinuouslyTraded: p.isContinuouslyTraded,
                    deployer: p.deployer,
                    seedAmount: p.seedAmount
                })
            );

        // Transfer escrowed seed USDC to pair (the bond sits with UMA, which returns it to the
        // deployer at settlement)
        IERC20(usdc).safeTransfer(pairAddr, p.seedAmountUsdc);

        pairAddressById[p.pairId] = pairAddr;
        pairAddressByBaseFeed[_rawBaseFeed(p.baseFeedId)] = pairAddr;
        _allPairs.add(pairAddr);
        pairTerminator.registerPair(pairAddr);

        emit PairDeployed(
            p.pairId, pairAddr, p.deployer, p.baseFeedId, p.isContinuouslyTraded, p.seedAmount, p.description
        );
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
