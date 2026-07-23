// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title StaleAndRewardEdgeTest
/// @notice Stale-oracle margin/liquidation posture and the liquidator-reward soft-fail arms.
contract StaleAndRewardEdgeTest is IntegrationBase {
    using stdStorage for StdStorage;

    function _depositAapl(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function _placeLimitAapl(address user, uint256 size, uint256 limitPrice, bytes[] memory pu) internal {
        vm.prank(user);
        aaplPair.createOrder(
            BazaarTypes.OrderType.Limit,
            0,
            limitPrice,
            0,
            size,
            true,
            false,
            uint64(vm.getBlockNumber() + 500_000),
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
    }

    // ============================ stale 2x IMR at creation ============================

    /// @notice On a stale oracle, order creation demands DOUBLE the initial margin: collateral that
    ///         comfortably clears 1x IMR with a fresh price is rejected once the price goes stale.
    function test_staleOracle_doublesCreationMargin() public {
        // 1 AAPL @ ~$200 notional: warmup IMR 20% = $40; stale doubles it to $80. Deposit $60.
        _depositAapl(alice, 60 * BAZAAR_SCALE);

        // Fresh price: creation clears 1x IMR.
        bytes[] memory fresh = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
        _placeLimitAapl(alice, 1 * BAZAAR_SCALE, 200 * BAZAAR_SCALE, fresh);
        (uint256[] memory ids,,,) = aaplPair.getUserActiveLimitOrders(alice);
        assertEq(ids.length, 1, "fresh-price creation succeeds at 1x IMR");

        // Cancel, stale the cache, retry with an empty update: 2x IMR now binds.
        vm.prank(alice);
        aaplPair.cancelOrders(ids, 0, 0, 0, "");
        vm.warp(vm.getBlockTimestamp() + 30);
        vm.prank(alice);
        vm.expectRevert();
        aaplPair.createOrder(
            BazaarTypes.OrderType.Limit,
            0,
            200 * BAZAAR_SCALE,
            0,
            1 * BAZAAR_SCALE,
            true,
            false,
            uint64(vm.getBlockNumber() + 500_000),
            address(0),
            new bytes[](0),
            0,
            0,
            0,
            ""
        );
    }

    // ============================ stale liquidation posture ============================

    /// @notice Non-continuous pairs liquidate on the stale-fallback price: bad debt is not left
    ///         hanging just because the market is closed.
    function test_staleLiquidation_nonContinuousPairProceeds() public {
        // Warm the AAPL cache at $200, give dave a phantom insolvent long (entry $300).
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
        vm.deal(address(this), 1 ether);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(pu)}(pu);
        aaplPair.refreshPrice(new bytes[](0));

        _depositAapl(dave, 10 * BAZAAR_SCALE);
        _stdstore.target(address(aaplPair)).sig("positionBuckets(address)").with_key(dave).depth(0).checked_write(true);
        _stdstore.target(address(aaplPair)).sig("positionBuckets(address)").with_key(dave).depth(1)
            .checked_write(1 * BAZAAR_SCALE);
        _stdstore.target(address(aaplPair)).sig("positionBuckets(address)").with_key(dave).depth(2)
            .checked_write(300 * BAZAAR_SCALE);

        vm.warp(vm.getBlockTimestamp() + 30); // stale (MAX_PRICE_STALENESS = 2s)
        vm.prank(bob);
        uint256 n = aaplPair.liquidate(_arr1(dave), new bytes[](0));
        assertEq(n, 1, "liquidated at the stale fallback price");
    }

    /// @notice Continuous pairs REQUIRE a fresh price to liquidate — pinning the protocol posture
    ///         that BTC-style liquidations cannot run on stale data.
    function test_staleLiquidation_continuousPairRequiresFreshPrice() public {
        _setupInsolventAlice();
        vm.warp(vm.getBlockTimestamp() + 30); // nothing fresh in the cache
        vm.prank(bob);
        vm.expectRevert();
        pair.liquidate(_arr1(alice), new bytes[](0));
    }

    // ============================ liquidator reward soft-fail ============================

    /// @notice A liquidator that cannot receive USDC does not poison the liquidation: the reward
    ///         debit is restored to insurance and the liquidation still commits.
    function test_reward_transferFailureRestoresInsurance() public {
        _setupInsolventAlice();
        address liquidator = makeAddr("unreachableLiquidator");
        uint256 insBefore = _insuranceBal();

        bytes[] memory pu = _freshPrice();
        // Any USDC transfer to this liquidator silently fails (e.g. blacklisted).
        vm.mockCall(address(usdc), abi.encodeWithSignature("transfer(address,uint256)", liquidator), abi.encode(false));
        vm.prank(liquidator);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "liquidation commits regardless");
        vm.clearMockedCalls();

        assertEq(usdc.balanceOf(liquidator), 0, "no reward received");
        // Insurance ends at +seized collateral exactly: the reward debit was restored.
        assertEq(_insuranceBal() - insBefore, 10 * BAZAAR_SCALE, "reward restored, seizure kept");
    }

    /// @notice When insurance cannot afford the reward at all, it is skipped and the liquidation
    ///         still commits (dust-position griefing cannot block liquidations).
    function test_reward_skippedWhenInsuranceCannotAfford() public {
        // Zero-collateral phantom victim (nothing seized) + insurance crushed to zero.
        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, BAZAAR_SCALE / 10, 5_005 * BAZAAR_SCALE);
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(dave).depth(3)
            .checked_write(uint256(0));
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(uint256(0));

        address liquidator = makeAddr("unpaidLiquidator");
        bytes[] memory pu = _freshPrice();
        vm.prank(liquidator);
        assertEq(pair.liquidate(_arr1(dave), pu), 1, "liquidation commits");
        assertEq(usdc.balanceOf(liquidator), 0, "reward skipped, not reverted");
    }
}
