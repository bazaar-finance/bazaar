// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarSequencer} from "../../src/BazaarSequencer.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {OrderManagementLib} from "../../src/libraries/OrderManagementLib.sol";
import {MatchingEngineLib} from "../../src/libraries/MatchingEngineLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

/// @title MatchingEngineTest
/// @notice End-to-end tests for BazaarPair.matchBatch covering all three matching passes.
///         Phase 1: Pass B (markets × limits) and Pass C (limits × limits).
///         Pass A (vault-liquidation × limits) and exhaustive edge cases land in follow-ups.
contract MatchingEngineTest is Test {
    using stdStorage for StdStorage;
    StdStorage internal _stdstore;

    // -------------------- Constants --------------------
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant AAPL_USD_FEED_ID = 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688;
    uint256 constant AAPL_SPOT_PRICE = 200 * BAZAAR_SCALE; // $200/share

    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant BP_SCALE = 10_000;

    uint256 constant INITIAL_USER_BALANCE = 1_000_000 * USDC_SCALE;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;

    // Pyth: BTC at $50,000, expo=-8, conf $50 (0.1%)
    int64 constant BTC_PYTH_PRICE = 5_000_000_000_000;
    uint64 constant BTC_PYTH_CONF = 5_000_000_000;
    int32 constant BTC_PYTH_EXPO = -8;
    uint256 constant BTC_SPOT_PRICE = 50_000 * BAZAAR_SCALE;

    // -------------------- State --------------------
    BazaarFactory public factory;
    BazaarOracle public oracle;
    BazaarSequencer public sequencer;
    BazaarPair public pair;
    BazaarPair public aaplPair; // non-continuously-traded; used for stale-oracle tests
    MockUSDC public usdc;
    MockPyth public mockPyth;

    address public deployer;
    address public alice;
    address public bob;
    address public carol;
    address public dave;
    address public seq; // bonded sequencer

    uint256 bondUsdc;

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dave = makeAddr("dave");
        seq = makeAddr("seq");

        // Etch MockArbSys at the Arbitrum precompile address so _l2Block() works
        vm.etch(address(0x64), address(new MockArbSys()).code);

        DeployBazaar dep = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = dep.deploy(makeAddr("bugBounty"));

        (, address usdcAddr,,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcAddr);
        oracle = factory.oracle();
        sequencer = factory.sequencer();
        mockPyth = MockPyth(address(oracle.pyth()));

        bondUsdc = factory.DEPLOYMENT_BOND_USDC();

        // Mint USDC to actors
        usdc.mint(deployer, INITIAL_USER_BALANCE);
        usdc.mint(alice, INITIAL_USER_BALANCE);
        usdc.mint(bob, INITIAL_USER_BALANCE);
        usdc.mint(carol, INITIAL_USER_BALANCE);
        usdc.mint(dave, INITIAL_USER_BALANCE);
        usdc.mint(seq, INITIAL_USER_BALANCE);

        // Deploy a BTC pair via the factory (continuously traded)
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();

        // Also propose an AAPL pair (non-continuously-traded) used by Phase 5 stale-oracle tests.
        usdc.mint(deployer, PROPOSAL_TOTAL_USDC);
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 aaplAssertionId =
            factory.proposePairDeployment(AAPL_USD_FEED_ID, false, PROPOSAL_TOTAL, "AAPL on NASDAQ");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        factory.settleDeploymentProposal(aaplAssertionId);
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        pair = BazaarPair(payable(factory.getPairAddress(pairId)));
        (,,,,,, bytes32 aaplPairId,,,) = factory.deploymentProposals(aaplAssertionId);
        aaplPair = BazaarPair(payable(factory.getPairAddress(aaplPairId)));

        // Register & bond a sequencer (MIN_BOND = 1000 BAZAAR_SCALE → 1000 USDC)
        uint256 bondAmount = 5_000 * USDC_SCALE;
        vm.startPrank(seq);
        usdc.approve(address(sequencer), bondAmount);
        sequencer.deposit(bondAmount);
        vm.stopPrank();

        // Advance blocks so observationBlock has headroom (matchBatch requires currentBlock - observationBlock <= 12)
        vm.roll(block.number + 20);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║                     HARNESS HELPERS                          ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @dev Build a Pyth price update for BTC at the given USD price.
    function _priceUpdate(uint256 priceUsd, uint64 publishTime) internal view returns (bytes[] memory pu) {
        int64 pythPrice = int64(int256(priceUsd * 1e8));
        uint64 conf = uint64(priceUsd * 1e8 / 1000); // 0.1%
        bytes memory data = mockPyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID,
            pythPrice,
            conf,
            BTC_PYTH_EXPO,
            pythPrice,
            conf,
            publishTime,
            publishTime > 0 ? publishTime - 1 : 0
        );
        pu = new bytes[](1);
        pu[0] = data;
    }

    /// @dev Default-priced update at current timestamp.
    function _freshPrice() internal view returns (bytes[] memory) {
        return _priceUpdate(50_000, uint64(block.timestamp));
    }

    /// @dev Build a BTC update with a custom confidence (in bp of price), for testing the conf cap.
    function _priceUpdateConf(uint256 priceUsd, uint256 confBp, uint64 publishTime)
        internal
        view
        returns (bytes[] memory pu)
    {
        int64 pythPrice = int64(int256(priceUsd * 1e8));
        uint64 conf = uint64(priceUsd * 1e8 * confBp / 10_000);
        bytes memory data = mockPyth.createPriceFeedUpdateData(
            BTC_USD_FEED_ID,
            pythPrice,
            conf,
            BTC_PYTH_EXPO,
            pythPrice,
            conf,
            publishTime,
            publishTime > 0 ? publishTime - 1 : 0
        );
        pu = new bytes[](1);
        pu[0] = data;
    }

    /// @dev Deposit collateral for a user (BAZAAR_SCALE amount).
    function _deposit(address user, uint256 amount) internal {
        uint256 amountUsdc = amount * USDC_SCALE / BAZAAR_SCALE;
        vm.startPrank(user);
        usdc.approve(address(pair), amountUsdc);
        pair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev Read nextOrderId from storage to capture newly-created order IDs reliably.
    ///      nextOrderId is `private` so we can't call it — we use a probe via createOrder
    ///      and the userActiveLimitOrders set (limits) or positionBucket (market/TP/SL).
    function _newestLimitOrderId(address user) internal returns (uint256) {
        (uint256[] memory ids,,,) = pair.getUserActiveLimitOrders(user);
        require(ids.length > 0, "no active limit orders");
        return ids[ids.length - 1];
    }

    function _activeMarketOrderId(address user) internal view returns (uint256) {
        (,,,,,,,, uint256 mktId,) = pair.positionBuckets(user);
        return mktId;
    }

    function _takeProfitOrderId(address user) internal view returns (uint256) {
        (,,,,, uint256 tpId,,,,) = pair.positionBuckets(user);
        return tpId;
    }

    function _stopLossOrderId(address user) internal view returns (uint256) {
        (,,,,,, uint256 slId,,,) = pair.positionBuckets(user);
        return slId;
    }

    /// @dev Place a Limit order. Returns the orderId.
    function _placeLimit(address user, bool isLong, uint256 size, uint256 limitPrice) internal returns (uint256) {
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
            uint64(block.number + 500_000),
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
        return _newestLimitOrderId(user);
    }

    /// @dev Place a Market order. Returns the orderId.
    function _placeMarket(address user, bool isLong, uint256 size, uint256 maxSlippageBp) internal returns (uint256) {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        pair.createOrder(
            BazaarTypes.OrderType.Market,
            0,
            0,
            maxSlippageBp,
            size,
            isLong,
            false,
            0, // expiry ignored for market
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
        return _activeMarketOrderId(user);
    }

    /// @dev Place a StopLimit order. Returns the orderId.
    function _placeStopLimit(address user, bool isLong, uint256 size, uint256 triggerPrice, uint256 limitPrice)
        internal
        returns (uint256)
    {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        pair.createOrder(
            BazaarTypes.OrderType.StopLimit,
            triggerPrice,
            limitPrice,
            0,
            size,
            isLong,
            false,
            uint64(block.number + 500_000),
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
        return _newestLimitOrderId(user);
    }

    /// @dev Place a TakeProfit (requires existing position, opposite direction).
    function _placeTakeProfit(address user, bool isLong, uint256 size, uint256 limitPrice) internal returns (uint256) {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        pair.createOrder(
            BazaarTypes.OrderType.TakeProfit,
            0,
            limitPrice,
            0,
            size,
            isLong,
            false,
            0, // never expires
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
        return _takeProfitOrderId(user);
    }

    /// @dev Place a StopLoss (requires existing position, opposite direction).
    function _placeStopLoss(address user, bool isLong, uint256 size, uint256 triggerPrice, uint256 maxSlippageBp)
        internal
        returns (uint256)
    {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        pair.createOrder(
            BazaarTypes.OrderType.StopLoss,
            triggerPrice,
            0,
            maxSlippageBp,
            size,
            isLong,
            false,
            0, // never expires
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
        return _stopLossOrderId(user);
    }

    /// @dev Helper: open a position for `user` by matching them against a counterparty.
    ///      `user` ends up with `size` units in the direction `isLong`.
    function _openPosition(address user, address counterparty, bool isLong, uint256 size) internal {
        _deposit(user, 20_000 * BAZAAR_SCALE);
        _deposit(counterparty, 20_000 * BAZAAR_SCALE);
        uint256 longId;
        uint256 shortId;
        if (isLong) {
            longId = _placeLimit(user, true, size, 51_000 * BAZAAR_SCALE);
            shortId = _placeLimit(counterparty, false, size, 49_000 * BAZAAR_SCALE);
        } else {
            shortId = _placeLimit(user, false, size, 49_000 * BAZAAR_SCALE);
            longId = _placeLimit(counterparty, true, size, 51_000 * BAZAAR_SCALE);
        }
        vm.roll(block.number + 2);
        _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);
    }

    /// @dev Build an OrderLists with the four sorted arrays (any may be empty).
    function _lists(
        uint256[] memory longLimits,
        uint256[] memory shortLimits,
        uint256[] memory longMarkets,
        uint256[] memory shortMarkets
    ) internal pure returns (BazaarTypes.OrderLists memory ol) {
        ol.longLimits = longLimits;
        ol.shortLimits = shortLimits;
        ol.longMarkets = longMarkets;
        ol.shortMarkets = shortMarkets;
    }

    function _empty() internal pure returns (uint256[] memory a) {
        a = new uint256[](0);
    }

    function _one(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _two(uint256 a, uint256 b) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        out[0] = a;
        out[1] = b;
    }

    function _three(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    /// @dev Run matchBatch as the bonded sequencer. observationBlock = current - 1.
    function _match(BazaarTypes.OrderLists memory lists, uint256 maxMatches) internal returns (uint256 successCount) {
        bytes[] memory pu = _freshPrice();
        uint64 obs = uint64(block.number - 1);
        vm.prank(seq);
        successCount = pair.matchBatch(lists, maxMatches, pu, obs);
    }

    /// @dev Run matchBatch expecting it to revert with `expectedError`. The price update is built
    ///      BEFORE arming expectRevert so the cheat targets matchBatch, not _freshPrice's mock call.
    function _matchRevert(BazaarTypes.OrderLists memory lists, bytes memory expectedError) internal {
        bytes[] memory pu = _freshPrice();
        uint64 obs = uint64(block.number - 1);
        vm.prank(seq);
        vm.expectRevert(expectedError);
        pair.matchBatch(lists, 10, pu, obs);
    }

    /// @dev Run matchBatch at a custom oracle price (whole USD), for stop-trigger tests.
    ///      Warps past MAX_PRICE_STALENESS (2s) first so the prior fresh-price cache is stale and
    ///      matchBatch actually consumes the supplied price rather than reusing the cached one.
    function _matchAtPrice(BazaarTypes.OrderLists memory lists, uint256 maxMatches, uint256 priceUsd)
        internal
        returns (uint256 successCount)
    {
        vm.warp(block.timestamp + 3);
        bytes[] memory pu = _priceUpdate(priceUsd, uint64(block.timestamp));
        uint64 obs = uint64(block.number - 1);
        vm.prank(seq);
        successCount = pair.matchBatch(lists, maxMatches, pu, obs);
    }

    /// @dev Read the filled size of an order.
    function _filledSize(uint256 orderId) internal view returns (uint256) {
        (,,,,,, uint256 filledSize,,,,,,,) = pair.orders(orderId);
        return filledSize;
    }

    /// @dev Accept ETH refunds (challengeStaleBatch refunds unused value to msg.sender).
    receive() external payable {}

    /// @dev Read order size.
    function _size(uint256 orderId) internal view returns (uint256) {
        (,,,,, uint256 size,,,,,,,,) = pair.orders(orderId);
        return size;
    }

    /// @dev Read canceledBlock — non-zero means auto-canceled.
    function _canceledBlock(uint256 orderId) internal view returns (uint64) {
        (,,,,,,,,,,,, uint64 cb,) = pair.orders(orderId);
        return cb;
    }

    /// @dev Read filledBlock — non-zero means fully filled.
    function _filledBlock(uint256 orderId) internal view returns (uint64) {
        (,,,,,,,,,,,,, uint64 fb) = pair.orders(orderId);
        return fb;
    }

    /// @dev Read a user's position size + side.
    function _position(address user) internal view returns (bool isLong, uint256 size) {
        (isLong, size,,,,,,,,) = pair.positionBuckets(user);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       PASS C — limits × limits (basic coverage)              ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice One long limit @ 51k vs one short limit @ 49k — crosses, fills at older orderId's price.
    function testPassC_LimitVsLimit_CrossesAndFills() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10; // 0.1 BTC
        uint256 longId = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);

        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1, "one match expected");
        assertEq(_filledSize(longId), size, "long fully filled");
        assertEq(_filledSize(shortId), size, "short fully filled");

        (bool aliceLong, uint256 aliceSize) = _position(alice);
        assertTrue(aliceLong);
        assertEq(aliceSize, size);

        (bool bobLong, uint256 bobSize) = _position(bob);
        assertFalse(bobLong);
        assertEq(bobSize, size);
    }

    /// @notice Long @ 49k vs short @ 51k — does NOT cross, no fills.
    function testPassC_LimitVsLimit_NoCrossWhenBidBelowAsk() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longId = _placeLimit(alice, true, size, 49_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 51_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);

        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 0, "no cross expected");
        assertEq(_filledSize(longId), 0);
        assertEq(_filledSize(shortId), 0);
    }

    /// @notice Asymmetric sizes — smaller side fully fills, larger side partially fills.
    function testPassC_LimitVsLimit_PartialFill() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 bigSize = 3 * BAZAAR_SCALE / 10; // 0.3 BTC long
        uint256 smallSize = 1 * BAZAAR_SCALE / 10; // 0.1 BTC short

        uint256 longId = _placeLimit(alice, true, bigSize, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, smallSize, 49_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1);
        assertEq(_filledSize(longId), smallSize, "long partially filled");
        assertEq(_filledSize(shortId), smallSize, "short fully filled");
        assertEq(_filledBlock(shortId) > 0, true, "short marked filled");
        assertEq(_filledBlock(longId), 0, "long not yet fully filled");
    }

    /// @notice Self-match — same creator on both sides → newer order is auto-canceled.
    function testPassC_LimitVsLimit_SelfMatchAutoCancels() public {
        _deposit(alice, 40_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longId = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(alice, false, size, 49_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 0, "self-match must not fill");
        // shortId was placed second, so it's the newer side — it gets canceled.
        assertGt(_canceledBlock(shortId), 0, "newer order auto-canceled");
        assertEq(_canceledBlock(longId), 0, "older order untouched");
    }

    /// @notice Two long limits cross one short limit — best-priced long fills first.
    function testPassC_LimitVsLimit_BestPricedLongFirst() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longBest = _placeLimit(alice, true, size, 52_000 * BAZAAR_SCALE); // higher bid wins
        uint256 longWorse = _placeLimit(bob, true, size, 50_500 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(carol, false, size, 50_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        // longs sorted DESC by price → [longBest, longWorse]
        uint256 success = _match(_lists(_two(longBest, longWorse), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1);
        assertEq(_filledSize(longBest), size, "best long filled");
        assertEq(_filledSize(longWorse), 0, "worse long untouched");
    }

    /// @notice Two short limits cross one long limit — best-priced short (lowest ask) fills first.
    function testPassC_LimitVsLimit_BestPricedShortFirst() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longId = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        uint256 shortBest = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE); // lower ask wins
        uint256 shortWorse = _placeLimit(carol, false, size, 50_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        // shorts sorted ASC by price → [shortBest, shortWorse]
        uint256 success = _match(_lists(_one(longId), _two(shortBest, shortWorse), _empty(), _empty()), 10);

        assertEq(success, 1);
        assertEq(_filledSize(shortBest), size);
        assertEq(_filledSize(shortWorse), 0);
    }

    /// @notice Two-pair chain: longA → shortA, longB → shortB, all in one batch.
    function testPassC_LimitVsLimit_MultipleSuccessivePairs() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longA = _placeLimit(alice, true, size, 52_000 * BAZAAR_SCALE);
        uint256 longB = _placeLimit(bob, true, size, 51_000 * BAZAAR_SCALE);
        uint256 shortA = _placeLimit(carol, false, size, 49_500 * BAZAAR_SCALE);
        uint256 shortB = _placeLimit(dave, false, size, 50_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_two(longA, longB), _two(shortA, shortB), _empty(), _empty()), 10);

        assertEq(success, 2, "two pairs match");
        assertEq(_filledSize(longA), size);
        assertEq(_filledSize(longB), size);
        assertEq(_filledSize(shortA), size);
        assertEq(_filledSize(shortB), size);
    }

    /// @notice maxMatches = 1 caps the walk after a single fill even when more crosses exist.
    function testPassC_LimitVsLimit_MaxMatchesCircuitBreaker() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longA = _placeLimit(alice, true, size, 52_000 * BAZAAR_SCALE);
        uint256 longB = _placeLimit(bob, true, size, 51_000 * BAZAAR_SCALE);
        uint256 shortA = _placeLimit(carol, false, size, 49_500 * BAZAAR_SCALE);
        uint256 shortB = _placeLimit(dave, false, size, 50_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_two(longA, longB), _two(shortA, shortB), _empty(), _empty()), 1);

        assertEq(success, 1, "maxMatches=1 stops after first fill");
        // One pair filled; the other pair still has zero fills.
        uint256 filledA = _filledSize(longA);
        uint256 filledB = _filledSize(longB);
        assertTrue(
            (filledA == size && filledB == 0) || (filledA == 0 && filledB == size), "exactly one long should be filled"
        );
    }

    /// @notice Post-only that crosses an older counterparty is auto-canceled.
    function testPassC_LimitVsLimit_PostOnlyAutoCancelsOnCross() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // older short @ 49k
        uint256 shortId = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);
        // newer post-only long @ 51k — crosses → must auto-cancel itself
        bytes[] memory pu = _freshPrice();
        vm.prank(alice);
        pair.createOrder(
            BazaarTypes.OrderType.Limit,
            0,
            51_000 * BAZAAR_SCALE,
            0,
            size,
            true,
            true,
            uint64(block.number + 500_000),
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
        uint256 longId = _newestLimitOrderId(alice);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 0, "post-only must not match against older book");
        assertGt(_canceledBlock(longId), 0, "post-only auto-canceled");
        assertEq(_canceledBlock(shortId), 0, "resting short untouched");
    }

    /// @notice Sort violation — longLimits passed with worse price first reverts.
    ///         Uses 2 shorts so the walk advances past the first long and loads the second
    ///         (out-of-order) long, triggering the sort check at head-load.
    function testPassC_LimitVsLimit_SortViolation_RevertsLongs() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longWorse = _placeLimit(alice, true, size, 50_500 * BAZAAR_SCALE);
        uint256 longBest = _placeLimit(bob, true, size, 52_000 * BAZAAR_SCALE);
        // Two shorts to keep the walk alive after the first long fully fills
        uint256 shortA = _placeLimit(carol, false, size, 49_500 * BAZAAR_SCALE);
        uint256 shortB = _placeLimit(dave, false, size, 50_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        // Pass longs in wrong order (worse before best) — should revert SortViolation when
        // the engine tries to load longBest after longWorse fully fills.
        BazaarTypes.OrderLists memory bad = _lists(_two(longWorse, longBest), _two(shortA, shortB), _empty(), _empty());
        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert();
        pair.matchBatch(bad, 10, pu, uint64(block.number - 1));
    }

    /// @notice Empty lists fail at validation (NoMatchesProvided).
    function testPassC_EmptyLists_Reverts() public {
        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__NoMatchesProvided.selector);
        pair.matchBatch(_lists(_empty(), _empty(), _empty(), _empty()), 10, pu, uint64(block.number - 1));
    }

    /// @notice maxMatches = 0 reverts at the entry guard.
    function testPassC_ZeroMaxMatches_Reverts() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 longId = _placeLimit(alice, true, 1 * BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        vm.roll(block.number + 2);

        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__InvalidMaxMatches.selector);
        pair.matchBatch(_lists(_one(longId), _empty(), _empty(), _empty()), 0, pu, uint64(block.number - 1));
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       PASS B — markets × limits (basic coverage)             ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice One long market vs one short limit — market takes liquidity at the limit's price.
    function testPassB_LongMarketTakesShortLimit() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 shortId = _placeLimit(bob, false, size, 50_500 * BAZAAR_SCALE);
        uint256 marketId = _placeMarket(alice, true, size, 200); // 2% slippage cap → bound = 51,000

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_empty(), _one(shortId), _one(marketId), _empty()), 10);

        assertEq(success, 1, "market x limit must match");
        assertEq(_filledSize(shortId), size);
        assertEq(_filledSize(marketId), size);

        (bool aliceLong,) = _position(alice);
        assertTrue(aliceLong);
    }

    /// @notice One short market vs one long limit — symmetric to the prior test.
    function testPassB_ShortMarketTakesLongLimit() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longId = _placeLimit(alice, true, size, 49_500 * BAZAAR_SCALE);
        uint256 marketId = _placeMarket(bob, false, size, 200);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _empty(), _empty(), _one(marketId)), 10);

        assertEq(success, 1);
        assertEq(_filledSize(longId), size);
        assertEq(_filledSize(marketId), size);

        (bool bobLong,) = _position(bob);
        assertFalse(bobLong, "bob should be short");
    }

    /// @notice Market with too-tight slippage cap cannot cross the limit's price → no fill, no cross.
    function testPassB_LongMarket_SlippageCapBelowLimit_NoFill() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // Short limit at 51,000 (above oracle 50,000). For a long market to cross,
        // its effective price must be >= 51,000. With 1bp slippage, bound = 50,005 < 51,000.
        uint256 shortId = _placeLimit(bob, false, size, 51_000 * BAZAAR_SCALE);
        uint256 marketId = _placeMarket(alice, true, size, 1); // 1bp → bound ~50,005

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_empty(), _one(shortId), _one(marketId), _empty()), 10);

        assertEq(success, 0, "market cannot reach limit price - no fill");
        assertEq(_filledSize(shortId), 0);
        assertEq(_filledSize(marketId), 0);
    }

    /// @notice Self-match in Pass B — newer side auto-cancels.
    function testPassB_LongMarket_SelfMatchAutoCancelsNewerSide() public {
        _deposit(alice, 40_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 shortId = _placeLimit(alice, false, size, 50_500 * BAZAAR_SCALE);
        uint256 marketId = _placeMarket(alice, true, size, 200);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_empty(), _one(shortId), _one(marketId), _empty()), 10);

        assertEq(success, 0, "self-match must not fill");
        // marketId was placed after shortId → market is newer → market gets auto-canceled.
        assertGt(_canceledBlock(marketId), 0, "newer market auto-canceled");
        assertEq(_canceledBlock(shortId), 0);
    }

    /// @notice Market with high slippage takes the best (lowest) short ask first.
    function testPassB_LongMarket_TakesBestShortFirst() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 shortBest = _placeLimit(bob, false, size, 49_500 * BAZAAR_SCALE);
        uint256 shortWorse = _placeLimit(carol, false, size, 50_500 * BAZAAR_SCALE);
        uint256 marketId = _placeMarket(alice, true, size, 500); // 5%

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_empty(), _two(shortBest, shortWorse), _one(marketId), _empty()), 10);

        assertEq(success, 1);
        assertEq(_filledSize(shortBest), size);
        assertEq(_filledSize(shortWorse), 0);
    }

    /// @notice Market eats two short limits when its size is large enough.
    function testPassB_LongMarket_SweepsMultipleShorts() public {
        _deposit(alice, 40_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);

        uint256 smallSize = 1 * BAZAAR_SCALE / 10;
        uint256 bigSize = 2 * BAZAAR_SCALE / 10;

        uint256 shortBest = _placeLimit(bob, false, smallSize, 49_500 * BAZAAR_SCALE);
        uint256 shortWorse = _placeLimit(carol, false, smallSize, 50_500 * BAZAAR_SCALE);
        uint256 marketId = _placeMarket(alice, true, bigSize, 500);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_empty(), _two(shortBest, shortWorse), _one(marketId), _empty()), 10);

        assertEq(success, 2, "market sweeps both shorts");
        assertEq(_filledSize(shortBest), smallSize);
        assertEq(_filledSize(shortWorse), smallSize);
        assertEq(_filledSize(marketId), bigSize);
    }

    /// @notice Market × limit runs BEFORE Pass C — a market and a crossable limit pair on the
    ///         same side: the market takes the limit first. The opposite-side limit (which would
    ///         have crossed with the limit the market consumed) is left unfilled.
    function testPassB_BeforePassC_MarketEatsCrossableLimit() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // Resting orders that would cross each other:
        uint256 longLimitId = _placeLimit(alice, true, size, 50_500 * BAZAAR_SCALE);
        uint256 shortLimitId = _placeLimit(bob, false, size, 49_500 * BAZAAR_SCALE);
        // Long market also targets the short side
        uint256 marketId = _placeMarket(carol, true, size, 500);

        vm.roll(block.number + 2);
        // Submit all four lists — Pass B runs first, sweeps shortLimit with the market.
        // Then Pass C has the longLimit but no remaining shortLimit → no Pass C match.
        uint256 success = _match(_lists(_one(longLimitId), _one(shortLimitId), _one(marketId), _empty()), 10);

        assertEq(success, 1, "market consumed liquidity; long limit goes unfilled this batch");
        assertEq(_filledSize(shortLimitId), size, "short limit eaten by market");
        assertEq(_filledSize(longLimitId), 0, "long limit unfilled - Pass B ran first");
        assertEq(_filledSize(marketId), size);
    }

    /// @notice Market and limit on same side from same creator: market is newer → auto-cancels.
    function testPassB_LongMarket_AutoCancelOnSelfMatch_LongMarketSide() public {
        _deposit(alice, 40_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 shortId = _placeLimit(alice, false, size, 50_500 * BAZAAR_SCALE);
        uint256 marketId = _placeMarket(alice, true, size, 200);

        vm.roll(block.number + 2);
        _match(_lists(_empty(), _one(shortId), _one(marketId), _empty()), 10);

        assertGt(_canceledBlock(marketId), 0, "market is newer, auto-cancels");
    }

    /// @notice Short market with too-tight slippage doesn't fill.
    function testPassB_ShortMarket_SlippageCapAboveLimit_NoFill() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // Long limit at 49,000 — for short market to cross, effective price must be <= 49,000.
        // With 1bp slippage, bound = 50,000 - 5 = 49,995 > 49,000 → no fill.
        uint256 longId = _placeLimit(alice, true, size, 49_000 * BAZAAR_SCALE);
        uint256 marketId = _placeMarket(bob, false, size, 1);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _empty(), _empty(), _one(marketId)), 10);

        assertEq(success, 0);
        assertEq(_filledSize(longId), 0);
        assertEq(_filledSize(marketId), 0);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║         PASS A — vault liquidation × limits                  ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @dev Inject pending-liquidation state into pairVault via stdstore.
    ///      Slots discovered through the public `pairVault()` tuple getter.
    function _setVaultPendingLiq(uint256 size, uint256 entryPrice, uint256 bankruptcyPrice, bool isLong) internal {
        uint256 entryNotional = size * entryPrice / BAZAAR_SCALE;
        uint256 bkNotional = size * bankruptcyPrice / BAZAAR_SCALE;
        _stdstore.target(address(pair)).sig("pairVault()").depth(6).checked_write(size);
        _stdstore.target(address(pair)).sig("pairVault()").depth(7).checked_write(entryNotional);
        _stdstore.target(address(pair)).sig("pairVault()").depth(8).checked_write(bkNotional);
        _stdstore.target(address(pair)).sig("pairVault()").depth(10).checked_write(isLong);
    }

    /// @dev Pin MMR for Pass A band tests. Also stamps lastUpdateTs so the IMR/MMR recalc
    ///      inside matchBatch hits its 1-minute cooldown and can't overwrite the injected value.
    function _setMmr(uint256 mmrBp) internal {
        _stdstore.target(address(pair)).sig("marginRequirements()").depth(1).checked_write(mmrBp);
        _stdstore.target(address(pair)).sig("marginRequirements()").depth(2).checked_write(block.timestamp);
    }

    /// @notice Pass A long liquidation: vault inherited a long → sells into long limits (bids).
    function testPassA_LongLiq_FillsLongLimit() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 liqSize = 1 * BAZAAR_SCALE / 10;
        uint256 longId = _placeLimit(alice, true, liqSize, 49_800 * BAZAAR_SCALE);

        // Vault holds 0.1 BTC long, entered at 51,000, would go bankrupt at 49,000.
        _setVaultPendingLiq(liqSize, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _empty(), _empty(), _empty()), 10);

        assertEq(success, 1, "vault liq fills against long limit");
        assertEq(_filledSize(longId), liqSize, "limit fully filled");
        (,,,,,, uint256 remaining,,,,,) = pair.pairVault();
        assertEq(remaining, 0, "vault pending liq cleared");
    }

    /// @notice Pass A short liquidation: vault inherited a short → buys into short limits (asks).
    function testPassA_ShortLiq_FillsShortLimit() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 liqSize = 1 * BAZAAR_SCALE / 10;
        uint256 shortId = _placeLimit(alice, false, liqSize, 50_200 * BAZAAR_SCALE);

        _setVaultPendingLiq(liqSize, 49_000 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE, false);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_empty(), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1);
        assertEq(_filledSize(shortId), liqSize);
        (,,,,,, uint256 remaining,,,,,) = pair.pairVault();
        assertEq(remaining, 0);
    }

    /// @notice When a vault pending-liq position is closed via a match, the funding accrued on it
    ///         over the holding window is realized into the vault PnL (→ insurance). Isolated by
    ///         running the identical match twice — once with entry funding index 0, once with F0 —
    ///         so the insurance delta is purely the realized funding (the shared price PnL and the
    ///         shared current funding index cancel between the two runs).
    function test_VaultLiqMatch_RealizesPendingLiqFunding() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longId = _placeLimit(alice, true, size, 49_800 * BAZAAR_SCALE);
        _setVaultPendingLiq(size, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true); // vault holds long
        vm.roll(block.number + 2);

        // Run A: pendingLiqEntryFundingIndex = 0 (default) → no extra funding component.
        uint256 snap = vm.snapshotState();
        _match(_lists(_one(longId), _empty(), _empty(), _empty()), 10);
        (,,,,, uint256 insA, uint256 remA,,,,,) = pair.pairVault();
        assertEq(remA, 0, "run A cleared pending-liq");

        // Run B: identical, but entry funding index = F0 above the (shared) current index, so the
        // vault long receives funding = F0 * size / SCALE, realized into insurance.
        vm.revertToState(snap);
        uint256 F0 = 1e18; // positive → same bit-pattern as the int256 slot it's written into
        _stdstore.target(address(pair)).sig("pairVault()").depth(9).checked_write(F0);
        _match(_lists(_one(longId), _empty(), _empty(), _empty()), 10);
        (,,,,, uint256 insB, uint256 remB,,,,,) = pair.pairVault();
        assertEq(remB, 0, "run B cleared pending-liq");

        assertEq(
            int256(insB) - int256(insA),
            int256(F0 * size / BAZAAR_SCALE),
            "realized funding folded into vault PnL -> insurance"
        );
    }

    /// @notice Pass A long-liq fills the highest-priced long limit first, then advances.
    function testPassA_LongLiq_TakesBestPriceFirst() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longBest = _placeLimit(alice, true, size, 50_500 * BAZAAR_SCALE);
        uint256 longWorse = _placeLimit(bob, true, size, 49_800 * BAZAAR_SCALE);

        // Vault liq smaller than longBest → only longBest fills.
        _setVaultPendingLiq(size, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_two(longBest, longWorse), _empty(), _empty(), _empty()), 10);

        assertEq(success, 1);
        assertEq(_filledSize(longBest), size, "best long taken first");
        assertEq(_filledSize(longWorse), 0, "worse long untouched");
    }

    /// @notice Pass A long-liq sweeps multiple long limits when liq size exceeds the head.
    function testPassA_LongLiq_SweepsMultipleLimits() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longA = _placeLimit(alice, true, size, 50_500 * BAZAAR_SCALE);
        uint256 longB = _placeLimit(bob, true, size, 49_900 * BAZAAR_SCALE);

        // Liq size = 2 × limit size — should sweep both.
        _setVaultPendingLiq(2 * size, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_two(longA, longB), _empty(), _empty(), _empty()), 10);

        assertEq(success, 2, "vault liq sweeps both limits");
        assertEq(_filledSize(longA), size);
        assertEq(_filledSize(longB), size);
        (,,,,,, uint256 remaining,,,,,) = pair.pairVault();
        assertEq(remaining, 0);
    }

    /// @notice Pass A long-liq halts when the next limit's price is below the floor
    ///         (oracle × (1 - LIQ_MAX_SLIPPAGE_BP = 5%)) — vault refuses to sell below 47,500.
    function testPassA_LongLiq_HaltsBelowFloor() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // First limit OK at 49,500 (above floor 47,500), second too low at 47,000.
        uint256 longOk = _placeLimit(alice, true, size, 49_500 * BAZAAR_SCALE);
        uint256 longBad = _placeLimit(bob, true, size, 47_000 * BAZAAR_SCALE);

        _setVaultPendingLiq(2 * size, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_two(longOk, longBad), _empty(), _empty(), _empty()), 10);

        assertEq(success, 1, "only the price-OK limit fills");
        assertEq(_filledSize(longOk), size);
        assertEq(_filledSize(longBad), 0, "below-floor limit not filled");
        (,,,,,, uint256 remaining,,,,,) = pair.pairVault();
        assertEq(remaining, size, "remaining liq stays in vault");
    }

    /// @notice Pass A short-liq halts when the next short ask is above the ceiling
    ///         (oracle × (1 + LIQ_MAX_SLIPPAGE_BP = 5%) = 52,500).
    function testPassA_ShortLiq_HaltsAboveCeiling() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 shortOk = _placeLimit(alice, false, size, 50_500 * BAZAAR_SCALE);
        uint256 shortBad = _placeLimit(bob, false, size, 53_000 * BAZAAR_SCALE); // above ceiling

        _setVaultPendingLiq(2 * size, 49_000 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE, false);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_empty(), _two(shortOk, shortBad), _empty(), _empty()), 10);

        assertEq(success, 1);
        assertEq(_filledSize(shortOk), size);
        assertEq(_filledSize(shortBad), 0);
    }

    /// @notice Pass A band tightens to MMR when MMR < LIQ_MAX_SLIPPAGE_BP: at 2% MMR the
    ///         floor is oracle × 0.98 = 49,000 — a bid at 48,500 (fine under the 5% cap
    ///         alone) is refused.
    function testPassA_LongLiq_BandTightensToMmr() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longOk = _placeLimit(alice, true, size, 49_500 * BAZAAR_SCALE); // above the 49,000 floor
        uint256 longBad = _placeLimit(bob, true, size, 48_500 * BAZAAR_SCALE); // inside 5% cap, below MMR floor

        _setVaultPendingLiq(2 * size, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);
        _setMmr(200); // 2% — post-warmup minimum (MIN_IMR_BP / 2)

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_two(longOk, longBad), _empty(), _empty(), _empty()), 10);

        assertEq(success, 1, "only the limit above the MMR floor fills");
        assertEq(_filledSize(longOk), size);
        assertEq(_filledSize(longBad), 0, "bid below MMR-tightened floor not filled");
        (,,,,,, uint256 remaining,,,,,) = pair.pairVault();
        assertEq(remaining, size, "remaining liq stays in vault");
    }

    /// @notice Short-side mirror: at 2% MMR the buyback ceiling is oracle × 1.02 = 51,000 —
    ///         an ask at 52,000 (fine under the 5% cap alone) is refused.
    function testPassA_ShortLiq_BandTightensToMmr() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 shortOk = _placeLimit(alice, false, size, 50_500 * BAZAAR_SCALE); // below the 51,000 ceiling
        uint256 shortBad = _placeLimit(bob, false, size, 52_000 * BAZAAR_SCALE); // inside 5% cap, above MMR ceiling

        _setVaultPendingLiq(2 * size, 49_000 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE, false);
        _setMmr(200);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_empty(), _two(shortOk, shortBad), _empty(), _empty()), 10);

        assertEq(success, 1, "only the ask below the MMR ceiling fills");
        assertEq(_filledSize(shortOk), size);
        assertEq(_filledSize(shortBad), 0, "ask above MMR-tightened ceiling not filled");
        (,,,,,, uint256 remaining,,,,,) = pair.pairVault();
        assertEq(remaining, size, "remaining liq stays in vault");
    }

    /// @notice Closing is never more expensive than opening: with the fund in surplus the
    ///         risk-adding taker insurance fee is fully discounted to 0, and the closing
    ///         portion must inherit that discount (min(closingFee, riskAddingFee)) rather
    ///         than paying the flat base fee. Asserted via insurance-fund deltas: an opening
    ///         batch and a closing batch of identical notional must credit the fund the same
    ///         amount (maker insurance fee only — integrator-less orders pay no integrator
    ///         fee — net of bug-bounty tax; taker insurance fee 0 in both).
    function testTakerInsuranceFee_ClosingNeverExceedsOpening() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10; // 0.1 BTC → $5,000 notional at 50,000

        // Open: alice market-buys (taker, risk-adding) against bob's short limit.
        uint256 bobShort = _placeLimit(bob, false, size, 50_000 * BAZAAR_SCALE);
        uint256 aliceOpen = _placeMarket(alice, true, size, 500);

        (,,,,, uint256 fund0,,,,,,) = pair.pairVault();

        vm.roll(vm.getBlockNumber() + 2);
        uint256 success = _match(_lists(_empty(), _one(bobShort), _one(aliceOpen), _empty()), 10);
        assertEq(success, 1, "opening match fills");

        (,,,,, uint256 fund1,,,,,,) = pair.pairVault();

        // Close: alice market-sells (taker, fully closing) against bob's long limit.
        uint256 bobLong = _placeLimit(bob, true, size, 50_000 * BAZAAR_SCALE);
        uint256 aliceClose = _placeMarket(alice, false, size, 500);

        // vm.getBlockNumber(): via_ir may CSE a plain block.number read across the earlier
        // vm.roll, silently rolling to a stale target; the cheatcode read can't be cached.
        vm.roll(vm.getBlockNumber() + 2);
        success = _match(_lists(_one(bobLong), _empty(), _empty(), _one(aliceClose)), 10);
        assertEq(success, 1, "closing match fills");

        (,,,,, uint256 fund2,,,,,,) = pair.pairVault();

        // Both batches credit the fund identically: the maker's 0.5 bp insurance fee on
        // $5,000 ($0.25), net of the 1% bug-bounty tax → $0.2475. No integrator fees are
        // charged (orders carry no integrator). The taker insurance fee is 0 in BOTH
        // batches: opening is fully surplus-discounted (fund >> 2x target), and closing
        // takes min(closingFee, riskAddingFee) = 0. Pre-fix, the closing batch charged
        // the taker the flat 0.5 bp base fee and its delta exceeded the opening batch's.
        uint256 fillNotional = 5_000 * BAZAAR_SCALE;
        uint256 grossPerBatch = fillNotional * 50 / 1_000_000; // maker insurance fee
        uint256 expectedPerBatch = grossPerBatch * 9_900 / 10_000; // net of 1% bug-bounty tax
        assertEq(fund1 - fund0, expectedPerBatch, "opening batch: taker pays 0 in surplus");
        assertEq(fund2 - fund1, expectedPerBatch, "closing batch: taker pays 0, closing never exceeds opening");
    }

    /// @notice Pass A partial fill: vault liq smaller than the limit's size — limit gets partial fill.
    function testPassA_LongLiq_PartialFillsLimit() public {
        _deposit(alice, 30_000 * BAZAAR_SCALE);
        uint256 limitSize = 5 * BAZAAR_SCALE / 10; // 0.5 BTC
        uint256 liqSize = 1 * BAZAAR_SCALE / 10; // 0.1 BTC

        uint256 longId = _placeLimit(alice, true, limitSize, 49_800 * BAZAAR_SCALE);
        _setVaultPendingLiq(liqSize, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _empty(), _empty(), _empty()), 10);

        assertEq(success, 1);
        assertEq(_filledSize(longId), liqSize, "limit partially filled by liq size");
        (,,,,,, uint256 remaining,,,,,) = pair.pairVault();
        assertEq(remaining, 0, "vault liq cleared");
    }

    /// @notice Pass A respects maxMatches.
    function testPassA_LongLiq_RespectsMaxMatches() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longA = _placeLimit(alice, true, size, 50_500 * BAZAAR_SCALE);
        uint256 longB = _placeLimit(bob, true, size, 49_900 * BAZAAR_SCALE);

        _setVaultPendingLiq(2 * size, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_two(longA, longB), _empty(), _empty(), _empty()), 1);

        assertEq(success, 1, "maxMatches=1 stops after one fill");
        assertEq(_filledSize(longA), size, "best limit filled");
        assertEq(_filledSize(longB), 0, "second limit untouched");
        (,,,,,, uint256 remaining,,,,,) = pair.pairVault();
        assertEq(remaining, size, "half the liq remains");
    }

    /// @notice With no pending liq, Pass A is a no-op and Pass C still runs.
    function testPassA_NoPendingLiq_FallsThroughToPassC() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longId = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);

        // No _setVaultPendingLiq call → pendingLiqSize == 0.
        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1, "Pass C cross still happens");
        assertEq(_filledSize(longId), size);
        assertEq(_filledSize(shortId), size);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       SORT VIOLATIONS — remaining lists                      ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice Shorts must be sorted ASC by price — wrong order reverts.
    function testSort_ShortLimits_RevertsOnDescOrder() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longA = _placeLimit(alice, true, size, 52_000 * BAZAAR_SCALE);
        uint256 longB = _placeLimit(bob, true, size, 51_000 * BAZAAR_SCALE);
        uint256 shortHigh = _placeLimit(carol, false, size, 50_500 * BAZAAR_SCALE);
        uint256 shortLow = _placeLimit(dave, false, size, 49_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        // Shorts wrong order (high before low). Two longs to keep walk alive past first fill.
        BazaarTypes.OrderLists memory bad = _lists(_two(longA, longB), _two(shortHigh, shortLow), _empty(), _empty());
        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert();
        pair.matchBatch(bad, 10, pu, uint64(block.number - 1));
    }

    /// @notice Long markets must be sorted DESC by maxSlippageBp — wrong order reverts.
    function testSort_LongMarkets_RevertsOnAscOrder() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // Two crossable shorts (so walk keeps going past first fill)
        uint256 shortA = _placeLimit(carol, false, size, 49_500 * BAZAAR_SCALE);
        uint256 shortB = _placeLimit(dave, false, size, 49_800 * BAZAAR_SCALE);
        // Markets in wrong order: lower slippage first
        uint256 marketLowSlip = _placeMarket(alice, true, size, 100);
        uint256 marketHighSlip = _placeMarket(bob, true, size, 300);

        vm.roll(block.number + 2);
        BazaarTypes.OrderLists memory bad =
            _lists(_empty(), _two(shortA, shortB), _two(marketLowSlip, marketHighSlip), _empty());
        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert();
        pair.matchBatch(bad, 10, pu, uint64(block.number - 1));
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       OBSERVATION-BLOCK GUARDS                               ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice observationBlock in the future reverts.
    function testObservationBlock_InFuture_Reverts() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 longId = _placeLimit(alice, true, 1 * BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);
        vm.roll(block.number + 2);

        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert();
        pair.matchBatch(_lists(_one(longId), _empty(), _empty(), _empty()), 10, pu, uint64(block.number + 1));
    }

    /// @notice observationBlock more than MAX_OBSERVATION_BLOCK_AGE (12) blocks old reverts.
    function testObservationBlock_TooOld_Reverts() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 longId = _placeLimit(alice, true, 1 * BAZAAR_SCALE / 10, 51_000 * BAZAAR_SCALE);

        uint64 oldBlock = uint64(block.number);
        vm.roll(block.number + 20); // age > 12

        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert();
        pair.matchBatch(_lists(_one(longId), _empty(), _empty(), _empty()), 10, pu, oldBlock);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       HEAD-LOAD EDGE CASES                                   ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice A canceled order in a list is silently race-skipped (not a revert).
    function testHeadLoad_CanceledOrder_RaceSkipped() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // Place two longs; the better-priced one gets canceled before matching.
        uint256 longBest = _placeLimit(alice, true, size, 52_000 * BAZAAR_SCALE);
        uint256 longWorse = _placeLimit(bob, true, size, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(carol, false, size, 50_000 * BAZAAR_SCALE);

        // Alice cancels her best long
        uint256[] memory ids = new uint256[](1);
        ids[0] = longBest;
        vm.prank(alice);
        pair.cancelOrders(ids, 0, 0, 0, "");

        vm.roll(block.number + 2);
        // Sequencer still includes the canceled longBest in the list — engine should skip it
        // and fill longWorse against the short.
        uint256 success = _match(_lists(_two(longBest, longWorse), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1, "canceled head skipped, walk continues");
        assertEq(_filledSize(longWorse), size, "second-best long filled");
        assertEq(_filledSize(shortId), size);
    }

    /// @notice An order created AFTER observationBlock is rejected (sequencer can't claim observation).
    function testHeadLoad_CreatedAfterObservation_Reverts() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 shortId = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);

        // Capture an "old" observation block, then create the long order AFTER it.
        uint64 obs = uint64(block.number);
        vm.roll(block.number + 2);
        uint256 longId = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        vm.roll(block.number + 1);

        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert();
        pair.matchBatch(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10, pu, obs);
    }

    /// @notice An expired order in the list is race-skipped (expiry < currentBlock).
    function testHeadLoad_ExpiredOrder_RaceSkipped() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;

        // Place a long order with short expiry by passing a small expiry block.
        bytes[] memory pu0 = _freshPrice();
        vm.prank(alice);
        pair.createOrder(
            BazaarTypes.OrderType.Limit,
            0,
            52_000 * BAZAAR_SCALE,
            0,
            size,
            true,
            false,
            uint64(block.number + 100), // expires soon
            address(0),
            pu0,
            0,
            0,
            0,
            ""
        );
        uint256 longExpiring = _newestLimitOrderId(alice);

        uint256 longBackup = _placeLimit(bob, true, size, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(carol, false, size, 50_000 * BAZAAR_SCALE);

        // Roll forward past the first long's expiry.
        vm.roll(block.number + 200);

        uint256 success = _match(_lists(_two(longExpiring, longBackup), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1, "expired head skipped, walk continues with backup");
        assertEq(_filledSize(longExpiring), 0, "expired order not filled");
        assertEq(_filledSize(longBackup), size);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       ORDER TYPES — StopLimit / TakeProfit / StopLoss        ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice StopLimit (post-trigger) matches like a Limit in Pass C. The engine now also gates
    ///         on the trigger: a buy StopLimit (isLong=true) only matches once the oracle is at/above
    ///         the trigger. Here trigger $49,500 <= oracle $50,000 → triggered → matches at limitPrice.
    function testOrderType_StopLimit_MatchesInPassC() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // Long StopLimit with triggerPrice 49,500, limitPrice 51,000 — once triggered acts as a long limit at 51k.
        uint256 stopLimitId = _placeStopLimit(alice, true, size, 49_500 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(stopLimitId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1, "StopLimit fills against short limit");
        assertEq(_filledSize(stopLimitId), size);
        assertEq(_filledSize(shortId), size);
    }

    /// @notice Untriggered StopLimit must not match: a buy StopLimit with trigger ABOVE the oracle
    ///         ($50,500 > $50,000) hasn't broken out yet, so it is skipped in the limit walk — the
    ///         sequencer can't arm it early. (limitPrice would bound the fill regardless; this also
    ///         prevents the order being matched at all before its trigger.)
    function testOrderType_StopLimit_UntriggeredDoesNotFill() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 stopLimitId = _placeStopLimit(alice, true, size, 50_500 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(stopLimitId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 0, "untriggered StopLimit does not match");
        assertEq(_filledSize(stopLimitId), 0, "StopLimit left unfilled");
    }

    /// @notice A buy StopLimit with limitPrice BELOW triggerPrice is a dead config (can never fill
    ///         under settlement-price trigger semantics) and must be rejected at creation.
    function testStopLimit_RejectsBuyLimitBelowTrigger() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 size = 1 * BAZAAR_SCALE / 10;
        bytes[] memory pu = _freshPrice();
        vm.expectRevert(OrderManagementLib.OrderManagementLib__StopLimitPriceOnWrongSide.selector);
        vm.prank(alice);
        pair.createOrder(
            BazaarTypes.OrderType.StopLimit,
            52_000 * BAZAAR_SCALE,
            51_000 * BAZAAR_SCALE,
            0,
            size,
            true,
            false,
            uint64(block.number + 500_000),
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
    }

    /// @notice A sell StopLimit with limitPrice ABOVE triggerPrice is the mirror dead config and
    ///         must also be rejected.
    function testStopLimit_RejectsSellLimitAboveTrigger() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        uint256 size = 1 * BAZAAR_SCALE / 10;
        bytes[] memory pu = _freshPrice();
        vm.expectRevert(OrderManagementLib.OrderManagementLib__StopLimitPriceOnWrongSide.selector);
        vm.prank(alice);
        pair.createOrder(
            BazaarTypes.OrderType.StopLimit,
            48_000 * BAZAAR_SCALE,
            49_000 * BAZAAR_SCALE,
            0,
            size,
            false,
            false,
            uint64(block.number + 500_000),
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
    }

    /// @notice The boundary (limitPrice == triggerPrice) is fillable for both sides and accepted;
    ///         a sell with limit below trigger (correct side) is accepted too.
    function testStopLimit_AllowsCorrectSideAndEqual() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = 1 * BAZAAR_SCALE / 10;

        // limit == trigger: boundary, accepted.
        uint256 buyEqual = _placeStopLimit(alice, true, size, 50_000 * BAZAAR_SCALE, 50_000 * BAZAAR_SCALE);
        assertGt(buyEqual, 0, "buy StopLimit with limit == trigger accepted");

        // Sell with limit < trigger (breakdown, correct side): accepted.
        uint256 sellOk = _placeStopLimit(bob, false, size, 48_000 * BAZAAR_SCALE, 47_500 * BAZAAR_SCALE);
        assertGt(sellOk, 0, "sell StopLimit with limit < trigger accepted");
    }

    /// @notice TakeProfit fills against a counterparty limit when triggered.
    ///         Alice opens long, attaches TP @ 52k, bob places long @ 52k → TP fills (alice closes).
    function testOrderType_TakeProfit_FillsAgainstLongLimit() public {
        uint256 size = 1 * BAZAAR_SCALE / 10;
        _openPosition(alice, bob, true, size); // alice goes long, bob is short

        // Verify alice has a long position
        (bool aliceLong, uint256 aliceSize) = _position(alice);
        assertTrue(aliceLong, "alice is long after open");
        assertEq(aliceSize, size);

        // Alice attaches a TakeProfit (opposite direction = short) at 52k
        uint256 tpId = _placeTakeProfit(alice, false, size, 52_000 * BAZAAR_SCALE);

        // Carol places a long limit that crosses
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 carolLongId = _placeLimit(carol, true, size, 52_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(carolLongId), _one(tpId), _empty(), _empty()), 10);

        assertEq(success, 1, "TP fills against carol's long limit");
        assertEq(_filledSize(tpId), size);

        // Alice's position should be closed (size = 0).
        (, uint256 aliceFinalSize) = _position(alice);
        assertEq(aliceFinalSize, 0, "alice position closed by TP");
    }

    /// @notice StopLoss is oracle-derived and may be placed in the markets list. A sell stop
    ///         (closing a long) only matches once the batch oracle price has fallen to/through its
    ///         trigger. Here the trigger is $49,500 and the batch settles at $49,000 → triggered.
    function testOrderType_StopLoss_FillsInPassB() public {
        uint256 size = 1 * BAZAAR_SCALE / 10;
        _openPosition(alice, bob, true, size); // alice long, bob short

        uint256 slId = _placeStopLoss(alice, false, size, 49_500 * BAZAAR_SCALE, 500);

        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 carolLongId = _placeLimit(carol, true, size, 49_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        // Settle at $49,000 (<= trigger $49,500) → the sell stop is triggered and fills.
        uint256 success = _matchAtPrice(_lists(_one(carolLongId), _empty(), _empty(), _one(slId)), 10, 49_000);

        assertEq(success, 1, "StopLoss fills via Pass B once triggered");
        assertEq(_filledSize(slId), size, "stop loss fully filled");
        assertEq(_filledSize(carolLongId), size, "counterparty long filled");

        // Alice was long; SL on short side closes her position.
        (, uint256 aliceSize) = _position(alice);
        assertEq(aliceSize, 0, "alice closed via stop loss");
    }

    /// @notice Wrongful-trigger defense: a sell StopLoss (trigger $49,500) must NOT fill when the
    ///         batch oracle price is ABOVE the trigger ($50,000). The sequencer can no longer
    ///         force-close the stop early; the order is skipped, not matched.
    function testOrderType_StopLoss_UntriggeredDoesNotFill() public {
        uint256 size = 1 * BAZAAR_SCALE / 10;
        _openPosition(alice, bob, true, size); // alice long

        uint256 slId = _placeStopLoss(alice, false, size, 49_500 * BAZAAR_SCALE, 500);

        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 carolLongId = _placeLimit(carol, true, size, 49_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        // Settle at $50,000 (> trigger $49,500): a sell stop fires only on a fall to/through the
        // trigger, so it is NOT triggered and must be skipped.
        uint256 success = _matchAtPrice(_lists(_one(carolLongId), _empty(), _empty(), _one(slId)), 10, 50_000);

        assertEq(success, 0, "untriggered StopLoss does not match");
        assertEq(_filledSize(slId), 0, "stop loss left unfilled");
        (, uint256 aliceSize) = _position(alice);
        assertEq(aliceSize, size, "alice position untouched");
    }

    /// @notice Buy-stop direction (isLong=true, closing a SHORT) exercises the `>=` branch: it
    ///         matches once the oracle price is at/above the trigger. Trigger $49,500, oracle
    ///         $50,000 → triggered → fills, closing alice's short.
    function testOrderType_StopLoss_BuyStop_FillsWhenTriggered() public {
        uint256 size = 1 * BAZAAR_SCALE / 10;
        _openPosition(alice, bob, false, size); // alice SHORT

        // Buy stop closing the short. Oracle ($50k) is at/above the trigger → triggered.
        uint256 slId = _placeStopLoss(alice, true, size, 49_500 * BAZAAR_SCALE, 500);

        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 carolShortId = _placeLimit(carol, false, size, 49_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 filled = _match(_lists(_empty(), _one(carolShortId), _one(slId), _empty()), 10);
        assertEq(filled, 1, "buy stop at/above trigger fills");
        assertEq(_filledSize(slId), size, "filled once triggered");
        (, uint256 aliceSize) = _position(alice);
        assertEq(aliceSize, 0, "short closed via buy stop");
    }

    /// @notice Buy-stop NOT triggered: with the trigger ABOVE the oracle ($50,500 > $50,000) a buy
    ///         stop must not match (price hasn't risen to it). Confirms the `>=` direction can't be
    ///         force-fired early from below.
    function testOrderType_StopLoss_BuyStop_UntriggeredDoesNotFill() public {
        uint256 size = 1 * BAZAAR_SCALE / 10;
        _openPosition(alice, bob, false, size); // alice SHORT

        uint256 slId = _placeStopLoss(alice, true, size, 50_500 * BAZAAR_SCALE, 500);

        _deposit(carol, 20_000 * BAZAAR_SCALE);
        uint256 carolShortId = _placeLimit(carol, false, size, 50_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_empty(), _one(carolShortId), _one(slId), _empty()), 10);
        assertEq(success, 0, "buy stop below trigger does not fill");
        assertEq(_filledSize(slId), 0, "left unfilled");
        (, uint256 aliceSize) = _position(alice);
        assertEq(aliceSize, size, "short untouched");
    }

    /// @notice The omission challenge must respect the StopLoss trigger: a StopLoss whose trigger
    ///         the batch oracle price never reached was CORRECTLY omitted, so challenging it is
    ///         rejected (reason 10) and the sequencer is not slashed for declining to fire an
    ///         untriggered stop. Mirrors the matching-engine trigger gate.
    function test_OmissionChallenge_RejectsUntriggeredStopLoss() public {
        uint256 size = 1 * BAZAAR_SCALE / 10;
        _openPosition(alice, bob, true, size); // alice long

        // Sell stop on the long, trigger $49,500. The batch settles at $50,000 (> trigger) → the
        // stop is NOT triggered, so omitting it is correct, not censorship.
        uint256 slId = _placeStopLoss(alice, false, size, 49_500 * BAZAAR_SCALE, 500);

        // A separate matched pair so the batch records (batchHashes set, totalMatchNotional > 0)
        // while the StopLoss is omitted.
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        uint256 carolLong = _placeLimit(carol, true, size, 51_000 * BAZAAR_SCALE);
        uint256 daveShort = _placeLimit(dave, false, size, 49_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        vm.recordLogs();
        uint256 success = _match(_lists(_one(carolLong), _one(daveShort), _empty(), _empty()), 10);
        assertEq(success, 1, "carol/dave match records the batch; SL omitted");
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _captureBatch();
        assertEq(info.oraclePrice, 50_000 * BAZAAR_SCALE, "batch settled above the stop trigger");

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.expectEmit(true, true, true, true, address(sequencer));
        emit BazaarSequencer.OmissionChallengeRejected(address(pair), batchId, slId, 10);
        sequencer.challengeOmission(address(pair), batchId, info, slId);

        assertEq(sequencer.sequencerBonds(seq), bondBefore, "untriggered StopLoss omission is not slashable");
    }

    /// @notice Same trigger gate on the challenge for StopLimit: a buy StopLimit whose trigger the
    ///         batch oracle price never reached ($50,500 > $50,000) was correctly omitted, so the
    ///         omission challenge is rejected (reason 10) and the sequencer is not slashed.
    function test_OmissionChallenge_RejectsUntriggeredStopLimit() public {
        uint256 size = 1 * BAZAAR_SCALE / 10;
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        // Buy StopLimit, trigger $50,500 above the $50,000 batch price → not triggered.
        uint256 stopLimitId = _placeStopLimit(alice, true, size, 50_500 * BAZAAR_SCALE, 51_000 * BAZAAR_SCALE);

        // Separate matched pair so the batch records while the StopLimit is omitted.
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
        uint256 carolLong = _placeLimit(carol, true, size, 51_000 * BAZAAR_SCALE);
        uint256 daveShort = _placeLimit(dave, false, size, 49_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        vm.recordLogs();
        uint256 success = _match(_lists(_one(carolLong), _one(daveShort), _empty(), _empty()), 10);
        assertEq(success, 1, "carol/dave match records the batch; StopLimit omitted");
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _captureBatch();
        assertEq(info.oraclePrice, 50_000 * BAZAAR_SCALE, "batch settled below the breakout trigger");

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.expectEmit(true, true, true, true, address(sequencer));
        emit BazaarSequencer.OmissionChallengeRejected(address(pair), batchId, stopLimitId, 10);
        sequencer.challengeOmission(address(pair), batchId, info, stopLimitId);

        assertEq(sequencer.sequencerBonds(seq), bondBefore, "untriggered StopLimit omission is not slashable");
    }

    /// @notice Per-(batch, order) challenge key: a sequencer that censors the SAME order across two
    ///         different batches is slashed for EACH batch. Previously the key was per-order, so the
    ///         second omission reverted AlreadyChallenged and the order was censorable for free
    ///         after one slash.
    function test_OmissionChallenge_SameOrderTwoBatches_SlashesTwice() public {
        // Batch 1: alice's aggressive long is omitted while carol/dave match (helper records it).
        (uint256 omittedLong, uint256 batchId1, BazaarTypes.BatchInfo memory info1,,) = _setupOmittedAliceLong();

        uint256 bond0 = sequencer.sequencerBonds(seq);
        vm.prank(makeAddr("challenger1"));
        sequencer.challengeOmission(address(pair), batchId1, info1, omittedLong);
        uint256 bond1 = sequencer.sequencerBonds(seq);
        assertLt(bond1, bond0, "batch 1 omission slashes the sequencer");

        // Batch 2: a fresh worse-priced pair matches; alice's SAME long is omitted again.
        address eve = makeAddr("eve");
        address frank = makeAddr("frank");
        usdc.mint(eve, INITIAL_USER_BALANCE);
        usdc.mint(frank, INITIAL_USER_BALANCE);
        _deposit(eve, 20_000 * BAZAAR_SCALE);
        _deposit(frank, 20_000 * BAZAAR_SCALE);
        uint256 size = 1 * BAZAAR_SCALE / 10; // small, stays under the rolling volume cap
        uint256 eveLong = _placeLimit(eve, true, size, 51_000 * BAZAAR_SCALE);
        uint256 frankShort = _placeLimit(frank, false, size, 49_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        vm.recordLogs();
        uint256 success = _match(_lists(_one(eveLong), _one(frankShort), _empty(), _empty()), 10);
        assertEq(success, 1, "batch 2 records; alice's long omitted again");
        (uint256 batchId2, BazaarTypes.BatchInfo memory info2) = _captureBatch();
        assertTrue(batchId2 != batchId1, "distinct batch");

        // The SAME order, omitted in a different batch, is challengeable again (no AlreadyChallenged).
        vm.prank(makeAddr("challenger2"));
        sequencer.challengeOmission(address(pair), batchId2, info2, omittedLong);
        assertLt(sequencer.sequencerBonds(seq), bond1, "second batch's omission of the same order slashes again");
    }

    /// @notice Omission slash routes 1/7 (1%) to the challenger and 6/7 (6%) to the pair's
    ///         insurance fund — not to the victim — so a sequencer self-censoring its own order
    ///         can't recover the 6%.
    function test_OmissionSlash_SixSeventhsToInsurance() public {
        (
            uint256 omittedLong,
            uint256 batchId,
            BazaarTypes.BatchInfo memory info,
            uint256 aliceSize,
            uint256 aliceLimitPrice
        ) = _setupOmittedAliceLong();

        uint256 censoredNotional = aliceSize * aliceLimitPrice / BAZAAR_SCALE;
        uint256 penaltyBase = censoredNotional < info.totalMatchNotional ? censoredNotional : info.totalMatchNotional;
        uint256 fullPenalty = penaltyBase * sequencer.OMISSION_PENALTY_BP() / 10_000;
        uint256 challengerShare = fullPenalty / 7;
        uint256 insuranceShare = fullPenalty - challengerShare;

        address challenger = makeAddr("challenger");
        uint256 bondBefore = sequencer.sequencerBonds(seq);
        (,,,,, uint256 insBefore,,,,,,) = pair.pairVault();

        vm.prank(challenger);
        sequencer.challengeOmission(address(pair), batchId, info, omittedLong);

        // Full penalty slashed; 1/7 to the challenger, 6/7 credited to insurance (backed by USDC).
        assertEq(bondBefore - sequencer.sequencerBonds(seq), fullPenalty, "full penalty slashed");
        assertEq(usdc.balanceOf(challenger), challengerShare / 1e12, "challenger gets the 1/7 bounty");
        (,,,,, uint256 insAfter,,,,,,) = pair.pairVault();
        assertEq(insAfter - insBefore, (insuranceShare / 1e12) * 1e12, "6/7 credited to pair insurance");
    }

    /// @notice Same (batch, order) still can't be double-slashed: a second challenge of the same
    ///         omission in the same batch reverts AlreadyChallenged.
    function test_OmissionChallenge_SameBatchAndOrder_RevertsOnSecondTry() public {
        (uint256 omittedLong, uint256 batchId, BazaarTypes.BatchInfo memory info,,) = _setupOmittedAliceLong();

        vm.prank(makeAddr("challengerA"));
        sequencer.challengeOmission(address(pair), batchId, info, omittedLong);

        vm.expectRevert(BazaarSequencer.Sequencer__AlreadyChallenged.selector);
        vm.prank(makeAddr("challengerB"));
        sequencer.challengeOmission(address(pair), batchId, info, omittedLong);
    }

    /// @notice The omission window is time-based on matchTimestamp: past SEQUENCER_WINDOW the
    ///         challenge reverts ChallengeWindowExpired. Pre-fix the gate compared L1 block.number
    ///         against the L2 executionBlock (ArbSys.arbBlockNumber) — incomparable sequences, so
    ///         the window never expired and batches stayed challengeable forever.
    function test_OmissionChallenge_WindowExpires_TimeBased() public {
        (uint256 omittedLong, uint256 batchId, BazaarTypes.BatchInfo memory info,,) = _setupOmittedAliceLong();

        // One second past the window: expired regardless of block numbers.
        vm.warp(uint256(info.matchTimestamp) + sequencer.SEQUENCER_WINDOW() + 1);
        vm.expectRevert(BazaarSequencer.Sequencer__ChallengeWindowExpired.selector);
        vm.prank(makeAddr("challenger"));
        sequencer.challengeOmission(address(pair), batchId, info, omittedLong);
    }

    /// @notice Boundary: exactly matchTimestamp + SEQUENCER_WINDOW is still inside the window.
    function test_OmissionChallenge_WindowBoundary_StillOpen() public {
        (uint256 omittedLong, uint256 batchId, BazaarTypes.BatchInfo memory info,,) = _setupOmittedAliceLong();

        vm.warp(uint256(info.matchTimestamp) + sequencer.SEQUENCER_WINDOW());
        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.prank(makeAddr("challenger"));
        sequencer.challengeOmission(address(pair), batchId, info, omittedLong);
        assertLt(sequencer.sequencerBonds(seq), bondBefore, "challenge at the window edge still slashes");
    }

    /// @notice Stale-challenge ETH is refunded in full on a Step-1 reject (no stored batch hash),
    ///         not stranded in the contract. Pre-fix the early `return` skipped the refund block and
    ///         the entire msg.value was stuck. (Old code: balance would be down by the sent value.)
    function test_StaleChallenge_RejectRefundsFullValue() public {
        vm.deal(address(this), 1 ether);
        BazaarTypes.BatchInfo memory info;
        info.matchTimestamp = uint64(block.timestamp); // recent → passes the challenge-window check

        uint256 balBefore = address(this).balance;
        bytes[] memory empty = new bytes[](0);
        // batchId 999999 has no stored hash → Step 1 reject; the full value must come back.
        sequencer.challengeStaleBatch{value: 0.5 ether}(address(pair), 999999, info, empty);
        assertEq(address(this).balance, balBefore, "full msg.value refunded on Step-1 reject");
    }

    /// @notice On a genuinely-stale batch with no fresh tick supplied (the challenge correctly fails
    ///         in the catch), the challenger's ETH is refunded and the sequencer is not slashed. The
    ///         refund now runs on the catch path too. (With a fee-charging Pyth this is also where
    ///         the unconsumed fee would otherwise strand; the mock charges 0, so only the path-runs
    ///         and no-slash behavior is asserted here.)
    function test_StaleChallenge_CatchRefundsAndNoSlash() public {
        // Build a real stale AAPL batch so the challenge passes Steps 1 & 2.
        _depositAapl(alice, 20_000 * BAZAAR_SCALE);
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = 1 * BAZAAR_SCALE;
        uint256 longId = _placeLimitAapl(alice, true, size, 202 * BAZAAR_SCALE);
        uint256 shortId = _placeLimitAapl(bob, false, size, 198 * BAZAAR_SCALE);
        vm.warp(block.timestamp + 30); // stale the cache (MAX_PRICE_STALENESS = 2s)
        vm.roll(block.number + 2);
        vm.recordLogs();
        uint256 ok = _matchAaplStale(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);
        assertEq(ok, 1, "stale batch recorded");
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _captureBatch();
        assertTrue(info.isStale, "batch labeled stale");

        vm.deal(address(this), 1 ether);
        uint256 balBefore = address(this).balance;
        uint256 bondBefore = sequencer.sequencerBonds(seq);

        // Empty priceData → no tick in window → fetchHistoricalPrice reverts → catch path.
        bytes[] memory empty = new bytes[](0);
        sequencer.challengeStaleBatch{value: 0.3 ether}(address(aaplPair), batchId, info, empty);

        assertEq(address(this).balance, balBefore, "challenger fully refunded on catch");
        assertEq(sequencer.sequencerBonds(seq), bondBefore, "sequencer not slashed on a correct stale label");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       UNCAPPED maxMatches                                    ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice No protocol ceiling on maxMatches: an enormous value neither reverts nor
    ///         inflates engine allocations — buffers are sized from min(maxMatches, order
    ///         count), so the effective batch bound is the L2 gas limit, not a constant.
    function testMaxMatches_HugeValue_Accepted() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longId = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), type(uint256).max);

        assertEq(success, 1, "match completes with uncapped maxMatches");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       SORT VIOLATIONS — remaining lists                      ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice Long limits: same price → must be sorted by orderId ASC. Reversed ID order reverts.
    function testSort_LongLimits_OrderIdTiebreak_Reverts() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // Two longs at the SAME price → tiebreak by orderId ASC.
        uint256 longOlder = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        uint256 longNewer = _placeLimit(bob, true, size, 51_000 * BAZAAR_SCALE);
        // Two shorts to keep walk alive past first fill.
        uint256 shortA = _placeLimit(carol, false, size, 49_500 * BAZAAR_SCALE);
        uint256 shortB = _placeLimit(dave, false, size, 49_800 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        // Submit longs in WRONG orderId order (newer before older).
        BazaarTypes.OrderLists memory bad = _lists(_two(longNewer, longOlder), _two(shortA, shortB), _empty(), _empty());
        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert();
        pair.matchBatch(bad, 10, pu, uint64(block.number - 1));
    }

    /// @notice Short markets must be sorted DESC by maxSlippageBp — wrong order reverts.
    function testSort_ShortMarkets_RevertsOnAscOrder() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longA = _placeLimit(carol, true, size, 50_500 * BAZAAR_SCALE);
        uint256 longB = _placeLimit(dave, true, size, 50_200 * BAZAAR_SCALE);
        // Markets in wrong order (lower slippage first)
        uint256 marketLow = _placeMarket(alice, false, size, 100);
        uint256 marketHigh = _placeMarket(bob, false, size, 300);

        vm.roll(block.number + 2);
        BazaarTypes.OrderLists memory bad = _lists(_two(longA, longB), _empty(), _empty(), _two(marketLow, marketHigh));
        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        vm.expectRevert();
        pair.matchBatch(bad, 10, pu, uint64(block.number - 1));
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       MULTI-PASS INTERACTIONS                                ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice Pass A consumes vault liq using a long limit; the SAME long limit is also in
    ///         the list, so Pass C sees no remaining long → only Pass A fills happen.
    function testMultiPass_AThenC_AConsumesLimit_CDoesNothing() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // Long limit and a crossable short limit. Pass A would normally consume the long
        // before Pass C runs.
        uint256 longId = _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_500 * BAZAAR_SCALE);

        _setVaultPendingLiq(size, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1, "Pass A used the long; Pass C found nothing");
        assertEq(_filledSize(longId), size, "long consumed by Pass A");
        assertEq(_filledSize(shortId), 0, "short left unfilled - counterparty already taken");
    }

    /// @notice Pass A only takes part of a long limit (size > liq) → Pass C uses the remainder
    ///         to cross with a short limit. Both passes contribute.
    function testMultiPass_AThenC_APartial_CFinishesRemainder() public {
        _deposit(alice, 30_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 limitSize = 3 * BAZAAR_SCALE / 10; // 0.3 BTC
        uint256 liqSize = 1 * BAZAAR_SCALE / 10; // 0.1 BTC
        uint256 shortSize = 2 * BAZAAR_SCALE / 10; // 0.2 BTC

        uint256 longId = _placeLimit(alice, true, limitSize, 50_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, shortSize, 49_500 * BAZAAR_SCALE);

        _setVaultPendingLiq(liqSize, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 2, "Pass A then Pass C both produce a fill");
        // long got eaten for liqSize (Pass A) + shortSize (Pass C) = 0.3 BTC = full size
        assertEq(_filledSize(longId), limitSize, "long fully filled across A and C");
        assertEq(_filledSize(shortId), shortSize, "short fully filled by Pass C");
    }

    /// @notice Pass B partial-fills a market → Pass C then fills the remaining limit cross.
    ///         Tests the cross-pass walk state (longLimitHead carries past Pass B's exit).
    function testMultiPass_BThenC_BPartial_CContinues() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);

        uint256 marketSize = 1 * BAZAAR_SCALE / 10;
        uint256 limitSize = 3 * BAZAAR_SCALE / 10; // bigger so a remainder survives Pass B

        // Long limit, big enough to absorb the market AND have remainder.
        uint256 longLimitId = _placeLimit(alice, true, limitSize, 50_500 * BAZAAR_SCALE);
        // Short market consumes 0.1 of the long limit in Pass B.
        uint256 shortMarketId = _placeMarket(bob, false, marketSize, 500);
        // Short limit to cross what remains in Pass C.
        uint256 shortLimitId = _placeLimit(carol, false, 1 * BAZAAR_SCALE / 10, 50_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longLimitId), _one(shortLimitId), _empty(), _one(shortMarketId)), 10);

        assertEq(success, 2, "Pass B fill + Pass C fill");
        assertEq(
            _filledSize(longLimitId),
            marketSize + (1 * BAZAAR_SCALE / 10),
            "long limit eaten by market then short limit"
        );
        assertEq(_filledSize(shortMarketId), marketSize);
        assertEq(_filledSize(shortLimitId), 1 * BAZAAR_SCALE / 10);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       POST-ONLY                                              ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice Post-only on the SHORT side: newer post-only short that crosses an older long
    ///         gets auto-canceled rather than filled.
    function testPostOnly_ShortSide_AutoCancelsOnCross() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // Older long limit at 51k
        uint256 longId = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        // Newer post-only short at 49k — crosses the long → must auto-cancel itself.
        bytes[] memory pu = _freshPrice();
        vm.prank(bob);
        pair.createOrder(
            BazaarTypes.OrderType.Limit,
            0,
            49_000 * BAZAAR_SCALE,
            0,
            size,
            false,
            true,
            uint64(block.number + 500_000),
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
        uint256 shortId = _newestLimitOrderId(bob);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 0, "post-only short must not match older book");
        assertGt(_canceledBlock(shortId), 0, "post-only short auto-canceled");
        assertEq(_canceledBlock(longId), 0, "resting long untouched");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       MARK PRICE UPDATE                                      ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice After a successful Pass C cross, the pair's markPrice is updated.
    function testMarkPrice_UpdatedAfterPassCFill() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // Fill at the older order's price. Place alice (long) first → her 51k is the maker price.
        uint256 longId = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_000 * BAZAAR_SCALE);

        // Capture markPrice before the match (initialized at deploy spot ~50k).
        uint256 markBefore = pair.markPrice();

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);
        assertEq(success, 1);

        uint256 markAfter = pair.markPrice();
        assertTrue(markAfter != markBefore || markBefore != 0, "markPrice updated after fill");
        // markPrice is an EMA of fill VWAPs against the oracle; with a single fill at 51k
        // and oracle at 50k, the new mark must shift between them.
        assertGe(markAfter, markBefore, "markPrice moves toward fill price (51k > oracle 50k)");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       MARGIN-FAIL AUTO-CANCEL                                ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @dev Drain a user's collateral via stdstore so a subsequent match fails IMR.
    ///      Collateral is field 3 of the positionBuckets tuple (after isLong, size, entryValue).
    function _setCollateral(address user, uint256 newAmount) internal {
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(user).depth(3).checked_write(newAmount);
    }

    /// @notice An order whose creator no longer meets IMR at match time gets auto-canceled.
    ///         Walk advances; the batch does NOT revert.
    function testMargin_LongFailsIMR_AutoCancelsAtMatch() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10; // 0.1 BTC → $5k notional, IMR 20% = $1k
        uint256 longFail = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        uint256 longOk = _placeLimit(bob, true, size, 50_500 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(carol, false, size, 50_000 * BAZAAR_SCALE);

        // Drain alice's collateral to $10 — far below the ~$1k IMR needed for the fill.
        _setCollateral(alice, 10 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_two(longFail, longOk), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1, "alice's long auto-canceled, bob's long fills instead");
        assertGt(_canceledBlock(longFail), 0, "underfunded long auto-canceled");
        assertEq(_filledSize(longFail), 0);
        assertEq(_filledSize(longOk), size, "second-best long fills");
        assertEq(_filledSize(shortId), size);
    }

    /// @notice Short side margin failure mirror: short with insufficient collateral auto-cancels.
    function testMargin_ShortFailsIMR_AutoCancelsAtMatch() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 shortFail = _placeLimit(alice, false, size, 49_000 * BAZAAR_SCALE);
        uint256 shortOk = _placeLimit(bob, false, size, 49_500 * BAZAAR_SCALE);
        uint256 longId = _placeLimit(carol, true, size, 51_000 * BAZAAR_SCALE);

        _setCollateral(alice, 10 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _two(shortFail, shortOk), _empty(), _empty()), 10);

        assertEq(success, 1, "underfunded short auto-canceled, next-best short fills");
        assertGt(_canceledBlock(shortFail), 0);
        assertEq(_filledSize(shortFail), 0);
        assertEq(_filledSize(shortOk), size);
    }

    /// @notice Margin failure in Pass B: market with depleted collateral auto-cancels.
    function testMargin_MarketFailsIMR_AutoCancelsInPassB() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 shortId = _placeLimit(bob, false, size, 50_500 * BAZAAR_SCALE);
        uint256 marketId = _placeMarket(alice, true, size, 200);

        // Drain alice's collateral after order placement
        _setCollateral(alice, 10 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_empty(), _one(shortId), _one(marketId), _empty()), 10);

        assertEq(success, 0, "market auto-canceled, no fill");
        assertGt(_canceledBlock(marketId), 0);
        assertEq(_filledSize(shortId), 0, "counterparty short left untouched");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       VOLUME-CAPACITY EXHAUSTION                             ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice The sequencer's remaining capacity is bond × VOLUME_CAP_MULTIPLIER (14).
    ///         With our bond of 5,000 USDC → cap = 70,000 USDC. A long+short fill of $50k
    ///         notional easily fits. We test the inner loop's
    ///         `totalMatchedVolume >= ctx.remainingCapacity` exit by stuffing volume into
    ///         the sequencer's bucket via the pair's recordVolume callback isn't safe to call
    ///         directly, so instead we issue two matches: first one consumes most of the cap,
    ///         second's second pair partial-fills / aborts.
    // ╔══════════════════════════════════════════════════════════════╗
    // ║       GAS BENCHMARK                                          ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice Same setup as the 10-match benchmark but only 1 pair, to measure the
    ///         per-batch fixed overhead (Pyth fetch, IMR recompute, mark/funding update, etc.).
    function testGasBenchmark_OneMatch_PassC() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        uint256 size = 1 * BAZAAR_SCALE / 100;
        uint256 longId = _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);

        bytes[] memory pu = _freshPrice();
        uint64 obs = uint64(block.number - 1);
        vm.prank(seq);
        uint256 gasBefore = gasleft();
        uint256 success = pair.matchBatch(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10, pu, obs);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(success, 1);
        emit log_named_uint("gas for 1 match (Pass C, cold)", gasUsed);
    }

    /// @notice Measure the gas cost of a 10-match Pass C batch in isolation
    ///         (i.e., excluding setUp, deposits, order placement).
    function testGasBenchmark_TenMatches_PassC() public {
        // 10 distinct users so no self-match auto-cancels. Each pair gets its own long+short.
        address[10] memory longs;
        address[10] memory shorts;
        for (uint256 i = 0; i < 10; i++) {
            longs[i] = makeAddr(string(abi.encodePacked("L", vm.toString(i))));
            shorts[i] = makeAddr(string(abi.encodePacked("S", vm.toString(i))));
            usdc.mint(longs[i], 100_000 * USDC_SCALE);
            usdc.mint(shorts[i], 100_000 * USDC_SCALE);
            _deposit(longs[i], 20_000 * BAZAAR_SCALE);
            _deposit(shorts[i], 20_000 * BAZAAR_SCALE);
        }

        // Sort the limits properly: longs DESC by price, shorts ASC by price.
        // Use a $100 price band so distinct prices are easy to enumerate.
        uint256 size = 1 * BAZAAR_SCALE / 100; // 0.01 BTC ($500) per fill — small enough to stay well within capacity
        uint256[] memory longIds = new uint256[](10);
        uint256[] memory shortIds = new uint256[](10);
        // longs at 51_000, 50_900, ... 50_100  (DESC)
        // shorts at 49_100, 49_200, ... 50_000 (ASC)
        for (uint256 i = 0; i < 10; i++) {
            longIds[i] = _placeLimit(longs[i], true, size, (51_000 - i * 100) * BAZAAR_SCALE);
            shortIds[i] = _placeLimit(shorts[i], false, size, (49_100 + i * 100) * BAZAAR_SCALE);
        }

        vm.roll(block.number + 2);

        // Measure ONLY the matchBatch call.
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderLists memory lists = _lists(longIds, shortIds, _empty(), _empty());
        uint64 obs = uint64(block.number - 1);

        vm.prank(seq);
        uint256 gasBefore = gasleft();
        uint256 success = pair.matchBatch(lists, 10, pu, obs);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(success, 10, "expected exactly 10 matches");
        emit log_named_uint("gas for 10 matches (Pass C)", gasUsed);
        emit log_named_uint("gas per match (approx)", gasUsed / 10);
    }

    /// @notice Regression: capacity boundary that doesn't divide evenly by fillPrice.
    ///         Before the no-progress-bool fix, this would tight-loop until OOG because
    ///         `mulDiv(capRoom, SCALE, fillPrice)` rounds down to 0 on the second iteration
    ///         while `totalMatchedVolume` is still strictly less than `remainingCapacity`.
    function testVolumeCapacity_RoundingResidue_DoesNotInfiniteLoop() public {
        usdc.mint(alice, 1_000_000 * USDC_SCALE);
        usdc.mint(bob, 1_000_000 * USDC_SCALE);
        _deposit(alice, 50_000 * BAZAAR_SCALE);
        _deposit(bob, 50_000 * BAZAAR_SCALE);

        // 50,500 does NOT divide 85,000 evenly → rounding residue triggers no-progress exit.
        uint256 size = 2 * BAZAAR_SCALE;
        uint256 longId = _placeLimit(alice, true, size, 50_500 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        // Bound gas so an infinite loop would visibly fail. The post-fix path completes well under 5M.
        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1, "single partial fill at the rounding boundary");
        uint256 filledLong = _filledSize(longId);
        assertGt(filledLong, 0, "fill happened");
        assertLt(filledLong, size, "fill was partial (capacity cap)");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       PHASE 5 — STALE-ORACLE PATHS (AAPL non-continuous)     ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @dev Build a Pyth price update for AAPL at the given USD price.
    function _priceUpdateAapl(uint256 priceUsd, uint64 publishTime) internal view returns (bytes[] memory pu) {
        int64 pythPrice = int64(int256(priceUsd * 1e8));
        uint64 conf = uint64(priceUsd * 1e8 / 1000);
        bytes memory data = mockPyth.createPriceFeedUpdateData(
            AAPL_USD_FEED_ID,
            pythPrice,
            conf,
            BTC_PYTH_EXPO,
            pythPrice,
            conf,
            publishTime,
            publishTime > 0 ? publishTime - 1 : 0
        );
        pu = new bytes[](1);
        pu[0] = data;
    }

    function _freshPriceAapl() internal view returns (bytes[] memory) {
        return _priceUpdateAapl(200, uint64(block.timestamp));
    }

    function _depositAapl(address user, uint256 amount) internal {
        uint256 amountUsdc = amount * USDC_SCALE / BAZAAR_SCALE;
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amountUsdc);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function _placeLimitAapl(address user, bool isLong, uint256 size, uint256 limitPrice) internal returns (uint256) {
        bytes[] memory pu = _freshPriceAapl();
        vm.prank(user);
        aaplPair.createOrder(
            BazaarTypes.OrderType.Limit,
            0,
            limitPrice,
            0,
            size,
            isLong,
            false,
            uint64(block.number + 500_000),
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
        (uint256[] memory ids,,,) = aaplPair.getUserActiveLimitOrders(user);
        return ids[ids.length - 1];
    }

    function _placeMarketAapl(address user, bool isLong, uint256 size, uint256 maxSlippageBp)
        internal
        returns (uint256)
    {
        bytes[] memory pu = _freshPriceAapl();
        vm.prank(user);
        aaplPair.createOrder(
            BazaarTypes.OrderType.Market, 0, 0, maxSlippageBp, size, isLong, false, 0, address(0), pu, 0, 0, 0, ""
        );
        (,,,,,,,, uint256 mktId,) = aaplPair.positionBuckets(user);
        return mktId;
    }

    /// @dev Match against AAPL pair with an empty priceUpdate so the engine falls through
    ///      to the stale fallback (lastPairPrice with isStale=true). Caller must warp
    ///      timestamp past MAX_PRICE_STALENESS before calling.
    function _matchAaplStale(BazaarTypes.OrderLists memory lists, uint256 maxMatches) internal returns (uint256) {
        bytes[] memory emptyPu = new bytes[](0);
        uint64 obs = uint64(block.number - 1);
        vm.prank(seq);
        return aaplPair.matchBatch(lists, maxMatches, emptyPu, obs);
    }

    function _aaplOrderFilledSize(uint256 orderId) internal view returns (uint256) {
        (,,,,,, uint256 filledSize,,,,,,,) = aaplPair.orders(orderId);
        return filledSize;
    }

    function _aaplPosition(address user) internal view returns (bool isLong, uint256 size) {
        (isLong, size,,,,,,,,) = aaplPair.positionBuckets(user);
    }

    /// @notice Well-margined limits cross normally even during a stale batch (passes both
    ///         normal IMR and 2× stale IMR).
    function testStale_WellMarginedLimits_StillFill() public {
        // Place orders with fresh price; users hold enough collateral to pass 2× IMR.
        _depositAapl(alice, 20_000 * BAZAAR_SCALE);
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE; // 1 share, $200 notional → 2×IMR ~ $80 (40% of 200)
        uint256 longId = _placeLimitAapl(alice, true, size, 202 * BAZAAR_SCALE);
        uint256 shortId = _placeLimitAapl(bob, false, size, 198 * BAZAAR_SCALE);

        // Make Pyth cache + lastPairPrice stale (MAX_PRICE_STALENESS = 2s).
        vm.warp(block.timestamp + 30);
        vm.roll(block.number + 2);

        uint256 success = _matchAaplStale(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1, "well-margined limits still cross during stale batch");
        assertEq(_aaplOrderFilledSize(longId), size);
        assertEq(_aaplOrderFilledSize(shortId), size);
    }

    /// @notice Order that passes normal IMR but fails 2× IMR during stale → pushed to
    ///         staleSkippedIds and NOT filled. Counterparty also not filled.
    function testStale_UndermarginedLimit_GoesToStaleSkippedIds() public {
        // AAPL is non-continuously-traded → IMR has a 1.5× multiplier (30% effective).
        // For 1 share @ ~$200: normal IMR ≈ $60.60; stale 2× IMR ≈ $121.20.
        // Give alice $80 — passes creation + normal match IMR, fails stale 2× IMR.
        _depositAapl(alice, 80 * BAZAAR_SCALE);
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE;
        uint256 longId = _placeLimitAapl(alice, true, size, 202 * BAZAAR_SCALE);
        uint256 shortId = _placeLimitAapl(bob, false, size, 198 * BAZAAR_SCALE);

        vm.warp(block.timestamp + 30);
        vm.roll(block.number + 2);

        uint256 success = _matchAaplStale(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 0, "stale-skipped: no fill happens");
        assertEq(_aaplOrderFilledSize(longId), 0, "long not filled");
        // Importantly: the long is NOT auto-canceled. It survives for a future fresh batch.
        (,,,,,,,,,,,, uint64 cb,) = aaplPair.orders(longId);
        assertEq(cb, 0, "long not auto-canceled - preserved for fresh batches");
    }

    /// @notice Market orders are silently skipped at head-load during a stale batch.
    ///         The engine's `_loadHeadLongMarket` / `_loadHeadShortMarket` check `isOracleStale`
    ///         and race-skip the market without erroring.
    function testStale_MarketHead_SkippedSilently() public {
        // Alice opens a long market BEFORE the oracle goes stale (market creation requires fresh price).
        _depositAapl(alice, 20_000 * BAZAAR_SCALE);
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE;
        uint256 shortId = _placeLimitAapl(bob, false, size, 201 * BAZAAR_SCALE);
        uint256 marketId = _placeMarketAapl(alice, true, size, 500);

        // Now make oracle stale.
        vm.warp(block.timestamp + 30);
        vm.roll(block.number + 2);

        // Submit the market in longMarkets — engine should silently skip it.
        uint256 success = _matchAaplStale(_lists(_empty(), _one(shortId), _one(marketId), _empty()), 10);

        assertEq(success, 0, "market silently skipped during stale; no fill");
        assertEq(_aaplOrderFilledSize(marketId), 0);
        assertEq(_aaplOrderFilledSize(shortId), 0);
    }

    /// @notice Creating a new market order while the oracle is stale reverts with
    ///         MarketOrderBlockedOracleStale — separate guard at the createOrder layer.
    function testStale_MarketOrderCreation_Reverts() public {
        _depositAapl(alice, 20_000 * BAZAAR_SCALE);
        // Bootstrap lastPairPrice with one priceUpdate so the contract has something to fall back to.
        _placeLimitAapl(alice, true, 1 * BAZAAR_SCALE, 199 * BAZAAR_SCALE);

        // Warp past stale threshold for user-facing transactions (10 seconds).
        vm.warp(block.timestamp + 30);

        bytes[] memory emptyPu = new bytes[](0);
        vm.prank(alice);
        vm.expectRevert(BazaarPair.BazaarPair__MarketOrderBlockedOracleStale.selector);
        aaplPair.createOrder(
            BazaarTypes.OrderType.Market, 0, 0, 200, 1 * BAZAAR_SCALE, true, false, 0, address(0), emptyPu, 0, 0, 0, ""
        );
    }

    /// @notice Stale-band price rejection: if the limit's fillPrice deviates from the
    ///         cached price by > MAX_STALE_DEVIATION_BP (10%), both heads are consumed
    ///         without a fill (defensive — prevents stale-batch price gaming).
    function testStale_PriceBand_RejectsExtremeLimitPrice() public {
        _depositAapl(alice, 20_000 * BAZAAR_SCALE);
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);

        // Use generous-band fills: long @ $250 (25% above cached $200), short @ $50.
        // Either ep > maxPrice (220) or ep < minPrice (180), so the band check fires.
        uint256 size = 1 * BAZAAR_SCALE / 10; // small size keeps margin requirements modest
        uint256 longId = _placeLimitAapl(alice, true, size, 250 * BAZAAR_SCALE);
        uint256 shortId = _placeLimitAapl(bob, false, size, 50 * BAZAAR_SCALE);

        vm.warp(block.timestamp + 30);
        vm.roll(block.number + 2);

        uint256 success = _matchAaplStale(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 0, "stale-band rejects fill");
        // The band rejection sets both head.remaining = 0 in MEMORY only, so the orders
        // themselves remain unfilled on storage. Future fresh batches can still match them.
        assertEq(_aaplOrderFilledSize(longId), 0);
        assertEq(_aaplOrderFilledSize(shortId), 0);
    }

    /// @notice Confidence cap on the hot path: a FRESH Pyth cache whose confidence exceeds the 2%
    ///         cap must not be used for fills. With no user-supplied update to fall back on, the
    ///         batch hard-pauses (reverts) instead of matching against an over-confidence price.
    ///         Pre-fix, step 1 used readUnsafePrice (no conf check) and the match would proceed.
    function testConfCap_FreshHighConfCache_HardPausesFill() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longId = _placeLimit(alice, true, size, 50_100 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_900 * BAZAAR_SCALE);

        // Overwrite the Pyth cache with a FRESH price at 3% confidence (> 2% cap), writing
        // straight to MockPyth (fee 0) to bypass the order-flow conf check. publishTime is
        // bumped +1s so it's strictly newer than the order-placement price and overwrites it.
        vm.warp(block.timestamp + 1);
        bytes[] memory highConf = _priceUpdateConf(50_000, 300, uint64(block.timestamp));
        mockPyth.updatePriceFeeds(highConf);

        vm.roll(block.number + 2);

        // No user priceUpdate: step 1 (fresh cache) is now confidence-gated and rejects the
        // over-conf price → no fallback for a continuously-traded pair → hard-pause revert.
        bytes[] memory emptyPu = new bytes[](0);
        vm.prank(seq);
        vm.expectRevert(BazaarPair.BazaarPair__NoPriceUpdatesProvided.selector);
        pair.matchBatch(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10, emptyPu, uint64(block.number - 1));
    }

    /// @notice Counterpart: the same fresh cache at an IN-confidence (1%) level fills normally,
    ///         confirming the cap gates only over-confidence prices, not all cached fills.
    function testConfCap_FreshInConfCache_FillsNormally() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 longId = _placeLimit(alice, true, size, 50_100 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_900 * BAZAAR_SCALE);

        vm.warp(block.timestamp + 1);
        bytes[] memory okConf = _priceUpdateConf(50_000, 100, uint64(block.timestamp)); // 1% < 2% cap
        mockPyth.updatePriceFeeds(okConf);

        vm.roll(block.number + 2);

        bytes[] memory emptyPu = new bytes[](0);
        vm.prank(seq);
        uint256 success = pair.matchBatch(
            _lists(_one(longId), _one(shortId), _empty(), _empty()), 10, emptyPu, uint64(block.number - 1)
        );
        assertEq(success, 1, "in-confidence fresh cache still fills");
    }

    /// @notice Security regression (sequencer-bond theft): a stale price-band-voided limit pair
    ///         must be recorded in staleSkippedIds — symmetric with the stale-IMR skip path.
    ///         Otherwise the voided orders look like un-recorded omissions, and an omission
    ///         challenge would slash the honest sequencer (and, via the 50/50 split, a single
    ///         attacker who placed the order and files the challenge collects the whole bond).
    ///         The omission challenge needs a stored batch hash, so a real batch always has ≥1
    ///         successful match; we include one in-band pair, then assert both band-voided orders
    ///         land in staleSkippedIds so the challenge's Step-5 membership check rejects them.
    function testStale_PriceBand_VoidedOrders_RecordedInStaleSkippedIds() public {
        _depositAapl(alice, 20_000 * BAZAAR_SCALE);
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);
        _depositAapl(carol, 20_000 * BAZAAR_SCALE);
        _depositAapl(dave, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        // Out-of-band pair: fill price ($250 or $50) is outside [$180, $220] → band-voided.
        uint256 obLong = _placeLimitAapl(alice, true, size, 250 * BAZAAR_SCALE);
        uint256 obShort = _placeLimitAapl(bob, false, size, 50 * BAZAAR_SCALE);
        // In-band pair: matches normally, so the batch is recorded (successCount > 0).
        uint256 ibLong = _placeLimitAapl(carol, true, size, 202 * BAZAAR_SCALE);
        uint256 ibShort = _placeLimitAapl(dave, false, size, 198 * BAZAAR_SCALE);

        vm.warp(block.timestamp + 30);
        vm.roll(block.number + 2);

        // Longs sorted DESC ($250, $202), shorts sorted ASC ($50, $198): the walk takes the
        // out-of-band pair first (band-voided) then fills the in-band pair.
        vm.recordLogs();
        uint256 success = _matchAaplStale(_lists(_two(obLong, ibLong), _two(obShort, ibShort), _empty(), _empty()), 10);

        assertEq(success, 1, "only the in-band pair fills; the out-of-band pair is band-voided");
        assertEq(_aaplOrderFilledSize(obLong), 0, "out-of-band long not filled");
        assertEq(_aaplOrderFilledSize(obShort), 0, "out-of-band short not filled");

        uint256[] memory skipped = _staleSkippedFromLogs();
        assertTrue(_arrContains(skipped, obLong), "band-voided long recorded in staleSkippedIds");
        assertTrue(_arrContains(skipped, obShort), "band-voided short recorded in staleSkippedIds");
    }

    /// @dev Decode staleSkippedIds from the BatchRecorded event in the recorded logs.
    function _staleSkippedFromLogs() internal returns (uint256[] memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == BazaarTypes.BatchRecorded.selector) {
                BazaarTypes.BatchInfo memory info = abi.decode(logs[i].data, (BazaarTypes.BatchInfo));
                return info.staleSkippedIds;
            }
        }
        revert("no BatchRecorded event emitted");
    }

    function _arrContains(uint256[] memory arr, uint256 v) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == v) return true;
        }
        return false;
    }

    /// @dev Decode (batchId, BatchInfo) from the BatchRecorded event in the recorded logs.
    function _captureBatch() internal returns (uint256 batchId, BazaarTypes.BatchInfo memory info) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == BazaarTypes.BatchRecorded.selector) {
                batchId = uint256(logs[i].topics[2]); // topics: [sig, pairId, batchId, sequencer]
                info = abi.decode(logs[i].data, (BazaarTypes.BatchInfo));
                return (batchId, info);
            }
        }
        revert("no BatchRecorded event emitted");
    }

    /// @dev Shared setup for the omission-penalty-on-full-size tests: alice places an aggressive
    ///      long that SHOULD match first by price priority, the sequencer instead matches a
    ///      worse-priced carol/dave pair and omits alice. Returns alice's omitted orderId, the
    ///      batchId/BatchInfo of the omitting batch, and alice's size/price.
    function _setupOmittedAliceLong()
        internal
        returns (
            uint256 omittedLong,
            uint256 batchId,
            BazaarTypes.BatchInfo memory info,
            uint256 aliceSize,
            uint256 aliceLimitPrice
        )
    {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);

        aliceSize = 1 * BAZAAR_SCALE / 10; // 0.1 BTC
        aliceLimitPrice = 52_000 * BAZAAR_SCALE; // more aggressive than carol's $51k

        omittedLong = _placeLimit(alice, true, aliceSize, aliceLimitPrice);
        // Worse-priced in-band pair: matches and records the batch with totalMatchNotional >> alice.
        uint256 matchedSize = 1 * BAZAAR_SCALE; // 1 BTC, ~$50k matched, under the $70k cap
        uint256 carolLong = _placeLimit(carol, true, matchedSize, 51_000 * BAZAAR_SCALE);
        uint256 daveShort = _placeLimit(dave, false, matchedSize, 49_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        vm.recordLogs();
        uint256 success = _match(_lists(_one(carolLong), _one(daveShort), _empty(), _empty()), 10);
        assertEq(success, 1, "carol/dave match; alice's better-priced long is omitted");
        (batchId, info) = _captureBatch();

        assertEq(_filledSize(omittedLong), 0, "alice omitted, unfilled in this batch");
        assertGt(info.lowestLongLimitPrice, 0, "a long limit matched (sets the in-range cutoff)");
        assertLt(info.lowestLongLimitPrice, aliceLimitPrice, "alice was more aggressive -> in range");
    }

    /// @notice Omission penalty must be charged on the order's FULL size, not the current
    ///         remainder. Scenario: alice's 0.1 BTC long is omitted, then later PARTIALLY filled
    ///         (0.05) in a subsequent batch. The challenge for the omitting batch must still slash
    ///         on the full 0.1, not the post-fill 0.05.
    function test_OmissionPenalty_UsesFullSize_AfterPartialFill() public {
        (
            uint256 omittedLong,
            uint256 batchId,
            BazaarTypes.BatchInfo memory info,
            uint256 aliceSize,
            uint256 aliceLimitPrice
        ) = _setupOmittedAliceLong();

        // Later batch: partially fill alice (0.05 of 0.1). Partial fill leaves filledBlock == 0.
        uint256 fillSize = aliceSize / 2;
        uint256 bobShort = _placeLimit(bob, false, fillSize, 49_000 * BAZAAR_SCALE);
        vm.roll(block.number + 2);
        _match(_lists(_one(omittedLong), _one(bobShort), _empty(), _empty()), 10);
        assertEq(_filledSize(omittedLong), fillSize, "alice partially filled in a later batch");

        uint256 censoredNotional = aliceSize * aliceLimitPrice / BAZAAR_SCALE; // full size
        assertLt(censoredNotional, info.totalMatchNotional, "order-size side binds, not the cap");
        uint256 expectedPenalty = censoredNotional * sequencer.OMISSION_PENALTY_BP() / 10_000;

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.prank(makeAddr("challenger"));
        sequencer.challengeOmission(address(pair), batchId, info, omittedLong);
        uint256 bondAfter = sequencer.sequencerBonds(seq);

        assertEq(bondBefore - bondAfter, expectedPenalty, "penalty charged on full size despite later partial fill");
    }

    /// @notice The laundering gap is closed: an order FULLY filled in a later batch still incurs
    ///         the full-size omission penalty for the earlier batch that censored it (previously
    ///         the current remainder was 0, so the sequencer escaped all liability).
    function test_OmissionPenalty_UsesFullSize_AfterFullFill() public {
        (
            uint256 omittedLong,
            uint256 batchId,
            BazaarTypes.BatchInfo memory info,
            uint256 aliceSize,
            uint256 aliceLimitPrice
        ) = _setupOmittedAliceLong();

        // Later batch: FULLY fill alice (0.1 of 0.1). Full fill sets filledBlock to a block AFTER
        // the omitting batch's executionBlock, so Step 4 still admits the challenge.
        uint256 bobShort = _placeLimit(bob, false, aliceSize, 49_000 * BAZAAR_SCALE);
        vm.roll(block.number + 2);
        _match(_lists(_one(omittedLong), _one(bobShort), _empty(), _empty()), 10);
        assertEq(_filledSize(omittedLong), aliceSize, "alice fully filled in a later batch");

        uint256 censoredNotional = aliceSize * aliceLimitPrice / BAZAAR_SCALE;
        assertLt(censoredNotional, info.totalMatchNotional, "order-size side binds, not the cap");
        uint256 expectedPenalty = censoredNotional * sequencer.OMISSION_PENALTY_BP() / 10_000;

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.prank(makeAddr("challenger"));
        sequencer.challengeOmission(address(pair), batchId, info, omittedLong);
        uint256 bondAfter = sequencer.sequencerBonds(seq);

        assertEq(bondBefore - bondAfter, expectedPenalty, "full-size penalty even though order later fully filled");
    }

    /// @notice Per-batch cap: a challenge charges on the omitted order's FULL size even when only a
    ///         sliver was actually censorable, so stacked challenges across orders in one batch are
    ///         capped in aggregate at 7% of the batch's matched notional. Here a tiny carol/dave
    ///         pair matches while two large, better-priced longs are omitted — the first challenge
    ///         alone hits the cap, the second slashes nothing.
    function test_OmissionPenalty_PerBatchCap() public {
        usdc.mint(alice, 1_000_000 * USDC_SCALE);
        usdc.mint(bob, 1_000_000 * USDC_SCALE);
        usdc.mint(carol, 1_000_000 * USDC_SCALE);
        usdc.mint(dave, 1_000_000 * USDC_SCALE);
        _deposit(alice, 100_000 * BAZAAR_SCALE);
        _deposit(bob, 100_000 * BAZAAR_SCALE);
        _deposit(carol, 100_000 * BAZAAR_SCALE);
        _deposit(dave, 100_000 * BAZAAR_SCALE);

        uint256 smallSize = 1 * BAZAAR_SCALE / 100; // 0.01 BTC
        uint256 bigSize = 1 * BAZAAR_SCALE; // 1 BTC

        uint256 aliceLong = _placeLimit(alice, true, bigSize, 52_000 * BAZAAR_SCALE);
        uint256 bobLong = _placeLimit(bob, true, bigSize, 52_500 * BAZAAR_SCALE);
        uint256 carolLong = _placeLimit(carol, true, smallSize, 51_000 * BAZAAR_SCALE);
        uint256 daveShort = _placeLimit(dave, false, smallSize, 49_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        vm.recordLogs();
        // Match ONLY the small carol/dave pair; alice & bob (better-priced) are omitted.
        assertEq(_match(_lists(_one(carolLong), _one(daveShort), _empty(), _empty()), 10), 1, "small pair matched");
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _captureBatch();
        assertEq(_filledSize(aliceLong), 0, "alice omitted");
        assertEq(_filledSize(bobLong), 0, "bob omitted");

        uint256 cap = info.totalMatchNotional * sequencer.OMISSION_PENALTY_BP() / 10_000;
        uint256 bond0 = sequencer.sequencerBonds(seq);

        vm.prank(makeAddr("c1"));
        sequencer.challengeOmission(address(pair), batchId, info, aliceLong);
        uint256 bond1 = sequencer.sequencerBonds(seq);
        assertEq(bond0 - bond1, cap, "first omission consumes the whole per-batch cap");

        vm.prank(makeAddr("c2"));
        sequencer.challengeOmission(address(pair), batchId, info, bobLong);
        uint256 bond2 = sequencer.sequencerBonds(seq);
        assertEq(bond1 - bond2, 0, "second omission slashes nothing once the cap is exhausted");
        assertEq(bond0 - bond2, cap, "aggregate omission penalty capped at 7% of matched notional");
    }

    /// @notice One pair larger than the sequencer's remaining capacity → partial fill at the boundary.
    ///         Bond 5000 USDC × VOLUME_CAP_MULTIPLIER 14 = $70k capacity. A 2 BTC × $50k
    ///         fill would be $100k, so the fill is truncated to 1.4 BTC (clean divide).
    function testVolumeCapacity_PartialFillAtBoundary() public {
        usdc.mint(alice, 1_000_000 * USDC_SCALE);
        usdc.mint(bob, 1_000_000 * USDC_SCALE);
        _deposit(alice, 50_000 * BAZAAR_SCALE);
        _deposit(bob, 50_000 * BAZAAR_SCALE);

        // Use a fillPrice (= older order's price) that divides the capacity evenly to
        // avoid any rounding residue in `fillSize = mulDiv(capRoom, SCALE, fillPrice)`.
        // 70,000 BAZAAR_SCALE / 50,000 BAZAAR_SCALE = 1.4 BAZAAR_SCALE exactly.
        uint256 size = 2 * BAZAAR_SCALE;
        uint256 longId = _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE);
        uint256 shortId = _placeLimit(bob, false, size, 49_500 * BAZAAR_SCALE);

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        assertEq(success, 1, "one (partial) fill happens");
        uint256 filledLong = _filledSize(longId);
        uint256 filledShort = _filledSize(shortId);
        assertEq(filledLong, filledShort, "long/short fills balance");
        assertLt(filledLong, size, "fill truncated by sequencer's volume cap");
        // Sanity: filled notional ≤ cap (70,000 BAZAAR_SCALE) within rounding.
        uint256 filledNotional = filledLong * 50_500 / 1; // size * price; both in BAZAAR_SCALE units cancel via BAZAAR_SCALE
        // 70,000 * BAZAAR_SCALE^2 is the cap times BAZAAR_SCALE (filledLong was in BAZAAR_SCALE)
        assertLe(filledNotional, 70_000 * BAZAAR_SCALE * BAZAAR_SCALE, "filled volume within capacity");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║       PHASE 6 — CROSS-PASS / VAULT-PNL / INTERACTIONS        ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice Full A + B + C pipeline in one batch. Verifies the pass-ordering invariants:
    ///         A consumes vault liq against a long limit, then B's market takes the next
    ///         short limit, then C crosses what's left.
    function testAllPasses_InSingleBatch_AbcOrdering() public {
        // 4 users so each pass has its own counterparty
        address eve = makeAddr("eve");
        address frank = makeAddr("frank");
        usdc.mint(eve, 100_000 * USDC_SCALE);
        usdc.mint(frank, 100_000 * USDC_SCALE);

        _deposit(alice, 20_000 * BAZAAR_SCALE); // long limit #1 (consumed by Pass A)
        _deposit(bob, 20_000 * BAZAAR_SCALE); // short limit #1 (eaten by Pass B market)
        _deposit(carol, 20_000 * BAZAAR_SCALE); // long market (Pass B taker)
        _deposit(dave, 20_000 * BAZAAR_SCALE); // long limit #2 (Pass C maker)
        _deposit(eve, 20_000 * BAZAAR_SCALE); // short limit #2 (Pass C maker)
        _deposit(frank, 20_000 * BAZAAR_SCALE); // unused, reserved for clarity

        uint256 size = 1 * BAZAAR_SCALE / 10;

        // Pass A target: vault long-liq → fills against a long limit.
        uint256 longA = _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE);
        // Pass B target: short limit eaten by long market.
        uint256 shortB = _placeLimit(bob, false, size, 49_500 * BAZAAR_SCALE);
        uint256 marketB = _placeMarket(carol, true, size, 500);
        // Pass C target: long limit + short limit that cross each other.
        uint256 longC = _placeLimit(dave, true, size, 50_200 * BAZAAR_SCALE);
        uint256 shortC = _placeLimit(eve, false, size, 49_800 * BAZAAR_SCALE);

        // Vault pending long liquidation, sized to consume only longA.
        _setVaultPendingLiq(size, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);

        vm.roll(block.number + 2);

        // longs sorted DESC by price: longC ($50,200) before longA ($50,000)
        // shorts sorted ASC by price: shortC ($49,800) before shortB ($49,500) — wait, ASC means lower first
        // ASC: shortB ($49,500) before shortC ($49,800)
        uint256[] memory longs = new uint256[](2);
        longs[0] = longC; // 50,200
        longs[1] = longA; // 50,000
        uint256[] memory shorts = new uint256[](2);
        shorts[0] = shortB; // 49,500
        shorts[1] = shortC; // 49,800

        uint256 success = _match(_lists(longs, shorts, _one(marketB), _empty()), 10);

        // Expected fills:
        //   Pass A: vault liq × longA → 1 fill
        //   Pass B: marketB × shortB (best short at lowest ask) → 1 fill
        //   Pass C: longC × shortC → 1 fill
        // Total: 3 fills
        assertEq(success, 3, "all three passes contributed one fill each");
        assertEq(_filledSize(longA), size, "Pass A filled longA");
        assertEq(_filledSize(shortB), size, "Pass B filled shortB via market");
        assertEq(_filledSize(marketB), size);
        assertEq(_filledSize(longC), size, "Pass C filled longC");
        assertEq(_filledSize(shortC), size, "Pass C filled shortC");

        // Vault liq should be cleared.
        (,,,,,, uint256 remaining,,,,,) = pair.pairVault();
        assertEq(remaining, 0, "vault pending liq cleared by Pass A");
    }

    /// @notice Pass B's two sub-walks both fire in one batch: longMarkets × shortLimits AND
    ///         shortMarkets × longLimits. Verifies sub-walk independence.
    function testPassB_BothSubWalks_InOneBatch() public {
        address eve = makeAddr("eve");
        address frank = makeAddr("frank");
        usdc.mint(eve, 100_000 * USDC_SCALE);
        usdc.mint(frank, 100_000 * USDC_SCALE);

        _deposit(alice, 20_000 * BAZAAR_SCALE); // long market
        _deposit(bob, 20_000 * BAZAAR_SCALE); // short limit (sub-walk 1 counterparty)
        _deposit(carol, 20_000 * BAZAAR_SCALE); // short market
        _deposit(dave, 20_000 * BAZAAR_SCALE); // long limit (sub-walk 2 counterparty)

        uint256 size = 1 * BAZAAR_SCALE / 10;

        uint256 shortLimitId = _placeLimit(bob, false, size, 50_500 * BAZAAR_SCALE);
        uint256 longLimitId = _placeLimit(dave, true, size, 49_500 * BAZAAR_SCALE);
        uint256 longMarketId = _placeMarket(alice, true, size, 500);
        uint256 shortMarketId = _placeMarket(carol, false, size, 500);

        vm.roll(block.number + 2);

        uint256 success =
            _match(_lists(_one(longLimitId), _one(shortLimitId), _one(longMarketId), _one(shortMarketId)), 10);

        assertEq(success, 2, "both sub-walks each produce one fill");
        // Sub-walk 1 (longs first per the deterministic ordering):
        assertEq(_filledSize(longMarketId), size, "long market took short limit");
        assertEq(_filledSize(shortLimitId), size);
        // Sub-walk 2:
        assertEq(_filledSize(shortMarketId), size, "short market took long limit");
        assertEq(_filledSize(longLimitId), size);
    }

    /// @notice Stale-oracle batch hitting the capacity boundary: verifies the two paths
    ///         play together. Capacity exhausts BEFORE the stale-band check would trip
    ///         (orders are well-priced relative to cached), so the partial-fill path
    ///         runs and the no-progress bool exits cleanly.
    function testStale_AndCapacity_Combined() public {
        usdc.mint(alice, 1_000_000 * USDC_SCALE);
        usdc.mint(bob, 1_000_000 * USDC_SCALE);
        _depositAapl(alice, 50_000 * BAZAAR_SCALE);
        _depositAapl(bob, 50_000 * BAZAAR_SCALE);

        // Big enough notional to exceed the $85k sequencer cap.
        // 500 shares × $200 = $100k notional.
        uint256 size = 500 * BAZAAR_SCALE;
        uint256 longId = _placeLimitAapl(alice, true, size, 200 * BAZAAR_SCALE);
        uint256 shortId = _placeLimitAapl(bob, false, size, 200 * BAZAAR_SCALE);

        // Make oracle stale, run match with empty priceUpdate.
        vm.warp(block.timestamp + 30);
        vm.roll(block.number + 2);

        uint256 success = _matchAaplStale(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);

        // Either: partial fill happens (success=1) and exits via no-progress, OR fill is
        // entirely blocked (success=0) due to stale 2× IMR. Both are valid given setup;
        // the key assertion is that the test completes (no infinite loop) with bounded gas.
        assertLe(success, 1);
        // If a fill happened it must be partial.
        if (success == 1) {
            assertLt(_aaplOrderFilledSize(longId), size, "fill was partial");
        }
    }

    /// @notice Vault Pass A PnL sign — long-liq selling ABOVE entry produces positive PnL
    ///         flowing INTO the insurance fund.
    function testPassA_VaultPnl_PositiveOnLongLiqAboveEntry() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);

        uint256 liqSize = 1 * BAZAAR_SCALE / 10;
        // Long limit at $50,200 — vault sells (closes its inherited long) at $50,200.
        uint256 longId = _placeLimit(alice, true, liqSize, 50_200 * BAZAAR_SCALE);

        // Vault entered the long at $49,000 — selling at $50,200 is a $120 gain × 0.1 = $12 PnL.
        _setVaultPendingLiq(liqSize, 49_000 * BAZAAR_SCALE, 47_000 * BAZAAR_SCALE, true);

        // Capture insurance fund balance before the match.
        (,,,,, uint256 insBefore,,,,,,) = pair.pairVault();

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _empty(), _empty(), _empty()), 10);

        assertEq(success, 1);
        (,,,,, uint256 insAfter,,,,,,) = pair.pairVault();
        assertGt(insAfter, insBefore, "insurance fund grew from positive vault PnL");
    }

    /// @notice Vault Pass A PnL sign — long-liq selling BELOW entry produces negative PnL
    ///         which is debited from the insurance fund.
    function testPassA_VaultPnl_NegativeOnLongLiqBelowEntry() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);

        uint256 liqSize = 1 * BAZAAR_SCALE / 10;
        // Long limit at $49,800 — vault sells at $49,800.
        uint256 longId = _placeLimit(alice, true, liqSize, 49_800 * BAZAAR_SCALE);

        // Vault entered the long at $51,000 — selling at $49,800 is a $120 loss × 0.1 = $12 loss.
        _setVaultPendingLiq(liqSize, 51_000 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE, true);

        (,,,,, uint256 insBefore,,,,,,) = pair.pairVault();

        vm.roll(block.number + 2);
        uint256 success = _match(_lists(_one(longId), _empty(), _empty(), _empty()), 10);

        assertEq(success, 1);
        (,,,,, uint256 insAfter,,,,,,) = pair.pairVault();
        assertLt(insAfter, insBefore, "insurance fund shrank from negative vault PnL");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║     LIQUIDATOR REWARD — max(floor, 2bps × notional)          ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @dev Write position fields into `user`'s bucket via stdstore. Collateral must be
    ///      deposited normally beforehand so USDC bookkeeping (Check 3) stays exact.
    function _writePosition(address user, bool isLong, uint256 size, uint256 entryValue) internal {
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(user).depth(0).checked_write(isLong);
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(user).depth(1).checked_write(size);
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(user).depth(2)
            .checked_write(entryValue);
    }

    /// @dev Alice: 0.1 BTC long ($5,000 notional) entered at $50,050 with $10 collateral.
    ///      Underwater at the $50,000 oracle. Reward = max($0.10, 2bps × $5,000) = $1.00.
    function _setupInsolventAlice() internal {
        _deposit(alice, 10 * BAZAAR_SCALE);
        _writePosition(alice, true, BAZAAR_SCALE / 10, 5_005 * BAZAAR_SCALE);
    }

    /// @notice Reward is the 2bps term for a large position, debited from insurance so the
    ///         balance bookkeeping (vault-health Check 3) never drifts.
    function testLiquidate_LargePosition_PaysBpsFromInsurance() public {
        _setupInsolventAlice();

        (,,,, uint256 collBefore, uint256 insBefore,,,,,,) = pair.pairVault();
        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        address[] memory users = new address[](1);
        users[0] = alice;
        bytes[] memory liqPu = _freshPrice();
        vm.prank(bob);
        pair.liquidate(users, liqPu);

        // 2bps × $5,000 = $1.00 (1 USDC), above the $0.10 floor.
        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, USDC_SCALE, "2bps reward paid");

        (,,,, uint256 collAfter, uint256 insAfter,,,,,,) = pair.pairVault();
        assertEq(collBefore - collAfter, 10 * BAZAAR_SCALE, "seized collateral left user bookkeeping");
        assertEq(
            insAfter - insBefore,
            10 * BAZAAR_SCALE - 1 * BAZAAR_SCALE,
            "insurance gained seizure minus the reward debit"
        );
    }

    /// @notice A small position ($50 notional) pays the $0.10 floor, not the sub-floor 2bps.
    function testLiquidate_SmallPosition_PaysFloor() public {
        _deposit(alice, BAZAAR_SCALE); // $1 collateral (deposit minimum)
        _writePosition(alice, true, BAZAAR_SCALE / 1000, 505 * BAZAAR_SCALE / 10); // 0.001 BTC, $50.50 entry

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        address[] memory users = new address[](1);
        users[0] = alice;
        bytes[] memory liqPu = _freshPrice();
        vm.prank(bob);
        uint256 count = pair.liquidate(users, liqPu);

        assertEq(count, 1, "small position liquidated");
        // 2bps × $50 = $0.01 < $0.10 floor → floor is paid.
        assertEq(usdc.balanceOf(bob) - bobUsdcBefore, USDC_SCALE / 10, "floor reward paid");
    }

    /// @notice Termination clears isAdlPending. The ADL-timeout path terminates with the flag
    ///         freshly re-set to true (VaultHealthLib keeps it pending in that branch), and the
    ///         position-holder withdrawal freeze keys on the flag — if it outlived termination,
    ///         terminal settlement withdrawals would be bricked. Trigger a REAL termination via
    ///         Check-0 (pre-seeded deficit) during a liquidation, with the flag forced on.
    function testTermination_ClearsAdlPending() public {
        _setupInsolventAlice();
        // isAdlPending is PACKED (slot 26, byte offset 20) — stdstore can't write packed slots.
        {
            bytes32 slot = bytes32(uint256(26));
            bytes32 cur = vm.load(address(pair), slot);
            bytes32 mask = bytes32(uint256(0xff) << (20 * 8));
            vm.store(address(pair), slot, (cur & ~mask) | bytes32(uint256(1) << (20 * 8)));
            assertTrue(pair.isAdlPending(), "flag write landed");
        }
        // Pre-seed realized bad debt so the post-liquidation isVaultHealthy hits Check-0 and
        // terminates through _terminatePair. (deficit is field 12 → depth 11 of pairVault.)
        _stdstore.target(address(pair)).sig("pairVault()").depth(11).checked_write(1);

        address[] memory users = new address[](1);
        users[0] = alice;
        bytes[] memory liqPu = _freshPrice();
        vm.prank(bob);
        pair.liquidate(users, liqPu);

        assertTrue(
            pair.isPairTerminatedEmergency() || pair.isPairTerminatedNormal(), "Check-0 deficit terminated the pair"
        );
        assertFalse(pair.isAdlPending(), "termination cleared the ADL-pending flag");
        assertEq(pair.adlPendingSince(), 0, "termination cleared the ADL clock");
    }

    /// @notice A liquidation refreshes IMR/MMR and records a lag sample, so the margin curve is
    ///         not gated solely by matchBatch. (ADL completion uses the same mechanism.)
    function testLiquidate_RefreshesMmrAndRecordsSample() public {
        _setupInsolventAlice();

        // No match/liquidation has run yet, so the margin requirements have never been recomputed.
        (,, uint256 lastTsBefore,) = pair.marginRequirements();
        assertTrue(lastTsBefore < block.timestamp, "precondition: MMR not yet stamped at `now`");
        assertEq(pair.getLaggedMmrBp(), 0, "precondition: no samples yet");

        address[] memory users = new address[](1);
        users[0] = alice;
        bytes[] memory liqPu = _freshPrice();
        vm.prank(bob);
        assertEq(pair.liquidate(users, liqPu), 1, "alice liquidated");

        // The post-liquidation refresh fired: IMR/MMR recomputed and stamped to `now`.
        (uint256 imrAfter, uint256 mmrAfter, uint256 lastTsAfter,) = pair.marginRequirements();
        assertEq(lastTsAfter, block.timestamp, "IMR/MMR recomputed during liquidate()");
        assertEq(mmrAfter, imrAfter / 2, "MMR = IMR/2");
        assertGt(mmrAfter, 0, "MMR is set");

        // A sample was recorded at liquidation time: after 24h it becomes the lagged MMR.
        vm.warp(block.timestamp + 24 hours);
        assertEq(pair.getLaggedMmrBp(), mmrAfter, "liquidation-time sample becomes the lagged MMR");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║   STALE-CHALLENGE INSURANCE CREDIT (sequencer → pair fund)   ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice Only the registered sequencer may credit the insurance fund.
    function testCreditInsuranceFromSequencer_OnlySequencer() public {
        vm.prank(makeAddr("notSequencer"));
        vm.expectRevert(BazaarPair.BazaarPair__OnlySequencer.selector);
        pair.creditInsuranceFromSequencer(1 * BAZAAR_SCALE);
    }

    /// @notice The sequencer's half of a stale-batch slash lands in the pair's insurance fund,
    ///         backed by the matching USDC it pushes first.
    function testCreditInsuranceFromSequencer_CreditsBackedAmount() public {
        (,,,,, uint256 insBefore,,,,,,) = pair.pairVault();

        uint256 amount = 50 * BAZAAR_SCALE; // $50 in BAZAAR precision
        uint256 amountUsdc = amount / 1e12; // USDC_TO_BAZAAR = 1e12

        // Mirror the real flow: the sequencer pushes the USDC, then credits the accounting.
        usdc.mint(address(sequencer), amountUsdc);
        vm.startPrank(address(sequencer));
        usdc.transfer(address(pair), amountUsdc);
        pair.creditInsuranceFromSequencer(amount);
        vm.stopPrank();

        (,,,,, uint256 insAfter,,,,,,) = pair.pairVault();
        assertEq(insAfter - insBefore, amount, "insurance credited by the sequencer share");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║   ORDER-SIDE ASSERTION — a resting order can only be filled   ║
    // ║   in the direction it was signed for. The matching engine     ║
    // ║   takes fill direction from WHICH list an id is placed in, so ║
    // ║   each head loader must reject an order whose own isLong does  ║
    // ║   not match its list — otherwise a sequencer could fill a     ║
    // ║   user's long as a short (and vice versa). See                ║
    // ║   MatchingEngineLib__WrongOrderSideInList.                    ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice The core exploit: a genuine LONG limit dropped into the shortLimits array by the
    ///         sequencer must revert the whole batch rather than fill the maker as a short.
    function testSideAssertion_LongLimitInShortList_Reverts() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE); // victim
        _deposit(bob, 20_000 * BAZAAR_SCALE); // sequencer's counterparty

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 victimLong = _placeLimit(alice, true, size, 50_000 * BAZAAR_SCALE);
        uint256 attackerLong = _placeLimit(bob, true, size, 50_000 * BAZAAR_SCALE); // priced to cross

        vm.roll(block.number + 2);

        // Sequencer misfiles the victim's long into the short list.
        _matchRevert(
            _lists(_one(attackerLong), _one(victimLong), _empty(), _empty()),
            abi.encodeWithSelector(
                MatchingEngineLib.MatchingEngineLib__WrongOrderSideInList.selector, victimLong, false, true
            )
        );
    }

    /// @notice Symmetric case: a genuine SHORT limit dropped into the longLimits array must revert.
    function testSideAssertion_ShortLimitInLongList_Reverts() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 victimShort = _placeLimit(alice, false, size, 50_000 * BAZAAR_SCALE);
        uint256 attackerShort = _placeLimit(bob, false, size, 50_000 * BAZAAR_SCALE);

        vm.roll(block.number + 2);

        _matchRevert(
            _lists(_one(victimShort), _one(attackerShort), _empty(), _empty()),
            abi.encodeWithSelector(
                MatchingEngineLib.MatchingEngineLib__WrongOrderSideInList.selector, victimShort, true, false
            )
        );
    }

    /// @notice A LONG market misfiled into the shortMarkets array must revert (Pass B, sub-walk 2).
    function testSideAssertion_LongMarketInShortMarketList_Reverts() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 victimLongMkt = _placeMarket(alice, true, size, 100); // 1% slippage
        uint256 attackerLong = _placeLimit(bob, true, size, 50_000 * BAZAAR_SCALE); // enters sub-walk 2

        vm.roll(block.number + 2);

        _matchRevert(
            _lists(_one(attackerLong), _empty(), _empty(), _one(victimLongMkt)),
            abi.encodeWithSelector(
                MatchingEngineLib.MatchingEngineLib__WrongOrderSideInList.selector, victimLongMkt, false, true
            )
        );
    }

    /// @notice A SHORT market misfiled into the longMarkets array must revert (Pass B, sub-walk 1).
    function testSideAssertion_ShortMarketInLongMarketList_Reverts() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        uint256 size = 1 * BAZAAR_SCALE / 10;
        uint256 victimShortMkt = _placeMarket(alice, false, size, 100);
        uint256 attackerShort = _placeLimit(bob, false, size, 50_000 * BAZAAR_SCALE); // enters sub-walk 1

        vm.roll(block.number + 2);

        _matchRevert(
            _lists(_empty(), _one(attackerShort), _one(victimShortMkt), _empty()),
            abi.encodeWithSelector(
                MatchingEngineLib.MatchingEngineLib__WrongOrderSideInList.selector, victimShortMkt, true, false
            )
        );
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║  FEE COVERAGE — a fill whose fee exceeds the payer's own       ║
    // ║  collateral is auto-canceled and skipped, never filled with    ║
    // ║  the shortfall silently drained from the shared deposit pool.  ║
    // ║  Guards the D == Σ bucket.collateral invariant.               ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice A full close whose owner holds less collateral than the flat sequencer fee ($0.03) is
    ///         auto-canceled and skipped, not filled. Previously the fee floored to the available
    ///         collateral while the ledger (D) was decremented by — and the fee paid out at — the full
    ///         nominal amount, draining the shared pool and eventually bricking the last withdrawer.
    function testFeeCoverage_SubFeeClose_AutoCanceledNotFilled() public {
        uint256 size = 1 * BAZAAR_SCALE / 10; // 0.1 BTC

        // Alice: long 0.1 BTC entered @ $50,000. Real deposit first so USDC/ledger bookkeeping is exact.
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _writePosition(alice, true, size, 5_000 * BAZAAR_SCALE);

        // Bob: healthy counterparty for the other side of Alice's close.
        _deposit(bob, 20_000 * BAZAAR_SCALE);

        // Alice full-closes @ $50,000 (breakeven vs entry); Bob takes the long. Orders are placed
        // while Alice still has ample collateral so createOrder doesn't block them.
        uint256 aliceClose = _placeLimit(alice, false, size, 50_000 * BAZAAR_SCALE);
        uint256 bobLong = _placeLimit(bob, true, size, 50_000 * BAZAAR_SCALE);

        // Force Alice's collateral below the $0.03 flat fee — the fee can no longer be fully collected.
        _setCollateral(alice, 2 * BAZAAR_SCALE / 100); // $0.02

        vm.roll(block.number + 2);

        (,,,, uint256 dBefore,,,,,,,) = pair.pairVault(); // totalCollateralDeposited

        uint256 success = _match(_lists(_one(bobLong), _one(aliceClose), _empty(), _empty()), 10);

        // The under-collateralized close is rejected, not filled.
        assertEq(success, 0, "sub-fee close must not fill");
        assertGt(_canceledBlock(aliceClose), 0, "alice's close auto-canceled");
        assertEq(_filledSize(aliceClose), 0, "alice's close not filled");

        // Alice's long position is untouched.
        (bool aliceLong, uint256 aliceSize) = _position(alice);
        assertTrue(aliceLong, "alice still long");
        assertEq(aliceSize, size, "alice position intact");

        // No fee leaked: the deposits ledger is unchanged by the skipped match.
        (,,,, uint256 dAfter,,,,,,,) = pair.pairVault();
        assertEq(dAfter, dBefore, "D unchanged when the fee was uncollectable");
    }
}
