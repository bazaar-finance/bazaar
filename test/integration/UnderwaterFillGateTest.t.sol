// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";

/// @title UnderwaterFillGateTest
/// @notice The order and fill gates judge an account by the equity a fill would leave it at the
///         mark, with the held position's unrealized loss counted against it. An account in bad
///         debt can neither add exposure nor shed part of its position; no fill, at any price and
///         against any counterparty, moves a solvent account into bad debt; and an account under
///         maintenance can still close in full, in one fill or across several makers.
///         alice opens 1 BTC long at $50k against bob on 1.06x IMR unless a case says otherwise.
contract UnderwaterFillGateTest is IntegrationBase {
    uint256 constant S = 1e18;
    uint256 constant ENTRY = 50_000;

    function setUp() public override {
        super.setUp();
        _depositInsurance(seq, 100_000 * S);
        _deposit(bob, 200_000 * S);
        _deposit(carol, 200_000 * S);
        _deposit(dave, 200_000 * S);
    }

    // ---------------------------------------------------------------- helpers

    function _rates() internal view returns (uint256 imrBp, uint256 mmrBp) {
        (imrBp, mmrBp,,) = pair.marginRequirements();
    }

    function _state(address u, uint256 priceUsd) internal view returns (BazaarTypes.BucketState memory) {
        return lens.checkBucketSolvency(address(pair), u, priceUsd * S);
    }

    function _equity(address u, uint256 priceUsd) internal view returns (int256) {
        BazaarTypes.BucketState memory st = _state(u, priceUsd);
        return int256(st.effectiveCollateral) + st.totalPnl;
    }

    /// @dev alice opens 1 BTC long at $50k on `imrPct`% of the IMR it needs. bob's resting ask is
    ///      the first arrival, so the rates read after it hold for the rest of the case: every
    ///      later call lands inside the margin curve's one-minute cooldown.
    function _openAliceLong(uint256 imrPct) internal returns (uint256 collateral) {
        _placeLimitAt(bob, false, 1 * S, ENTRY * S, ENTRY);
        (uint256 imrBp,) = _rates();
        _deposit(alice, ENTRY * S * imrBp / 10_000 * imrPct / 100);
        _roll(2);
        _placeLimitAt(alice, true, 1 * S, ENTRY * S, ENTRY);
        assertEq(_posSize(alice), 1 * S, "alice opened 1 BTC");
        collateral = _posCollateral(alice);
    }

    /// @dev The whole-dollar price at or just below which alice's 1 BTC long has no equity left.
    function _bankruptcyPrice(uint256 collateral) internal pure returns (uint256) {
        return (ENTRY * S - collateral) / S;
    }

    /// @dev The reason on the cancellation reported for `orderId` among `logs`.
    function _cancelReason(Vm.Log[] memory logs, uint256 orderId) internal view returns (BazaarTypes.CancelReason) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pair) || logs[i].topics[0] != BazaarTypes.OrderUpdated.selector) continue;
            if (uint256(logs[i].topics[2]) != orderId) continue;
            BazaarTypes.OrderUpdatePayload memory u = abi.decode(logs[i].data, (BazaarTypes.OrderUpdatePayload));
            if (u.action == BazaarTypes.OrderAction.Canceled) return u.cancelReason;
        }
        revert("no cancellation reported");
    }

    /// @dev Places alice's limit order and returns its id plus the reason it was canceled with.
    function _aliceLimitCanceled(bool isLong, uint256 size, uint256 limitUsd, uint256 oracleUsd)
        internal
        returns (uint256 id, BazaarTypes.CancelReason reason)
    {
        vm.recordLogs();
        id = _placeLimitAt(alice, isLong, size, limitUsd * S, oracleUsd);
        reason = _cancelReason(vm.getRecordedLogs(), id);
    }

    /// @dev Expects alice's limit order to be refused at creation for margin.
    function _expectAliceLimitRefused(bool isLong, uint256 size, uint256 limitUsd, uint256 oracleUsd) internal {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdate(oracleUsd, uint64(vm.getBlockTimestamp()));
        BazaarTypes.OrderSpec memory spec = _limitSpec(isLong, size, limitUsd * S);
        vm.expectPartialRevert(OrderManagementLib.OrderManagementLib__InsufficientMarginAfterOrder.selector);
        vm.prank(alice);
        pair.createOrder(spec, _hintsNone(), pu, 0, 0, 0, "", "");
    }

    // ---------------------------------------------------------------- under maintenance, solvent

    /// @notice Equity at half the maintenance requirement: a full close into one maker fills.
    function test_underMaintenance_fullCloseAtOneMaker_fills() public {
        uint256 c = _openAliceLong(106);
        (, uint256 mmrBp) = _rates();
        uint256 p = (ENTRY * S - c) * 10_000 / (10_000 - mmrBp / 2) / S;
        _roll(2);
        _placeLimitAt(dave, true, 1 * S, p * S, p);
        assertFalse(_state(alice, p).isSolvent, "under maintenance");
        assertGt(_equity(alice, p), 0, "equity still positive");

        _roll(2);
        uint256 id = _placeLimitAt(alice, false, 1 * S, p * S, p);
        assertEq(_filledSize(id), 1 * S, "full close filled");
        assertEq(_posSize(alice), 0, "flat");
    }

    /// @notice The same account closes through four makers stepping away from the mark. Each fill
    ///         but the last is a partial close that leaves the remainder under maintenance at first;
    ///         each keeps the margin-to-MMR ratio, so the walk runs to the end.
    function test_underMaintenance_fullCloseAcrossSeveralMakers_fills() public {
        uint256 c = _openAliceLong(106);
        (, uint256 mmrBp) = _rates();
        uint256 p = (ENTRY * S - c) * 10_000 / (10_000 - mmrBp / 2) / S;
        for (uint256 k; k < 4; ++k) {
            _roll(2);
            _placeLimitAt(dave, true, S / 4, (p - 20 * k) * S, p);
        }
        assertFalse(_state(alice, p).isSolvent, "under maintenance");

        _roll(2);
        uint256 id = _placeLimitAt(alice, false, 1 * S, (p - 60) * S, p);
        assertEq(_filledSize(id), 1 * S, "every level filled");
        assertEq(_posSize(alice), 0, "flat");
        assertGt(_posCollateral(alice), 0, "closed solvent");
    }

    // ---------------------------------------------------------------- bad debt

    /// @notice $500 of bad debt at the mark: a full close at the mark is refused.
    function test_badDebt_fullCloseAtMark_refused() public {
        uint256 p = _bankruptcyPrice(_openAliceLong(106)) - 500;
        _roll(2);
        _placeLimitAt(dave, true, 1 * S, p * S, p);
        assertLt(_equity(alice, p), 0, "bad debt");

        _roll(2);
        (uint256 id, BazaarTypes.CancelReason reason) = _aliceLimitCanceled(false, 1 * S, p, p);
        assertEq(_filledSize(id), 0, "nothing filled");
        assertEq(uint8(reason), uint8(BazaarTypes.CancelReason.Margin), "margin");
        assertEq(_posSize(alice), 1 * S, "position untouched");
    }

    /// @notice The gate reads the fill price, not the mark: a bid above the bankruptcy price closes
    ///         the same account in full without realizing any bad debt.
    function test_badDebt_fullCloseAboveBankruptcyPrice_fills() public {
        uint256 bk = _bankruptcyPrice(_openAliceLong(106));
        uint256 p = bk - 500;
        _roll(2);
        _placeLimitAt(dave, true, 1 * S, (bk + 100) * S, p);
        assertLt(_equity(alice, p), 0, "bad debt at the mark");

        _roll(2);
        uint256 id = _placeLimitAt(alice, false, 1 * S, (bk + 100) * S, p);
        assertEq(_filledSize(id), 1 * S, "full close filled");
        assertEq(_posSize(alice), 0, "flat");
    }

    /// @notice A partial close at the mark would leave the remainder carrying the whole deficit, so
    ///         it is refused as well.
    function test_badDebt_partialCloseAtMark_refused() public {
        uint256 p = _bankruptcyPrice(_openAliceLong(106)) - 500;
        _roll(2);
        _placeLimitAt(dave, true, 1 * S, p * S, p);

        _roll(2);
        (uint256 id, BazaarTypes.CancelReason reason) = _aliceLimitCanceled(false, S / 2, p, p);
        assertEq(_filledSize(id), 0, "nothing filled");
        assertEq(uint8(reason), uint8(BazaarTypes.CancelReason.Margin), "margin");
        assertEq(_posSize(alice), 1 * S, "position untouched");
    }

    /// @notice An add is refused at creation: the held loss already exceeds the collateral.
    function test_badDebt_addRefusedAtCreation() public {
        uint256 p = _bankruptcyPrice(_openAliceLong(106)) - 500;
        _roll(2);
        _placeLimitAt(carol, false, 1 * S, p * S, p);
        assertLt(_equity(alice, p), 0, "bad debt");

        _roll(2);
        _expectAliceLimitRefused(true, S / 20, p, p);
        assertEq(_posSize(alice), 1 * S, "position untouched");
    }

    /// @notice An add that was resting before the account fell into bad debt is canceled when a
    ///         seller reaches it, and the seller's walk moves on.
    function test_badDebt_restingAddCanceledOnContact() public {
        uint256 bk = _bankruptcyPrice(_openAliceLong(106));
        _roll(2);
        uint256 bid = _placeLimitAt(alice, true, S / 25, 38_000 * S, ENTRY);
        uint256 p = bk - 500;
        assertGt(p, 38_000, "the resting bid sits below the mark");
        _roll(2);
        _placeLimitAt(dave, true, S / 100, 30_000 * S, p); // stores the mark without crossing
        assertLt(_equity(alice, p), 0, "bad debt");

        _roll(2);
        vm.recordLogs();
        _placeLimitAt(carol, false, S / 25, 38_000 * S, p);
        assertEq(uint8(_cancelReason(vm.getRecordedLogs(), bid)), uint8(BazaarTypes.CancelReason.Margin), "margin");
        assertEq(_filledSize(bid), 0, "nothing filled");
        assertEq(_posSize(alice), 1 * S, "position untouched");
    }

    // ---------------------------------------------------------------- no fill creates bad debt

    /// @notice alice is $300 from bankruptcy with a bid resting from before the drop, now far above
    ///         the mark. Filling it would buy at a loss her equity cannot cover, so the bid is
    ///         canceled on contact and her equity is left where it was.
    function test_restingBidAboveMark_cannotPushSolventAccountIntoBadDebt() public {
        uint256 bk = _bankruptcyPrice(_openAliceLong(106));
        _roll(2);
        uint256 bid = _placeLimitAt(alice, true, S / 25, 49_000 * S, ENTRY);
        uint256 p = bk + 300;
        _roll(2);
        _placeLimitAt(dave, true, S / 100, 30_000 * S, p); // stores the mark without crossing
        assertGt(_equity(alice, p), 0, "solvent");
        uint256 collateralBefore = _posCollateral(alice);

        _roll(2);
        vm.recordLogs();
        _placeLimitAt(carol, false, S / 25, 49_000 * S, p);
        assertEq(uint8(_cancelReason(vm.getRecordedLogs(), bid)), uint8(BazaarTypes.CancelReason.Margin), "margin");
        assertEq(_posSize(alice), 1 * S, "position untouched");
        assertEq(_posCollateral(alice), collateralBefore, "collateral untouched");
        assertGt(_equity(alice, p), 0, "still solvent");
    }

    /// @notice The same account sells 0.3 BTC to a colluding bid 30% under the mark. Collateral alone
    ///         would cover the realized loss and MMR on the remainder, but the remainder's own loss
    ///         would leave the account in bad debt, so the sale is refused and the bid keeps resting.
    function test_offMarketPartialSell_refused() public {
        uint256 p = _bankruptcyPrice(_openAliceLong(106)) + 300;
        uint256 qLow = p * 70 / 100;
        _roll(2);
        uint256 colluderBid = _placeLimitAt(carol, true, 3 * S / 10, qLow * S, p);

        _roll(2);
        (uint256 id, BazaarTypes.CancelReason reason) = _aliceLimitCanceled(false, 3 * S / 10, qLow, p);
        assertEq(_filledSize(id), 0, "nothing filled");
        assertEq(uint8(reason), uint8(BazaarTypes.CancelReason.Margin), "margin");
        assertEq(_posSize(alice), 1 * S, "position untouched");
        assertEq(_filledSize(colluderBid), 0, "colluder unfilled");
        assertEq(_canceledBlock(colluderBid), 0, "colluder bid still resting");
    }

    /// @notice With the oracle fixed at $50k: buy 0.5 BTC at $60k from a colluder (a $5k incipient
    ///         loss the open is allowed to carry), then sell 0.24 BTC back to the same colluder at
    ///         $25.5k. The sale would leave the remainder's loss uncovered, so it is refused.
    function test_zeroMove_offMarketRoundTrip_refused() public {
        _placeLimitAt(carol, false, S / 2, 60_000 * S, ENTRY);
        _deposit(alice, 10_200 * S);
        _roll(2);
        _placeLimitAt(alice, true, S / 2, 60_000 * S, ENTRY);
        assertEq(_posSize(alice), S / 2, "opened");
        assertGt(_equity(alice, ENTRY), 0, "solvent after the open");

        _roll(2);
        _placeLimitAt(carol, true, 24 * S / 100, 25_500 * S, ENTRY);
        _roll(2);
        (uint256 id, BazaarTypes.CancelReason reason) = _aliceLimitCanceled(false, 24 * S / 100, 25_500, ENTRY);
        assertEq(_filledSize(id), 0, "nothing filled");
        assertEq(uint8(reason), uint8(BazaarTypes.CancelReason.Margin), "margin");
        assertEq(_posSize(alice), S / 2, "position untouched");
        assertGt(_equity(alice, ENTRY), 0, "still solvent");
    }

    // ---------------------------------------------------------------- losing but healthy

    /// @notice A losing account keeps trading on what is left after its loss: on 1.5x IMR and $2k
    ///         underwater, a 0.2 BTC add fits IMR net of the loss and fills, and a further 0.3 BTC
    ///         does not and is refused at creation.
    function test_losingAccount_addsWithinImrNetOfLoss() public {
        _openAliceLong(150);
        uint256 p = 48_000;
        _roll(2);
        _placeLimitAt(carol, false, 1 * S, p * S, p);
        assertLt(_equity(alice, p), int256(_posCollateral(alice)), "underwater");

        _roll(2);
        uint256 id = _placeLimitAt(alice, true, S / 5, p * S, p);
        assertEq(_filledSize(id), S / 5, "add filled");

        _roll(2);
        _expectAliceLimitRefused(true, 3 * S / 10, p, p);
        assertEq(_posSize(alice), 12 * S / 10, "second add refused");
    }
}
