// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";

/// @title InsuranceGuardsTest
/// @notice The insurance fund's drain-guards under a LIVE book (all previously dead in the suite):
///         OI-based withdrawal rate limits, the vote-lock, the ADL block, plus the insolvent-
///         withdrawal gate, the rung-4 principal haircut, and blocked-state deposit arms.
contract InsuranceGuardsTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant SLOT_TERMINATION_FLAGS = 29;
    uint256 constant SLOT_NORMAL_TERMINATION_PRICE = 64;
    uint256 constant SLOT_WINNERS_PAYOUT_BP = 66;
    uint256 constant SLOT_NORMAL_COLLATERAL_RATIO = 67;

    /// @dev Open a 1v1 BTC position (alice long / bob short at $50k) so the pair has live OI.
    function _openOI() internal {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 aL = _placeLimit(alice, true, 1 * BAZAAR_SCALE, 50_000 * BAZAAR_SCALE);
        uint256 bS = _placeLimit(bob, false, 1 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(aL), _one(bS), _empty(), _empty()), 10), 1, "OI opened");
    }

    function _requestAll(address user) internal returns (uint256 shares) {
        shares = pair.insuranceShares(user);
        vm.prank(user);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
    }

    function _execute(address user) internal {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        pair.executeInsuranceWithdrawal(pu, 0, 0, 0, "");
    }

    function _executeExpect(address user, bytes4 selector) internal {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        vm.expectRevert(selector);
        pair.executeInsuranceWithdrawal(pu, 0, 0, 0, "");
    }

    // ============================ OI-based rate limits ============================

    /// @notice Above the target ratio the period budget is 1% of OI ($1k on $100k OI). Pulling the
    ///         whole large deposit in one execution exceeds it and reverts — the above-target regime
    ///         is a cumulative period cap now, not an unbounded per-withdrawal cap.
    function test_rateLimit_aboveTarget_periodCapBlocksFullExit() public {
        _openOI(); // OI notional $100k -> above-target period cap = 1% = $1,000
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE); // fund ~ $34k -> ratio ~34% >> target
        _requestAll(carol);
        vm.warp(vm.getBlockTimestamp() + 20 days + 1);
        _executeExpect(carol, InsuranceVaultLib.InsuranceVaultLib__RateLimitExceeded.selector);
        assertGt(pair.insuranceShares(carol), 0, "shares retained after the blocked exit");
    }

    /// @notice A withdrawal inside the above-target period budget (1% of OI = $1k) executes normally.
    function test_rateLimit_aboveTarget_compliantWithdrawalSucceeds() public {
        _openOI();
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        // Request ~$400 of shares: comfortably below the above-target period cap of 1% x $100k = $1,000.
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(400 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + 20 days + 1);
        uint256 usdcBefore = usdc.balanceOf(carol);
        _execute(carol);
        assertGt(usdc.balanceOf(carol), usdcBefore, "compliant withdrawal paid out");
    }

    /// @notice REGRESSION: above target the period budget accrues across withdrawals — including
    ///         across separate (Sybil) accounts. Previously the above-target branch checked only a
    ///         per-withdrawal cap and never touched withdrawnThisPeriod, so two accounts could each
    ///         withdraw under the cap and collectively blow past the intended rate. Now the second
    ///         withdrawal that pushes the cumulative total over 1% of OI in the same period reverts.
    function test_rateLimit_aboveTarget_periodBudgetAccruesAcrossAccounts() public {
        _openOI(); // OI notional $100k
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        _depositInsurance(dave, 30_000 * BAZAAR_SCALE); // fund ~$64k, ratio ~64% >> target
        // Above-target period budget = max(1% OI $1k, 10% fund ~$6.4k) = ~$6.4k, cumulative.

        // Each requests ~4,000 shares (~$4.5k) — individually under the ~$6.4k budget, together over it.
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(4_000 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.prank(dave);
        pair.requestInsuranceWithdrawal(4_000 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + 20 days + 1);

        // Carol's withdrawal fits the fresh period budget and accrues into withdrawnThisPeriod.
        uint256 usdcBefore = usdc.balanceOf(carol);
        _execute(carol);
        assertGt(usdc.balanceOf(carol), usdcBefore, "first withdrawal within budget paid out");

        // Dave's withdrawal in the SAME 6h period pushes the cumulative total over the budget -> rejected.
        _executeExpect(dave, InsuranceVaultLib.InsuranceVaultLib__RateLimitExceeded.selector);
        assertGt(pair.insuranceShares(dave), 0, "dave's shares retained after the blocked exit");
    }

    /// @notice REGRESSION: a fund that dwarfs OI is NOT trapped behind the tiny 1%-of-OI cap. With
    ///         only $100 of OI and a large fund, the 10%-of-fund floor governs, so an LP can withdraw
    ///         far more than 1% of OI ($1) per period. A pure-1%-of-OI cap would have reverted this.
    function test_rateLimit_aboveTarget_tinyOI_fundFloorAllowsExit() public {
        // Tiny OI: 0.001 BTC each side @ ~$50k -> OI notional ~$100.
        _deposit(alice, 100 * BAZAAR_SCALE);
        _deposit(bob, 100 * BAZAAR_SCALE);
        uint256 aL = _placeLimit(alice, true, BAZAAR_SCALE / 1000, 50_000 * BAZAAR_SCALE);
        uint256 bS = _placeLimit(bob, false, BAZAAR_SCALE / 1000, 49_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(aL), _one(bS), _empty(), _empty()), 10), 1, "tiny OI opened");

        _depositInsurance(carol, 1_000 * BAZAAR_SCALE); // fund >> OI -> far above target

        // Withdraw 50 shares — many multiples of the 1%-of-OI cap ($1), but within the 10%-of-fund floor.
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(50 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + 20 days + 1);
        uint256 usdcBefore = usdc.balanceOf(carol);
        _execute(carol);
        assertGt(usdc.balanceOf(carol), usdcBefore, "fund-floor withdrawal paid out despite tiny OI");
    }

    /// @notice Below the target ratio the 6h period cap (0.5% of OI notional) binds: a withdrawal
    ///         exceeding it reverts.
    function test_rateLimit_belowTarget_periodCapBlocks() public {
        _openOI(); // OI notional $100k -> period cap = $500
        _depositInsurance(carol, 6_000 * BAZAAR_SCALE);
        _requestAll(carol);
        vm.warp(vm.getBlockTimestamp() + 20 days + 1);
        // Crush the fund so the ratio (0.9%) is below the 2% floor target, and carol's share
        // value (~$540) exceeds the $500 period cap.
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(900 * BAZAAR_SCALE);
        _executeExpect(carol, InsuranceVaultLib.InsuranceVaultLib__RateLimitExceeded.selector);
    }

    // ============================ vote-lock ============================

    /// @notice Shares voted into an active insurer-termination proposal cannot be withdrawn —
    ///         no exiting with the capital backing a live vote.
    function test_voteLock_blocksWithdrawalOfVotedShares() public {
        BazaarPairTerminator terminator = factory.pairTerminator();
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
        _requestAll(carol); // executable in [T0+20d, T0+23d]

        // Inside the execute window: propose + vote ALL shares -> they lock.
        vm.warp(vm.getBlockTimestamp() + 20 days + 1 hours);
        uint256 bond = 500 * USDC_SCALE;
        usdc.mint(carol, bond);
        vm.startPrank(carol);
        usdc.approve(address(terminator), bond);
        terminator.proposeInsurerTermination(address(pair));
        terminator.voteForInsurerTermination(address(pair), pair.insuranceShares(carol));
        vm.stopPrank();

        _executeExpect(carol, InsuranceVaultLib.InsuranceVaultLib__SharesLockedForVoting.selector);
        assertGt(pair.insuranceShares(carol), 0, "shares stay in the fund while voted");
    }

    /// @notice Voting only part of the balance leaves the unvoted remainder withdrawable.
    function test_voteLock_partialVoteLeavesRemainderWithdrawable() public {
        BazaarPairTerminator terminator = factory.pairTerminator();
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(5_000 * BAZAAR_SCALE, 0, 0, 0, "", "");

        vm.warp(vm.getBlockTimestamp() + 20 days + 1 hours);
        uint256 bond = 500 * USDC_SCALE;
        usdc.mint(carol, bond);
        vm.startPrank(carol);
        usdc.approve(address(terminator), bond);
        terminator.proposeInsurerTermination(address(pair));
        terminator.voteForInsurerTermination(address(pair), 4_000 * BAZAAR_SCALE); // 5k + 4k <= 10k
        vm.stopPrank();

        uint256 usdcBefore = usdc.balanceOf(carol);
        _execute(carol);
        assertGt(usdc.balanceOf(carol), usdcBefore, "unvoted remainder withdrawn");
        assertEq(pair.insuranceShares(carol), 5_000 * BAZAAR_SCALE, "voted shares remain");
    }

    // ============================ ADL block ============================

    /// @notice A pending ADL freezes insurance withdrawals — LPs cannot front-run the draw-down.
    function test_adlPending_blocksInsuranceWithdrawal() public {
        _depositInsurance(carol, 1_000 * BAZAAR_SCALE);
        _requestAll(carol);
        vm.warp(vm.getBlockTimestamp() + 20 days + 1);
        _stdstore.target(address(pair)).sig("adlPendingSince()").checked_write(vm.getBlockTimestamp());
        _executeExpect(carol, InsuranceVaultLib.InsuranceVaultLib__AdlBlocking.selector);
    }

    // ============================ insolvent-position withdrawal ============================

    /// @notice An underwater trader cannot pull collateral ahead of liquidation.
    function test_withdrawCollateral_insolventPositionBlocked() public {
        _setupInsolventAlice();
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        // equity floored to 0 ($10 collateral vs -$5 PnL rounding), minRequired = MMR x $5k notional
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralLib.CollateralLib__InsolventPositionBucket.selector, 0, 499_500000000000000000
            )
        );
        pair.withdrawCollateral(1 * BAZAAR_SCALE, pu, 0, 0, 0, "");
    }

    // ============================ rung-4 principal haircut ============================

    /// @notice The rung-4 haircut applies exactly ONCE to a user's whole balance on their first
    ///         post-termination withdrawal, and caps their total extraction at ratio x balance.
    function test_rung4Haircut_appliedOncePerUser() public {
        _deposit(alice, 10_000 * BAZAAR_SCALE);

        // Simulate a normal termination whose rung-4 pot only covers 75% of principal.
        bytes32 current = vm.load(address(pair), bytes32(SLOT_TERMINATION_FLAGS));
        vm.store(address(pair), bytes32(SLOT_TERMINATION_FLAGS), current | bytes32(uint256(1) << 16));
        vm.store(address(pair), bytes32(SLOT_NORMAL_TERMINATION_PRICE), bytes32(uint256(50_000 * BAZAAR_SCALE)));
        vm.store(address(pair), bytes32(SLOT_WINNERS_PAYOUT_BP), bytes32(uint256(10_000)));
        vm.store(address(pair), bytes32(SLOT_NORMAL_COLLATERAL_RATIO), bytes32(uint256(7_500)));

        // First withdrawal: haircut fires (10,000 -> 7,500), then pays the requested 1,000.
        uint256 before1 = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - before1, 1_000 * USDC_SCALE, "first withdrawal pays in full post-haircut");

        // Remaining claim is 6,500 — not 9,000: the haircut is not re-applied, but it already bit.
        vm.prank(alice);
        vm.expectRevert();
        pair.withdrawCollateral(7_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");

        uint256 before2 = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(6_500 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - before2, 6_500 * USDC_SCALE, "exact remainder withdrawable");
        assertEq(_posCollateral(alice), 0, "total extracted = 75% of principal");
    }

    // ============================ blocked-state deposits + request/execute negatives ============================

    /// @notice Deposits are refused on a terminated pair (collateral and insurance alike).
    function test_deposits_blockedAfterNormalTermination() public {
        address uma = pair.umaContract();
        vm.prank(uma);
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        pair.finalizeTermination();

        vm.startPrank(carol);
        usdc.approve(address(pair), 20 * USDC_SCALE);
        vm.expectRevert(abi.encodeWithSelector(CollateralLib.CollateralLib__DepositsAreBlocked.selector, false, true));
        pair.depositCollateral(1 * BAZAAR_SCALE, 0, 0, 0, "", "");

        // Above the $5 minimum so the terminated gate (not the minimum) is what fires.
        vm.expectRevert(InsuranceVaultLib.InsuranceVaultLib__PairTerminated.selector);
        pair.depositToInsurance(10 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @notice The scheduled-but-not-executed termination limbo also blocks deposits.
    function test_deposits_blockedInScheduledTerminationLimbo() public {
        _stdstore.target(address(pair)).sig("scheduledTerminationTs()").checked_write(vm.getBlockTimestamp() - 1);

        vm.startPrank(carol);
        usdc.approve(address(pair), 2 * USDC_SCALE);
        vm.expectRevert(CollateralLib.CollateralLib__PairScheduledForTermination.selector);
        pair.depositCollateral(1 * BAZAAR_SCALE, 0, 0, 0, "", "");

        vm.expectRevert();
        pair.depositToInsurance(1 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    // ============================ orphaned-fund lock ============================

    /// @dev Drive the fund into the orphaned state (share supply zero, balance nonzero) and
    ///      recapitalize: the deployer (sole seed LP) exits fully, fees "accrue" into the
    ///      share-less fund (storage write + real USDC so backing stays honest), then carol
    ///      deposits `amount`.
    function _orphanThenRecap(uint256 orphan, uint256 amount) internal {
        _requestAll(deployer);
        vm.warp(vm.getBlockTimestamp() + 20 days + 1);
        _execute(deployer);
        assertEq(pair.totalInsuranceShares(), 0, "share supply fully exited");

        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(orphan);
        usdc.mint(address(pair), orphan * USDC_SCALE / BAZAAR_SCALE);

        _depositInsurance(carol, amount);
    }

    /// @notice Fees/seized collateral accrued after every LP exited must not be captured by the
    ///         next depositor: the orphan is minted as permanently locked shares at address(0),
    ///         the depositor is priced 1:1 against their own contribution, and a full exit
    ///         returns exactly what they put in — the orphan stays behind as buffer.
    function test_orphanedFund_lockedNotCapturedByNextDepositor() public {
        uint256 orphan = 1_000 * BAZAAR_SCALE;
        uint256 amount = 100 * BAZAAR_SCALE;
        _orphanThenRecap(orphan, amount);

        assertEq(pair.insuranceShares(carol), amount, "depositor priced 1:1 against own contribution");
        assertEq(pair.insuranceShares(address(0)), orphan, "orphan minted as locked shares");
        assertEq(pair.totalInsuranceShares(), orphan + amount, "supply = orphan + deposit");
        assertEq(lens.getInsuranceDepositValue(address(pair), carol), amount, "carol's claim = her deposit only");

        // Full exit: carol gets back exactly her contribution; the orphan is unreachable.
        _requestAll(carol);
        vm.warp(vm.getBlockTimestamp() + 20 days + 1);
        uint256 usdcBefore = usdc.balanceOf(carol);
        _execute(carol);
        assertEq(usdc.balanceOf(carol) - usdcBefore, 100 * USDC_SCALE, "withdrew exactly her deposit");
        assertEq(pair.totalInsuranceShares(), orphan, "only locked shares remain");
        (,,,,, uint256 fund,,,,,,) = pair.pairVault();
        assertEq(fund, orphan, "orphan stays in the fund as buffer");
    }

    /// @notice REGRESSION (mulDiv hardening): at a recap-inflated share supply, a fair deposit
    ///         and the lens valuation must not panic on their uint256 intermediates
    ///         (amount x supply and shares x fund respectively). Pre-fix both computations
    ///         reverted with an arithmetic panic even though the fair results fit comfortably.
    function test_mulDiv_hugeShareSupply_depositAndLensSurvive() public {
        // A supply reachable only through repeated wipe+rescue cycles (1e58 shares) backed by
        // a healthy $10k fund. amount x supply = 1e78 > uint256 max -> raw math panicked.
        _stdstore.target(address(pair)).sig("totalInsuranceShares()").checked_write(uint256(1e58));
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(10_000 * BAZAAR_SCALE);

        _depositInsurance(carol, 100 * BAZAAR_SCALE);

        // shares = 1e20 x 1e58 / 1e22 = 1e56 — fair, and far under the uint192 lot cap.
        assertEq(pair.insuranceShares(carol), 1e56, "fair share count minted");
        // Lens valuation (raw shares x fund = 1e78) must survive too, pricing exactly $100.
        assertEq(
            lens.getInsuranceDepositValue(address(pair), carol),
            100 * BAZAAR_SCALE,
            "lens values the deposit at its contribution"
        );
    }

    // ============================ share-epoch reset ============================

    /// @dev One-transaction rescue: bad-debt wipe (fund -> 0 while shares exist), then a
    ///      single deposit. The deposit bumps the share epoch: pre-drain balances lazily
    ///      read as 0 and the supply restarts from the rescue amount alone — no holder
    ///      enumeration, no separate cleanup step.
    function _drainAndRescue(address rescuer, uint256 amount) internal {
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(uint256(0));
        _depositInsurance(rescuer, amount);
    }

    /// @notice The epoch reset replaces multiplicative recap dilution: supply equals the rescue
    ///         amount EXACTLY after every wipe+rescue cycle (no geometric growth, unbounded
    ///         cycles), the rescue is a single deposit, and each wiped generation reads as
    ///         zero everywhere — pair and lens.
    function test_shareEpoch_SupplyResetsExactly_WipedHoldersReadZero() public {
        _drainAndRescue(carol, 10_000 * BAZAAR_SCALE);
        assertEq(pair.totalInsuranceShares(), 10_000 * BAZAAR_SCALE, "supply == rescue amount, cycle 1");
        assertEq(pair.insuranceShares(carol), 10_000 * BAZAAR_SCALE, "rescuer owns it all");
        assertEq(pair.insuranceShares(deployer), 0, "seed LP generationally wiped");

        _drainAndRescue(dave, 7_000 * BAZAAR_SCALE);
        assertEq(pair.totalInsuranceShares(), 7_000 * BAZAAR_SCALE, "supply == rescue amount, cycle 2: no inflation");
        assertEq(pair.insuranceShares(carol), 0, "first rescuer wiped in turn");
        assertEq(pair.insuranceShares(dave), 7_000 * BAZAAR_SCALE, "second rescuer owns it all");

        assertEq(lens.getInsuranceDepositValue(address(pair), dave), 7_000 * BAZAAR_SCALE, "lens: live value");
        assertEq(lens.getInsuranceDepositValue(address(pair), carol), 0, "lens: wiped value is zero");
    }

    /// @notice A withdrawal request made before an epoch bump refers to a wiped stake: executing
    ///         it must revert (ExceedsShares) rather than burn the new generation's supply, and
    ///         the wiped holder has no insurer-vote power in the new epoch.
    function test_shareEpoch_StaleRequestCannotBurnNewSupply() public {
        _drainAndRescue(carol, 10_000 * BAZAAR_SCALE);
        _requestAll(carol); // requested in carol's epoch

        _drainAndRescue(dave, 10_000 * BAZAAR_SCALE); // bump: carol's stake is wiped

        vm.warp(vm.getBlockTimestamp() + 20 days + 1);
        _executeExpect(carol, InsuranceVaultLib.InsuranceVaultLib__ExceedsShares.selector);
        assertEq(pair.totalInsuranceShares(), 10_000 * BAZAAR_SCALE, "new-epoch supply untouched");
        assertEq(pair.getSharesAsOf(carol, uint64(vm.getBlockTimestamp())), 0, "no stale voting power");
    }

    /// @notice A fund drained to sub-$1 dust (not exactly 0) also triggers the epoch reset; the
    ///         dust is locked at address(0) so the rescuer is priced only against their own
    ///         contribution at an exact $1 share price.
    function test_shareEpoch_DustFundResetsAndLocksDustAsOrphan() public {
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(BAZAAR_SCALE / 2); // $0.50
        _depositInsurance(carol, 100 * BAZAAR_SCALE);

        assertEq(pair.insuranceShares(address(0)), BAZAAR_SCALE / 2, "dust locked at address(0), new epoch");
        assertEq(pair.insuranceShares(carol), 100 * BAZAAR_SCALE, "rescuer priced 1:1");
        assertEq(pair.totalInsuranceShares(), 100 * BAZAAR_SCALE + BAZAAR_SCALE / 2, "supply = deposit + dust");
        assertEq(lens.getInsuranceDepositValue(address(pair), carol), 100 * BAZAAR_SCALE, "carol's claim = her deposit");
    }

    /// @notice The insurer-termination vote denominator must exclude the locked orphan shares —
    ///         they can never vote, so counting them could deadlock the 60% threshold forever.
    function test_insurerVote_snapshotExcludesLockedOrphanShares() public {
        _orphanThenRecap(1_000 * BAZAAR_SCALE, 100 * BAZAAR_SCALE);

        BazaarPairTerminator terminator = factory.pairTerminator();
        uint256 bond = 500 * USDC_SCALE;
        usdc.mint(carol, bond);
        vm.startPrank(carol);
        usdc.approve(address(terminator), bond);
        terminator.proposeInsurerTermination(address(pair));
        vm.stopPrank();

        (,,,,, uint256 snapTotal,,) = terminator.insurerProposals(address(pair));
        assertEq(snapTotal, pair.insuranceShares(carol), "vote denominator counts live shares only");
    }

    /// @notice Request/execute negatives, with exact selectors.
    function test_withdrawalRequest_negatives() public {
        _depositInsurance(carol, 1_000 * BAZAAR_SCALE);

        vm.prank(carol);
        vm.expectRevert(InsuranceVaultLib.InsuranceVaultLib__ZeroShares.selector);
        pair.requestInsuranceWithdrawal(0, 0, 0, 0, "", "");

        uint256 tooMany = pair.insuranceShares(carol) + 1;
        vm.prank(carol);
        vm.expectRevert(InsuranceVaultLib.InsuranceVaultLib__ExceedsShares.selector);
        pair.requestInsuranceWithdrawal(tooMany, 0, 0, 0, "", "");

        // Execute with no request on file.
        _executeExpect(carol, InsuranceVaultLib.InsuranceVaultLib__NoWithdrawalRequest.selector);
    }
}
