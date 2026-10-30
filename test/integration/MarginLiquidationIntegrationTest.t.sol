// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title MarginLiquidationIntegrationTest
/// @notice End-to-end margin/liquidation flows: the 24h-lagged-MMR sampling + walk-back through the
///         real pair, liquidation refreshing the margin curve, close/reduce round-trips realizing
///         PnL, and IMR-gated withdrawal solvency.
contract MarginLiquidationIntegrationTest is IntegrationBase {
    /// @dev Drive one hourly MMR sample into the pair's ring buffer: every order arrival refreshes
    ///      the margin curve and records a sample (at most one per MMR_SAMPLE_INTERVAL), so a
    ///      far-from-market resting bid placed each hour keeps the ring advancing.
    function _sampleHour() internal {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _roll(1);
        _placeLimit(alice, true, BAZAAR_SCALE / 100, 40_000 * BAZAAR_SCALE);
    }

    /// @dev Permissionless price poke stamped now: records an MMR sample and advances the mark the
    ///      lagged-MMR lookback is measured back from.
    function _pokePrice(uint256 priceUsd) internal {
        bytes[] memory pu = _priceAt(priceUsd);
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        pair.refreshPrice{value: fee}(pu);
    }

    // ============================ 24h-lagged MMR ============================

    /// @notice A pair younger than the grace period has no sample old enough to open a 24h window,
    ///         and `getLaggedMmr()` falls back to the lowest rate it has recorded, so positions on a
    ///         new pair still get a lagged threshold. Once ≥24h of hourly samples exist, the window
    ///         opens on the newest sample ≥24h old. This exercises MmrSampleLib.record + laggedMmr
    ///         through the live pair.
    function test_e2e_LaggedMmr_YoungPairUsesItsWholeHistory() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        // A resting long limit far below oracle — never crosses (no counterparty). The arrival
        // itself records the first MMR sample; each hourly placement records another.
        _placeLimit(alice, true, BAZAAR_SCALE / 100, 40_000 * BAZAAR_SCALE);
        _roll(2);
        (, uint256 mmrAtStart,,) = pair.marginRequirements();

        // A second sample an hour later; nothing is ≥24h old yet, so the whole history counts.
        _sampleHour();
        uint256 laggedEarly = pair.getLaggedMmr();
        assertGt(laggedEarly, 0, "a young pair still has a lagged MMR");
        assertLe(laggedEarly, mmrAtStart, "the lowest rate recorded so far");

        // Lay a full ring of hourly samples spanning >24h.
        for (uint256 i = 0; i < 25; i++) {
            _sampleHour();
        }

        uint256 lagged = pair.getLaggedMmr();
        assertGt(lagged, 0, "a >=24h-old sample now opens the window");
        (, uint256 mmrNow,,) = pair.marginRequirements();
        assertGt(mmrNow, 0, "current MMR is set");
    }

    /// @notice A liquidation refreshes the margin curve (lastUpdateTs = now) and records the rate it
    ///         sets, so the ring is not advanced by order arrivals alone: the record is in the
    ///         lagged minimum at once, through the open interval.
    function test_e2e_LaggedMmr_LiquidationRefreshesMarginAndSamples() public {
        _setupInsolventAlice();

        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), _freshPrice()), 1, "alice liquidated");

        (, uint256 mmrAfter, uint256 lastTs,) = pair.marginRequirements();
        assertEq(lastTs, vm.getBlockTimestamp(), "margin curve refreshed at liquidation");
        assertGt(mmrAfter, 0, "MMR set");
        uint256 lagged = pair.getLaggedMmr();
        assertGt(lagged, 0, "the pair has a lagged MMR");
        assertLe(lagged, mmrAfter, "no higher than the rate the liquidation recorded");

        // A day later, with a fresh mark, the window opens on the interval in force at the
        // liquidation; the rate has not moved since, so that is the lagged MMR.
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        _pokePrice(50_000);
        assertEq(pair.getLaggedMmr(), mmrAfter, "liquidation-time rate is the lagged MMR");
    }

    /// @notice refreshPrice() is the permissionless way to keep both halves of the lagged
    ///         threshold moving through a trading gap: it recomputes the margin curve, records the
    ///         rate it sets, and advances the mark the grace period is measured back from. A silent
    ///         week moves neither, and the pair keeps the lagged rate it had before the gap.
    function test_e2e_LaggedMmr_RefreshPriceAdvancesRingDuringTradingGap() public {
        // Lay real samples via order arrivals, then go quiet.
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, BAZAAR_SCALE / 100, 40_000 * BAZAAR_SCALE);
        _roll(2);
        _sampleHour();
        (, uint256 mmrPreGap,,) = pair.marginRequirements();

        // A week of silence advances neither the ring nor the mark.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 laggedFrozen = pair.getLaggedMmr();
        assertGt(laggedFrozen, 0, "frozen mark: the pre-gap lagged rate stands");
        assertLe(laggedFrozen, mmrPreGap, "no higher than the pre-gap rate");

        // Permissionless poke from an outsider with no orders or position: it recomputes the curve
        // and records the rate it sets.
        _pokePrice(50_000);
        (, uint256 mmrNow, uint256 lastTs,) = pair.marginRequirements();
        assertEq(lastTs, vm.getBlockTimestamp(), "margin curve recomputed by the poke");
        assertLe(pair.getLaggedMmr(), mmrNow, "the poke's record is in the lagged minimum");

        // A day later a second poke's mark puts the first poke's interval at the cutoff.
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        _pokePrice(50_000);
        assertEq(pair.getLaggedMmr(), mmrNow, "poke-time rate is the lagged MMR once a 24h-newer mark exists");
    }

    // ============================ close / reduce round-trip ============================

    /// @notice Full round-trip: open a matched long/short at $50k, then close both against each other
    ///         at $49k → positions go flat, realized PnL is folded into collateral, and the freed
    ///         collateral is withdrawable.
    function test_e2e_CloseRoundTrip_RealizesPnlAndWithdraws() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10; // 0.1 BTC

        // Open: alice's bid rests, bob's crossing short fills at the resting maker's price ($50k).
        _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), size, "alice long open");
        assertEq(_posSize(bob), size, "bob short open");

        // Close: alice's opposing short rests at $49k; bob's opposing long crosses it — both
        // positions net to flat at the $49k maker price.
        _placeLimit(alice, false, size, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, true, size, 51_000 * BAZAAR_SCALE);

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

        _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), size, "opened 1 BTC");

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
