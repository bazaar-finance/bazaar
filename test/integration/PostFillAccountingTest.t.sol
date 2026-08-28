// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";

/// @title PostFillAccountingTest
/// @notice Everything that happens AFTER an arrival fill settles: position state transitions
///         beyond open/full-close (partial close, flip), the TP/SL oversize fence, vault OI
///         aggregates, the fee pipeline (user debits -> insurance/bug-bounty/integrator
///         routing), the vault-unload maker margin re-check, the maker-price fill rule, and
///         bucket slot clearing.
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
        bytes[] memory pu = _freshPrice(); // build BEFORE the prank (external mockPyth call would consume it)
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Limit;
        s.isLong = isLong;
        s.size = size;
        s.limitPrice = limitPrice;
        s.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        s.integrator = integrator;
        vm.prank(user);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "");
        return _lastCreatedOrderId(pair);
    }

    /// @dev Open alice long `size` against bob at exactly $50k: alice's bid is placed first
    ///      (older id -> resting maker), so bob's crossing sell fills at her $50k limit.
    /// @dev Set the insurance fund's balance directly, to position a scenario on a chosen side
    ///      of the fee curve's surplus/deficit split. Lowering I below cash only widens the
    ///      one-directional Check-3 margin, so vault health stays green.
    function _drainInsuranceTo(uint256 target) internal {
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(target);
    }

    function _openAt50k(uint256 size) internal {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE); // older -> fill $50k
        _roll(2);
        _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), size, "opened at 50k");
    }

    function _posEntryValue(address user) internal view returns (uint256 ev) {
        (,, ev,,,,,,) = pair.positionBuckets(user);
    }

    function _mmrUpdateTs(address user) internal view returns (uint256 ts) {
        (,,,,,,,, ts) = pair.positionBuckets(user);
    }

    // ============================ partial close / flip ============================

    /// @notice Partial close via a crossing arrival: pro-rata entryValue reduction, realized loss
    ///         folded into collateral, remainder stays long.
    function test_partialClose_proRataEntry_andRealizedPnl() public {
        _openAt50k(2 * BAZAAR_SCALE / 10); // alice long 0.2 @ 50k
        assertEq(_posEntryValue(alice), 10_000 * BAZAAR_SCALE, "entry 0.2 x 50k");
        uint256 collBefore = _posCollateral(alice);

        // Alice rests a 0.1 sell at her $49k limit (maker); carol's crossing buy fills it there,
        // realizing a $100 loss on the closed half.
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(carol, true, BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);

        (bool isLong, uint256 size) = _position(alice);
        assertTrue(isLong, "remainder still long");
        assertEq(size, BAZAAR_SCALE / 10, "half closed");
        assertEq(_posEntryValue(alice), 5_000 * BAZAAR_SCALE, "entryValue reduced pro-rata");
        // Realized loss (100) + close fees come out of collateral.
        assertLt(_posCollateral(alice), collBefore - 100 * BAZAAR_SCALE + 1, "realized loss debited");
    }

    /// @notice Flip: an oversized opposing fill closes the position and reopens the remainder on
    ///         the other side at the fill price, restamping the MMR clock.
    function test_flip_reopensRemainderOnOppositeSide() public {
        _openAt50k(BAZAAR_SCALE / 10); // alice long 0.1 @ 50k

        // Advance time so the restamp is distinguishable from the open's stamp.
        vm.warp(vm.getBlockTimestamp() + 100);
        _deposit(carol, 30_000 * BAZAAR_SCALE);
        _placeLimit(alice, false, 3 * BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE); // older -> fill 49k
        _roll(2);
        _placeLimit(carol, true, 3 * BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);

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

        // Partial close 0.1: carol's buy takes alice's $49k ask (the TP rests deeper at $55k).
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(carol, true, BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), BAZAAR_SCALE / 10, "partial close filled");

        assertEq(_takeProfitOrderId(alice), 0, "oversized TP detached");
        assertGt(_canceledBlock(tpId), 0, "TP order canceled");
    }

    /// @notice Same fence for an oversized StopLoss.
    function test_fence_oversizedStopLossCanceledOnPartialClose() public {
        _openAt50k(2 * BAZAAR_SCALE / 10);
        uint256 slId = _placeStopLoss(alice, false, 2 * BAZAAR_SCALE / 10, 45_000 * BAZAAR_SCALE, 500);
        assertEq(_stopLossOrderId(alice), slId, "SL attached");

        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(carol, true, BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), BAZAAR_SCALE / 10, "partial close filled");

        assertEq(_stopLossOrderId(alice), 0, "oversized SL detached");
        assertGt(_canceledBlock(slId), 0, "SL order canceled");
    }

    // ============================ vault OI aggregates ============================

    /// @notice OI and weighted entry sums track real fills: symmetric on open, zero after close.
    function test_oiAggregates_openThenCloseRoundTrip() public {
        _openAt50k(BAZAAR_SCALE / 10);
        (uint256 longOI, uint256 shortOI, uint256 longSum, uint256 shortSum,,,,,,,,) = pair.pairVault();
        assertEq(longOI, BAZAAR_SCALE / 10, "long OI == size");
        assertEq(shortOI, BAZAAR_SCALE / 10, "short OI == size");
        assertEq(longSum, 5_000 * BAZAAR_SCALE, "long weighted entry == fill notional");
        assertEq(shortSum, 5_000 * BAZAAR_SCALE, "short weighted entry == fill notional");

        // Close both against each other: alice's resting $49k ask takes bob's crossing buy.
        _placeLimit(alice, false, BAZAAR_SCALE / 10, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, true, BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), 0, "closed");

        (longOI, shortOI, longSum, shortSum,,,,,,,,) = pair.pairVault();
        assertEq(longOI, 0, "long OI zeroed");
        assertEq(shortOI, 0, "short OI zeroed");
        assertEq(longSum, 0, "long sum zeroed");
        assertEq(shortSum, 0, "short sum zeroed");
    }

    // ============================ fee plumbing ============================

    /// @notice The full fee pipeline on one clean open fill: the maker is debited exactly the
    ///         flat maker insurance rate, the taker the dynamic (deficit-priced) insurance rate,
    ///         the aggregate deposits ledger drops by the same total, and every debited unit
    ///         lands with insurance or the bug bounty (1% tax) — nowhere else.
    function test_feePipeline_conservationAndRouting() public {
        address bugBounty = makeAddr("bugBounty"); // same label the deployment used
        // Seed open interest, then drain the insurance fund below its target ratio: at genesis
        // the $5k seed fully covers $5k of OI (deep surplus), where the dynamic taker rate
        // legitimately prices at ZERO — which would leave the taker leg untested. Under-target,
        // the deficit curve prices it at or above the base rate.
        _openAt50k(BAZAAR_SCALE / 10);
        _drainInsuranceTo(50 * BAZAAR_SCALE);

        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;
        uint256 fillNotional = 5_000 * BAZAAR_SCALE;

        _placeLimit(carol, true, size, 50_000 * BAZAAR_SCALE); // maker, fill == oracle
        _roll(2);

        uint256 cCollBefore = _posCollateral(carol);
        uint256 dCollBefore = _posCollateral(dave);
        uint256 aggBefore = _totalDeposited();
        uint256 insBefore = _insuranceBal();
        uint256 bbUsdcBefore = usdc.balanceOf(bugBounty);

        _placeLimit(dave, false, size, 49_000 * BAZAAR_SCALE); // taker, crosses at carol's $50k

        // Fill at oracle ($50k) -> zero incipient PnL: all collateral movement is fees.
        uint256 makerFee = fillNotional * BazaarTypes.MAKER_INSURANCE_FEE_EBP / BazaarTypes.EBP_SCALE;
        uint256 carolDebit = cCollBefore - _posCollateral(carol);
        uint256 daveDebit = dCollBefore - _posCollateral(dave);
        assertEq(carolDebit, makerFee, "maker pays exactly the flat 0.5bp insurance fee");
        // The taker's dynamic rate stays within the curve's bounds: at least the base rate
        // (deficit multiplier >= 1x), at most the hard cap.
        assertGe(
            daveDebit,
            fillNotional * RiskParamsLib.TAKER_INSURANCE_FEE_MIN_EBP / BazaarTypes.EBP_SCALE,
            "dynamic taker fee >= base insurance rate"
        );
        assertLe(
            daveDebit,
            fillNotional * RiskParamsLib.TAKER_INSURANCE_FEE_CAP_EBP / BazaarTypes.EBP_SCALE,
            "dynamic taker fee <= hard cap"
        );

        uint256 totalFees = carolDebit + daveDebit;
        assertEq(aggBefore - _totalDeposited(), totalFees, "aggregate books mirror the user debits");

        uint256 bbGain = (usdc.balanceOf(bugBounty) - bbUsdcBefore) * 1e12;
        uint256 insGain = _insuranceBal() - insBefore;
        // 1% of the insurance stream goes to the bug bounty; the rest accrues to the fund.
        // Tolerances absorb the USDC-flooring dust on the bounty transfer.
        assertApproxEqAbs(bbGain, totalFees / 100, 2e12, "bug bounty tax = 1% of total fees");
        assertApproxEqAbs(insGain + bbGain, totalFees, 2e12, "conservation: fees fully routed");
    }

    /// @notice Integrator routing: each side's integrator fee goes to that order's integrator
    ///         (99%, 1% bug-bounty tax); orders without an integrator (address(0)) are charged
    ///         no integrator fee at all.
    function test_integratorFees_distinctIntegratorsAndZeroAddress() public {
        address integratorX = makeAddr("integratorX");
        address integratorY = makeAddr("integratorY");
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;
        uint256 fillNotional = 5_000 * BAZAAR_SCALE;

        // Cross 1: alice (maker, X) vs bob (taker, Y) -> each side's 0.25bp fee to its integrator.
        _placeLimitWithIntegrator(alice, true, size, 50_000 * BAZAAR_SCALE, integratorX);
        _roll(2);
        _placeLimitWithIntegrator(bob, false, size, 49_000 * BAZAAR_SCALE, integratorY);

        uint256 makerSideFee = fillNotional * BazaarTypes.MAKER_INTEGRATOR_FEE_EBP / BazaarTypes.EBP_SCALE;
        uint256 takerSideFee = fillNotional * BazaarTypes.TAKER_INTEGRATOR_FEE_EBP / BazaarTypes.EBP_SCALE;
        uint256 expectedNetX = (makerSideFee * 9_900 / 10_000) / 1e12; // 99%, floored to USDC
        uint256 expectedNetY = (takerSideFee * 9_900 / 10_000) / 1e12;
        assertEq(usdc.balanceOf(integratorX), expectedNetX, "maker integrator paid its side's fee");
        assertEq(usdc.balanceOf(integratorY), expectedNetY, "taker integrator paid its side's fee");

        // Cross 2: both sides integrator address(0) -> NO integrator fee is charged at all.
        // Alice's resting $49k ask closes her long; bob's crossing buy closes his short. The
        // realized PnL is an exact +-$100 wash between the two buckets, so the summed collateral
        // debits equal the summed fees — and full conservation into insurance + bug bounty
        // proves nothing was routed to any integrator. The fund is drained below target first:
        // in the genesis surplus the closing rate prices at zero, which would leave the taker
        // fee assertion vacuous.
        _drainInsuranceTo(50 * BAZAAR_SCALE);
        uint256 insBefore = _insuranceBal();
        uint256 bbUsdcBefore = usdc.balanceOf(makeAddr("bugBounty"));
        uint256 aCollBefore = _posCollateral(alice);
        uint256 bCollBefore = _posCollateral(bob);

        _placeLimit(alice, false, size, 49_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, true, size, 51_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), 0, "both closed");

        uint256 closeNotional = 4_900 * BAZAAR_SCALE;
        uint256 makerInsFee = closeNotional * BazaarTypes.MAKER_INSURANCE_FEE_EBP / BazaarTypes.EBP_SCALE;
        // Alice (maker) realizes the $100 loss and pays ONLY the flat maker insurance fee — no
        // integrator fee on an address(0) order.
        assertEq(
            aCollBefore - _posCollateral(alice),
            100 * BAZAAR_SCALE + makerInsFee,
            "maker debit = realized loss + 0.5bp insurance fee only"
        );
        // Bob (taker) realizes a $100 gain net of the closing-rate insurance fee, which never
        // prices below the curve's base rate.
        uint256 takerFee = 100 * BAZAAR_SCALE - (_posCollateral(bob) - bCollBefore);
        assertGe(
            takerFee,
            closeNotional * RiskParamsLib.TAKER_INSURANCE_FEE_MIN_EBP / BazaarTypes.EBP_SCALE,
            "taker pays at least the base closing rate"
        );

        uint256 insGain = _insuranceBal() - insBefore;
        uint256 bbGain = (usdc.balanceOf(makeAddr("bugBounty")) - bbUsdcBefore) * 1e12;
        assertApproxEqAbs(insGain + bbGain, makerInsFee + takerFee, 2e12, "all fees land in insurance + bounty");
        assertEq(usdc.balanceOf(integratorX), expectedNetX, "integrator X unchanged by integrator-less cross");
        assertEq(usdc.balanceOf(integratorY), expectedNetY, "integrator Y unchanged by integrator-less cross");
    }

    /// @notice One arrival can sweep several makers carrying DISTINCT integrators: every maker's
    ///         integrator receives its own side's fee and the taker's integrator accumulates
    ///         across all fills — four unique integrators paid out of a single walk.
    function test_integratorAccums_fourIntegratorsOneWalk_allRouted() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;

        // Three resting bids at $50k, three distinct maker integrators.
        uint256 aL = _placeLimitWithIntegrator(alice, true, size, 50_000 * BAZAAR_SCALE, makeAddr("uniqInt1"));
        uint256 cL = _placeLimitWithIntegrator(carol, true, size, 50_000 * BAZAAR_SCALE, makeAddr("uniqInt2"));
        uint256 dL = _placeLimitWithIntegrator(dave, true, size, 50_000 * BAZAAR_SCALE, makeAddr("uniqInt3"));
        _roll(2);
        // Bob's sell sweeps all three in one walk with a fourth integrator on the taker side.
        uint256 bS = _placeLimitWithIntegrator(bob, false, 3 * size, 49_000 * BAZAAR_SCALE, makeAddr("uniqInt4"));

        assertEq(_filledSize(bS), 3 * size, "taker swept all three makers");
        assertEq(_filledSize(aL), size, "maker 1 filled");
        assertEq(_filledSize(cL), size, "maker 2 filled");
        assertEq(_filledSize(dL), size, "maker 3 filled");

        uint256 makerNet = (5_000 * BAZAAR_SCALE * BazaarTypes.MAKER_INTEGRATOR_FEE_EBP / BazaarTypes.EBP_SCALE)
            * 9_900 / 10_000 / 1e12;
        uint256 takerNet = (15_000 * BAZAAR_SCALE * BazaarTypes.TAKER_INTEGRATOR_FEE_EBP / BazaarTypes.EBP_SCALE)
            * 9_900 / 10_000 / 1e12;
        assertEq(usdc.balanceOf(makeAddr("uniqInt1")), makerNet, "maker integrator 1 paid");
        assertEq(usdc.balanceOf(makeAddr("uniqInt2")), makerNet, "maker integrator 2 paid");
        assertEq(usdc.balanceOf(makeAddr("uniqInt3")), makerNet, "maker integrator 3 paid");
        assertEq(usdc.balanceOf(makeAddr("uniqInt4")), takerNet, "taker integrator accumulated all three fills");
    }

    // ============================ vault-unload maker safety ============================

    /// @notice Unload margin re-check: a resting maker whose collateral no longer covers fresh
    ///         IMR is NOT filled against the vault's liquidation inventory — the order is
    ///         auto-canceled and the inventory stays put.
    function test_unloadVault_makerFailingImr_autoCanceledNotFilled() public {
        _deposit(alice, 2_000 * BAZAAR_SCALE);
        uint256 liqSize = BAZAAR_SCALE / 10;
        uint256 longId = _placeLimit(alice, true, liqSize, 49_800 * BAZAAR_SCALE);

        // Alice's collateral evaporates after creation (simulating consumption elsewhere).
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(alice).depth(3)
            .checked_write(uint256(100 * BAZAAR_SCALE));

        _setVaultPendingLiq(liqSize, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);
        _roll(2);
        uint256 unloaded = _unloadVault();

        assertEq(unloaded, 0, "no fill against an under-margined maker");
        assertEq(_filledSize(longId), 0, "order unfilled");
        assertGt(_canceledBlock(longId), 0, "failing maker auto-canceled");
        (,,,,,, uint256 pendSize,,,,,) = pair.pairVault();
        assertEq(pendSize, liqSize, "vault inventory untouched");
    }

    // ============================ maker-price fill rule ============================

    /// @notice A market taker fills at the RESTING limit's price, not at its own slippage bound.
    function test_market_fillsAtRestingLimitPrice() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = BAZAAR_SCALE / 10;

        uint256 shortId = _placeLimit(bob, false, size, 50_500 * BAZAAR_SCALE);
        _roll(2);
        uint256 marketId = _placeMarket(alice, true, size, 500); // bound $52.5k >> $50.5k
        assertEq(_filledSize(marketId), size, "market filled");
        assertEq(_filledSize(shortId), size, "maker filled");

        assertEq(_posEntryValue(alice), size * 50_500, "entry at the maker's $50.5k, not the bound");
    }

    // ============================ bucket slot clearing ============================

    /// @notice A fully-filled TakeProfit clears its bucket slot so a fresh TP can be attached.
    function test_persistFill_takeProfitSlotClearedOnFullFill() public {
        _openAt50k(BAZAAR_SCALE / 10);
        uint256 tpId = _placeTakeProfit(alice, false, BAZAAR_SCALE / 10, 50_500 * BAZAAR_SCALE);

        // The TP rests in the book; carol's crossing buy fills it at its $50.5k limit.
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(carol, true, BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);

        assertEq(_filledSize(tpId), BAZAAR_SCALE / 10, "TP fully filled");
        assertEq(_takeProfitOrderId(alice), 0, "TP slot cleared");
        assertEq(_posSize(alice), 0, "position closed by the TP");
    }
}
