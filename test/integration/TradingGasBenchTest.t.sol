// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";
import {OrderView} from "../OrderView.sol";

/// @title TradingGasBenchTest
/// @notice Gas of the trading and keeper entry points on a pair that has already traded: resting,
///         taking, closing, order management, collateral, liquidation and the price refresh. The
///         figures are logged, never asserted, because absolute gas moves with every optimizer
///         and matching change; the assertions only confirm that each test ran the scenario its
///         label names.
/// @dev    Read it with
///         `forge test --match-path test/integration/TradingGasBenchTest.t.sol --isolate -vv`.
///         `--isolate` runs every top-level call as a transaction of its own, so a figure includes
///         the base transaction cost, calldata, cold storage access and the capped refund: what
///         the call costs on chain. Without it a test body is one transaction, everything an
///         earlier step touched stays warm, and every figure understates.
///
///         "Posts a new price" in a label means the Pyth cache was older than MAX_PRICE_STALENESS,
///         so the call pushes its update to Pyth and stores the tick on the pair. "Price already
///         fresh" means an earlier call on the pair stored the tick the call carries, so it is
///         served from the cache and stores nothing, as is every later caller inside one
///         staleness window.
///
///         The oracle is MockPyth, which stores an update without verifying it, so against the
///         real Pyth a call that posts a new price costs more: by the gap between a real Pyth
///         update transaction on the target chain and the control here that prices
///         MockPyth.updatePriceFeeds as a transaction of its own. Collateral is MockUSDC, a plain
///         OpenZeppelin ERC-20, while Circle's USDC routes each transfer through a proxy and
///         checks pause and blacklist state, so the calls that move the token cost somewhat more
///         on chain.
contract TradingGasBenchTest is IntegrationBase {
    uint256 constant BTC = 1e18;

    address internal maker1;
    address internal maker2;
    address internal taker;

    /// @dev Leaves the pair the way trading leaves a live one, so a measured call rewrites state
    ///      in place instead of paying the zero-to-nonzero stores of a pair's first trades. Three
    ///      rounds of fills an hour apart write the funding index, the variance sample, the margin
    ///      curve and the hourly sample ring. Each round's ask rests below the index for
    ///      MAKER_EXPOSURE_BLOCKS before it is taken, so its fill enters the mark: the mark's
    ///      tallies hold values and the funding index moves at every store. Left at zero, the index
    ///      would make storing a new position's entryFundingIndex a no-op instead of the
    ///      zero-to-nonzero write it is on a live pair. The first round also liquidates an account
    ///      into a bid below the oracle, which writes the liquidation-outcome EMAs and the keeper's
    ///      fee balance; the price moves there and back inside one VARIANCE_UPDATE_COOLDOWN, so the
    ///      excursion leaves the variance EMA alone.
    ///
    ///      The last round's first order recomputes the curve and advances the variance sample.
    ///      Every measured call lands inside IMR_UPDATE_COOLDOWN of it (_assertInsideCurveCooldown
    ///      fails a test that strays), inside VARIANCE_UPDATE_COOLDOWN, and inside the open
    ///      MMR_SAMPLE_INTERVAL, so none pays the curve recompute, the variance advance or the
    ///      ring sample that one call per period pays on a live pair. Each test starts on an empty
    ///      book at the second of setUp's last stored price.
    function setUp() public override {
        super.setUp();
        maker1 = makeAddr("benchMaker1");
        maker2 = makeAddr("benchMaker2");
        taker = makeAddr("benchTaker");
        address[6] memory funded = [alice, bob, carol, dave, maker1, maker2];
        for (uint256 i; i < funded.length; ++i) {
            usdc.mint(funded[i], 1_000_000 * USDC_SCALE);
            _deposit(funded[i], 100_000 * BAZAAR_SCALE);
        }
        usdc.mint(taker, 1_000_000 * USDC_SCALE);

        for (uint256 round; round < 3; ++round) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _roll(FundingLib.MAKER_EXPOSURE_BLOCKS);
            _placeLimitAt(alice, false, BTC / 10, 49_990 * BAZAAR_SCALE, 50_000);
            _roll(FundingLib.MAKER_EXPOSURE_BLOCKS);
            _placeLimitAt(bob, true, BTC / 10, 50_000 * BAZAAR_SCALE, 50_000);
            if (round == 0) _liquidateIntoBidAndRecover();
        }
        _roll(FundingLib.MAKER_EXPOSURE_BLOCKS);
    }

    /// @dev setUp's liquidation: a victim seized and sold by the inline unload into a resting
    ///      bid, then the price restored.
    function _liquidateIntoBidAndRecover() internal {
        address[] memory victims = _victims("benchWarmVictim", 1);
        _openVictims(victims);
        address bidder = makeAddr("benchWarmBidder");
        usdc.mint(bidder, 1_000_000 * USDC_SCALE);
        _deposit(bidder, 100_000 * BAZAAR_SCALE);
        uint256 px = _liquidationPriceUsd(victims[0]);
        _placeLimit(bidder, true, BTC / 5, px * 99 / 100 * BAZAAR_SCALE);
        _roll(FundingLib.MAKER_EXPOSURE_BLOCKS);

        bytes[] memory pu = _nextTick(px);
        vm.prank(seq);
        assertEq(pair.liquidate(victims, pu), 1, "warm-up: seized");
        assertEq(_heldInventory(), 0, "warm-up: the unload sold the seizure");
        assertGt(_escrowOwed(seq), 0, "warm-up: keeper paid");

        pu = _nextTick(50_000);
        vm.prank(seq);
        pair.refreshPrice(pu);
    }

    // ============================================================
    // Helpers
    // ============================================================

    /// @dev A BTC update at `priceUsd` with the clock moved past MAX_PRICE_STALENESS, so the Pyth
    ///      cache is stale and the call that carries the update posts it.
    function _nextTick(uint256 priceUsd) internal returns (bytes[] memory) {
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.MAX_PRICE_STALENESS + 1);
        return _priceUpdate(priceUsd, uint64(vm.getBlockTimestamp()));
    }

    /// @dev Rests `maker`'s quote on the current tick and ages it MAKER_EXPOSURE_BLOCKS, as a
    ///      standing quote is when a taker reaches it.
    function _standingQuote(address maker, bool isLong, uint256 size, uint256 limitPrice) internal {
        _placeLimit(maker, isLong, size, limitPrice);
        _roll(FundingLib.MAKER_EXPOSURE_BLOCKS);
    }

    /// @dev Opens a `size` long for `who` against an ask `maker` rests at `price`, on the current
    ///      tick.
    function _openLong(address who, address maker, uint256 size, uint256 price) internal {
        _placeLimit(maker, false, size, price);
        _roll(2);
        _placeLimit(who, true, size, price);
        assertEq(_posSize(who), size, "fixture: long opened");
    }

    /// @dev Fails once the clock has run IMR_UPDATE_COOLDOWN past the curve's last recompute, where
    ///      the measured call would also pay the next one (setUp).
    function _assertInsideCurveCooldown() internal view {
        (,, uint256 curveTs,) = pair.marginRequirements();
        assertLt(
            vm.getBlockTimestamp(), curveTs + RiskParamsLib.IMR_UPDATE_COOLDOWN, "fixture: inside the curve cooldown"
        );
    }

    function _measureCreate(address who, BazaarTypes.OrderSpec memory s, bytes[] memory pu)
        internal
        returns (uint256 used)
    {
        _assertInsideCurveCooldown();
        vm.prank(who);
        uint256 g0 = gasleft();
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "", "");
        used = g0 - gasleft();
    }

    function _victims(string memory label, uint256 n) internal returns (address[] memory v) {
        v = new address[](n);
        for (uint256 i; i < n; ++i) {
            v[i] = makeAddr(string.concat(label, vm.toString(i)));
        }
    }

    /// @dev Opens a 0.2 BTC long at $50,000 on $3,000 of collateral for each of `victims`, against
    ///      one ask alice rests for all of them, on the current tick.
    function _openVictims(address[] memory victims) internal {
        _placeLimit(alice, false, victims.length * BTC / 5, 50_000 * BAZAAR_SCALE);
        for (uint256 i; i < victims.length; ++i) {
            usdc.mint(victims[i], 1_000_000 * USDC_SCALE);
            _deposit(victims[i], 3_000 * BAZAAR_SCALE);
            _roll(2);
            _placeLimit(victims[i], true, BTC / 5, 50_000 * BAZAAR_SCALE);
            assertEq(_posSize(victims[i]), BTC / 5, "fixture: victim long");
        }
    }

    /// @dev 2% under the highest whole-dollar price at which the lens calls `victim` insolvent.
    ///      liquidate judges at the curve its own price gives, which can sit below the stored one
    ///      the lens reads, so a price on the lens's line alone might not seize.
    function _liquidationPriceUsd(address victim) internal view returns (uint256) {
        uint256 insolvent = 25_000;
        uint256 solvent = 50_000;
        while (solvent - insolvent > 1) {
            uint256 mid = (insolvent + solvent) / 2;
            if (lens.checkBucketSolvency(address(pair), victim, mid * BAZAAR_SCALE).isSolvent) solvent = mid;
            else insolvent = mid;
        }
        return insolvent * 98 / 100;
    }

    function _measureLiquidate(address[] memory victims, bytes[] memory pu) internal returns (uint256 used) {
        _assertInsideCurveCooldown();
        vm.prank(seq);
        uint256 g0 = gasleft();
        uint256 n = pair.liquidate(victims, pu);
        used = g0 - gasleft();
        assertEq(n, victims.length, "fixture: every account seized");
    }

    function _heldInventory() internal view returns (uint256 held) {
        (,,,,,, held,,,,,,,,,,) = pair.pairVault();
    }

    function _stopLossSpec(uint256 size, uint256 triggerPrice) internal pure returns (BazaarTypes.OrderSpec memory s) {
        s.orderType = BazaarTypes.OrderType.StopLoss;
        s.isLong = false;
        s.size = size;
        s.triggerPrice = triggerPrice;
        s.maxSlippageBp = 100;
    }

    // ============================================================
    // Resting
    // ============================================================

    function test_gas_rest_postsPrice() public {
        _placeLimit(dave, true, BTC / 100, 48_000 * BAZAAR_SCALE);
        bytes[] memory pu = _nextTick(50_000);
        uint256 used = _measureCreate(carol, _limitSpec(true, BTC / 100, 49_000 * BAZAAR_SCALE), pu);
        assertTrue(_inBook(_lastCreatedOrderId(pair)), "fixture: rested");
        emit log_named_uint("createOrder: rest a limit, posts a new price", used);
    }

    function test_gas_rest_priceAlreadyFresh() public {
        _placeLimit(dave, true, BTC / 100, 48_000 * BAZAAR_SCALE);
        // _freshPrice carries the tick already stored this second, so the call reads the cache.
        uint256 used = _measureCreate(carol, _limitSpec(true, BTC / 100, 49_000 * BAZAAR_SCALE), _freshPrice());
        assertTrue(_inBook(_lastCreatedOrderId(pair)), "fixture: rested");
        emit log_named_uint("createOrder: rest a limit, price already fresh", used);
    }

    // ============================================================
    // Taking
    // ============================================================

    /// @notice A near-side ask, above the index: the fill leaves the mark to its decay.
    function test_gas_take1_opensPosition_postsPrice() public {
        _deposit(taker, 20_000 * BAZAAR_SCALE);
        _standingQuote(maker1, false, BTC / 10, 50_010 * BAZAAR_SCALE);
        uint256 markVolume = pair.auxState().rollingVolume;
        bytes[] memory pu = _nextTick(50_000);
        uint256 used = _measureCreate(taker, _limitSpec(true, BTC / 10, 50_100 * BAZAAR_SCALE), pu);
        assertEq(_posSize(taker), BTC / 10, "fixture: filled");
        assertEq(pair.auxState().rollingVolume, markVolume, "fixture: the fill left the mark alone");
        emit log_named_uint("createOrder: take 1 maker, opens a position, posts a new price", used);
    }

    /// @notice The take above against an ask resting below the index instead: a far-side quote,
    ///         so the fill also enters the mark's tallies, which a fill against a near-side quote
    ///         leaves alone.
    function test_gas_take1_farSideMaker_postsPrice() public {
        _deposit(taker, 20_000 * BAZAAR_SCALE);
        _standingQuote(maker1, false, BTC / 10, 49_990 * BAZAAR_SCALE);
        uint256 markVolume = pair.auxState().rollingVolume;
        bytes[] memory pu = _nextTick(50_000);
        uint256 used = _measureCreate(taker, _limitSpec(true, BTC / 10, 50_100 * BAZAAR_SCALE), pu);
        assertEq(_posSize(taker), BTC / 10, "fixture: filled");
        assertTrue(pair.auxState().rollingVolume != markVolume, "fixture: the fill entered the mark");
        emit log_named_uint("createOrder: take 1 far-side maker (fill enters the mark), posts a new price", used);
    }

    function test_gas_take1_opensPosition_priceAlreadyFresh() public {
        _deposit(taker, 20_000 * BAZAAR_SCALE);
        _standingQuote(maker1, false, BTC / 10, 50_010 * BAZAAR_SCALE);
        // _freshPrice carries the tick already stored this second, so the call reads the cache.
        uint256 used = _measureCreate(taker, _limitSpec(true, BTC / 10, 50_100 * BAZAAR_SCALE), _freshPrice());
        assertEq(_posSize(taker), BTC / 10, "fixture: filled");
        emit log_named_uint("createOrder: take 1 maker, opens a position, price already fresh", used);
    }

    function test_gas_take1_addsToPosition_postsPrice() public {
        _deposit(taker, 20_000 * BAZAAR_SCALE);
        _openLong(taker, maker1, BTC / 10, 50_010 * BAZAAR_SCALE);
        _standingQuote(maker2, false, BTC / 10, 50_010 * BAZAAR_SCALE);
        bytes[] memory pu = _nextTick(50_000);
        uint256 used = _measureCreate(taker, _limitSpec(true, BTC / 10, 50_100 * BAZAAR_SCALE), pu);
        assertEq(_posSize(taker), BTC / 5, "fixture: added");
        emit log_named_uint("createOrder: take 1 maker, adds to an open long, posts a new price", used);
    }

    function test_gas_market1_postsPrice() public {
        _deposit(taker, 20_000 * BAZAAR_SCALE);
        _standingQuote(maker1, false, BTC / 10, 50_010 * BAZAAR_SCALE);
        bytes[] memory pu = _nextTick(50_000);
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Market;
        s.isLong = true;
        s.size = BTC / 10;
        s.maxSlippageBp = 100;
        uint256 used = _measureCreate(taker, s, pu);
        assertEq(_posSize(taker), BTC / 10, "fixture: filled");
        emit log_named_uint("createOrder: market order into 1 maker, posts a new price", used);
    }

    function test_gas_close_into1Bid_postsPrice() public {
        _deposit(taker, 20_000 * BAZAAR_SCALE);
        _openLong(taker, maker1, BTC / 10, 50_010 * BAZAAR_SCALE);
        _standingQuote(maker2, true, BTC / 10, 49_990 * BAZAAR_SCALE);
        bytes[] memory pu = _nextTick(50_000);
        uint256 used = _measureCreate(taker, _limitSpec(false, BTC / 10, 49_900 * BAZAAR_SCALE), pu);
        assertEq(_posSize(taker), 0, "fixture: closed");
        emit log_named_uint("createOrder: close a whole position into 1 bid, posts a new price", used);
    }

    function test_gas_take8_postsPrice() public {
        _deposit(taker, 200_000 * BAZAAR_SCALE);
        for (uint256 i; i < 8; ++i) {
            address m = makeAddr(string.concat("benchLadder", vm.toString(i)));
            usdc.mint(m, 1_000_000 * USDC_SCALE);
            _deposit(m, 60_000 * BAZAAR_SCALE);
            _placeLimit(m, false, BTC / 100, (50_010 + i) * BAZAAR_SCALE);
        }
        _roll(FundingLib.MAKER_EXPOSURE_BLOCKS);
        bytes[] memory pu = _nextTick(50_000);
        uint256 used = _measureCreate(taker, _limitSpec(true, 8 * BTC / 100, 50_100 * BAZAAR_SCALE), pu);
        assertEq(_posSize(taker), 8 * BTC / 100, "fixture: filled");
        emit log_named_uint("createOrder: take 8 makers, posts a new price", used);
    }

    // ============================================================
    // Order management
    // ============================================================

    function test_gas_cancel1() public {
        uint256 id = _placeLimit(carol, true, BTC / 100, 49_000 * BAZAAR_SCALE);
        uint256[] memory ids = _one(id);
        vm.prank(carol);
        uint256 g0 = gasleft();
        pair.cancelOrders(ids, 0, 0, 0, "", "");
        uint256 used = g0 - gasleft();
        assertFalse(_inBook(id), "fixture: canceled");
        emit log_named_uint("cancelOrders: cancel 1 resting order", used);
    }

    function test_gas_amend1_reprice_postsPrice() public {
        uint256 id = _placeLimit(carol, true, BTC / 100, 49_000 * BAZAAR_SCALE);
        uint256[] memory words = new uint256[](3);
        (words[0], words[1], words[2]) = (id, 48_900 * BAZAAR_SCALE, BTC / 100);
        bytes[] memory pu = _nextTick(50_000);
        _assertInsideCurveCooldown();
        vm.prank(carol);
        uint256 g0 = gasleft();
        pair.amendOrders(words, pu, 0, 0, 0, "", "");
        uint256 used = g0 - gasleft();
        assertEq(OrderView.order(pair, id).limitPrice, 48_900 * BAZAAR_SCALE, "fixture: repriced");
        emit log_named_uint("amendOrders: reprice 1 resting order, posts a new price", used);
    }

    function test_gas_placeStopLoss_postsPrice() public {
        _deposit(taker, 20_000 * BAZAAR_SCALE);
        _openLong(taker, maker1, BTC / 10, 50_010 * BAZAAR_SCALE);
        bytes[] memory pu = _nextTick(50_000);
        uint256 used = _measureCreate(taker, _stopLossSpec(BTC / 10, 48_000 * BAZAAR_SCALE), pu);
        assertEq(_stopLossOrderId(taker), _lastCreatedOrderId(pair), "fixture: stop attached");
        emit log_named_uint("createOrder: place a stop-loss on an open long, posts a new price", used);
    }

    function test_gas_executeStop_into1Bid_postsPrice() public {
        _deposit(taker, 20_000 * BAZAAR_SCALE);
        _openLong(taker, maker1, BTC / 10, 50_010 * BAZAAR_SCALE);
        uint256 sl = _placeStopLoss(taker, false, BTC / 10, 48_000 * BAZAAR_SCALE, 100);
        _standingQuote(carol, true, BTC / 10, 47_600 * BAZAAR_SCALE);
        bytes[] memory pu = _nextTick(47_500);
        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](1);
        execs[0].orderId = uint64(sl);
        _assertInsideCurveCooldown();
        vm.prank(seq);
        uint256 g0 = gasleft();
        uint256 n = pair.executeTriggeredOrders(execs, pu);
        uint256 used = g0 - gasleft();
        assertEq(n, 1, "fixture: stop fired");
        assertEq(_posSize(taker), 0, "fixture: closed");
        emit log_named_uint("executeTriggeredOrders: 1 stop-loss into 1 bid, posts a new price", used);
    }

    // ============================================================
    // Collateral
    // ============================================================

    function test_gas_deposit_firstAndAgain() public {
        vm.prank(taker);
        usdc.approve(address(pair), 40_000 * USDC_SCALE);
        vm.prank(taker);
        uint256 g0 = gasleft();
        pair.depositCollateral(20_000 * BAZAAR_SCALE, 0, 0, 0, "", "");
        uint256 first = g0 - gasleft();
        vm.prank(taker);
        g0 = gasleft();
        pair.depositCollateral(10_000 * BAZAAR_SCALE, 0, 0, 0, "", "");
        uint256 again = g0 - gasleft();
        assertEq(_posCollateral(taker), 30_000 * BAZAAR_SCALE, "fixture: both deposits landed");
        emit log_named_uint("depositCollateral: an account's first deposit", first);
        emit log_named_uint("depositCollateral: a later deposit", again);
    }

    /// @notice An account with no position and no orders has no exposure to price, so the
    ///         withdrawal reads no price and the call carries no update.
    function test_gas_withdraw_flat() public {
        _deposit(taker, 20_000 * BAZAAR_SCALE);
        bytes[] memory none = new bytes[](0);
        vm.prank(taker);
        uint256 g0 = gasleft();
        pair.withdrawCollateral(5_000 * BAZAAR_SCALE, none, 0, 0, 0, "");
        uint256 used = g0 - gasleft();
        assertEq(_posCollateral(taker), 15_000 * BAZAAR_SCALE, "fixture: withdrawn");
        emit log_named_uint("withdrawCollateral: no position or orders (reads no price)", used);
    }

    function test_gas_withdraw_withPosition_postsPrice() public {
        _deposit(taker, 20_000 * BAZAAR_SCALE);
        _openLong(taker, maker1, BTC / 10, 50_010 * BAZAAR_SCALE);
        uint256 before = _posCollateral(taker);
        bytes[] memory pu = _nextTick(50_000);
        _assertInsideCurveCooldown();
        vm.prank(taker);
        uint256 g0 = gasleft();
        pair.withdrawCollateral(5_000 * BAZAAR_SCALE, pu, 0, 0, 0, "");
        uint256 used = g0 - gasleft();
        assertLt(_posCollateral(taker), before, "fixture: withdrawn");
        emit log_named_uint("withdrawCollateral: with an open position, posts a new price", used);
    }

    // ============================================================
    // Keeper paths
    // ============================================================

    /// @notice A seizure with no bid in the book: the position stays in the vault's inventory
    ///         because the inline unload finds nothing to sell it into.
    function test_gas_liquidate1_emptyBook() public {
        address[] memory victims = _victims("benchVictim", 1);
        _openVictims(victims);
        bytes[] memory pu = _nextTick(_liquidationPriceUsd(victims[0]));
        uint256 used = _measureLiquidate(victims, pu);
        assertEq(_heldInventory(), BTC / 5, "fixture: seized into inventory");
        emit log_named_uint("liquidate: 1 account, no bid in the book", used);
    }

    /// @notice A seizure the inline unload sells, in the same call, into a bid resting 1% under
    ///         the liquidation price.
    function test_gas_liquidate1_unloadInto1Bid() public {
        address[] memory victims = _victims("benchVictim", 1);
        _openVictims(victims);
        uint256 px = _liquidationPriceUsd(victims[0]);
        _standingQuote(carol, true, BTC / 5, px * 99 / 100 * BAZAAR_SCALE);
        bytes[] memory pu = _nextTick(px);
        uint256 used = _measureLiquidate(victims, pu);
        assertEq(_heldInventory(), 0, "fixture: the unload sold the seizure");
        emit log_named_uint("liquidate: 1 account, inline unload sells it into 1 bid", used);
    }

    /// @notice Five seizures in one call with no bid in the book, and their average per account.
    function test_gas_liquidate5_emptyBook() public {
        address[] memory victims = _victims("benchVictim", 5);
        _openVictims(victims);
        bytes[] memory pu = _nextTick(_liquidationPriceUsd(victims[0]));
        uint256 used = _measureLiquidate(victims, pu);
        assertEq(_heldInventory(), BTC, "fixture: seized into inventory");
        emit log_named_uint("liquidate: 5 accounts in one call, no bid in the book", used);
        emit log_named_uint("liquidate: per account of the five", used / 5);
    }

    function test_gas_refreshPrice_postsPrice() public {
        uint256 owed = _escrowOwed(seq);
        bytes[] memory pu = _nextTick(50_000);
        _assertInsideCurveCooldown();
        vm.prank(seq);
        uint256 g0 = gasleft();
        pair.refreshPrice(pu);
        uint256 used = g0 - gasleft();
        assertEq(_escrowOwed(seq), owed, "fixture: no bounty due");
        emit log_named_uint("refreshPrice: posts a new price, no bounty due", used);
    }

    /// @notice The oracle control: the mock's own update as a transaction of its own, to set
    ///         against a real Pyth update transaction on the target chain.
    function test_gas_mockPythUpdate_control() public {
        bytes[] memory pu = _nextTick(50_000);
        uint256 fee = mockPyth.getUpdateFee(pu);
        vm.deal(seq, fee);
        vm.prank(seq);
        uint256 g0 = gasleft();
        mockPyth.updatePriceFeeds{value: fee}(pu);
        uint256 used = g0 - gasleft();
        emit log_named_uint("MockPyth.updatePriceFeeds as its own transaction", used);
        emit log_named_uint("MockPyth: update payload (bytes)", pu[0].length);
    }
}
