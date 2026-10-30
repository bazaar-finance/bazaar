// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title PartialCloseMarginRatioTest
/// @notice A partial close is judged by what it leaves behind. A remainder that still meets IMR
///         fills outright; below IMR the fill must not lower the account's margin-to-MMR ratio,
///         even where the remainder would stay above maintenance. A reduction sold at a deep
///         discount to the owner's own second account therefore cannot carry margin out of a
///         position that stays open, while sales near the mark still fill.
///         alice opens 1 BTC long at $50k against bob on 1.06x IMR; carol stands in for her second
///         account, and dave for an ordinary bidder.
contract PartialCloseMarginRatioTest is IntegrationBase {
    uint256 constant S = 1e18;
    uint256 constant ENTRY = 50_000;
    uint256 constant SOLD = 3 * S / 10; // every sale in this file is 0.3 BTC

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

    function _equity(address u, uint256 priceUsd) internal view returns (int256) {
        BazaarTypes.BucketState memory st = lens.checkBucketSolvency(address(pair), u, priceUsd * S);
        return int256(st.effectiveCollateral) + st.totalPnl;
    }

    /// @dev alice opens 1 BTC long at $50k on 106% of the IMR it needs. bob's resting ask is the
    ///      first arrival, so the rates read after it hold for the rest of the case: every later
    ///      call lands inside the margin curve's one-minute cooldown.
    function _openAliceLong() internal returns (uint256 collateral) {
        _placeLimitAt(bob, false, 1 * S, ENTRY * S, ENTRY);
        (uint256 imrBp,) = _rates();
        _deposit(alice, ENTRY * S * imrBp / 10_000 * 106 / 100);
        _roll(2);
        _placeLimitAt(alice, true, 1 * S, ENTRY * S, ENTRY);
        assertEq(_posSize(alice), 1 * S, "alice opened 1 BTC");
        collateral = _posCollateral(alice);
    }

    /// @dev alice's margin, fee aside, after selling 0.3 BTC at `priceUsd` with the oracle at
    ///      `oracleUsd` (both at or below her entry): her collateral less the loss the sale
    ///      realizes and the loss the remaining 0.7 BTC still holds.
    function _marginAfterSale(uint256 collateral, uint256 priceUsd, uint256 oracleUsd) internal pure returns (uint256) {
        return collateral - SOLD * (ENTRY - priceUsd) - (S - SOLD) * (ENTRY - oracleUsd);
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

    /// @dev Places alice's 0.3 BTC limit sell and returns its id plus the reason it was canceled
    ///      with.
    function _aliceSaleCanceled(uint256 limitUsd, uint256 oracleUsd)
        internal
        returns (uint256 id, BazaarTypes.CancelReason reason)
    {
        vm.recordLogs();
        id = _placeLimitAt(alice, false, SOLD, limitUsd * S, oracleUsd);
        reason = _cancelReason(vm.getRecordedLogs(), id);
    }

    // ---------------------------------------------------------------- at IMR

    /// @notice carol bids for 0.3 BTC at 1.5 times the IMR rate under the mark, deeper than alice's
    ///         own margin per unit. Filled, the sale would leave alice's remainder above maintenance
    ///         but well short of IMR, so it is refused: nothing fills and nothing moves.
    function test_atImr_offMarketSaleToSecondAccount_refused() public {
        uint256 c = _openAliceLong();
        (uint256 imrBp, uint256 mmrBp) = _rates();
        assertLe(imrBp * 3 / 2, 5_000, "the bid fits the placement band");
        uint256 q = ENTRY * (10_000 - imrBp * 3 / 2) / 10_000;
        uint256 left = _marginAfterSale(c, q, ENTRY);
        uint256 remainderNotional = (S - SOLD) * ENTRY;
        assertGe(left, remainderNotional * mmrBp / 10_000, "the sale would leave MMR covered");
        assertLt(left, remainderNotional * imrBp / 10_000, "but not IMR");

        _roll(2);
        uint256 carolBid = _placeLimitAt(carol, true, SOLD, q * S, ENTRY);
        _roll(2);
        (uint256 id, BazaarTypes.CancelReason reason) = _aliceSaleCanceled(q, ENTRY);
        assertEq(_filledSize(id), 0, "nothing filled");
        assertEq(uint8(reason), uint8(BazaarTypes.CancelReason.Margin), "margin");
        assertEq(_posSize(alice), 1 * S, "position untouched");
        assertEq(_posCollateral(alice), c, "collateral untouched");
        assertEq(_filledSize(carolBid), 0, "carol unfilled");
        assertEq(_canceledBlock(carolBid), 0, "carol's bid still resting");
    }

    /// @notice The same sale resting as alice's ask is refused when carol lifts it: the maker side
    ///         is judged the same way, so the ask is canceled and carol's bid rests unfilled.
    function test_atImr_offMarketRestingAsk_canceledWhenLifted() public {
        uint256 c = _openAliceLong();
        (uint256 imrBp,) = _rates();
        uint256 q = ENTRY * (10_000 - imrBp * 3 / 2) / 10_000;

        _roll(2);
        uint256 ask = _placeLimitAt(alice, false, SOLD, q * S, ENTRY);
        assertTrue(_inBook(ask), "the reducing ask rests");

        _roll(2);
        vm.recordLogs();
        uint256 carolBid = _placeLimitAt(carol, true, SOLD, q * S, ENTRY);
        assertEq(uint8(_cancelReason(vm.getRecordedLogs(), ask)), uint8(BazaarTypes.CancelReason.Margin), "margin");
        assertEq(_filledSize(ask), 0, "ask unfilled");
        assertEq(_filledSize(carolBid), 0, "carol unfilled");
        assertTrue(_inBook(carolBid), "carol's bid rests");
        assertEq(_posSize(alice), 1 * S, "position untouched");
        assertEq(_posCollateral(alice), c, "collateral untouched");
    }

    /// @notice A sale half the IMR rate under the mark keeps the remainder at or above IMR, so it
    ///         fills.
    function test_atImr_saleWithinImrRate_fills() public {
        uint256 c = _openAliceLong();
        (uint256 imrBp,) = _rates();
        uint256 q = ENTRY * (10_000 - imrBp / 2) / 10_000;
        assertGe(_marginAfterSale(c, q, ENTRY), (S - SOLD) * ENTRY * imrBp / 10_000, "the sale leaves IMR covered");

        _roll(2);
        _placeLimitAt(dave, true, SOLD, q * S, ENTRY);
        _roll(2);
        uint256 id = _placeLimitAt(alice, false, SOLD, q * S, ENTRY);
        assertEq(_filledSize(id), SOLD, "sale filled");
        assertEq(_posSize(alice), S - SOLD, "0.7 BTC left");
    }

    // ---------------------------------------------------------------- between MMR and IMR

    /// @notice A drop leaves alice at 1.5x MMR. A sale twice the MMR rate under the mark would still
    ///         leave the remainder above maintenance, but it lowers her margin-to-MMR ratio, so it
    ///         is refused. A sale one MMR rate under the mark keeps the ratio and fills.
    function test_betweenMmrAndImr_saleMustKeepTheRatio() public {
        uint256 c = _openAliceLong();
        (uint256 imrBp, uint256 mmrBp) = _rates();
        uint256 p = (ENTRY * S - c) * 10_000 / (10_000 - mmrBp * 3 / 2) / S;
        assertGt(_equity(alice, p), int256(p * S * mmrBp / 10_000), "above maintenance");
        assertLt(_equity(alice, p), int256(p * S * imrBp / 10_000), "below IMR");

        uint256 deep = p * (10_000 - 2 * mmrBp) / 10_000;
        uint256 remainderNotional = (S - SOLD) * p;
        assertGe(
            _marginAfterSale(c, deep, p), remainderNotional * mmrBp / 10_000, "the deep sale would leave MMR covered"
        );

        _roll(2);
        uint256 carolBid = _placeLimitAt(carol, true, SOLD, deep * S, p);
        _roll(2);
        (uint256 id, BazaarTypes.CancelReason reason) = _aliceSaleCanceled(deep, p);
        assertEq(_filledSize(id), 0, "deep sale refused");
        assertEq(uint8(reason), uint8(BazaarTypes.CancelReason.Margin), "margin");
        assertEq(_posSize(alice), 1 * S, "position untouched");
        assertEq(_canceledBlock(carolBid), 0, "carol's bid still resting");

        // dave's bid sits above carol's, so alice's sale at its price fills there and never
        // reaches carol's.
        uint256 near = p * (10_000 - mmrBp) / 10_000;
        _roll(2);
        _placeLimitAt(dave, true, SOLD, near * S, p);
        _roll(2);
        id = _placeLimitAt(alice, false, SOLD, near * S, p);
        assertEq(_filledSize(id), SOLD, "near sale filled");
        assertEq(_posSize(alice), S - SOLD, "0.7 BTC left");
        assertEq(_filledSize(carolBid), 0, "carol still unfilled");
    }
}
