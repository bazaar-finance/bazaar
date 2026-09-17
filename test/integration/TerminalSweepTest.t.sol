// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";

/// @title TerminalSweepTest
/// @notice Two-stage termination end to end. fixSettlementPrice pins the price and opens the
///         settlement window; permissionless settlement (through liquidate) marks every position
///         to it — a loser's loss leaves its collateral, a winner's profit registers as a claim,
///         losses beyond collateral tally as bad debt; finalizeTermination, allowed once open
///         interest is zero or 14 days after the fix, derives the total owed from the ledgers
///         and freezes the two payout ratios. Principal is senior, registered profits share what
///         remains at one ratio, and the insurance fund is the residual — so insurance absorbs
///         bad debt before any winner is cut.
contract TerminalSweepTest is IntegrationBase {
    uint256 constant ESCAPE = 14 days; // BazaarTypes.TERMINAL_SETTLEMENT_ESCAPE
    uint256 constant SWEEP_GRACE = 14 days; // BazaarTypes.INSURER_SWEEP_GRACE
    uint256 constant PAYOUT_TOL = 1e14; // $0.0001: mulDiv rounding plus 1e18 -> 1e6 payout truncation
    uint256 constant TIP = BAZAAR_SCALE / 10; // BazaarTypes.TERMINAL_SETTLEMENT_TIP

    function _fix(uint256 priceUsd) internal {
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(priceUsd * BAZAAR_SCALE);
    }

    /// @dev Terminal settlement reuses the liquidate() entry point once the price is fixed.
    function _settle(address u) internal returns (uint256) {
        return pair.liquidate(_arr1(u), new bytes[](0));
    }

    function _settleMany(address[] memory users) internal returns (uint256) {
        return pair.liquidate(users, new bytes[](0));
    }

    function _claimable(address who) internal view returns (uint256 owed) {
        (owed,) = pair.claimableFees(who);
    }

    function _two(address a, address b) internal pure returns (address[] memory u) {
        u = new address[](2);
        u[0] = a;
        u[1] = b;
    }

    function _bucket(address u)
        internal
        view
        returns (bool isLong, uint256 size, uint256 entryValue, uint256 collateral)
    {
        (isLong, size, entryValue, collateral,,,,,) = pair.positionBuckets(u);
    }

    function _ratios() internal view returns (uint256 principalBp, uint256 profitBp) {
        BazaarTypes.AuxState memory a = pair.auxState();
        return (a.terminalPrincipalRatioBp, a.terminalProfitRatioBp);
    }

    /// @dev Withdraw a user's entire terminal entitlement. A first 1-wei withdrawal settles a
    ///      still-open position inline and credits a registered claim into the bucket (it pays
    ///      0 USDC after truncation); the second pass drains the bucket.
    function _withdrawAll(address u) internal returns (uint256 total) {
        uint256 before = usdc.balanceOf(u);
        (, uint256 size,,) = _bucket(u);
        if (size > 0 || pair.terminalProfitClaim(u) > 0) {
            vm.prank(u);
            pair.withdrawCollateral(1, new bytes[](0), 0, 0, 0, "");
        }
        (,,, uint256 c) = _bucket(u);
        if (c > 0) {
            vm.prank(u);
            pair.withdrawCollateral(c, new bytes[](0), 0, 0, 0, "");
        }
        total = usdc.balanceOf(u) - before;
    }

    /// @dev The frozen profit ratio is basis-point granular, so up to 1 bp of the registered
    ///      claims cannot be distributed and stays with the insurers.
    function _assertInsuranceConsumed(string memory label) internal view {
        assertLe(_insuranceBal(), pair.auxState().terminalProfitClaims / 10_000 + 1, label);
    }

    /// @dev Redeem every insurance share `lp` holds. Post-finalize the cooldown and window gates
    ///      are exempt and, with the sweep complete, so is the sweep gate, so request and execute
    ///      run back to back.
    function _insurerExit(address lp) internal returns (uint256 received) {
        uint256 shares = pair.insuranceShares(lp);
        bytes[] memory pu = _priceAt(50_000); // build BEFORE the prank (mockPyth call consumes it)
        vm.prank(lp);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        pair.executeInsuranceWithdrawal(pu, 0, 0, 0, "");
        received = usdc.balanceOf(lp) - before;
    }

    // ============================ gating ============================

    /// @notice Finalize waits for the sweep, not for a clock: it reverts while any position is
    ///         open, whoever calls it, and is permissionless the moment the last one settles.
    function test_finalize_gatedOnSweep_thenPermissionless() public {
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.finalizeTermination();

        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(50_000);
        assertEq(pair.settlementPriceFixedTs(), vm.getBlockTimestamp(), "price fixed");
        assertFalse(pair.isPairTerminated(), "fixing is not termination");

        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.finalizeTermination();

        // Time alone does not open the gate short of the escape hatch.
        vm.warp(vm.getBlockTimestamp() + ESCAPE - 1 hours);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.finalizeTermination();

        // One side settled is not enough.
        assertEq(_settle(alice), 1, "alice settled");
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.finalizeTermination();

        assertEq(_settle(bob), 1, "bob settled");
        vm.prank(makeAddr("randomKeeper"));
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminated(), "finalized");
        assertEq(pair.auxState().settlementPrice, 50_000 * BAZAAR_SCALE, "settled at the fixed price");
    }

    /// @notice The escape hatch: 14 days after the fix, finalize proceeds with positions still
    ///         open, and those positions settle inline on their first withdrawal.
    function test_finalize_escapeHatch_afterFourteenDays() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(50_000);

        vm.warp(vm.getBlockTimestamp() + ESCAPE - 1);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.finalizeTermination();

        vm.warp(vm.getBlockTimestamp() + 2);
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminated(), "escape hatch finalized with open positions");
        assertEq(_posSize(alice), BAZAAR_SCALE, "alice still open");

        // Alice (long from $51k, settled at $50k) realizes her $1k loss on withdrawal.
        uint256 collBefore = _posCollateral(alice);
        uint256 received = _withdrawAll(alice);
        assertEq(_posSize(alice), 0, "settled inline");
        assertApproxEqAbs(received, (collBefore - 1_000 * BAZAAR_SCALE) / 1e12, 1, "collateral less the loss");
        _assertBooks("after escape-hatch inline settlement");
    }

    /// @notice fixSettlementPrice is terminator-only, single-shot, and stamps
    ///         scheduledTerminationTs so all limbo guards engage (insurer/stale paths).
    function test_fix_onlyUma_singleShot_stampsSchedule() public {
        vm.expectRevert(); // onlyUma
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);

        assertEq(pair.scheduledTerminationTs(), 0, "no schedule before fix");
        _fix(50_000);
        assertEq(pair.scheduledTerminationTs(), vm.getBlockTimestamp(), "scheduledTs stamped by fix");

        vm.prank(pair.umaContract());
        vm.expectRevert(BazaarPair.BazaarPair__AlreadyTerminated.selector);
        pair.fixSettlementPrice(40_000 * BAZAAR_SCALE);
    }

    /// @notice While the window is open every user-facing withdrawal is frozen; the freeze lifts
    ///         at finalize, which on a book with no open positions is immediate.
    function test_window_freezesWithdrawals_liftsAtFinalize() public {
        _deposit(alice, 1_000 * BAZAAR_SCALE); // flat user — no position
        _fix(50_000);

        vm.prank(alice);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.withdrawCollateral(1 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");

        vm.prank(deployer);
        vm.expectRevert(BazaarPair.BazaarPair__SweepWindowActive.selector);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "");

        // liquidate() while the window is open is the settlement entry point, not the live
        // engine: alice is flat (no position) so it settles 0 and returns without reverting.
        assertEq(pair.liquidate(_arr1(alice), new bytes[](0)), 0, "flat user: nothing to settle");

        pair.finalizeTermination();

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - before, 1_000 * USDC_SCALE, "freeze lifted at finalize");
    }

    // ============================ settlement is harmless accounting ============================

    /// @notice Settlement is permissionless, needs no price update or ETH, and never seizes: a
    ///         position with positive equity keeps that equity less the settler's tip, charged
    ///         like a fee and escrowed for the keeper. (0.1 BTC long, $10 collateral, ~$50,050
    ///         entry, settled at $50,040 -> $9 equity.)
    function test_settle_positiveEquity_keepsEquity() public {
        _setupInsolventAlice(); // bucket only; seed matching OI so the settlement decrement is exact
        vm.store(address(pair), bytes32(uint256(5)), bytes32(BAZAAR_SCALE / 10)); // pairVault.totalLongOI
        vm.store(address(pair), bytes32(uint256(7)), bytes32(uint256(5_005 * BAZAAR_SCALE))); // longWeightedEntrySum
        _fix(50_040);

        address keeper = makeAddr("terminalKeeper");
        uint256 keeperBefore = usdc.balanceOf(keeper);
        uint256 dBefore = _totalDeposited();
        uint256 iBefore = _insuranceBal();
        vm.prank(keeper);
        assertEq(_settle(alice), 1, "position settled");
        assertEq(usdc.balanceOf(keeper), keeperBefore, "the tip is escrowed, not pushed");
        assertEq(_claimable(keeper), TIP, "settler tipped");
        (, uint256 size,, uint256 remaining) = _bucket(alice);
        assertEq(size, 0, "position closed by settlement");
        assertEq(remaining, 9 * BAZAAR_SCALE - TIP, "equity kept, less the tip");
        assertEq(_totalDeposited(), dBefore - TIP, "the tip leaves the deposits ledger like a fee");
        assertEq(_insuranceBal(), iBefore, "a position with collateral funds its own tip");
        assertEq(pair.terminalProfitClaim(alice), 0, "a loser registers no claim");

        pair.finalizeTermination();
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(remaining, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - before, remaining / 1e12, "she withdraws the full remainder");
        vm.prank(keeper);
        pair.claimFees();
        assertEq(usdc.balanceOf(keeper) - keeperBefore, TIP / 1e12, "keeper pulls the tip");
    }

    /// @notice A deep-underwater position settles with no price update (dead-feed safe): its
    ///         collateral is consumed, the uncovered remainder is tallied as bad debt, and the
    ///         deposits ledger is left alone for finalize to derive from.
    function test_settle_negativeEquity_deadFeed_talliesBadDebt() public {
        _setupInsolventAlice(); // 0.1 long, $10 collateral, entry ~$50,050
        vm.store(address(pair), bytes32(uint256(5)), bytes32(BAZAAR_SCALE / 10));
        vm.store(address(pair), bytes32(uint256(7)), bytes32(uint256(5_005 * BAZAAR_SCALE)));
        vm.warp(vm.getBlockTimestamp() + 30 days); // feed long dead
        uint256 dBefore = _totalDeposited();
        uint256 iBefore = _insuranceBal();
        _fix(30_000); // equity = 10 - (5005 - 3000) = -1995

        assertEq(_settle(alice), 1, "settled at the fixed price, empty calldata"); // no ETH, no priceUpdate
        (, uint256 size,, uint256 collateral) = _bucket(alice);
        assertEq(size, 0, "bucket cleared");
        assertEq(collateral, 0, "collateral consumed by the loss");
        assertEq(pair.auxState().terminalBadDebt, 1_995 * BAZAAR_SCALE, "uncovered loss tallied as bad debt");
        assertEq(_totalDeposited(), dBefore, "settlement never touches the deposits ledger");
        assertEq(_insuranceBal(), iBefore - TIP, "nothing left to charge: insurance funds the settler's tip");
        assertEq(_claimable(address(this)), TIP, "settler tipped");
    }

    // ============================ end-to-end economics ============================

    /// @notice THE guarantee: a gap makes the loser deeply insolvent, insurance is consumed
    ///         first, and the winner's PRINCIPAL is fully paid while the profit shortfall is
    ///         taken at one ratio — no first-come drain, no ledger underflow.
    function test_e2e_insolventLoser_winnerPrincipalSafe_profitsProRata() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE); // 1 BTC, $51k entries, ~20k collateral each

        (,, uint256 aliceEntry, uint256 aliceColl) = _bucket(alice);
        _fix(23_000); // alice (long) loss ~28k >> her ~20k collateral: deep insolvency
        assertGt(aliceEntry - 23_000 * BAZAAR_SCALE, aliceColl, "setup: alice negative equity");

        assertEq(_settleMany(_two(alice, bob)), 2, "both settled");
        uint256 insuranceBefore = _insuranceBal();
        assertLt(insuranceBefore, 8_000 * BAZAAR_SCALE, "setup: bad debt exceeds the fund");

        pair.finalizeTermination();

        (uint256 principalBp, uint256 profitBp) = _ratios();
        assertEq(principalBp, 10_000, "principal fully covered");
        assertGt(profitBp, 8_000, "meaningful pro-rata ratio");
        assertLt(profitBp, 10_000, "profits cut only after insurance is gone");
        _assertInsuranceConsumed("insurance consumed before any winner is cut");

        // Winner (bob): full principal + 28k claim at the frozen ratio.
        uint256 cashBefore = usdc.balanceOf(address(pair));
        uint256 received = _withdrawAll(bob);
        assertGt(received, 20_000 * USDC_SCALE, "winner recovered principal PLUS profit");
        assertLe(received, cashBefore, "pot covered the withdrawal");
        _assertBooks("after winner exit");

        // Loser (alice) had negative equity -> zero collateral remains; nothing to withdraw.
        assertEq(_withdrawAll(alice), 0, "insolvent loser's collateral fully consumed by loss");
        assertApproxEqAbs(
            _cashBaz(), _insuranceBal() + _escrowTotal(), PAYOUT_TOL, "pot exhausted: only the bp residual is left"
        );
    }

    /// @notice Principal is senior: a loser who keeps some collateral is paid it in full even
    ///         while winners are pro-rated, because the shortfall is charged to profits only.
    function test_e2e_solventLoserWhole_whileWinnersProRated() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE); // alice long 1 BTC, bob short 1 BTC, $51k
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BAZAAR_SCALE / 5, 51_000 * BAZAAR_SCALE); // carol long 0.2 BTC
        _roll(2);
        _placeLimit(dave, false, BAZAAR_SCALE / 5, 49_000 * BAZAAR_SCALE); // dave short 0.2 BTC at carol's $51k

        // $80k: bob (short 1 BTC) loses 29k on ~20k -> bankrupt; dave (short 0.2) loses 5.8k and
        // keeps the rest; alice and carol win 29k and 5.8k.
        _fix(80_000);
        address[] memory all = new address[](4);
        all[0] = alice;
        all[1] = bob;
        all[2] = carol;
        all[3] = dave;
        assertEq(_settleMany(all), 4, "all settled");
        uint256 daveColl = _posCollateral(dave);
        assertApproxEqAbs(daveColl, 14_200 * BAZAAR_SCALE, 50 * BAZAAR_SCALE, "dave keeps collateral less his loss");

        pair.finalizeTermination();
        (uint256 principalBp, uint256 profitBp) = _ratios();
        assertEq(principalBp, 10_000, "principal senior");
        assertLt(profitBp, 10_000, "winners pro-rated");
        _assertInsuranceConsumed("insurance consumed first");

        assertEq(_withdrawAll(dave), daveColl / 1e12, "solvent loser paid his remainder in full");
        uint256 aliceGot = _withdrawAll(alice);
        uint256 carolGot = _withdrawAll(carol);
        assertGt(aliceGot, 20_000 * USDC_SCALE, "alice: principal plus part of her profit");
        assertGt(carolGot, 20_000 * USDC_SCALE, "carol: principal plus part of her profit");
        assertEq(_withdrawAll(bob), 0, "bankrupt loser gets nothing");
        assertApproxEqAbs(
            _cashBaz(), _insuranceBal() + _escrowTotal(), PAYOUT_TOL, "pot exhausted: only the bp residual is left"
        );
    }

    /// @notice Insurance is the residual: with a fund larger than the bad debt every trader is
    ///         made whole, and the LPs redeem exactly the fund less the bad debt (and the
    ///         bankrupt loser's settlement tip) afterwards.
    function test_e2e_insuranceCoversBadDebt_lpsRedeemResidual() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
        uint256 fundBefore = _insuranceBal();

        _fix(23_000); // alice bankrupt by ~8k (28k loss on ~20k collateral)
        assertEq(_settleMany(_two(alice, bob)), 2, "both settled");
        uint256 badDebt = pair.auxState().terminalBadDebt;
        assertGt(badDebt, 7_000 * BAZAAR_SCALE, "setup: real bad debt");
        assertLt(badDebt, fundBefore, "setup: fund covers it");
        uint256 bobPrincipal = _posCollateral(bob); // a winner's collateral is untouched by settlement
        uint256 bobClaim = pair.terminalProfitClaim(bob);

        pair.finalizeTermination();
        (uint256 principalBp, uint256 profitBp) = _ratios();
        assertEq(principalBp, 10_000, "principal whole");
        assertEq(profitBp, 10_000, "profits whole");
        assertEq(_insuranceBal(), fundBefore - badDebt - TIP, "fund pays the bad debt and the bankrupt loser's tip");

        uint256 bobGot = _withdrawAll(bob);
        assertApproxEqAbs(bobGot, (bobPrincipal + bobClaim) / 1e12, 1, "winner made whole: principal plus full claim");
        uint256 lpTotal = _insurerExit(carol) + _insurerExit(deployer);
        assertApproxEqAbs(lpTotal, (fundBefore - badDebt - TIP) / 1e12, 1, "LPs redeem the residual");
        assertApproxEqAbs(_cashBaz(), _escrowTotal(), PAYOUT_TOL, "pot exhausted");
    }

    /// @notice Unsettled winner past the escape hatch: finalize counted their profit inside
    ///         principal, and their first withdrawal realizes it in full.
    function test_e2e_unsettledWinner_escapeHatch_selfSettlesAtWithdraw() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(60_000); // alice (long, $51k entry) wins ~9k; solvent (bob's collateral covers it)

        // Nobody settles anyone; the escape hatch finalizes.
        vm.warp(vm.getBlockTimestamp() + ESCAPE + 1);
        pair.finalizeTermination();

        assertEq(_settle(bob), 1, "loser settled after finalize: loss leaves his bucket");
        uint256 received = _withdrawAll(alice);
        assertGt(received, 28_000 * USDC_SCALE, "principal + profit realized inline");
        _assertBooks("after unsettled winner self-settles");
    }

    /// @notice Escape hatch with a bankrupt position nobody settled, insurance ample: finalize
    ///         understated bad debt, so settling it afterwards adds the shortfall back to the
    ///         principal ledger and charges the insurers' residual — the winner is still whole.
    function test_escapeHatch_unsettledBankrupt_chargedToInsuranceResidual() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
        uint256 fundBefore = _insuranceBal();

        _fix(23_000); // alice bankrupt by ~8k
        assertEq(_settle(bob), 1, "only the winner settles");
        vm.warp(vm.getBlockTimestamp() + ESCAPE + 1);
        pair.finalizeTermination();
        (, uint256 profitBp) = _ratios();
        assertEq(profitBp, 10_000, "fund covers the claim");
        uint256 residualBefore = _insuranceBal();

        // Settling alice post-finalize registers her shortfall against the residual.
        uint256 dBefore = _totalDeposited();
        assertEq(_settle(alice), 1, "bankrupt straggler settled");
        uint256 shortfall = pair.auxState().terminalBadDebt;
        assertGt(shortfall, 7_000 * BAZAAR_SCALE, "shortfall recorded");
        assertEq(_totalDeposited(), dBefore + shortfall, "principal ledger corrected upward");
        assertEq(_insuranceBal(), residualBefore - shortfall - TIP, "charged to the insurers' residual, then the tip");
        assertEq(_insuranceBal(), fundBefore - shortfall - TIP, "net: the fund paid the bad debt and the tip");
        assertEq(_claimable(address(this)), 2 * TIP, "tipped for the winner (his collateral) and the straggler");

        uint256 bobGot = _withdrawAll(bob);
        assertGt(bobGot, 40_000 * USDC_SCALE, "winner whole: principal + 28k claim");
        assertApproxEqAbs(_cashBaz(), _insuranceBal() + _escrowTotal(), PAYOUT_TOL, "books settled");
    }

    /// @notice Escape hatch with a bankrupt position nobody settled and insurance too small:
    ///         the pot is paid out in full, and the unfunded remainder lands on the last
    ///         withdrawal instead of being stranded.
    function test_escapeHatch_unsettledBankrupt_fundTooSmall_lastWithdrawalShort() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(23_000);
        assertEq(_settle(bob), 1, "only the winner settles");
        vm.warp(vm.getBlockTimestamp() + ESCAPE + 1);
        pair.finalizeTermination();

        uint256 dBefore = _totalDeposited();
        uint256 residualBefore = _insuranceBal();
        assertEq(_settle(alice), 1, "bankrupt straggler settled after finalize");
        assertEq(_insuranceBal(), 0, "residual exhausted by the shortfall");
        assertEq(_claimable(address(this)), TIP, "only the winner's tip: an exhausted residual pays none");
        // The ledger grows only by what insurance funded; the unfunded remainder is tallied, not
        // credited, so the books never claim more cash than the pot holds.
        assertEq(_totalDeposited(), dBefore + residualBefore, "ledger credited only the funded part");
        assertGt(pair.auxState().terminalBadDebt, residualBefore, "unfunded remainder stays in the tally");
        assertApproxEqAbs(
            _totalDeposited() + _insuranceBal() + _escrowTotal() + pair.terminalProfitClaim(bob),
            _cashBaz(),
            PAYOUT_TOL,
            "books balance against cash after the straggler"
        );

        // Bob's entitlement exceeds the pot; he can draw the whole pot and no more.
        uint256 pot = _cashBaz() - _escrowTotal();
        vm.prank(bob);
        pair.withdrawCollateral(1, new bytes[](0), 0, 0, 0, ""); // credits the claim
        (,,, uint256 entitled) = _bucket(bob);
        assertGt(entitled, pot, "entitlement exceeds the pot");
        vm.prank(bob);
        pair.withdrawCollateral(pot, new bytes[](0), 0, 0, 0, "");
        assertApproxEqAbs(_cashBaz(), _escrowTotal(), PAYOUT_TOL, "pot fully paid out");
        vm.prank(bob);
        vm.expectRevert();
        pair.withdrawCollateral(entitled - pot, new bytes[](0), 0, 0, 0, "");
    }

    /// @notice After an escape-hatch finalize the insurers' exit waits for the sweep: while a
    ///         position finalize did not wait for is still open, the redemption reverts with the
    ///         timestamp the grace would release it at; settling the straggler releases it at
    ///         once, and the residual it then redeems against has already funded the shortfall.
    function test_escapeHatch_insurerExit_waitsForStraggler_releasedBySettlement() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);

        _fix(23_000); // alice bankrupt by ~8k
        assertEq(_settle(bob), 1, "only the winner settles");
        uint256 fixTs = pair.settlementPriceFixedTs();
        vm.warp(fixTs + ESCAPE + 1);
        pair.finalizeTermination();
        uint256 residualBefore = _insuranceBal();

        uint256 shares = pair.insuranceShares(carol);
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(
                InsuranceVaultLib.InsuranceVaultLib__SweepIncomplete.selector, fixTs + ESCAPE + SWEEP_GRACE
            )
        );
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "");

        // Settling the straggler charges the residual and opens the gate in the same block.
        assertEq(_settle(alice), 1, "bankrupt straggler settled");
        uint256 shortfall = pair.auxState().terminalBadDebt;
        assertGt(shortfall, 7_000 * BAZAAR_SCALE, "shortfall recorded");
        assertEq(
            _insuranceBal(), residualBefore - shortfall - TIP, "residual charged and settler tipped before any LP exits"
        );
        uint256 before = usdc.balanceOf(carol);
        vm.prank(carol);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "");
        uint256 got = usdc.balanceOf(carol) - before;
        assertGt(got, 0, "redeemed once the sweep completed");
        assertLt(got, 10_000 * USDC_SCALE, "priced against the residual net of the shortfall");

        // The winner is whole: no LP left ahead of the shortfall.
        uint256 bobGot = _withdrawAll(bob);
        assertGt(bobGot, 40_000 * USDC_SCALE, "winner whole: principal + 28k claim");
        assertApproxEqAbs(_cashBaz(), _insuranceBal() + _escrowTotal(), PAYOUT_TOL, "books settled");
    }

    /// @notice The sweep gate is bounded: with the straggler still open, the redemption is
    ///         released once the grace has elapsed beyond the escape hatch, so an unsettled
    ///         position can delay the insurers' exit but never strand it.
    function test_escapeHatch_insurerExit_releasedByGrace() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);

        _fix(23_000);
        assertEq(_settle(bob), 1, "only the winner settles");
        uint256 fixTs = pair.settlementPriceFixedTs();
        vm.warp(fixTs + ESCAPE + 1);
        pair.finalizeTermination();

        uint256 shares = pair.insuranceShares(carol);
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");

        uint256 releaseTs = fixTs + ESCAPE + SWEEP_GRACE;
        vm.warp(releaseTs - 1);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__SweepIncomplete.selector, releaseTs)
        );
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "");

        vm.warp(releaseTs);
        (, uint256 size,,) = _bucket(alice);
        assertGt(size, 0, "straggler still open");
        uint256 before = usdc.balanceOf(carol);
        vm.prank(carol);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "");
        assertGt(usdc.balanceOf(carol) - before, 0, "released by the grace alone");
    }

    /// @notice Solvency invariant across a fuzzed settlement price: the pot covers every payout,
    ///         and after every trader exits the cash left is exactly the insurers' residual.
    function testFuzz_solvencyHolds(uint256 priceUsd) public {
        priceUsd = bound(priceUsd, 1_000, 200_000);
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(priceUsd);
        _settleMany(_two(alice, bob));
        pair.finalizeTermination();
        _assertBooks("post-finalize solvency");
        _withdrawAll(alice);
        _withdrawAll(bob);
        assertApproxEqAbs(_cashBaz(), _insuranceBal() + _escrowTotal(), PAYOUT_TOL, "cash left == residual");
    }

    /// @notice A winner with no collateral registers its full profit as a claim, untouched by
    ///         the settler's tip (insurance funds it, there being no collateral), and is paid at
    ///         the same frozen ratio as every winner.
    function test_settle_zeroCollateralWinner_registersFullClaim() public {
        // Real book: carol (long 1 BTC) wins big, bob (short) is left deeply insolvent at the
        // settlement price, so the frozen profit ratio lands strictly below 100%.
        _openPosition(bob, carol, false, BAZAAR_SCALE);
        // Zero-collateral winner: 0.1 BTC long at $50,050 entry with no deposit behind it.
        _writePosition(alice, true, BAZAAR_SCALE / 10, 5_005 * BAZAAR_SCALE);
        // Seed the OI aggregates for the synthetic bucket so settlement's decrement is exact.
        vm.store(
            address(pair),
            bytes32(uint256(5)),
            bytes32(uint256(vm.load(address(pair), bytes32(uint256(5)))) + BAZAAR_SCALE / 10)
        ); // pairVault.totalLongOI
        vm.store(
            address(pair),
            bytes32(uint256(7)),
            bytes32(uint256(vm.load(address(pair), bytes32(uint256(7)))) + 5_005 * BAZAAR_SCALE)
        ); // pairVault.longWeightedEntrySum

        _fix(80_000); // alice +$2,995; bob (short) loses ~$29k on ~$20k collateral
        _settleMany(_two(bob, carol));

        address keeper = makeAddr("terminalKeeper");
        uint256 iBefore = _insuranceBal();
        vm.prank(keeper);
        assertEq(pair.liquidate(_arr1(alice), new bytes[](0)), 1, "zero-collateral winner settled");
        assertEq(_claimable(keeper), TIP, "settler tipped");
        assertEq(_insuranceBal(), iBefore - TIP, "no collateral to charge: insurance funds the tip");
        assertEq(pair.terminalProfitClaim(alice), 2_995 * BAZAAR_SCALE, "full profit registered, untouched by the tip");

        pair.finalizeTermination();
        (, uint256 profitBp) = _ratios();
        assertGt(profitBp, 0, "ratio meaningful");
        assertLt(profitBp, 10_000, "underwater book: sub-100% frozen ratio");

        uint256 expected = 2_995 * BAZAAR_SCALE * profitBp / 10_000;
        assertApproxEqAbs(_withdrawAll(alice), expected / 1e12, 1, "claim paid at the frozen ratio");
        _assertBooks("after claim payout");
    }

    // ============================ settlement tip ============================

    /// @notice Settling someone else's position before finalize earns the tip from that
    ///         position's own collateral: the bucket and the deposits ledger drop together, so
    ///         the pot and the total owed fall by the same amount and the insurers' residual is
    ///         untouched — a position that can pay its own tip is never a drain on the fund.
    function test_settleTip_beforeFinalize_solvent_paidFromCollateral() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE); // ~20k collateral each, $51k entries
        _fix(50_000); // alice loses 1k, bob wins 1k: both solvent
        uint256 aliceColl = _posCollateral(alice);
        uint256 bobColl = _posCollateral(bob);
        uint256 dBefore = _totalDeposited();
        uint256 iBefore = _insuranceBal();
        uint256 escrowBefore = _escrowTotal();

        address keeper = makeAddr("terminalKeeper");
        vm.prank(keeper);
        assertEq(_settleMany(_two(alice, bob)), 2, "both settled by the keeper");
        assertEq(_claimable(keeper), 2 * TIP, "one tip per position settled");
        assertEq(_posCollateral(alice), aliceColl - 1_000 * BAZAAR_SCALE - TIP, "loser: the loss, then the tip");
        assertEq(_posCollateral(bob), bobColl - TIP, "winner: collateral pays the tip, profit stays a claim");
        assertEq(pair.terminalProfitClaim(bob), 1_000 * BAZAAR_SCALE, "claim untouched by the tip");
        assertEq(_totalDeposited(), dBefore - 2 * TIP, "ledger drops with the buckets, like a fee");
        assertEq(_insuranceBal(), iBefore, "insurance untouched");
        assertEq(_escrowTotal(), escrowBefore + 2 * TIP, "tips escrowed");

        pair.finalizeTermination();
        assertEq(_insuranceBal(), iBefore, "residual unaffected by collateral-funded tips");
        _assertBooks("after a tipped sweep");
        uint256 before = usdc.balanceOf(keeper);
        vm.prank(keeper);
        pair.claimFees();
        assertEq(usdc.balanceOf(keeper) - before, 2 * TIP / 1e12, "keeper pulls both tips");
    }

    /// @notice A position whose settlement leaves it nothing pays no tip itself: insurance
    ///         covers it, in full, and the deposits ledger is left alone.
    function test_settleTip_beforeFinalize_bankrupt_paidFromInsurance() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(23_000); // alice (long from $51k) loses 28k on ~20k collateral: bankrupt
        uint256 dBefore = _totalDeposited();
        uint256 iBefore = _insuranceBal();

        address keeper = makeAddr("terminalKeeper");
        vm.prank(keeper);
        assertEq(_settle(alice), 1, "bankrupt position settled");
        assertEq(_posCollateral(alice), 0, "collateral consumed by the loss");
        assertEq(_claimable(keeper), TIP, "settler tipped in full");
        assertEq(_insuranceBal(), iBefore - TIP, "insurance funds the whole tip");
        assertEq(_totalDeposited(), dBefore, "deposits ledger untouched");
    }

    /// @notice A position left with less than the tip pays what it has and insurance tops up
    ///         the rest: 0.1 BTC long from ~$50,050 with $10 collateral, settled at $49,950.50,
    ///         keeps $0.05 after its $9.95 loss.
    function test_settleTip_beforeFinalize_partialCollateral_insuranceTopsUp() public {
        _setupInsolventAlice();
        vm.store(address(pair), bytes32(uint256(5)), bytes32(BAZAAR_SCALE / 10)); // pairVault.totalLongOI
        vm.store(address(pair), bytes32(uint256(7)), bytes32(uint256(5_005 * BAZAAR_SCALE))); // longWeightedEntrySum
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(49_950 * BAZAAR_SCALE + BAZAAR_SCALE / 2);
        uint256 dBefore = _totalDeposited();
        uint256 iBefore = _insuranceBal();

        address keeper = makeAddr("terminalKeeper");
        vm.prank(keeper);
        assertEq(_settle(alice), 1, "settled");
        assertEq(_posCollateral(alice), 0, "the $0.05 left went to the tip");
        assertEq(_claimable(keeper), TIP, "settler tipped in full");
        assertEq(_totalDeposited(), dBefore - BAZAAR_SCALE / 20, "ledger charged the collateral half");
        assertEq(_insuranceBal(), iBefore - BAZAAR_SCALE / 20, "insurance topped up the other half");
    }

    /// @notice Settling your own position is free: no tip leaves the bucket, none leaves
    ///         insurance, none is credited.
    function test_settleTip_ownerSettlesSelf_free() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(50_000);
        uint256 aliceColl = _posCollateral(alice);
        uint256 dBefore = _totalDeposited();
        uint256 iBefore = _insuranceBal();

        vm.prank(alice);
        assertEq(_settle(alice), 1, "owner settled herself");
        assertEq(_posCollateral(alice), aliceColl - 1_000 * BAZAAR_SCALE, "only the loss left her bucket");
        assertEq(_claimable(alice), 0, "no tip");
        assertEq(_totalDeposited(), dBefore, "ledger untouched");
        assertEq(_insuranceBal(), iBefore, "insurance untouched");
    }

    /// @notice After finalize a solvent straggler pays nothing: finalize reserved its equity in
    ///         full, so settling it changes no ledger and earns no tip.
    function test_settleTip_afterFinalize_solventStraggler_free() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(50_000);
        vm.warp(vm.getBlockTimestamp() + ESCAPE + 1);
        pair.finalizeTermination();
        uint256 residual = _insuranceBal();
        uint256 dBefore = _totalDeposited();

        address keeper = makeAddr("terminalKeeper");
        vm.prank(keeper);
        assertEq(_settleMany(_two(alice, bob)), 2, "both stragglers settled");
        assertEq(_claimable(keeper), 0, "solvent stragglers pay no tip after finalize");
        assertEq(_insuranceBal(), residual, "residual untouched");
        assertEq(_totalDeposited(), dBefore, "principal ledger untouched");
        _assertBooks("after free post-finalize settlement");
    }

    /// @notice After finalize a bankrupt straggler's settlement is the one nobody is otherwise
    ///         paid for and the one the insurers' gate waits on, so it tips the settler from the
    ///         residual — after the shortfall is funded, and only from what is left.
    function test_settleTip_afterFinalize_bankruptStraggler_paidFromResidual() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _depositInsurance(carol, 10_000 * BAZAAR_SCALE);
        _fix(23_000); // alice bankrupt by ~8k
        vm.warp(vm.getBlockTimestamp() + ESCAPE + 1);
        pair.finalizeTermination();
        uint256 residualBefore = _insuranceBal();
        uint256 dBefore = _totalDeposited();

        address keeper = makeAddr("terminalKeeper");
        vm.prank(keeper);
        assertEq(_settle(alice), 1, "bankrupt straggler settled");
        uint256 shortfall = pair.auxState().terminalBadDebt;
        assertGt(shortfall, 7_000 * BAZAAR_SCALE, "shortfall recorded");
        assertEq(_claimable(keeper), TIP, "settler tipped");
        assertEq(_insuranceBal(), residualBefore - shortfall - TIP, "shortfall funded first, then the tip");
        assertEq(_totalDeposited(), dBefore + shortfall, "principal ledger gains only the funded shortfall");
        _assertBooks("after a tipped post-finalize settlement");
    }

    /// @notice A continuously traded pair whose feed has died: insurers exit after finalize with
    ///         no price update at all, because nothing post-termination depends on a price.
    function test_insurerExit_afterTermination_needsNoPrice() public {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _fix(50_000);
        _settleMany(_two(alice, bob));
        pair.finalizeTermination();
        uint256 residual = _insuranceBal();
        assertGt(residual, 0, "setup: residual to redeem");

        vm.warp(vm.getBlockTimestamp() + 30 days); // feed long dead: no fresh tick can be resolved
        uint256 shares = pair.insuranceShares(deployer);
        vm.prank(deployer);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
        uint256 before = usdc.balanceOf(deployer);
        vm.prank(deployer);
        pair.executeInsuranceWithdrawal(new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(deployer) - before, residual / 1e12, "sole LP redeems the whole residual");
    }

    // ============================ cash short of principal ============================

    /// @notice A books-vs-balance gap (cash below principal) is shared pro-rata on collateral:
    ///         the principal ratio drops, profits pay nothing, the insurers' claim is zero, and
    ///         the pot is exactly exhausted even when the insurer exits FIRST.
    function test_cashShortOfPrincipal_principalProRata_insuranceZero() public {
        // Flat principal depositor: D = 10,000. Insurance I = 4,000 (deployer's factory seed).
        _deposit(alice, 10_000 * BAZAAR_SCALE);
        assertEq(_insuranceBal(), 4_000 * BAZAAR_SCALE, "setup: seeded insurance fund");

        // An UNREGISTERED cash shortfall: USDC leaves the pair with no ledger deduction.
        // Cash 14,000 -> 7,500, below D = 10,000.
        vm.prank(address(pair));
        usdc.transfer(makeAddr("driftSink"), 6_500 * USDC_SCALE);

        _fix(50_000);
        pair.finalizeTermination();

        (uint256 principalBp, uint256 profitBp) = _ratios();
        assertEq(principalBp, 7_500, "principal ratio = cash / principal");
        assertEq(profitBp, 0, "no cash beyond principal for profits");
        assertEq(_insuranceBal(), 0, "insurers' claim zero when cash < principal");

        assertEq(_insurerExit(deployer), 0, "junior claim pays zero, even exiting first");

        // Principal draws the ENTIRE remaining pot at the uniform ratio: 10,000 nominal -> 7,500.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(10_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - aliceBefore, 7_500 * USDC_SCALE, "principal pays at the ratio");
        assertEq(usdc.balanceOf(address(pair)), 0, "pot exactly exhausted, no phantom claim left");
    }
}
