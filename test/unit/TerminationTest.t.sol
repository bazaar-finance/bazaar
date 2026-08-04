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

// ==================== termination PnL / frozen ratio ====================

/// @notice Harness owning Vault + TerminalSettlement storage, forwarding into TerminationLib's
///         finalize so the frozen-ratio math (surplus/claims from ACTUAL cash) can be unit-tested
///         without a full BazaarPair. Winner profit claims are pre-registered via setClaims (the
///         48h settlement window's job in production); the estate/funding/bad-debt legs are seeded
///         directly.
contract TerminationHarness {
    BazaarTypes.Vault public vault;
    BazaarTypes.TerminalSettlement public ts;

    function setVault(
        uint256 totalCollateralDeposited,
        uint256 insuranceFundBalance,
        uint256 pendingLiqSize,
        uint256 pendingLiqEntryNotional,
        uint256 pendingLiqBankruptcyNotional,
        int256 pendingLiqEntryFundingIndex,
        bool pendingLiqIsLong
    ) external {
        vault.totalCollateralDeposited = totalCollateralDeposited;
        vault.insuranceFundBalance = insuranceFundBalance;
        vault.pendingLiqSize = pendingLiqSize;
        vault.pendingLiqEntryNotional = pendingLiqEntryNotional;
        vault.pendingLiqBankruptcyNotional = pendingLiqBankruptcyNotional;
        vault.pendingLiqEntryFundingIndex = pendingLiqEntryFundingIndex;
        vault.pendingLiqIsLong = pendingLiqIsLong;
    }

    function setClaims(uint256 totalProfitClaims, uint256 terminalBadDebt) external {
        ts.totalProfitClaims = totalProfitClaims;
        ts.terminalBadDebt = terminalBadDebt;
    }

    function setDeficit(uint256 d) external {
        vault.deficit = d;
    }

    function deficit() external view returns (uint256) {
        return vault.deficit;
    }

    function insurance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function collateral() external view returns (uint256) {
        return vault.totalCollateralDeposited;
    }

    function profitReserve() external view returns (uint256) {
        return ts.profitReserve;
    }

    function execTerm(BazaarTypes.TerminationParams memory params)
        external
        returns (BazaarTypes.TerminationResult memory)
    {
        return TerminationLib.executeTermination(vault, ts, params);
    }
}

/// @notice Unit tests for the frozen-ratio normal-termination finalize (TerminationLib). The
///         profit payout ratio is min(100%, surplus/claims) computed from ACTUAL cash minus the
///         principal reserve (D) and insurers' remainder (I) — never from net-per-side PnL
///         aggregates, whose net-of-side denominator would zero every winner over a 1-wei
///         shortfall on an internally hedged book.
contract Phase2TerminationPnlTest is Test {
    TerminationHarness harness;
    MockUSDC usdc;

    uint256 constant SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant PRICE = 100 * 1e18;

    function setUp() public {
        harness = new TerminationHarness();
        usdc = new MockUSDC();
    }

    function _params() internal view returns (BazaarTypes.TerminationParams memory) {
        return BazaarTypes.TerminationParams({
            isEmergency: false,
            terminationPrice: PRICE,
            usdc: address(usdc),
            pairId: bytes32(uint256(0xBA2AAA)),
            currentFundingIndex: 0
        });
    }

    /// @notice Solvent book: cash covers principal + insurers + all profit claims -> ratio 100%.
    function test_Solvent_FullProfitRatio() public {
        // D = 2000, I = 50, claims = 400. Cash 2600 -> surplus 550 >= 400 -> 100%.
        harness.setVault(2_000 * SCALE, 50 * SCALE, 0, 0, 0, 0, false);
        harness.setClaims(400 * SCALE, 0);
        usdc.mint(address(harness), 2_600 * USDC_SCALE);

        BazaarTypes.TerminationResult memory r = harness.execTerm(_params());
        assertEq(r.winnersPayoutRatioBp, 10_000, "surplus covers claims: 100%");
        assertEq(r.normalCollateralRatioBp, 10_000, "principal never haircut when cash >= D");
        assertEq(harness.profitReserve(), 400 * SCALE, "full claims reserved");
    }

    /// @notice Shortfall: surplus below total claims -> uniform pro-rata haircut = surplus/claims.
    function test_Shortfall_ProRataRatioFromCash() public {
        // D = 2000, I = 50, claims = 400. Cash 2250 -> surplus 200 -> ratio 200/400 = 50%.
        harness.setVault(2_000 * SCALE, 50 * SCALE, 0, 0, 0, 0, false);
        harness.setClaims(400 * SCALE, 0);
        usdc.mint(address(harness), 2_250 * USDC_SCALE);

        BazaarTypes.TerminationResult memory r = harness.execTerm(_params());
        assertEq(r.winnersPayoutRatioBp, 5_000, "surplus/claims = 50%");
        assertEq(r.normalCollateralRatioBp, 10_000, "principal fully reserved");
        assertEq(harness.profitReserve(), 200 * SCALE, "reserve = claims x ratio = surplus");
    }

    /// @notice An internally hedged winning side (net PnL ≈ 0) must NOT collapse the ratio. A
    ///         net-per-side denominator would read ~0 here and wipe every winner over a trivial
    ///         shortfall; the cash-based denominator is the real claim total.
    function test_R1_InternallyHedgedSide_NoSpuriousWipeout() public {
        // Registered claims total 1000 (e.g. many winners) even though a naive per-side net could
        // be near zero. Cash gives surplus 900 -> ratio 90%, NOT 0.
        harness.setVault(5_000 * SCALE, 100 * SCALE, 0, 0, 0, 0, false);
        harness.setClaims(1_000 * SCALE, 0);
        usdc.mint(address(harness), 6_000 * USDC_SCALE); // surplus = 6000 - 5000 - 100 = 900

        BazaarTypes.TerminationResult memory r = harness.execTerm(_params());
        assertEq(r.winnersPayoutRatioBp, 9_000, "ratio from real claim total, no spurious wipeout");
    }

    /// @notice Bad debt is charged to insurance first, shrinking the insurers' remainder and
    ///         thereby growing the profit surplus by the same amount.
    function test_BadDebt_ChargedToInsurance_GrowsSurplus() public {
        // D = 2000, I = 300, badDebt = 200, claims = 400.
        // After charge: I = 100. Cash 2500 -> surplus = 2500 - 2000 - 100 = 400 >= 400 -> 100%.
        harness.setVault(2_000 * SCALE, 300 * SCALE, 0, 0, 0, 0, false);
        harness.setClaims(400 * SCALE, 200 * SCALE);
        usdc.mint(address(harness), 2_500 * USDC_SCALE);

        BazaarTypes.TerminationResult memory r = harness.execTerm(_params());
        assertEq(harness.insurance(), 100 * SCALE, "insurance charged the bad debt");
        assertEq(r.winnersPayoutRatioBp, 10_000, "freed insurance reservation covers claims");
    }

    /// @notice Deficit (realized bad debt from matching/netting) charges insurance identically.
    function test_DeficitFold_ChargedToInsurance() public {
        harness.setVault(2_000 * SCALE, 300 * SCALE, 0, 0, 0, 0, false);
        harness.setClaims(400 * SCALE, 0);
        harness.setDeficit(200 * SCALE);
        usdc.mint(address(harness), 2_500 * USDC_SCALE);

        BazaarTypes.TerminationResult memory r = harness.execTerm(_params());
        assertEq(harness.insurance(), 100 * SCALE, "deficit charged to insurance");
        assertEq(harness.deficit(), 0, "deficit consumed");
        assertEq(r.winnersPayoutRatioBp, 10_000, "surplus covers claims after charge");
    }

    /// @notice Black-swan: cash below the principal reserve -> principal itself haircut pro-rata
    ///         against the pot, and the profit ratio is 0 (no surplus).
    function test_CashBelowPrincipal_HaircutsPrincipal() public {
        // D = 2000, I = 0, claims = 100. Cash only 1500 -> cash < D.
        harness.setVault(2_000 * SCALE, 0, 0, 0, 0, 0, false);
        harness.setClaims(100 * SCALE, 0);
        usdc.mint(address(harness), 1_500 * USDC_SCALE);

        BazaarTypes.TerminationResult memory r = harness.execTerm(_params());
        assertEq(r.normalCollateralRatioBp, 7_500, "principal haircut = cash/D = 75%");
        assertEq(r.winnersPayoutRatioBp, 0, "no surplus -> 0 profit ratio");
    }

    /// @notice Black swan with live insurance: when cash < D, the insurers'
    ///         book claim must be ZEROED, not left standing. Insurance is junior to principal;
    ///         a surviving I is a phantom claim on USDC already committed to the haircut
    ///         principal — post-termination insurance withdrawals are cooldown-exempt, so
    ///         junior money would exit first and the last principal withdrawals would revert.
    function test_N1_CashBelowPrincipal_InsuranceClaimZeroed() public {
        // D = 2000, I = 50, claims = 100. Cash 1500 < D. No REGISTERED bad debt: the gap is
        // unregistered drift, which the ts.terminalBadDebt/deficit charge cannot see.
        harness.setVault(2_000 * SCALE, 50 * SCALE, 0, 0, 0, 0, false);
        harness.setClaims(100 * SCALE, 0);
        usdc.mint(address(harness), 1_500 * USDC_SCALE);

        BazaarTypes.TerminationResult memory r = harness.execTerm(_params());
        assertEq(r.normalCollateralRatioBp, 7_500, "principal haircut = cash/D = 75%");
        assertEq(harness.insurance(), 0, "insurance claim zeroed: no cash beyond principal");
        assertEq(r.winnersPayoutRatioBp, 0, "no surplus -> 0 profit ratio");
        assertEq(harness.profitReserve(), 0, "nothing reserved for profits");
    }

    /// @notice Gap band: D <= cash < D + I. Principal is fully covered (no
    ///         haircut) but the insurers' claim exceeds the post-principal residual — it must
    ///         be written down to exactly cash - D so total withdrawable never exceeds the pot.
    function test_N1_GapBand_InsuranceClampedToResidualCash() public {
        // D = 2000, I = 300, claims = 400. Cash 2100: residual after principal = 100 < I.
        harness.setVault(2_000 * SCALE, 300 * SCALE, 0, 0, 0, 0, false);
        harness.setClaims(400 * SCALE, 0);
        usdc.mint(address(harness), 2_100 * USDC_SCALE);

        BazaarTypes.TerminationResult memory r = harness.execTerm(_params());
        assertEq(r.normalCollateralRatioBp, 10_000, "principal fully reserved, no haircut");
        assertEq(harness.insurance(), 100 * SCALE, "insurance clamped to cash - D");
        assertEq(r.winnersPayoutRatioBp, 0, "no surplus above D + clamped I");
        assertEq(harness.profitReserve(), 0, "nothing reserved for profits");
    }

    /// @notice No-op guard: on solvent books (cash >= D + I) the clamp must not move I at all —
    ///         it is a write-down for shortfalls, not a repricing every termination pays.
    function test_N1_Solvent_InsuranceUntouched() public {
        // Same shape as test_Solvent_FullProfitRatio, additionally pinning I afterwards.
        harness.setVault(2_000 * SCALE, 50 * SCALE, 0, 0, 0, 0, false);
        harness.setClaims(400 * SCALE, 0);
        usdc.mint(address(harness), 2_600 * USDC_SCALE);

        BazaarTypes.TerminationResult memory r = harness.execTerm(_params());
        assertEq(harness.insurance(), 50 * SCALE, "clamp is a no-op when cash covers D + I");
        assertEq(r.winnersPayoutRatioBp, 10_000, "solvent profit ratio unchanged");
        assertEq(r.normalCollateralRatioBp, 10_000, "no principal haircut");
    }

    /// @notice Ordering: the registered bad-debt charge shrinks I first; the clamp then
    ///         writes down only whatever the charge left standing.
    function test_N1_BadDebtCharge_ThenClamp() public {
        // D = 2000, I = 300, registered badDebt = 200 -> I = 100 after the charge.
        // Cash 1900 < D -> haircut 95%, and the clamp zeroes the remaining 100.
        harness.setVault(2_000 * SCALE, 300 * SCALE, 0, 0, 0, 0, false);
        harness.setClaims(0, 200 * SCALE);
        usdc.mint(address(harness), 1_900 * USDC_SCALE);

        BazaarTypes.TerminationResult memory r = harness.execTerm(_params());
        assertEq(r.normalCollateralRatioBp, 9_500, "principal haircut = 1900/2000");
        assertEq(harness.insurance(), 0, "charged for registered bad debt, then clamped to 0");
    }

    /// @notice The estate (pendingLiq) funding leg is settled at termination, not
    ///         discarded. A long estate with a positive funding delta owes funding; that reduces
    ///         its entry->settlement value, shifting the I/D split accordingly.
    function test_R2_EstateFundingLeg_Settled() public {
        // Long estate: size 10, entryNotional 1000 ($100/unit), settle at PRICE=$100 -> price leg 0.
        // Funding index moved +5 (per unit, xsize 10 / SCALE) -> fundingLeg = 50. Long pays it, so
        // estate value change = 0 - 0 - 50 = -50 -> I -= 50, D += 50.
        harness.setVault(2_000 * SCALE, 500 * SCALE, 10 * SCALE, 1_000 * SCALE, 1_000 * SCALE, 0, true);
        harness.setClaims(0, 0);
        usdc.mint(address(harness), 2_500 * USDC_SCALE);

        BazaarTypes.TerminationParams memory p = _params();
        p.currentFundingIndex = 5 * int256(SCALE); // +5 per unit
        harness.execTerm(p);

        assertEq(harness.insurance(), 450 * SCALE, "estate funding obligation charged to insurance");
        assertEq(harness.collateral(), 2_050 * SCALE, "counterparties' funding backing moved into D");
    }

    /// @notice No claims registered (nobody settled, or no winners) -> ratio 100% trivially,
    ///         nothing reserved for profits.
    function test_NoClaims_RatioIsFull() public {
        harness.setVault(1_000 * SCALE, 100 * SCALE, 0, 0, 0, 0, false);
        harness.setClaims(0, 0);
        usdc.mint(address(harness), 1_100 * USDC_SCALE);

        BazaarTypes.TerminationResult memory r = harness.execTerm(_params());
        assertEq(r.winnersPayoutRatioBp, 10_000, "no claims -> full ratio");
        assertEq(harness.profitReserve(), 0, "nothing reserved for profits");
    }
}

// ==================== insurer vote / share dilution ====================

/// @notice The insurer-vote share-dilution attack and its offensive counterpart (acquiring shares
///         to pass an unjust vote during the proposal window). Two defenses close both directions:
///         snapshotTotalShares freezes the threshold denominator at proposal creation, so minting
///         cannot move the bar; and the share-maturity check (7-day age) disqualifies shares
///         minted inside the maturity window before a proposal from voting on it. Withdrawals are
///         gated on mature shares only.
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
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        pair.finalizeTermination();
    }

    // -------------------- Tests --------------------

    /// @notice Defensive dilution: a defender deposits between vote-end and execution. Recomputing
    ///         the threshold off the live supply would scale it up and sink a vote that had already
    ///         passed; frozen at the snapshot, the vote still passes.
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

    /// @notice Offensive acquisition: an attacker deposits a large amount mid-voting
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

    /// @notice A failed insurer-vote forfeits the 400 USDC bond into the insurance fund,
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
        // Bond in BAZAAR_SCALE = 400 USDC x 1e12 = 400e18
        uint256 expectedBazaarGain = INSURER_BOND_USDC * 1e12;
        assertEq(insuranceAfter - insuranceBefore, expectedBazaarGain, "insurance bookkeeping grew by bond amount");
    }

    /// @notice Negative case: a successful insurer vote refunds the bond to the proposer
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

        // No price update or ETH is needed — the pre-empted branch returns before any
        // termination/oracle work. Treating an already-terminated pair as an error here would
        // revert AlreadyTerminated and strand the bond.
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

    /// @notice A proposal that expires with nobody calling executeInsurerTermination is settled by
    ///         the NEXT proposeInsurerTermination before the struct is overwritten. Failed-vote
    ///         case: the stale bond forfeits to the pair's insurance fund. Overwriting without
    ///         settling first would discard the only reference to that bond, stranding it in the
    ///         terminator forever.
    function test_L8_ExpiredUnresolvedProposal_SettledOnOverwrite_ForfeitsToInsurance() public {
        _proposeInsurerTermination(whaleProposer);

        // Nobody votes and nobody executes. The execution window (7d voting + 7d execution) and
        // the 14-day re-proposal cooldown expire at the same moment — one second later, the slot
        // is overwritable.
        vm.warp(block.timestamp + 14 days + 1);

        uint256 terminatorBefore = usdc.balanceOf(address(terminator));
        uint256 pairBefore = usdc.balanceOf(address(pair));
        (,,,,, uint256 insuranceBefore,,,,,,) = pair.pairVault();

        // The overwriting proposal settles the expired one: old bond -> insurance fund.
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

    /// @notice Consensus case: the vote passed but nobody executed inside the
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
        // No revert -> shares were eligible.
    }

    /// @notice MIN_INSURANCE_DEPOSIT floor (=$5) prevents dust deposits that would otherwise
    ///         enable orphan-balance capture (deposit 1 wei -> 100% share via bootstrap).
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

    /// @notice Zero-amount votes are rejected. Without the guard they clear every other check and
    ///         emit a noise event with amount=0 — wasted gas, spammy logs.
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
        // (= the state under test).
        vm.prank(umaCaller);
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        _finalizeAfterSweep();
        assertTrue(pair.isPairTerminatedNormal(), "scheduled termination executed");
        assertGt(pair.scheduledTerminationTs(), 0, "state under test: scheduledTerminationTs still set");

        // An insurance LP requests + executes withdrawal — must succeed. A terminated pair whose
        // schedule stamp is still set must not read as "scheduled for termination" and freeze exits.
        bytes[] memory pu = _btcPriceUpdate(uint64(vm.getBlockTimestamp()));
        uint256 majShares = pair.insuranceShares(majorityVoter);
        vm.prank(majorityVoter);
        pair.requestInsuranceWithdrawal(majShares, 0, 0, 0, "", "");
        // Terminated -> no cooldown wait needed.
        vm.prank(majorityVoter);
        pair.executeInsuranceWithdrawal(pu, 0, 0, 0, "");
        assertEq(pair.insuranceShares(majorityVoter), 0, "withdrawal succeeded post-scheduled-termination");
    }

    /// @dev Vault.insuranceFundBalance lives at slot 6 + offset 5 = 11.
    uint256 constant SLOT_VAULT_INSURANCE_FUND_BALANCE = 11;

    /// @notice When a bad-debt cascade drains the insurance fund to 0 without triggering
    ///         termination (e.g. no pending liquidations when the last loss settles), a
    ///         recapitalizer MUST be able to deposit. Pricing the new shares off the drained fund
    ///         would divide by zero (shares = amount * total / 0); the deposit instead bumps the
    ///         share epoch — pre-drain balances lazily read as 0 — and reprices at a clean 1:1 in
    ///         a single transaction, with no holder enumeration.
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
    ///         wipe+rescue cycle minted amount x supply shares, overflowed the then-uint192
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
        // Under 1-wei pricing this cycle overflows: the supply is already x(amount-in-wei)
        // inflated, so amount x supply blows past any narrow lot field. The epoch reset restarts
        // the supply at the rescue amount, and the lot field is full-width, so nothing truncates.
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
        vm.warp(block.timestamp + 22 days); // past INSURER_LOT_RETENTION_PERIOD (21d)
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
        // No revert -> vote went through using the pruned-lot mature shares.
    }
}

// ==================== UMA identifier-upgrade governance ====================

/// @notice The UMA identifier-upgrade governance path must cost more than the pair-deployment
///         path. A protocol-wide change to the adjudicating identifier at deployment-grade
///         friction (1,000 USDC, no timelock) would be a cheap governance-compromise vector, so
///         it runs at a 5,000 USDC bond and a 14-day activation timelock on top of its 2-day
///         liveness.
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

    /// @notice Governance-track constants: 2-day liveness / 5,000 USDC bond, plus the
    ///         14-day post-approval activation timelock.
    function test_R2_3_OracleUpgradeConstants() public view {
        assertEq(factory.IDENTIFIER_UPGRADE_LIVENESS(), 2 days, "liveness = 2 days");
        assertEq(factory.IDENTIFIER_UPGRADE_BOND_USDC(), 5_000 * 1e6, "bond = 5,000 USDC");
        assertEq(factory.IDENTIFIER_UPGRADE_TIMELOCK(), 14 days, "activation timelock = 14 days");
        // Pair-deployment params: 48h liveness, cheap pair deployments stay cheap.
        assertEq(factory.DEPLOYMENT_LIVENESS(), 48 hours, "deployment liveness = 48 hours");
        assertEq(factory.DEPLOYMENT_BOND_USDC(), 1_000 * 1e6, "deployment bond = 1,000 USDC");
    }

    // -------------------- activation timelock --------------------

    function _proposeUpgrade(bytes32 newIdentifier) internal returns (bytes32 assertionId) {
        vm.startPrank(proposer);
        usdc.approve(address(factory), factory.IDENTIFIER_UPGRADE_BOND_USDC());
        assertionId = factory.proposeUmaIdentifierUpgrade(newIdentifier);
        vm.stopPrank();
    }

    /// @notice Approval QUEUES the upgrade behind the timelock — the identifier must not move.
    function test_Timelock_ApprovalQueuesButDoesNotSwap() public {
        bytes32 oldIdentifier = factory.umaIdentifier();

        bytes32 aid = _proposeUpgrade("ASSERT_TRUTH5");
        vm.warp(block.timestamp + 14 days + 1);
        factory.settleIdentifierUpgradeProposal(aid);

        assertEq(factory.umaIdentifier(), oldIdentifier, "identifier unchanged during the timelock");
        (bytes32 qAid, bytes32 qId, uint256 effectiveTs) = factory.queuedIdentifierUpgrade();
        assertEq(qAid, aid, "queued assertion recorded");
        assertEq(qId, bytes32("ASSERT_TRUTH5"), "queued identifier recorded");
        assertEq(
            effectiveTs, block.timestamp + factory.IDENTIFIER_UPGRADE_TIMELOCK(), "activates 14 days after approval"
        );
    }

    /// @notice Activating before effectiveTs reverts; at/after it, anyone can activate.
    function test_Timelock_EarlyActivationReverts_ThenAnyoneActivates() public {
        bytes32 aid = _proposeUpgrade("ASSERT_TRUTH5");
        vm.warp(block.timestamp + 14 days + 1);
        factory.settleIdentifierUpgradeProposal(aid);

        (,, uint256 effectiveTs) = factory.queuedIdentifierUpgrade();
        vm.expectRevert(
            abi.encodeWithSelector(BazaarFactory.Factory__IdentifierUpgradeTimelocked.selector, effectiveTs)
        );
        factory.activateIdentifierUpgrade();

        vm.warp(effectiveTs);
        vm.prank(makeAddr("randomKeeper"));
        factory.activateIdentifierUpgrade();

        assertEq(factory.umaIdentifier(), bytes32("ASSERT_TRUTH5"), "swap executed after the timelock");
        (,, uint256 clearedTs) = factory.queuedIdentifierUpgrade();
        assertEq(clearedTs, 0, "queue cleared after activation");

        vm.expectRevert(BazaarFactory.Factory__NoQueuedIdentifierUpgrade.selector);
        factory.activateIdentifierUpgrade();
    }

    /// @notice A queued (approved, not yet active) upgrade blocks new upgrade proposals until it
    ///         activates — the one-at-a-time invariant covers the timelock window too.
    function test_Timelock_ProposeDuringTimelockReverts() public {
        bytes32 aid = _proposeUpgrade("ASSERT_TRUTH5");
        vm.warp(block.timestamp + 14 days + 1);
        factory.settleIdentifierUpgradeProposal(aid);

        usdc.mint(proposer, 5_000 * 1e6);
        vm.startPrank(proposer);
        usdc.approve(address(factory), factory.IDENTIFIER_UPGRADE_BOND_USDC());
        vm.expectRevert(BazaarFactory.Factory__IdentifierUpgradeStillPending.selector);
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH6");
        vm.stopPrank();
    }

    /// @notice A rejected (disputed-false) upgrade queues nothing.
    function test_Timelock_RejectedUpgradeQueuesNothing() public {
        MockOptimisticOracleV3 oo = MockOptimisticOracleV3(address(factory.oo()));
        // Whitelisted identifier; "bad" in the DVM voters' judgment, not the whitelist's.
        bytes32 aid = _proposeUpgrade("ASSERT_TRUTH5");

        address disputer = makeAddr("disputer");
        usdc.mint(disputer, 5_000 * 1e6);
        vm.startPrank(disputer);
        usdc.approve(address(oo), 5_000 * 1e6);
        oo.disputeAssertion(aid, disputer);
        vm.stopPrank();
        oo.mockDvmResolve(aid, false);

        factory.settleIdentifierUpgradeProposal(aid);

        (,, uint256 effectiveTs) = factory.queuedIdentifierUpgrade();
        assertEq(effectiveTs, 0, "nothing queued on rejection");
        vm.expectRevert(BazaarFactory.Factory__NoQueuedIdentifierUpgrade.selector);
        factory.activateIdentifierUpgrade();
    }

    /// @notice Approving only DEPLOYMENT_BOND_USDC (1,000) is not enough to propose an identifier
    ///         upgrade: that path pulls IDENTIFIER_UPGRADE_BOND_USDC (5,000), so safeTransferFrom
    ///         reverts on the allowance.
    function test_R2_3_OldBondAllowance_NotEnough_Reverts() public {
        vm.startPrank(proposer);
        // Approve only the deployment bond (1k USDC) — the smaller of the factory's two bonds.
        usdc.approve(address(factory), factory.DEPLOYMENT_BOND_USDC());
        vm.expectRevert(); // safeTransferFrom should revert on insufficient allowance
        factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH5");
        vm.stopPrank();
    }

    /// @notice With the correct allowance, the proposal goes through and the factory's USDC
    ///         balance grows by exactly the 5k identifier-upgrade bond.
    function test_R2_3_CorrectBond_ProposalSucceeds() public {
        uint256 factoryUsdcBefore = usdc.balanceOf(address(factory));
        uint256 proposerUsdcBefore = usdc.balanceOf(proposer);

        vm.startPrank(proposer);
        usdc.approve(address(factory), factory.IDENTIFIER_UPGRADE_BOND_USDC());
        bytes32 assertionId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH5");
        vm.stopPrank();

        assertTrue(assertionId != bytes32(0), "assertion created");
        // Bond pulled from proposer (eventually forwarded to OO via assertTruth, so the
        // factory's net balance may be 0, but the proposer always lost the bond amount).
        assertEq(proposerUsdcBefore - usdc.balanceOf(proposer), 5_000 * 1e6, "5k pulled from proposer");
        // factory balance arithmetic is OO-implementation-dependent; the proposer-side
        // assertion is the cleanest invariant to check.
        factoryUsdcBefore; // suppress unused-warning
    }

    /// @notice H6-class regression, identifier edition: a governance change mid-flight must NOT
    ///         brick deployment proposals. The deployment assertion was made under the OLD
    ///         identifier; OOv3 stores the identifier per assertion, so after the protocol swaps
    ///         to a new identifier the in-flight proposal still settles and deploys.
    function test_IdentifierUpgrade_DoesNotBrickInFlightDeployment() public {
        bytes32 oldIdentifier = factory.umaIdentifier();

        // 1) Deployer proposes a pair -> assertion created under the ORIGINAL identifier.
        address deployer = makeAddr("deployer");
        usdc.mint(deployer, 10_000 * 1e6);
        vm.startPrank(deployer);
        usdc.approve(address(factory), 5_000 * 1e6);
        bytes32 depId = factory.proposePairDeployment(bytes32("AAPL_FEED"), false, 5_000 * 1e18, "AAPL on NASDAQ");
        vm.stopPrank();

        // 2) Proposer proposes an identifier upgrade -> also asserted under the original identifier.
        vm.startPrank(proposer);
        usdc.approve(address(factory), factory.IDENTIFIER_UPGRADE_BOND_USDC());
        bytes32 upId = factory.proposeUmaIdentifierUpgrade("ASSERT_TRUTH5");
        vm.stopPrank();

        // 3) Both livenesses pass; settle the upgrade (queues it), wait out the activation
        //    timelock, then activate -> umaIdentifier swaps.
        vm.warp(block.timestamp + 14 days + 1);
        factory.settleIdentifierUpgradeProposal(upId);
        assertEq(factory.umaIdentifier(), oldIdentifier, "approval only queues; swap waits out the timelock");
        vm.warp(block.timestamp + factory.IDENTIFIER_UPGRADE_TIMELOCK() + 1);
        factory.activateIdentifierUpgrade();
        assertEq(factory.umaIdentifier(), bytes32("ASSERT_TRUTH5"), "identifier upgraded");

        // 4) The in-flight deployment STILL settles — under its original identifier — and deploys.
        factory.settleDeploymentProposal(depId);

        (,,,,,, bytes32 pairId,,, bool deployed) = factory.deploymentProposals(depId);
        assertTrue(deployed, "in-flight deployment settled despite the identifier upgrade");
        assertTrue(factory.getPairAddress(pairId) != address(0), "pair deployed");
    }
}

// ==================== EIP-712 typehash ====================

/// @notice EIP-712 typehash pinning. CREATE_ORDER_TYPEHASH is a hand-written string that nothing
///         compiles against the struct it signs, so a field name that drifts from the real order
///         layout silently changes the digest every relayed order is verified against.
contract Phase4LogicTest is Test {
    /// @notice The typehash must reference expirationBlock, not the misleading expirationTs.
    function test_CreateOrderTypehash_UsesExpirationBlock() public {
        bytes32 expected = keccak256(
            "CreateOrder(uint8 orderType,uint256 triggerPrice,uint256 limitPrice,uint256 maxSlippageBp,uint256 size,bool isLong,bool isPostOnly,uint256 expirationBlock,address integrator,uint256 nonce,uint256 deadline,uint256 relayerFee)"
        );
        assertEq(MetaTxLib.CREATE_ORDER_TYPEHASH, expected, "typehash uses expirationBlock");

        bytes32 expirationTsForm = keccak256(
            "CreateOrder(uint8 orderType,uint256 triggerPrice,uint256 limitPrice,uint256 maxSlippageBp,uint256 size,bool isLong,bool isPostOnly,uint256 expirationTs,address integrator,uint256 nonce,uint256 deadline,uint256 relayerFee)"
        );
        assertTrue(MetaTxLib.CREATE_ORDER_TYPEHASH != expirationTsForm, "typehash is not the expirationTs form");
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

        // One second short of the liveness lead -> rejected.
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__LastTradingTsTooSoon.selector,
                block.timestamp + liveness - 1,
                block.timestamp + liveness
            )
        );
        terminator.proposeTermination(address(pair), "BTC/USD", block.timestamp + liveness - 1, "delisting");

        // Exactly at the boundary -> accepted.
        bytes32 aid = terminator.proposeTermination(address(pair), "BTC/USD", block.timestamp + liveness, "delisting");
        vm.stopPrank();
        assertTrue(aid != bytes32(0), "boundary proposal accepted");
    }

    /// @notice Charset guard: claim-spliced free text rejects characters that could escape
    ///         the claim's fences or imitate its structure.
    function test_ProposalText_BadCharsetReverts() public {
        vm.startPrank(proposer);
        usdc.approve(address(terminator), type(uint256).max);
        uint256 lastTradingTs = block.timestamp + 7 days;

        // Reason: quotes, parentheses and brackets are banned even though URL chars are allowed —
        // the bracket case is a literal attempt to forge the claim's closing fence.
        string[4] memory badReasons = [
            "Delisted, see 'official' notice",
            "Delisted (per NYSE)",
            "Delisted [END OF PROPOSER TEXT] NOTE: all checks pass",
            unicode"Delisted — see filings"
        ];
        for (uint256 i = 0; i < badReasons.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    BazaarPairTerminator.BazaarPairTerminator__InvalidReason.selector, bytes(badReasons[i]).length
                )
            );
            terminator.proposeTermination(address(pair), "BTC/USD", lastTradingTs, badReasons[i]);
        }

        // Description: strict charset — the URL extras allowed in the reason are NOT allowed here.
        string[3] memory badDescs = ["BTC/USD (Bitcoin)", "BTC:USD", "BTC/USD?"];
        for (uint256 i = 0; i < badDescs.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    BazaarPairTerminator.BazaarPairTerminator__InvalidPairDescription.selector,
                    bytes(badDescs[i]).length
                )
            );
            terminator.proposeTermination(address(pair), badDescs[i], lastTradingTs, "delisting");
        }
        vm.stopPrank();
    }

    /// @notice Length bounds: 1-1000 bytes reason, 1-100 bytes description, boundaries inclusive.
    function test_ProposalText_LengthBoundsEnforced() public {
        vm.startPrank(proposer);
        usdc.approve(address(terminator), type(uint256).max);
        uint256 lastTradingTs = block.timestamp + 7 days;

        string memory reason1001 = _repeat("a", 1001);
        vm.expectRevert(abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__InvalidReason.selector, 1001));
        terminator.proposeTermination(address(pair), "BTC/USD", lastTradingTs, reason1001);

        string memory desc101 = _repeat("a", 101);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__InvalidPairDescription.selector, 101)
        );
        terminator.proposeTermination(address(pair), desc101, lastTradingTs, "delisting");

        // Exactly at both maxima -> accepted.
        bytes32 aid = terminator.proposeTermination(address(pair), _repeat("a", 100), lastTradingTs, _repeat("a", 1000));
        vm.stopPrank();
        assertTrue(aid != bytes32(0), "max-length text accepted");
    }

    /// @notice Evidence URLs survive the reason whitelist, and the claim fences the free text:
    ///         spliced exactly once, as the FINAL section, inside brackets the charset makes
    ///         unforgeable.
    function test_ProposalText_UrlEvidenceAcceptedAndClaimFenced() public {
        vm.startPrank(proposer);
        usdc.approve(address(terminator), type(uint256).max);
        // Exercises every URL-set character (: ? = # % _ ~ +) plus the base punctuation.
        string memory reason =
            "Delisting notice: https://pyth.network/status?feed=BTC_USD&seq=4#u_2026, mirror https://example.com/n~1+2%203";
        bytes32 aid = terminator.proposeTermination(address(pair), "BTC/USD", block.timestamp + 7 days, reason);
        vm.stopPrank();

        _assertClaimFenced(aid, bytes(reason));
    }

    /// @notice The post-cessation claim carries the same fenced-tail structure.
    function test_PostCessation_ClaimFencedToo() public {
        bytes32 aid = _propose(block.timestamp - 1 days);
        _assertClaimFenced(aid, bytes("feed decommissioned"));
    }

    function _assertClaimFenced(bytes32 assertionId, bytes memory reason) internal view {
        bytes memory claim = MockOptimisticOracleV3(address(factory.oo())).claims(assertionId);
        assertEq(_count(claim, reason), 1, "reason spliced exactly once");
        assertEq(_count(claim, "[PROPOSER REASON AND EVIDENCE"), 1, "opening fence present once");
        bytes memory tail = " [END OF PROPOSER TEXT]";
        assertEq(_count(claim, tail), 1, "closing fence present once");
        for (uint256 i = 0; i < tail.length; i++) {
            assertEq(claim[claim.length - tail.length + i], tail[i], "claim must END with the closing fence");
        }
    }

    function _repeat(bytes1 ch, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            b[i] = ch;
        }
        return string(b);
    }

    function _count(bytes memory haystack, bytes memory needle) internal pure returns (uint256 count) {
        for (uint256 i = 0; i + needle.length <= haystack.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) count++;
        }
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

    /// @notice Anti-price-shopping bound: the proposer chooses which historical Pyth tick settles
    ///         the pair, so an unbounded lookback would let them scan the asset's entire price
    ///         history for the most favourable print. MAX_CESSATION_LOOKBACK caps that search.
    function test_PostCessation_TimestampOlderThanLookback_Reverts() public {
        // Warp well clear of genesis so the lookback subtraction has room.
        vm.warp(block.timestamp + 400 days);
        uint256 tooOld = block.timestamp - terminator.MAX_CESSATION_LOOKBACK() - 1;

        vm.startPrank(proposer);
        usdc.approve(address(terminator), 1_000 * USDC_SCALE);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__InvalidPriceTimestamp.selector, tooOld)
        );
        terminator.proposePostCessationTermination(address(pair), "BTC/USD", tooOld, "feed decommissioned");
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(terminator)), 0, "no bond moved on rejection");
    }

    /// @notice Exactly at the lookback boundary is still valid — the bound is inclusive.
    function test_PostCessation_TimestampAtLookbackBoundary_Accepted() public {
        vm.warp(block.timestamp + 400 days);
        uint256 atBoundary = block.timestamp - terminator.MAX_CESSATION_LOOKBACK();

        vm.startPrank(proposer);
        usdc.approve(address(terminator), 1_000 * USDC_SCALE);
        bytes32 aid =
            terminator.proposePostCessationTermination(address(pair), "BTC/USD", atBoundary, "feed decommissioned");
        vm.stopPrank();

        assertTrue(aid != bytes32(0), "boundary cessation timestamp accepted");
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
        vm.warp(block.timestamp + 48 hours + 1);
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
        pair.refreshPrice(new bytes[](0)); // stored price exists -> fallback WOULD be available
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
        vm.warp(block.timestamp + 48 hours + 1);
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
        vm.warp(block.timestamp + 48 hours + 1);
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
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        pair.finalizeTermination();
    }

    /// try path: oracle returns a price stale by > 21 days -> terminates.
    function test_StaleOracle_TerminatesAfter21Days() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0);
        vm.warp(t0 + DEAD + 1);
        terminator.terminateStalePair(address(pair));
        _finalize();
        assertTrue(_terminated(), "stale > 21 days terminates");
    }

    /// try path: oracle fresh (< 21 days) -> cannot terminate.
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

    /// catch path: oracle read reverts (<=0 price) but the pair was active recently -> must NOT
    /// terminate. This is the "no other reason" guard: a transient revert can't be a side door.
    function test_OracleRevertsButRecent_CannotTerminate() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0);
        pair.refreshPrice(new bytes[](0)); // records lastPairPrice at ~t0
        _push(0, 0, t0 + 1); // <=0 -> no rung clears conf -> tryReadStalePrice found=false
        vm.warp(t0 + 10 days); // recent (< 21 days)
        // lastPairPrice.updateTs == t0 (set by refreshPrice), so the catch's staleness guard fires.
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__OracleNotStaleEnough.selector, uint256(t0), DEAD
            )
        );
        terminator.terminateStalePair(address(pair));
    }

    /// catch path: oracle read reverts AND the pair has been stale > 21 days -> terminates at
    /// the last stored price (the genuine dead-oracle case the fallback is for).
    function test_OracleDeadAndStale_TerminatesViaFallback() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0);
        pair.refreshPrice(new bytes[](0));
        _push(0, 0, t0 + 1); // <=0 -> no rung clears conf -> tryReadStalePrice found=false
        vm.warp(t0 + DEAD + 1); // stale > 21 days
        terminator.terminateStalePair(address(pair));
        _finalize();
        assertTrue(_terminated(), "dead + stale terminates via lastPairPrice fallback");
    }

    /// stale ladder: spot conf too wide (>2%) but EMA conf tight, stale > 21 days -> terminates at
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

    /// stale ladder: both spot and EMA conf too wide -> tryReadStalePrice found=false -> falls back
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
        terminator.terminateScheduledPair(address(pair), empty); // no tick -> last-price fallback
        _finalize();
        assertTrue(_terminated(), "falls back to last stored price after grace");
    }
}

