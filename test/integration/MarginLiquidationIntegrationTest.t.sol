// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title MarginLiquidationIntegrationTest
/// @notice End-to-end margin/liquidation flows: the 24h-lagged-MMR sampling + walk-back through the
///         real pair, liquidation refreshing the margin curve, close/reduce round-trips realizing
///         PnL, and IMR-gated withdrawal solvency.
contract MarginLiquidationIntegrationTest is IntegrationBase {
    /// @dev Drive one hourly MMR sample into the pair's ring buffer by re-submitting a resting,
    ///      non-crossing order through matchBatch (which records a sample before it processes fills).
    function _sampleHour(uint256 restId) internal {
        vm.warp(block.timestamp + 1 hours);
        _roll(1);
        _match(_lists(_one(restId), _empty(), _empty(), _empty()), 1);
    }

    // ============================ 24h-lagged MMR ============================

    /// @notice The lagged-MMR threshold only becomes available once ≥24h of hourly samples exist:
    ///         `getLaggedMmrBp()` walks the ring buffer for the newest sample ≥24h old. Before that
    ///         history accrues it returns 0 (falling back to entryMmrBp); after 24h it returns a real
    ///         historical MMR. This exercises MmrSampleLib.record + laggedMmr through the live pair.
    function test_e2e_LaggedMmr_BecomesAvailableAfter24hOfSamples() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        // A resting long limit far below oracle — never crosses (no counterparty), so it just keeps
        // the order live and lets each matchBatch record an MMR sample.
        uint256 restId = _placeLimit(alice, true, BAZAAR_SCALE / 100, 40_000 * BAZAAR_SCALE);
        vm.roll(block.number + 2);

        // One sample laid; nothing is ≥24h old yet.
        _sampleHour(restId);
        assertEq(pair.getLaggedMmrBp(), 0, "no >=24h-old sample yet");

        // Lay a full ring of hourly samples spanning >24h.
        for (uint256 i = 0; i < 25; i++) {
            _sampleHour(restId);
        }

        uint256 lagged = pair.getLaggedMmrBp();
        assertGt(lagged, 0, "a >=24h-old sample is now the lagged MMR");
        (, uint256 mmrNow,,) = pair.marginRequirements();
        assertGt(mmrNow, 0, "current MMR is set");
    }

    /// @notice A liquidation refreshes the margin curve (lastUpdateTs = now) and records an MMR
    ///         sample — so MMR sampling is not gated solely by matching activity. After 24h that
    ///         liquidation-time sample is exactly what `getLaggedMmrBp()` returns.
    function test_e2e_LaggedMmr_LiquidationRefreshesMarginAndSamples() public {
        _setupInsolventAlice();

        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), _freshPrice()), 1, "alice liquidated");

        (, uint256 mmrAfter, uint256 lastTs,) = pair.marginRequirements();
        assertEq(lastTs, block.timestamp, "margin curve refreshed at liquidation");
        assertGt(mmrAfter, 0, "MMR set");

        // The single liquidation-time sample becomes retrievable as the lagged MMR after 24h.
        vm.warp(block.timestamp + 24 hours + 1);
        assertEq(pair.getLaggedMmrBp(), mmrAfter, "liquidation-time sample is the lagged MMR");
    }

    /// @notice refreshPrice() is the permissionless way to advance the MMR sample ring through a
    ///         trading gap. With no fills and no liquidations the ring freezes, so laggedMmr()
    ///         keeps returning a sample with no ceiling on its age (here: a week old). Anyone can
    ///         then push a price refresh — it recomputes IMR/MMR and records a fresh sample, and
    ///         the lagged threshold catches up to reality once that sample ages past the grace
    ///         period, instead of never.
    function test_e2e_LaggedMmr_RefreshPriceAdvancesRingDuringTradingGap() public {
        // Lay one real sample via matchBatch, then go quiet.
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 restId = _placeLimit(alice, true, BAZAAR_SCALE / 100, 40_000 * BAZAAR_SCALE);
        vm.roll(block.number + 2);
        _sampleHour(restId);
        (, uint256 mmrAtFreeze,,) = pair.marginRequirements();

        // A week of silence: the week-old sample still rules the lagged threshold (no staleness
        // ceiling), and nothing on the matching/liquidation paths will ever advance it.
        vm.warp(block.timestamp + 7 days);
        assertEq(pair.getLaggedMmrBp(), mmrAtFreeze, "frozen ring: week-old sample still rules");

        // Permissionless poke from a non-sequencer outsider.
        bytes[] memory pu = _priceAt(50_000);
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        pair.refreshPrice{value: fee}(pu);

        (, uint256 mmrNow, uint256 lastTs,) = pair.marginRequirements();
        assertEq(lastTs, block.timestamp, "margin curve recomputed by the poke");

        // The poke-time sample supersedes the frozen one once it clears the 24h grace.
        vm.warp(block.timestamp + 24 hours + 1);
        assertEq(pair.getLaggedMmrBp(), mmrNow, "poke-time sample is the lagged MMR after 24h");
    }

    // ============================ close / reduce round-trip ============================

    /// @notice Full round-trip: open a matched long/short at $50k, then close both against each other
    ///         at $49k → positions go flat, realized PnL is folded into collateral, and the freed
    ///         collateral is withdrawable.
    function test_e2e_CloseRoundTrip_RealizesPnlAndWithdraws() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10; // 0.1 BTC

        // Open: alice long / bob short, fills at the older order's price ($50k).
        uint256 aL = _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE);
        uint256 bS = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(aL), _one(bS), _empty(), _empty()), 10), 1, "opened");
        assertEq(_posSize(alice), size, "alice long open");
        assertEq(_posSize(bob), size, "bob short open");

        // Close: alice's opposing short vs bob's opposing long — both positions net to flat.
        uint256 aS = _placeLimit(alice, false, size, 49_000 * BAZAAR_SCALE);
        uint256 bL = _placeLimit(bob, true, size, 51_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(bL), _one(aS), _empty(), _empty()), 10), 1, "closed");

        assertEq(_posSize(alice), 0, "alice flat");
        assertEq(_posSize(bob), 0, "bob flat");

        // Flat user (no position, no live orders) can withdraw freed collateral with an empty update.
        uint256 bal = usdc.balanceOf(alice);
        vm.prank(alice);
        pair.withdrawCollateral(5_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice), bal + 5_000 * USDC_SCALE, "freed collateral withdrawn");
    }

    // ============================ withdrawal solvency gating ============================

    /// @notice Withdrawals are gated on IMR: a user with an open position can only pull down to their
    ///         free collateral (availableEquity − IMR). Withdrawing the full equity reverts; a safe
    ///         fraction of the free collateral succeeds.
    function test_e2e_Withdrawal_SolvencyGating() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = 1 * BAZAAR_SCALE; // 1 BTC → $50k notional

        uint256 aL = _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE);
        uint256 bS = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(aL), _one(bS), _empty(), _empty()), 10), 1, "opened 1 BTC");

        BazaarTypes.BucketState memory st = lens.checkBucketSolvency(address(pair), alice, 50_000 * BAZAAR_SCALE);
        (uint256 imrBp,,,) = pair.marginRequirements();
        uint256 imrReq = imrBp * st.currentNotional / 10_000;
        assertGt(st.availableEquity, imrReq, "position has free collateral");
        uint256 free = st.availableEquity - imrReq;

        // Over-withdraw: pulling the whole equity leaves nothing for IMR → revert.
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        vm.expectRevert();
        pair.withdrawCollateral(st.availableEquity, pu, 0, 0, 0, "");

        // Safe: half the free collateral clears the IMR gate.
        uint256 safe = free / 2;
        uint256 bal = usdc.balanceOf(alice);
        pu = _freshPrice();
        vm.prank(alice);
        pair.withdrawCollateral(safe, pu, 0, 0, 0, "");
        assertEq(usdc.balanceOf(alice), bal + safe * USDC_SCALE / BAZAAR_SCALE, "safe withdrawal returned USDC");
    }
}
