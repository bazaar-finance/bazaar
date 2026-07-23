// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title PostFillAccountingTest
/// @notice Everything that happens AFTER a match is accepted: position state transitions beyond
///         open/full-close (partial close, flip), the TP/SL oversize fence, vault OI aggregates,
///         the fee-settlement pipeline (user debits -> sequencer/bug-bounty/insurance/integrator
///         routing), Pass A maker safety, the Pass B fill-price rule, and bucket slot clearing.
contract PostFillAccountingTest is IntegrationBase {
    using stdStorage for StdStorage;

    // ---------------------------- local helpers ----------------------------

    function _setVaultPendingLiq(uint256 size, uint256 entryPrice, uint256 bankruptcyPrice, bool isLong) internal {
        _stdstore.target(address(pair)).sig("pairVault()").depth(6).checked_write(size);
        _stdstore.target(address(pair)).sig("pairVault()").depth(7).checked_write(size * entryPrice / BAZAAR_SCALE);
        _stdstore.target(address(pair)).sig("pairVault()").depth(8).checked_write(size * bankruptcyPrice / BAZAAR_SCALE);
        _stdstore.target(address(pair)).sig("pairVault()").depth(10).checked_write(isLong);
    }

    function _placeLimitWithIntegrator(address user, bool isLong, uint256 size, uint256 limitPrice, address integrator)
        internal
        returns (uint256)
    {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        pair.createOrder(
            BazaarTypes.OrderType.Limit,
            0,
            limitPrice,
            0,
            size,
            isLong,
            false,
            uint64(vm.getBlockNumber() + 500_000),
            integrator,
            pu,
            0,
            0,
            0,
            ""
        );
        return _newestLimitOrderId(user);
    }

    function _openAt50k(uint256 size) internal {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 aL = _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE); // older -> fill $50k
        uint256 bS = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(aL), _one(bS), _empty(), _empty()), 10), 1, "opened at 50k");
    }

    function _posEntryValue(address user) internal view returns (uint256 ev) {
        (,, ev,,,,,,,) = pair.positionBuckets(user);
    }

    function _mmrUpdateTs(address user) internal view returns (uint256 ts) {
        (,,,,,,,,, ts) = pair.positionBuckets(user);
    }

    function _totalCollateral() internal view returns (uint256 c) {
        (,,,, c,,,,,,,) = pair.pairVault();
    }

    // ============================ partial close / flip ============================

    /// @notice Partial close via matchBatch: pro-rata entryValue reduction, realized loss folded
    ///         into collateral, remainder stays long.
    function test_partialClose_proRataEntry_andRealizedPnl() public {
        _openAt50k(2 * BAZAAR_SCALE / 10); // alice long 0.2 @ 50k
        assertEq(_posEntryValue(alice), 10_000 * BAZAAR_SCALE, "entry 0.2 x 50k");
        uint256 collBefore = _posCollateral(alice);

        // Alice sells 0.1 (older order -> fill at her $49k limit): realizes a $100 loss.
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 aS = _placeLimit(alice, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        uint256 cL = _placeLimit(carol, true, BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(cL), _one(aS), _empty(), _empty()), 10), 1, "partial close matched");

        (bool isLong, uint256 size) = _position(alice);
        assertTrue(isLong, "remainder still long");
        assertEq(size, BAZAAR_SCALE / 10, "half closed");
        assertEq(_posEntryValue(alice), 5_000 * BAZAAR_SCALE, "entryValue reduced pro-rata");
        // Realized loss (100) + close fees come out of collateral.
        assertLt(_posCollateral(alice), collBefore - 100 * BAZAAR_SCALE + 1, "realized loss debited");
    }

    /// @notice Flip via matchBatch: an oversized opposing fill closes the position and reopens the
    ///         remainder on the other side at the fill price, restamping the MMR clock.
    function test_flip_reopensRemainderOnOppositeSide() public {
        _openAt50k(BAZAAR_SCALE / 10); // alice long 0.1 @ 50k

        _deposit(carol, 30_000 * BAZAAR_SCALE);
        uint256 aS = _placeLimit(alice, false, 3 * BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE); // older -> fill 49k
        uint256 cL = _placeLimit(carol, true, 3 * BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(cL), _one(aS), _empty(), _empty()), 10), 1, "flip matched");

        (bool isLong, uint256 size) = _position(alice);
        assertFalse(isLong, "flipped short");
        assertEq(size, 2 * BAZAAR_SCALE / 10, "remainder 0.2");
        assertEq(_posEntryValue(alice), 2 * BAZAAR_SCALE / 10 * 49_000, "fresh entry at the fill price");
        assertEq(_mmrUpdateTs(alice), vm.getBlockTimestamp(), "MMR clock restamped on flip");
    }

    // ============================ TP/SL oversize fence ============================

    /// @notice A TakeProfit larger than the shrunken position is auto-canceled by the fence.
    function test_fence_oversizedTakeProfitCanceledOnPartialClose() public {
        _openAt50k(2 * BAZAAR_SCALE / 10);
        uint256 tpId = _placeTakeProfit(alice, false, 2 * BAZAAR_SCALE / 10, 55_000 * BAZAAR_SCALE);
        assertEq(_takeProfitOrderId(alice), tpId, "TP attached");

        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 aS = _placeLimit(alice, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        uint256 cL = _placeLimit(carol, true, BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(cL), _one(aS), _empty(), _empty()), 10), 1, "partial close");

        assertEq(_takeProfitOrderId(alice), 0, "oversized TP detached");
        assertGt(_canceledBlock(tpId), 0, "TP order canceled");
    }

    /// @notice Same fence for an oversized StopLoss.
    function test_fence_oversizedStopLossCanceledOnPartialClose() public {
        _openAt50k(2 * BAZAAR_SCALE / 10);
        uint256 slId = _placeStopLoss(alice, false, 2 * BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE, 500);
        assertEq(_stopLossOrderId(alice), slId, "SL attached");

        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 aS = _placeLimit(alice, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        uint256 cL = _placeLimit(carol, true, BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(cL), _one(aS), _empty(), _empty()), 10), 1, "partial close");

        assertEq(_stopLossOrderId(alice), 0, "oversized SL detached");
        assertGt(_canceledBlock(slId), 0, "SL order canceled");
    }

    // ============================ vault OI aggregates ============================

    /// @notice OI and weighted entry sums track real matches: symmetric on open, zero after close.
    function test_oiAggregates_openThenCloseRoundTrip() public {
        _openAt50k(BAZAAR_SCALE / 10);
        (uint256 longOI, uint256 shortOI, uint256 longSum, uint256 shortSum,,,,,,,,) = pair.pairVault();
        assertEq(longOI, BAZAAR_SCALE / 10, "long OI == size");
        assertEq(shortOI, BAZAAR_SCALE / 10, "short OI == size");
        assertEq(longSum, 5_000 * BAZAAR_SCALE, "long weighted entry == fill notional");
        assertEq(shortSum, 5_000 * BAZAAR_SCALE, "short weighted entry == fill notional");

        // Close both against each other.
        uint256 aS = _placeLimit(alice, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        uint256 bL = _placeLimit(bob, true, BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(bL), _one(aS), _empty(), _empty()), 10), 1, "closed");

        (longOI, shortOI, longSum, shortSum,,,,,,,,) = pair.pairVault();
        assertEq(longOI, 0, "long OI zeroed");
        assertEq(shortOI, 0, "short OI zeroed");
        assertEq(longSum, 0, "long sum zeroed");
        assertEq(shortSum, 0, "short sum zeroed");
    }

    // ============================ fee plumbing ============================

    /// @notice The full fee pipeline on one clean open match: user collateral debits equal the fee
    ///         total, the aggregate books drop by the same amount, and every debited unit lands with
    ///         the sequencer (99% of seq fees), the bug bounty (1% tax), or insurance (the rest).
    function test_feePipeline_conservationAndRouting() public {
        address bugBounty = makeAddr("bugBounty"); // same label the deployment used
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;

        uint256 aL = _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE); // maker, fill == oracle
        uint256 bS = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        _roll(2);

        uint256 aCollBefore = _posCollateral(alice);
        uint256 bCollBefore = _posCollateral(bob);
        uint256 aggBefore = _totalCollateral();
        uint256 insBefore = _insuranceBal();
        uint256 seqUsdcBefore = usdc.balanceOf(seq);
        uint256 bbUsdcBefore = usdc.balanceOf(bugBounty);

        assertEq(_match(_lists(_one(aL), _one(bS), _empty(), _empty()), 10), 1, "matched");

        // Fill at oracle ($50k) -> zero incipient loss, zero PnL: all collateral movement is fees.
        uint256 totalFees = (aCollBefore - _posCollateral(alice)) + (bCollBefore - _posCollateral(bob));
        assertGt(totalFees, 0, "fees were charged");
        assertEq(aggBefore - _totalCollateral(), totalFees, "aggregate books mirror the user debits");

        uint256 seqGain = (usdc.balanceOf(seq) - seqUsdcBefore) * 1e12;
        uint256 bbGain = (usdc.balanceOf(bugBounty) - bbUsdcBefore) * 1e12;
        uint256 insGain = _insuranceBal() - insBefore;

        // 1% of everything goes to the bug bounty.
        assertApproxEqAbs(bbGain, totalFees / 100, 3e12, "bug bounty tax = 1% of total fees");
        // Every debited unit is routed somewhere (allow USDC-flooring dust on the two transfers).
        assertApproxEqAbs(seqGain + bbGain + insGain, totalFees, 3e12, "conservation: fees fully routed");

        // The sequencer leg is exactly derivable: maker 25 EBP + dynamic taker EBP + 2 flat fees.
        uint256 fillNotional = 5_000 * BAZAAR_SCALE;
        uint256 takerEbp = sequencer.getDynamicTakerSequencerFee();
        uint256 userSeqFees = fillNotional * 25 / 1_000_000 + fillNotional * takerEbp / 1_000_000 + 2
            * BazaarTypes.SEQUENCER_FLAT_FEE_PER_SIDE;
        assertApproxEqAbs(seqGain, userSeqFees * 99 / 100, 2e12, "sequencer gets 99% of seq fees");
    }

    /// @notice Integrator routing: each side's integrator fee goes to that order's integrator (99%,
    ///         1% bug-bounty tax); orders without an integrator (address(0)) are charged no
    ///         integrator fee at all.
    function test_integratorFees_distinctIntegratorsAndZeroAddress() public {
        address integratorX = makeAddr("integratorX");
        address integratorY = makeAddr("integratorY");
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;
        uint256 fillNotional = 5_000 * BAZAAR_SCALE;

        // Match 1: alice(maker, X) vs bob(taker, Y) -> each side's 25 EBP fee to its integrator.
        uint256 aL = _placeLimitWithIntegrator(alice, true, size, 50_000 * BAZAAR_SCALE, integratorX);
        uint256 bS = _placeLimitWithIntegrator(bob, false, size, 49_000 * BAZAAR_SCALE, integratorY);
        _roll(2);
        assertEq(_match(_lists(_one(aL), _one(bS), _empty(), _empty()), 10), 1, "matched with integrators");

        uint256 sideFee = fillNotional * 25 / 1_000_000; // 25 EBP each side
        uint256 expectedNet = (sideFee * 9_900 / 10_000) / 1e12; // 99%, floored to USDC
        assertEq(usdc.balanceOf(integratorX), expectedNet, "maker integrator paid its side's fee");
        assertEq(usdc.balanceOf(integratorY), expectedNet, "taker integrator paid its side's fee");

        // Match 2: both sides integrator address(0) -> NO integrator fee is charged at all.
        // Direct-to-contract traders don't pay for a front-end they didn't use, and nothing
        // extra lands in insurance: the fund grows by the maker insurance fee only (net of
        // bug-bounty tax). The cross fills at the resting short's 49,000 -> $4,900 notional.
        uint256 insBefore = _insuranceBal();
        uint256 aS = _placeLimit(alice, false, size, 49_000 * BAZAAR_SCALE);
        uint256 bL = _placeLimit(bob, true, size, 51_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(bL), _one(aS), _empty(), _empty()), 10), 1, "matched without integrators");

        uint256 makerInsFee = (4_900 * BAZAAR_SCALE) * 50 / 1_000_000;
        assertEq(
            _insuranceBal() - insBefore,
            makerInsFee * 9_900 / 10_000,
            "no integrator fee charged or routed to insurance"
        );
        assertEq(usdc.balanceOf(integratorX), expectedNet, "integrator X unchanged by integrator-less match");
        assertEq(usdc.balanceOf(integratorY), expectedNet, "integrator Y unchanged by integrator-less match");
    }

    /// @notice Regression: each match can append TWO distinct integrators (one per side).
    ///         With four unique integrators across two matches and maxMatches = 2, the old
    ///         maxMatches-sized accums buffer (2 slots) overflowed on the third append and
    ///         reverted the whole batch (Panic 0x32) — a griefing vector via a book seeded
    ///         with unique integrator addresses. The buffer is now sized to 2x the fill bound.
    function test_integratorAccums_twoIntegratorsPerMatch_noOverflow() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);

        uint256 size = BAZAAR_SCALE / 10;
        // Two independent crosses, four distinct integrators.
        uint256 aL = _placeLimitWithIntegrator(alice, true, size, 50_000 * BAZAAR_SCALE, makeAddr("uniqInt1"));
        uint256 cL = _placeLimitWithIntegrator(carol, true, size, 50_000 * BAZAAR_SCALE, makeAddr("uniqInt2"));
        uint256 bS = _placeLimitWithIntegrator(bob, false, size, 49_000 * BAZAAR_SCALE, makeAddr("uniqInt3"));
        uint256 dS = _placeLimitWithIntegrator(dave, false, size, 49_000 * BAZAAR_SCALE, makeAddr("uniqInt4"));

        _roll(2);
        uint256 success = _match(_lists(_two(aL, cL), _two(bS, dS), _empty(), _empty()), 2);

        assertEq(success, 2, "both crosses fill; 4 distinct integrators fit the accums buffer");
    }

    // ============================ Pass A maker safety ============================

    /// @notice Pass A margin re-check: a maker whose collateral no longer covers fresh IMR is NOT
    ///         filled against the vault's liquidation inventory — the order is auto-canceled.
    function test_passA_makerFailingImr_autoCanceledNotFilled() public {
        _deposit(alice, 2_000 * BAZAAR_SCALE);
        uint256 liqSize = BAZAAR_SCALE / 10;
        uint256 longId = _placeLimit(alice, true, liqSize, 49_800 * BAZAAR_SCALE);

        // Alice's collateral evaporates after creation (simulating consumption elsewhere).
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(alice).depth(3)
            .checked_write(uint256(100 * BAZAAR_SCALE));

        _setVaultPendingLiq(liqSize, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);
        _roll(2);
        uint256 success = _match(_lists(_one(longId), _empty(), _empty(), _empty()), 10);

        assertEq(success, 0, "no fill against an under-margined maker");
        assertEq(_filledSize(longId), 0, "order unfilled");
        assertGt(_canceledBlock(longId), 0, "failing maker auto-canceled");
        (,,,,,, uint256 pendSize,,,,,) = pair.pairVault();
        assertEq(pendSize, liqSize, "vault inventory untouched");
    }

    // ============================ Pass B fill-price rule ============================

    /// @notice A market taker fills at the RESTING limit's price, not at its own slippage bound.
    function test_passB_marketFillsAtRestingLimitPrice() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;

        uint256 shortId = _placeLimit(bob, false, size, 50_500 * BAZAAR_SCALE);
        uint256 marketId = _placeMarket(alice, true, size, 500); // bound $52.5k >> $50.5k
        _roll(2);
        assertEq(_match(_lists(_empty(), _one(shortId), _one(marketId), _empty()), 10), 1, "filled");

        assertEq(_posEntryValue(alice), size * 50_500, "entry at the maker's $50.5k, not the bound");
    }

    // ============================ bucket slot clearing ============================

    /// @notice A fully-filled TakeProfit clears its bucket slot so a fresh TP can be attached.
    function test_persistFill_takeProfitSlotClearedOnFullFill() public {
        _openAt50k(BAZAAR_SCALE / 10);
        uint256 tpId = _placeTakeProfit(alice, false, BAZAAR_SCALE / 10, 50_500 * BAZAAR_SCALE);

        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 cL = _placeLimit(carol, true, BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        _roll(2);
        assertEq(_match(_lists(_one(cL), _one(tpId), _empty(), _empty()), 10), 1, "TP filled");

        assertEq(_filledSize(tpId), BAZAAR_SCALE / 10, "TP fully filled");
        assertEq(_takeProfitOrderId(alice), 0, "TP slot cleared");
        assertEq(_posSize(alice), 0, "position closed by the TP");
    }

    /// @notice A fully-filled market order clears activeMarketOrderId so the next one can be placed.
    function test_persistFill_marketSlotClearedOnFullFill() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;

        uint256 shortId = _placeLimit(bob, false, size, 50_500 * BAZAAR_SCALE);
        uint256 marketId = _placeMarket(alice, true, size, 500);
        _roll(2);
        assertEq(_match(_lists(_empty(), _one(shortId), _one(marketId), _empty()), 10), 1, "market filled");

        assertEq(_activeMarketOrderId(alice), 0, "market slot cleared");
        // A fresh market order can be created immediately (no ActiveMarketOrderExists revert).
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 short2 = _placeLimit(carol, false, size, 50_500 * BAZAAR_SCALE);
        uint256 market2 = _placeMarket(alice, true, size, 500);
        assertGt(market2, 0, "second market order accepted");
        assertGt(short2, 0);
    }
}
