// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {OrderView} from "../OrderView.sol";
import {BucketStore} from "../BucketStore.sol";

/// @title UnloadStaleOracleTest
/// @notice Vault unloads on a non-continuously-traded pair wait for a fresh price. Against the
///         stale fallback neither unloadVault nor liquidate()'s inline unload crosses the book,
///         even into a bid a fresh-price walk takes whole, because a maker who can see the reopen
///         off-chain would buy the inventory at the frozen mark only when the reopen favours the
///         fund. Each case follows the stale call with a fresh-price control on the same state,
///         so the refusal is attributable to the price's age alone.
///
///         AAPL warmup margins: IMR 40% (WARMUP 20% x 2 non-continuous), MMR = IMR/2 = 20%, so
///         the unload band is min(LIQ_MAX_SLIPPAGE_BP, MMR) = 5% of the oracle.
contract UnloadStaleOracleTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant AAPL = 1e18;

    // ---- aaplPair helpers (IntegrationBase's are hardwired to the continuous BTC pair) ----

    function _depositAapl(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev An AAPL update at `priceUsd`, stamped now.
    function _aaplPu(uint256 priceUsd) internal view returns (bytes[] memory) {
        return _priceUpdateFor(AAPL_USD_FEED_ID, priceUsd, uint64(vm.getBlockTimestamp()));
    }

    /// @dev Push `priceUsd` into Pyth's cache and store it as the pair's mark, stamped now.
    function _warmAapl(uint256 priceUsd) internal {
        bytes[] memory pu = _aaplPu(priceUsd);
        vm.deal(address(this), 1 ether);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(pu)}(pu);
        aaplPair.refreshPrice(new bytes[](0));
    }

    /// @dev Rest a Limit buy on the AAPL pair. An empty `pu` places it against the stale fallback.
    function _placeBidAapl(address user, uint256 size, uint256 limitPrice, bytes[] memory pu)
        internal
        returns (uint256)
    {
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Limit;
        s.isLong = true;
        s.size = size;
        s.limitPrice = limitPrice;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        vm.prank(user);
        aaplPair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        return _lastCreatedOrderId(aaplPair);
    }

    /// @dev Stage long inventory in the AAPL vault by raw notionals (1e18 scale). The gap between
    ///      entry and bankruptcy is the collateral seized with it; no seizure stamp is written, so
    ///      the unload floor reads as fully open and only the band and the neutral price bound it.
    function _stageLongInventory(uint256 size, uint256 entryNotional, uint256 bankruptcyNotional) internal {
        uint256 seized = entryNotional - bankruptcyNotional;
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(6).checked_write(size);
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(7).checked_write(entryNotional);
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(8).checked_write(bankruptcyNotional);
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(10).checked_write(true);
        _stdstore.target(address(aaplPair)).sig("pairVault()").depth(13).checked_write(seized);
    }

    function _pendingLiqSize() internal view returns (uint256 s) {
        (,,,,,, s,,,,,,,,,,) = aaplPair.pairVault();
    }

    function _aaplInsurance() internal view returns (uint256 b) {
        (,,,,, b,,,,,,,,,,,) = aaplPair.pairVault();
    }

    function _aaplEscrowOwed(address who) internal view returns (uint256 owed) {
        (owed,) = lens.claimableFees(address(aaplPair), who);
    }

    function _aaplPosition(address user) internal view returns (uint256 size, uint256 entryValue) {
        (, size, entryValue,,,,) = aaplPair.positionBuckets(user);
    }

    // ============================================================
    // unloadVault
    // ============================================================

    /// @notice A keeper's unloadVault on the stale fallback fills nothing and earns nothing, even
    ///         against a bid placed at the frozen mark that a fresh walk takes at once. The call
    ///         does not revert. The same call carrying a fresh price then unloads the inventory
    ///         into that bid.
    ///
    ///         Inventory: 1 AAPL long, entry $210, $12 seized, so the fund-neutral price is $198.
    ///         Frozen mark $200, band edge $190. A bid at $200 sits beyond the neutral price: a
    ///         fresh walk takes it whole without spending any headroom.
    function test_unloadVault_staleFallback_fillsNothing_freshControlFills() public {
        _warmAapl(200);
        _stageLongInventory(AAPL, 210 * BAZAAR_SCALE, 198 * BAZAAR_SCALE);

        // The venue closes: nothing fresh reaches the pair past MAX_PRICE_STALENESS (3 s).
        vm.warp(vm.getBlockTimestamp() + 30);

        // A maker who can see the reopen rests a bid at the frozen mark, itself placed against the
        // stale fallback (only Market and trigger orders are refused there).
        _depositAapl(carol, 200 * BAZAAR_SCALE);
        uint256 bidId = _placeBidAapl(carol, AAPL, 200 * BAZAAR_SCALE, new bytes[](0));
        assertTrue(OrderView.order(aaplPair, bidId).inBook, "bait bid rests");

        uint256 insuranceBefore = _aaplInsurance();

        // ---- stale: the walk refuses to cross ----
        vm.prank(seq);
        uint256 unloaded = aaplPair.unloadVault(0, new bytes[](0));

        assertEq(unloaded, 0, "nothing unloaded against the stale fallback");
        assertEq(_pendingLiqSize(), AAPL, "inventory stays with the vault");
        assertEq(OrderView.order(aaplPair, bidId).filledSize, 0, "bait bid untouched");
        assertTrue(OrderView.order(aaplPair, bidId).inBook, "bait bid still resting");
        (uint256 carolSize,) = _aaplPosition(carol);
        assertEq(carolSize, 0, "maker took nothing over");
        assertEq(_aaplEscrowOwed(seq), 0, "keeper earns nothing for an empty walk");
        assertEq(_aaplInsurance(), insuranceBefore, "fund untouched");

        // ---- control: the same bid, the same inventory, a fresh price ----
        bytes[] memory pu = _aaplPu(200);
        vm.deal(seq, 1 ether);
        vm.prank(seq);
        unloaded = aaplPair.unloadVault{value: 0.01 ether}(0, pu);

        assertEq(unloaded, AAPL, "a fresh price unloads the inventory into the same bid");
        assertEq(_pendingLiqSize(), 0, "inventory cleared");
        (uint256 size, uint256 entryValue) = _aaplPosition(carol);
        assertEq(size, AAPL, "maker took the inventory over");
        assertEq(entryValue, 200 * BAZAAR_SCALE, "at the maker's own price");
        assertGt(_aaplEscrowOwed(seq), 0, "keeper paid for the fresh unload");
    }

    // ============================================================
    // liquidate()'s inline unload
    // ============================================================

    /// @notice A liquidation on a stale fallback no older than MAX_LIQUIDATION_PRICE_AGE still
    ///         seizes, and still pays the flat reward, but its inline unload leaves the inventory
    ///         in the vault instead of selling it into an in-band bid. A fresh-price unloadVault
    ///         afterwards sells the same inventory into that bid.
    ///
    ///         Dave: 1 AAPL long, entry $190, $50 collateral. At the stale $150 his equity is $10,
    ///         under the 20% MMR of $30, and his bankruptcy price is about $140. Carol's bid at
    ///         $150 sits inside the 5% band (edge $142.50), where a fresh walk fills at once.
    function test_liquidate_staleFallback_seizesButLeavesInventory_freshUnloadFills() public {
        _warmAapl(150);

        _depositAapl(carol, 300 * BAZAAR_SCALE);
        uint256 bidId = _placeBidAapl(carol, AAPL, 150 * BAZAAR_SCALE, _aaplPu(150));

        _depositAapl(dave, 50 * BAZAAR_SCALE);
        BucketStore.setIsLong(address(aaplPair), dave, true);
        BucketStore.setSize(address(aaplPair), dave, AAPL);
        BucketStore.setEntryValue(address(aaplPair), dave, 190 * BAZAAR_SCALE);

        // Stale, but well inside MAX_LIQUIDATION_PRICE_AGE, so the seizure itself is allowed.
        vm.warp(vm.getBlockTimestamp() + 30);

        vm.prank(bob);
        assertEq(aaplPair.liquidate(_arr1(dave), new bytes[](0)), 1, "seizure commits on the stale mark");

        assertEq(_pendingLiqSize(), AAPL, "the inline unload leaves the inventory with the vault");
        assertEq(OrderView.order(aaplPair, bidId).filledSize, 0, "in-band bid not sold into");
        assertTrue(OrderView.order(aaplPair, bidId).inBook, "in-band bid still resting");
        (uint256 carolSize,) = _aaplPosition(carol);
        assertEq(carolSize, 0, "maker took nothing over");
        // One account seized: the flat reward once, and no rate top-up since the walk sold nothing.
        assertEq(
            _aaplEscrowOwed(bob),
            BazaarTypes.MIN_LIQUIDATOR_REWARD,
            "liquidator keeps the flat reward, no unload top-up"
        );

        // ---- control: a fresh price sells the same inventory into the same bid ----
        bytes[] memory pu = _aaplPu(150);
        vm.deal(seq, 1 ether);
        vm.prank(seq);
        uint256 unloaded = aaplPair.unloadVault{value: 0.01 ether}(0, pu);

        assertEq(unloaded, AAPL, "fresh unload fills the in-band bid");
        assertEq(_pendingLiqSize(), 0, "inventory cleared");
        (uint256 size, uint256 entryValue) = _aaplPosition(carol);
        assertEq(size, AAPL, "maker took the inventory over");
        assertEq(entryValue, 150 * BAZAAR_SCALE, "at the maker's own price");
    }
}
