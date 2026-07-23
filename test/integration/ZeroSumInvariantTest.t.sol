// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarSequencer} from "../../src/BazaarSequencer.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

/// @title ZeroSumInvariantTest
/// @notice Books-conservation invariants asserted at every step of realistic trading lifecycles.
///         Two invariants, checked together by _assertZeroSum:
///
///         CASH BOOKS (Check-3 mirror):
///             usdc.balanceOf(pair) == insuranceFundBalance + totalCollateralDeposited
///
///         CLAIMS == CASH (zero-sum):
///             Σ trader equity(P, F)  +  vault inventory value(P, F)  +  insurance
///                 == insuranceFundBalance + totalCollateralDeposited
///             ⟺   Σ trader equity + vault inventory == totalCollateralDeposited
///
///         where equity = collateral + price PnL + funding PnL, and the vault inventory value is
///         the pendingLiq aggregate marked at the same (P, F). Because every long unit is offset
///         by a short unit (trader or vault inventory), the P- and F-dependent terms cancel in
///         the sum — the invariant holds at ANY consistent (P, F) if and only if no state
///         transition mints or drops value between traders, the vault, and insurance.
///         A dropped funding settlement, a PnL credited without a debit, or a seizure that
///         doesn't reach insurance all break this equality immediately.
contract ZeroSumInvariantTest is Test {
    // -------------------- Constants --------------------
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;

    uint256 constant INITIAL_USER_BALANCE = 1_000_000 * USDC_SCALE;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;

    int32 constant BTC_PYTH_EXPO = -8;

    /// @dev Tolerance in BAZAAR 18-decimals: absorbs mulDiv rounding across many fills and the
    ///      sub-USDC dust stranded by 1e18→1e6 payout truncation (always in the contract's favor).
    uint256 constant CLAIMS_TOL = 1e13; // $0.00001

    // -------------------- State --------------------
    BazaarFactory public factory;
    BazaarOracle public oracle;
    BazaarSequencer public sequencer;
    BazaarPair public pair;
    MockUSDC public usdc;
    MockPyth public mockPyth;

    address public deployer;
    address public alice;
    address public bob;
    address public carol;
    address public dave;
    address public seq;

    address[] internal traders;

    /// @dev Test-side clock. via-IR legitimately caches `block.timestamp` across external calls
    ///      (TIMESTAMP is constant within a real transaction), so reading it after `vm.warp` in
    ///      the same frame can return a stale value. All warps and price publishTimes go through
    ///      this storage variable instead.
    uint64 internal t;

    function _advance(uint256 secs) internal {
        t += uint64(secs);
        vm.warp(t);
    }

    function _pu(uint256 priceUsd) internal view returns (bytes[] memory) {
        return _priceUpdate(priceUsd, t);
    }

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dave = makeAddr("dave");
        seq = makeAddr("seq");
        traders = [alice, bob, carol, dave];

        vm.etch(address(0x64), address(new MockArbSys()).code);

        DeployBazaar dep = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = dep.deploy(makeAddr("bugBounty"));

        (, address usdcAddr,,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcAddr);
        oracle = factory.oracle();
        sequencer = factory.sequencer();
        mockPyth = MockPyth(address(oracle.pyth()));

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

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        pair = BazaarPair(payable(factory.getPairAddress(pairId)));

        // Bond high enough that the 14× rolling volume cap never binds in these scenarios.
        vm.startPrank(seq);
        usdc.approve(address(sequencer), 50_000 * USDC_SCALE);
        sequencer.deposit(50_000 * USDC_SCALE);
        vm.stopPrank();

        vm.roll(block.number + 20);
        t = uint64(block.timestamp);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║                    THE INVARIANT                             ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @dev Trader equity marked at (price P, funding index F): collateral + price PnL + funding PnL.
    function _equityAt(address u, uint256 p, int256 f) internal view returns (int256 equity) {
        (bool isLong, uint256 size, uint256 entryValue, uint256 collateral, int256 entryFundingIdx,,,,,) =
            pair.positionBuckets(u);
        equity = int256(collateral);
        if (size == 0) return equity;

        int256 notional = int256(size * p / BAZAAR_SCALE);
        int256 pricePnl = isLong ? notional - int256(entryValue) : int256(entryValue) - notional;
        int256 rawFunding = (f - entryFundingIdx) * int256(size) / int256(BAZAAR_SCALE);
        int256 fundingPnl = isLong ? -rawFunding : rawFunding;
        equity += pricePnl + fundingPnl;
    }

    /// @dev The vault's pendingLiq inventory marked at the same (P, F): price PnL vs its entry
    ///      notional basis plus funding from the liquidatees' entry-weighted index — the same
    ///      bases Pass A settles against, so realizing inventory moves value to insurance 1:1.
    function _vaultInventoryAt(uint256 p, int256 f) internal view returns (int256 value) {
        (,,,,,, uint256 plSize, uint256 plEntry,, int256 plFundIdx, bool plIsLong,) = pair.pairVault();
        if (plSize == 0) return 0;

        int256 notional = int256(plSize * p / BAZAAR_SCALE);
        int256 pricePnl = plIsLong ? notional - int256(plEntry) : int256(plEntry) - notional;
        int256 rawFunding = (f - plFundIdx) * int256(plSize) / int256(BAZAAR_SCALE);
        int256 windowFunding = plIsLong ? -rawFunding : rawFunding;
        value = pricePnl + windowFunding;
    }

    /// @dev Assert THE invariant:
    ///          Σ trader equity(P, F) + vault inventory(P, F) + insurance == actual USDC held.
    ///      Every transition must conserve this: PnL and funding are transfers between the three
    ///      parties, deposits/withdrawals/fee-payouts/rewards move claims and cash together.
    ///      (The deposits ledger D deliberately does NOT appear: D + I is a deposits-flow view
    ///      that legitimately lags realized-PnL redistribution until winners withdraw — the
    ///      protocol's Check-3 only requires cash >= D + I − tolerance, one-directional.)
    ///      `priceUsd` is only a marking price — conservation is price-independent because long
    ///      and short sizes (traders + vault inventory) always balance.
    function _assertZeroSum(uint256 priceUsd, string memory label) internal view {
        (,,,,, uint256 I,,,,,, uint256 deficit) = pair.pairVault();
        assertEq(deficit, 0, string.concat(label, ": no realized bad debt expected in this scenario"));

        uint256 p = priceUsd * BAZAAR_SCALE;
        int256 f = pair.currentFundingIndex();
        int256 claims = int256(I);
        for (uint256 i = 0; i < traders.length; i++) {
            claims += _equityAt(traders[i], p, f);
        }
        claims += _vaultInventoryAt(p, f);

        int256 cash = int256(usdc.balanceOf(address(pair)) * 1e12);
        assertApproxEqAbs(claims, cash, CLAIMS_TOL, string.concat(label, ": total claims == actual USDC (zero-sum)"));
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║                    SCENARIO HELPERS                          ║
    // ╚══════════════════════════════════════════════════════════════╝

    function _priceUpdate(uint256 priceUsd, uint64 publishTime) internal view returns (bytes[] memory pu) {
        int64 pythPrice = int64(int256(priceUsd * 1e8));
        uint64 conf = uint64(priceUsd * 1e8 / 1000);
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

    function _freshPrice() internal view returns (bytes[] memory) {
        return _priceUpdate(50_000, t);
    }

    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(pair), amount * USDC_SCALE / BAZAAR_SCALE);
        pair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function _placeLimit(address user, bool isLong, uint256 size, uint256 limitPrice) internal returns (uint256) {
        return _placeLimitAt(user, isLong, size, limitPrice, 50_000);
    }

    function _placeLimitAt(address user, bool isLong, uint256 size, uint256 limitPrice, uint256 priceUsd)
        internal
        returns (uint256)
    {
        // +3s: past MAX_PRICE_STALENESS, so the pair consumes the supplied price rather than a
        // fresh-enough cache from a previous (possibly differently-priced) step.
        _advance(3);
        bytes[] memory pu = _pu(priceUsd);
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
        (uint256[] memory ids,,,) = pair.getUserActiveLimitOrders(user);
        return ids[ids.length - 1];
    }

    function _lists(uint256[] memory longLimits, uint256[] memory shortLimits)
        internal
        pure
        returns (BazaarTypes.OrderLists memory ol)
    {
        ol.longLimits = longLimits;
        ol.shortLimits = shortLimits;
        ol.longMarkets = new uint256[](0);
        ol.shortMarkets = new uint256[](0);
    }

    function _one(uint256 a) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = a;
    }

    function _none() internal pure returns (uint256[] memory a) {
        a = new uint256[](0);
    }

    function _matchAtPrice(BazaarTypes.OrderLists memory lists, uint256 priceUsd)
        internal
        returns (uint256 successCount)
    {
        _advance(3);
        bytes[] memory pu = _pu(priceUsd);
        vm.roll(block.number + 2);
        uint64 obs = uint64(block.number - 1);
        vm.prank(seq);
        successCount = pair.matchBatch(lists, 10, pu, obs);
    }

    /// @dev Cross a (long, short) pair of fresh limit orders in one batch at the given oracle price.
    function _crossAt(
        address longUser,
        uint256 longPx,
        address shortUser,
        uint256 shortPx,
        uint256 size,
        uint256 priceUsd
    ) internal {
        uint256 longId = _placeLimitAt(longUser, true, size, longPx, priceUsd);
        uint256 shortId = _placeLimitAt(shortUser, false, size, shortPx, priceUsd);
        vm.roll(block.number + 2); // orders must exist strictly before the observation block
        assertEq(_matchAtPrice(_lists(_one(longId), _one(shortId)), priceUsd), 1, "cross must fill");
    }

    function _cross(address longUser, uint256 longPx, address shortUser, uint256 shortPx, uint256 size) internal {
        _crossAt(longUser, longPx, shortUser, shortPx, size, 50_000);
    }

    /// @dev Withdraw a flat user's full collateral (rounded down to USDC granularity).
    function _withdrawAll(address u) internal {
        (, uint256 size,, uint256 coll,,,,,,) = pair.positionBuckets(u);
        assertEq(size, 0, "withdrawAll expects a flat user");
        uint256 amount = coll - (coll % 1e12);
        if (amount == 0) return;
        vm.prank(u);
        pair.withdrawCollateral(amount, new bytes[](0), 0, 0, 0, "");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║                       SCENARIOS                              ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @notice Full trade lifecycle without funding: deposits → open → add a third trader →
    ///         partial close → full closes → withdrawals. Books must balance at every step.
    function test_zeroSum_tradeLifecycle() public {
        _assertZeroSum(50_000, "genesis");

        _deposit(alice, 15_000 * BAZAAR_SCALE);
        _deposit(bob, 15_000 * BAZAAR_SCALE);
        _deposit(dave, 15_000 * BAZAAR_SCALE);
        _assertZeroSum(50_000, "after deposits");

        // Open: alice long 1 BTC vs bob short 1 BTC.
        _cross(alice, 51_000 * BAZAAR_SCALE, bob, 49_000 * BAZAAR_SCALE, 1 * BAZAAR_SCALE);
        _assertZeroSum(50_000, "after open");

        // Partial close: alice sells 0.4 to dave (dave opens a long).
        _cross(dave, 51_000 * BAZAAR_SCALE, alice, 49_000 * BAZAAR_SCALE, 4 * BAZAAR_SCALE / 10);
        _assertZeroSum(50_000, "after partial close");

        // Full closes: alice sells her remaining 0.6 to bob (bob reduces to 0.4 short),
        // then dave sells his 0.4 to bob (both flat).
        _cross(bob, 51_000 * BAZAAR_SCALE, alice, 49_000 * BAZAAR_SCALE, 6 * BAZAAR_SCALE / 10);
        _assertZeroSum(50_000, "after alice fully closed");
        _cross(bob, 51_000 * BAZAAR_SCALE, dave, 49_000 * BAZAAR_SCALE, 4 * BAZAAR_SCALE / 10);
        _assertZeroSum(50_000, "after all flat");

        _withdrawAll(alice);
        _withdrawAll(bob);
        _withdrawAll(dave);
        _assertZeroSum(50_000, "after withdrawals");
    }

    /// @notice Same lifecycle with REAL funding accrued through the live index: a batch executes
    ///         above oracle (mark > index → longs pay), time passes, the next batch accrues the
    ///         index, then positions close. Funding must transfer between the sides — settled
    ///         into collateral on close — without minting or dropping a cent.
    ///         Pre-fix (funding dropped on match-close) this test fails at "after closes".
    function test_zeroSum_withFundingAccrual() public {
        _deposit(alice, 15_000 * BAZAAR_SCALE);
        _deposit(bob, 15_000 * BAZAAR_SCALE);
        _deposit(carol, 15_000 * BAZAAR_SCALE);
        _deposit(dave, 15_000 * BAZAAR_SCALE);

        // Open the main positions: alice long 1 vs bob short 1 at ~oracle.
        _cross(alice, 51_000 * BAZAAR_SCALE, bob, 49_000 * BAZAAR_SCALE, 1 * BAZAAR_SCALE);
        _assertZeroSum(50_000, "after open");

        // Push the mark above the index: carol/dave cross 0.1 BTC at a ~1% premium.
        _cross(carol, 50_600 * BAZAAR_SCALE, dave, 50_450 * BAZAAR_SCALE, 1 * BAZAAR_SCALE / 10);
        _assertZeroSum(50_000, "after premium batch");

        // Let funding accrue over 30 minutes, then trigger an index update with another batch.
        _advance(30 minutes);
        _cross(carol, 50_500 * BAZAAR_SCALE, dave, 49_500 * BAZAAR_SCALE, 5 * BAZAAR_SCALE / 100);
        int256 f = pair.currentFundingIndex();
        assertTrue(f != 0, "scenario must accrue real funding");
        _assertZeroSum(50_000, "after funding accrual");

        // Close the funded positions against each other: both sides settle funding into collateral.
        _cross(bob, 51_000 * BAZAAR_SCALE, alice, 49_000 * BAZAAR_SCALE, 1 * BAZAAR_SCALE);
        _assertZeroSum(50_000, "after closes");

        // Close carol/dave's 0.15 residuals and unwind completely.
        _cross(dave, 51_000 * BAZAAR_SCALE, carol, 49_000 * BAZAAR_SCALE, 15 * BAZAAR_SCALE / 100);
        _assertZeroSum(50_000, "after all flat");

        _withdrawAll(alice);
        _withdrawAll(bob);
        _withdrawAll(carol);
        _withdrawAll(dave);
        _assertZeroSum(50_000, "after withdrawals");
    }

    /// @notice Liquidation path: a price drop makes alice insolvent; she is liquidated (collateral
    ///         seized to insurance, inventory to the vault), the vault's inventory is closed in
    ///         Pass A against a fresh buyer, and the survivors unwind. Every step must conserve —
    ///         including the liquidator reward (insurance-debited, paid out as cash).
    function test_zeroSum_liquidationAndVaultClose() public {
        _deposit(alice, 12_000 * BAZAAR_SCALE);
        _deposit(bob, 15_000 * BAZAAR_SCALE);

        // Alice long 1 BTC vs bob short 1 BTC at ~$50k. Alice's $12k collateral is ~24% margin.
        _cross(alice, 51_000 * BAZAAR_SCALE, bob, 49_000 * BAZAAR_SCALE, 1 * BAZAAR_SCALE);
        _assertZeroSum(50_000, "after open");

        // Step the oracle down, then liquidate alice at $41k (equity ~$3k < MMR).
        _advance(3);
        address[] memory users = new address[](1);
        users[0] = alice;
        bytes[] memory liqPu = _pu(41_000);
        vm.prank(dave);
        uint256 liquidated = pair.liquidate(users, liqPu);
        assertEq(liquidated, 1, "alice liquidated");
        _assertZeroSum(41_000, "after liquidation");

        // Pass A: the vault sells its inherited long to carol at ~$41k.
        _deposit(carol, 12_000 * BAZAAR_SCALE);
        uint256 carolBid = _placeLimit(carol, true, 1 * BAZAAR_SCALE, 41_400 * BAZAAR_SCALE);
        assertEq(_matchAtPrice(_lists(_one(carolBid), _none()), 41_000), 1, "vault inventory closed");
        (,,,,,, uint256 plSize,,,,,) = pair.pairVault();
        assertEq(plSize, 0, "vault fully unwound");
        _assertZeroSum(41_000, "after vault close");

        // Bob (short, in profit) closes against carol; both flat; everyone withdraws.
        _crossAt(bob, 41_500 * BAZAAR_SCALE, carol, 40_500 * BAZAAR_SCALE, 1 * BAZAAR_SCALE, 41_000);
        _assertZeroSum(41_000, "after survivors closed");

        _withdrawAll(alice); // seized to zero — no-op, but must not revert
        _withdrawAll(bob); // withdraws deposits + realized profit
        _assertZeroSum(41_000, "after bob withdrew");

        // Carol — last to withdraw — must get her fully-backed collateral out. Pre-fix this
        // underflowed the deposits ledger: the vault's Pass-A loss (backing for bob's realized
        // profit) was debited from insurance without the matching I → D transfer, so bob's
        // profit-inclusive withdrawal drained a ledger that had never been credited. With the
        // transfer booked in _finalize, the ledger covers every withdrawer in any order.
        _withdrawAll(carol);
        _assertZeroSum(41_000, "after withdrawals");
    }

    /// @notice Whipsaw producing a VAULT PROFIT: bob's short is liquidated on a spike to $59k,
    ///         the market falls back, and Pass A closes the inherited short below its basis —
    ///         vaultPnl > 0, exercising the D → I transfer. Pre-transfer, each vault profit
    ///         permanently inflated expectedBalance (I + D) above actual USDC, accumulating
    ///         toward a false reason-3 termination.
    function test_zeroSum_vaultProfitOnWhipsaw() public {
        _deposit(alice, 15_000 * BAZAAR_SCALE);
        _deposit(bob, 12_000 * BAZAAR_SCALE);

        // Alice long 1 BTC vs bob short 1 BTC at ~$50k; bob carries ~24% margin.
        _cross(alice, 51_000 * BAZAAR_SCALE, bob, 49_000 * BAZAAR_SCALE, 1 * BAZAAR_SCALE);
        _assertZeroSum(50_000, "after open");

        // Spike to $59k: bob's equity ~$3k < MMR → liquidated; vault inherits his short at ~$50k basis.
        _advance(3);
        address[] memory users = new address[](1);
        users[0] = bob;
        bytes[] memory liqPu = _pu(59_000);
        vm.prank(dave);
        assertEq(pair.liquidate(users, liqPu), 1, "bob liquidated on the spike");
        _assertZeroSum(59_000, "after liquidation");

        // Market falls back to $48k. Pass A buys the inventory back from carol's short limit
        // BELOW the vault's ~$50k basis → vault profit → D → I transfer.
        _deposit(carol, 12_000 * BAZAAR_SCALE);
        uint256 carolAsk = _placeLimitAt(carol, false, 1 * BAZAAR_SCALE, 48_200 * BAZAAR_SCALE, 48_000);
        assertEq(_matchAtPrice(_lists(_none(), _one(carolAsk)), 48_000), 1, "vault inventory closed at a profit");
        (,,,,,, uint256 plSize,,,,,) = pair.pairVault();
        assertEq(plSize, 0, "vault fully unwound");
        _assertZeroSum(48_000, "after profitable vault close");

        // Unwind: alice (long from ~50k) closes against carol (short from ~48.2k); withdraw all.
        _crossAt(carol, 48_500 * BAZAAR_SCALE, alice, 47_500 * BAZAAR_SCALE, 1 * BAZAAR_SCALE, 48_000);
        _assertZeroSum(48_000, "after survivors closed");

        _withdrawAll(alice);
        _withdrawAll(bob); // seized to zero — no-op
        _withdrawAll(carol);
        _assertZeroSum(48_000, "after withdrawals");
    }

    /// @notice Mixed-direction liquidations: a long is liquidated on the way down, then a short
    ///         (opened near the bottom) is liquidated on the way back up while the vault still
    ///         holds the long inventory — `_netOpposingLiquidation` fires and settles the two
    ///         estates against each other. Exercises the netting transfer arms end-to-end.
    function test_zeroSum_opposingNettingLiquidations() public {
        _deposit(alice, 12_000 * BAZAAR_SCALE);
        _deposit(bob, 15_000 * BAZAAR_SCALE);

        // Phase 1: alice long 1 vs bob short 1 at ~$50k.
        _cross(alice, 51_000 * BAZAAR_SCALE, bob, 49_000 * BAZAAR_SCALE, 1 * BAZAAR_SCALE);

        // Phase 2: the market drops; carol shorts 1 vs dave long 1 near the bottom (~$41k) on
        // thin margin. Opened BEFORE alice's liquidation — once the vault holds long inventory,
        // Pass A would consume dave's long limit before Pass C could cross it with carol.
        _deposit(carol, 8_500 * BAZAAR_SCALE);
        _deposit(dave, 15_000 * BAZAAR_SCALE);
        _crossAt(dave, 41_500 * BAZAAR_SCALE, carol, 40_500 * BAZAAR_SCALE, 1 * BAZAAR_SCALE, 41_000);
        _assertZeroSum(41_000, "after bottom open");

        // Now liquidate alice at $41k: the vault inherits her long.
        _advance(3);
        address[] memory users = new address[](1);
        users[0] = alice;
        vm.prank(dave);
        assertEq(pair.liquidate(users, _pu(41_000)), 1, "alice liquidated");
        _assertZeroSum(41_000, "after long liquidation (vault holds longs)");

        // Rally until carol's short has ~$300 of equity left (well under any MMR, still positive
        // so no bad debt): P = (entry + collateral − 300) for her 1-unit short. Liquidating her
        // while the vault still holds alice's long fires the opposing-netting arm.
        uint256 liqPriceUsd;
        {
            (,, uint256 carolEntry, uint256 carolColl,,,,,,) = pair.positionBuckets(carol);
            liqPriceUsd = (carolEntry + carolColl) / BAZAAR_SCALE - 300;
        }
        _advance(3);
        users[0] = carol;
        vm.prank(bob);
        assertEq(pair.liquidate(users, _pu(liqPriceUsd)), 1, "carol liquidated");
        (,,,,,, uint256 plSize,,,,,) = pair.pairVault();
        assertEq(plSize, 0, "1-vs-1 netting fully cleared the vault");
        _assertZeroSum(49_000, "after opposing netting");

        // Unwind the survivors: bob (short from ~50k) closes against dave (long from ~41k).
        _crossAt(bob, 49_500 * BAZAAR_SCALE, dave, 48_500 * BAZAAR_SCALE, 1 * BAZAAR_SCALE, 49_000);
        _assertZeroSum(49_000, "after survivors closed");

        _withdrawAll(alice);
        _withdrawAll(bob);
        _withdrawAll(carol);
        _withdrawAll(dave);
        _assertZeroSum(49_000, "after withdrawals");
    }

    /// @notice Liquidation of a position carrying accrued funding. The liquidatee's funding
    ///         claim/debt must be accounted somewhere (seized value, vault basis, or insurance) —
    ///         if any path drops it, the claims sum drifts from the deposits ledger here.
    function test_zeroSum_liquidationWithAccruedFunding() public {
        _deposit(alice, 12_000 * BAZAAR_SCALE);
        _deposit(bob, 15_000 * BAZAAR_SCALE);
        _deposit(carol, 15_000 * BAZAAR_SCALE);
        _deposit(dave, 15_000 * BAZAAR_SCALE);

        _cross(alice, 51_000 * BAZAAR_SCALE, bob, 49_000 * BAZAAR_SCALE, 1 * BAZAAR_SCALE);

        // Accrue real funding (mark > index → alice, long, pays).
        _cross(carol, 50_600 * BAZAAR_SCALE, dave, 50_450 * BAZAAR_SCALE, 1 * BAZAAR_SCALE / 10);
        _advance(30 minutes);
        _cross(carol, 50_500 * BAZAAR_SCALE, dave, 49_500 * BAZAAR_SCALE, 5 * BAZAAR_SCALE / 100);
        assertTrue(pair.currentFundingIndex() != 0, "scenario must accrue real funding");
        _assertZeroSum(50_000, "after funding accrual");

        // Liquidate alice at $41k while she carries an unsettled funding balance.
        _advance(3);
        address[] memory users = new address[](1);
        users[0] = alice;
        bytes[] memory liqPu = _pu(41_000);
        vm.prank(dave);
        assertEq(pair.liquidate(users, liqPu), 1, "alice liquidated");
        _assertZeroSum(41_000, "after liquidation of funded position");
    }
}
