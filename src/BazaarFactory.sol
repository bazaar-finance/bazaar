// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BazaarPair} from "./BazaarPair.sol";
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

    struct UmaOracleUpgradeProposal {
        address proposer;
        address newOracleAddress;
        bytes32 newIdentifier;
        uint256 proposalTs;
        bool resolved;
        bool settlementResolution;
    }

    /// @notice An APPROVED oracle upgrade waiting out its activation timelock.
    ///         effectiveTs == 0 means nothing is queued.
    struct QueuedOracleUpgrade {
        bytes32 assertionId;
        address newOracleAddress;
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

    event UmaOracleUpgradeProposed(
        bytes32 indexed assertionId, address indexed proposer, address newOracleAddress, bytes32 newIdentifier
    );

    event UmaOracleUpgradeDisputed(bytes32 indexed assertionId);

    /// @notice An upgrade proposal was approved and queued; it activates at effectiveTs. This
    ///         event is the user-facing exit signal: anyone who distrusts the incoming oracle has
    ///         until effectiveTs to close positions and withdraw.
    event UmaOracleUpgradeQueued(
        bytes32 indexed assertionId, address newOracleAddress, bytes32 newIdentifier, uint256 effectiveTs
    );

    event UmaOracleUpgraded(
        bytes32 indexed assertionId, address oldOracle, address newOracle, bytes32 oldIdentifier, bytes32 newIdentifier
    );

    /// @notice A queued upgrade was dropped at activation because the candidate oracle failed the
    ///         conformance probe (no code, or basic OOv3 views revert). The incumbent oracle stays
    ///         in place; governance keeps working and a corrected upgrade can be proposed.
    event UmaOracleUpgradeCanceled(bytes32 indexed assertionId, address newOracleAddress, bytes32 newIdentifier);

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
    error Factory__OracleUpgradeStillPending();
    error Factory__OracleUpgradeNoChange();
    error Factory__InvalidIdentifier();
    error Factory__NoQueuedOracleUpgrade();
    error Factory__OracleUpgradeTimelocked(uint256 effectiveTs);
    error Factory__OracleProbeFailed(address newOracleAddress);

    // -------------------- Constants --------------------
    uint256 public constant MIN_DEPLOYMENT_AMOUNT = 4_000 * 1e18; // 4000 USDC in BAZAAR_SCALE (1k bond + 3k+ seed)
    uint256 public constant DEPLOYMENT_BOND_USDC = 1_000 * 1e6; // 1000 USDC bond for pair-deployment assertion
    bytes32 public umaIdentifier = "ASSERT_TRUTH2";
    uint64 public constant DEPLOYMENT_LIVENESS = 48 hours;

    // Stricter than pair-deployment params because the UMA oracle is protocol-wide
    // governance; a 14-day window leaves enough time for honest disputers to react.
    uint256 public constant ORACLE_UPGRADE_BOND_USDC = 5_000 * 1e6;
    uint64 public constant ORACLE_UPGRADE_LIVENESS = 14 days;
    /// @notice Delay between an upgrade proposal being APPROVED and the new oracle taking effect.
    ///         The dispute window defends against bad proposals; this timelock is the second line:
    ///         if a malicious upgrade somehow survives liveness/DVM, users get 14 days' notice
    ///         to close positions and exit before the new oracle gains any authority. (Insurance-LP
    ///         withdrawals remain subject to their 20-day cooldown, which outlasts the timelock.)
    uint256 public constant ORACLE_UPGRADE_TIMELOCK = 14 days;

    // -------------------- Storage --------------------
    address public immutable usdc;
    BazaarOracle public immutable oracle;
    address public immutable bugBountyAddress;
    address public immutable pairImplementation;
    BazaarSequencer public sequencer;
    BazaarPairLens public immutable lens;
    BazaarPairTerminator public pairTerminator;
    IOptimisticOracleV3 public oo;

    // pairId => deployed pair address
    mapping(bytes32 => address) public pairAddressById;

    // assertionId => deployment proposal
    mapping(bytes32 => PairDeploymentProposal) public deploymentProposals;

    // pairId => pending assertionId (only cleared when claim is rejected)
    mapping(bytes32 => bytes32) public pendingDeploymentByPairId;

    // assertionId => oracle upgrade proposal
    mapping(bytes32 => UmaOracleUpgradeProposal) public oracleUpgradeProposals;

    /// @notice The Optimistic Oracle an assertion was created against, recorded at proposal time.
    /// @dev Settlement and callback auth route through this per-assertion OO rather than the
    ///      mutable `oo` pointer, so an oracle upgrade can't strand in-flight assertions
    ///      (their bonds/escrowed seeds) created against the previous oracle.
    mapping(bytes32 => IOptimisticOracleV3) public assertionOo;

    // pending oracle upgrade assertion (only one at a time)
    bytes32 public pendingOracleUpgradeAssertionId;

    // approved oracle upgrade waiting out ORACLE_UPGRADE_TIMELOCK (only one at a time)
    QueuedOracleUpgrade public queuedOracleUpgrade;

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
        address _pairTerminator
    ) {
        if (_usdc == address(0)) revert Factory__ZeroAddress();
        if (_oracle == address(0)) revert Factory__ZeroAddress();
        if (_lens == address(0)) revert Factory__ZeroAddress();
        if (_bugBountyAddress == address(0)) revert Factory__ZeroAddress();
        if (_optimisticOracleV3 == address(0)) revert Factory__ZeroAddress();
        if (_pairImplementation == address(0)) revert Factory__ZeroAddress();
        if (_sequencer == address(0)) revert Factory__ZeroAddress();
        if (_pairTerminator == address(0)) revert Factory__ZeroAddress();
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
    }

    // -------------------- Phase 1: Propose Pair Deployment --------------------

    /// @notice Propose a new pair deployment. Requires minimum 4000 USDC: 1k UMA bond + 3k+ seed.
    /// @param baseFeedId Pyth price feed ID for the base asset, or a composite feed ID registered
    ///        on the BazaarOracle (for assets quoted in a non-USD currency).
    /// @param isContinuouslyTraded True if asset trades 24/7 (crypto), false for assets with trading hours (stocks).
    ///        Must be false for composite (non-USD-quoted) pairs — FX rates are not live 24/7.
    /// @param totalAmount Total deposit in BAZAAR_SCALE (1e18). Minimum 4000 USDC. 1k goes to UMA bond, rest is seed.
    /// @param description Human-readable asset description, e.g. "AAPL on NASDAQ". Max 200 chars.
    /// @return assertionId The UMA assertion ID for tracking this proposal.
    function proposePairDeployment(
        bytes32 baseFeedId,
        bool isContinuouslyTraded,
        uint256 totalAmount,
        string calldata description
    ) external nonReentrant returns (bytes32 assertionId) {
        if (totalAmount < MIN_DEPLOYMENT_AMOUNT) revert Factory__SeedBelowMinimum();
        if (bytes(description).length == 0 || bytes(description).length > 200) revert Factory__DescriptionInvalid();

        // Composite (non-USD-quoted) pairs depend on an FX leg that does not tick 24/7,
        // so they can never be continuously traded
        (bytes32 compositeBaseLeg,,) = oracle.composites(baseFeedId);
        if (compositeBaseLeg != bytes32(0) && isContinuouslyTraded) {
            revert Factory__CompositePairMustBeNonContinuous();
        }

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

        // Pull total from deployer. 1k bond goes to UMA (user is asserter, gets it back on success).
        // Remainder is escrowed in factory and transferred to pair on deployment.
        uint256 totalAmountUsdc = totalAmount / 1e12;
        uint256 seedAmountUsdc = totalAmountUsdc - DEPLOYMENT_BOND_USDC;
        // µUSDC-aligned: the seed credited to the pair exactly matches the USDC escrowed (no
        // sub-µUSDC dust retained in the 1e18 bookkeeping vs the floored 1e6 amount held).
        uint256 seedAmount = seedAmountUsdc * 1e12;
        IERC20Minimal usdcToken = IERC20Minimal(usdc);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), totalAmountUsdc);
        IERC20(usdc).forceApprove(address(oo), DEPLOYMENT_BOND_USDC);

        // Build claim and submit to UMA
        bytes memory claim = _buildDeploymentClaim(baseFeedId, isContinuouslyTraded, description);

        assertionId = oo.assertTruth(
            claim,
            msg.sender, // asserter = deployer (bond refunded directly to them on success)
            address(this), // callbackRecipient = factory
            address(0), // no escalation manager
            DEPLOYMENT_LIVENESS,
            usdcToken,
            DEPLOYMENT_BOND_USDC,
            umaIdentifier,
            bytes32(0)
        );

        // Store proposal. Record the OO this assertion was created against so it settles on
        // that oracle even if `oo` is later upgraded.
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

    // -------------------- UMA Oracle Upgrade --------------------

    /// @notice Propose upgrading the UMA oracle contract and/or identifier.
    function proposeUmaOracleUpgrade(address newOracleAddress, bytes32 newIdentifier)
        external
        nonReentrant
        returns (bytes32 assertionId)
    {
        if (newOracleAddress == address(0)) revert Factory__ZeroAddress();
        if (newIdentifier == bytes32(0)) revert Factory__InvalidIdentifier();

        // If there's a pending upgrade, try to settle it first
        if (pendingOracleUpgradeAssertionId != bytes32(0)) {
            try this.settleOracleUpgradeProposal(pendingOracleUpgradeAssertionId) {}
            catch {
                revert Factory__OracleUpgradeStillPending();
            }
        }

        // An approved upgrade waiting out its timelock blocks new proposals; once the timelock
        // has elapsed, activate it now rather than leaving it stranded.
        if (queuedOracleUpgrade.effectiveTs != 0) {
            if (block.timestamp < queuedOracleUpgrade.effectiveTs) {
                revert Factory__OracleUpgradeStillPending();
            }
            activateOracleUpgrade();
        }

        // Must propose at least one change
        if (newOracleAddress == address(oo) && newIdentifier == umaIdentifier) {
            revert Factory__OracleUpgradeNoChange();
        }

        // Conformance probe: a candidate that can't answer basic OOv3 views would, once
        // activated, revert every assertTruth call-site — pair listings, UMA terminations, and
        // this function itself (the only repair path), bricking governance permanently. Fail
        // fast here before the bond moves; activateOracleUpgrade re-probes in case the
        // candidate breaks during the ~28 days of liveness + timelock.
        if (!_oracleProbeOk(newOracleAddress)) revert Factory__OracleProbeFailed(newOracleAddress);

        IERC20Minimal usdcToken = IERC20Minimal(usdc);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), ORACLE_UPGRADE_BOND_USDC);
        IERC20(usdc).forceApprove(address(oo), ORACLE_UPGRADE_BOND_USDC);

        bytes memory claim = bytes.concat(
            abi.encodePacked(
                "UMA oracle upgrade proposal for Bazaar protocol on Arbitrum (chain ID 42161).",
                " Current oracle: ",
                Strings.toHexString(address(oo)),
                ". Current identifier: ",
                Strings.toHexString(uint256(umaIdentifier)),
                ". Proposed new oracle: ",
                Strings.toHexString(newOracleAddress),
                ". Proposed new identifier: ",
                Strings.toHexString(uint256(newIdentifier)),
                "."
            ),
            abi.encodePacked(
                " HOW TO VALIDATE: "
                "NOTE: Identifiers are displayed as hex-encoded bytes32 values. To verify, convert the hex to a UTF-8 string "
                "(e.g., 0x4153534552545f545255544832... decodes to 'ASSERT_TRUTH2'). " "UMA voters should verify that: "
                "(1) The proposed new oracle address is a legitimate UMA Optimistic Oracle V3 deployment on Arbitrum. "
                "(2) The proposed new identifier is an active, non-deprecated identifier approved by UMA governance. "
                "(3) The upgrade is necessary because the current identifier or oracle is deprecated or will be deprecated. "
                "Assertion is INVALID if: the new address is not a legitimate UMA OOV3 contract, the new identifier is not approved, "
                "or there is no need for the upgrade (current oracle and identifier are still functional)."
            )
        );

        assertionId = oo.assertTruth(
            claim,
            msg.sender,
            address(this),
            address(0),
            ORACLE_UPGRADE_LIVENESS,
            usdcToken,
            ORACLE_UPGRADE_BOND_USDC,
            umaIdentifier,
            bytes32(0)
        );

        assertionOo[assertionId] = oo;
        pendingOracleUpgradeAssertionId = assertionId;

        oracleUpgradeProposals[assertionId] = UmaOracleUpgradeProposal({
            proposer: msg.sender,
            newOracleAddress: newOracleAddress,
            newIdentifier: newIdentifier,
            proposalTs: block.timestamp,
            resolved: false,
            settlementResolution: false
        });

        emit UmaOracleUpgradeProposed(assertionId, msg.sender, newOracleAddress, newIdentifier);
    }

    // -------------------- Phase 2: UMA Callbacks & Settlement --------------------

    /// @notice settle a deployment proposal after liveness expires (fallback to callback).
    function settleDeploymentProposal(bytes32 assertionId) external {
        PairDeploymentProposal storage p = deploymentProposals[assertionId];
        if (p.deployer == address(0)) revert Factory__ProposalNotFound(assertionId);
        if (p.resolved) revert Factory__ProposalAlreadyResolved(assertionId);

        assertionOo[assertionId].settleAndGetAssertionResult(assertionId);
    }

    /// @notice settle an oracle upgrade proposal after liveness expires.
    function settleOracleUpgradeProposal(bytes32 assertionId) external {
        UmaOracleUpgradeProposal storage p = oracleUpgradeProposals[assertionId];
        if (p.proposer == address(0)) revert Factory__ProposalNotFound(assertionId);
        if (p.resolved) revert Factory__ProposalAlreadyResolved(assertionId);

        assertionOo[assertionId].settleAndGetAssertionResult(assertionId);
    }

    /// @notice Called by UMA oracle when assertion is resolved (after liveness or DVM vote).
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external override {
        // Auth against the OO this assertion was created on, not the (possibly upgraded) `oo`
        // pointer — so a callback from the original oracle still authenticates after an upgrade.
        if (msg.sender != address(assertionOo[assertionId])) revert Factory__OnlyUmaOracle();

        if (deploymentProposals[assertionId].deployer != address(0)) {
            _handleDeploymentResolution(assertionId, assertedTruthfully);
            return;
        }

        _handleOracleUpgradeResolution(assertionId, assertedTruthfully);
    }

    /// @notice Called by UMA oracle when assertion is disputed. Proposal stays pending during DVM voting.
    function assertionDisputedCallback(bytes32 assertionId) external override {
        if (msg.sender != address(assertionOo[assertionId])) revert Factory__OnlyUmaOracle();

        if (deploymentProposals[assertionId].deployer != address(0)) {
            emit PairDeploymentProposalDisputed(assertionId);
            return;
        }

        emit UmaOracleUpgradeDisputed(assertionId);
    }

    // -------------------- Internal --------------------

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
                " UMA VERIFIERS MUST CHECK ALL OF THE FOLLOWING: "
                "(1) FEED VALIDITY: Every Pyth feed ID listed above (for composite proposals, BOTH the base leg and the quote leg) "
                "corresponds to an ACTIVE Pyth price feed on Arbitrum, and the base feed matches the described asset ('",
                description,
                "'). Verify via the Pyth price feed registry. "
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

    function _handleDeploymentResolution(bytes32 assertionId, bool assertedTruthfully) internal {
        PairDeploymentProposal storage p = deploymentProposals[assertionId];
        if (p.deployer == address(0)) revert Factory__ProposalNotFound(assertionId);
        if (p.resolved) revert Factory__ProposalAlreadyResolved(assertionId);

        p.resolved = true;

        if (!assertedTruthfully) {
            // DVM ruled against deployer. Bond (1k) lost to disputer. Refund escrowed seed.
            delete pendingDeploymentByPairId[p.pairId];
            if (p.seedAmountUsdc > 0) {
                IERC20(usdc).safeTransfer(p.deployer, p.seedAmountUsdc);
            }
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

    /// @dev Approval does NOT swap the oracle — it queues the swap behind
    ///      ORACLE_UPGRADE_TIMELOCK. The queued oracle has zero authority until
    ///      activateOracleUpgrade executes; assertions created in the meantime are pinned to the
    ///      oracle they were made on (per-assertion routing), so nothing is stranded either way.
    function _handleOracleUpgradeResolution(bytes32 assertionId, bool assertedTruthfully) internal {
        UmaOracleUpgradeProposal storage p = oracleUpgradeProposals[assertionId];
        if (p.proposer == address(0)) revert Factory__ProposalNotFound(assertionId);
        if (p.resolved) revert Factory__ProposalAlreadyResolved(assertionId);

        p.resolved = true;
        p.settlementResolution = assertedTruthfully;
        pendingOracleUpgradeAssertionId = bytes32(0);

        if (assertedTruthfully) {
            uint256 effectiveTs = block.timestamp + ORACLE_UPGRADE_TIMELOCK;
            queuedOracleUpgrade = QueuedOracleUpgrade({
                assertionId: assertionId,
                newOracleAddress: p.newOracleAddress,
                newIdentifier: p.newIdentifier,
                effectiveTs: effectiveTs
            });

            emit UmaOracleUpgradeQueued(assertionId, p.newOracleAddress, p.newIdentifier, effectiveTs);
        }
    }

    /// @notice Activate an approved oracle upgrade once its 14-day timelock has elapsed.
    ///         Callable by anyone. The delay is the users' guaranteed exit window: between
    ///         approval (UmaOracleUpgradeQueued) and activation the incoming oracle has no
    ///         authority, so anyone who distrusts it can close positions and withdraw first.
    function activateOracleUpgrade() public {
        QueuedOracleUpgrade memory queued = queuedOracleUpgrade;
        if (queued.effectiveTs == 0) revert Factory__NoQueuedOracleUpgrade();
        if (block.timestamp < queued.effectiveTs) revert Factory__OracleUpgradeTimelocked(queued.effectiveTs);

        delete queuedOracleUpgrade;

        // Re-probe at activation: the candidate passed the propose-time probe, but liveness plus
        // the timelock leave ~28 days in which it can be deprecated or otherwise break. A dud
        // must CANCEL (keep the incumbent oracle) rather than revert — reverting would strand the
        // queue forever, and proposeUmaOracleUpgrade's auto-activation would brick with it.
        // Cancellation keeps governance live: a corrected upgrade can be proposed immediately.
        if (!_oracleProbeOk(queued.newOracleAddress)) {
            emit UmaOracleUpgradeCanceled(queued.assertionId, queued.newOracleAddress, queued.newIdentifier);
            return;
        }

        address oldOracle = address(oo);
        bytes32 oldIdentifier = umaIdentifier;

        oo = IOptimisticOracleV3(queued.newOracleAddress);
        umaIdentifier = queued.newIdentifier;

        emit UmaOracleUpgraded(
            queued.assertionId, oldOracle, queued.newOracleAddress, oldIdentifier, queued.newIdentifier
        );
    }

    /// @dev Cheap conformance probe on a candidate optimistic oracle: it must have code and
    ///      answer two parameterless OOv3 views. This can't prove assertTruth will succeed
    ///      (identifier and currency whitelists live in UMA's DVM and aren't queryable here),
    ///      so it narrows the brick class — no-code addresses, self-destructed or non-OOv3
    ///      contracts — while identifier legitimacy stays with the DVM dispute layer.
    ///      When only the identifier changes, the candidate is the incumbent and passes trivially.
    function _oracleProbeOk(address candidate) internal view returns (bool) {
        if (candidate.code.length == 0) return false;

        (bool ok, bytes memory ret) =
            candidate.staticcall(abi.encodeWithSelector(IOptimisticOracleV3.defaultIdentifier.selector));
        if (!ok || ret.length != 32) return false;

        (ok, ret) = candidate.staticcall(abi.encodeWithSelector(IOptimisticOracleV3.defaultCurrency.selector));
        return ok && ret.length == 32;
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

    function getOracleUpgradeProposal(bytes32 assertionId) external view returns (UmaOracleUpgradeProposal memory) {
        return oracleUpgradeProposals[assertionId];
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
