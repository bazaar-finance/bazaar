// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Malicious ETH receiver. `_refundEth` sends excess msg.value back to the caller with a raw
///      call and EMPTY calldata, landing on receive(); the actor re-enters a nonReentrant entrypoint
///      from there. The reentrant call is made low-level so the guard's revert is captured rather
///      than propagated — proving the OUTER call still completes while the inner one is rejected.
contract ReentrantActor {
    BazaarPair public immutable pair;
    uint256 public mode; // 1 = re-enter liquidate, 2 = re-enter withdrawCollateral
    bool public reentered;
    bool public reentrySucceeded;
    bytes public reentryReturndata;

    constructor(BazaarPair _pair) {
        pair = _pair;
    }

    function attackLiquidate(address[] calldata users, bytes[] calldata pu, uint256 _mode) external {
        mode = _mode;
        pair.liquidate{value: address(this).balance}(users, pu);
    }

    receive() external payable {
        if (reentered) return; // only re-enter once, then accept the refund so the outer call finishes
        reentered = true;

        bytes memory data;
        if (mode == 1) {
            // Guard runs before the body, so empty args still reach it.
            data = abi.encodeCall(BazaarPair.liquidate, (new address[](0), new bytes[](0)));
        } else {
            data = abi.encodeWithSignature(
                "withdrawCollateral(uint256,bytes[],uint256,uint256,uint256,bytes)",
                uint256(0),
                new bytes[](0),
                uint256(0),
                uint256(0),
                uint256(0),
                bytes("")
            );
        }
        (bool ok, bytes memory ret) = address(pair).call(data);
        reentrySucceeded = ok;
        reentryReturndata = ret;
    }
}

/// @notice The suite had zero attacker-contract / reentrancy tests despite seven ETH-refunding
///         payable entrypoints. These prove the contract-wide ReentrancyGuard actually blocks
///         reentry through the refund callback.
contract ReentrancyAttackTest is IntegrationBase {
    ReentrantActor internal actor;

    function setUp() public override {
        super.setUp();
        actor = new ReentrantActor(pair);
        vm.deal(address(actor), 1 ether); // funds the excess-ETH refund that triggers the callback
    }

    /// @notice Re-entering liquidate from the refund callback is rejected by the guard, while the
    ///         outer liquidate completes normally.
    function test_reentrancy_liquidate_selfReenter_blocked() public {
        bytes[] memory pu = _priceAt(50_000);
        actor.attackLiquidate(_arr1(bob), pu, 1); // bob has no position — outer call is a no-op that still refunds

        assertTrue(actor.reentered(), "refund callback must fire");
        assertFalse(actor.reentrySucceeded(), "reentrant liquidate must be rejected");
        assertEq(
            bytes4(actor.reentryReturndata()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "rejected by the reentrancy guard, not some other revert"
        );
    }

    /// @notice The guard is contract-wide: re-entering a DIFFERENT nonReentrant entrypoint
    ///         (withdrawCollateral) from inside liquidate is also blocked.
    function test_reentrancy_liquidate_reenterWithdraw_blocked() public {
        bytes[] memory pu = _priceAt(50_000);
        actor.attackLiquidate(_arr1(bob), pu, 2);

        assertTrue(actor.reentered(), "refund callback must fire");
        assertFalse(actor.reentrySucceeded(), "cross-function reentry must be rejected");
        assertEq(
            bytes4(actor.reentryReturndata()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "guard is global across entrypoints"
        );
    }
}
