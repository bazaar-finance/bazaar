// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AdlInsuranceShortfallTest
/// @notice When an ADL'd winner's credit exceeds the insurance fund, the funded portion is paid
///         as the usual I → D transfer and the unpaid remainder is recorded as vault deficit.
///         The winner's position closes for its full size either way, so a dropped remainder
///         would erase a solvent trader's realized claim while every ledger check still
///         balanced. Pinned here:
///
///         - credited + deficit == owed PnL (nothing is silently discarded);
///         - the recorded deficit makes the same transaction's post-batch health check fix the
///           settlement price (Check 0), routing the shortfall into the settlement waterfall's
///           pro-rata sharing;
///         - the batch stops at the first shortfall instead of seizing later winners for zero
///           credit.
contract AdlInsuranceShortfallTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant MARK = 50_000; // BTC mark, whole dollars
    uint256 constant ESTATE_SIZE = 100 * BAZAAR_SCALE;
    uint256 constant ESTATE_COLLATERAL = 10 * BAZAAR_SCALE;
    uint256 constant WINNER_COLLATERAL = 10 * BAZAAR_SCALE;
    uint256 constant WINNER_SIZE = 1 * BAZAAR_SCALE;

    // ---------------------------- staging helpers ----------------------------

    /// @dev Stage a short winner: real collateral deposit (so the vault's USDC stays backed) and
    ///      a stdstore-written position. The short-side OI aggregates are bumped to match the
    ///      staged position because closing a winner decrements them with bare subtraction.
    function _stageShortWinner(address user, uint256 entryValue) internal {
        _deposit(user, WINNER_COLLATERAL);
        _writePosition(user, false, WINNER_SIZE, entryValue);
        (, uint256 shortOI,, uint256 shortEntrySum,,,,,,,,) = pair.pairVault();
        _stdstore.target(address(pair)).sig("pairVault()").depth(1).checked_write(shortOI + WINNER_SIZE);
        _stdstore.target(address(pair)).sig("pairVault()").depth(3).checked_write(shortEntrySum + entryValue);
    }

    /// @dev A long so far underwater that the vault inherits it above the mark: bankruptcy
    ///      notional lands at markNotional + 2×insurance, so the inherited gap clears the 80%
    ///      ADL trigger regardless of the fixture's insurance seed.
    function _stageDeepUnderwaterEstate() internal {
        _deposit(dave, ESTATE_COLLATERAL);
        uint256 entryValue = ESTATE_SIZE * MARK + ESTATE_COLLATERAL + 2 * _insuranceBal();
        _writePosition(dave, true, ESTATE_SIZE, entryValue);
    }

    /// @dev Liquidate the estate on a fresh mark (opens the ADL window), then age past
    ///      ADL_AUCTION_DURATION so the score threshold floors at 1 and any profitable winner is
    ///      eligible without threshold arithmetic. Stays far inside ADL_TIMEOUT_DURATION.
    function _liquidateEstateOpeningWindow() internal {
        bytes[] memory pu = _priceAt(MARK); // build BEFORE the prank (mockPyth call would consume it)
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        assertEq(pair.liquidate{value: 0.01 ether}(_arr1(dave), pu), 1, "estate liquidation must commit");
        assertTrue(pair.isAdlPending(), "inherited gap must open the ADL window");

        vm.warp(vm.getBlockTimestamp() + 11 minutes);
    }

    // ---------------------------- readers ----------------------------

    function _deficit() internal view returns (uint256 x) {
        (,,,,,,,,,,, x) = pair.pairVault();
    }

    /// @dev Live vault reads plus the settlement notional a WINNER_SIZE position closes at:
    ///      executeAdlCore settles at avgBP = pendingLiqBankruptcyNotional / pendingLiqSize.
    function _vaultSnapshot()
        internal
        view
        returns (uint256 d, uint256 i, uint256 pendSize, uint256 settlementNotional)
    {
        uint256 bk;
        (,,,, d, i, pendSize,, bk,,,) = pair.pairVault();
        uint256 settlementPrice = Math.mulDiv(bk, BAZAAR_SCALE, pendSize);
        settlementNotional = Math.mulDiv(WINNER_SIZE, settlementPrice, BAZAAR_SCALE);
    }

    // ---------------------------- tests ----------------------------

    /// A single winner whose credit exceeds the whole fund: the fund is drained into their
    /// bucket, the unpaid remainder lands in deficit (credited + deficit == owed), and the same
    /// transaction fixes the settlement price via the post-batch health check.
    function test_winnerCreditOverrun_recordsDeficit_andFixesSettlement() public {
        uint256 i0 = _insuranceBal();
        // Entry far enough above any reachable settlement price that the owed credit dwarfs the
        // fund even after liquidation-time insurance movements.
        uint256 aliceEntry = MARK * BAZAAR_SCALE + 2 * i0 / 100 + 4 * (i0 + ESTATE_COLLATERAL);
        _stageShortWinner(alice, aliceEntry);
        _stageDeepUnderwaterEstate();
        _liquidateEstateOpeningWindow();

        (uint256 d1, uint256 i1, uint256 pendSize1, uint256 settlementNotional) = _vaultSnapshot();
        uint256 owed = aliceEntry - settlementNotional;

        // Fixture guards: the credit must overrun a non-empty fund, with no funding leg to move
        // the owed amount (the staged winner's entryFundingIndex is zero).
        assertGt(owed, i1, "fixture: owed credit must exceed the fund");
        assertGt(i1, 0, "fixture: fund must be non-empty so the partial credit is visible");
        assertEq(pair.currentFundingIndex(), 0, "fixture: zero funding index");

        bytes[] memory pu = _priceAt(MARK);
        vm.prank(bob);
        pair.executeAdl{value: 0.01 ether}(_arr1(alice), pu);

        // Winner fully closed and credited exactly what the fund held.
        assertEq(_posSize(alice), 0, "winner position fully closed");
        assertEq(_posCollateral(alice), WINNER_COLLATERAL + i1, "winner credited the whole fund");
        assertEq(_insuranceBal(), 0, "fund drained");

        // The unpaid remainder is recorded, not dropped: credited + deficit == owed.
        assertEq(_deficit(), owed - i1, "shortfall recorded as deficit");

        // The funded leg is an I -> D transfer and the deficit is bookkeeping only, so I + D is
        // invariant across the call.
        assertEq(_totalDeposited(), d1 + i1, "funded leg credited to the deposits ledger");

        // Check 0 fired inside the same transaction: the pair is in the settlement window.
        assertGt(pair.settlementPriceFixedTs(), 0, "deficit fixed the settlement price");

        (,, uint256 pendSizeAfter,) = _vaultSnapshot();
        assertEq(pendSizeAfter, pendSize1 - WINNER_SIZE, "pending aggregate decremented by the closed size");
    }

    /// Two winners with the fund exhausted by the first: the batch stops at the recorded deficit
    /// instead of seizing the second winner for zero credit, and the deficit reflects the first
    /// winner's shortfall alone.
    function test_batchStopsAtDeficit_secondWinnerUntouched() public {
        uint256 i0 = _insuranceBal();
        uint256 aliceEntry = MARK * BAZAAR_SCALE + 2 * i0 / 100 + 4 * (i0 + ESTATE_COLLATERAL);
        uint256 carolEntry = MARK * BAZAAR_SCALE + 2 * i0 / 100 + 2 * (i0 + ESTATE_COLLATERAL);
        _stageShortWinner(alice, aliceEntry);
        _stageShortWinner(carol, carolEntry);
        _stageDeepUnderwaterEstate();
        _liquidateEstateOpeningWindow();

        (, uint256 i1,, uint256 settlementNotional) = _vaultSnapshot();
        uint256 owedAlice = aliceEntry - settlementNotional;

        assertGt(owedAlice, i1, "fixture: first credit must exhaust the fund");
        // The second winner must be genuinely profitable at the settlement price — otherwise the
        // eligibility checks would SKIP her and the untouched-assertions below could not
        // discriminate a stopped batch from a skipped account.
        assertGt(carolEntry, settlementNotional, "fixture: second winner profitable at settlement");
        assertEq(pair.currentFundingIndex(), 0, "fixture: zero funding index");

        // Equal collateral and a larger snapshot PnL rank the overrun winner first, satisfying
        // the descending-score submission check.
        address[] memory winners = new address[](2);
        winners[0] = alice;
        winners[1] = carol;

        bytes[] memory pu = _priceAt(MARK);
        vm.prank(bob);
        pair.executeAdl{value: 0.01 ether}(winners, pu);

        // First winner: closed, fund-drained credit, shortfall recorded.
        assertEq(_posSize(alice), 0, "first winner closed");
        assertEq(_posCollateral(alice), WINNER_COLLATERAL + i1, "first winner credited the whole fund");
        assertEq(_deficit(), owedAlice - i1, "deficit is the first winner's shortfall alone");

        // Second winner untouched: still open at full size with entry and collateral intact.
        assertEq(_posSize(carol), WINNER_SIZE, "second winner still open");
        assertEq(_posCollateral(carol), WINNER_COLLATERAL, "second winner collateral untouched");
        (,, uint256 carolEntryAfter,,,,,,,) = pair.positionBuckets(carol);
        assertEq(carolEntryAfter, carolEntry, "second winner entry untouched");

        assertGt(pair.settlementPriceFixedTs(), 0, "deficit fixed the settlement price");
    }
}
