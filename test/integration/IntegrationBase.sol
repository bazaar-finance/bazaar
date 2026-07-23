// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairLens} from "../../src/BazaarPairLens.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarSequencer} from "../../src/BazaarSequencer.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

/// @title IntegrationBase
/// @notice Shared deployment harness for the Bazaar integration suite. Every integration test
///         contract inherits this so it gets a full factory/oracle/sequencer/pair deployment plus
///         the order/deposit/match/price helpers — no duplicated setUp per file.
///
/// @dev    Prank ordering gotcha: any helper that builds a Pyth price update makes an EXTERNAL call
///         to `mockPyth`, which CONSUMES a pending `vm.prank`. Every helper here builds the price
///         bytes BEFORE the prank; do the same in tests.
abstract contract IntegrationBase is Test {
    using stdStorage for StdStorage;
    StdStorage internal _stdstore;

    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant AAPL_USD_FEED_ID = 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688;
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;
    int32 constant PYTH_EXPO = -8;
    uint256 constant INITIAL_USER_BALANCE = 1_000_000 * USDC_SCALE;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;

    BazaarFactory public factory;
    BazaarOracle public oracle;
    BazaarSequencer public sequencer;
    BazaarPair public pair;
    BazaarPair public aaplPair;
    MockUSDC public usdc;
    MockPyth public mockPyth;
    BazaarPairLens public lens;

    address public deployer;
    address public alice;
    address public bob;
    address public carol;
    address public dave;
    address public seq;

    function setUp() public virtual {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dave = makeAddr("dave");
        seq = makeAddr("seq");
        vm.etch(address(0x64), address(new MockArbSys()).code); // ArbSys precompile

        DeployBazaar dep = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = dep.deploy(makeAddr("bugBounty"));
        (, address usdcAddr,,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcAddr);
        oracle = factory.oracle();
        sequencer = factory.sequencer();
        mockPyth = MockPyth(address(oracle.pyth()));
        lens = new BazaarPairLens();

        usdc.mint(deployer, INITIAL_USER_BALANCE);
        usdc.mint(alice, INITIAL_USER_BALANCE);
        usdc.mint(bob, INITIAL_USER_BALANCE);
        usdc.mint(carol, INITIAL_USER_BALANCE);
        usdc.mint(dave, INITIAL_USER_BALANCE);
        usdc.mint(seq, INITIAL_USER_BALANCE);

        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();

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

        vm.startPrank(seq);
        usdc.approve(address(sequencer), 5_000 * USDC_SCALE);
        sequencer.deposit(5_000 * USDC_SCALE);
        vm.stopPrank();

        vm.roll(block.number + 20); // observationBlock headroom
    }

    // ---------------------------- price helpers ----------------------------
    receive() external payable {}

    /// @dev General Pyth update for any feed at any price (uses PYTH_EXPO = -8, conf = 0.1%).
    function _priceUpdateFor(bytes32 feedId, uint256 priceUsd, uint64 publishTime)
        internal
        view
        returns (bytes[] memory pu)
    {
        int64 pythPrice = int64(int256(priceUsd * 1e8));
        uint64 conf = uint64(priceUsd * 1e8 / 1000);
        bytes memory data = mockPyth.createPriceFeedUpdateData(
            feedId, pythPrice, conf, PYTH_EXPO, pythPrice, conf, publishTime, publishTime > 0 ? publishTime - 1 : 0
        );
        pu = new bytes[](1);
        pu[0] = data;
    }

    function _priceUpdate(uint256 priceUsd, uint64 publishTime) internal view returns (bytes[] memory) {
        return _priceUpdateFor(BTC_USD_FEED_ID, priceUsd, publishTime);
    }

    /// @dev BTC update at an arbitrary price, stamped now. Uses the vm.getBlockTimestamp() cheatcode
    ///      (not the block.timestamp opcode) so a stale cached timestamp can't slip in after a match.
    function _priceAt(uint256 priceUsd) internal returns (bytes[] memory) {
        return _priceUpdate(priceUsd, uint64(vm.getBlockTimestamp()));
    }

    /// @dev BTC update at $50k, stamped now.
    function _freshPrice() internal returns (bytes[] memory) {
        return _priceAt(50_000);
    }

    // ---------------------------- collateral / insurance ----------------------------
    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(pair), amount * USDC_SCALE / BAZAAR_SCALE);
        pair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function _depositInsurance(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(pair), amount * USDC_SCALE / BAZAAR_SCALE);
        pair.depositToInsurance(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    // ---------------------------- orders ----------------------------
    function _newestLimitOrderId(address user) internal returns (uint256) {
        (uint256[] memory ids,,,) = pair.getUserActiveLimitOrders(user);
        require(ids.length > 0, "no active limit orders");
        return ids[ids.length - 1];
    }

    function _placeLimit(address user, bool isLong, uint256 size, uint256 limitPrice) internal returns (uint256) {
        bytes[] memory pu = _freshPrice(); // build BEFORE the prank (external mockPyth call would consume it)
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

    function _lists(uint256[] memory a, uint256[] memory b, uint256[] memory c, uint256[] memory d)
        internal
        pure
        returns (BazaarTypes.OrderLists memory ol)
    {
        ol.longLimits = a;
        ol.shortLimits = b;
        ol.longMarkets = c;
        ol.shortMarkets = d;
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

    function _match(BazaarTypes.OrderLists memory lists, uint256 maxMatches) internal returns (uint256 successCount) {
        bytes[] memory pu = _freshPrice(); // build BEFORE the prank (external mockPyth call would consume it)
        uint64 obs = uint64(vm.getBlockNumber() - 1);
        vm.prank(seq);
        successCount = pair.matchBatch(lists, maxMatches, pu, obs);
    }

    // ---------------------------- order-type placement ----------------------------
    function _placeMarket(address user, bool isLong, uint256 size, uint256 maxSlippageBp) internal returns (uint256) {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        pair.createOrder(
            BazaarTypes.OrderType.Market, 0, 0, maxSlippageBp, size, isLong, false, 0, address(0), pu, 0, 0, 0, ""
        );
        return _activeMarketOrderId(user);
    }

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
            0,
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
        return _stopLossOrderId(user);
    }

    function _placeTakeProfit(address user, bool isLong, uint256 size, uint256 limitPrice) internal returns (uint256) {
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        pair.createOrder(
            BazaarTypes.OrderType.TakeProfit, 0, limitPrice, 0, size, isLong, false, 0, address(0), pu, 0, 0, 0, ""
        );
        return _takeProfitOrderId(user);
    }

    /// @dev Open `size` for `user` in direction `isLong` by matching against `counterparty` at $50k.
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
        _roll(2);
        _match(_lists(_one(longId), _one(shortId), _empty(), _empty()), 10);
    }

    /// @dev matchBatch at a custom oracle price (whole USD); warps past staleness so the price is consumed.
    function _matchAtPrice(BazaarTypes.OrderLists memory lists, uint256 maxMatches, uint256 priceUsd)
        internal
        returns (uint256 successCount)
    {
        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceUpdate(priceUsd, uint64(vm.getBlockTimestamp()));
        uint64 obs = uint64(vm.getBlockNumber() - 1);
        vm.prank(seq);
        successCount = pair.matchBatch(lists, maxMatches, pu, obs);
    }

    // ---------------------------- order / position / vault readers ----------------------------
    function _activeMarketOrderId(address user) internal view returns (uint256 id) {
        (,,,,,,,, id,) = pair.positionBuckets(user);
    }

    function _takeProfitOrderId(address user) internal view returns (uint256 id) {
        (,,,,, id,,,,) = pair.positionBuckets(user);
    }

    function _stopLossOrderId(address user) internal view returns (uint256 id) {
        (,,,,,, id,,,) = pair.positionBuckets(user);
    }

    function _filledSize(uint256 orderId) internal view returns (uint256 s) {
        (,,,,,, s,,,,,,,) = pair.orders(orderId);
    }

    function _orderSize(uint256 orderId) internal view returns (uint256 s) {
        (,,,,, s,,,,,,,,) = pair.orders(orderId);
    }

    function _canceledBlock(uint256 orderId) internal view returns (uint64 cb) {
        (,,,,,,,,,,,, cb,) = pair.orders(orderId);
    }

    function _position(address user) internal view returns (bool isLong, uint256 size) {
        (isLong, size,,,,,,,,) = pair.positionBuckets(user);
    }

    function _posSize(address user) internal view returns (uint256 size) {
        (, size,,,,,,,,) = pair.positionBuckets(user);
    }

    function _posCollateral(address user) internal view returns (uint256 c) {
        (,,, c,,,,,,) = pair.positionBuckets(user);
    }

    function _insuranceBal() internal view returns (uint256 b) {
        (,,,,, b,,,,,,) = pair.pairVault();
    }

    // ---------------------------- solvency books (Check-3) ----------------------------

    /// @dev Rounding tolerance between the (I + D) ledger — fees debited in 1e18 precision — and
    ///      the contract's USDC balance (1e6 granularity). Absorbs sub-µUSDC mulDiv dust.
    uint256 constant BOOKS_TOL = 1e13; // $0.00001

    /// @dev totalCollateralDeposited (D) — Vault field index 4.
    function _totalDeposited() internal view returns (uint256 d) {
        (,,,, d,,,,,,,) = pair.pairVault();
    }

    /// @dev The Check-3 expected balance, insuranceFundBalance (I) + totalCollateralDeposited (D),
    ///      in BAZAAR (1e18) precision.
    function _ledgerBaz() internal view returns (uint256) {
        (,,,, uint256 d, uint256 i,,,,,,) = pair.pairVault();
        return d + i;
    }

    /// @dev The contract's actual USDC balance, scaled to BAZAAR (1e18) precision.
    function _cashBaz() internal view returns (uint256) {
        return usdc.balanceOf(address(pair)) * 1e12;
    }

    /// @dev Mid-lifecycle solvency — the protocol's one-directional Check-3 invariant (isVaultHealthy):
    ///      the contract must hold at least I + D of USDC (minus rounding). Realized-but-unwithdrawn
    ///      PnL lets cash legitimately EXCEED I + D, so only this direction is asserted. Holds at any
    ///      point the pair is not terminated; a bug that drifts I + D above the real balance (e.g. an
    ///      outflow debiting a bucket but not D) breaks it.
    function _assertBooks(string memory label) internal view {
        assertGe(_cashBaz() + BOOKS_TOL, _ledgerBaz(), string.concat(label, ": cash >= I + D (Check-3 solvency)"));
    }

    /// @dev Settled-state books — cash EXACTLY equals I + D (both directions). Valid only where no
    ///      realized-but-unredistributed value is in flight: genesis, after deposits/insurance deposits,
    ///      and after a fresh open (unrealized PnL doesn't move collateral, so it's fine). Catches
    ///      D-drift in EITHER direction that the one-directional Check-3 cannot.
    function _assertBooksSettled(string memory label) internal view {
        assertApproxEqAbs(_cashBaz(), _ledgerBaz(), BOOKS_TOL, string.concat(label, ": cash == I + D (settled books)"));
    }

    // ---------------------------- misc ----------------------------
    function _arr1(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    /// @dev Advance `n` L2 blocks. Uses the vm.getBlockNumber() cheatcode rather than the `block.number`
    ///      opcode: after an external call like matchBatch the optimizer can re-materialize a stale
    ///      cached `block.number`, turning `vm.roll(block.number + n)` into a no-op. The cheatcode read
    ///      is immune to that, so sequential-match tests advance reliably.
    function _roll(uint256 n) internal {
        vm.roll(vm.getBlockNumber() + n);
    }

    /// @dev Overwrite a user's position bucket via stdstore (isLong/size/entryValue). Collateral must
    ///      come from a real _deposit so the vault's USDC accounting stays backed.
    function _writePosition(address user, bool isLong, uint256 size, uint256 entryValue) internal {
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(user).depth(0).checked_write(isLong);
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(user).depth(1).checked_write(size);
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(user).depth(2)
            .checked_write(entryValue);
    }

    /// @dev Write an underwater 0.1 BTC long for alice (thin $10 collateral, liquidatable at $50k).
    function _setupInsolventAlice() internal {
        _deposit(alice, 10 * BAZAAR_SCALE);
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(alice).depth(0).checked_write(true); // isLong
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(alice).depth(1)
            .checked_write(BAZAAR_SCALE / 10); // size
        _stdstore.target(address(pair)).sig("positionBuckets(address)").with_key(alice).depth(2)
            .checked_write(5_005 * BAZAAR_SCALE); // entryValue
    }
}
