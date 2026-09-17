// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {CollateralLib} from "../../src/libraries/CollateralLib.sol";
import {BucketStore} from "../BucketStore.sol";

/// @title StaleAndRewardEdgeTest
/// @notice Stale-oracle margin/liquidation posture and the liquidator-reward edge arms (an
///         unreachable liquidator, an unaffordable reward).
contract StaleAndRewardEdgeTest is IntegrationBase {
    using stdStorage for StdStorage;

    function _depositAapl(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function _placeLimitAapl(address user, uint256 size, uint256 limitPrice, bytes[] memory pu) internal {
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Limit;
        s.isLong = true;
        s.size = size;
        s.limitPrice = limitPrice;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        vm.prank(user);
        aaplPair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
    }

    // ============================ stale creation margin ============================

    /// @notice A stale oracle adds NO margin surcharge at order creation: the same collateral that
    ///         clears the IMR with a fresh price clears it against the stale fallback too. Gap
    ///         risk is priced into the non-continuous pair's always-on IMR (2x multiplier +
    ///         reopen-gap floor), not into a stale-mode rate.
    function test_staleOracle_noCreationSurcharge() public {
        // 1 AAPL @ $200 limit: warmup IMR 40% (20% x 2 non-continuous) = $80. Deposit $85 —
        // above 1x IMR, far below what any 2x stale surcharge would demand ($160).
        _depositAapl(alice, 85 * BAZAAR_SCALE);

        // Fresh price: creation clears the IMR.
        bytes[] memory fresh = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
        _placeLimitAapl(alice, 1 * BAZAAR_SCALE, 200 * BAZAAR_SCALE, fresh);
        (uint256[] memory ids,,,) = aaplPair.getUserActiveLimitOrders(alice);
        assertEq(ids.length, 1, "fresh-price creation succeeds at 1x IMR");

        // Cancel, stale the cache, retry with an empty update: the SAME 1x IMR still clears.
        vm.prank(alice);
        aaplPair.cancelOrders(ids, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + 30);
        _placeLimitAapl(alice, 1 * BAZAAR_SCALE, 200 * BAZAAR_SCALE, new bytes[](0));
        (uint256[] memory staleIds,,,) = aaplPair.getUserActiveLimitOrders(alice);
        assertEq(staleIds.length, 1, "stale-price creation succeeds at the same 1x IMR");
    }

    // ============================ stale withdrawal freeze ============================

    /// @notice A position holder cannot withdraw against the stale fallback. Around a closure,
    ///         off-chain venues print the reopen hours before the oracle can, so releasing
    ///         equity at the frozen mark would let a holder who is already dead at the real
    ///         price convert that loss into vault deficit. The identical withdrawal clears the
    ///         moment a fresh price is supplied.
    function test_staleOracle_positionHolderWithdrawalBlocked() public {
        // Warm the AAPL cache at $200 and give dave a healthy 1-share long with wide headroom.
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
        vm.deal(address(this), 1 ether);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(pu)}(pu);
        aaplPair.refreshPrice(new bytes[](0));

        _depositAapl(dave, 200 * BAZAAR_SCALE);
        BucketStore.setIsLong(address(aaplPair), dave, true);
        BucketStore.setSize(address(aaplPair), dave, 1 * BAZAAR_SCALE); // size
        BucketStore.setEntryValue(address(aaplPair), dave, 200 * BAZAAR_SCALE); // entryValue

        vm.warp(vm.getBlockTimestamp() + 30); // stale the cache (MAX_PRICE_STALENESS = 2s)
        vm.prank(dave);
        vm.expectRevert(CollateralLib.CollateralLib__WithdrawalRequiresFreshPrice.selector);
        aaplPair.withdrawCollateral(10 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");

        // Same withdrawal, fresh price: clears every gate.
        bytes[] memory fresh = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
        uint256 before = usdc.balanceOf(dave);
        vm.deal(dave, 1 ether);
        vm.prank(dave);
        aaplPair.withdrawCollateral{value: 0.01 ether}(10 * BAZAAR_SCALE, fresh, 0, 0, 0, "");
        assertEq(usdc.balanceOf(dave) - before, 10 * BAZAAR_SCALE / 1e12, "fresh-price withdrawal pays out");
    }

    /// @notice Flat accounts with resting orders keep the stale-fallback path: they hold no
    ///         position whose frozen mark could hide a loss, and their resting exposure keeps
    ///         its order-IMR reserve through the withdrawal.
    function test_staleOracle_flatWithOrdersWithdrawalAllowed() public {
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
        vm.deal(address(this), 1 ether);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(pu)}(pu);
        aaplPair.refreshPrice(new bytes[](0));

        // $100 collateral, one resting half-share bid at $150: order-IMR reserve = 40% x $75 = $30.
        _depositAapl(alice, 100 * BAZAAR_SCALE);
        bytes[] memory fresh = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
        _placeLimitAapl(alice, BAZAAR_SCALE / 2, 150 * BAZAAR_SCALE, fresh);

        vm.warp(vm.getBlockTimestamp() + 30); // stale
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        aaplPair.withdrawCollateral(20 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice) - before, 20 * BAZAAR_SCALE / 1e12, "order-only account withdraws while stale");
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
        BucketStore.setIsLong(address(aaplPair), dave, true);
        BucketStore.setSize(address(aaplPair), dave, 1 * BAZAAR_SCALE);
        BucketStore.setEntryValue(address(aaplPair), dave, 300 * BAZAAR_SCALE);

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

    // ============================ liquidator reward edges ============================

    /// @notice A liquidator that cannot receive USDC does not poison the liquidation: the reward
    ///         accrues to its claimable balance with insurance debited exactly once, the
    ///         liquidation commits, and only the later claim — the liquidator's own call — fails
    ///         while the address stays unreachable, leaving the balance intact for a retry.
    function test_reward_unreachableLiquidator_accruesAndClaimFails() public {
        _setupInsolventAlice();
        address liquidator = makeAddr("unreachableLiquidator");
        uint256 insBefore = _insuranceBal();

        bytes[] memory pu = _freshPrice();
        vm.prank(liquidator);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "liquidation commits regardless");

        uint256 reward = _escrowOwed(liquidator);
        assertGt(reward, 0, "reward accrued");
        assertEq(usdc.balanceOf(liquidator), 0, "nothing pushed");
        // Insurance ends at +seized collateral - reward: the debit funds the escrow credit.
        assertEq(_insuranceBal() + reward - insBefore, 10 * BAZAAR_SCALE, "seizure in, reward out");
        _assertBooks("after liquidation");

        // Any USDC transfer to this liquidator silently fails (e.g. blacklisted).
        vm.mockCall(address(usdc), abi.encodeWithSignature("transfer(address,uint256)", liquidator), abi.encode(false));
        vm.prank(liquidator);
        vm.expectRevert(CollateralLib.CollateralLib__ClaimTransferFailed.selector);
        pair.claimFees();
        vm.clearMockedCalls();

        assertEq(_escrowOwed(liquidator), reward, "failed claim leaves the balance for a retry");
    }

    /// @notice When insurance cannot afford the reward at all, it is skipped and the liquidation
    ///         still commits (dust-position griefing cannot block liquidations).
    function test_reward_skippedWhenInsuranceCannotAfford() public {
        // Zero-collateral phantom victim (nothing seized) + insurance crushed to zero.
        _deposit(dave, 10 * BAZAAR_SCALE);
        _writePosition(dave, true, BAZAAR_SCALE / 10, 5_005 * BAZAAR_SCALE);
        BucketStore.setCollateral(address(pair), dave, uint256(0));
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(uint256(0));

        address liquidator = makeAddr("unpaidLiquidator");
        bytes[] memory pu = _freshPrice();
        vm.prank(liquidator);
        assertEq(pair.liquidate(_arr1(dave), pu), 1, "liquidation commits");
        assertEq(_escrowOwed(liquidator), 0, "reward skipped, not reverted");
    }
}
