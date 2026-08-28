// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairLens} from "../../src/BazaarPairLens.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

/// @title IntegrationBase
/// @notice Shared deployment harness for the Bazaar integration suite. Every integration test
///         contract inherits this so it gets a full factory/oracle/pair deployment plus the
///         order/deposit/price helpers — no duplicated setUp per file.
///
/// @dev    Matching is arrival-time: createOrder walks the book in the same transaction, so a
///         crossing placement fills immediately at the resting maker's price and there is no
///         separate match step. Helpers that place a maker first and a crossing taker second
///         therefore produce the fill prices their callers assert on.
///
///         Prank ordering gotcha: any helper that builds a Pyth price update makes an EXTERNAL
///         call to `mockPyth`, which CONSUMES a pending `vm.prank`. Every helper here builds the
///         price bytes BEFORE the prank; do the same in tests.
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
    address public seq; // generic keeper address (trigger execution, unloads, sweeps)

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

        vm.roll(block.number + 20);
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
    ///      (not the block.timestamp opcode) so a stale cached timestamp can't slip in after a fill.
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

    /// @dev Zeroed execution aids: head-insert-or-repair positioning, protocol-default walk cap.
    function _hintsNone() internal pure returns (BazaarTypes.MatchHints memory m) {}

    /// @dev Per-pair probe watermark for _lastCreatedOrderId.
    mapping(address => uint256) internal _idProbe;

    /// @dev The newest orderId a pair has assigned. Ids are a gapless monotonic counter from 1,
    ///      so probing forward from a per-pair watermark finds the last created order without
    ///      reading events — createOrder has no id return, and the order may already be terminal
    ///      (filled or canceled in its own transaction) so the active-set is no source either.
    function _lastCreatedOrderId(BazaarPair p) internal returns (uint256) {
        uint256 w = _idProbe[address(p)];
        if (w == 0) w = 1;
        while (true) {
            (address creator,,,,,,,,,,,,,,,,,) = p.orders(w);
            if (creator == address(0)) break;
            ++w;
        }
        _idProbe[address(p)] = w;
        require(w > 1, "no orders created yet");
        return w - 1;
    }

    function _newestLimitOrderId(address user) internal returns (uint256) {
        (uint256[] memory ids,,,) = pair.getUserActiveLimitOrders(user);
        require(ids.length > 0, "no active limit orders");
        return ids[ids.length - 1];
    }

    function _limitSpec(bool isLong, uint256 size, uint256 limitPrice)
        internal
        view
        returns (BazaarTypes.OrderSpec memory s)
    {
        s.orderType = BazaarTypes.OrderType.Limit;
        s.isLong = isLong;
        s.size = size;
        s.limitPrice = limitPrice;
        s.expirationBlock = uint64(block.number + 500_000);
    }

    function _placeLimit(address user, bool isLong, uint256 size, uint256 limitPrice) internal returns (uint256) {
        bytes[] memory pu = _freshPrice(); // build BEFORE the prank (external mockPyth call would consume it)
        vm.prank(user);
        pair.createOrder(_limitSpec(isLong, size, limitPrice), _hintsNone(), pu, 0, 0, 0, "");
        return _lastCreatedOrderId(pair);
    }

    /// @dev Place a limit while the oracle prints `oraclePriceUsd` (warps +3s so the update is
    ///      strictly newer). A crossing placement fills immediately at the maker's price; the
    ///      oracle price drives the margin checks and the stale band only.
    function _placeLimitAt(address user, bool isLong, uint256 size, uint256 limitPrice, uint256 oraclePriceUsd)
        internal
        returns (uint256)
    {
        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceUpdate(oraclePriceUsd, uint64(vm.getBlockTimestamp()));
        vm.prank(user);
        pair.createOrder(_limitSpec(isLong, size, limitPrice), _hintsNone(), pu, 0, 0, 0, "");
        return _lastCreatedOrderId(pair);
    }

    function _placeMarket(address user, bool isLong, uint256 size, uint256 maxSlippageBp) internal returns (uint256) {
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.Market;
        s.isLong = isLong;
        s.size = size;
        s.maxSlippageBp = maxSlippageBp;
        vm.prank(user);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "");
        return _lastCreatedOrderId(pair);
    }

    function _placeStopLimit(address user, bool isLong, uint256 size, uint256 triggerPrice, uint256 limitPrice)
        internal
        returns (uint256)
    {
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.StopLimit;
        s.isLong = isLong;
        s.size = size;
        s.triggerPrice = triggerPrice;
        s.limitPrice = limitPrice;
        s.expirationBlock = uint64(block.number + 500_000);
        vm.prank(user);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "");
        return _lastCreatedOrderId(pair);
    }

    function _placeStopLoss(address user, bool isLong, uint256 size, uint256 triggerPrice, uint256 maxSlippageBp)
        internal
        returns (uint256)
    {
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.StopLoss;
        s.isLong = isLong;
        s.size = size;
        s.triggerPrice = triggerPrice;
        s.maxSlippageBp = maxSlippageBp;
        vm.prank(user);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "");
        return _lastCreatedOrderId(pair);
    }

    function _placeTakeProfit(address user, bool isLong, uint256 size, uint256 limitPrice) internal returns (uint256) {
        bytes[] memory pu = _freshPrice();
        BazaarTypes.OrderSpec memory s;
        s.orderType = BazaarTypes.OrderType.TakeProfit;
        s.isLong = isLong;
        s.size = size;
        s.limitPrice = limitPrice;
        vm.prank(user);
        pair.createOrder(s, _hintsNone(), pu, 0, 0, 0, "");
        return _lastCreatedOrderId(pair);
    }

    /// @dev Open `size` for `user` in direction `isLong` against `counterparty` at $50k oracle.
    ///      The user's limit is placed first (older id → resting maker), so the fill executes at
    ///      the user's limit price when the counterparty's crossing order arrives.
    function _openPosition(address user, address counterparty, bool isLong, uint256 size) internal {
        _deposit(user, 20_000 * BAZAAR_SCALE);
        _deposit(counterparty, 20_000 * BAZAAR_SCALE);
        if (isLong) {
            _placeLimit(user, true, size, 51_000 * BAZAAR_SCALE);
            _roll(2);
            _placeLimit(counterparty, false, size, 49_000 * BAZAAR_SCALE);
        } else {
            _placeLimit(user, false, size, 49_000 * BAZAAR_SCALE);
            _roll(2);
            _placeLimit(counterparty, true, size, 51_000 * BAZAAR_SCALE);
        }
    }

    // ---------------------------- keeper entry points ----------------------------

    /// @dev Fire one stop through the permissionless trigger executor at $50k.
    function _executeTrigger(uint256 orderId) internal returns (uint256 executedCount) {
        return _executeTriggerAt(orderId, 50_000);
    }

    /// @dev Fire one stop at a custom oracle price (warps +3s so the update is strictly newer).
    function _executeTriggerAt(uint256 orderId, uint256 priceUsd) internal returns (uint256 executedCount) {
        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _priceUpdate(priceUsd, uint64(vm.getBlockTimestamp()));
        BazaarTypes.TriggerExec[] memory execs = new BazaarTypes.TriggerExec[](1);
        execs[0].orderId = uint64(orderId);
        vm.prank(seq);
        executedCount = pair.executeTriggeredOrders(execs, pu);
    }

    /// @dev Unload vault liquidation inventory into the book (protocol-default walk cap) at $50k.
    function _unloadVault() internal returns (uint256 unloadedSize) {
        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        unloadedSize = pair.unloadVault(0, pu);
    }

    // ---------------------------- order / position / vault readers ----------------------------
    function _takeProfitOrderId(address user) internal view returns (uint256 id) {
        (,,,,, id,,,) = pair.positionBuckets(user);
    }

    function _stopLossOrderId(address user) internal view returns (uint256 id) {
        (,,,,,, id,,) = pair.positionBuckets(user);
    }

    function _filledSize(uint256 orderId) internal view returns (uint256 s) {
        (,,,,,, s,,,,,,,,,,,) = pair.orders(orderId);
    }

    function _orderSize(uint256 orderId) internal view returns (uint256 s) {
        (,,,,, s,,,,,,,,,,,,) = pair.orders(orderId);
    }

    function _canceledBlock(uint256 orderId) internal view returns (uint64 cb) {
        (,,,,,,,,,,,,,, cb,,,) = pair.orders(orderId);
    }

    function _inBook(uint256 orderId) internal view returns (bool b) {
        (,,,,,,,,,,, b,,,,,,) = pair.orders(orderId);
    }

    function _position(address user) internal view returns (bool isLong, uint256 size) {
        (isLong, size,,,,,,,) = pair.positionBuckets(user);
    }

    function _posSize(address user) internal view returns (uint256 size) {
        (, size,,,,,,,) = pair.positionBuckets(user);
    }

    function _posCollateral(address user) internal view returns (uint256 c) {
        (,,, c,,,,,) = pair.positionBuckets(user);
    }

    function _insuranceBal() internal view returns (uint256 b) {
        (,,,,, b,,,,,,) = pair.pairVault();
    }

    // ---------------------------- misc array helpers ----------------------------
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
    ///      opcode: after an external call like createOrder the optimizer can re-materialize a stale
    ///      cached `block.number`, turning `vm.roll(block.number + n)` into a no-op. The cheatcode read
    ///      is immune to that, so sequential-fill tests advance reliably.
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
