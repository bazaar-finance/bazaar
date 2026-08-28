// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

/// @title UnloadVaultTest
/// @notice Vault liquidation inventory crossing into the resting book: the liquidation price
///         band (min(LIQ_MAX_SLIPPAGE_BP, MMR) around oracle), proportional aggregate
///         decrements, the inline unload at the end of liquidate(), and the permissionless
///         unloadVault caller reward with its anti-dust gate.
contract UnloadVaultTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant BTC = 1e18;

    /// @dev Inject vault liquidation inventory directly (sizes in 1e18, prices in whole USD).
    ///      entryNotional/bankruptcyNotional land in 1e18 scale because size already carries it.
    function _setVaultPendingLiq(uint256 size, uint256 entryPriceUsd, uint256 bankruptcyPriceUsd, bool isLong)
        internal
    {
        _stdstore.target(address(pair)).sig("pairVault()").depth(6).checked_write(size);
        _stdstore.target(address(pair)).sig("pairVault()").depth(7).checked_write(size * entryPriceUsd);
        _stdstore.target(address(pair)).sig("pairVault()").depth(8).checked_write(size * bankruptcyPriceUsd);
        _stdstore.target(address(pair)).sig("pairVault()").depth(10).checked_write(isLong);
    }

    function _pendingLiqSize() internal view returns (uint256 s) {
        (,,,,,, s,,,,,) = pair.pairVault();
    }

    // ============================================================
    // Band + fills + aggregates
    // ============================================================

    function test_unload_fillsRestingBid_clearsInventory() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 49_900 * BAZAAR_SCALE);

        // Vault holds a 0.1 BTC long at a $50k basis.
        _setVaultPendingLiq(BTC / 10, 50_000, 48_000, true);

        assertEq(_unloadVault(), BTC / 10, "inventory fully unloaded");
        assertEq(_pendingLiqSize(), 0, "aggregate cleared");

        (, uint256 sz, uint256 entry,,,,,,) = pair.positionBuckets(carol);
        assertEq(sz, BTC / 10, "counterparty took the inventory over");
        assertEq(entry, 49_900 * BAZAAR_SCALE / 10, "filled at the resting maker's price");
    }

    function test_unload_stopsAtFirstOutOfBandMaker() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        // Band at warmup MMR (10%) is min(5%, 10%) = 5% → floor $47,500 at a $50k oracle.
        _placeLimit(carol, true, BTC / 10, 47_600 * BAZAAR_SCALE); // inside
        _placeLimit(dave, true, BTC / 10, 47_400 * BAZAAR_SCALE); // outside

        _setVaultPendingLiq(3 * BTC / 10, 50_000, 48_000, true);

        assertEq(_unloadVault(), BTC / 10, "only the in-band maker filled");
        assertEq(_pendingLiqSize(), 2 * BTC / 10, "remainder stays as vault inventory");
        assertEq(_posSize(dave), 0, "out-of-band maker untouched");
        assertTrue(_inBook(_newestLimitOrderId(dave)), "out-of-band maker still resting");
    }

    function test_unload_respectsStepBudget() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 49_900 * BAZAAR_SCALE);
        _placeLimit(dave, true, BTC / 10, 49_800 * BAZAAR_SCALE);

        _setVaultPendingLiq(3 * BTC / 10, 50_000, 48_000, true);

        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        assertEq(pair.unloadVault(1, pu), BTC / 10, "one node visited, one fill");
        assertEq(_pendingLiqSize(), 2 * BTC / 10);
        assertEq(_posSize(dave), 0, "second maker beyond the budget");
    }

    function test_unload_noInventory_noop() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 49_900 * BAZAAR_SCALE);
        assertEq(_unloadVault(), 0, "nothing to unload");
        assertEq(_posSize(carol), 0, "maker untouched");
    }

    function test_unload_shortInventory_walksAsks() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, false, BTC / 10, 50_100 * BAZAAR_SCALE); // resting ask, inside +5% band

        // Vault holds a short: it buys back from the ask side.
        _setVaultPendingLiq(BTC / 10, 50_000, 52_000, false);

        assertEq(_unloadVault(), BTC / 10);
        assertEq(_pendingLiqSize(), 0);
        (bool isLong, uint256 sz,,,,,,,) = pair.positionBuckets(carol);
        assertEq(sz, BTC / 10);
        assertFalse(isLong, "counterparty inherited the short side");
    }

    // ============================================================
    // Caller reward
    // ============================================================

    function test_unload_reward_paidAboveMinNotional() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 49_900 * BAZAAR_SCALE);
        _setVaultPendingLiq(BTC / 10, 49_900, 48_000, true); // entry == fill → zero vault PnL

        uint256 keeperBefore = usdc.balanceOf(seq);
        _unloadVault();

        // reward = max($0.10, 2bp × $4,990 unloaded) = $0.998.
        uint256 expected = (BTC / 10) * 49_900 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE / 1e12;
        assertEq(usdc.balanceOf(seq) - keeperBefore, expected, "2bp-of-notional reward paid");
    }

    function test_unload_reward_floorApplies() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 100, 49_900 * BAZAAR_SCALE); // $499 unloaded → 2bp ≈ $0.0998
        _setVaultPendingLiq(BTC / 100, 49_900, 48_000, true);

        uint256 keeperBefore = usdc.balanceOf(seq);
        _unloadVault();
        assertEq(usdc.balanceOf(seq) - keeperBefore, 0.1e6, "$0.10 floor applies below the crossover");
    }

    function test_unload_reward_withheldBelowMinNotional() public {
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        // ~$50 unloaded — below UNLOAD_BOUNTY_MIN_NOTIONAL ($100): unload executes, no reward.
        _placeLimit(carol, true, BTC / 1000, 49_900 * BAZAAR_SCALE);
        _setVaultPendingLiq(BTC / 1000, 49_900, 48_000, true);

        uint256 keeperBefore = usdc.balanceOf(seq);
        assertEq(_unloadVault(), BTC / 1000, "dust unload still executes");
        assertEq(usdc.balanceOf(seq), keeperBefore, "no reward for sub-$100 unloads");
    }

    // ============================================================
    // Inline unload inside liquidate()
    // ============================================================

    function test_liquidate_inlineUnload_absorbsIntoRestingBid() public {
        _setupInsolventAlice(); // 0.1 BTC long, $5,005 entry basis, $10 collateral
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, BTC / 10, 49_950 * BAZAAR_SCALE);

        vm.prank(dave);
        bytes[] memory pu = _freshPrice();
        // Build the update before the prank is consumed by an external call.
        vm.stopPrank();
        vm.prank(dave);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "alice liquidated");

        assertEq(_pendingLiqSize(), 0, "inline unload absorbed the whole seizure in the same tx");
        assertEq(_posSize(carol), BTC / 10, "resting bidder inherited the position");
        assertEq(_posSize(alice), 0);
    }

    function test_liquidate_inlineUnload_emptyBook_leavesInventory() public {
        _setupInsolventAlice();
        vm.prank(dave);
        assertEq(pair.liquidate(_arr1(alice), _freshPrice()), 1, "alice liquidated");
        assertEq(_pendingLiqSize(), BTC / 10, "no liquidity: inventory awaits unloadVault");
    }
}
