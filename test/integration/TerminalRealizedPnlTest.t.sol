// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title TerminalRealizedPnlTest
/// @notice Terminal settlement on a book that carries realized PnL against still-open
///         counterparties. A close books its realized PnL into the closer's bucket only, so the
///         deposits ledger D equals the sum of bucket collateral plus the open positions' net
///         unrealized PnL — it is NOT the principal owed. Finalize derives the total owed from
///         the ledger identity once every position is settled, so both signs of that gap must
///         come out exact: no winner paid short, no principal bricked, nothing stranded.
contract TerminalRealizedPnlTest is IntegrationBase {
    uint256 constant PAYOUT_TOL = 1e14; // $0.0001

    function _fix(uint256 priceUsd) internal {
        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(priceUsd * BAZAAR_SCALE);
    }

    function _settleMany(address[] memory users) internal returns (uint256) {
        return pair.liquidate(users, new bytes[](0));
    }

    function _bucket(address u)
        internal
        view
        returns (bool isLong, uint256 size, uint256 entryValue, uint256 collateral)
    {
        (isLong, size, entryValue, collateral,,,) = pair.positionBuckets(u);
    }

    function _withdrawAll(address u) internal returns (uint256 total) {
        uint256 before = usdc.balanceOf(u);
        for (uint256 i = 0; i < 2; i++) {
            (,,, uint256 c) = _bucket(u);
            if (c == 0) break;
            vm.prank(u);
            pair.withdrawCollateral(c, new bytes[](0), 0, 0, 0, "");
        }
        total = usdc.balanceOf(u) - before;
    }

    /// @dev alice long 1 BTC at 51k vs bob short 1 BTC at 51k, 20k collateral each; carol deposits 20k.
    ///      Then the oracle moves to `closePriceUsd` and bob closes his short against carol's
    ///      resting ask at that price, realizing his PnL into his own bucket. Book afterwards:
    ///      alice long at 51k (open), carol short at closePrice (open), bob flat.
    function _openThenBobCloses(uint256 closePriceUsd) internal {
        _openPosition(alice, bob, true, BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimitAt(carol, false, BAZAAR_SCALE, closePriceUsd * BAZAAR_SCALE, closePriceUsd);
        _roll(2);
        _placeLimitAt(bob, true, BAZAAR_SCALE, (closePriceUsd + 1_000) * BAZAAR_SCALE, closePriceUsd);
        assertEq(_posSize(bob), 0, "setup: bob flat");
        assertEq(_posSize(alice), BAZAAR_SCALE, "setup: alice still open");
        assertEq(_posSize(carol), BAZAAR_SCALE, "setup: carol open");
    }

    function _settleAliceAndCarolThenFinalize() internal {
        address[] memory u = new address[](2);
        u[0] = alice;
        u[1] = carol;
        assertEq(_settleMany(u), 2, "both open positions settled");
        pair.finalizeTermination();
    }

    /// @notice Bob realized a ~9k LOSS into his bucket; alice's offsetting +9k is unrealized.
    ///         That cash sits in the contract counted in D but owned by no bucket. Finalize must
    ///         still pay alice's fully cash-backed profit in full and strand nothing.
    function test_realizedLossOutstanding_winnerPaidInFull() public {
        _openThenBobCloses(60_000);

        (,,, uint256 bobColl) = _bucket(bob);
        assertLt(bobColl, 12_000 * BAZAAR_SCALE, "setup: bob realized ~9k loss");
        uint256 sumColl = _posCollateral(alice) + bobColl + _posCollateral(carol);
        assertGt(
            _totalDeposited(), sumColl + 8_000 * BAZAAR_SCALE, "setup: D exceeds sum of buckets by the realized loss"
        );

        _fix(60_000);
        _settleAliceAndCarolThenFinalize();

        BazaarTypes.AuxState memory aux = pair.auxState();
        assertEq(aux.terminalPrincipalRatio, BAZAAR_SCALE, "principal whole");
        assertEq(aux.terminalProfitRatio, BAZAAR_SCALE, "profit fully cash-backed");

        uint256 aliceGot = _withdrawAll(alice);
        uint256 bobGot = _withdrawAll(bob);
        uint256 carolGot = _withdrawAll(carol);
        assertGt(aliceGot, 28_900 * USDC_SCALE, "winner paid principal plus the full 9k profit");
        assertApproxEqAbs(bobGot, bobColl / 1e12, 1, "bob withdraws his post-loss balance");
        assertApproxEqAbs(carolGot, 19_985 * USDC_SCALE, 20 * USDC_SCALE, "carol whole");
        assertLt(_totalDeposited(), PAYOUT_TOL, "nothing left in the deposits ledger");
        assertApproxEqAbs(_cashBaz(), _insuranceBal() + _escrowTotal(), PAYOUT_TOL, "nothing stranded");
    }

    /// @notice Bob realized a ~11k GAIN into his bucket; alice's offsetting −11k is unrealized.
    ///         The sum of buckets exceeds D by 11k. Every principal withdrawal, including the
    ///         last, must still go through.
    function test_realizedGainOutstanding_everyPrincipalWithdrawalSucceeds() public {
        _openThenBobCloses(40_000);

        (,,, uint256 bobColl) = _bucket(bob);
        assertGt(bobColl, 30_000 * BAZAAR_SCALE, "setup: bob realized ~11k gain");

        _fix(40_000);
        _settleAliceAndCarolThenFinalize();

        uint256 aliceGot = _withdrawAll(alice);
        uint256 bobGot = _withdrawAll(bob);
        uint256 carolColl = _posCollateral(carol);
        uint256 carolGot = _withdrawAll(carol);
        assertApproxEqAbs(aliceGot, 8_990 * USDC_SCALE, 20 * USDC_SCALE, "alice: collateral less her 11k loss");
        assertApproxEqAbs(bobGot, bobColl / 1e12, 1, "bob withdraws his post-gain balance");
        assertEq(carolGot, carolColl / 1e12, "carol's untouched principal withdraws in full");
        assertLt(_totalDeposited(), PAYOUT_TOL, "nothing left in the deposits ledger");
        assertApproxEqAbs(_cashBaz(), _insuranceBal() + _escrowTotal(), PAYOUT_TOL, "nothing stranded");
    }
}
