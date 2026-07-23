// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

// Consolidated: termination PnL, insurer vote, oracle upgrade, termination price + stale termination.
import {Test} from "forge-std/Test.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";
import {TerminationLib} from "../../src/libraries/TerminationLib.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

// ==================== from Phase2TerminationPnlTest.t.sol ====================

/// @notice Harness that owns its own Vault storage and forwards termination calls into
///         TerminationLib. Lets us construct the both-sides-negative-aggregate-PnL scenario
///         without standing up a full BazaarPair, and inspect `winnersPayoutRatioBp`.
contract TerminationHarness {
    BazaarTypes.Vault public vault;

    function setVault(
        uint256 totalLongOI,
        uint256 totalShortOI,
        uint256 longWeightedEntrySum,
        uint256 shortWeightedEntrySum,
        uint256 totalCollateralDeposited,
        uint256 insuranceFundBalance,
        uint256 pendingLiqSize,
        uint256 pendingLiqEntryNotional,
        uint256 pendingLiqBankruptcyNotional,
        bool pendingLiqIsLong
    ) external {
        vault.totalLongOI = totalLongOI;
        vault.totalShortOI = totalShortOI;
        vault.longWeightedEntrySum = longWeightedEntrySum;
        vault.shortWeightedEntrySum = shortWeightedEntrySum;
        vault.totalCollateralDeposited = totalCollateralDeposited;
        vault.insuranceFundBalance = insuranceFundBalance;
        vault.pendingLiqSize = pendingLiqSize;
        vault.pendingLiqEntryNotional = pendingLiqEntryNotional;
        vault.pendingLiqBankruptcyNotional = pendingLiqBankruptcyNotional;
        vault.pendingLiqIsLong = pendingLiqIsLong;
    }

    function setDeficit(uint256 d) external {
        vault.deficit = d;
    }

    function deficit() external view returns (uint256) {
        return vault.deficit;
    }

    function execTerm(BazaarTypes.TerminationParams memory params)
        external
        returns (BazaarTypes.TerminationResult memory)
    {
        return TerminationLib.executeTermination(vault, params);
    }
}

/// @notice Regression test for R2-4: `winningPnl` must not wrap a negative `int256` to
///         `uint256` when both `longPnL` and `shortPnL` are negative.
contract Phase2TerminationPnlTest is Test {
    TerminationHarness harness;
    MockUSDC usdc;

    uint256 constant SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;

    function setUp() public {
        harness = new TerminationHarness();
        usdc = new MockUSDC();
    }

    /// @notice Construct a scenario where:
    ///         - vault has pending long liquidations underwater enough to exceed insurance,
    ///         - aggregate `longPnL` AND `shortPnL` are BOTH negative,
    ///         - `longPnL > shortPnL` (so the pre-fix code picks the long side and casts -400 → ~2^256).
    ///         Pre-fix outcome: `winnersPayoutRatioBp ≈ 10000` (100%, no haircut).
    ///         Post-fix outcome: `winnersPayoutRatioBp == 0` (full haircut, since no aggregate winners).
    function test_R2_4_BothNegativeAggregatePnl_WinnersPayoutRatioIsZero() public {
        uint256 terminationPrice = 100 * SCALE;

        // Both-negative PnL setup at terminationPrice = $100:
        //   longNotional  = 10  × $100 = $1,000 ; longWeightedEntrySum  = $1,400 → longPnL  = -$400
        //   shortNotional = 10  × $100 = $1,000 ; shortWeightedEntrySum = $500   → shortPnL = -$500
        // longPnL > shortPnL  → pre-fix selects long side → uint256(-$400) wraps.
        //
        // Pending liq: 5 units inherited long, bankruptcyPrice = $200, terminationPrice = $100
        //   → liq impact = (100 - 200) * 5 = -$500 (loss). Insurance fund = $50 → shortfall $450.
        harness.setVault({
            totalLongOI: 10 * SCALE,
            totalShortOI: 10 * SCALE,
            longWeightedEntrySum: 1_400 * SCALE,
            shortWeightedEntrySum: 500 * SCALE,
            totalCollateralDeposited: 2_000 * SCALE,
            insuranceFundBalance: 50 * SCALE,
            pendingLiqSize: 5 * SCALE,
            pendingLiqEntryNotional: 1_000 * SCALE, // entry $200/unit
            pendingLiqBankruptcyNotional: 1_000 * SCALE, // bankruptcy $200/unit
            pendingLiqIsLong: true
        });

        // Mint USDC to the harness matching bookkeeping so the reconciliation step at
        // TerminationLib L131-157 doesn't adjust liqInsuranceImpact.
        //   expectedBalance (USDC) = (insurance + collateral) × USDC_SCALE / SCALE
        //                        = (50 + 2000) × 1e6 = 2_050 × 1e6
        usdc.mint(address(harness), 2_050 * USDC_SCALE);

        BazaarTypes.TerminationParams memory params = BazaarTypes.TerminationParams({
            isEmergency: false,
            terminationPrice: terminationPrice,
            usdc: address(usdc),
            pairId: bytes32(uint256(0xBA2AAA))
        });

        BazaarTypes.TerminationResult memory result = harness.execTerm(params);

        // Post-fix: aggregate PnL is non-positive on both sides → winningPnl = 0
        // → shortfall >= winningPnl → winnersPayoutRatioBp = 0.
        // Pre-fix this returned ~BP_SCALE (10000) due to the negative-cast wrap.
        assertEq(result.winnersPayoutRatioBp, 0, "no aggregate winners: 100% haircut");

        // Rung 4: the pot (2050 USDC) still covers all principal (2000), so even though
        // winner PnL and insurance are wiped, principal is NOT haircut.
        assertEq(result.normalCollateralRatioBp, 10_000, "principal fully covered, no haircut");
    }

    /// @notice Deep insolvency: winner PnL fully wiped AND the USDC on hand is less than booked
    ///         principal, so rung 4 haircuts principal pro-rata against the actual pot.
    function test_DeepInsolvency_PrincipalHaircutAnchoredOnActualUsdc() public {
        uint256 terminationPrice = 100 * SCALE;

        // Same both-negative aggregate as above (winningPnl = 0), but the contract only holds
        // 1,500 USDC against 2,000 booked principal (+50 insurance). The reconciliation folds the
        // 550 USDC shortfall into the liq impact, insurance is wiped, and rung 4 engages.
        harness.setVault({
            totalLongOI: 10 * SCALE,
            totalShortOI: 10 * SCALE,
            longWeightedEntrySum: 1_400 * SCALE, // longPnL  = -$400
            shortWeightedEntrySum: 500 * SCALE, // shortPnL = -$500
            totalCollateralDeposited: 2_000 * SCALE,
            insuranceFundBalance: 50 * SCALE,
            pendingLiqSize: 5 * SCALE,
            pendingLiqEntryNotional: 1_000 * SCALE,
            pendingLiqBankruptcyNotional: 1_000 * SCALE, // bankruptcy $200/unit
            pendingLiqIsLong: true
        });
        // Hold only 1,500 USDC < 2,000 booked principal.
        usdc.mint(address(harness), 1_500 * USDC_SCALE);

        BazaarTypes.TerminationResult memory result = harness.execTerm(
            BazaarTypes.TerminationParams({
                isEmergency: false,
                terminationPrice: terminationPrice,
                usdc: address(usdc),
                pairId: bytes32(uint256(0xBA2AAA))
            })
        );

        assertEq(result.winnersPayoutRatioBp, 0, "winners fully wiped in deep insolvency");
        // The estate leg first transfers min(I, entry - settle) = min(50, 500) = 50 from I to D
        // (backing the estates' counterparties), so the rung-4 denominator is 2,050:
        // ratio = actualUsdc / totalCollateralDeposited = 1500 / 2050 = 73.17% (floor).
        assertEq(result.normalCollateralRatioBp, 7_317, "principal haircut to pot / post-transfer D");

        // Conservation: applying the ratio to the full post-transfer principal ledger stays
        // within the pot (floor rounding leaves dust stranded, never overdraws).
        uint256 maxPrincipalPayout = result.normalCollateralRatioBp * (2_050 * SCALE) / 10_000;
        uint256 potBazaar = 1_500 * SCALE; // 1,500 USDC in BAZAAR precision
        assertLe(maxPrincipalPayout, potBazaar, "payouts bounded by the pot");
    }

    /// @notice Extreme deep insolvency: when the surviving pot is below 0.01% of booked principal the
    ///         bp-scale ratio rounds DOWN to 0. CollateralLib must treat a computed 0 as a real full
    ///         haircut (everyone gets ~nothing, dust stranded) — NOT as "no haircut", which would
    ///         re-open the first-come-first-served drain. Asserts the ratio genuinely computes to 0.
    function test_DeepInsolvency_RatioRoundsToZero_IsAFullHaircut() public {
        uint256 terminationPrice = 100 * SCALE;

        harness.setVault({
            totalLongOI: 10 * SCALE,
            totalShortOI: 10 * SCALE,
            longWeightedEntrySum: 1_400 * SCALE, // longPnL  = -$400
            shortWeightedEntrySum: 500 * SCALE, // shortPnL = -$500 -> winningPnl = 0
            totalCollateralDeposited: 2_000_000 * SCALE, // huge book
            insuranceFundBalance: 50 * SCALE,
            pendingLiqSize: 5 * SCALE,
            pendingLiqEntryNotional: 1_000 * SCALE,
            pendingLiqBankruptcyNotional: 1_000 * SCALE,
            pendingLiqIsLong: true
        });
        usdc.mint(address(harness), 100 * USDC_SCALE); // 100 USDC against a 2,000,000 book

        BazaarTypes.TerminationResult memory result = harness.execTerm(
            BazaarTypes.TerminationParams({
                isEmergency: false,
                terminationPrice: terminationPrice,
                usdc: address(usdc),
                pairId: bytes32(uint256(0xBA2AAA))
            })
        );

        assertEq(result.winnersPayoutRatioBp, 0, "winners fully wiped");
        // mulDiv(100e18, 10000, 2_000_000e18) = 0.5 -> floors to 0: a genuine ratio, not the unset default.
        assertEq(result.normalCollateralRatioBp, 0, "sub-0.01% pot rounds the ratio to 0");
        assertTrue(result.normalCollateralRatioBp < 10_000, "0 < BP_SCALE -> CollateralLib applies a full haircut");
    }

    /// @notice Sanity check: when longs are actually winning, the haircut math behaves
    ///         normally (this asserts we didn't break the happy path).
    function test_R2_4_LongsWinning_RatioReflectsRealHaircut() public {
        uint256 terminationPrice = 100 * SCALE;

        // Longs winning: longNotional > longWeightedEntrySum → longPnL > 0
        //   longWeightedEntrySum = $500 → longPnL = $500
        //   shortWeightedEntrySum = $500 → shortPnL = -$500 (shorts losing)
        // Pending liq creates a shortfall < longPnL so we get a partial haircut.
        harness.setVault({
            totalLongOI: 10 * SCALE,
            totalShortOI: 10 * SCALE,
            longWeightedEntrySum: 500 * SCALE, // longPnL = +$500
            shortWeightedEntrySum: 500 * SCALE, // shortPnL = -$500
            totalCollateralDeposited: 2_000 * SCALE,
            insuranceFundBalance: 50 * SCALE,
            pendingLiqSize: 5 * SCALE,
            pendingLiqEntryNotional: 1_000 * SCALE,
            pendingLiqBankruptcyNotional: 1_000 * SCALE,
            pendingLiqIsLong: true
        });
        usdc.mint(address(harness), 2_050 * USDC_SCALE);

        BazaarTypes.TerminationParams memory params = BazaarTypes.TerminationParams({
            isEmergency: false,
            terminationPrice: terminationPrice,
            usdc: address(usdc),
            pairId: bytes32(uint256(0xBA2AAA))
        });

        BazaarTypes.TerminationResult memory result = harness.execTerm(params);

        // Shortfall: liq loss $500 - insurance $50 = $450. winningPnl = $500.
        // ratio = (500 - 450) * 10000 / 500 = 1000 (10% payout).
        assertEq(result.winnersPayoutRatioBp, 1000, "10% payout ratio under partial-haircut");

        // Winner PnL absorbs the shortfall, so principal is untouched (rung 4 not engaged).
        assertEq(result.normalCollateralRatioBp, 10_000, "no principal haircut when winners absorb the shortfall");
    }

    /// @notice REGRESSION (two-sided-positive haircut miscalibration): a liquidation-imbalanced
    ///         book can leave BOTH aggregate sides net-positive at the termination price. The
    ///         payout ratio is applied to every winner on both sides, so its denominator must be
    ///         the combined positive PnL — not max() of the sides, which over-haircut all winners
    ///         and stranded the excess with no claimant.
    function test_TwoSidedPositivePnl_RatioUsesCombinedWinnerPnl() public {
        uint256 terminationPrice = 100 * SCALE;

        // Both sides winning at $100: avg long entry $50 (< price), avg short entry $150 (> price).
        //   longPnL  = 10 x $100 - $500   = +$500
        //   shortPnL = $1,500 - 10 x $100 = +$500
        // Pending liq: loss $500 - insurance $50 = shortfall $450 (same rig as the tests above).
        harness.setVault({
            totalLongOI: 10 * SCALE,
            totalShortOI: 10 * SCALE,
            longWeightedEntrySum: 500 * SCALE, // longPnL  = +$500
            shortWeightedEntrySum: 1_500 * SCALE, // shortPnL = +$500
            totalCollateralDeposited: 2_000 * SCALE,
            insuranceFundBalance: 50 * SCALE,
            pendingLiqSize: 5 * SCALE,
            pendingLiqEntryNotional: 1_000 * SCALE,
            pendingLiqBankruptcyNotional: 1_000 * SCALE,
            pendingLiqIsLong: true
        });
        usdc.mint(address(harness), 2_050 * USDC_SCALE);

        BazaarTypes.TerminationParams memory params = BazaarTypes.TerminationParams({
            isEmergency: false,
            terminationPrice: terminationPrice,
            usdc: address(usdc),
            pairId: bytes32(uint256(0xBA2AAA))
        });

        BazaarTypes.TerminationResult memory result = harness.execTerm(params);

        // winningPnl = 500 + 500 = $1,000 -> ratio = (1000 - 450) * 10000 / 1000 = 5500 (55%).
        // Pre-fix: winningPnl = max = $500 -> ratio 10%, clawing ~2x the shortfall from winners.
        assertEq(result.winnersPayoutRatioBp, 5500, "ratio denominates over BOTH sides' positive PnL");
        assertEq(result.normalCollateralRatioBp, 10_000, "principal untouched");
    }

    /// @notice REGRESSION: a shortfall larger than one side's PnL but smaller than the combined
    ///         total must stay in rung 3 (partial haircut), not escalate to the rung-4 full PnL
    ///         wipeout. Pre-fix, `shortfall >= max(side PnL)` tripped rung 4 even though the
    ///         combined winner PnL could absorb the shortfall.
    function test_TwoSidedPositivePnl_NoPrematureRung4Escalation() public {
        uint256 terminationPrice = 100 * SCALE;

        // Both sides +$500 as above; pending liq loss = (100 - 250) x 5 = -$750, insurance $50
        // -> shortfall $700: above either side alone ($500), below the combined $1,000.
        harness.setVault({
            totalLongOI: 10 * SCALE,
            totalShortOI: 10 * SCALE,
            longWeightedEntrySum: 500 * SCALE, // longPnL  = +$500
            shortWeightedEntrySum: 1_500 * SCALE, // shortPnL = +$500
            totalCollateralDeposited: 2_000 * SCALE,
            insuranceFundBalance: 50 * SCALE,
            pendingLiqSize: 5 * SCALE,
            pendingLiqEntryNotional: 1_250 * SCALE, // entry $250/unit
            pendingLiqBankruptcyNotional: 1_250 * SCALE, // bankruptcy $250/unit
            pendingLiqIsLong: true
        });
        usdc.mint(address(harness), 2_050 * USDC_SCALE);

        BazaarTypes.TerminationParams memory params = BazaarTypes.TerminationParams({
            isEmergency: false,
            terminationPrice: terminationPrice,
            usdc: address(usdc),
            pairId: bytes32(uint256(0xBA2AAA))
        });

        BazaarTypes.TerminationResult memory result = harness.execTerm(params);

        // winningPnl = $1,000 > shortfall $700 -> rung 3: ratio = 300 * 10000 / 1000 = 3000 (30%).
        // Pre-fix: shortfall $700 >= max $500 -> rung 4: every winner's PnL zeroed.
        assertEq(result.winnersPayoutRatioBp, 3000, "combined PnL absorbs the shortfall at 30% payout");
        assertEq(result.normalCollateralRatioBp, 10_000, "no principal haircut in rung 3");
    }

    /// @notice REGRESSION (deficit fold): pairVault.deficit — realized-but-unbacked bad debt from
    ///         Pass-A vault closes or opposing-liquidation netting (incl. terminal sweeps) — is
    ///         booked as an I <-> D transfer of the covered part only, so the books-vs-USDC drift
    ///         check can never see it. executeTermination must charge it through the waterfall
    ///         explicitly; pre-fix it was silently dropped and winners kept a 100% ratio while
    ///         their claims exceeded the pot by exactly the deficit.
    function test_DeficitFold_ChargesInsuranceThenHaircutsWinners() public {
        uint256 terminationPrice = 100 * SCALE;

        // Longs winning +$500, shorts losing -$500, no pending liq. Books match cash exactly
        // (I + D = 2050 = minted USDC), so the drift leg contributes nothing — only the
        // deficit fold can surface the $250 of unbacked claims.
        harness.setVault({
            totalLongOI: 10 * SCALE,
            totalShortOI: 10 * SCALE,
            longWeightedEntrySum: 500 * SCALE, // longPnL = +$500
            shortWeightedEntrySum: 500 * SCALE, // shortPnL = -$500
            totalCollateralDeposited: 2_000 * SCALE,
            insuranceFundBalance: 50 * SCALE,
            pendingLiqSize: 0,
            pendingLiqEntryNotional: 0,
            pendingLiqBankruptcyNotional: 0,
            pendingLiqIsLong: false
        });
        harness.setDeficit(250 * SCALE);
        usdc.mint(address(harness), 2_050 * USDC_SCALE);

        BazaarTypes.TerminationResult memory result = harness.execTerm(
            BazaarTypes.TerminationParams({
                isEmergency: false,
                terminationPrice: terminationPrice,
                usdc: address(usdc),
                pairId: bytes32(uint256(0xBA2AAA))
            })
        );

        // Deficit $250: insurance absorbs $50, the remaining $200 haircuts winner PnL:
        // ratio = (500 - 200) * 10000 / 500 = 6000. Pre-fix: 10000 (deficit ignored).
        assertEq(result.winnersPayoutRatioBp, 6_000, "deficit charged through insurance then winner PnL");
        assertEq(result.normalCollateralRatioBp, 10_000, "principal untouched (winner PnL absorbed it)");
        assertEq(harness.deficit(), 0, "deficit consumed at termination");
    }
}

// ==================== from Phase2InsurerVoteTest.t.sol ====================

/// @notice Regression tests for R2-1: insurer-vote share-dilution attack and the offensive
///         counterpart (acquiring shares to pass an unjust vote during the proposal window).
///         Verifies the Phase 2.1 defenses: snapshotTotalShares freezes the threshold
///         denominator at proposal creation, and the share-maturity check (7-day age)
///         disqualifies shares minted within the maturity window before a proposal from
///         voting on it. Withdrawals are also gated on mature shares only.
contract Phase2InsurerVoteTest is Test {
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;

    BazaarFactory factory;
    BazaarPair pair;
    BazaarPairTerminator terminator;
    MockUSDC usdc;
    MockPyth mockPyth;

    address deployer;
    address whaleProposer; // proposer with substantial pre-existing stake
    address majorityVoter; // votes yes, has ~60% of pre-snapshot shares
    address diluter; // tries to defeat a passing vote by depositing fresh USDC
    address attacker; // tries to pass an unjust vote by acquiring shares mid-window

    function setUp() public {
        deployer = makeAddr("deployer");
        whaleProposer = makeAddr("whaleProposer");
        majorityVoter = makeAddr("majorityVoter");
        diluter = makeAddr("diluter");
        attacker = makeAddr("attacker");

        vm.etch(address(0x64), address(new MockArbSys()).code);

        DeployBazaar dep = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = dep.deploy(makeAddr("bugBounty"));

        (, address usdcAddr,,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcAddr);
        terminator = factory.pairTerminator();
        mockPyth = MockPyth(address(factory.oracle().pyth()));

        usdc.mint(deployer, PROPOSAL_TOTAL_USDC);
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        pair = BazaarPair(payable(factory.getPairAddress(pairId)));

        // Give each actor enough USDC for proposal bonds and insurance deposits.
        usdc.mint(whaleProposer, 100_000 * USDC_SCALE);
        usdc.mint(majorityVoter, 100_000 * USDC_SCALE);
        usdc.mint(diluter, 100_000 * USDC_SCALE);
        usdc.mint(attacker, 100_000 * USDC_SCALE);

        // Pre-existing insurers (in addition to the deployer's 4_000 seed). Majority
        // needs >60% of total, so we make it dominate. Total after these: 4000 + 100 + 20000 = 24100.
        // Majority has 20000 / 24100 ≈ 83%, comfortably above the 60% threshold.
        _depositInsurance(whaleProposer, 100 * BAZAAR_SCALE);
        _depositInsurance(majorityVoter, 20_000 * BAZAAR_SCALE);

        // Warp past the share-maturity period so these pre-existing deposits can vote on
        // proposals filed during the tests. Without this, freshly-deposited shares would
        // be immature at proposalTs and the votes would fail with InsufficientUnlockedShares.
        vm.warp(block.timestamp + 8 days);
    }

    // -------------------- Helpers --------------------

    function _depositInsurance(address user, uint256 amountBazaar) internal {
        uint256 amountUsdc = amountBazaar * USDC_SCALE / BAZAAR_SCALE;
        vm.startPrank(user);
        usdc.approve(address(pair), amountUsdc);
        pair.depositToInsurance(amountBazaar, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    uint256 constant INSURER_BOND_USDC = 500 * 1e6; // mirror of internal constant in BazaarPairTerminator
    uint256 constant INSURER_VOTING_PERIOD = 7 days;

    function _proposeInsurerTermination(address proposer) internal {
        usdc.mint(proposer, INSURER_BOND_USDC);
        vm.startPrank(proposer);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        terminator.proposeInsurerTermination(address(pair));
        vm.stopPrank();
    }

    function _vote(address voter, uint256 amount) internal {
        vm.prank(voter);
        terminator.voteForInsurerTermination(address(pair), amount);
    }

    /// @dev Build a BTC price update payload at a given USD spot price.
    function _btcPriceUpdate(uint64 publishTime) internal view returns (bytes[] memory pu) {
        int64 pythPrice = int64(int256(uint256(50_000 * 1e8))); // $50,000
        uint64 conf = uint64(50_000 * 1e8 / 1000);
        bytes memory data = mockPyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID, pythPrice, conf, -8, pythPrice, conf, publishTime, publishTime > 0 ? publishTime - 1 : 0
        );
        pu = new bytes[](1);
        pu[0] = data;
    }

    function _readSnapshot() internal view returns (uint256) {
        (,,,,, uint256 snapshotTotalShares,,) = terminator.insurerProposals(address(pair));
        return snapshotTotalShares;
    }

    /// @dev Two-stage termination: a successful terminator path only FIXES the settlement price
    ///      and opens the 1h terminal sweep window; finalizing flips the terminated flag.
    ///      Uses the vm.getBlockTimestamp() cheatcode (not the opcode) — after external calls
    ///      the via_ir optimizer can re-materialize a stale cached block.timestamp.
    function _finalizeAfterSweep() internal {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        pair.finalizeTermination();
    }

    // -------------------- Tests --------------------

    /// @notice Defensive dilution defense (R2-1 primary): defender deposits between
    ///         vote-end and execution. Before fix: threshold scaled up, vote failed.
    ///         After fix: threshold is frozen at the snapshot, vote still passes.
    function test_R2_1_DefensiveDilution_DoesNotDefeatPassingVote() public {
        _proposeInsurerTermination(whaleProposer);

        // Snapshot at proposal time = deployer seed (5,000) + whale (100) + majority (5,000)
        uint256 snapshot = _readSnapshot();
        assertGt(snapshot, 0, "snapshot captured");

        // Majority votes yes — well above 60% of snapshot
        _vote(majorityVoter, 20_000 * BAZAAR_SCALE);

        // Voting period closes
        vm.warp(block.timestamp + INSURER_VOTING_PERIOD + 1);

        // Defender tries to dilute by depositing a massive amount of fresh insurance USDC
        _depositInsurance(diluter, 50_000 * BAZAAR_SCALE);

        // Live totalShares grew, but the snapshot didn't — the vote should still pass.
        bytes[] memory pu = _btcPriceUpdate(uint64(block.timestamp));
        uint256 fee = factory.oracle().getUpdateFee(pu);
        terminator.executeInsurerTermination{value: fee}(address(pair), pu);
        _finalizeAfterSweep();

        // After execution + finalize the pair is normal-terminated — proves the vote passed despite dilution.
        assertTrue(pair.isPairTerminatedNormal(), "pair terminated despite dilution attempt");
    }

    /// @notice Offensive defense (R2-1 secondary): attacker deposits a large amount mid-voting
    ///         to acquire shares, then tries to vote with them. The shares must be
    ///         disqualified by postProposalShares so the unjust vote cannot pass.
    function test_R2_1_OffensiveAcquisition_NewSharesCannotVote() public {
        _proposeInsurerTermination(whaleProposer);

        // Attacker has no pre-snapshot shares. They deposit during voting to grab voting power.
        _depositInsurance(attacker, 20_000 * BAZAAR_SCALE);

        // Attacker tries to vote with their freshly-minted shares — must revert.
        // Their current shares > 0 but all of them are in postProposalShares,
        // so eligibleShares = 0.
        uint256 attackerShares = pair.insuranceShares(attacker);
        assertGt(attackerShares, 0, "attacker actually received shares");

        vm.expectRevert(); // BazaarPairTerminator__InsurerInsufficientUnlockedShares(unlocked, amount)
        vm.prank(attacker);
        terminator.voteForInsurerTermination(address(pair), 1);
    }

    /// @notice A user with old (mature) shares plus a top-up during the proposal window can
    ///         still vote their mature pre-existing balance — the fresh shares are immature
    ///         and don't count toward vote eligibility.
    function test_R2_1_PreExistingHolderCanVoteOldShares_NotNew() public {
        uint256 votersPreShares = pair.insuranceShares(majorityVoter);
        assertGt(votersPreShares, 0);

        _proposeInsurerTermination(whaleProposer);

        // Majority voter tops up after the proposal opens
        _depositInsurance(majorityVoter, 1_000 * BAZAAR_SCALE);
        uint256 votersPostShares = pair.insuranceShares(majorityVoter);
        assertGt(votersPostShares, votersPreShares);

        // They can still vote up to their PRE-proposal balance, no more.
        _vote(majorityVoter, votersPreShares);

        // Voting more than that should revert.
        vm.expectRevert(); // BazaarPairTerminator__InsurerInsufficientUnlockedShares(unlocked, amount)
        vm.prank(majorityVoter);
        terminator.voteForInsurerTermination(address(pair), 1);
    }

    /// @notice R2-2: failed insurer-vote forfeits the 400 USDC bond into the insurance fund,
    ///         not as orphan dust. Both the contract's actual USDC balance and the
    ///         `insuranceFundBalance` bookkeeping field must grow by the bond amount.
    function test_R2_2_FailedVote_BondCreditedToInsuranceFund() public {
        _proposeInsurerTermination(whaleProposer);

        // No one votes yes (or anyone votes below threshold) — proposal will fail at execution.
        // Wait through voting period.
        vm.warp(block.timestamp + INSURER_VOTING_PERIOD + 1);

        // Snapshot insurance fund balance + pair USDC balance pre-execution.
        (,,,,, uint256 insuranceBefore,,,,,,) = pair.pairVault();
        uint256 pairUsdcBefore = usdc.balanceOf(address(pair));

        // Execute the (failing) proposal. No price update needed in the fail branch.
        bytes[] memory emptyPu = new bytes[](0);
        terminator.executeInsurerTermination(address(pair), emptyPu);

        // Pair NOT terminated (threshold was not met).
        assertFalse(pair.isPairTerminatedNormal(), "pair must not be terminated");
        assertFalse(pair.isPairTerminatedEmergency(), "no emergency termination either");

        // The 400 USDC bond should be in the pair AND credited to insurance bookkeeping.
        uint256 pairUsdcAfter = usdc.balanceOf(address(pair));
        assertEq(pairUsdcAfter - pairUsdcBefore, INSURER_BOND_USDC, "pair received the bond in USDC");

        (,,,,, uint256 insuranceAfter,,,,,,) = pair.pairVault();
        // Bond in BAZAAR_SCALE = 400 USDC × 1e12 = 400e18
        uint256 expectedBazaarGain = INSURER_BOND_USDC * 1e12;
        assertEq(insuranceAfter - insuranceBefore, expectedBazaarGain, "insurance bookkeeping grew by bond amount");
    }

    /// @notice R2-2 negative: a successful insurer vote refunds the bond to the proposer
    ///         and does NOT credit the pair's insurance fund. Mirror of the above.
    function test_R2_2_SuccessfulVote_BondRefundedNotCredited() public {
        _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, 20_000 * BAZAAR_SCALE);
        vm.warp(block.timestamp + INSURER_VOTING_PERIOD + 1);

        (,,,,, uint256 insuranceBefore,,,,,,) = pair.pairVault();
        uint256 proposerUsdcBefore = usdc.balanceOf(whaleProposer);

        bytes[] memory pu = _btcPriceUpdate(uint64(block.timestamp));
        uint256 fee = factory.oracle().getUpdateFee(pu);
        terminator.executeInsurerTermination{value: fee}(address(pair), pu);
        _finalizeAfterSweep();

        // Successful vote: pair terminated, bond went back to proposer.
        assertTrue(pair.isPairTerminatedNormal(), "pair was terminated on success");
        uint256 proposerUsdcAfter = usdc.balanceOf(whaleProposer);
        assertEq(proposerUsdcAfter - proposerUsdcBefore, INSURER_BOND_USDC, "bond refunded to proposer");

        // Insurance fund must NOT have grown by the bond (it might have changed for other
        // termination-settlement reasons, so we just assert no bond-sized credit).
        (,,,,, uint256 insuranceAfter,,,,,,) = pair.pairVault();
        uint256 expectedBazaarGain = INSURER_BOND_USDC * 1e12;
        assertLt(insuranceAfter - insuranceBefore, expectedBazaarGain, "no bond credit on success");
    }

    /// @notice Regression: if the pair is terminated by ANOTHER path (autonomous emergency
    ///         termination, UMA scheduled/post-cessation, or stale termination) during an active
    ///         insurer-termination proposal's window, executeInsurerTermination must still resolve
    ///         the proposal and REFUND the bond — not revert with AlreadyTerminated, which would
    ///         strand the 400 USDC bond forever (this is the only function that releases it, and
    ///         proposeInsurerTermination reverts on an already-terminated pair so it can't recover).
    function test_PreemptedByOtherTermination_RefundsBondInsteadOfStranding() public {
        // Proposer files an insurer-termination proposal and posts the 400 USDC bond.
        _proposeInsurerTermination(whaleProposer);

        // Mid-window, the pair is terminated by a DIFFERENT path. We use the UMA normal-termination
        // entrypoint (fixSettlementPrice + finalizeTermination, onlyUma) as a concrete "other
        // path"; an autonomous emergency termination flips isPairTerminatedEmergency through the
        // identical preempted-branch guard and is handled by the same fix branch.
        address umaCaller = pair.umaContract();
        vm.prank(umaCaller);
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        _finalizeAfterSweep();
        assertTrue(pair.isPairTerminatedNormal(), "pair pre-empted by another termination path");

        // Advance past the voting period so executeInsurerTermination is callable.
        vm.warp(block.timestamp + INSURER_VOTING_PERIOD + 1);

        uint256 proposerUsdcBefore = usdc.balanceOf(whaleProposer);
        (,,,,, uint256 insuranceBefore,,,,,,) = pair.pairVault();

        // Pre-fix this reverted with AlreadyTerminated and stranded the bond. No price update or
        // ETH is needed — the pre-empted branch returns before any termination/oracle work.
        bytes[] memory emptyPu = new bytes[](0);
        terminator.executeInsurerTermination(address(pair), emptyPu);

        // Bond is refunded to the proposer (NOT forfeited to insurance).
        assertEq(
            usdc.balanceOf(whaleProposer) - proposerUsdcBefore,
            INSURER_BOND_USDC,
            "bond refunded to proposer when pre-empted"
        );
        (,,,,, uint256 insuranceAfter,,,,,,) = pair.pairVault();
        assertEq(insuranceAfter, insuranceBefore, "bond not forfeited to insurance on pre-emption");

        // Proposal is resolved so the slot can't be reused/double-spent, and the pair was not
        // re-terminated (still the original normal termination, no emergency flag flipped).
        (,,,,,, bool resolved, bool executed) = terminator.insurerProposals(address(pair));
        assertTrue(resolved, "proposal resolved");
        assertFalse(executed, "insurer flow did not execute the termination");
        assertFalse(pair.isPairTerminatedEmergency(), "no spurious emergency termination");
    }

    /// @notice L-8 regression: a proposal that expires with nobody calling
    ///         executeInsurerTermination is settled by the NEXT proposeInsurerTermination before
    ///         the struct is overwritten. Failed-vote case: the old bond forfeits to the pair's
    ///         insurance fund instead of being stranded in the terminator forever. Pre-fix, the
    ///         overwrite discarded the only reference to the old bond.
    function test_L8_ExpiredUnresolvedProposal_SettledOnOverwrite_ForfeitsToInsurance() public {
        _proposeInsurerTermination(whaleProposer);

        // Nobody votes and nobody executes. The execution window (7d voting + 7d execution) and
        // the 14-day re-proposal cooldown expire at the same moment — one second later, the slot
        // is overwritable.
        vm.warp(block.timestamp + 14 days + 1);

        uint256 terminatorBefore = usdc.balanceOf(address(terminator));
        uint256 pairBefore = usdc.balanceOf(address(pair));
        (,,,,, uint256 insuranceBefore,,,,,,) = pair.pairVault();

        // The overwriting proposal settles the expired one: old bond → insurance fund.
        _proposeInsurerTermination(majorityVoter);

        assertEq(usdc.balanceOf(address(pair)) - pairBefore, INSURER_BOND_USDC, "old bond forfeited to the pair");
        (,,,,, uint256 insuranceAfter,,,,,,) = pair.pairVault();
        assertEq(insuranceAfter - insuranceBefore, INSURER_BOND_USDC * 1e12, "insurance bookkeeping credited");
        // Old bond out, new bond in: the terminator's balance is net unchanged, i.e. it holds
        // ONLY the live proposal's bond — nothing stranded.
        assertEq(usdc.balanceOf(address(terminator)), terminatorBefore, "terminator holds only the new bond");

        // The new proposal occupies the slot, untouched by the settlement.
        (address proposer,,,, uint256 yesShares,, bool resolved, bool executed) =
            terminator.insurerProposals(address(pair));
        assertEq(proposer, majorityVoter, "new proposal in the slot");
        assertEq(yesShares, 0, "fresh vote count");
        assertFalse(resolved, "new proposal unresolved");
        assertFalse(executed, "new proposal unexecuted");
    }

    /// @notice L-8 regression, consensus case: the vote passed but nobody executed inside the
    ///         window. The next proposal refunds the old proposer's bond (consensus succeeded
    ///         on-chain) rather than forfeiting or stranding it — and must NOT terminate the
    ///         pair off the weeks-stale vote.
    function test_L8_ExpiredPassedProposal_SettledOnOverwrite_RefundsProposer() public {
        _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, 20_000 * BAZAAR_SCALE); // ~83% of snapshot, above the 60% threshold
        vm.warp(block.timestamp + 14 days + 1); // window + cooldown elapsed, never executed

        uint256 proposerBefore = usdc.balanceOf(whaleProposer);
        (,,,,, uint256 insuranceBefore,,,,,,) = pair.pairVault();

        _proposeInsurerTermination(majorityVoter);

        assertEq(
            usdc.balanceOf(whaleProposer) - proposerBefore, INSURER_BOND_USDC, "old bond refunded to the old proposer"
        );
        (,,,,, uint256 insuranceAfter,,,,,,) = pair.pairVault();
        assertEq(insuranceAfter, insuranceBefore, "nothing forfeited when the threshold was met");
        assertFalse(pair.isPairTerminatedNormal(), "stale consensus must not terminate on settlement");
    }

    /// @notice creditInsuranceFromTerminator is gated by onlyUma — direct calls revert.
    function test_R2_2_CreditFunction_OnlyUmaGuard() public {
        vm.prank(attacker);
        vm.expectRevert(); // BazaarPair__OnlyUma
        pair.creditInsuranceFromTerminator(1_000 * BAZAAR_SCALE);
    }

    /// @notice Maturity: shares deposited within 7 days of a proposal cannot vote on it.
    ///         This is the "snipe defense" — an attacker can't deposit majority and propose
    ///         in the same transaction; their shares need to age 7 days before they count.
    function test_Maturity_FreshlyDepositedSharesCannotVoteOnSameDayProposal() public {
        // Diluter deposits AT proposal time (immature)
        _depositInsurance(diluter, 10_000 * BAZAAR_SCALE);
        _proposeInsurerTermination(whaleProposer);

        // Diluter's shares are 0 seconds old at proposalTs. Voting must revert.
        vm.expectRevert(); // InsurerInsufficientUnlockedShares(0, ...)
        vm.prank(diluter);
        terminator.voteForInsurerTermination(address(pair), 1);
    }

    /// @notice Maturity: shares that have aged past 7 days CAN vote, even if deposited
    ///         after some prior unrelated event but before the proposal.
    function test_Maturity_SharesMaturedBeforeProposalCanVote() public {
        // Diluter deposits, waits 8 days (past maturity), then proposal is filed.
        _depositInsurance(diluter, 10_000 * BAZAAR_SCALE);
        vm.warp(block.timestamp + 8 days);
        _proposeInsurerTermination(whaleProposer);

        // Diluter's shares are 8 days old at proposalTs > 7 days maturity. Vote allowed.
        uint256 diluterShares = pair.insuranceShares(diluter);
        vm.prank(diluter);
        terminator.voteForInsurerTermination(address(pair), diluterShares);
        // No revert → shares were eligible.
    }

    /// @notice MIN_INSURANCE_DEPOSIT floor (=$5) prevents dust deposits that would otherwise
    ///         enable orphan-balance capture (deposit 1 wei → 100% share via bootstrap).
    function test_InsuranceDeposit_BelowMinimumReverts() public {
        // 4 USDC in BAZAAR_SCALE — below the $5 floor
        uint256 belowFloor = 4 * BAZAAR_SCALE;
        usdc.mint(attacker, belowFloor * USDC_SCALE / BAZAAR_SCALE);
        vm.startPrank(attacker);
        usdc.approve(address(pair), belowFloor * USDC_SCALE / BAZAAR_SCALE);
        vm.expectRevert(); // InsuranceVaultLib__DepositBelowMinimum
        pair.depositToInsurance(belowFloor, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @notice Deposits at or above the $5 floor succeed normally.
    function test_InsuranceDeposit_AtMinimumSucceeds() public {
        uint256 atFloor = 5 * BAZAAR_SCALE;
        usdc.mint(attacker, atFloor * USDC_SCALE / BAZAAR_SCALE);
        vm.startPrank(attacker);
        usdc.approve(address(pair), atFloor * USDC_SCALE / BAZAAR_SCALE);
        pair.depositToInsurance(atFloor, 0, 0, 0, "", "");
        vm.stopPrank();
        assertGt(pair.insuranceShares(attacker), 0, "shares minted");
    }

    /// @notice MAX_DEPOSITS_PER_WINDOW (100 per 7-day rolling window) caps the active lot
    ///         list. The 101st deposit within the window must revert; after warping past
    ///         the maturity period, deposits resume.
    function test_DepositRateLimit_CapEnforcedAndResetsAfterMaturity() public {
        // attacker is a clean account (no prior deposits, since setUp's warp put us past day 0).
        uint256 amt = 5 * BAZAAR_SCALE;
        uint256 amtUsdc = amt * USDC_SCALE / BAZAAR_SCALE;
        usdc.mint(attacker, 200 * amtUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(pair), 200 * amtUsdc);

        // 100 deposits succeed.
        for (uint256 i = 0; i < 100; i++) {
            pair.depositToInsurance(amt, 0, 0, 0, "", "");
        }
        // 101st in the same window reverts.
        vm.expectRevert(); // BazaarPair__TooManyRecentInsuranceDeposits(100, 100)
        pair.depositToInsurance(amt, 0, 0, 0, "", "");
        vm.stopPrank();

        // After 7 days, the rolling window has rolled past all 100 entries: deposits work again.
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(attacker);
        pair.depositToInsurance(amt, 0, 0, 0, "", "");
    }

    /// @notice The view `getSharesAsOf` returns mature shares only (immature top-ups
    ///         minted within the maturity window are excluded). This view is what
    ///         executeInsuranceWithdrawal uses to enforce the mature-only withdrawal cap.
    function test_MatureView_ImmaturePortionExcluded() public {
        // Make a mature seed deposit, warp past maturity.
        uint256 matureBazaar = 100 * BAZAAR_SCALE;
        _depositInsurance(attacker, matureBazaar);
        uint256 matureShares = pair.insuranceShares(attacker);
        vm.warp(block.timestamp + 8 days);

        // mature_as_of(now - 7d) should equal the original deposit (fully aged).
        uint64 cutoff = uint64(block.timestamp - 7 days);
        assertEq(pair.getSharesAsOf(attacker, cutoff), matureShares, "old deposit fully mature");

        // Top up with a fresh (immature) deposit.
        _depositInsurance(attacker, 50 * BAZAAR_SCALE);
        uint256 totalAfter = pair.insuranceShares(attacker);
        assertGt(totalAfter, matureShares, "top-up minted new shares");

        // Mature shares as of (now - 7d) should NOT include the fresh top-up.
        uint256 matureAfter = pair.getSharesAsOf(attacker, cutoff);
        assertEq(matureAfter, matureShares, "fresh top-up excluded from mature view");
        assertLt(matureAfter, totalAfter, "mature is strictly less than total when immature lots exist");
    }

    /// @notice Zero-amount votes are rejected. Previously they passed all checks and emitted
    ///         a noise event with amount=0 — wasted gas / spammy logs.
    function test_Vote_ZeroAmountReverts() public {
        _proposeInsurerTermination(whaleProposer);
        vm.expectRevert(); // BazaarPairTerminator__InsurerZeroVoteAmount
        vm.prank(majorityVoter);
        terminator.voteForInsurerTermination(address(pair), 0);
    }

    /// @notice Regression: after a successful insurer-vote termination, insurance LPs MUST
    ///         still be able to withdraw their funds. Earlier code reverted forever because
    ///         the `scheduledTerminationTs` guard fired before the terminated-flag check.
    function test_Withdrawal_AfterInsurerTermination_StillWorks() public {
        // Whale + majority already have shares from setUp. Trigger an insurer-vote termination.
        _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, 20_000 * BAZAAR_SCALE);
        vm.warp(block.timestamp + INSURER_VOTING_PERIOD + 1);
        bytes[] memory pu = _btcPriceUpdate(uint64(block.timestamp));
        uint256 fee = factory.oracle().getUpdateFee(pu);
        terminator.executeInsurerTermination{value: fee}(address(pair), pu);
        _finalizeAfterSweep();
        assertTrue(pair.isPairTerminatedNormal(), "sanity: pair terminated");

        // fixSettlementPrice stamps scheduledTerminationTs for the insurer-vote path too (so all
        // limbo guards engage during the sweep window), which means this flow now ALSO exercises
        // the "scheduledTerminationTs set + past + terminated" guard-ordering regression that
        // test_Withdrawal_AfterScheduledTermination_StillWorks covers for the UMA-scheduled path.
        assertGt(pair.scheduledTerminationTs(), 0, "insurer path stamps scheduledTerminationTs now");

        // For this test we just confirm the post-insurer-termination fast path is reachable.
        uint256 majShares = pair.insuranceShares(majorityVoter);
        vm.prank(majorityVoter);
        pair.requestInsuranceWithdrawal(majShares, 0, 0, 0, "", "");

        // No cooldown wait needed when terminated — execute immediately. Cheatcode timestamp:
        // block.timestamp can be stale-cached by via_ir after the finalize warp above.
        bytes[] memory pu2 = _btcPriceUpdate(uint64(vm.getBlockTimestamp()));
        vm.prank(majorityVoter);
        pair.executeInsuranceWithdrawal(pu2, 0, 0, 0, "");
        assertEq(pair.insuranceShares(majorityVoter), 0, "majority withdrew post-termination");
    }

    /// @notice The CRITICAL regression: after a UMA-scheduled normal termination, the
    ///         scheduledTerminationTs field is set AND we're past it AND the terminated
    ///         flag is true. The earlier guard ordering reverted forever in this state.
    function test_Withdrawal_AfterScheduledTermination_StillWorks() public {
        // Simulate UMA scheduled termination via the BazaarPairTerminator->Pair path.
        // The Terminator's setScheduledTermination is onlyUma — call from the umaContract.
        address umaCaller = pair.umaContract();
        uint256 lastTradingTs = block.timestamp + 1 days;
        vm.prank(umaCaller);
        pair.setScheduledTermination(lastTradingTs, whaleProposer);

        // Warp past lastTradingTs.
        vm.warp(lastTradingTs + 1 hours);

        // Execute the scheduled termination (two-stage: fix + sweep window + finalize) — this is
        // the path that flips isPairTerminatedNormal while leaving scheduledTerminationTs set
        // (= the bug condition).
        vm.prank(umaCaller);
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        _finalizeAfterSweep();
        assertTrue(pair.isPairTerminatedNormal(), "scheduled termination executed");
        assertGt(pair.scheduledTerminationTs(), 0, "bug condition: scheduledTerminationTs still set");

        // Now an insurance LP requests + executes withdrawal — must succeed (was reverting before fix).
        bytes[] memory pu = _btcPriceUpdate(uint64(vm.getBlockTimestamp()));
        uint256 majShares = pair.insuranceShares(majorityVoter);
        vm.prank(majorityVoter);
        pair.requestInsuranceWithdrawal(majShares, 0, 0, 0, "", "");
        // Terminated → no cooldown wait needed.
        vm.prank(majorityVoter);
        pair.executeInsuranceWithdrawal(pu, 0, 0, 0, "");
        assertEq(pair.insuranceShares(majorityVoter), 0, "withdrawal succeeded post-scheduled-termination");
    }

    /// @notice Regression: when a bad-debt cascade drains the insurance fund to 0 without
    ///         triggering termination (e.g., no pending liquidations when the last loss
    ///         settles), a recapitalizer MUST be able to deposit. Originally this reverted
    ///         with a div-by-zero (shares = amount * total / 0); the deposit now bumps the
    ///         share epoch — pre-drain balances lazily read as 0 — and reprices at a clean
    ///         1:1 in a single transaction, with no holder enumeration.
    /// @dev Vault.insuranceFundBalance lives at slot 6 + offset 5 = 11.
    uint256 constant SLOT_VAULT_INSURANCE_FUND_BALANCE = 11;

    function test_DepositToInsurance_RecapitalizesAfterFundDrain() public {
        // Simulate a drained fund by directly zeroing the bookkeeping slot. (Real-world
        // path: cascading liquidations land all-at-once, last loss clamps balance to 0,
        // pending-liq cleared so isVaultHealthy still passes.)
        vm.store(address(pair), bytes32(SLOT_VAULT_INSURANCE_FUND_BALANCE), bytes32(uint256(0)));
        (,,,,, uint256 fundAfter,,,,,,) = pair.pairVault();
        assertEq(fundAfter, 0, "fund drained to 0");
        // totalShares should still be > 0 (the bookkeeping zeroing didn't touch them).
        assertGt(pair.totalInsuranceShares(), 0, "shares still issued");

        // Recapitalizer steps in — single deposit, epoch bump, 1:1 repricing.
        uint256 recap = 10_000 * BAZAAR_SCALE;
        uint256 recapUsdc = recap * USDC_SCALE / BAZAAR_SCALE;
        usdc.mint(attacker, recapUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(pair), recapUsdc);
        pair.depositToInsurance(recap, 0, 0, 0, "", "");
        vm.stopPrank();

        (,,,,, uint256 fundPostRecap,,,,,,) = pair.pairVault();
        assertEq(fundPostRecap, recap, "fund equals recap amount");

        uint256 attackerShares = pair.insuranceShares(attacker);
        uint256 totalShares = pair.totalInsuranceShares();
        // Epoch reset + 1:1 repricing: the recapitalizer owns the supply outright; the
        // pre-drain generation reads as zero.
        assertGe(attackerShares * 10_000 / totalShares, 9_999, "recapitalizer owns ~100%");
        assertEq(attackerShares, recap, "supply restarted at exactly the rescue amount");
        assertEq(pair.insuranceShares(deployer), 0, "wiped seed LP reads zero");
    }

    /// @notice REGRESSION (recap share-supply overflow): pricing a drained fund at 1 wei
    ///         multiplied the share supply by amount-in-WEI per rescue, so a SECOND
    ///         wipe+rescue cycle minted amount x supply shares, overflowed the uint192
    ///         deposit-lot guard, and permanently bricked recapitalization. The share-epoch
    ///         reset removes the inflation entirely: each drained-fund recap bumps the epoch,
    ///         pre-drain balances lazily read as 0, and the supply restarts at exactly the
    ///         rescue amount — every cycle, forever, in one transaction.
    function test_DepositToInsurance_SecondFundDrainRecapDoesNotBrick() public {
        uint256 recap = 10_000 * BAZAAR_SCALE;
        uint256 recapUsdc = recap * USDC_SCALE / BAZAAR_SCALE;

        // Cycle 1: wipe -> rescue by `attacker`.
        vm.store(address(pair), bytes32(SLOT_VAULT_INSURANCE_FUND_BALANCE), bytes32(uint256(0)));
        usdc.mint(attacker, recapUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(pair), recapUsdc);
        pair.depositToInsurance(recap, 0, 0, 0, "", "");
        vm.stopPrank();

        // Cycle 2: wipe again -> a NEW rescuer deposits directly.
        // Under 1-wei pricing cycle 2 reverted with the uint192 lot-guard overflow: the
        // supply was already x(amount-in-wei) inflated, so amount x supply blew through
        // uint192. With the epoch reset the supply simply restarts at the rescue amount.
        vm.store(address(pair), bytes32(SLOT_VAULT_INSURANCE_FUND_BALANCE), bytes32(uint256(0)));
        usdc.mint(majorityVoter, recapUsdc);
        vm.startPrank(majorityVoter);
        usdc.approve(address(pair), recapUsdc);
        pair.depositToInsurance(recap, 0, 0, 0, "", "");
        vm.stopPrank();

        (,,,,, uint256 fund,,,,,,) = pair.pairVault();
        assertEq(fund, recap, "fund equals the second rescue amount");
        // The second rescuer owns 100% outright: every earlier generation reads as zero.
        assertEq(pair.insuranceShares(majorityVoter), recap, "supply restarted at the rescue amount");
        assertEq(pair.totalInsuranceShares(), recap, "no residual shares from earlier generations");
        assertEq(pair.insuranceShares(attacker), 0, "first rescuer's stake reads zero");
    }

    /// @notice After a long-aged lot has been pruned by a fresh deposit, the OLD shares
    ///         still vote (their counts live in totalShares, which is the source of truth).
    ///         Guards against off-by-one in the prune+walk math.
    function test_Maturity_PrunedOldLotsStillVote() public {
        // diluter deposits a big mature batch, waits long enough for it to be eligible
        // for pruning (21d), then makes a small fresh deposit that triggers pruning.
        _depositInsurance(diluter, 5_000 * BAZAAR_SCALE);
        vm.warp(block.timestamp + 22 days); // past LOT_RETENTION_PERIOD
        _depositInsurance(diluter, 5 * BAZAAR_SCALE); // triggers prune of the old lot

        // Now propose. The old 5,000 are mature; the freshly-pruned-and-then-redeposited
        // 5 are immature. Diluter must still be able to vote with the old 5,000.
        _proposeInsurerTermination(whaleProposer);
        uint256 diluterTotal = pair.insuranceShares(diluter);
        // mature_at_proposal_cutoff ~= 5,000 (the new $5 deposit is < 7d old at proposal time)
        uint64 cutoffTs = uint64(block.timestamp - 7 days);
        uint256 mature = pair.getSharesAsOf(diluter, cutoffTs);
        assertLt(mature, diluterTotal, "fresh top-up correctly excluded from mature");
        assertGt(mature, 0, "old pruned lot still counts toward mature voting power");

        vm.prank(diluter);
        terminator.voteForInsurerTermination(address(pair), mature);
        // No revert → vote went through using the pruned-lot mature shares.
    }
}

// ==================== from Phase2OracleUpgradeTest.t.sol ====================

/// @notice Regression tests for R2-3: the UMA oracle-upgrade governance path must use a
///         stricter dispute window and bond than the pair-deployment path. A protocol-wide
///         oracle swap with only 12-hour liveness was a low-friction governance-compromise
///         vector; Phase 2.4 raises it to 14 days + 5,000 USDC bond.
contract Phase2OracleUpgradeTest is Test {
    BazaarFactory factory;
    MockUSDC usdc;
    address proposer;

    function setUp() public {
        vm.etch(address(0x64), address(new MockArbSys()).code);
        proposer = makeAddr("proposer");

        DeployBazaar dep = new DeployBazaar();
        (factory,) = dep.deploy(makeAddr("bugBounty"));

        usdc = MockUSDC(factory.usdc());
        usdc.mint(proposer, 10_000 * 1e6);
    }

    /// @notice The new constants must match the Phase 2.4 spec (14 days / 5,000 USDC), plus the
    ///         14-day post-approval activation timelock.
    function test_R2_3_OracleUpgradeConstants() public view {
        assertEq(factory.ORACLE_UPGRADE_LIVENESS(), 14 days, "liveness = 14 days");
        assertEq(factory.ORACLE_UPGRADE_BOND_USDC(), 5_000 * 1e6, "bond = 5,000 USDC");
        assertEq(factory.ORACLE_UPGRADE_TIMELOCK(), 14 days, "activation timelock = 14 days");
        // Pair-deployment params: 48h liveness, cheap pair deployments stay cheap.
        assertEq(factory.DEPLOYMENT_LIVENESS(), 48 hours, "deployment liveness = 48 hours");
        assertEq(factory.DEPLOYMENT_BOND_USDC(), 1_000 * 1e6, "deployment bond unchanged");
    }

    // -------------------- activation timelock --------------------

    function _proposeUpgrade(address newOo) internal returns (bytes32 assertionId) {
        vm.startPrank(proposer);
        usdc.approve(address(factory), factory.ORACLE_UPGRADE_BOND_USDC());
        assertionId = factory.proposeUmaOracleUpgrade(newOo, bytes32("NEW_ID_v1"));
        vm.stopPrank();
    }

    /// @notice Approval QUEUES the upgrade behind the timelock — the oo pointer must not move.
    function test_Timelock_ApprovalQueuesButDoesNotSwap() public {
        address oldOo = address(factory.oo());
        address newOo = address(new MockOptimisticOracleV3(address(usdc), 7200));

        bytes32 aid = _proposeUpgrade(newOo);
        vm.warp(block.timestamp + 14 days + 1);
        factory.settleOracleUpgradeProposal(aid);

        assertEq(address(factory.oo()), oldOo, "oo unchanged during the timelock");
        (bytes32 qAid, address qOo,, uint256 effectiveTs) = factory.queuedOracleUpgrade();
        assertEq(qAid, aid, "queued assertion recorded");
        assertEq(qOo, newOo, "queued oracle recorded");
        assertEq(effectiveTs, block.timestamp + factory.ORACLE_UPGRADE_TIMELOCK(), "activates 14 days after approval");
    }

    /// @notice Activating before effectiveTs reverts; at/after it, anyone can activate.
    function test_Timelock_EarlyActivationReverts_ThenAnyoneActivates() public {
        address newOo = address(new MockOptimisticOracleV3(address(usdc), 7200));
        bytes32 aid = _proposeUpgrade(newOo);
        vm.warp(block.timestamp + 14 days + 1);
        factory.settleOracleUpgradeProposal(aid);

        (,,, uint256 effectiveTs) = factory.queuedOracleUpgrade();
        vm.expectRevert(abi.encodeWithSelector(BazaarFactory.Factory__OracleUpgradeTimelocked.selector, effectiveTs));
        factory.activateOracleUpgrade();

        vm.warp(effectiveTs);
        vm.prank(makeAddr("randomKeeper"));
        factory.activateOracleUpgrade();

        assertEq(address(factory.oo()), newOo, "swap executed after the timelock");
        (,,, uint256 clearedTs) = factory.queuedOracleUpgrade();
        assertEq(clearedTs, 0, "queue cleared after activation");

        vm.expectRevert(BazaarFactory.Factory__NoQueuedOracleUpgrade.selector);
        factory.activateOracleUpgrade();
    }

    /// @notice A queued (approved, not yet active) upgrade blocks new upgrade proposals until it
    ///         activates — the one-at-a-time invariant covers the timelock window too.
    function test_Timelock_ProposeDuringTimelockReverts() public {
        address newOo = address(new MockOptimisticOracleV3(address(usdc), 7200));
        bytes32 aid = _proposeUpgrade(newOo);
        vm.warp(block.timestamp + 14 days + 1);
        factory.settleOracleUpgradeProposal(aid);

        usdc.mint(proposer, 5_000 * 1e6);
        vm.startPrank(proposer);
        usdc.approve(address(factory), factory.ORACLE_UPGRADE_BOND_USDC());
        vm.expectRevert(BazaarFactory.Factory__OracleUpgradeStillPending.selector);
        factory.proposeUmaOracleUpgrade(makeAddr("anotherOo"), bytes32("NEW_ID_v2"));
        vm.stopPrank();
    }

    /// @notice A rejected (disputed-false) upgrade queues nothing.
    function test_Timelock_RejectedUpgradeQueuesNothing() public {
        MockOptimisticOracleV3 oo = MockOptimisticOracleV3(address(factory.oo()));
        // Probe-passing contract; "bad" in the DVM voters' judgment, not the conformance probe's.
        bytes32 aid = _proposeUpgrade(address(new MockOptimisticOracleV3(address(usdc), 7200)));

        address disputer = makeAddr("disputer");
        usdc.mint(disputer, 5_000 * 1e6);
        vm.startPrank(disputer);
        usdc.approve(address(oo), 5_000 * 1e6);
        oo.disputeAssertion(aid, disputer);
        vm.stopPrank();
        oo.mockDvmResolve(aid, false);

        factory.settleOracleUpgradeProposal(aid);

        (,,, uint256 effectiveTs) = factory.queuedOracleUpgrade();
        assertEq(effectiveTs, 0, "nothing queued on rejection");
        vm.expectRevert(BazaarFactory.Factory__NoQueuedOracleUpgrade.selector);
        factory.activateOracleUpgrade();
    }

    /// @notice Proposing an oracle upgrade with only the old (1,000 USDC) allowance reverts
    ///         because the new constant pulls 5,000 USDC.
    function test_R2_3_OldBondAllowance_NotEnough_Reverts() public {
        address newOo = address(new MockOptimisticOracleV3(address(usdc), 7200));
        vm.startPrank(proposer);
        // Approve only the old deployment bond amount (1k USDC).
        usdc.approve(address(factory), factory.DEPLOYMENT_BOND_USDC());
        vm.expectRevert(); // safeTransferFrom should revert on insufficient allowance
        factory.proposeUmaOracleUpgrade(newOo, bytes32("NEW_ID_v1"));
        vm.stopPrank();
    }

    /// @notice With the correct allowance, the proposal goes through and the factory's
    ///         USDC balance grew by exactly the new 5k bond amount.
    function test_R2_3_CorrectBond_ProposalSucceeds() public {
        uint256 factoryUsdcBefore = usdc.balanceOf(address(factory));
        uint256 proposerUsdcBefore = usdc.balanceOf(proposer);

        address newOo = address(new MockOptimisticOracleV3(address(usdc), 7200));
        vm.startPrank(proposer);
        usdc.approve(address(factory), factory.ORACLE_UPGRADE_BOND_USDC());
        bytes32 assertionId = factory.proposeUmaOracleUpgrade(newOo, bytes32("NEW_ID_v1"));
        vm.stopPrank();

        assertTrue(assertionId != bytes32(0), "assertion created");
        // Bond pulled from proposer (eventually forwarded to OO via assertTruth, so the
        // factory's net balance may be 0, but the proposer always lost the bond amount).
        assertEq(proposerUsdcBefore - usdc.balanceOf(proposer), 5_000 * 1e6, "5k pulled from proposer");
        // factory balance arithmetic is OO-implementation-dependent; the proposer-side
        // assertion is the cleanest invariant to check.
        factoryUsdcBefore; // suppress unused-warning
    }

    /// @notice H6 regression: an oracle upgrade must NOT brick deployment proposals that were
    ///         in-flight when the `oo` pointer swapped. Pre-fix, settleDeploymentProposal routed
    ///         the old assertion to the NEW oracle (which never saw it), permanently stranding
    ///         the proposal and its escrowed seed. Per-assertion OO recording lets the in-flight
    ///         proposal still settle on its original oracle and deploy.
    function test_OracleUpgrade_DoesNotBrickInFlightDeployment() public {
        address oldOo = address(factory.oo());

        // 1) Deployer proposes a pair → assertion created on the ORIGINAL oracle.
        address deployer = makeAddr("deployer");
        usdc.mint(deployer, 10_000 * 1e6);
        vm.startPrank(deployer);
        usdc.approve(address(factory), 5_000 * 1e6);
        bytes32 depId = factory.proposePairDeployment(bytes32("AAPL_FEED"), false, 5_000 * 1e18, "AAPL on NASDAQ");
        vm.stopPrank();

        // 2) Proposer proposes an oracle upgrade to a brand-new oracle → also on the original oracle.
        MockOptimisticOracleV3 newOo = new MockOptimisticOracleV3(address(usdc), 7200);
        vm.startPrank(proposer);
        usdc.approve(address(factory), factory.ORACLE_UPGRADE_BOND_USDC());
        bytes32 upId = factory.proposeUmaOracleUpgrade(address(newOo), bytes32("NEW_ID_v1"));
        vm.stopPrank();

        // 3) Both livenesses pass; settle the upgrade (queues it), wait out the activation
        //    timelock, then activate → factory.oo swaps to the new oracle.
        vm.warp(block.timestamp + 14 days + 1);
        factory.settleOracleUpgradeProposal(upId);
        assertEq(address(factory.oo()), oldOo, "approval only queues; swap waits out the timelock");
        vm.warp(block.timestamp + factory.ORACLE_UPGRADE_TIMELOCK() + 1);
        factory.activateOracleUpgrade();
        assertEq(address(factory.oo()), address(newOo), "oracle upgraded");
        assertTrue(address(factory.oo()) != oldOo, "oo pointer changed");

        // 4) The in-flight deployment STILL settles — on its original oracle — and deploys.
        //    (Pre-fix this reverted: settle routed to newOo, which has no record of depId.)
        factory.settleDeploymentProposal(depId);

        (,,,,,, bytes32 pairId,,, bool deployed) = factory.deploymentProposals(depId);
        assertTrue(deployed, "in-flight deployment settled despite the oracle upgrade");
        assertTrue(factory.getPairAddress(pairId) != address(0), "pair deployed");
    }
}

// ==================== from Phase4LogicTest.t.sol ====================

/// @notice Regression tests for Phase 4 fixes that are straightforward to assert directly:
///         - 4.2: CREATE_ORDER_TYPEHASH must use "expirationBlock" not "expirationTs"
///
///         The other Phase 4 fixes have integration-style regression tests:
///         - 4.1: testOrderType_StopLoss_FillsInPassB (MatchingEngineTest)
///         - 4.3: ETH-refund integration test would require a full BazaarPair + sequencer
///                + valid stale BatchInfo; skipping in favor of the smaller assertion that
///                the new helpers are wired correctly (covered by compile + suite green).
///         - 4.4: PermitExecutionFailed event — only emitted when a permit call reverts,
///                which requires a malicious or already-used permit. Covered by manual
///                inspection of the catch block.
///         - 4.5: superseded — post-cessation proposals no longer carry a proposer-supplied
///                price at all; settlement is the on-chain-verified historical tick
///                (see PostCessationTerminationTest).
contract Phase4LogicTest is Test {
    /// @notice 4.2: typehash must reference expirationBlock, not the misleading expirationTs.
    function test_CreateOrderTypehash_UsesExpirationBlock() public {
        bytes32 expected = keccak256(
            "CreateOrder(uint8 orderType,uint256 triggerPrice,uint256 limitPrice,uint256 maxSlippageBp,uint256 size,bool isLong,bool isPostOnly,uint256 expirationBlock,address integrator,uint256 nonce,uint256 deadline,uint256 relayerFee)"
        );
        assertEq(MetaTxLib.CREATE_ORDER_TYPEHASH, expected, "typehash uses expirationBlock");

        bytes32 oldBuggy = keccak256(
            "CreateOrder(uint8 orderType,uint256 triggerPrice,uint256 limitPrice,uint256 maxSlippageBp,uint256 size,bool isLong,bool isPostOnly,uint256 expirationTs,address integrator,uint256 nonce,uint256 deadline,uint256 relayerFee)"
        );
        assertTrue(MetaTxLib.CREATE_ORDER_TYPEHASH != oldBuggy, "typehash differs from old buggy form");
    }
}

/// @notice Post-cessation termination: the proposer supplies only a cessation TIMESTAMP; the
///         settlement price is the Pyth tick in [ts-2s, ts], verified on-chain by
///         terminateScheduledPair — never a proposer-supplied number. Acceptance schedules the
///         (past) timestamp (halting trading) and the precise-only grace runs from ACCEPTANCE,
///         so an immediate empty-calldata call can't force the last-stored-price fallback while
///         the genuine archived tick is still postable.
contract PostCessationTerminationTest is Test {
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    int32 constant BTC_EXPO = -8;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;
    uint256 constant GRACE = 3 hours; // mirror of SCHEDULED_TERMINATION_GRACE

    BazaarFactory factory;
    BazaarPair pair;
    BazaarPairTerminator terminator;
    MockUSDC usdc;
    MockPyth pyth;

    address deployer;
    address proposer;

    receive() external payable {}

    function setUp() public {
        deployer = makeAddr("deployer");
        proposer = makeAddr("proposer");

        vm.etch(address(0x64), address(new MockArbSys()).code);

        DeployBazaar dep = new DeployBazaar();
        (factory,) = dep.deploy(makeAddr("bugBounty"));
        usdc = MockUSDC(factory.usdc());
        terminator = factory.pairTerminator();

        usdc.mint(deployer, PROPOSAL_TOTAL_USDC);
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        pair = BazaarPair(payable(factory.getPairAddress(pairId)));

        pyth = MockPyth(address(BazaarOracle(pair.oracle()).pyth()));
        usdc.mint(proposer, 10_000 * USDC_SCALE);
    }

    /// @dev Push a live Pyth tick (feeds the pair's stored price via refreshPrice).
    function _push(int64 price, uint64 conf, uint64 publishTime) internal {
        bytes[] memory u = new bytes[](1);
        u[0] = pyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID, price, conf, BTC_EXPO, price, conf, publishTime, publishTime > 0 ? publishTime - 1 : 0
        );
        pyth.updatePriceFeeds(u);
    }

    /// @dev Build (without submitting) a Pyth update at a specific historical publishTime.
    function _historicalUpdate(int64 price, uint64 conf, uint64 publishTime) internal view returns (bytes[] memory u) {
        u = new bytes[](1);
        u[0] = pyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID, price, conf, BTC_EXPO, price, conf, publishTime, publishTime > 0 ? publishTime - 1 : 0
        );
    }

    function _propose(uint256 cessationTs) internal returns (bytes32 assertionId) {
        vm.startPrank(proposer);
        usdc.approve(address(terminator), 1_000 * USDC_SCALE);
        assertionId =
            terminator.proposePostCessationTermination(address(pair), "BTC/USD", cessationTs, "feed decommissioned");
        vm.stopPrank();
    }

    function _proposeAndAccept(uint256 cessationTs) internal returns (bytes32 assertionId) {
        assertionId = _propose(cessationTs);
        vm.warp(block.timestamp + terminator.POST_CESSATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(assertionId);
    }

    /// @notice Companion guard on the SCHEDULED path: lastTradingTs must sit at least the
    ///         12-hour liveness in the future, so a trading cutoff can never land before its own
    ///         dispute window ends.
    function test_ScheduledProposal_MinimumTwelveHourLead() public {
        uint256 liveness = terminator.TERMINATION_PROPOSAL_LIVENESS();

        vm.startPrank(proposer);
        usdc.approve(address(terminator), 2_000 * USDC_SCALE);

        // One second short of the liveness lead → rejected.
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__LastTradingTsTooSoon.selector,
                block.timestamp + liveness - 1,
                block.timestamp + liveness
            )
        );
        terminator.proposeTermination(address(pair), "BTC/USD", block.timestamp + liveness - 1, "delisting");

        // Exactly at the boundary → accepted.
        bytes32 aid = terminator.proposeTermination(address(pair), "BTC/USD", block.timestamp + liveness, "delisting");
        vm.stopPrank();
        assertTrue(aid != bytes32(0), "boundary proposal accepted");
    }

    /// @notice Post-cessation proposals carry a 72-hour dispute window (vs 12 h for scheduled):
    ///         acceptance halts the market instantly, so all scrutiny must precede approval.
    ///         Settling at the scheduled path's 12-hour mark must fail.
    function test_PostCessation_72HourLiveness_EarlySettleReverts() public {
        bytes32 aid = _propose(block.timestamp - 1 days);

        vm.warp(block.timestamp + 12 hours + 1); // scheduled-path liveness is not enough here
        vm.expectRevert();
        terminator.settleTerminationProposal(aid);
        assertEq(pair.scheduledTerminationTs(), 0, "nothing scheduled before the window ends");

        vm.warp(block.timestamp + 72 hours); // past the full 72-hour window
        terminator.settleTerminationProposal(aid);
        assertGt(pair.scheduledTerminationTs(), 0, "accepted after the 72-hour window");
    }

    /// @notice The cessation timestamp must already be in the past.
    function test_PostCessation_FutureTimestamp_Reverts() public {
        vm.startPrank(proposer);
        usdc.approve(address(terminator), 1_000 * USDC_SCALE);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InvalidPriceTimestamp.selector, block.timestamp + 1
            )
        );
        terminator.proposePostCessationTermination(address(pair), "BTC/USD", block.timestamp + 1, "feed decommissioned");
        vm.stopPrank();
    }

    /// @notice Acceptance only SCHEDULES the (past) cessation timestamp — the price-dependent
    ///         settlement runs in a separate retryable transaction, never inside the UMA callback.
    function test_PostCessation_AcceptanceSchedulesButDoesNotTerminate() public {
        uint256 cessationTs = block.timestamp - 1 days;
        _proposeAndAccept(cessationTs);

        assertEq(pair.scheduledTerminationTs(), cessationTs, "cessation timestamp scheduled");
        assertEq(terminator.terminationAcceptedTs(address(pair)), block.timestamp, "acceptance time recorded");
        assertFalse(pair.isPairTerminatedNormal(), "acceptance alone must not terminate");
        assertFalse(pair.isPairTerminatedEmergency(), "no emergency either");
    }

    /// @notice The settlement price comes from the on-chain-verified Pyth tick at the cessation
    ///         timestamp — not from anything the proposer typed.
    function test_PostCessation_PreciseTickSettlesAtVerifiedPrice() public {
        // Last valid print: $48k at t0. The feed then goes dark; the event is noticed 5 days later.
        uint64 t0 = uint64(block.timestamp);
        _push(48_000e8, 48e8, t0);
        pair.refreshPrice(new bytes[](0));
        vm.warp(t0 + 5 days);

        _proposeAndAccept(t0);

        // Within the acceptance-anchored grace: settle with the archived tick from t0.
        bytes[] memory pu = _historicalUpdate(48_000e8, 48e8, t0);
        uint256 fee = BazaarOracle(pair.oracle()).getUpdateFee(pu);
        vm.deal(address(this), fee);
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
        vm.warp(block.timestamp + 1 hours);
        pair.finalizeTermination();

        assertTrue(pair.isPairTerminatedNormal(), "terminated at the verified tick");
        assertEq(pair.auxState().normalTerminationPrice, 48_000 * BAZAAR_SCALE, "price from the tick, normalized");
    }

    /// @notice A tick outside [cessationTs - 2s, cessationTs] must not settle the pair — the
    ///         window is enforced on-chain by Pyth's parsePriceFeedUpdates.
    function test_PostCessation_OutOfWindowTick_Reverts() public {
        uint64 t0 = uint64(block.timestamp);
        _push(48_000e8, 48e8, t0);
        pair.refreshPrice(new bytes[](0));
        vm.warp(t0 + 5 days);

        _proposeAndAccept(t0);

        // A tick 10s after cessation (e.g. a manipulated/chaotic post-event print) is rejected.
        bytes[] memory pu = _historicalUpdate(1_000e8, 1e8, t0 + 10);
        uint256 fee = BazaarOracle(pair.oracle()).getUpdateFee(pu);
        vm.deal(address(this), fee);
        vm.expectRevert();
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
        assertFalse(pair.isPairTerminatedNormal(), "out-of-window tick rejected");
    }

    /// @notice REGRESSION (grace anchor): the precise-only grace runs from ACCEPTANCE, not from
    ///         the long-past cessation timestamp. Otherwise an attacker could front-run the honest
    ///         keeper right after acceptance with empty calldata, force the catch branch, and
    ///         settle at the last stored price instead of the true cessation tick.
    function test_PostCessation_WithinGraceOfAcceptance_EmptyDataReverts() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0);
        pair.refreshPrice(new bytes[](0)); // stored price exists → fallback WOULD be available
        vm.warp(t0 + 5 days); // cessation is far beyond t0 + GRACE

        _proposeAndAccept(t0);

        // Immediately after acceptance: empty calldata must revert, NOT fall back.
        bytes[] memory empty = new bytes[](0);
        vm.expectRevert();
        terminator.terminateScheduledPair(address(pair), empty);
        assertFalse(pair.isPairTerminatedNormal(), "no fallback inside the acceptance grace");

        // Still inside the grace at acceptance + GRACE exactly.
        vm.warp(block.timestamp + GRACE);
        vm.expectRevert();
        terminator.terminateScheduledPair(address(pair), empty);
        assertFalse(pair.isPairTerminatedNormal(), "grace holds until it fully elapses");
    }

    /// @notice Liveness guarantee: once the acceptance grace elapses with no verifiable tick
    ///         (feed had no tick in the window, or the archived payload can no longer verify),
    ///         the pair settles at its frozen last stored price rather than stranding forever.
    function test_PostCessation_AfterGrace_FallsBackToLastStoredPrice() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0);
        pair.refreshPrice(new bytes[](0)); // lastPairPrice ~$50k, frozen at/before cessation
        vm.warp(t0 + 5 days);

        _proposeAndAccept(t0);

        vm.warp(block.timestamp + GRACE + 1);
        terminator.terminateScheduledPair(address(pair), new bytes[](0));
        vm.warp(block.timestamp + 1 hours);
        pair.finalizeTermination();

        assertTrue(pair.isPairTerminatedNormal(), "fallback settles after the grace");
        assertEq(pair.auxState().normalTerminationPrice, 50_000 * BAZAAR_SCALE, "settled at last stored price");
    }

    /// @notice REGRESSION: the empty-calldata fallback must survive the Pyth CONTRACT itself being
    ///         bricked/migrated (every call into it reverting) — the worst-case "oracle
    ///         decommissioned" scenario. getUpdateFee sits outside the try/catch, so querying it
    ///         unconditionally would have made even the fallback revert and stranded the pair.
    function test_PostCessation_PythContractBricked_FallbackStillSettles() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0);
        pair.refreshPrice(new bytes[](0)); // stored price frozen before the contract dies
        vm.warp(t0 + 5 days);

        _proposeAndAccept(t0); // propose/accept touch UMA + BazaarOracle storage only, not Pyth

        // Brick the Pyth contract: every call (getUpdateFee, parsePriceFeedUpdates, ...) reverts.
        vm.etch(address(pyth), hex"60006000fd"); // PUSH1 0 PUSH1 0 REVERT

        // Within the grace nothing can settle (precise-only, and precise can't verify) …
        bytes[] memory empty = new bytes[](0);
        vm.expectRevert();
        terminator.terminateScheduledPair(address(pair), empty);

        // … but after the grace the fallback needs no Pyth call outside the try/catch.
        vm.warp(block.timestamp + GRACE + 1);
        terminator.terminateScheduledPair(address(pair), empty);
        vm.warp(block.timestamp + 1 hours);
        pair.finalizeTermination(); // needs no Pyth either — settles at the fixed price

        assertTrue(pair.isPairTerminatedNormal(), "pair settles despite a dead Pyth contract");
        assertEq(pair.auxState().normalTerminationPrice, 50_000 * BAZAAR_SCALE, "settled at last stored price");
    }
}

/// @notice terminateStalePair must terminate ONLY for a >21-day-stale oracle — never for any
///         other reason. It reads via tryReadStalePrice (spot if conf <=2%, else EMA); when no
///         rung clears the cap (found=false) or the oracle read reverts, it falls back to the
///         pair's last stored price but STILL requires 21-day staleness — so a transient
///         wide-conf / reverting read on a recently-active pair cannot be used to terminate it.
contract Phase4StaleTerminationTest is Test {
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    int32 constant BTC_EXPO = -8;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;
    uint256 constant DEAD = 21 days;

    BazaarFactory factory;
    BazaarPair pair;
    BazaarPairTerminator terminator;
    MockUSDC usdc;
    MockPyth pyth;

    function setUp() public {
        vm.etch(address(0x64), address(new MockArbSys()).code);
        DeployBazaar dep = new DeployBazaar();
        (factory,) = dep.deploy(makeAddr("bugBounty"));
        usdc = MockUSDC(factory.usdc());
        terminator = factory.pairTerminator();

        address deployer = makeAddr("deployer");
        usdc.mint(deployer, PROPOSAL_TOTAL_USDC);
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        pair = BazaarPair(payable(factory.getPairAddress(pairId)));

        pyth = MockPyth(address(BazaarOracle(pair.oracle()).pyth()));
    }

    function _push(int64 price, uint64 conf, uint64 publishTime) internal {
        bytes[] memory u = new bytes[](1);
        u[0] = pyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID, price, conf, BTC_EXPO, price, conf, publishTime, publishTime > 0 ? publishTime - 1 : 0
        );
        pyth.updatePriceFeeds(u);
    }

    /// @dev Push a feed with independently-set spot and EMA price/conf (to drive the stale ladder).
    function _pushSpotEma(int64 spotP, uint64 spotC, int64 emaP, uint64 emaC, uint64 pub) internal {
        bytes[] memory u = new bytes[](1);
        u[0] = pyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID, spotP, spotC, BTC_EXPO, emaP, emaC, pub, pub > 0 ? pub - 1 : 0
        );
        pyth.updatePriceFeeds(u);
    }

    function _terminated() internal view returns (bool) {
        return pair.isPairTerminatedNormal() || pair.isPairTerminatedEmergency();
    }

    /// @dev Two-stage termination: the terminator call only FIXES the settlement price and opens
    ///      the 1h terminal sweep window; finalize afterwards to flip the terminated flag.
    ///      Cheatcode timestamp: via_ir can re-materialize a stale block.timestamp post-call.
    function _finalize() internal {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        pair.finalizeTermination();
    }

    /// try path: oracle returns a price stale by > 21 days → terminates.
    function test_StaleOracle_TerminatesAfter21Days() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0);
        vm.warp(t0 + DEAD + 1);
        terminator.terminateStalePair(address(pair));
        _finalize();
        assertTrue(_terminated(), "stale > 21 days terminates");
    }

    /// try path: oracle fresh (< 21 days) → cannot terminate.
    function test_FreshOracle_CannotTerminate() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0);
        vm.warp(t0 + 20 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__OracleNotStaleEnough.selector, uint256(t0), DEAD
            )
        );
        terminator.terminateStalePair(address(pair));
    }

    /// catch path: oracle read reverts (≤0 price) but the pair was active recently → must NOT
    /// terminate. This is the "no other reason" guard: a transient revert can't be a side door.
    function test_OracleRevertsButRecent_CannotTerminate() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0);
        pair.refreshPrice(new bytes[](0)); // records lastPairPrice at ~t0
        _push(0, 0, t0 + 1); // ≤0 → no rung clears conf → tryReadStalePrice found=false
        vm.warp(t0 + 10 days); // recent (< 21 days)
        // lastPairPrice.updateTs == t0 (set by refreshPrice), so the catch's staleness guard fires.
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__OracleNotStaleEnough.selector, uint256(t0), DEAD
            )
        );
        terminator.terminateStalePair(address(pair));
    }

    /// catch path: oracle read reverts AND the pair has been stale > 21 days → terminates at
    /// the last stored price (the genuine dead-oracle case the fallback is for).
    function test_OracleDeadAndStale_TerminatesViaFallback() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0);
        pair.refreshPrice(new bytes[](0));
        _push(0, 0, t0 + 1); // ≤0 → no rung clears conf → tryReadStalePrice found=false
        vm.warp(t0 + DEAD + 1); // stale > 21 days
        terminator.terminateStalePair(address(pair));
        _finalize();
        assertTrue(_terminated(), "dead + stale terminates via lastPairPrice fallback");
    }

    /// stale ladder: spot conf too wide (>2%) but EMA conf tight, stale > 21 days → terminates at
    /// the EMA price (rung 2), not the wide spot. The publish time is shared, so the staleness
    /// gate still uses the genuine 21-day age.
    function test_StaleWideSpot_TerminatesViaEmaRung() public {
        uint64 t0 = uint64(block.timestamp);
        // spot: 50k +/- 5k (10% conf, wide); EMA: 48k +/- 48 (0.1% conf, tight)
        _pushSpotEma(50_000e8, 5_000e8, 48_000e8, 48e8, t0);
        vm.warp(t0 + DEAD + 1);
        terminator.terminateStalePair(address(pair));
        _finalize();
        assertTrue(_terminated(), "wide spot but tight EMA + stale -> terminates via EMA rung");
    }

    /// stale ladder: both spot and EMA conf too wide → tryReadStalePrice found=false → falls back
    /// to the last stored (conf-checked-when-recorded) price; still terminates because stale > 21d.
    function test_StaleBothWide_TerminatesViaLastStored() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0); // tight -> refreshPrice records lastPairPrice at ~t0
        pair.refreshPrice(new bytes[](0));
        _pushSpotEma(50_000e8, 5_000e8, 48_000e8, 4_800e8, t0 + 1); // both ~10% conf (wide)
        vm.warp(t0 + DEAD + 1);
        terminator.terminateStalePair(address(pair));
        _finalize();
        assertTrue(_terminated(), "both rungs wide + stale -> terminates via last stored price");
    }

    // -------------------- scheduled termination price window --------------------

    /// @dev Build (without submitting) a Pyth update at a specific historical publishTime.
    function _historicalUpdate(int64 price, uint64 conf, uint64 publishTime) internal view returns (bytes[] memory u) {
        u = new bytes[](1);
        u[0] = pyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID, price, conf, BTC_EXPO, price, conf, publishTime, publishTime > 0 ? publishTime - 1 : 0
        );
    }

    function _schedule(uint256 lastTradingTs) internal {
        vm.prank(pair.umaContract());
        pair.setScheduledTermination(lastTradingTs, address(this));
    }

    /// Within the 3h grace, a precise in-window tick settles the scheduled termination.
    function test_ScheduledTermination_WithinGrace_PreciseTickSettles() public {
        _push(50_000e8, 50e8, uint64(block.timestamp));
        pair.refreshPrice(new bytes[](0));

        uint256 scheduledTs = block.timestamp + 1 hours;
        _schedule(scheduledTs);

        uint64 pubT = uint64(scheduledTs) - 1;
        bytes[] memory pu = _historicalUpdate(48_000e8, 48e8, pubT);
        uint256 fee = BazaarOracle(pair.oracle()).getUpdateFee(pu);

        vm.warp(scheduledTs + 1); // within grace
        vm.deal(address(this), fee);
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
        _finalize();
        assertTrue(_terminated(), "precise tick settles within grace");
    }

    /// Within the grace, missing the precise tick reverts — NO last-price fallback yet, so bad/empty
    /// data can't force a fallback while a real tick may still be postable.
    function test_ScheduledTermination_WithinGrace_NoTickReverts() public {
        _push(50_000e8, 50e8, uint64(block.timestamp));
        pair.refreshPrice(new bytes[](0));

        uint256 scheduledTs = block.timestamp + 1 hours;
        _schedule(scheduledTs);
        vm.warp(scheduledTs + 1); // within grace

        bytes[] memory empty = new bytes[](0);
        vm.expectRevert(); // Pyth: no tick in [scheduledTs-2, scheduledTs]; no fallback in grace
        terminator.terminateScheduledPair(address(pair), empty);
        assertFalse(_terminated(), "not terminated; no fallback during grace");
    }

    /// After the 3h grace, missing the precise tick settles at the last stored price (capped at
    /// scheduledTs) so the pair can't be stranded in scheduled-but-not-terminated limbo.
    function test_ScheduledTermination_AfterGrace_FallsBackToLastPrice() public {
        _push(50_000e8, 50e8, uint64(block.timestamp));
        pair.refreshPrice(new bytes[](0)); // lastPairPrice ~ $50k, publishTime <= scheduledTs

        uint256 scheduledTs = block.timestamp + 1 hours;
        _schedule(scheduledTs);
        vm.warp(scheduledTs + 3 hours + 1); // past the grace

        bytes[] memory empty = new bytes[](0);
        terminator.terminateScheduledPair(address(pair), empty); // no tick → last-price fallback
        _finalize();
        assertTrue(_terminated(), "falls back to last stored price after grace");
    }
}

