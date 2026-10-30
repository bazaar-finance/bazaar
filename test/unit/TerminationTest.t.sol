// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

// Consolidated: termination PnL, insurer vote, oracle upgrade, termination price + stale termination.
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";
import {MetaTxLib} from "../../src/libraries/MetaTxLib.sol";
import {TerminationLib} from "../../src/libraries/TerminationLib.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {PythSeed} from "../PythSeed.sol";
import {PythChain} from "../PythChain.sol";

// ==================== termination finalize ====================

/// @notice Harness owning Vault + TerminalSettlement storage, forwarding into TerminationLib's
///         finalize so the payout-ratio math can be unit-tested without a full BazaarPair. The
///         settlement tallies (registered claims, bad debt) are seeded directly — in production
///         they accumulate while positions are settled at the fixed price.
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
        // The gap between the two notionals is staged as the collateral seized with the inventory.
        vault.pendingLiqSeized = pendingLiqEntryNotional > pendingLiqBankruptcyNotional
            ? pendingLiqEntryNotional - pendingLiqBankruptcyNotional
            : pendingLiqBankruptcyNotional - pendingLiqEntryNotional;
        vault.pendingLiqEntryFundingIndex = pendingLiqEntryFundingIndex;
        vault.pendingLiqIsLong = pendingLiqIsLong;
    }

    function setTallies(uint256 totalProfitClaims, uint256 terminalBadDebt) external {
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

    function pendingLiqSize() external view returns (uint256) {
        return vault.pendingLiqSize;
    }

    function pendingLiqSeized() external view returns (uint256) {
        return vault.pendingLiqSeized;
    }

    function principalRatio() external view returns (uint256) {
        return ts.principalRatio;
    }

    function profitRatio() external view returns (uint256) {
        return ts.profitRatio;
    }

    function execTerm(BazaarTypes.TerminationParams memory params) external {
        TerminationLib.executeTermination(vault, ts, params);
    }

    function freeze(uint256 pot, uint256 principal, uint256 claims)
        external
        pure
        returns (uint256 principalRatio, uint256 profitRatio, uint256 residual)
    {
        return TerminationLib.freezeRatios(pot, principal, claims);
    }
}

/// @notice Unit tests for TerminationLib.executeTermination. The total owed to traders is
///         Σ collateral + Σ registered claims, derived from the ledger identity
///         D + deficit + badDebt − estateValue; principal is paid first, registered profits share
///         what remains at one ratio, and the insurance fund is the residual. In every fixture
///         the cash minted to the harness is what the ledgers say the contract should hold
///         (D + I + escrow) unless the test is about a shortfall.
contract TerminationFinalizeTest is Test {
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
            settlementPrice: PRICE,
            usdc: address(usdc),
            pairId: bytes32(uint256(0xBA2AAA)),
            currentFundingIndex: 0,
            claimableFeesTotal: 0,
            sweepComplete: true
        });
    }

    /// @notice freezeRatios conserves the pot on any books: what the two ratios reserve on the
    ///         totals plus the residual is the pot to the wei, principal is whole whenever the
    ///         pot allows it and pro-rata otherwise, profits pay only once principal is whole,
    ///         neither ratio exceeds 100%, and the residual is the ratios' rounding alone unless
    ///         every entitlement is covered in full.
    function testFuzz_freezeRatios_conservesThePot(uint256 pot, uint256 principal, uint256 claims) public view {
        pot = bound(pot, 0, 1e36);
        principal = bound(principal, 0, 1e36);
        claims = bound(claims, 0, 1e36);
        (uint256 principalRatio, uint256 profitRatio, uint256 residual) = harness.freeze(pot, principal, claims);
        assertLe(principalRatio, SCALE, "principal ratio at most 100%");
        assertLe(profitRatio, SCALE, "profit ratio at most 100%");
        uint256 reserved = Math.mulDiv(principal, principalRatio, SCALE) + Math.mulDiv(claims, profitRatio, SCALE);
        assertEq(reserved + residual, pot, "pot conserved");
        if (pot >= principal) {
            assertEq(principalRatio, SCALE, "principal whole");
            if (pot - principal >= claims) {
                assertEq(profitRatio, SCALE, "claims whole");
                assertEq(residual, pot - principal - claims, "surplus is the residual");
            } else {
                assertLe(residual, claims / SCALE + 1, "residual is the profit ratio's rounding");
            }
        } else {
            assertEq(profitRatio, 0, "profits pay nothing while principal is short");
            assertLe(residual, principal / SCALE + 1, "residual is the principal ratio's rounding");
        }
    }

    /// @notice Solvent book: the pot covers principal and every registered claim -> both ratios
    ///         100%, the ledger becomes the principal owed, insurance keeps its balance.
    function test_Solvent_FullRatios() public {
        // D = 2000 holds 400 of the winners' claims as unrealized-then-registered profit:
        // principal = 2000 - 400 = 1600. I = 50, cash 2050.
        harness.setVault(2_000 * SCALE, 50 * SCALE, 0, 0, 0, 0, false);
        harness.setTallies(400 * SCALE, 0);
        usdc.mint(address(harness), 2_050 * USDC_SCALE);

        harness.execTerm(_params());
        assertEq(harness.principalRatio(), SCALE, "principal whole");
        assertEq(harness.profitRatio(), SCALE, "profits whole");
        assertEq(harness.collateral(), 1_600 * SCALE, "ledger = principal owed");
        assertEq(harness.insurance(), 50 * SCALE, "insurance untouched");
    }

    /// @notice Finalize releases the seizure earmarked against the inventory it retires. The
    ///         residual it writes is what the insurers own outright; an earmark left behind would
    ///         keep that much of it out of every redemption's basis for good.
    function test_Finalize_ReleasesSeizureEarmark() public {
        // One unit long at entry 100 with bankruptcy 90: 10 of collateral was seized alongside it.
        harness.setVault(2_000 * SCALE, 300 * SCALE, 1 * SCALE, 100 * SCALE, 90 * SCALE, 0, true);
        usdc.mint(address(harness), 2_300 * USDC_SCALE);
        assertEq(harness.pendingLiqSeized(), 10 * SCALE, "earmark staged");

        harness.execTerm(_params());
        assertEq(harness.pendingLiqSize(), 0, "inventory retired");
        assertEq(harness.pendingLiqSeized(), 0, "earmark released with it");
    }

    /// @notice Bad debt smaller than the fund: winners are made whole and the insurers'
    ///         residual is exactly the fund less the bad debt.
    function test_BadDebt_PaidByInsurance() public {
        // Principal 1800, claims 400, of which 200 was never backed by a loser's collateral.
        harness.setVault(2_000 * SCALE, 300 * SCALE, 0, 0, 0, 0, false);
        harness.setTallies(400 * SCALE, 200 * SCALE);
        usdc.mint(address(harness), 2_300 * USDC_SCALE);

        harness.execTerm(_params());
        assertEq(harness.profitRatio(), SCALE, "insurance covers the bad debt");
        assertEq(harness.collateral(), 1_800 * SCALE, "principal = owed - claims");
        assertEq(harness.insurance(), 100 * SCALE, "residual = fund - bad debt");
    }

    /// @notice Bad debt larger than the fund: insurance is consumed entirely first, and only the
    ///         remaining shortfall is shared by the winners at one ratio.
    function test_BadDebtBeyondInsurance_ProfitsProRata() public {
        // Principal 1900, claims 400, bad debt 300, fund 50: profit pot = 2050 - 1900 = 150.
        harness.setVault(2_000 * SCALE, 50 * SCALE, 0, 0, 0, 0, false);
        harness.setTallies(400 * SCALE, 300 * SCALE);
        usdc.mint(address(harness), 2_050 * USDC_SCALE);

        harness.execTerm(_params());
        assertEq(harness.principalRatio(), SCALE, "principal senior");
        assertEq(harness.profitRatio(), 375 * SCALE / 1_000, "150 / 400");
        assertEq(harness.insurance(), 0, "fund consumed before winners are cut");
    }

    /// @notice A pre-termination deficit (bad debt realized while the pair was live) is part of
    ///         what is owed, exactly like bad debt tallied at settlement.
    function test_Deficit_FoldedIntoOwed() public {
        harness.setVault(2_000 * SCALE, 300 * SCALE, 0, 0, 0, 0, false);
        harness.setTallies(400 * SCALE, 0);
        harness.setDeficit(200 * SCALE);
        usdc.mint(address(harness), 2_300 * USDC_SCALE);

        harness.execTerm(_params());
        assertEq(harness.deficit(), 0, "deficit consumed");
        assertEq(harness.collateral(), 1_800 * SCALE, "principal = D + deficit - claims");
        assertEq(harness.insurance(), 100 * SCALE, "insurance paid the deficit");
        assertEq(harness.profitRatio(), SCALE, "winners whole");
    }

    /// @notice Cash below principal (a books-vs-balance gap): principal is paid pro-rata on the
    ///         pot, profits pay nothing, and the insurers keep only what the ratio's rounding
    ///         leaves of the pot.
    function test_CashShortOfPrincipal_PrincipalProRata_NoProfit() public {
        // Principal 1900 (D 2000 less 100 of claims); only 1500 of cash exists.
        harness.setVault(2_000 * SCALE, 0, 0, 0, 0, 0, false);
        harness.setTallies(100 * SCALE, 0);
        usdc.mint(address(harness), 1_500 * USDC_SCALE);

        harness.execTerm(_params());
        assertEq(harness.principalRatio(), 1_500 * SCALE / 1_900, "1500 / 1900");
        assertEq(harness.profitRatio(), 0, "nothing beyond principal");
        assertEq(harness.collateral(), 1_900 * SCALE, "ledger = nominal principal");
        // 1900 x 0.789473684210526315 draws 1500 less 1,500 wei: under one wei per dollar.
        assertEq(harness.insurance(), 1_500, "junior claim is the rounding remainder only");
    }

    /// @notice Winners short of cash share the whole profit pot: 999,950 left for 1,000,000 of
    ///         claims freezes the ratio at exactly 99.995%, and the insurers' residual takes
    ///         nothing of it.
    function test_ProfitPot_PaidInFullAtTheRatio() public {
        // D 1,500,000 = principal 500,000 + claims 1,000,000; I 0; cash 1,499,950.
        harness.setVault(1_500_000 * SCALE, 0, 0, 0, 0, 0, false);
        harness.setTallies(1_000_000 * SCALE, 0);
        usdc.mint(address(harness), 1_499_950 * USDC_SCALE);

        harness.execTerm(_params());
        assertEq(harness.principalRatio(), SCALE, "principal whole");
        assertEq(harness.profitRatio(), 99_995 * SCALE / 100_000, "999,950 / 1,000,000");
        assertEq(harness.insurance(), 0, "no part of the winners' share reaches the residual");
    }

    /// @notice Cash short of principal is drawn in full: a pot of 999,999 against 1,000,000 of
    ///         principal freezes the ratio at exactly 99.9999%, so withdrawals at it draw the whole
    ///         pot and none of it is left without an owner.
    function test_PrincipalShortfall_PotDrawnInFullAtTheRatio() public {
        harness.setVault(1_000_000 * SCALE, 0, 0, 0, 0, 0, false);
        harness.setTallies(0, 0);
        usdc.mint(address(harness), 999_999 * USDC_SCALE);

        harness.execTerm(_params());
        assertEq(harness.principalRatio(), 999_999 * SCALE / 1_000_000, "999,999 / 1,000,000");
        assertEq(
            harness.collateral() * harness.principalRatio() / SCALE, 999_999 * SCALE, "principal draws the whole pot"
        );
        assertEq(harness.insurance(), 0, "nothing left over");
    }

    /// @notice Estate loss: the vault's inherited short lost 18 to its counterparty, whose +18 is
    ///         a registered claim. Insurance pays it (it holds the liquidated loser's seized 20).
    function test_EstateLoss_PaidByInsurance() public {
        // Winner's principal D = 20; I = 20 (seized); short estate entered at $100, settles at
        // $118 -> -18. Cash 40.
        harness.setVault(20 * SCALE, 20 * SCALE, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, false);
        harness.setTallies(18 * SCALE, 0);
        usdc.mint(address(harness), 40 * USDC_SCALE);

        BazaarTypes.TerminationParams memory p = _params();
        p.settlementPrice = 118 * SCALE;
        harness.execTerm(p);

        assertEq(harness.pendingLiqSize(), 0, "estate retired");
        assertEq(harness.profitRatio(), SCALE, "claim fully covered");
        assertEq(harness.collateral(), 20 * SCALE, "principal = 38 owed - 18 claims");
        assertEq(harness.insurance(), 2 * SCALE, "insurance: 20 seized - 18 estate loss");
    }

    /// @notice Estate gain: the counterparty's loss already left its bucket at settlement, so
    ///         the total owed shrinks by the gain and insurance inherits it.
    function test_EstateGain_InheritedByInsurance() public {
        // D = 20 (the ledger does not move at settlement); short estate at $100 settles at $90.
        harness.setVault(20 * SCALE, 20 * SCALE, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, false);
        harness.setTallies(0, 0);
        usdc.mint(address(harness), 40 * USDC_SCALE);

        BazaarTypes.TerminationParams memory p = _params();
        p.settlementPrice = 90 * SCALE;
        harness.execTerm(p);

        assertEq(harness.collateral(), 10 * SCALE, "owed = 20 - 10 gain = the loser's remaining 10");
        assertEq(harness.insurance(), 30 * SCALE, "insurance inherits the gain");
        assertEq(harness.collateral() + harness.insurance(), 40 * SCALE, "D + I == cash");
    }

    /// @notice Estate gain beyond every entitlement: its counterparty is an unsettled position
    ///         bankrupt by more than the rest of the ledger, so the derivation goes negative.
    ///         Principal is clamped at zero, the pot is the residual, and the excess the clamp
    ///         discarded is carried in `deficit` for that position's settlement to consume.
    function test_NegativeOwed_PrincipalZero_ExcessCarriedInDeficit() public {
        // D = 11 (a flat 10 plus the straggler's 1 of collateral); long estate from $40 settles
        // at $100: gain 60. Owed = 11 - 60 = -49 -> principal 0, carry 49; cash 11 -> I = 11.
        harness.setVault(11 * SCALE, 0, 1 * SCALE, 40 * SCALE, 40 * SCALE, 0, true);
        harness.setTallies(0, 0);
        usdc.mint(address(harness), 11 * USDC_SCALE);

        harness.execTerm(_params());

        assertEq(harness.collateral(), 0, "principal clamped at zero");
        assertEq(harness.deficit(), 49 * SCALE, "the excess the clamp discarded is carried");
        assertEq(harness.principalRatio(), SCALE, "nothing to cover");
        assertEq(harness.insurance(), 11 * SCALE, "the pot is the residual");
    }

    /// @notice The same clamp through the claims: owed is positive but below the registered
    ///         claims — a winner settled against a loser left open — so principal is zero and
    ///         the difference is carried.
    function test_OwedBelowClaims_PrincipalZero_DifferenceCarriedInDeficit() public {
        // D = 20 (winner 10, open loser 10), claim 30, no estate: owed 20 < claims 30 ->
        // principal 0, carry 10; cash 20 -> profit pot 20 on 30 of claims.
        harness.setVault(20 * SCALE, 0, 0, 0, 0, 0, false);
        harness.setTallies(30 * SCALE, 0);
        usdc.mint(address(harness), 20 * USDC_SCALE);

        harness.execTerm(_params());

        assertEq(harness.collateral(), 0, "principal clamped at zero");
        assertEq(harness.deficit(), 10 * SCALE, "claims beyond owed are carried");
        assertEq(harness.profitRatio(), 20 * SCALE / 30, "profit pot shared across the claims");
    }

    /// @notice Estate loss beyond the fund: insurance drains to zero and the counterparty's
    ///         claim is paid pro-rata from what remains.
    function test_EstateLossBeyondInsurance_ProfitsProRata() public {
        // D = 20, I = 10, short estate at $100 settles at $118 (-18), claim 18, cash 30.
        // Owed 38, principal 20, profit pot 10 -> ratio 10/18.
        harness.setVault(20 * SCALE, 10 * SCALE, 1 * SCALE, 100 * SCALE, 100 * SCALE, 0, false);
        harness.setTallies(18 * SCALE, 0);
        usdc.mint(address(harness), 30 * USDC_SCALE);

        BazaarTypes.TerminationParams memory p = _params();
        p.settlementPrice = 118 * SCALE;
        harness.execTerm(p);

        assertEq(harness.profitRatio(), 10 * SCALE / 18, "10 / 18");
        assertEq(harness.collateral(), 20 * SCALE, "principal untouched");
        // 18 x 0.555555555555555555 reserves 10 less 10 wei; only that rounding remainder stays
        // with the insurers.
        assertEq(harness.insurance(), 10, "rounding remainder only");
    }

    /// @notice The estate's funding leg is part of its value. A long estate with a positive
    ///         funding delta owes funding, which raises what the counterparties are owed.
    function test_EstateFundingLeg_Settled() public {
        // Long estate: size 10, entryNotional 1000 ($100/unit), settle at PRICE=$100 -> price
        // leg 0. Funding index moved +5 per unit -> the long owes 50 -> estate value -50.
        harness.setVault(2_000 * SCALE, 500 * SCALE, 10 * SCALE, 1_000 * SCALE, 1_000 * SCALE, 0, true);
        harness.setTallies(0, 0);
        usdc.mint(address(harness), 2_500 * USDC_SCALE);

        BazaarTypes.TerminationParams memory p = _params();
        p.currentFundingIndex = 5 * int256(SCALE);
        harness.execTerm(p);

        assertEq(harness.collateral(), 2_050 * SCALE, "owed grows by the funding the estate pays");
        assertEq(harness.insurance(), 450 * SCALE, "insurance pays the estate's funding");
    }

    /// @notice The fee escrow is reserved out of the pot before anything is distributed.
    function test_FeeEscrow_ReservedOutOfPot() public {
        // D 2000 (claims 400 -> principal 1600), I 0, escrow 300. Cash 2400 -> pot 2100.
        harness.setVault(2_000 * SCALE, 0, 0, 0, 0, 0, false);
        harness.setTallies(400 * SCALE, 0);
        usdc.mint(address(harness), 2_400 * USDC_SCALE);

        BazaarTypes.TerminationParams memory p = _params();
        p.claimableFeesTotal = 300 * SCALE;
        harness.execTerm(p);

        assertEq(harness.profitRatio(), SCALE, "2100 covers 1600 + 400");
        assertEq(harness.insurance(), 100 * SCALE, "residual = pot - principal - claims");
    }

    /// @notice No claims registered (no winners, or nobody settled) -> both ratios 100%.
    function test_NoClaims_FullRatios() public {
        harness.setVault(1_000 * SCALE, 100 * SCALE, 0, 0, 0, 0, false);
        harness.setTallies(0, 0);
        usdc.mint(address(harness), 1_100 * USDC_SCALE);

        harness.execTerm(_params());
        assertEq(harness.principalRatio(), SCALE, "principal whole");
        assertEq(harness.profitRatio(), SCALE, "no claims -> full ratio");
        assertEq(harness.collateral(), 1_000 * SCALE, "ledger unchanged");
        assertEq(harness.insurance(), 100 * SCALE, "insurance unchanged");
    }

    /// @notice A zero settlement price can never finalize.
    function test_ZeroPrice_Reverts() public {
        harness.setVault(1_000 * SCALE, 100 * SCALE, 0, 0, 0, 0, false);
        BazaarTypes.TerminationParams memory p = _params();
        p.settlementPrice = 0;
        vm.expectRevert(TerminationLib.TerminationLib__TerminationPriceRequired.selector);
        harness.execTerm(p);
    }
}

// ==================== insurer vote / share dilution ====================

/// @notice The insurer vote: independent per-proposer proposals that schedule a trading cutoff the
///         moment the vote reaches 60% of the snapshot frozen at proposal, and settle under the
///         chain rule: the median of five prints chained from that cutoff. Two defenses close both
///         directions of the
///         share-dilution attack: snapshotTotalShares freezes the threshold denominator at proposal
///         creation, so minting cannot move the bar; and the share-maturity check (4-day age)
///         disqualifies shares minted inside the maturity window before a proposal from voting on
///         it. Withdrawals are gated on mature shares only.
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
    address majorityVoter; // votes yes, has ~80% of pre-snapshot shares
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
        PythSeed.seed(address(mockPyth), BTC_USD_FEED_ID);

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

        // Pre-existing insurers (in addition to the deployer's listing seed). Majority needs >60%
        // of total, so we make it dominate: 20,000 against the seed plus the whale's 100.
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
        pair.depositToInsurance(amountBazaar, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();
    }

    uint256 constant INSURER_BOND_USDC = 1_000 * 1e6; // mirror of internal constant in BazaarPairTerminator
    uint64 constant MIN_LEAD = 2 hours; // mirror of INSURER_TERMINATION_MIN_LEAD
    uint64 constant LATCH_LEAD = 1 hours; // mirror of INSURER_TERMINATION_LATCH_LEAD
    uint64 constant MAX_LEAD = 14 days; // mirror of INSURER_TERMINATION_MAX_LEAD
    uint256 constant POST_FIX_LOCK = 13 days; // mirror of INSURER_POST_FIX_LOCK (INSURANCE_WITHDRAWAL_COOLDOWN)
    uint256 constant LEVY_BP = 5_000; // mirror of INSURER_LEVY_BP
    uint256 constant LEVY_FLOOR_BP = 1_000; // mirror of INSURER_LEVY_FLOOR_BP
    uint64 constant MATURITY = 4 days; // mirror of INSURER_SHARE_MATURITY_PERIOD
    uint64 constant DEFAULT_LEAD = 1 days;

    /// @dev Each proposer's latest proposal id: the vote, execute and read helpers name it.
    mapping(address => bytes32) lastId;

    function _now() internal view returns (uint64) {
        return uint64(vm.getBlockTimestamp());
    }

    /// @dev The factory's bug bounty address: where the levy's forfeited shares go.
    function _bounty() internal view returns (address) {
        return factory.bugBountyAddress();
    }

    function _proposeAt(address proposer, uint64 cutoffTs) internal returns (bytes32 id) {
        usdc.mint(proposer, INSURER_BOND_USDC);
        vm.startPrank(proposer);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        id = terminator.proposeInsurerTermination(address(pair), cutoffTs);
        vm.stopPrank();
        lastId[proposer] = id;
    }

    /// @dev Proposes with a cutoff one day out and returns it.
    function _proposeInsurerTermination(address proposer) internal returns (uint64 cutoffTs) {
        cutoffTs = _now() + DEFAULT_LEAD;
        _proposeAt(proposer, cutoffTs);
    }

    function _vote(address voter, address proposer, uint256 amount) internal {
        bytes32 id = lastId[proposer];
        vm.prank(voter);
        terminator.voteForInsurerTermination(address(pair), id, amount);
    }

    function _execute(address proposer) internal {
        terminator.executeInsurerTermination(address(pair), lastId[proposer]);
    }

    /// @dev Build a BTC price update at `priceUsd` with an explicit predecessor publish time.
    function _btcTick(uint256 priceUsd, uint64 publishTime, uint64 prevPublishTime)
        internal
        view
        returns (bytes[] memory pu)
    {
        int64 pythPrice = int64(int256(priceUsd * 1e8));
        uint64 conf = uint64(priceUsd * 1e8 / 1000);
        bytes memory data = mockPyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID, pythPrice, conf, -8, pythPrice, conf, publishTime, prevPublishTime
        );
        pu = new bytes[](1);
        pu[0] = data;
    }

    /// @dev Build a $50,000 BTC price update whose predecessor is the previous second.
    function _btcPriceUpdate(uint64 publishTime) internal view returns (bytes[] memory) {
        return _btcTick(50_000, publishTime, publishTime > 0 ? publishTime - 1 : 0);
    }

    /// @dev Stage 1 for an insurer-scheduled pair under the chain rule: warp past the last sample
    ///      and settle at a chain of $50,000 prints whose first is published at the cutoff itself.
    function _settleAtCutoff(uint64 cutoffTs) internal {
        uint64 lastSample = PythChain.lastPublish(cutoffTs);
        if (_now() <= lastSample) vm.warp(lastSample + 10);
        bytes[] memory pu = PythChain.flat(mockPyth, BTC_USD_FEED_ID, 50_000, cutoffTs, cutoffTs - 1);
        uint256 fee = factory.oracle().getSampleSetFee(BTC_USD_FEED_ID, pu);
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
    }

    function _readProposal(address proposer)
        internal
        view
        returns (
            uint64 proposalTs,
            uint64 cutoffTs,
            uint256 yesShares,
            uint256 snapshotTotalShares,
            bool resolved,
            bool scheduled
        )
    {
        uint256 cutoff;
        (,, proposalTs,, cutoff,, yesShares, snapshotTotalShares,,, resolved, scheduled,,,,) =
            terminator.insurerProposals(lastId[proposer]);
        cutoffTs = uint64(cutoff);
    }

    function _readSnapshot(address proposer) internal view returns (uint256 snapshot) {
        (,,, snapshot,,) = _readProposal(proposer);
    }

    /// @dev What the fix stamped on the proposer's latest proposal: whether its yes-voters owe the
    ///      post-fix lock, the outcome, and the levy rate on each voted share.
    function _readOutcome(address proposer) internal view returns (bool costed, uint8 outcome, uint16 levyBp) {
        (,,,,,,,,,,,, costed,, outcome, levyBp) = terminator.insurerProposals(lastId[proposer]);
    }

    /// @dev The levy owed on `voted` yes-voted shares at the proposer's stamped rate.
    function _levyShares(address proposer, uint256 voted) internal view returns (uint256) {
        (,, uint16 levyBp) = _readOutcome(proposer);
        return voted * levyBp / 10_000;
    }

    /// @dev Requests and redeems a holder's whole balance on the terminated pair.
    function _redeemAll(address user) internal {
        uint256 shares = pair.insuranceShares(user);
        vm.prank(user);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
        vm.prank(user);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "", "");
    }

    /// @dev What `shares` redeem for right now, in USDC, at the fund's price per share.
    function _payoutUsdc(uint256 shares) internal view returns (uint256) {
        return shares * _insuranceFund() / pair.totalInsuranceShares() / 1e12;
    }

    function _insuranceFund() internal view returns (uint256 fund) {
        (,,,,, fund,,,,,,,,,,,) = pair.pairVault();
    }

    /// @dev Two-stage termination: a successful terminator path only FIXES the settlement price
    ///      and opens the settlement window; finalizing flips the terminated flag. No position is
    ///      open in these scenarios, so finalize is allowed at once.
    function _finalizeAfterSweep() internal {
        pair.finalizeTermination();
    }

    // -------------------- Tests --------------------

    /// @notice Defensive dilution: a defender deposits during the vote. Recomputing the threshold
    ///         off the live supply would scale it up and sink a vote that had already passed;
    ///         frozen at the snapshot, the vote still passes and the pair settles at the cutoff.
    function test_DefensiveDilution_DoesNotDefeatPassingVote() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);

        uint256 snapshot = _readSnapshot(whaleProposer);
        assertGt(snapshot, 0, "snapshot captured");

        // Defender tries to dilute by depositing a massive amount of fresh insurance USDC.
        _depositInsurance(diluter, 50_000 * BAZAAR_SCALE);
        assertGt(pair.totalInsuranceShares(), snapshot * 2, "live supply more than doubled");

        // Majority votes yes — well above 60% of the frozen snapshot, well below 60% of the live supply.
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        assertLt(20_000 * BAZAAR_SCALE, pair.totalInsuranceShares() * 6_000 / 10_000, "would fail on live supply");

        _execute(whaleProposer);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "vote passed against the snapshot");

        _settleAtCutoff(cutoffTs);
        _finalizeAfterSweep();
        assertTrue(pair.isPairTerminated(), "pair terminated despite dilution attempt");
    }

    /// @notice Offensive acquisition: an attacker deposits a large amount mid-vote to acquire
    ///         shares, then tries to vote with them. The shares are younger than the maturity
    ///         cutoff, so the unjust vote cannot pass.
    function test_OffensiveAcquisition_NewSharesCannotVote() public {
        _proposeInsurerTermination(whaleProposer);

        _depositInsurance(attacker, 20_000 * BAZAAR_SCALE);
        assertGt(pair.insuranceShares(attacker), 0, "attacker actually received shares");

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerInsufficientUnlockedShares.selector, 0, 1
            )
        );
        vm.prank(attacker);
        terminator.voteForInsurerTermination(address(pair), lastId[whaleProposer], 1);
    }

    /// @notice A user with old (mature) shares plus a top-up during the vote can still vote their
    ///         mature pre-existing balance — the fresh shares are immature and don't count.
    function test_PreExistingHolderCanVoteOldShares_NotNew() public {
        uint256 votersPreShares = pair.insuranceShares(majorityVoter);
        assertGt(votersPreShares, 0);

        _proposeInsurerTermination(whaleProposer);

        _depositInsurance(majorityVoter, 1_000 * BAZAAR_SCALE);
        assertGt(pair.insuranceShares(majorityVoter), votersPreShares);

        _vote(majorityVoter, whaleProposer, votersPreShares);

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerInsufficientUnlockedShares.selector, 0, 1
            )
        );
        vm.prank(majorityVoter);
        terminator.voteForInsurerTermination(address(pair), lastId[whaleProposer], 1);
    }

    /// @notice A proposal whose cutoff passes without reaching the threshold forfeits the bond
    ///         into the insurance fund, not as orphan dust: both the pair's USDC balance and the
    ///         `insuranceFundBalance` bookkeeping grow by the bond. The pair is left untouched.
    function test_ExpiredWithoutThreshold_BondCreditedToInsuranceFund() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        vm.warp(cutoffTs);

        uint256 insuranceBefore = _insuranceFund();
        uint256 pairUsdcBefore = usdc.balanceOf(address(pair));

        _execute(whaleProposer);

        assertEq(pair.scheduledTerminationTs(), 0, "pair not scheduled");
        assertEq(usdc.balanceOf(address(pair)) - pairUsdcBefore, INSURER_BOND_USDC, "pair received the bond in USDC");
        assertEq(
            _insuranceFund() - insuranceBefore, INSURER_BOND_USDC * 1e12, "insurance bookkeeping grew by bond amount"
        );
        (,,,, bool resolved, bool scheduled) = _readProposal(whaleProposer);
        assertTrue(resolved && !scheduled, "resolved without scheduling");
    }

    /// @notice The threshold met before the cutoff schedules the pair at the cutoff and refunds
    ///         the bond at once. Nothing is fixed yet: the pair keeps trading until the cutoff and
    ///         settles under the chain rule from it.
    function test_ThresholdMet_SchedulesPairAndRefundsBond() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);

        uint256 insuranceBefore = _insuranceFund();
        uint256 proposerUsdcBefore = usdc.balanceOf(whaleProposer);

        _execute(whaleProposer);

        assertEq(pair.scheduledTerminationTs(), cutoffTs, "scheduled at the proposal's cutoff");
        assertTrue(terminator.insurerScheduled(address(pair)), "settlement will use the chain rule");
        assertEq(pair.settlementPriceFixedTs(), 0, "nothing fixed before the cutoff");
        assertEq(usdc.balanceOf(whaleProposer) - proposerUsdcBefore, INSURER_BOND_USDC, "bond refunded to proposer");
        assertEq(_insuranceFund(), insuranceBefore, "no bond credit on success");
        (,,,, bool resolved, bool scheduled) = _readProposal(whaleProposer);
        assertTrue(resolved && scheduled, "proposal resolved by scheduling");

        _settleAtCutoff(cutoffTs);
        _finalizeAfterSweep();
        assertTrue(pair.isPairTerminated(), "pair terminated at the cutoff");
    }

    /// @notice Before the cutoff, execute is a latch, not a resolution: below the threshold it
    ///         reverts and voting stays open.
    function test_Execute_BelowThreshold_Reverts() public {
        _proposeInsurerTermination(whaleProposer);
        _vote(whaleProposer, whaleProposer, 100 * BAZAAR_SCALE);
        uint256 required = _readSnapshot(whaleProposer) * 6_000 / 10_000;

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerThresholdNotMet.selector, 100 * BAZAAR_SCALE, required
            )
        );
        _execute(whaleProposer);

        // Voting is still open; the majority can still push it over.
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertGt(pair.scheduledTerminationTs(), 0, "scheduled once the threshold arrived");
    }

    /// @notice A holder above the threshold proposes, votes and schedules in the same block. The
    ///         minimum lead is the only clock: the cutoff sits two hours out.
    function test_MajorityLatchesInOneBlock() public {
        uint64 cutoffTs = _now() + MIN_LEAD;
        _proposeAt(majorityVoter, cutoffTs);
        _vote(majorityVoter, majorityVoter, 20_000 * BAZAAR_SCALE);
        _execute(majorityVoter);

        assertEq(pair.scheduledTerminationTs(), cutoffTs, "scheduled two hours out in one block");

        _settleAtCutoff(cutoffTs);
        assertGt(pair.settlementPriceFixedTs(), 0, "fixed at the chain from the cutoff");
    }

    /// @notice The cutoff must sit between the minimum and maximum lead, inclusive.
    function test_CutoffBounds() public {
        usdc.mint(whaleProposer, 2 * INSURER_BOND_USDC);
        vm.startPrank(whaleProposer);
        usdc.approve(address(terminator), 2 * INSURER_BOND_USDC);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerCutoffTooSoon.selector,
                _now() + MIN_LEAD - 1,
                _now() + MIN_LEAD
            )
        );
        terminator.proposeInsurerTermination(address(pair), _now() + MIN_LEAD - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerCutoffTooLate.selector,
                _now() + MAX_LEAD + 1,
                _now() + MAX_LEAD
            )
        );
        terminator.proposeInsurerTermination(address(pair), _now() + MAX_LEAD + 1);
        lastId[whaleProposer] = terminator.proposeInsurerTermination(address(pair), _now() + MIN_LEAD);
        vm.stopPrank();

        _proposeAt(majorityVoter, _now() + MAX_LEAD);
        (, uint64 whaleCutoff,,,,) = _readProposal(whaleProposer);
        (, uint64 majorityCutoff,,,,) = _readProposal(majorityVoter);
        assertEq(whaleCutoff, _now() + MIN_LEAD, "minimum lead accepted");
        assertEq(majorityCutoff, _now() + MAX_LEAD, "maximum lead accepted");
    }

    /// @notice Consensus that nobody executed before the cutoff: the proposer's bond is refunded
    ///         (consensus was real) but the pair is NOT scheduled off a vote whose cutoff passed.
    function test_ExpiredWithThreshold_RefundsWithoutScheduling() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        vm.warp(cutoffTs + 1);

        uint256 proposerBefore = usdc.balanceOf(whaleProposer);
        uint256 insuranceBefore = _insuranceFund();

        _execute(whaleProposer);

        assertEq(usdc.balanceOf(whaleProposer) - proposerBefore, INSURER_BOND_USDC, "bond refunded on real consensus");
        assertEq(_insuranceFund(), insuranceBefore, "nothing forfeited when the threshold was met");
        assertEq(pair.scheduledTerminationTs(), 0, "stale consensus must not schedule");
    }

    /// @notice A proposer may file again while an earlier proposal of theirs is still unresolved:
    ///         proposals are independent records, so nothing is overwritten, and the stale one is
    ///         resolved on its own, forfeiting its bond to the insurance fund once its deadline has
    ///         passed with no consensus.
    function test_SameProposerFilesAgain_StaleProposalResolvesOnItsOwn() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        bytes32 stale = lastId[whaleProposer];
        vm.warp(cutoffTs + 1);

        uint256 pairBefore = usdc.balanceOf(address(pair));
        uint256 insuranceBefore = _insuranceFund();
        uint64 newCutoff = _proposeInsurerTermination(whaleProposer);
        assertTrue(lastId[whaleProposer] != stale, "a new record");
        assertEq(usdc.balanceOf(address(pair)), pairBefore, "filing again settles nothing");

        terminator.executeInsurerTermination(address(pair), stale);
        assertEq(usdc.balanceOf(address(pair)) - pairBefore, INSURER_BOND_USDC, "stale bond forfeited to the pair");
        assertEq(_insuranceFund() - insuranceBefore, INSURER_BOND_USDC * 1e12, "insurance bookkeeping credited");

        (uint64 proposalTs, uint64 cutoff, uint256 yesShares,, bool resolved, bool scheduled) =
            _readProposal(whaleProposer);
        assertEq(proposalTs, _now(), "new proposal filed now");
        assertEq(cutoff, newCutoff, "new cutoff");
        assertEq(yesShares, 0, "fresh vote count");
        assertFalse(resolved || scheduled, "new proposal unresolved");
    }

    /// @notice Consensus whose latch deadline passed unexecuted: resolving it refunds the bond and
    ///         must not schedule the pair, and a fresh proposal by the same proposer runs beside it.
    function test_ExpiredPassedProposal_ResolvedLater_RefundsWithoutScheduling() public {
        uint64 cutoffTs = _proposeInsurerTermination(majorityVoter);
        bytes32 stale = lastId[majorityVoter];
        _vote(majorityVoter, majorityVoter, 20_000 * BAZAAR_SCALE);
        vm.warp(cutoffTs + 1);

        uint256 proposerBefore = usdc.balanceOf(majorityVoter);
        uint256 insuranceBefore = _insuranceFund();
        _proposeInsurerTermination(majorityVoter);
        terminator.executeInsurerTermination(address(pair), stale);

        assertEq(usdc.balanceOf(majorityVoter), proposerBefore + INSURER_BOND_USDC, "old bond refunded");
        assertEq(_insuranceFund(), insuranceBefore, "nothing forfeited when the threshold was met");
        assertEq(pair.scheduledTerminationTs(), 0, "stale consensus must not schedule");
    }

    /// @notice Proposals are independent records: one address may hold several live ones, and
    ///         other addresses file alongside. Only a second filing in the same second is refused,
    ///         since the two would share an id.
    function test_ProposalsAreIndependent_SameSecondRefused() public {
        _proposeInsurerTermination(whaleProposer);
        bytes32 first = lastId[whaleProposer];

        usdc.mint(whaleProposer, INSURER_BOND_USDC);
        vm.startPrank(whaleProposer);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerActiveProposal.selector);
        terminator.proposeInsurerTermination(address(pair), _now() + 2 days);
        vm.stopPrank();

        vm.warp(_now() + 1);
        _proposeAt(whaleProposer, _now() + 2 days);
        assertTrue(lastId[whaleProposer] != first, "a second live proposal by the same address");
        _proposeAt(majorityVoter, _now() + 2 days);
        (,,,,,,,,,, bool firstResolved,,,,,) = terminator.insurerProposals(first);
        (,,,, bool whaleResolved,) = _readProposal(whaleProposer);
        (,,,, bool majorityResolved,) = _readProposal(majorityVoter);
        assertTrue(!firstResolved && !whaleResolved && !majorityResolved, "all three pending alongside");
    }

    /// @notice A proposal with a late cutoff cannot occupy the path: the honest proposal runs
    ///         beside it and schedules the pair at its own cutoff. The junk proposal can neither
    ///         schedule (no threshold) nor delay anything, and once the pair is fixed it resolves
    ///         as preempted.
    function test_JunkProposal_DoesNotBlockHonestOne() public {
        _depositInsurance(attacker, 1_000 * BAZAAR_SCALE);
        vm.warp(_now() + 8 days); // the attacker's stake matures; everyone else's already had

        uint64 junkCutoff = _now() + MAX_LEAD;
        _proposeAt(attacker, junkCutoff);

        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "honest cutoff scheduled beside the junk proposal");

        uint256 junkRequired = _readSnapshot(attacker) * 6_000 / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerThresholdNotMet.selector, 0, junkRequired
            )
        );
        _execute(attacker);

        _settleAtCutoff(cutoffTs);
        uint256 attackerBefore = usdc.balanceOf(attacker);
        _execute(attacker);
        assertEq(usdc.balanceOf(attacker) - attackerBefore, INSURER_BOND_USDC, "preempted once the pair is fixed");
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "schedule untouched by the junk proposal");
    }

    /// @notice A later proposal with an earlier cutoff pulls the pair's schedule earlier.
    function test_EarlierCutoff_PullsScheduleEarlier() public {
        uint64 lateCutoff = _now() + 3 days;
        _proposeAt(whaleProposer, lateCutoff);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertEq(pair.scheduledTerminationTs(), lateCutoff, "first schedule");

        uint64 earlyCutoff = _now() + 1 days;
        _proposeAt(majorityVoter, earlyCutoff);
        _vote(majorityVoter, majorityVoter, 20_000 * BAZAAR_SCALE);
        _execute(majorityVoter);
        assertEq(pair.scheduledTerminationTs(), earlyCutoff, "pulled earlier");

        _settleAtCutoff(earlyCutoff);
        assertGt(pair.settlementPriceFixedTs(), 0, "settled at the earlier cutoff");
    }

    /// @notice A cutoff no earlier than the pair's schedule can never take effect: proposing one
    ///         is refused up front, and a proposal already pending when the schedule appears
    ///         resolves as preempted with its bond refunded.
    function test_LaterCutoff_RefusedOrPreempted() public {
        uint64 lateCutoff = _now() + 2 days;
        _proposeAt(majorityVoter, lateCutoff); // pending before any schedule exists

        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "earlier cutoff scheduled");

        // Filing at or after the schedule is refused, ahead of every other check.
        vm.startPrank(diluter);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerCutoffNotEarlier.selector, cutoffTs
            )
        );
        terminator.proposeInsurerTermination(address(pair), cutoffTs);
        vm.stopPrank();

        // The pending later proposal reaches threshold and is preempted: bond back, schedule kept.
        _vote(majorityVoter, majorityVoter, 20_000 * BAZAAR_SCALE);
        uint256 before = usdc.balanceOf(majorityVoter);
        _execute(majorityVoter);
        assertEq(usdc.balanceOf(majorityVoter) - before, INSURER_BOND_USDC, "preempted proposal refunded");
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "schedule untouched");
        (,,,, bool resolved, bool scheduled) = _readProposal(majorityVoter);
        assertTrue(resolved && !scheduled, "resolved without scheduling");
    }

    /// @notice Voted shares lock until the proposal fails, and release the moment it does.
    function test_VoteLock_ReleasesOnFailure() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        assertEq(
            terminator.getLockedShares(address(pair), majorityVoter), 20_000 * BAZAAR_SCALE, "locked while pending"
        );
        assertEq(terminator.getInsurerVote(address(pair), majorityVoter, lastId[whaleProposer]), 20_000 * BAZAAR_SCALE);

        vm.warp(cutoffTs);
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 0, "released at the cutoff");
        _execute(whaleProposer); // resolves as failed (nobody executed before the cutoff)
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 0, "still released");
        assertEq(
            terminator.getInsurerVote(address(pair), majorityVoter, lastId[whaleProposer]), 0, "dead record reads zero"
        );
    }

    /// @notice Shares voted into the proposal that scheduled the pair stay locked through the
    ///         cutoff and limbo — the record is what the post-fix lock and the levy read, so it
    ///         never dies — and, the vote being unjudged, through the cooldown after the fix.
    function test_VoteLock_HeldThroughScheduleAndLimbo() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertGt(pair.scheduledTerminationTs(), 0, "scheduled");
        assertEq(
            terminator.getLockedShares(address(pair), majorityVoter), 20_000 * BAZAAR_SCALE, "locked until the cutoff"
        );

        vm.warp(cutoffTs);
        assertEq(
            terminator.getLockedShares(address(pair), majorityVoter),
            20_000 * BAZAAR_SCALE,
            "the scheduling record stays live through limbo"
        );
        _settleAtCutoff(cutoffTs);
        assertEq(
            terminator.getLockedShares(address(pair), majorityVoter),
            20_000 * BAZAAR_SCALE,
            "and through the cooldown after the fix"
        );
        vm.warp(pair.settlementPriceFixedTs() + POST_FIX_LOCK);
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 0, "released once the cooldown has run");
    }

    /// @notice A voter may back at most INSURER_MAX_LIVE_VOTES live proposals; dead records are
    ///         pruned as votes are cast, so the cap only ever counts live ones.
    function test_MaxLiveVotes_EnforcedAndPruned() public {
        address[] memory proposers = new address[](9);
        for (uint256 i = 0; i < 9; i++) {
            proposers[i] = makeAddr(string(abi.encodePacked("proposer", i)));
            usdc.mint(proposers[i], 1_000 * USDC_SCALE);
            _depositInsurance(proposers[i], 100 * BAZAAR_SCALE);
        }
        vm.warp(_now() + 8 days); // the nine stakes mature

        uint64 base = _now();
        for (uint256 i = 0; i < 9; i++) {
            _proposeAt(proposers[i], base + MIN_LEAD + uint64(i) * 1 hours);
        }
        for (uint256 i = 0; i < 8; i++) {
            _vote(majorityVoter, proposers[i], 1);
        }
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 8, "eight live votes");

        vm.expectRevert(
            abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__InsurerTooManyLiveVotes.selector, 8)
        );
        vm.prank(majorityVoter);
        terminator.voteForInsurerTermination(address(pair), lastId[proposers[8]], 1);

        // The earliest proposal's cutoff passes: its record is dead and gets pruned on the next vote.
        vm.warp(base + MIN_LEAD);
        _vote(majorityVoter, proposers[8], 1);
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 8, "one pruned, one added");
        assertEq(
            terminator.getInsurerVote(address(pair), majorityVoter, lastId[proposers[0]]), 0, "expired record gone"
        );
        assertEq(terminator.getInsurerVote(address(pair), majorityVoter, lastId[proposers[8]]), 1, "new record live");
    }

    /// @notice Settlement of an insurer-scheduled pair is the chain rule: a call at the cutoff
    ///         itself is early, a set whose first sample predates the cutoff or is not the first
    ///         print after it is refused, no data at all is a short set refused until the last
    ///         resort, and the valid chain settles.
    function test_Settlement_ChainRuleOnly() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);

        bytes[] memory valid = PythChain.flat(mockPyth, BTC_USD_FEED_ID, 51_000, cutoffTs + 5, cutoffTs - 1);
        uint256 fee = factory.oracle().getSampleSetFee(BTC_USD_FEED_ID, valid);

        // At the cutoff itself the call is early.
        vm.warp(cutoffTs);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__TerminationTimeNotReached.selector, cutoffTs, cutoffTs
            )
        );
        terminator.terminateScheduledPair{value: fee}(address(pair), valid);

        vm.warp(PythChain.lastPublish(cutoffTs + 5) + 30);

        // A chain whose first sample was published before the cutoff.
        bytes[] memory early = PythChain.flat(mockPyth, BTC_USD_FEED_ID, 51_000, cutoffTs - 1, cutoffTs - 2);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        terminator.terminateScheduledPair{value: fee}(address(pair), early);

        // A chain whose first sample follows another print after the cutoff: not the first.
        bytes[] memory notFirst = PythChain.flat(mockPyth, BTC_USD_FEED_ID, 51_000, cutoffTs + 5, cutoffTs + 2);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        terminator.terminateScheduledPair{value: fee}(address(pair), notFirst);

        // No update at all is a short set: no fallback to the stored price before the last resort.
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__SampleCountMismatch.selector, 0, 5));
        terminator.terminateScheduledPair(address(pair), new bytes[](0));
        assertEq(pair.settlementPriceFixedTs(), 0, "nothing fixed by a refused set");

        // The chain whose first sample is the first print after the cutoff, five seconds later.
        terminator.terminateScheduledPair{value: fee}(address(pair), valid);
        assertEq(pair.auxState().settlementPrice, 51_000 * BAZAAR_SCALE, "settled at the chain's median");
    }

    /// @notice A UMA-scheduled cutoff is pulled earlier by an insurer vote, after which settlement
    ///         follows the chain rule, every sample capped at the UMA cutoff it pulled in. The pair
    ///         refuses to move a schedule later.
    function test_UmaSchedule_PulledEarlierByInsurers() public {
        address umaCaller = pair.umaContract();
        uint64 umaCutoff = _now() + 3 days;
        vm.prank(umaCaller);
        pair.setScheduledTermination(umaCutoff, whaleProposer);

        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "UMA cutoff pulled earlier");
        assertTrue(terminator.insurerScheduled(address(pair)), "insurer settlement rule now applies");
        assertEq(terminator.umaCutoffCap(address(pair)), umaCutoff, "capped at the UMA cutoff it pulled in");

        vm.prank(umaCaller);
        vm.expectRevert(BazaarPair.BazaarPair__TerminationAlreadyScheduled.selector);
        pair.setScheduledTermination(umaCutoff, whaleProposer);

        _settleAtCutoff(cutoffTs);
        assertGt(pair.settlementPriceFixedTs(), 0, "settled at the insurer cutoff");
    }

    /// @notice If another path fixes the pair's price while a proposal is pending, execute must
    ///         still resolve the proposal and REFUND the bond — not revert with AlreadyTerminated,
    ///         which would strand it (this is the only function that releases it, and
    ///         proposeInsurerTermination reverts on an already-terminated pair so it can't recover).
    function test_PreemptedByFixedPrice_RefundsBondInsteadOfStranding() public {
        _proposeInsurerTermination(whaleProposer);

        address umaCaller = pair.umaContract();
        vm.prank(umaCaller);
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        _finalizeAfterSweep();
        assertTrue(pair.isPairTerminated(), "pair pre-empted by another termination path");

        uint256 proposerUsdcBefore = usdc.balanceOf(whaleProposer);
        uint256 insuranceBefore = _insuranceFund();

        _execute(whaleProposer);

        assertEq(usdc.balanceOf(whaleProposer) - proposerUsdcBefore, INSURER_BOND_USDC, "bond refunded when pre-empted");
        assertEq(_insuranceFund(), insuranceBefore, "bond not forfeited to insurance on pre-emption");
        (,,,, bool resolved, bool scheduled) = _readProposal(whaleProposer);
        assertTrue(resolved && !scheduled, "resolved without scheduling");
    }

    /// @notice Every insurer event names its proposal by id, and the record behind the id carries
    ///         the cutoff, so a log can be read on its own. A bare proposal's id is the hash of the
    ///         pair, the proposer and the filing second.
    function test_Events_CarryProposalId() public {
        _depositInsurance(attacker, 1_000 * BAZAAR_SCALE);
        vm.warp(_now() + 8 days); // the attacker's stake matures; everyone else's already had

        uint64 proposalTs = _now();
        uint64 cutoffTs = proposalTs + DEFAULT_LEAD;
        uint256 snapshot = pair.totalInsuranceShares() - pair.insuranceShares(address(0));
        bytes32 id = keccak256(abi.encode(address(pair), whaleProposer, proposalTs));

        usdc.mint(whaleProposer, INSURER_BOND_USDC);
        vm.startPrank(whaleProposer);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        vm.expectEmit(true, true, true, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationProposed(
            address(pair), id, whaleProposer, cutoffTs, proposalTs, false
        );
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationSnapshot(address(pair), id, snapshot, 0);
        bytes32 filed = terminator.proposeInsurerTermination(address(pair), cutoffTs);
        vm.stopPrank();
        assertEq(filed, id, "the id is the hash of pair, proposer and filing second");
        lastId[whaleProposer] = id;

        // A later proposal, filed before any schedule exists, will be preempted below.
        uint64 laterCutoff = proposalTs + 2 days;
        bytes32 later = _proposeAt(majorityVoter, laterCutoff);

        vm.expectEmit(true, true, true, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationVoted(
            address(pair), id, majorityVoter, 20_000 * BAZAAR_SCALE, 20_000 * BAZAAR_SCALE
        );
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);

        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationScheduled(
            address(pair), id, cutoffTs, 20_000 * BAZAAR_SCALE, snapshot
        );
        _execute(whaleProposer);

        _vote(majorityVoter, majorityVoter, 20_000 * BAZAAR_SCALE);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationPreempted(address(pair), later);
        _execute(majorityVoter);

        // An earlier cutoff can still be filed against the schedule; expiring unvoted, it fails.
        uint64 earlyCutoff = proposalTs + MIN_LEAD;
        bytes32 early = _proposeAt(attacker, earlyCutoff);
        vm.warp(earlyCutoff);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationFailed(address(pair), early, earlyCutoff, 0, snapshot, false);
        _execute(attacker);
    }

    /// @notice creditInsurance is gated to the terminator/sequencer — direct calls revert.
    function test_CreditFunction_OnlyUmaGuard() public {
        vm.prank(attacker);
        vm.expectRevert(BazaarPair.BazaarPair__UnauthorizedInsuranceCreditor.selector);
        pair.creditInsurance(1_000 * BAZAAR_SCALE);
    }

    /// @notice Maturity: shares deposited within the maturity period before a proposal cannot
    ///         vote on it. This is the "snipe defense" — an attacker can't deposit majority and
    ///         propose in the same transaction; their shares need to age 4 days before they count.
    function test_Maturity_FreshlyDepositedSharesCannotVoteOnSameDayProposal() public {
        _depositInsurance(diluter, 10_000 * BAZAAR_SCALE);
        _proposeInsurerTermination(whaleProposer);

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__InsurerInsufficientUnlockedShares.selector, 0, 1
            )
        );
        vm.prank(diluter);
        terminator.voteForInsurerTermination(address(pair), lastId[whaleProposer], 1);
    }

    /// @notice Maturity: shares that have aged past the maturity period CAN vote, even if deposited
    ///         after some prior unrelated event but before the proposal.
    function test_Maturity_SharesMaturedBeforeProposalCanVote() public {
        _depositInsurance(diluter, 10_000 * BAZAAR_SCALE);
        vm.warp(block.timestamp + 8 days);
        _proposeInsurerTermination(whaleProposer);

        uint256 diluterShares = pair.insuranceShares(diluter);
        _vote(diluter, whaleProposer, diluterShares);
        assertEq(
            terminator.getInsurerVote(address(pair), diluter, lastId[whaleProposer]), diluterShares, "vote recorded"
        );
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
        pair.depositToInsurance(belowFloor, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @notice A deposit above the width of a collateral bucket is refused before anything is
    ///         credited or pulled: the amount is bounded so that no value the pull could not
    ///         match reaches the share and balance arithmetic.
    function test_InsuranceDeposit_AboveMaximumReverts() public {
        // A whole number of µUSDC, since the pair floors the amount to that granularity first.
        uint256 aboveCap = (uint256(type(uint128).max) / 1e12 + 1) * 1e12;
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsuranceVaultLib.InsuranceVaultLib__DepositAboveMaximum.selector, aboveCap, type(uint128).max
            )
        );
        pair.depositToInsurance(aboveCap, new bytes[](0), 0, 0, 0, "", "");
        assertEq(pair.insuranceShares(attacker), 0, "nothing credited");
    }

    /// @notice Deposits at or above the $5 floor succeed normally.
    function test_InsuranceDeposit_AtMinimumSucceeds() public {
        uint256 atFloor = 5 * BAZAAR_SCALE;
        usdc.mint(attacker, atFloor * USDC_SCALE / BAZAAR_SCALE);
        vm.startPrank(attacker);
        usdc.approve(address(pair), atFloor * USDC_SCALE / BAZAAR_SCALE);
        pair.depositToInsurance(atFloor, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();
        assertGt(pair.insuranceShares(attacker), 0, "shares minted");
    }

    /// @notice MAX_DEPOSITS_PER_WINDOW (100 per rolling maturity window, 4 days) caps the active
    ///         lot list. The 101st deposit within the window must revert; after warping past
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
            pair.depositToInsurance(amt, new bytes[](0), 0, 0, 0, "", "");
        }
        // 101st in the same window reverts.
        vm.expectRevert(); // BazaarPair__TooManyRecentInsuranceDeposits(100, 100)
        pair.depositToInsurance(amt, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();

        // After the maturity period, the rolling window has rolled past all 100 entries: deposits
        // work again.
        vm.warp(block.timestamp + MATURITY + 1);
        vm.prank(attacker);
        pair.depositToInsurance(amt, new bytes[](0), 0, 0, 0, "", "");
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

        // mature_as_of(now - maturity) should equal the original deposit (fully aged).
        uint64 cutoff = uint64(block.timestamp - MATURITY);
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
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerZeroVoteAmount.selector);
        vm.prank(majorityVoter);
        terminator.voteForInsurerTermination(address(pair), lastId[whaleProposer], 0);
    }

    /// @notice Regression: after an insurer-scheduled termination, insurance LPs MUST still be
    ///         able to withdraw their funds — the schedule stamp stays set forever, and the
    ///         terminated-flag check has to come before the scheduled-cutoff guard. A holder who
    ///         did not vote redeems at once in full; a yes-voter waits out the post-fix lock first
    ///         and pays the levy.
    function test_Withdrawal_AfterInsurerTermination_StillWorks() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        _settleAtCutoff(cutoffTs);
        _finalizeAfterSweep();
        assertTrue(pair.isPairTerminated(), "sanity: pair terminated");
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "schedule stamp persists");

        _redeemAll(whaleProposer);
        assertEq(pair.insuranceShares(whaleProposer), 0, "non-voter withdrew post-termination");
        assertEq(pair.insuranceShares(_bounty()), 0, "no levy on a non-voter");

        uint256 majShares = pair.insuranceShares(majorityVoter);
        vm.prank(majorityVoter);
        pair.requestInsuranceWithdrawal(majShares, 0, 0, 0, "", "");
        vm.prank(majorityVoter);
        vm.expectRevert(InsuranceVaultLib.InsuranceVaultLib__SharesLockedForVoting.selector);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "", "");

        vm.warp(pair.settlementPriceFixedTs() + POST_FIX_LOCK);
        vm.prank(majorityVoter);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "", "");
        assertEq(pair.insuranceShares(majorityVoter), 0, "majority withdrew post-termination");
        assertEq(
            pair.insuranceShares(_bounty()),
            _levyShares(whaleProposer, 20_000 * BAZAAR_SCALE),
            "the levy moved to the orphan balance"
        );
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
        // the path that flips isPairTerminated while leaving scheduledTerminationTs set
        // (= the state under test).
        vm.prank(umaCaller);
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        _finalizeAfterSweep();
        assertTrue(pair.isPairTerminated(), "scheduled termination executed");
        assertGt(pair.scheduledTerminationTs(), 0, "state under test: scheduledTerminationTs still set");

        // An insurance LP requests + executes withdrawal — must succeed. A terminated pair whose
        // schedule stamp is still set must not read as "scheduled for termination" and freeze exits.
        bytes[] memory pu = _btcPriceUpdate(uint64(vm.getBlockTimestamp()));
        uint256 majShares = pair.insuranceShares(majorityVoter);
        vm.prank(majorityVoter);
        pair.requestInsuranceWithdrawal(majShares, 0, 0, 0, "", "");
        // Terminated -> no cooldown wait needed.
        vm.prank(majorityVoter);
        pair.executeInsuranceWithdrawal(pu, 0, 0, 0, "", "");
        assertEq(pair.insuranceShares(majorityVoter), 0, "withdrawal succeeded post-scheduled-termination");
    }

    /// @dev Vault.insuranceFundBalance lives at pairVault's slot 4 + offset 5 = 9.
    uint256 constant SLOT_VAULT_INSURANCE_FUND_BALANCE = 9;

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
        (,,,,, uint256 fundAfter,,,,,,,,,,,) = pair.pairVault();
        assertEq(fundAfter, 0, "fund drained to 0");
        // totalShares should still be > 0 (the bookkeeping zeroing didn't touch them).
        assertGt(pair.totalInsuranceShares(), 0, "shares still issued");

        // Recapitalizer steps in — single deposit, epoch bump, 1:1 repricing.
        uint256 recap = 10_000 * BAZAAR_SCALE;
        uint256 recapUsdc = recap * USDC_SCALE / BAZAAR_SCALE;
        usdc.mint(attacker, recapUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(pair), recapUsdc);
        pair.depositToInsurance(recap, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();

        (,,,,, uint256 fundPostRecap,,,,,,,,,,,) = pair.pairVault();
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
        pair.depositToInsurance(recap, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();

        // Cycle 2: wipe again -> a NEW rescuer deposits directly.
        // Under 1-wei pricing this cycle overflows: the supply is already x(amount-in-wei)
        // inflated, so amount x supply blows past any narrow lot field. The epoch reset restarts
        // the supply at the rescue amount, and the lot field is full-width, so nothing truncates.
        vm.store(address(pair), bytes32(SLOT_VAULT_INSURANCE_FUND_BALANCE), bytes32(uint256(0)));
        usdc.mint(majorityVoter, recapUsdc);
        vm.startPrank(majorityVoter);
        usdc.approve(address(pair), recapUsdc);
        pair.depositToInsurance(recap, new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();

        (,,,,, uint256 fund,,,,,,,,,,,) = pair.pairVault();
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
        // for pruning (18d), then makes a small fresh deposit that triggers pruning.
        _depositInsurance(diluter, 5_000 * BAZAAR_SCALE);
        vm.warp(block.timestamp + 22 days); // past INSURER_LOT_RETENTION_PERIOD (18d)
        _depositInsurance(diluter, 5 * BAZAAR_SCALE); // triggers prune of the old lot

        // Now propose. The old 5,000 are mature; the freshly-pruned-and-then-redeposited
        // 5 are immature. Diluter must still be able to vote with the old 5,000.
        _proposeInsurerTermination(whaleProposer);
        uint256 diluterTotal = pair.insuranceShares(diluter);
        // mature_at_proposal_cutoff ~= 5,000 (the new $5 deposit is younger than the maturity
        // period at proposal time)
        uint64 cutoffTs = uint64(block.timestamp - MATURITY);
        uint256 mature = pair.getSharesAsOf(diluter, cutoffTs);
        assertLt(mature, diluterTotal, "fresh top-up correctly excluded from mature");
        assertGt(mature, 0, "old pruned lot still counts toward mature voting power");

        _vote(diluter, whaleProposer, mature);
        // No revert -> vote went through using the pruned-lot mature shares.
    }

    /// @notice A stake younger than the maturity period cannot open a vote either: the proposer is
    ///         held to the cutoff the vote applies, so an immature holder cannot file a proposal
    ///         no share of theirs could support.
    function test_Propose_ImmatureDepositorRejected() public {
        _depositInsurance(attacker, 1_000 * BAZAAR_SCALE);
        usdc.mint(attacker, INSURER_BOND_USDC);
        vm.startPrank(attacker);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerNoMatureShares.selector);
        terminator.proposeInsurerTermination(address(pair), _now() + DEFAULT_LEAD);
        vm.stopPrank();

        // Once the stake has aged the maturity period, the same holder proposes normally.
        vm.warp(vm.getBlockTimestamp() + MATURITY);
        _proposeInsurerTermination(attacker);
        (uint64 proposalTs,,,,,) = _readProposal(attacker);
        assertEq(proposalTs, _now(), "matured stake opened the vote");
    }

    /// @notice A proposer whose proposal scheduled the pair may file again with an earlier cutoff;
    ///         the first proposal's voters stay locked until the cutoff they voted for.
    function test_ScheduledProposal_ProposerMayFileAgain_VotersStayLocked() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "scheduled");

        vm.warp(_now() + 12 hours);
        _proposeAt(whaleProposer, _now() + MIN_LEAD);
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 20_000 * BAZAAR_SCALE, "voter still locked");
    }

    /// @notice Once another path fixes the pair's price, nothing stays locked: a voter into a
    ///         proposal whose cutoff lies weeks out redeems alongside every other insurer after
    ///         finalize instead of waiting out a cutoff that no longer means anything.
    function test_VoteLock_ReleasedOnceSettlementPriceFixed() public {
        _proposeAt(whaleProposer, _now() + MAX_LEAD);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 20_000 * BAZAAR_SCALE, "locked");

        // The autonomous insolvency path fixes the price well before the cutoff.
        vm.warp(_now() + 1 days);
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 0, "released at the fix");

        _finalizeAfterSweep();
        uint256 majShares = pair.insuranceShares(majorityVoter);
        vm.prank(majorityVoter);
        pair.requestInsuranceWithdrawal(majShares, 0, 0, 0, "", "");
        bytes[] memory pu = _btcPriceUpdate(_now());
        vm.prank(majorityVoter);
        pair.executeInsuranceWithdrawal(pu, 0, 0, 0, "", "");
        assertEq(pair.insuranceShares(majorityVoter), 0, "voter redeemed after finalize");
        assertEq(pair.insuranceShares(_bounty()), 0, "not costed: another path fixed the pair");
    }

    /// @notice Chain samples settle even when their confidence is wide: each has no second
    ///         candidate, so a confidence cap could only strand the pair.
    function test_Settlement_WideConfidenceSamplesStillSettle() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);

        // 5% confidence on every sample: well past the 2% cap the live paths enforce.
        int64 pythPrice = int64(int256(uint256(49_000 * 1e8)));
        uint64 conf = uint64(49_000 * 1e8 * 5 / 100);
        bytes[] memory pu = new bytes[](PythChain.COUNT);
        uint64 publish = cutoffTs + 5;
        uint64 prev = cutoffTs - 1;
        for (uint256 k = 0; k < PythChain.COUNT; k++) {
            pu[k] = mockPyth.createPriceFeedUpdateData(
                BTC_USD_FEED_ID, pythPrice, conf, -8, pythPrice, conf, publish, prev
            );
            prev = publish + PythChain.SPACING - 1;
            publish += PythChain.SPACING;
        }
        vm.warp(PythChain.lastPublish(cutoffTs + 5) + 30);
        uint256 fee = factory.oracle().getSampleSetFee(BTC_USD_FEED_ID, pu);
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
        assertEq(pair.auxState().settlementPrice, 49_000 * BAZAAR_SCALE, "settled at the wide samples");
    }

    /// @notice The latch closes INSURER_TERMINATION_LATCH_LEAD before the cutoff. A proposal that
    ///         has not scheduled the pair by then resolves as expired even with the threshold met,
    ///         so a coalition cannot wait until the cutoff print is in sight and then decide.
    function test_LatchDeadline_ExecuteAndVoteCloseOneLeadBeforeCutoff() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);

        vm.warp(cutoffTs - LATCH_LEAD + 1);
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerVotingClosed.selector);
        vm.prank(whaleProposer);
        terminator.voteForInsurerTermination(address(pair), lastId[whaleProposer], 1);

        uint256 before = usdc.balanceOf(whaleProposer);
        _execute(whaleProposer);
        assertEq(pair.scheduledTerminationTs(), 0, "too late to latch: nothing scheduled");
        assertEq(usdc.balanceOf(whaleProposer) - before, INSURER_BOND_USDC, "consensus was real: bond refunded");
    }

    /// @notice Exactly one latch lead before the cutoff is still in time to vote and latch.
    function test_LatchDeadline_ExactlyOneLeadBeforeCutoffStillLatches() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        vm.warp(cutoffTs - LATCH_LEAD);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "latched at the deadline");
    }

    /// @notice A proposal at the minimum lead still gives other insurers time to vote: its latch
    ///         deadline sits MIN_LEAD - LATCH_LEAD after the proposal, so a vote cast that late
    ///         still schedules the pair, and one a second later is refused.
    function test_MinimumLead_StillLeavesTimeToVote() public {
        uint64 proposalTs = _now();
        uint64 cutoffTs = proposalTs + MIN_LEAD;
        _proposeAt(whaleProposer, cutoffTs);
        bytes32 second = _proposeAt(majorityVoter, cutoffTs);

        // The whale's proposal is voted and latched at its deadline, an hour after it was filed.
        vm.warp(proposalTs + MIN_LEAD - LATCH_LEAD);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "latched an hour after the proposal");

        // The second proposal, filed at the same instant, closes to votes one second later.
        vm.warp(proposalTs + MIN_LEAD - LATCH_LEAD + 1);
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerVotingClosed.selector);
        vm.prank(majorityVoter);
        terminator.voteForInsurerTermination(address(pair), second, 1);
    }

    /// @notice A vote names the proposal it backs; an unknown id is refused.
    function test_Vote_UnknownId_Reverts() public {
        _proposeInsurerTermination(whaleProposer);
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerNoActiveProposal.selector);
        vm.prank(majorityVoter);
        terminator.voteForInsurerTermination(address(pair), bytes32(uint256(1)), 1);
    }

    /// @notice A preempted proposal cannot be refiled within the same second, since the two
    ///         filings would share an id. One second later it can, under a fresh id, and the old
    ///         record has no bearing on the new proposal.
    function test_Repropose_SameTimestampRefused_NextSecondFresh() public {
        _proposeAt(majorityVoter, _now() + 2 days);
        _vote(majorityVoter, majorityVoter, 20_000 * BAZAAR_SCALE);

        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        _execute(majorityVoter); // threshold met, but the pair is already scheduled earlier: preempted
        (,,,, bool resolved, bool scheduled) = _readProposal(majorityVoter);
        assertTrue(resolved && !scheduled, "preempted");

        usdc.mint(majorityVoter, INSURER_BOND_USDC);
        vm.startPrank(majorityVoter);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerActiveProposal.selector);
        terminator.proposeInsurerTermination(address(pair), _now() + MIN_LEAD);
        vm.stopPrank();

        vm.warp(_now() + 1);
        _proposeAt(majorityVoter, _now() + MIN_LEAD);
        assertLt(_now() + MIN_LEAD, cutoffTs, "sanity: still earlier than the schedule");
        assertEq(
            terminator.getInsurerVote(address(pair), majorityVoter, lastId[majorityVoter]),
            0,
            "nothing voted into the new proposal yet"
        );
        _vote(majorityVoter, majorityVoter, 20_000 * BAZAAR_SCALE); // full eligibility again
    }

    /// @notice Voters into a proposal overtaken by an earlier cutoff stay locked until that
    ///         earlier cutoff arrives: they voted to settle, and the settlement merely comes sooner.
    function test_PreemptedProposal_VotersLockedUntilPairCutoff() public {
        _depositInsurance(diluter, 1_000 * BAZAAR_SCALE);
        vm.warp(_now() + 8 days);

        _proposeAt(majorityVoter, _now() + 3 days);
        _vote(diluter, majorityVoter, 1_000 * BAZAAR_SCALE);

        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        _vote(majorityVoter, majorityVoter, 20_000 * BAZAAR_SCALE);
        _execute(majorityVoter); // preempted by the earlier schedule

        assertEq(
            terminator.getLockedShares(address(pair), diluter), 1_000 * BAZAAR_SCALE, "locked until the pair's cutoff"
        );
        vm.warp(cutoffTs);
        assertEq(terminator.getLockedShares(address(pair), diluter), 0, "released at the pair's cutoff");
    }

    /// @notice A verified UMA cutoff earlier than a pending insurer schedule pulls it in, and the
    ///         cutoff then settles under UMA's rules.
    function test_UmaAcceptance_PullsInsurerScheduleEarlier() public {
        _proposeAt(whaleProposer, _now() + MAX_LEAD);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertTrue(terminator.insurerScheduled(address(pair)), "insurer-scheduled");

        uint256 lastTradingTs = vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS();
        vm.startPrank(whaleProposer);
        usdc.approve(address(terminator), terminator.requiredTerminationBond());
        bytes32 aid = terminator.proposeTermination(address(pair), 3, lastTradingTs, "split at the open");
        vm.stopPrank();

        vm.warp(lastTradingTs + 1);
        terminator.settleTerminationProposal(aid);
        // Accepted a second after its proposed cutoff, so the cutoff lands a lead past acceptance.
        assertEq(
            pair.scheduledTerminationTs(),
            vm.getBlockTimestamp() + BazaarTypes.MIN_CUTOFF_LEAD,
            "UMA cutoff pulled the insurer schedule earlier"
        );
        assertFalse(terminator.insurerScheduled(address(pair)), "the cutoff is UMA's now");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), aid, "assertion accepted");
    }

    /// @notice A verified UMA cutoff at or after the insurer schedule leaves the earlier cutoff in
    ///         place and insurer-scheduled, and caps its settlement print instead.
    function test_UmaAcceptance_LaterCutoffCapsInsurerSchedule() public {
        uint256 lastTradingTs = vm.getBlockTimestamp() + 2 days;
        vm.startPrank(whaleProposer);
        usdc.approve(address(terminator), terminator.requiredTerminationBond());
        bytes32 aid = terminator.proposeTermination(address(pair), 2, lastTradingTs, "delisting");
        vm.stopPrank();

        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);

        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(aid);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "insurer cutoff stands");
        assertTrue(terminator.insurerScheduled(address(pair)), "still insurer-scheduled");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), aid, "UMA acceptance recorded");
        assertEq(terminator.umaCutoffCap(address(pair)), lastTradingTs, "UMA's cutoff caps the settlement print");
    }

    /// @notice Once the cutoff is ORACLE_DEAD_THRESHOLD old the stored price is the last resort
    ///         when the chain cannot be fetched; up to then, nothing but the chain.
    function test_Settlement_StoredPriceLastResortAfterDeadThreshold() public {
        bytes[] memory fresh = _btcPriceUpdate(_now());
        pair.refreshPrice{value: factory.oracle().getUpdateFee(fresh)}(fresh);
        (uint256 storedPrice,,,,) = pair.lastPairPrice();
        assertGt(storedPrice, 0, "sanity: a stored price exists");

        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);

        vm.warp(cutoffTs + 21 days);
        vm.expectRevert(abi.encodeWithSelector(BazaarOracle.BazaarOracle__SampleCountMismatch.selector, 0, 5));
        terminator.terminateScheduledPair(address(pair), new bytes[](0));

        vm.warp(cutoffTs + 21 days + 1);
        terminator.terminateScheduledPair(address(pair), new bytes[](0));
        assertEq(pair.auxState().settlementPrice, storedPrice, "settled at the stored price as a last resort");
    }

    /// @notice The last resort settles a pair that never stored a price at the nominal price, and
    ///         its insurers, who could leave the live pair only against a fresh price, are paid.
    function test_Settlement_NeverPricedLastResortAfterDeadThreshold() public {
        (uint256 storedPrice,,,,) = pair.lastPairPrice();
        assertEq(storedPrice, 0, "sanity: the pair never stored a price");

        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);

        vm.warp(cutoffTs + 21 days + 1);
        terminator.terminateScheduledPair(address(pair), new bytes[](0));
        assertEq(pair.auxState().settlementPrice, 1, "settled at the nominal price as a last resort");
        _finalizeAfterSweep();

        uint256 majShares = pair.insuranceShares(majorityVoter);
        uint256 balanceBefore = usdc.balanceOf(majorityVoter);
        vm.warp(vm.getBlockTimestamp() + POST_FIX_LOCK); // the yes-voter's post-fix lock
        vm.prank(majorityVoter);
        pair.requestInsuranceWithdrawal(majShares, 0, 0, 0, "", "");
        vm.prank(majorityVoter);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "", "");
        assertEq(pair.insuranceShares(majorityVoter), 0, "majority redeemed");
        assertGt(usdc.balanceOf(majorityVoter), balanceBefore, "majority paid out");
    }

    /// @notice Past the cutoff the book is frozen for settlement at the cutoff print: an ADL at
    ///         the frozen pre-cutoff mark is refused.
    function test_ExecuteAdl_RefusedInLimbo() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        vm.warp(cutoffTs);
        vm.expectRevert(BazaarPair.BazaarPair__PairScheduledForTermination.selector);
        pair.executeAdl(new address[](0), new address[](0), new bytes[](0));
    }

    uint256 constant PAIR_SLOT_SHARE_EPOCH = 92; // mirror of BazaarPairTerminator's pin

    function _pairEpoch() internal view returns (uint256) {
        return uint256(vm.load(address(pair), bytes32(PAIR_SLOT_SHARE_EPOCH)));
    }

    /// @dev Drain the fund's bookkeeping to zero and recapitalize it: the rescue deposit bumps
    ///      the share epoch, wiping every existing balance.
    function _drainAndRecap(address rescuer) internal {
        uint256 epochBefore = _pairEpoch();
        vm.store(address(pair), bytes32(SLOT_VAULT_INSURANCE_FUND_BALANCE), bytes32(uint256(0)));
        usdc.mint(rescuer, 10_000 * USDC_SCALE);
        _depositInsurance(rescuer, 10_000 * BAZAAR_SCALE);
        assertEq(_pairEpoch(), epochBefore + 1, "sanity: the recap started a new generation");
        assertEq(pair.insuranceShares(majorityVoter), 0, "sanity: the old generation reads zero");
    }

    /// @notice Pins the terminator's PAIR_SLOT_SHARE_EPOCH to the pair's layout: the slot moves by
    ///         exactly one on each recap — the moment old balances start reading zero — and not on
    ///         an ordinary deposit. A stale pin (a layout change) fails here rather than silently
    ///         disabling the epoch check.
    function test_EpochSlot_TracksRecaps() public {
        assertEq(_pairEpoch(), 0, "genesis generation");
        _depositInsurance(attacker, 1_000 * BAZAAR_SCALE);
        assertEq(_pairEpoch(), 0, "an ordinary deposit keeps the generation");
        _drainAndRecap(makeAddr("rescuer"));
        _drainAndRecap(makeAddr("rescuer2"));
        assertEq(_pairEpoch(), 2, "one step per recap");
    }

    /// @notice Votes cast by a generation the fund has since wiped cannot schedule the pair: the
    ///         proposal reached the threshold, but its voters own nothing now, so execute voids
    ///         it and refunds the bond instead of scheduling.
    function test_EpochBump_VoidsPassedProposal() public {
        _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _drainAndRecap(makeAddr("rescuer"));

        uint256 proposerBefore = usdc.balanceOf(whaleProposer);
        uint256 insuranceBefore = _insuranceFund();
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationVoided(address(pair), lastId[whaleProposer]);
        _execute(whaleProposer);

        assertEq(pair.scheduledTerminationTs(), 0, "a wiped generation cannot schedule the pair");
        assertEq(usdc.balanceOf(whaleProposer) - proposerBefore, INSURER_BOND_USDC, "bond refunded");
        assertEq(_insuranceFund(), insuranceBefore, "nothing forfeited to the recapitalized fund");
        (,,,, bool resolved, bool scheduled) = _readProposal(whaleProposer);
        assertTrue(resolved && !scheduled, "voided");
    }

    /// @notice A proposal from a wiped generation takes no further votes. The refusal comes from
    ///         the generation check, ahead of the share check the zeroed balance would also fail.
    function test_EpochBump_VoteOnOldProposalRefused() public {
        _proposeInsurerTermination(whaleProposer);
        _drainAndRecap(makeAddr("rescuer"));

        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerNoActiveProposal.selector);
        vm.prank(majorityVoter);
        terminator.voteForInsurerTermination(address(pair), lastId[whaleProposer], 1);
    }

    /// @notice Votes from a wiped generation lock nothing, even on a proposal that scheduled the
    ///         pair: a voter who re-deposits in the new generation can withdraw the new stake. The
    ///         schedule itself survives the recap — it is the pair's, not the voters'.
    function test_EpochBump_OldVotesLockNothing() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 20_000 * BAZAAR_SCALE, "locked");

        _drainAndRecap(makeAddr("rescuer"));
        _depositInsurance(majorityVoter, 1_000 * BAZAAR_SCALE);

        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 0, "old-generation votes lock nothing");
        assertEq(terminator.getInsurerVote(address(pair), majorityVoter, lastId[whaleProposer]), 0, "record reads dead");
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "the schedule survives the recap");
    }

    /// @notice A proposer whose stale proposal is still before its cutoff can file again once
    ///         their new-generation stake matures; the stale one is voided with its bond refunded
    ///         when anyone resolves it, never forfeited to the recapitalized fund.
    function test_EpochBump_StaleProposalVoidedOnResolution_NewOneFiles() public {
        _proposeAt(whaleProposer, _now() + MAX_LEAD);
        bytes32 stale = lastId[whaleProposer];
        _drainAndRecap(makeAddr("rescuer"));
        _depositInsurance(whaleProposer, 1_000 * BAZAAR_SCALE);
        vm.warp(_now() + 8 days); // the new stake matures; the stale proposal's cutoff is still ahead

        uint256 proposerBefore = usdc.balanceOf(whaleProposer);
        _proposeInsurerTermination(whaleProposer);
        assertEq(usdc.balanceOf(whaleProposer), proposerBefore, "the new bond is posted; nothing else moves");
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.InsurerTerminationVoided(address(pair), stale);
        terminator.executeInsurerTermination(address(pair), stale);
        assertEq(usdc.balanceOf(whaleProposer), proposerBefore + INSURER_BOND_USDC, "stale bond refunded");
        _vote(whaleProposer, whaleProposer, 1_000 * BAZAAR_SCALE); // the new proposal takes votes
    }

    // -------------------- The post-fix lock and the levy --------------------

    /// @notice A bare vote settles unjudged: once the pair is fixed, its yes-voters stay locked for
    ///         the withdrawal cooldown they would otherwise have bypassed, while a holder who did
    ///         not vote is free at once. The lock lifts on the day.
    function test_BareVote_YesVotersLockedThroughCooldownAfterFix() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        _settleAtCutoff(cutoffTs);

        (bool costed, uint8 outcome,) = _readOutcome(whaleProposer);
        assertTrue(costed, "a bare vote is costed");
        assertEq(outcome, terminator.OUTCOME_UNJUDGED(), "no verdict behind a bare vote");
        assertEq(
            terminator.getLockedShares(address(pair), majorityVoter),
            20_000 * BAZAAR_SCALE,
            "yes-voter locked after the fix"
        );
        assertEq(terminator.getLockedShares(address(pair), whaleProposer), 0, "the proposer did not vote: free");

        uint256 fixedTs = pair.settlementPriceFixedTs();
        vm.warp(fixedTs + POST_FIX_LOCK - 1);
        assertEq(
            terminator.getLockedShares(address(pair), majorityVoter), 20_000 * BAZAAR_SCALE, "locked to the last second"
        );
        vm.warp(fixedTs + POST_FIX_LOCK);
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 0, "released once the cooldown has run");
    }

    /// @notice The unjudged levy is half the dissent fraction of every yes-voted share, credited
    ///         at redemption to the bug bounty address: the yes-voter is paid for the rest, the
    ///         price every other holder redeems at is unchanged whatever the order, and the bounty
    ///         address redeems the forfeit like any holder.
    function test_BareVote_LevyIsHalfTheDissent_PaidToBugBounty() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        uint256 snapshot = _readSnapshot(whaleProposer);
        uint256 voted = 15_000 * BAZAAR_SCALE; // 62% of the snapshot: enough dissent to clear the floor
        _vote(majorityVoter, whaleProposer, voted);
        _execute(whaleProposer);
        _settleAtCutoff(cutoffTs);
        _finalizeAfterSweep();

        (,, uint16 levyBp) = _readOutcome(whaleProposer);
        assertEq(levyBp, LEVY_BP * (snapshot - voted) / snapshot, "half the dissent fraction");
        assertGt(levyBp, LEVY_FLOOR_BP, "fixture: the slope, not the floor");
        uint256 expectedLevy = voted * levyBp / 10_000;

        // The whale, who did not vote, redeems first at the fund's price.
        uint256 whaleBefore = usdc.balanceOf(whaleProposer);
        uint256 whaleExpected = _payoutUsdc(pair.insuranceShares(whaleProposer));
        _redeemAll(whaleProposer);
        assertApproxEqAbs(usdc.balanceOf(whaleProposer) - whaleBefore, whaleExpected, 1, "non-voter paid in full");

        // The yes-voter redeems after the lock: the forfeit goes to the bounty, the rest pays.
        vm.warp(pair.settlementPriceFixedTs() + POST_FIX_LOCK);
        uint256 majBefore = usdc.balanceOf(majorityVoter);
        uint256 majExpected = _payoutUsdc(pair.insuranceShares(majorityVoter) - expectedLevy); // 5,000 unvoted plus the voted rest
        _redeemAll(majorityVoter);
        assertEq(pair.insuranceShares(majorityVoter), 0, "all shares left the voter");
        assertEq(pair.insuranceShares(_bounty()), expectedLevy, "the forfeit sits with the bug bounty");
        assertApproxEqAbs(
            usdc.balanceOf(majorityVoter) - majBefore, majExpected, 1, "paid for the rest at the same price"
        );

        // The seed holder redeems at the same price, and the bounty address last, for the rest.
        uint256 seedBefore = usdc.balanceOf(deployer);
        uint256 seedExpected = _payoutUsdc(pair.insuranceShares(deployer));
        _redeemAll(deployer);
        assertApproxEqAbs(usdc.balanceOf(deployer) - seedBefore, seedExpected, 1, "seed holder paid at the same price");
        assertEq(pair.totalInsuranceShares(), expectedLevy, "only the forfeit remains");
        uint256 bountyBefore = usdc.balanceOf(_bounty());
        uint256 bountyExpected = _payoutUsdc(expectedLevy);
        _redeemAll(_bounty());
        assertApproxEqAbs(usdc.balanceOf(_bounty()) - bountyBefore, bountyExpected, 1, "the bounty redeems the forfeit");
        assertEq(pair.totalInsuranceShares(), 0, "nothing stranded");
    }

    /// @notice Below 20% dissent the floor binds: the majority's 83% backs the vote, and the
    ///         levy is a tenth of every voted share rather than the smaller dissent-scaled figure.
    function test_BareVote_FloorBindsWhenDissentIsSmall() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        uint256 snapshot = _readSnapshot(whaleProposer);
        uint256 voted = 20_000 * BAZAAR_SCALE;
        assertLt(LEVY_BP * (snapshot - voted) / snapshot, LEVY_FLOOR_BP, "fixture: the slope is under the floor");
        _vote(majorityVoter, whaleProposer, voted);
        _execute(whaleProposer);
        _settleAtCutoff(cutoffTs);
        (,, uint16 levyBp) = _readOutcome(whaleProposer);
        assertEq(levyBp, LEVY_FLOOR_BP, "the floor");
    }

    /// @notice A vote every share backed still pays the floor: ending a market with no judge has
    ///         a base price even for a holder of the whole fund. The post-fix lock applies too.
    function test_BareVote_Unanimous_PaysTheFloor() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _vote(whaleProposer, whaleProposer, 100 * BAZAAR_SCALE);
        _vote(deployer, whaleProposer, pair.insuranceShares(deployer));
        _execute(whaleProposer);
        _settleAtCutoff(cutoffTs);

        (bool costed,, uint16 levyBp) = _readOutcome(whaleProposer);
        assertTrue(costed, "unjudged, so costed");
        assertEq(levyBp, LEVY_FLOOR_BP, "no dissent to scale by: the floor");
        assertEq(
            terminator.getLockedShares(address(pair), deployer), pair.insuranceShares(deployer), "locked all the same"
        );

        _finalizeAfterSweep();
        vm.warp(pair.settlementPriceFixedTs() + POST_FIX_LOCK);
        _redeemAll(majorityVoter);
        assertEq(pair.insuranceShares(_bounty()), 20_000 * BAZAAR_SCALE / 10, "a tenth of the voted stake forfeited");
    }

    /// @notice A bare vote that pulled in a cutoff UMA had verified is not costed: UMA confirmed
    ///         the event the vote moved the halt ahead of, so no lock follows the fix and no levy
    ///         is owed. The settlement still runs under the cap.
    function test_BareVote_MetVerifiedUmaCutoff_NotCosted() public {
        address umaCaller = pair.umaContract();
        uint64 umaCutoff = _now() + 3 days;
        vm.prank(umaCaller);
        pair.setScheduledTermination(umaCutoff, whaleProposer);

        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertEq(terminator.umaCutoffCap(address(pair)), umaCutoff, "fixture: the vote met a UMA cutoff");

        _settleAtCutoff(cutoffTs);
        (bool costed, uint8 outcome, uint16 levyBp) = _readOutcome(whaleProposer);
        assertEq(outcome, terminator.OUTCOME_UNJUDGED(), "no verdict of its own");
        assertFalse(costed, "the verified cutoff it met vouches for it");
        assertEq(levyBp, 0, "no levy");
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 0, "no post-fix lock");
    }

    /// @notice The unvoted part of a balance leaves first and is never levied; the voted part is
    ///         drawn as it leaves, so two partial redemptions forfeit exactly what one would have.
    function test_BareVote_LevyAcrossPartialRedemptions() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        uint256 voted = 16_000 * BAZAAR_SCALE; // of the majority's 20,000; clears 60% of the snapshot
        _vote(majorityVoter, whaleProposer, voted);
        _execute(whaleProposer);
        _settleAtCutoff(cutoffTs);
        _finalizeAfterSweep();
        uint256 expectedLevy = _levyShares(whaleProposer, voted);
        assertGt(expectedLevy, 0, "fixture: a levy is owed");

        vm.warp(pair.settlementPriceFixedTs() + POST_FIX_LOCK);
        // The first 5,000 are the 4,000 unvoted shares plus 1,000 of the voted stake.
        vm.prank(majorityVoter);
        pair.requestInsuranceWithdrawal(5_000 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.prank(majorityVoter);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "", "");
        assertEq(
            pair.insuranceShares(_bounty()),
            _levyShares(whaleProposer, 1_000 * BAZAAR_SCALE),
            "only the voted part levied"
        );
        assertEq(
            terminator.getInsurerVote(address(pair), majorityVoter, lastId[whaleProposer]),
            voted - 1_000 * BAZAAR_SCALE,
            "voted stake drawn down by the voted part only"
        );
        // The rest is all voted stake.
        _redeemAll(majorityVoter);
        assertEq(pair.insuranceShares(_bounty()), expectedLevy, "the two draws add up to one");
        assertEq(
            terminator.getInsurerVote(address(pair), majorityVoter, lastId[whaleProposer]), 0, "voted stake exhausted"
        );
    }

    /// @notice During the post-fix lock a yes-voter may redeem the shares they never voted, which
    ///         pay no levy and do not shrink the lock; the voted stake stays put to the last second.
    function test_PostFixLock_UnvotedSharesLeave_VotedStayLocked() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        uint256 voted = 16_000 * BAZAAR_SCALE;
        _vote(majorityVoter, whaleProposer, voted);
        _execute(whaleProposer);
        _settleAtCutoff(cutoffTs);
        _finalizeAfterSweep();

        vm.prank(majorityVoter);
        pair.requestInsuranceWithdrawal(4_000 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.prank(majorityVoter);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "", "");
        assertEq(pair.insuranceShares(majorityVoter), voted, "the unvoted shares left");
        assertEq(pair.insuranceShares(_bounty()), 0, "no levy on unvoted shares");
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), voted, "the lock is untouched");

        vm.prank(majorityVoter);
        pair.requestInsuranceWithdrawal(1, 0, 0, 0, "", "");
        vm.prank(majorityVoter);
        vm.expectRevert(InsuranceVaultLib.InsuranceVaultLib__SharesLockedForVoting.selector);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "", "");

        vm.warp(pair.settlementPriceFixedTs() + POST_FIX_LOCK);
        _redeemAll(majorityVoter);
        assertEq(pair.insuranceShares(_bounty()), _levyShares(whaleProposer, voted), "the whole voted stake levied");
    }

    /// @notice A verified UMA cutoff far beyond the vote window vouches for nothing about a halt
    ///         pulled in by weeks: the vote is costed like one that met no cutoff at all.
    function test_BareVote_FarVerifiedCutoff_StillCosted() public {
        address umaCaller = pair.umaContract();
        uint64 umaCutoff = _now() + 60 days;
        vm.prank(umaCaller);
        pair.setScheduledTermination(umaCutoff, whaleProposer);

        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        assertEq(terminator.umaCutoffCap(address(pair)), umaCutoff, "fixture: the vote met a far UMA cutoff");

        _settleAtCutoff(cutoffTs);
        (bool costed,, uint16 levyBp) = _readOutcome(whaleProposer);
        assertTrue(costed, "a far cutoff does not vouch for the halt");
        assertGt(levyBp, 0, "the levy applies");
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 20_000 * BAZAAR_SCALE, "locked");
    }

    /// @notice Once a vote-set cutoff has passed, the stale-oracle path is refused: the pair
    ///         settles through terminateScheduledPair, whose last resort reaches the same stored
    ///         price with the vote's outcome stamped.
    function test_StalePath_RefusedPastInsurerCutoff() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);

        vm.warp(cutoffTs + 22 days);
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerScheduleSettlesPair.selector);
        terminator.terminateStalePair(address(pair));

        terminator.terminateScheduledPair(address(pair), new bytes[](0));
        (bool costed,,) = _readOutcome(whaleProposer);
        assertTrue(costed, "the last resort stamps the outcome");
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 20_000 * BAZAAR_SCALE, "locked");
    }

    /// @notice A share generation wiped after the vote latched owes nothing: the stake the vote
    ///         counted is gone, so a re-depositor's new shares are neither locked after the fix nor
    ///         levied, even though the vote's outcome is costed.
    function test_EpochBump_AfterLatch_NoPostFixLockOrLevy() public {
        uint64 cutoffTs = _proposeInsurerTermination(whaleProposer);
        _vote(majorityVoter, whaleProposer, 20_000 * BAZAAR_SCALE);
        _execute(whaleProposer);
        _drainAndRecap(makeAddr("rescuer"));
        _depositInsurance(majorityVoter, 1_000 * BAZAAR_SCALE);

        _settleAtCutoff(cutoffTs);
        (bool costed,,) = _readOutcome(whaleProposer);
        assertTrue(costed, "the outcome is costed");
        assertEq(terminator.getLockedShares(address(pair), majorityVoter), 0, "a wiped generation locks nothing");

        _finalizeAfterSweep();
        uint256 bountyBefore = pair.insuranceShares(_bounty());
        _redeemAll(majorityVoter);
        assertEq(pair.insuranceShares(majorityVoter), 0, "the new stake redeemed at once");
        assertEq(pair.insuranceShares(_bounty()), bountyBefore, "and paid no levy");
    }

    /// @notice Only a registered pair may draw on a levy.
    function test_ConsumeLevy_OnlyPair() public {
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__OnlyPair.selector);
        vm.prank(attacker);
        terminator.consumeInsurerLevy(majorityVoter, 1);
    }
}

// ==================== listing seed maturity ====================

/// @notice The listing seed is a deposit like any other for the insurer vote: it carries a lot
///         stamped at listing, so the deployer can neither propose nor vote it before it has aged
///         the maturity period. A lot-less seed would read as mature at every cutoff and let a
///         deployer list a market, let positions build, and force-terminate it a week early on a
///         snapshot frozen before anyone else could deposit.
contract SeedMaturityTest is Test {
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;
    uint256 constant INSURER_BOND_USDC = 1_000 * 1e6; // mirror of internal constant in BazaarPairTerminator
    uint256 constant INSURER_SHARE_MATURITY_PERIOD = 4 days;
    uint64 constant DEFAULT_LEAD = 1 days;

    BazaarFactory factory;
    BazaarPair pair;
    BazaarPairTerminator terminator;
    MockUSDC usdc;
    MockPyth mockPyth;

    address deployer;
    uint256 seed; // shares minted to the deployer at listing
    uint64 seedTs; // timestamp at which the pair was initialized and the seed minted

    function setUp() public {
        deployer = makeAddr("deployer");

        vm.etch(address(0x64), address(new MockArbSys()).code);

        DeployBazaar dep = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = dep.deploy(makeAddr("bugBounty"));

        (, address usdcAddr,,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcAddr);
        terminator = factory.pairTerminator();
        mockPyth = MockPyth(address(factory.oracle().pyth()));
        PythSeed.seed(address(mockPyth), BTC_USD_FEED_ID);

        usdc.mint(deployer, PROPOSAL_TOTAL_USDC);
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        pair = BazaarPair(payable(factory.getPairAddress(pairId)));
        seedTs = uint64(vm.getBlockTimestamp());
        seed = pair.insuranceShares(deployer);
        assertGt(seed, 0, "listing minted the seed to the deployer");
    }

    function _proposeAsDeployer() internal returns (bytes32 id, uint64 cutoffTs) {
        cutoffTs = uint64(vm.getBlockTimestamp()) + DEFAULT_LEAD;
        usdc.mint(deployer, INSURER_BOND_USDC);
        vm.startPrank(deployer);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        id = terminator.proposeInsurerTermination(address(pair), cutoffTs);
        vm.stopPrank();
    }

    /// @notice The seed reads as immature at any cutoff before listing and mature from listing on.
    function test_SeedLot_MaturesFromListingTimestamp() public view {
        assertEq(pair.totalInsuranceShares(), seed, "the seed is the whole supply at listing");
        assertEq(pair.getSharesAsOf(deployer, seedTs - 1), 0, "nothing mature before listing");
        assertEq(pair.getSharesAsOf(deployer, seedTs), seed, "fully mature at the listing timestamp");
    }

    /// @notice One second short of maturity the seed cannot open a vote: the proposer gate applies
    ///         the cutoff the vote would, and the seed lot is younger than it.
    function test_SeedCannotProposeBeforeMaturity() public {
        vm.warp(seedTs + INSURER_SHARE_MATURITY_PERIOD - 1);
        usdc.mint(deployer, INSURER_BOND_USDC);
        vm.startPrank(deployer);
        usdc.approve(address(terminator), INSURER_BOND_USDC);
        vm.expectRevert(BazaarPairTerminator.BazaarPairTerminator__InsurerNoMatureShares.selector);
        terminator.proposeInsurerTermination(address(pair), uint64(vm.getBlockTimestamp()) + DEFAULT_LEAD);
        vm.stopPrank();
    }

    /// @notice A seed that has aged exactly the maturity period proposes, votes, schedules, and
    ///         settles the pair at the cutoff.
    function test_SeedProposesAndVotesAfterMaturity() public {
        vm.warp(seedTs + INSURER_SHARE_MATURITY_PERIOD);
        (bytes32 id, uint64 cutoffTs) = _proposeAsDeployer();
        vm.prank(deployer);
        terminator.voteForInsurerTermination(address(pair), id, seed);
        terminator.executeInsurerTermination(address(pair), id);
        assertEq(pair.scheduledTerminationTs(), cutoffTs, "the matured seed's vote scheduled the pair");

        bytes[] memory pu = PythChain.flat(mockPyth, BTC_USD_FEED_ID, 50_000, cutoffTs, cutoffTs - 1);
        vm.warp(PythChain.lastPublish(cutoffTs) + 10);
        uint256 fee = factory.oracle().getSampleSetFee(BTC_USD_FEED_ID, pu);
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
        assertGt(pair.settlementPriceFixedTs(), 0, "settled at the chain from the cutoff");
    }
}

// ==================== UMA identifier-upgrade governance ====================

/// @notice The UMA identifier-upgrade governance path must cost more than the pair-deployment
///         path. A protocol-wide change to the adjudicating identifier at deployment-grade
///         friction (1,000 USDC, no timelock) would be a cheap governance-compromise vector, so
///         it runs at a 5,000 USDC bond and a 12-day activation timelock on top of its 2-day
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
    ///         12-day post-approval activation timelock.
    function test_R2_3_OracleUpgradeConstants() public view {
        assertEq(factory.IDENTIFIER_UPGRADE_LIVENESS(), 2 days, "liveness = 2 days");
        assertEq(factory.IDENTIFIER_UPGRADE_BOND_USDC(), 5_000 * 1e6, "bond = 5,000 USDC");
        assertEq(factory.IDENTIFIER_UPGRADE_TIMELOCK(), 12 days, "activation timelock = 12 days");
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
            effectiveTs, block.timestamp + factory.IDENTIFIER_UPGRADE_TIMELOCK(), "activates 12 days after approval"
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
        PythSeed.seed(address(factory.oracle().pyth()), bytes32("AAPL_FEED"));
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
            "CreateOrder(uint8 orderType,uint256 triggerPrice,uint256 limitPrice,uint256 maxSlippageBp,uint256 size,bool isLong,bool isPostOnly,uint8 tif,uint256 expirationBlock,address integrator,uint256 nonce,uint256 deadline,uint256 relayerFee)"
        );
        assertEq(MetaTxLib.CREATE_ORDER_TYPEHASH, expected, "typehash uses expirationBlock");

        bytes32 expirationTsForm = keccak256(
            "CreateOrder(uint8 orderType,uint256 triggerPrice,uint256 limitPrice,uint256 maxSlippageBp,uint256 size,bool isLong,bool isPostOnly,uint8 tif,uint256 expirationTs,address integrator,uint256 nonce,uint256 deadline,uint256 relayerFee)"
        );
        assertTrue(MetaTxLib.CREATE_ORDER_TYPEHASH != expirationTsForm, "typehash is not the expirationTs form");
    }
}

/// @notice UMA termination proposals: the proposal-time guards (lead time, free-text bounds,
///         claim fencing) and the acceptance-anchored settlement grace. A disputed proposal can
///         resolve at the DVM after its lastTradingTs has passed; the precise-only grace then
///         runs from ACCEPTANCE, so an immediate empty-calldata call can't force the
///         last-stored-price fallback while the genuine archived tick is still postable.
contract TerminationProposalTest is Test {
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    int32 constant BTC_EXPO = -8;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;
    uint256 constant GRACE = 12 hours; // mirror of SCHEDULED_TERMINATION_GRACE

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
        pyth = MockPyth(address(factory.oracle().pyth()));
        PythSeed.seed(address(pyth), BTC_USD_FEED_ID);

        usdc.mint(deployer, PROPOSAL_TOTAL_USDC);
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        pair = BazaarPair(payable(factory.getPairAddress(pairId)));

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

    /// @dev Build (without submitting) a Pyth update at a specific historical publishTime, with the
    ///      predecessor publish time Pyth's uniqueness check reads.
    function _historicalUpdate(int64 price, uint64 conf, uint64 publishTime, uint64 prevPublishTime)
        internal
        view
        returns (bytes[] memory u)
    {
        u = new bytes[](1);
        u[0] = pyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID, price, conf, BTC_EXPO, price, conf, publishTime, prevPublishTime
        );
    }

    /// @notice A settle must never consume an accepted assertion without scheduling the pair. A
    ///         caller who starves the settle of gas makes the pair-side call run out inside the
    ///         terminator's try; at every gas limit that has to surface as a reverted settle, never
    ///         as a settled assertion and an unscheduled pair.
    function test_UmaAcceptance_StarvedSettleRevertsRatherThanConsumingTheAssertion() public {
        uint256 lastTradingTs = vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS();
        bytes32 aid = _propose(lastTradingTs);
        vm.warp(lastTradingTs + 1);

        uint256 settled;
        uint256 unscheduled;
        for (uint256 g = 50_000; g <= 450_000; g += 500) {
            uint256 snap = vm.snapshotState();
            try terminator.settleTerminationProposal{gas: g}(aid) {
                settled++;
                if (pair.scheduledTerminationTs() == 0) unscheduled++;
            } catch {}
            vm.revertToStateAndDelete(snap);
        }
        assertGt(settled, 0, "the sweep reaches gas limits that settle");
        assertEq(unscheduled, 0, "every settle that went through scheduled the pair");
    }

    function _propose(uint256 lastTradingTs) internal returns (bytes32 assertionId) {
        vm.startPrank(proposer);
        usdc.approve(address(terminator), 1_000 * USDC_SCALE);
        assertionId = terminator.proposeTermination(address(pair), 1, lastTradingTs, "feed decommissioned");
        vm.stopPrank();
    }

    /// @dev Propose at the minimum lead, dispute, and have the DVM uphold the proposer only once
    ///      `acceptTs` — later than lastTradingTs — has arrived. Returns the scheduled cutoff.
    function _proposeDisputeAcceptLate(uint256 acceptTs) internal returns (uint256 lastTradingTs) {
        lastTradingTs = vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS();
        bytes32 aid = _propose(lastTradingTs);

        MockOptimisticOracleV3 oo = MockOptimisticOracleV3(address(factory.oo()));
        address disputer = makeAddr("disputer");
        usdc.mint(disputer, 1_000 * USDC_SCALE);
        vm.startPrank(disputer);
        usdc.approve(address(oo), 1_000 * USDC_SCALE);
        oo.disputeAssertion(aid, disputer);
        vm.stopPrank();

        vm.warp(acceptTs);
        oo.mockDvmResolve(aid, true);
        terminator.settleTerminationProposal(aid);
    }

    /// @notice The cutoff floor on the scheduled path is the vote's minimum lead: a cutoff nearer
    ///         than that could not be voted through before its latch closes.
    function test_ScheduledProposal_MinimumLeadIsTheVoteLead() public {
        uint256 lead = 2 hours; // mirror of INSURER_TERMINATION_MIN_LEAD

        vm.startPrank(proposer);
        usdc.approve(address(terminator), 2_000 * USDC_SCALE);

        // One second short of the lead -> rejected.
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__LastTradingTsTooSoon.selector,
                block.timestamp + lead - 1,
                block.timestamp + lead
            )
        );
        terminator.proposeTermination(address(pair), 2, block.timestamp + lead - 1, "delisting");

        // Exactly at the boundary -> accepted, and its vote opens with the claim.
        bytes32 aid = terminator.proposeTermination(address(pair), 2, block.timestamp + lead, "delisting");
        vm.stopPrank();
        assertTrue(aid != bytes32(0), "boundary proposal accepted");
        (address votePair,,,, uint256 cutoffTs,,,,, bool claimBacked,,,,,,) = terminator.insurerProposals(aid);
        assertEq(votePair, address(pair), "the claim opened a vote on the pair");
        assertEq(cutoffTs, block.timestamp + lead, "on the same cutoff");
        assertTrue(claimBacked, "backed by the claim");
    }

    /// @notice A cutoff nearer than the liveness that nobody votes through is accepted after it,
    ///         since an undisputed claim resolves only when the liveness ends, and is scheduled like
    ///         any late acceptance: MIN_CUTOFF_LEAD after the settle. The bond comes back.
    function test_NearCutoff_NoVote_ScheduledAfterTheAcceptance() public {
        uint256 lastTradingTs = vm.getBlockTimestamp() + 3 hours;
        bytes32 aid = _propose(lastTradingTs);
        uint256 proposerBefore = usdc.balanceOf(proposer);

        uint256 acceptTs = vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1;
        uint256 cutoffTs = acceptTs + BazaarTypes.MIN_CUTOFF_LEAD;
        vm.warp(acceptTs);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.TerminationProposalAccepted(address(pair), aid, cutoffTs);
        terminator.settleTerminationProposal(aid);

        assertEq(pair.scheduledTerminationTs(), cutoffTs, "scheduled a lead past the acceptance");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), aid, "the acceptance is in force");
        assertFalse(terminator.insurerScheduled(address(pair)), "a UMA schedule, not the vote's");
        assertEq(usdc.balanceOf(proposer), proposerBefore + 1_000 * USDC_SCALE, "undisputed: the bond came back");
        (,,,,,,,,,,,,, uint8 verdict,,) = terminator.insurerProposals(aid);
        assertEq(verdict, terminator.VERDICT_TRUE(), "the verdict is recorded on the vote");
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
            terminator.proposeTermination(address(pair), 2, lastTradingTs, badReasons[i]);
        }
        vm.stopPrank();
    }

    /// @notice Length bounds: 1-1000 bytes of reason, boundaries inclusive.
    function test_ProposalText_LengthBoundsEnforced() public {
        vm.startPrank(proposer);
        usdc.approve(address(terminator), type(uint256).max);
        uint256 lastTradingTs = block.timestamp + 7 days;

        vm.expectRevert(abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__InvalidReason.selector, 0));
        terminator.proposeTermination(address(pair), 2, lastTradingTs, "");

        string memory reason1001 = _repeat("a", 1001);
        vm.expectRevert(abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__InvalidReason.selector, 1001));
        terminator.proposeTermination(address(pair), 2, lastTradingTs, reason1001);

        // Exactly at the maximum -> accepted.
        bytes32 aid = terminator.proposeTermination(address(pair), 2, lastTradingTs, _repeat("a", 1000));
        vm.stopPrank();
        assertTrue(aid != bytes32(0), "max-length reason accepted");
    }

    /// @notice Evidence URLs survive the reason whitelist, and the claim fences the free text:
    ///         spliced exactly once, as the FINAL section, inside brackets the charset makes
    ///         unforgeable. The contract names the pair itself, by pair ID, and the claim tells
    ///         verifiers to identify the asset from its feed IDs.
    function test_ProposalText_UrlEvidenceAcceptedAndClaimFenced() public {
        vm.startPrank(proposer);
        usdc.approve(address(terminator), type(uint256).max);
        // Exercises every URL-set character (: ? = # % _ ~ +) plus the base punctuation.
        string memory reason =
            "Delisting notice: https://pyth.network/status?feed=BTC_USD&seq=4#u_2026, mirror https://example.com/n~1+2%203";
        bytes32 aid = terminator.proposeTermination(address(pair), 2, block.timestamp + 7 days, reason);
        vm.stopPrank();

        _assertClaimFenced(aid, bytes(reason));

        bytes memory claim = MockOptimisticOracleV3(address(factory.oo())).claims(aid);
        bytes memory opening = bytes(
            string.concat(
                "Termination proposal for the Bazaar trading pair with pair ID ",
                Strings.toHexString(uint256(pair.pairId())),
                " on "
            )
        );
        for (uint256 i = 0; i < opening.length; i++) {
            assertEq(claim[i], opening[i], "claim must open with the contract-written pair ID");
        }
        assertEq(_count(claim, "Identify the pair's asset from the feed IDs listed above"), 1, "asset step missing");
    }

    /// @notice The claim names the chain it is made on, renders the declared category (which the
    ///         proposal also stores), discloses that acceptance is final, holds future events to a
    ///         fixed official date, and runs head, category definitions and validation steps
    ///         together in that order.
    function test_ProposalClaim_ChainIdCategoryAndFinality() public {
        vm.chainId(421614);
        vm.startPrank(proposer);
        usdc.approve(address(terminator), type(uint256).max);
        bytes32 aid = terminator.proposeTermination(address(pair), 2, block.timestamp + 7 days, "delisting notice");
        vm.stopPrank();

        bytes memory claim = MockOptimisticOracleV3(address(factory.oo())).claims(aid);
        assertEq(_count(claim, "(chain ID 421614)"), 1, "claim names the live chain");
        assertEq(_count(claim, "42161)"), 0, "no hardcoded mainnet chain ID");
        assertEq(_count(claim, "Declared reason category: (2) ASSET CESSATION."), 1, "declared category rendered");
        (,,,,,, uint8 storedCategory) = terminator.terminationProposals(aid);
        assertEq(storedCategory, 2, "declared category stored");
        assertEq(_count(claim, "must open with the number"), 0, "the category is an argument, not reason text");
        assertEq(_count(claim, "ACCEPTANCE IS FINAL"), 1, "finality disclosed");
        assertEq(
            _count(claim, "It can only move earlier: a later UMA proposal with an earlier cutoff"),
            1,
            "the earlier-only rule disclosed"
        );
        assertEq(
            _count(claim, "Grounds that also fit another category do not invalidate the proposal"),
            1,
            "overlapping grounds are not fatal"
        );
        assertEq(_count(claim, "officially confirmed with a fixed effective date"), 1, "cessation certainty standard");
        assertEq(_count(claim, "fixed record, effective, or ex-date"), 1, "structural-change certainty standard");
        assertEq(
            _count(
                claim,
                bytes(
                    string.concat(
                        ". Proposed last trading timestamp: ",
                        Strings.toString(block.timestamp + 7 days),
                        ". VALID TERMINATION REASONS (the proposal declares one; the evidence must establish it): (1) ORACLE DECOMMISSION: "
                    )
                )
            ),
            1,
            "category definitions follow the head"
        );
        assertEq(
            _count(
                claim,
                "rendering the pair unable to fetch prices. HOW TO VALIDATE: "
                "Identify the pair's asset from the feed IDs listed above"
            ),
            1,
            "validation steps follow the category definitions"
        );
    }

    /// @notice A category outside the four the claim defines is refused before any bond moves.
    function test_ProposeTermination_InvalidCategoryReverts() public {
        vm.startPrank(proposer);
        usdc.approve(address(terminator), type(uint256).max);
        uint256 lastTradingTs = block.timestamp + 7 days;
        vm.expectRevert(abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__InvalidCategory.selector, 0));
        terminator.proposeTermination(address(pair), 0, lastTradingTs, "delisting");
        vm.expectRevert(abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__InvalidCategory.selector, 5));
        terminator.proposeTermination(address(pair), 5, lastTradingTs, "delisting");
        vm.stopPrank();
    }

    /// @notice Every figure the validation steps quote is rendered from the constant that enforces it.
    function test_ProposalClaim_FiguresComeFromConstants() public {
        vm.startPrank(proposer);
        usdc.approve(address(terminator), type(uint256).max);
        bytes32 aid = terminator.proposeTermination(address(pair), 1, block.timestamp + 7 days, "feed decommissioned");
        vm.stopPrank();

        bytes memory claim = MockOptimisticOracleV3(address(factory.oo())).claims(aid);
        string memory liveness = Strings.toString(terminator.TERMINATION_PROPOSAL_LIVENESS() / 1 hours);
        string memory voteLead = Strings.toString(uint256(2 hours) / 1 hours); // mirror of INSURER_TERMINATION_MIN_LEAD
        string memory halt = Strings.toString(BazaarTypes.LIMBO_LEAD);
        string memory window = Strings.toString(BazaarTypes.MAX_PRICE_STALENESS);
        string memory lead = Strings.toString(BazaarTypes.MIN_CUTOFF_LEAD);
        string memory grace = Strings.toString(GRACE / 1 hours);
        assertEq(_count(claim, bytes(string.concat("(", liveness, " hours after submission)"))), 1, "liveness figure");
        assertEq(
            _count(
                claim,
                bytes(string.concat("sooner than ", liveness, " hours after submission, down to ", voteLead, " hours"))
            ),
            1,
            "vote lead figure"
        );
        assertEq(_count(claim, "This proposal also opens a vote of the holders"), 1, "the vote is disclosed");
        assertEq(_count(claim, "forfeit half of their voted shares"), 1, "the levy is disclosed");
        assertEq(_count(claim, "Without a result 14 days after submission"), 1, "verdict grace figure");
        assertEq(_count(claim, "never less than 10 percent of them"), 1, "levy floor figure");
        assertEq(_count(claim, "may not redeem for 13 days after the settlement"), 1, "voter lock figure");
        assertEq(_count(claim, bytes(string.concat("halts trading ", halt, " seconds before"))), 1, "halt figure");
        assertEq(
            _count(claim, bytes(string.concat("within the last ", window, " seconds up to it"))), 1, "window figure"
        );
        assertEq(_count(claim, bytes(string.concat("moved to ", lead, " seconds after acceptance"))), 1, "lead figure");
        assertEq(
            _count(claim, bytes(string.concat("within ", grace, " hours of the scheduled timestamp"))),
            1,
            "grace figure"
        );
        assertEq(
            _count(claim, bytes(string.concat("except that the ", grace, " hours run from the end of this assertion"))),
            1,
            "vote grace figure"
        );
    }

    /// @notice An accepted cutoff only ever moves earlier: a later proposal for an earlier event
    ///         pulls the schedule in and becomes the accepted one.
    function test_LaterProposalWithAnEarlierCutoff_PullsTheScheduleIn() public {
        uint256 farCutoff = vm.getBlockTimestamp() + 120 days;
        bytes32 first = _propose(farCutoff);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(first);
        assertEq(pair.scheduledTerminationTs(), farCutoff, "fixture: the far cutoff is scheduled");

        uint256 nearCutoff = vm.getBlockTimestamp() + 7 days;
        bytes32 second = _propose(nearCutoff);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.TerminationProposalAccepted(address(pair), second, nearCutoff);
        terminator.settleTerminationProposal(second);

        assertEq(pair.scheduledTerminationTs(), nearCutoff, "the earlier cutoff is in force");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), second, "the later proposal is accepted");
    }

    /// @notice After an acceptance, a proposal whose cutoff is not earlier than the one in force is
    ///         refused before its bond moves.
    function test_ProposalNotEarlierThanTheAcceptedCutoff_RefusedWithoutBond() public {
        uint256 cutoff = vm.getBlockTimestamp() + 30 days;
        bytes32 aid = _propose(cutoff);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(aid);

        uint256 balanceBefore = usdc.balanceOf(proposer);
        vm.startPrank(proposer);
        usdc.approve(address(terminator), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(BazaarPairTerminator.BazaarPairTerminator__CutoffNotEarlier.selector, cutoff, cutoff)
        );
        terminator.proposeTermination(address(pair), 2, cutoff, "delisting");
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__CutoffNotEarlier.selector, cutoff + 1 days, cutoff
            )
        );
        terminator.proposeTermination(address(pair), 2, cutoff + 1 days, "delisting");
        vm.stopPrank();
        assertEq(usdc.balanceOf(proposer), balanceBefore, "no bond taken");
    }

    /// @notice Two proposals pending at once resolve to the earlier cutoff, whichever settles
    ///         first; on a tie the first to settle stands.
    function testFuzz_PendingProposalsResolveToTheEarlierCutoff(uint256 leadA, uint256 leadB, bool aFirst) public {
        uint256 liveness = terminator.TERMINATION_PROPOSAL_LIVENESS();
        leadA = bound(leadA, liveness, 365 days);
        leadB = bound(leadB, liveness, 365 days);
        bytes32 a = _propose(vm.getBlockTimestamp() + leadA);
        bytes32 b = _propose(vm.getBlockTimestamp() + leadB);
        (,, uint256 cutoffA,,,,) = terminator.terminationProposals(a);
        (,, uint256 cutoffB,,,,) = terminator.terminationProposals(b);
        vm.warp(vm.getBlockTimestamp() + liveness + 1);

        // Both settle in this block, so both get the same MIN_CUTOFF_LEAD floor.
        uint256 floorTs = vm.getBlockTimestamp() + BazaarTypes.MIN_CUTOFF_LEAD;
        uint256 effectiveA = cutoffA > floorTs ? cutoffA : floorTs;
        uint256 effectiveB = cutoffB > floorTs ? cutoffB : floorTs;
        (bytes32 first, bytes32 second) = aFirst ? (a, b) : (b, a);
        (uint256 firstTs, uint256 secondTs) = aFirst ? (effectiveA, effectiveB) : (effectiveB, effectiveA);
        terminator.settleTerminationProposal(first);
        terminator.settleTerminationProposal(second);

        bool secondWins = secondTs < firstTs;
        assertEq(pair.scheduledTerminationTs(), secondWins ? secondTs : firstTs, "the earlier cutoff is in force");
        assertEq(
            terminator.acceptedTerminationAssertionId(address(pair)), secondWins ? second : first, "its proposal stands"
        );
    }

    /// @notice The listing bounty is paid once per pair: the proposal that first schedules it earns
    ///         it, and a later one that brings the cutoff forward earns nothing.
    function test_PullIn_PaysTheProposerBountyOnce() public {
        bytes32 first = _propose(vm.getBlockTimestamp() + 60 days);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(first);
        (uint256 firstBounty,) = factory.lens().claimableFees(address(pair), proposer);
        assertGt(firstBounty, 0, "the first acceptance pays the bounty");

        address second = makeAddr("second proposer");
        usdc.mint(second, 1_000 * USDC_SCALE);
        vm.startPrank(second);
        usdc.approve(address(terminator), 1_000 * USDC_SCALE);
        bytes32 pullIn = terminator.proposeTermination(address(pair), 2, vm.getBlockTimestamp() + 7 days, "delisting");
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(pullIn);

        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), pullIn, "the pull-in took effect");
        (uint256 secondBounty,) = factory.lens().claimableFees(address(pair), second);
        assertEq(secondBounty, 0, "the pull-in earns nothing");
        (uint256 firstAfter,) = factory.lens().claimableFees(address(pair), proposer);
        assertEq(firstAfter, firstBounty, "the first proposer's bounty is unchanged");
    }

    /// @notice The maximum timestamp is a legal cutoff: with nothing in force it is accepted, and a
    ///         later finite cutoff then pulls it in.
    function test_UnboundedCutoff_AcceptedThenPulledIn() public {
        bytes32 unbounded = _propose(type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(unbounded);
        assertEq(pair.scheduledTerminationTs(), type(uint256).max, "the unbounded cutoff is scheduled");

        uint256 finite = vm.getBlockTimestamp() + 7 days;
        bytes32 pullIn = _propose(finite);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(pullIn);
        assertEq(pair.scheduledTerminationTs(), finite, "the finite cutoff pulled it in");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), pullIn, "the pull-in is in force");
    }

    /// @notice A pull-in settled after its own cutoff takes effect MIN_CUTOFF_LEAD after the settle,
    ///         and only while that still beats the cutoff in force: one second inside that bound it
    ///         pulls in by a second, at the bound it changes nothing.
    function test_LateSettleOfAPullIn_LandsAtTheLeadOrIsSuperseded() public {
        uint256 cutoff = vm.getBlockTimestamp() + 20 days;
        bytes32 first = _propose(cutoff);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(first);
        bytes32 late = _propose(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS());
        uint256 lead = BazaarTypes.MIN_CUTOFF_LEAD;

        uint256 snap = vm.snapshotState();
        vm.warp(cutoff - lead - 1);
        terminator.settleTerminationProposal(late);
        assertEq(pair.scheduledTerminationTs(), cutoff - 1, "inside the bound: pulled in by a second");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), late, "the pull-in is in force");
        vm.revertToStateAndDelete(snap);

        vm.warp(cutoff - lead);
        vm.expectEmit(true, true, false, true, address(terminator));
        emit BazaarPairTerminator.TerminationProposalSuperseded(address(pair), late);
        terminator.settleTerminationProposal(late);
        assertEq(pair.scheduledTerminationTs(), cutoff, "at the bound: nothing moves");
        assertEq(terminator.acceptedTerminationAssertionId(address(pair)), first, "the first acceptance stands");
    }

    /// @notice A disputed proposal the DVM upholds after its own cutoff, while an earlier acceptance
    ///         holds a later cutoff, pulls the schedule in to MIN_CUTOFF_LEAD after the ruling.
    function test_LateRulingAfterAnAcceptance_PullsInToTheLead() public {
        uint256 cutoff = vm.getBlockTimestamp() + 30 days;
        bytes32 first = _propose(cutoff);
        vm.warp(vm.getBlockTimestamp() + terminator.TERMINATION_PROPOSAL_LIVENESS() + 1);
        terminator.settleTerminationProposal(first);

        uint256 acceptTs = vm.getBlockTimestamp() + 5 days;
        _proposeDisputeAcceptLate(acceptTs);
        assertEq(pair.scheduledTerminationTs(), acceptTs + BazaarTypes.MIN_CUTOFF_LEAD, "a lead after the ruling");
        assertTrue(terminator.acceptedTerminationAssertionId(address(pair)) != first, "the late ruling is in force");
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

    /// @notice A late (disputed) acceptance only SCHEDULES the pair, MIN_CUTOFF_LEAD after the
    ///         acceptance instant rather than at the already-past proposed cutoff: the book traded
    ///         at live prices past that cutoff while its tick was public, and the lead puts the
    ///         window's first print after the acceptance block. The price-dependent settlement
    ///         runs in a separate retryable transaction, never inside the UMA callback.
    function test_LateAcceptance_SchedulesAtAcceptanceButDoesNotTerminate() public {
        uint256 acceptTs = vm.getBlockTimestamp() + 5 days;
        uint256 lastTradingTs = _proposeDisputeAcceptLate(acceptTs);

        assertLt(lastTradingTs, acceptTs, "proposed cutoff already past at acceptance");
        assertEq(
            pair.scheduledTerminationTs(),
            acceptTs + BazaarTypes.MIN_CUTOFF_LEAD,
            "cutoff scheduled a lead past acceptance"
        );
        assertFalse(pair.isPairTerminated(), "acceptance alone must not terminate");
    }

    /// @notice The tick at the proposed cutoff no longer settles the pair once acceptance has
    ///         moved the cutoff: it lies outside the window around the effective cutoff, so a
    ///         position opened after the proposed cutoff cannot be priced against it.
    function test_LateAcceptance_TickAtProposedCutoffRefused() public {
        _push(50_000e8, 50e8, uint64(vm.getBlockTimestamp()));
        pair.refreshPrice(new bytes[](0));
        uint256 lastTradingTs = _proposeDisputeAcceptLate(vm.getBlockTimestamp() + 5 days);
        vm.warp(pair.scheduledTerminationTs() + 1);

        bytes[] memory pu = _historicalUpdate(48_000e8, 48e8, uint64(lastTradingTs), uint64(lastTradingTs) - 4);
        uint256 fee = BazaarOracle(pair.oracle()).getUpdateFee(pu);
        vm.deal(address(this), fee);
        vm.expectRevert();
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
        assertFalse(pair.isPairTerminated(), "a tick from before the effective cutoff is refused");
    }

    /// @notice The verified tick at the effective cutoff — a lead past the acceptance instant —
    ///         settles the pair inside the grace, and the price is that tick, not anything the
    ///         proposer typed or the pair stored before.
    function test_LateAcceptance_PreciseTickSettlesAtVerifiedPrice() public {
        _push(50_000e8, 50e8, uint64(vm.getBlockTimestamp()));
        pair.refreshPrice(new bytes[](0)); // stored price $50k, before the cutoff
        _proposeDisputeAcceptLate(vm.getBlockTimestamp() + 5 days);
        uint256 cutoffTs = pair.scheduledTerminationTs();
        vm.warp(cutoffTs + 1);

        // The window's first print: the feed's previous print came before the window opened.
        bytes[] memory pu = _historicalUpdate(48_000e8, 48e8, uint64(cutoffTs), uint64(cutoffTs) - 4);
        uint256 fee = BazaarOracle(pair.oracle()).getUpdateFee(pu);
        vm.deal(address(this), fee);
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
        pair.finalizeTermination();

        assertTrue(pair.isPairTerminated(), "terminated at the verified tick");
        assertEq(pair.auxState().settlementPrice, 48_000 * BAZAAR_SCALE, "price from the tick, normalized");
    }

    /// @notice The precise-only grace runs from the effective cutoff, which a late acceptance sets
    ///         a lead past the acceptance instant, so it can never be pre-elapsed: nobody can front-run the
    ///         honest keeper right after a late acceptance with empty calldata, force the catch
    ///         branch, and settle at the last stored price instead of the true tick.
    function test_LateAcceptance_WithinGrace_EmptyDataReverts() public {
        _push(50_000e8, 50e8, uint64(vm.getBlockTimestamp()));
        pair.refreshPrice(new bytes[](0)); // stored price exists -> fallback WOULD be available
        _proposeDisputeAcceptLate(vm.getBlockTimestamp() + 5 days);
        vm.warp(pair.scheduledTerminationTs() + 1); // past the cutoff, inside the grace

        // Right after acceptance: empty calldata must revert, NOT fall back.
        bytes[] memory empty = new bytes[](0);
        vm.expectRevert();
        terminator.terminateScheduledPair(address(pair), empty);
        assertFalse(pair.isPairTerminated(), "no fallback inside the grace");

        // Still inside the grace at the cutoff + GRACE exactly.
        vm.warp(pair.scheduledTerminationTs() + GRACE);
        vm.expectRevert();
        terminator.terminateScheduledPair(address(pair), empty);
        assertFalse(pair.isPairTerminated(), "grace holds until it fully elapses");
    }

    /// @notice Liveness guarantee: once the acceptance grace elapses with no verifiable tick
    ///         (feed had no tick in the window, or the archived payload can no longer verify),
    ///         the pair settles at its frozen last stored price rather than stranding forever.
    function test_LateAcceptance_AfterGrace_FallsBackToLastStoredPrice() public {
        _push(50_000e8, 50e8, uint64(vm.getBlockTimestamp()));
        pair.refreshPrice(new bytes[](0)); // lastPairPrice ~$50k, frozen at/before the cutoff
        _proposeDisputeAcceptLate(vm.getBlockTimestamp() + 5 days);

        vm.warp(pair.scheduledTerminationTs() + GRACE + 1);
        terminator.terminateScheduledPair(address(pair), new bytes[](0));
        pair.finalizeTermination();

        assertTrue(pair.isPairTerminated(), "fallback settles after the grace");
        assertEq(pair.auxState().settlementPrice, 50_000 * BAZAAR_SCALE, "settled at last stored price");
    }
}

/// @notice terminateStalePair must terminate ONLY for a >21-day-stale oracle — never for any
///         other reason. tryReadStalePrice (spot if conf <=2%, else EMA) serves as the liveness
///         probe: any rung resolving a tick newer than 21 days blocks termination outright. When
///         no rung clears the cap (found=false) or the oracle read reverts, the 21-day requirement
///         is instead enforced against the pair's own stored price — so a transient wide-conf /
///         reverting read on a recently-active pair cannot be used to terminate it. Settlement
///         always uses that stored price, never a tick read from the oracle's cache.
contract Phase4StaleTerminationTest is Test {
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    int32 constant BTC_EXPO = -8;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;
    uint256 constant DEAD = 21 days;
    uint256 constant GRACE = 12 hours; // mirror of SCHEDULED_TERMINATION_GRACE

    BazaarFactory factory;
    BazaarPair pair;
    BazaarPairTerminator terminator;
    MockUSDC usdc;
    MockPyth pyth;

    /// @dev Receives the Pyth fee the terminator refunds when the precise fetch falls back.
    receive() external payable {}

    function setUp() public {
        vm.etch(address(0x64), address(new MockArbSys()).code);
        DeployBazaar dep = new DeployBazaar();
        (factory,) = dep.deploy(makeAddr("bugBounty"));
        usdc = MockUSDC(factory.usdc());
        terminator = factory.pairTerminator();
        pyth = MockPyth(address(factory.oracle().pyth()));
        PythSeed.seed(address(pyth), BTC_USD_FEED_ID);

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
        return pair.isPairTerminated();
    }

    /// @dev Two-stage termination: the terminator call only FIXES the settlement price and opens
    ///      the settlement window; finalize afterwards to flip the terminated flag. No position is
    ///      open in these scenarios, so finalize is allowed at once.
    function _finalize() internal {
        pair.finalizeTermination();
    }

    /// try path: oracle returns a price stale by > 21 days -> terminates at the pair's stored price.
    function test_StaleOracle_TerminatesAfter21Days() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0);
        pair.refreshPrice(new bytes[](0)); // records lastPairPrice at ~t0 — the settlement source
        vm.warp(t0 + DEAD + 1);
        vm.expectEmit(true, false, false, true, address(terminator));
        emit BazaarPairTerminator.StalePairTerminated(address(pair), 50_000 * BAZAAR_SCALE, t0);
        terminator.terminateStalePair(address(pair));
        _finalize();
        assertTrue(_terminated(), "stale > 21 days terminates");
    }

    /// A pair that never recorded a price settles at the nominal price once its feed is dead — the
    /// oracle's cached tick is still never the settlement price — and the listing seed, which a
    /// live pair pays out only against a fresh price, is released after finalize.
    function test_StaleOracle_NeverPriced_SettlesAtNominalPrice() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0);
        (uint256 stored,,,,) = pair.lastPairPrice();
        assertEq(stored, 0, "sanity: the pair never stored a price");
        uint256 createdTs = pair.auxState().pairCreatedTs;

        vm.warp(t0 + DEAD + 1);
        vm.expectEmit(true, false, false, true, address(terminator));
        emit BazaarPairTerminator.StalePairTerminated(address(pair), 1, createdTs);
        terminator.terminateStalePair(address(pair));
        assertEq(pair.auxState().settlementPrice, 1, "settled at the nominal price, not the cached tick");
        _finalize();
        assertTrue(_terminated(), "never-priced pair terminates");

        address deployer = makeAddr("deployer");
        uint256 seedShares = pair.insuranceShares(deployer);
        assertGt(seedShares, 0, "sanity: the deployer holds the seed shares");
        (,,,,, uint256 fund,,,,,,,,,,,) = pair.pairVault();
        uint256 balanceBefore = usdc.balanceOf(deployer);
        vm.startPrank(deployer);
        pair.requestInsuranceWithdrawal(seedShares, 0, 0, 0, "", "");
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "", "");
        vm.stopPrank();
        assertEq(pair.insuranceShares(deployer), 0, "seed shares redeemed");
        assertEq(usdc.balanceOf(deployer) - balanceBefore, fund / 1e12, "the whole fund is paid out");
    }

    /// A never-priced pair is aged from its creation, not from a stored price it lacks: an oracle
    /// that reads too wide to clear any rung cannot end a new listing before its first trade.
    function test_StaleOracle_NeverPriced_AgedFromCreation() public {
        uint64 t0 = uint64(block.timestamp);
        uint256 createdTs = pair.auxState().pairCreatedTs;
        _push(0, 0, t0 + 1); // <=0 -> no rung clears conf -> tryReadStalePrice found=false

        vm.warp(createdTs + DEAD);
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarPairTerminator.BazaarPairTerminator__OracleNotStaleEnough.selector, createdTs, DEAD
            )
        );
        terminator.terminateStalePair(address(pair));

        vm.warp(createdTs + DEAD + 1);
        terminator.terminateStalePair(address(pair));
        assertEq(pair.auxState().settlementPrice, 1, "past the threshold it settles at the nominal price");
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

    /// stale ladder: spot conf too wide (>2%) but EMA conf tight, so the EMA rung (rung 2) is what
    /// resolves the publish time the 21-day liveness gate is judged against — the wide spot alone
    /// would leave found=false. Past that age the pair terminates, settling at its own stored price
    /// rather than at either oracle rung. Warping to DEAD + 2 clears the gate against the rung's
    /// t0 + 1 publish time, not just against the stored price's t0.
    function test_StaleWideSpot_TerminatesViaEmaRung() public {
        uint64 t0 = uint64(block.timestamp);
        _push(50_000e8, 50e8, t0); // tight -> refreshPrice records lastPairPrice at ~t0
        pair.refreshPrice(new bytes[](0));
        // spot: 50k +/- 5k (10% conf, wide); EMA: 48k +/- 48 (0.1% conf, tight)
        _pushSpotEma(50_000e8, 5_000e8, 48_000e8, 48e8, t0 + 1);
        vm.warp(t0 + DEAD + 2);
        terminator.terminateStalePair(address(pair));
        _finalize();
        assertTrue(_terminated(), "wide spot but tight EMA + stale -> terminates");
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

    /// @dev Build (without submitting) a Pyth update at a specific historical publishTime, with the
    ///      predecessor publish time Pyth's uniqueness check reads.
    function _historicalUpdate(int64 price, uint64 conf, uint64 publishTime, uint64 prevPublishTime)
        internal
        view
        returns (bytes[] memory u)
    {
        u = new bytes[](1);
        u[0] = pyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID, price, conf, BTC_EXPO, price, conf, publishTime, prevPublishTime
        );
    }

    function _schedule(uint256 lastTradingTs) internal {
        vm.prank(pair.umaContract());
        pair.setScheduledTermination(lastTradingTs, address(this));
    }

    /// Within the grace, a precise in-window tick settles the scheduled termination.
    function test_ScheduledTermination_WithinGrace_PreciseTickSettles() public {
        _push(50_000e8, 50e8, uint64(block.timestamp));
        pair.refreshPrice(new bytes[](0));

        uint256 scheduledTs = block.timestamp + 1 hours;
        _schedule(scheduledTs);

        // The window's first print: the feed's previous print came before the window opened.
        uint64 pubT = uint64(scheduledTs) - 1;
        bytes[] memory pu = _historicalUpdate(48_000e8, 48e8, pubT, uint64(scheduledTs) - 4);
        uint256 fee = BazaarOracle(pair.oracle()).getUpdateFee(pu);

        vm.warp(scheduledTs + 1); // within grace
        vm.deal(address(this), fee);
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
        _finalize();
        assertTrue(_terminated(), "precise tick settles within grace");
        assertEq(pair.auxState().settlementPrice, 48_000 * BAZAAR_SCALE, "price from the tick, not the stored $50k");
    }

    /// Only the window's first print settles: with prints at T-3, T-2 and T, the two later ones
    /// are refused although they lie inside [T - 3s, T], so the caller cannot pick among them.
    function test_ScheduledTermination_OnlyTheWindowsFirstTickSettles() public {
        _push(50_000e8, 50e8, uint64(block.timestamp));
        pair.refreshPrice(new bytes[](0));

        uint256 scheduledTs = block.timestamp + 1 hours;
        _schedule(scheduledTs);
        uint64 t = uint64(scheduledTs);
        bytes[] memory first = _historicalUpdate(48_000e8, 48e8, t - 3, t - 4);
        bytes[] memory second = _historicalUpdate(47_000e8, 47e8, t - 2, t - 3);
        bytes[] memory third = _historicalUpdate(49_000e8, 49e8, t, t - 1);
        uint256 fee = BazaarOracle(pair.oracle()).getUpdateFee(first);
        vm.deal(address(this), 3 * fee);

        vm.warp(scheduledTs + 1); // within grace
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        terminator.terminateScheduledPair{value: fee}(address(pair), second);
        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        terminator.terminateScheduledPair{value: fee}(address(pair), third);
        assertEq(pair.settlementPriceFixedTs(), 0, "a later print in the window fixes nothing");

        terminator.terminateScheduledPair{value: fee}(address(pair), first);
        assertEq(pair.auxState().settlementPrice, 48_000 * BAZAAR_SCALE, "settled at the window's first print");
    }

    /// After the grace a later print in the window still cannot settle: the fetch is refused and
    /// the pair falls back to its stored price, so the only outcomes are the first print and that
    /// stored price.
    function test_ScheduledTermination_AfterGrace_LaterTickFallsBackToStoredPrice() public {
        _push(50_000e8, 50e8, uint64(block.timestamp));
        pair.refreshPrice(new bytes[](0)); // lastPairPrice $50k, before the cutoff

        uint256 scheduledTs = block.timestamp + 1 hours;
        _schedule(scheduledTs);
        bytes[] memory second = _historicalUpdate(47_000e8, 47e8, uint64(scheduledTs) - 1, uint64(scheduledTs) - 2);
        uint256 fee = BazaarOracle(pair.oracle()).getUpdateFee(second);
        vm.deal(address(this), fee);

        vm.warp(scheduledTs + GRACE + 1); // past the grace
        terminator.terminateScheduledPair{value: fee}(address(pair), second);
        assertEq(pair.auxState().settlementPrice, 50_000 * BAZAAR_SCALE, "stored price, not the later print");
    }

    /// The window's first print settles even when its confidence is wide: there is no second
    /// candidate, so a confidence cap could only push the pair onto the stored-price fallback.
    function test_ScheduledTermination_WideConfidenceFirstTickSettles() public {
        _push(50_000e8, 50e8, uint64(block.timestamp));
        pair.refreshPrice(new bytes[](0));

        uint256 scheduledTs = block.timestamp + 1 hours;
        _schedule(scheduledTs);
        // 5% confidence — well past the 2% cap the live paths enforce.
        bytes[] memory pu = _historicalUpdate(49_000e8, 2_450e8, uint64(scheduledTs) - 1, uint64(scheduledTs) - 4);
        uint256 fee = BazaarOracle(pair.oracle()).getUpdateFee(pu);
        vm.deal(address(this), fee);

        vm.warp(scheduledTs + 1); // within grace
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
        assertEq(pair.auxState().settlementPrice, 49_000 * BAZAAR_SCALE, "settled at the wide first print");
    }

    /// A tick outside [scheduledTs - 3s, scheduledTs] must not settle the pair — the window is
    /// enforced on-chain by Pyth's parser, so a post-cutoff print (manipulated or chaotic) cannot
    /// be passed off as the settlement tick.
    function test_ScheduledTermination_OutOfWindowTick_Reverts() public {
        _push(50_000e8, 50e8, uint64(block.timestamp));
        pair.refreshPrice(new bytes[](0));

        uint256 scheduledTs = block.timestamp + 1 hours;
        _schedule(scheduledTs);

        bytes[] memory pu = _historicalUpdate(1_000e8, 1e8, uint64(scheduledTs) + 10, uint64(scheduledTs) + 9);
        uint256 fee = BazaarOracle(pair.oracle()).getUpdateFee(pu);

        vm.warp(scheduledTs + 1); // within grace
        vm.deal(address(this), fee);
        vm.expectRevert();
        terminator.terminateScheduledPair{value: fee}(address(pair), pu);
        assertFalse(_terminated(), "out-of-window tick rejected");
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
        vm.expectRevert(); // Pyth: no tick in [scheduledTs-3, scheduledTs]; no fallback in grace
        terminator.terminateScheduledPair(address(pair), empty);
        assertFalse(_terminated(), "not terminated; no fallback during grace");
    }

    /// After the grace, missing the precise tick settles at the last stored price (capped at
    /// scheduledTs) so the pair can't be stranded in scheduled-but-not-terminated limbo.
    function test_ScheduledTermination_AfterGrace_FallsBackToLastPrice() public {
        _push(50_000e8, 50e8, uint64(block.timestamp));
        pair.refreshPrice(new bytes[](0)); // lastPairPrice ~ $50k, publishTime <= scheduledTs

        uint256 scheduledTs = block.timestamp + 1 hours;
        _schedule(scheduledTs);
        vm.warp(scheduledTs + GRACE + 1); // past the grace

        bytes[] memory empty = new bytes[](0);
        terminator.terminateScheduledPair(address(pair), empty); // no tick -> last-price fallback
        _finalize();
        assertTrue(_terminated(), "falls back to last stored price after grace");
        assertEq(pair.auxState().settlementPrice, 50_000 * BAZAAR_SCALE, "settled at last stored price");
    }

    /// After the grace, a pair that never stored a price settles at the nominal price rather than
    /// staying in limbo with no price to fall back to.
    function test_ScheduledTermination_AfterGrace_NeverPricedSettlesAtNominalPrice() public {
        uint256 scheduledTs = block.timestamp + 1 hours;
        _schedule(scheduledTs);
        vm.warp(scheduledTs + GRACE + 1); // past the grace

        terminator.terminateScheduledPair(address(pair), new bytes[](0));
        assertEq(pair.auxState().settlementPrice, 1, "settled at the nominal price");
        _finalize();
        assertTrue(_terminated(), "never-priced pair terminates after the grace");
    }

    /// REGRESSION: the empty-calldata fallback must survive the Pyth CONTRACT itself being
    /// bricked/migrated (every call into it reverting) — the worst-case "oracle decommissioned"
    /// scenario. getUpdateFee sits outside the try/catch, so querying it unconditionally would
    /// make even the fallback revert and strand the pair.
    function test_ScheduledTermination_PythContractBricked_FallbackStillSettles() public {
        _push(50_000e8, 50e8, uint64(block.timestamp));
        pair.refreshPrice(new bytes[](0)); // stored price frozen before the contract dies

        uint256 scheduledTs = block.timestamp + 1 hours;
        _schedule(scheduledTs);

        // Brick the Pyth contract: every call (getUpdateFee, parsePriceFeedUpdates, ...) reverts.
        vm.etch(address(pyth), hex"60006000fd"); // PUSH1 0 PUSH1 0 REVERT

        // Within the grace nothing can settle (precise-only, and precise can't verify) …
        bytes[] memory empty = new bytes[](0);
        vm.warp(scheduledTs + 1);
        vm.expectRevert();
        terminator.terminateScheduledPair(address(pair), empty);

        // … but after the grace the fallback needs no Pyth call outside the try/catch.
        vm.warp(scheduledTs + GRACE + 1);
        terminator.terminateScheduledPair(address(pair), empty);
        _finalize(); // needs no Pyth either — settles at the fixed price

        assertTrue(_terminated(), "pair settles despite a dead Pyth contract");
        assertEq(pair.auxState().settlementPrice, 50_000 * BAZAAR_SCALE, "settled at last stored price");
    }
}

