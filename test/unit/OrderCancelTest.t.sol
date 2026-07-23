// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @notice Drives OrderManagementLib.cancelOrder over real storage: order map, position buckets,
///         and the active-limit-order set. Covers slot-pointer clearing, set removal, and reverts.
contract OrderCancelHarness {
    using EnumerableSet for EnumerableSet.UintSet;
    mapping(uint256 => BazaarTypes.Order) internal orders;
    mapping(address => BazaarTypes.PositionBucket) internal positionBuckets;
    mapping(address => EnumerableSet.UintSet) internal userActiveLimitOrders;

    function seed(uint256 id, BazaarTypes.Order calldata o) external {
        orders[id] = o;
        BazaarTypes.OrderType ot = o.orderType;
        if (ot == BazaarTypes.OrderType.Limit || ot == BazaarTypes.OrderType.StopLimit) {
            userActiveLimitOrders[o.creator].add(id);
        } else if (ot == BazaarTypes.OrderType.TakeProfit) {
            positionBuckets[o.creator].takeProfitOrderId = id;
        } else if (ot == BazaarTypes.OrderType.StopLoss) {
            positionBuckets[o.creator].stopLossOrderId = id;
        } else if (ot == BazaarTypes.OrderType.Market) {
            positionBuckets[o.creator].activeMarketOrderId = id;
        }
    }

    function cancel(uint256 id, bytes32 pid, uint64 cb) external {
        OrderManagementLib.cancelOrder(orders, positionBuckets, userActiveLimitOrders, id, pid, cb);
    }

    function canceledBlock(uint256 id) external view returns (uint64) {
        return orders[id].canceledBlock;
    }

    function isActiveLimit(address u, uint256 id) external view returns (bool) {
        return userActiveLimitOrders[u].contains(id);
    }

    function tpId(address u) external view returns (uint256) {
        return positionBuckets[u].takeProfitOrderId;
    }

    function slId(address u) external view returns (uint256) {
        return positionBuckets[u].stopLossOrderId;
    }

    function mktId(address u) external view returns (uint256) {
        return positionBuckets[u].activeMarketOrderId;
    }
}

contract OrderCancelTest is Test {
    OrderCancelHarness internal h;
    address internal alice = makeAddr("alice");
    bytes32 constant PID = bytes32("PID");

    function setUp() public {
        h = new OrderCancelHarness();
    }

    function _order(BazaarTypes.OrderType ot, uint64 expiry) internal view returns (BazaarTypes.Order memory o) {
        o.creator = alice;
        o.orderType = ot;
        o.size = 100;
        o.limitPrice = 50_000e18;
        o.expiryBlock = expiry;
    }

    function test_cancelLimit_marksCanceledAndRemovesFromActiveSet() public {
        h.seed(1, _order(BazaarTypes.OrderType.Limit, 1000));
        assertTrue(h.isActiveLimit(alice, 1), "seeded as active");
        h.cancel(1, PID, 10);
        assertEq(h.canceledBlock(1), 10);
        assertFalse(h.isActiveLimit(alice, 1), "removed from active set");
    }

    function test_cancelStopLimit_removesFromActiveSet() public {
        h.seed(2, _order(BazaarTypes.OrderType.StopLimit, 1000));
        h.cancel(2, PID, 10);
        assertFalse(h.isActiveLimit(alice, 2));
    }

    function test_cancelTakeProfit_clearsSlotPointer() public {
        h.seed(3, _order(BazaarTypes.OrderType.TakeProfit, 1000));
        assertEq(h.tpId(alice), 3);
        h.cancel(3, PID, 10);
        assertEq(h.tpId(alice), 0, "TP slot cleared");
    }

    function test_cancelStopLoss_clearsSlotPointer() public {
        h.seed(4, _order(BazaarTypes.OrderType.StopLoss, 1000));
        h.cancel(4, PID, 10);
        assertEq(h.slId(alice), 0);
    }

    function test_cancelMarket_clearsSlotPointer() public {
        h.seed(5, _order(BazaarTypes.OrderType.Market, 1000));
        h.cancel(5, PID, 10);
        assertEq(h.mktId(alice), 0);
    }

    function test_cancel_orderNotFoundReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__OrderNotFound.selector, uint256(999))
        );
        h.cancel(999, PID, 10);
    }

    function test_cancel_alreadyCanceledReverts() public {
        BazaarTypes.Order memory o = _order(BazaarTypes.OrderType.Limit, 1000);
        o.canceledBlock = 5;
        h.seed(6, o);
        vm.expectRevert(
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__OrderIsNotActive.selector, uint256(6))
        );
        h.cancel(6, PID, 10);
    }

    function test_cancel_alreadyFilledReverts() public {
        BazaarTypes.Order memory o = _order(BazaarTypes.OrderType.Limit, 1000);
        o.filledBlock = 5;
        h.seed(7, o);
        vm.expectRevert(
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__OrderIsNotActive.selector, uint256(7))
        );
        h.cancel(7, PID, 10);
    }

    function test_cancel_expiredReverts() public {
        h.seed(8, _order(BazaarTypes.OrderType.Limit, 5)); // expires at block 5
        vm.expectRevert(
            abi.encodeWithSelector(OrderManagementLib.OrderManagementLib__OrderAlreadyExpired.selector, uint256(8))
        );
        h.cancel(8, PID, 10); // currentBlock 10 > expiry 5
    }
}
