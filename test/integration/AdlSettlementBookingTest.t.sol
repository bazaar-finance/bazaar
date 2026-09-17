// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {IntegrationBase} from "./IntegrationBase.sol";

/// @title AdlSettlementBookingTest
/// @notice ADL closes winners at the estates' average bankruptcy price, or at the mark when the
///         mark sits on the fund's favorable side of it, and settles the inventory slice through
///         insurance exactly as an unload fill does: the winner realizes their full PnL at that
///         price into their bucket, and the vault realizes the price leg from the liquidatees'
///         entry plus the funding leg from their entry index, which at the bankruptcy price net
///         to the seizure plus the holding-window funding. Every fill here is real, so the winner's gain
///         between their own entry and the estate's entry sits on the books of their earlier
///         counterparty, and the ledger identity the termination waterfall relies on,
///
///             Σ bucket.collateral + Σ unrealizedPnl + estateValue = D + deficit,
///
///         is checked after every deleverage. The tail is pinned too: with no free capital the
///         holding-window funding is withheld from each winner's own funding income and the pair
///         survives, while a fund below its seizure earmark records the excess as deficit and
///         stops the batch.
contract AdlSettlementBookingTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant ESTATE_SIZE = 5 * BAZAAR_SCALE;
    uint256 constant PRICE_36K = 36_000 * BAZAAR_SCALE;

    /// @dev Pending-liquidation aggregates a close is settled from.
    struct Inventory {
        uint256 size;
        uint256 entryNotional;
        uint256 bkNotional;
        int256 entryFundingIndex;
        uint256 seized;
    }

    /// @dev A winner's basis, read before the close resets the bucket.
    struct Winner {
        uint256 size;
        uint256 entryValue;
        int256 entryIdx;
    }

    /// @dev Every pre-close reading the expectations are computed from.
    struct Snapshot {
        Inventory inv;
        uint256 settlementPrice;
        uint256 insBefore;
        uint256 depBefore;
        uint256 escrowBefore;
        Winner bob;
        Winner alice;
        uint256 bobCollBefore;
        uint256 aliceCollBefore;
    }

    /// @dev One decoded UserAdld log.
    struct Close {
        bool found;
        uint256 closedSize;
        int256 realizedPnl;
        uint256 withheld;
    }

    // ---------------------------- readers ----------------------------

    function _sumBuckets() internal view returns (uint256) {
        return _posCollateral(alice) + _posCollateral(bob) + _posCollateral(carol) + _posCollateral(dave);
    }

    function _deficit() internal view returns (uint256 d) {
        (,,,,,,,,,,, d,,) = pair.pairVault();
    }

    function _inventory() internal view returns (Inventory memory inv) {
        (,,,,,, inv.size, inv.entryNotional, inv.bkNotional, inv.entryFundingIndex,,,, inv.seized) = pair.pairVault();
    }

    function _winner(address user) internal view returns (Winner memory w) {
        (, w.size, w.entryValue,, w.entryIdx,,,,) = pair.positionBuckets(user);
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.inv = _inventory();
        s.settlementPrice = Math.mulDiv(s.inv.bkNotional, BAZAAR_SCALE, s.inv.size);
        s.insBefore = _insuranceBal();
        s.depBefore = _totalDeposited();
        s.escrowBefore = _escrowTotal();
        s.bob = _winner(bob);
        s.alice = _winner(alice);
        s.bobCollBefore = _posCollateral(bob);
        s.aliceCollBefore = _posCollateral(alice);
    }

    /// @dev The vault's inventory valued from the liquidatees' entry, price and funding legs.
    function _estateValue(uint256 price) internal view returns (int256) {
        Inventory memory inv = _inventory();
        if (inv.size == 0) return 0;
        int256 cur = int256(inv.size * price / BAZAAR_SCALE);
        int256 funding = (pair.currentFundingIndex() - inv.entryFundingIndex) * int256(inv.size) / int256(BAZAAR_SCALE);
        return cur - int256(inv.entryNotional) - funding; // the vault holds longs throughout
    }

    function _sumUnrealized(uint256 price) internal view returns (int256 total) {
        address[4] memory users = [alice, bob, carol, dave];
        for (uint256 i = 0; i < 4; i++) {
            if (_posSize(users[i]) == 0) continue;
            BazaarTypes.BucketState memory st = lens.checkBucketSolvency(address(pair), users[i], price);
            total += st.totalPnl;
        }
    }

    function _assertIdentity(uint256 price, string memory label) internal view {
        int256 lhs = int256(_sumBuckets()) + _sumUnrealized(price) + _estateValue(price);
        int256 rhs = int256(_totalDeposited()) + int256(_deficit());
        assertApproxEqAbs(lhs, rhs, 1e12, label);
    }

    /// @dev Decode the UserAdld log emitted for `user`, if any.
    function _findClose(Vm.Log[] memory logs, address user) internal view returns (Close memory c) {
        bytes32 sig = keccak256("UserAdld(bytes32,address,bool,uint256,int256,uint256,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(pair) || logs[i].topics[0] != sig) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != user) continue;
            (, c.closedSize, c.realizedPnl,,,, c.withheld) =
                abi.decode(logs[i].data, (bool, uint256, int256, uint256, uint256, uint256, uint256));
            c.found = true;
            return c;
        }
    }

    /// @dev A short winner's PnL at the settlement price with the live index.
    function _winnerPnl(Winner memory w, uint256 settlementPrice, int256 idxAfter)
        internal
        pure
        returns (uint256 totalPnl, uint256 fundingPnl)
    {
        int256 price = int256(w.entryValue) - int256(Math.mulDiv(w.size, settlementPrice, BAZAAR_SCALE));
        int256 funding = (idxAfter - w.entryIdx) * int256(w.size) / int256(BAZAAR_SCALE);
        totalPnl = uint256(price + funding);
        fundingPnl = funding > 0 ? uint256(funding) : 0;
    }

    /// @dev The vault's loss on `closedSize` of long inventory closed at the bankruptcy price and
    ///      valued at `idxAfter`, computed as the settlement computes it: the price leg to the
    ///      slice's share of the bankruptcy notional plus the funding leg from the estate's entry
    ///      index, which net to the slice's earmark (its share of the seizure) plus the funding
    ///      accrued while the vault held it.
    function _vaultLoss(Inventory memory inv, int256 idxAfter, uint256 closedSize)
        internal
        pure
        returns (uint256 loss, uint256 earmark)
    {
        uint256 entryPortion = Math.mulDiv(inv.entryNotional, closedSize, inv.size);
        uint256 bkPortion = Math.mulDiv(inv.bkNotional, closedSize, inv.size);
        earmark = Math.mulDiv(inv.seized, closedSize, inv.size);
        int256 raw = (idxAfter - inv.entryFundingIndex) * int256(closedSize) / int256(BAZAAR_SCALE);
        loss = uint256(int256(entryPortion - bkPortion) + raw);
    }

    /// @dev The aggregates left after a proportional close of `closedSize`.
    function _remaining(Inventory memory inv, uint256 closedSize) internal pure returns (Inventory memory rest) {
        rest.size = inv.size - closedSize;
        rest.entryNotional = inv.entryNotional - Math.mulDiv(inv.entryNotional, closedSize, inv.size);
        rest.bkNotional = inv.bkNotional - Math.mulDiv(inv.bkNotional, closedSize, inv.size);
        rest.seized = inv.seized - Math.mulDiv(inv.seized, closedSize, inv.size);
        rest.entryFundingIndex = inv.entryFundingIndex;
    }

    function _writeInsurance(uint256 x) internal {
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(x);
    }

    function _arr2(address a, address b) internal pure returns (address[] memory out) {
        out = new address[](2);
        out[0] = a;
        out[1] = b;
    }

    // ---------------------------- scenario ----------------------------

    /// @dev Winners short at `entryUsd` against carol: bob 3 and alice 2, or bob 5 alone. Carol
    ///      then closes at $52k against dave, so dave is long 5 @ $52k while the winners still
    ///      hold their shorts and carol carries the realized gap between the two prices.
    function _openChain(uint256 entryUsd, bool twoWinners) internal {
        _deposit(bob, 200_000 * BAZAAR_SCALE);
        _deposit(carol, 200_000 * BAZAAR_SCALE);
        _deposit(dave, 60_000 * BAZAAR_SCALE);
        uint256 entry = entryUsd * BAZAAR_SCALE;
        if (twoWinners) {
            _deposit(alice, 200_000 * BAZAAR_SCALE);
            _placeLimitAt(bob, false, 3 * BAZAAR_SCALE, entry, entryUsd);
            _placeLimitAt(alice, false, 2 * BAZAAR_SCALE, entry, entryUsd);
        } else {
            _placeLimitAt(bob, false, ESTATE_SIZE, entry, entryUsd);
        }
        _roll(2);
        _placeLimitAt(carol, true, ESTATE_SIZE, entry, entryUsd);
        assertEq(_posSize(carol), ESTATE_SIZE, "carol long 5 against the winners");

        _placeLimitAt(carol, false, ESTATE_SIZE, 52_000 * BAZAAR_SCALE, 52_000);
        _roll(2);
        _placeLimitAt(dave, true, ESTATE_SIZE, 52_000 * BAZAAR_SCALE, 52_000);
        assertEq(_posSize(carol), 0, "carol flat");
        assertEq(_posSize(dave), ESTATE_SIZE, "dave long 5 @ 52k");
        _assertIdentity(52_000 * BAZAAR_SCALE, "identity after the opens");
    }

    /// @dev Oracle $36k: dave's $60k collateral is gone against an $80k loss. The book is empty,
    ///      so the vault inherits his long at a bankruptcy price of (260k - 60k) / 5 = $40k.
    function _liquidateEstate() internal {
        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceAt(36_000);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(dave), pu), 1, "dave liquidated");
        assertTrue(pair.isAdlPending(), "ADL pending");
        (,,,,,, uint256 pendSize,,,, bool pendIsLong,,,) = pair.pairVault();
        assertEq(pendSize, ESTATE_SIZE, "vault inherited 5 BTC");
        assertTrue(pendIsLong, "vault holds the long");
        _assertIdentity(PRICE_36K, "identity after the liquidation");
    }

    /// @dev Age past the auction, deleverage `winners` and return the recorded logs.
    function _executeAdl(address[] memory winners) internal returns (Vm.Log[] memory logs) {
        vm.warp(vm.getBlockTimestamp() + 15 minutes + 1);
        return _executeAdlNow(winners);
    }

    /// @dev The execution alone, for scenarios that have to stage vault state against the same
    ///      funding index the settlement will use.
    function _executeAdlNow(address[] memory winners) internal returns (Vm.Log[] memory logs) {
        bytes[] memory pu = _priceAt(36_000);
        vm.recordLogs();
        vm.prank(seq);
        pair.executeAdl(winners, pu);
        logs = vm.getRecordedLogs();
    }

    /// @dev Single-winner scenario: bob's whole short closes against the whole inventory, the
    ///      fund pays the vault's loss in full and bob is credited in full.
    function _runNeutralClose(uint256 entryUsd) internal {
        _openChain(entryUsd, false);
        _liquidateEstate();

        // Land the auction clock and settle the funding index to now, fixing what the vault owes
        // on the inventory it holds. Leaving the fund holding exactly that — the seizure plus the
        // carry, no free capital — makes the whole aggregate the size that restores health, so the
        // close is full, while still covering the settlement without withholding.
        vm.warp(vm.getBlockTimestamp() + 15 minutes + 1);
        vm.prank(seq);
        pair.refreshPrice(_priceAt(36_000));

        Inventory memory inv0 = _inventory();
        (uint256 owed,) = _vaultLoss(inv0, pair.currentFundingIndex(), inv0.size);
        _writeInsurance(owed);

        Snapshot memory s = _snapshot();
        Close memory c = _findClose(_executeAdlNow(_arr1(bob)), bob);
        int256 idxAfter = pair.currentFundingIndex();

        assertTrue(c.found, "UserAdld emitted for bob");
        assertEq(_posSize(bob), 0, "bob deleveraged");
        assertEq(_inventory().size, 0, "inventory closed");
        assertEq(c.withheld, 0, "nothing withheld while the fund can pay");

        // Winner: full PnL at the settlement price with the live index, into the bucket.
        (uint256 totalPnl,) = _winnerPnl(s.bob, s.settlementPrice, idxAfter);
        assertApproxEqAbs(uint256(c.realizedPnl), totalPnl, 1e6, "bob credited his full PnL at the bankruptcy price");
        assertEq(_posCollateral(bob) - s.bobCollBefore, uint256(c.realizedPnl), "bucket grew by the credit");

        // Vault: the seizure plus the holding-window funding, as an I -> D transfer. The ADL
        // executor reward leaves the fund for the escrow in the same call.
        (uint256 loss,) = _vaultLoss(s.inv, idxAfter, ESTATE_SIZE);
        uint256 adlReward = _escrowTotal() - s.escrowBefore;
        assertApproxEqAbs(s.insBefore - _insuranceBal(), loss + adlReward, 1e6, "insurance paid the vault's loss");
        assertApproxEqAbs(_totalDeposited() - s.depBefore, loss, 1e6, "deposits ledger gained the vault's loss");

        assertEq(_deficit(), 0, "no bad debt: every claim is cash-backed");
        assertEq(pair.settlementPriceFixedTs(), 0, "pair survives");
        _assertIdentity(PRICE_36K, "identity after the deleverage");
    }

    /// @dev With no free capital the shortfall on a slice is exactly the funding accrued while the
    ///      vault held it, and the withholding is that shortfall capped at the winner's own funding
    ///      income and credit.
    function _assertWithheldCarry(
        Close memory c,
        Inventory memory inv,
        Winner memory w,
        uint256 settlementPrice,
        int256 idxAfter
    ) internal pure {
        assertTrue(c.found, "close emitted");
        (uint256 loss, uint256 earmark) = _vaultLoss(inv, idxAfter, w.size);
        (uint256 totalPnl, uint256 fundingPnl) = _winnerPnl(w, settlementPrice, idxAfter);
        uint256 shortfall = loss - earmark;
        uint256 cap = fundingPnl < totalPnl ? fundingPnl : totalPnl;
        uint256 expected = shortfall < cap ? shortfall : cap;
        assertGt(expected, 0, "fixture: the inventory owed funding while the vault held it");
        assertApproxEqAbs(c.withheld, expected, 1e6, "withheld = funding shortfall, capped at own funding income");
        assertApproxEqAbs(uint256(c.realizedPnl) + c.withheld, totalPnl, 1e6, "credit + withheld = full PnL");
    }

    /// @dev The first close against a fund holding `fund`, less than that slice's earmark: the
    ///      winner's funding income is withheld in full and the rest of the shortfall is deficit.
    function _assertDeficitClose(Close memory c, Snapshot memory s, uint256 fund, int256 idxAfter) internal view {
        (uint256 loss,) = _vaultLoss(s.inv, idxAfter, s.bob.size);
        (uint256 totalPnl, uint256 fundingPnl) = _winnerPnl(s.bob, s.settlementPrice, idxAfter);
        uint256 shortfall = loss - fund;
        assertGt(shortfall, fundingPnl, "fixture: the shortfall exceeds bob's funding income");
        assertApproxEqAbs(c.withheld, fundingPnl, 1e6, "withholding capped at bob's own funding income");
        assertApproxEqAbs(uint256(c.realizedPnl), totalPnl - fundingPnl, 1e6, "price PnL paid in full");
        assertEq(_insuranceBal(), 0, "fund fully drawn");
        assertEq(_totalDeposited() - s.depBefore, fund, "ledger gained only what the fund could pay");
        assertApproxEqAbs(_deficit(), shortfall - fundingPnl, 1e6, "unbacked remainder recorded as deficit");
    }

    // ---------------------------- tests ----------------------------

    /// @notice Winner entered ABOVE the estate: his PnL at the bankruptcy price (about $100k)
    ///         exceeds the seizure (about $60k) by (60k − 52k) × 5 = $40k, which carol already
    ///         realized as a loss. The fund pays the seizure back, not the winner's PnL.
    function test_winnerEnteredAboveEstate_fundPaysSeizureNotWinnerPnl() public {
        _runNeutralClose(60_000);
    }

    /// @notice Winner entered BELOW the estate: his PnL at the bankruptcy price (about $40k) is
    ///         short of the seizure by (52k − 48k) × 5 = $20k, which carol already realized as a
    ///         gain. The fund still pays the whole seizure back to the ledger.
    function test_winnerEnteredBelowEstate_fundPaysSeizureNotWinnerPnl() public {
        _runNeutralClose(48_000);
    }

    /// @notice No free capital: the fund holds exactly the seizure it earmarked. Each slice is
    ///         funded from its own earmark, so both winners are closed, each has only the funding
    ///         the vault accrued on their slice withheld from their own funding income, nothing is
    ///         booked as deficit, the batch runs to the end and the pair survives.
    function test_noFreeCapital_carryWithheldPerWinner_batchContinues() public {
        _openChain(60_000, true);
        _liquidateEstate();

        Snapshot memory s = _snapshot();
        _writeInsurance(s.inv.seized); // free capital exactly zero
        Vm.Log[] memory logs = _executeAdl(_arr2(bob, alice)); // bob's larger PnL ranks first
        int256 idxAfter = pair.currentFundingIndex();

        assertEq(_posSize(bob), 0, "bob deleveraged");
        assertEq(_posSize(alice), 0, "alice deleveraged: the batch did not stop");
        assertEq(_inventory().size, 0, "inventory closed");
        assertEq(_deficit(), 0, "a withheld carry is not bad debt");
        assertEq(pair.settlementPriceFixedTs(), 0, "pair survives");
        assertEq(_insuranceBal(), 0, "the earmark went back to the ledger in full");
        assertEq(_totalDeposited() - s.depBefore, s.inv.seized, "ledger gained the seizure");

        // bob's slice is settled from the whole aggregate, alice's from what bob left.
        _assertWithheldCarry(_findClose(logs, bob), s.inv, s.bob, s.settlementPrice, idxAfter);
        _assertWithheldCarry(
            _findClose(logs, alice), _remaining(s.inv, s.bob.size), s.alice, s.settlementPrice, idxAfter
        );
        _assertIdentity(PRICE_36K, "identity after the deleverage");
    }

    /// @notice The mark recovers past the estates' bankruptcy price while the window is still
    ///         open: with nothing above the earmark the fund cannot finish the inventory inside
    ///         the band, so the gate holds and the batch settles at the mark rather than the
    ///         bankruptcy price. The winner is credited no better than market, the vault's loss
    ///         on the slice shrinks by the recovery so the fund keeps that much of its earmark,
    ///         no reward is paid, and the pair leaves the window healthy.
    function test_markAboveBankruptcy_settlesAtMark_fundKeepsTheRecovery() public {
        _openChain(60_000, false);
        _liquidateEstate();

        Snapshot memory s = _snapshot();
        // Below the earmark by a margin: no free capital keeps the window open, and the margin
        // keeps the batch sized to the whole inventory whatever sign the holding carry takes.
        _writeInsurance(s.inv.seized - 500 * BAZAAR_SCALE);
        s.insBefore = _insuranceBal();
        uint256 mark = 40_200 * BAZAAR_SCALE;
        assertGt(mark, s.settlementPrice, "fixture: the mark is above the bankruptcy price");

        vm.warp(vm.getBlockTimestamp() + 15 minutes + 1);
        bytes[] memory pu = _priceAt(40_200);
        vm.recordLogs();
        vm.prank(seq);
        pair.executeAdl(_arr1(bob), pu);
        Close memory c = _findClose(vm.getRecordedLogs(), bob);
        int256 idxAfter = pair.currentFundingIndex();

        assertTrue(c.found, "bob closed");
        assertEq(c.closedSize, ESTATE_SIZE, "the whole inventory closed against bob");
        assertEq(_posSize(bob), 0, "bob deleveraged");
        assertEq(_inventory().size, 0, "inventory closed");
        assertFalse(pair.isAdlPending(), "window released");
        assertEq(c.withheld, 0, "nothing withheld: the earmark covers the smaller loss");

        // Winner: full PnL at the mark, below what the bankruptcy price would have paid.
        (uint256 pnlAtMark,) = _winnerPnl(s.bob, mark, idxAfter);
        (uint256 pnlAtBankruptcy,) = _winnerPnl(s.bob, s.settlementPrice, idxAfter);
        assertLt(pnlAtMark, pnlAtBankruptcy, "fixture: the mark is the worse close for the winner");
        assertApproxEqAbs(uint256(c.realizedPnl), pnlAtMark, 1e6, "bob credited his PnL at the mark");
        assertEq(_posCollateral(bob) - s.bobCollBefore, uint256(c.realizedPnl), "bucket grew by the credit");

        // Vault: the loss at the bankruptcy price less the recovery to the mark, and no reward.
        (uint256 lossAtBankruptcy,) = _vaultLoss(s.inv, idxAfter, ESTATE_SIZE);
        uint256 loss = lossAtBankruptcy - Math.mulDiv(ESTATE_SIZE, mark - s.settlementPrice, BAZAAR_SCALE);
        assertApproxEqAbs(s.insBefore - _insuranceBal(), loss, 1e6, "insurance paid only the loss at the mark");
        assertApproxEqAbs(_totalDeposited() - s.depBefore, loss, 1e6, "deposits ledger gained the vault's loss");
        assertEq(_deficit(), 0, "no bad debt");
        assertEq(pair.settlementPriceFixedTs(), 0, "pair survives");
        _assertIdentity(mark, "identity after the deleverage");
    }

    /// @notice The fund holds half the seizure it earmarked: the first close's shortfall exceeds
    ///         the winner's funding income, so that income is withheld and the rest is recorded
    ///         as deficit. The winner's price PnL is untouched, the batch stops before the second
    ///         winner, and the same transaction fixes the settlement price.
    function test_fundBelowEarmark_recordsDeficit_stopsBatch_fixesSettlement() public {
        _openChain(60_000, true);
        _liquidateEstate();

        Snapshot memory s = _snapshot();
        uint256 fund = s.inv.seized / 2;
        _writeInsurance(fund);
        Close memory c = _findClose(_executeAdl(_arr2(bob, alice)), bob);
        int256 idxAfter = pair.currentFundingIndex();

        assertTrue(c.found, "bob closed");
        assertEq(_posSize(bob), 0, "bob deleveraged");
        assertEq(_posSize(alice), s.alice.size, "batch stopped: alice still open");
        assertEq(_posCollateral(alice), s.aliceCollBefore, "alice collateral untouched");
        assertEq(_winner(alice).entryValue, s.alice.entryValue, "alice entry untouched");
        assertEq(_inventory().size, ESTATE_SIZE - s.bob.size, "only bob's slice left the inventory");

        _assertDeficitClose(c, s, fund, idxAfter);
        assertGt(pair.settlementPriceFixedTs(), 0, "deficit fixed the settlement price");
        _assertIdentity(PRICE_36K, "identity with the deficit counted as owed");
    }

    /// @notice The executor's reward never draws on the earmark left against unclosed inventory:
    ///         with no free capital, a batch that closes only the first winner leaves the fund
    ///         holding exactly the remaining slice's seizure and accrues no reward.
    function test_partialBatch_executorRewardNeverDrawsOnTheRemainingEarmark() public {
        _openChain(60_000, true);
        _liquidateEstate();

        Snapshot memory s = _snapshot();
        _writeInsurance(s.inv.seized); // free capital exactly zero
        _executeAdl(_arr1(bob)); // alice's slice stays open

        assertEq(_posSize(bob), 0, "bob deleveraged");
        assertEq(_posSize(alice), s.alice.size, "alice still open");
        uint256 earmarkLeft = s.inv.seized - Math.mulDiv(s.inv.seized, s.bob.size, s.inv.size);
        assertEq(_inventory().seized, earmarkLeft, "alice's slice keeps its earmark");
        assertEq(_insuranceBal(), earmarkLeft, "and the fund holds exactly that earmark");
        assertEq(_escrowTotal(), s.escrowBefore, "no executor reward accrued from it");
        assertEq(_deficit(), 0, "no deficit");
        assertTrue(pair.isAdlPending(), "the window stays open for the rest");
    }
}
