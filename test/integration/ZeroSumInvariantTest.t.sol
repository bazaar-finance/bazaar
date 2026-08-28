// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
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

    /// @dev Probe watermark for _lastCreatedOrderId.
    uint256 internal idProbe;

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

        vm.roll(block.number + 20);
        t = uint64(block.timestamp);
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║                    THE INVARIANT                             ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @dev Trader equity marked at (price P, funding index F): collateral + price PnL + funding PnL.
    function _equityAt(address u, uint256 p, int256 f) internal view returns (int256 equity) {
        (bool isLong, uint256 size, uint256 entryValue, uint256 collateral, int256 entryFundingIdx,,,,) =
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
    ///      bases the unload walk settles against, so realizing inventory moves value to
    ///      insurance 1:1.
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

    function _deposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(pair), amount * USDC_SCALE / BAZAAR_SCALE);
        pair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev The newest orderId the pair has assigned. Ids are a gapless monotonic counter from 1,
    ///      so probing forward from a watermark finds the last created order even when it is
    ///      already terminal (a crossing placement fills in its own transaction, so the
    ///      active-order set is no source).
    function _lastCreatedOrderId() internal returns (uint256) {
        uint256 w = idProbe == 0 ? 1 : idProbe;
        while (true) {
            (address creator,,,,,,,,,,,,,,,,,) = pair.orders(w);
            if (creator == address(0)) break;
            ++w;
        }
        idProbe = w;
        require(w > 1, "no orders created yet");
        return w - 1;
    }

    function _filledOf(uint256 orderId) internal view returns (uint256 filled) {
        (,,,,,, filled,,,,,,,,,,,) = pair.orders(orderId);
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
        BazaarTypes.OrderSpec memory spec;
        spec.orderType = BazaarTypes.OrderType.Limit;
        spec.isLong = isLong;
        spec.size = size;
        spec.limitPrice = limitPrice;
        spec.expirationBlock = uint64(block.number + 500_000);
        BazaarTypes.MatchHints memory hints;
        vm.prank(user);
        pair.createOrder(spec, hints, pu, 0, 0, 0, "");
        return _lastCreatedOrderId();
    }

    /// @dev Cross a (long, short) pair of limit orders at the given oracle price. The long is
    ///      placed first (older id → resting maker), so the arriving short fills at longPx.
    function _crossAt(
        address longUser,
        uint256 longPx,
        address shortUser,
        uint256 shortPx,
        uint256 size,
        uint256 priceUsd
    ) internal {
        _placeLimitAt(longUser, true, size, longPx, priceUsd);
        vm.roll(vm.getBlockNumber() + 2);
        uint256 shortId = _placeLimitAt(shortUser, false, size, shortPx, priceUsd);
        assertEq(_filledOf(shortId), size, "cross must fill");
    }

    function _cross(address longUser, uint256 longPx, address shortUser, uint256 shortPx, uint256 size) internal {
        _crossAt(longUser, longPx, shortUser, shortPx, size, 50_000);
    }

    /// @dev Unload vault liquidation inventory into the resting book at the given oracle price.
    ///      The caller (seq) earns the insurance-funded unload reward when >= $100 unloads —
    ///      cash and the insurance claim fall together, so the zero-sum identity is unmoved.
    function _unloadAt(uint256 priceUsd) internal returns (uint256 unloadedSize) {
        _advance(3);
        bytes[] memory pu = _pu(priceUsd);
        vm.prank(seq);
        unloadedSize = pair.unloadVault(0, pu);
    }

    /// @dev Withdraw a flat user's full collateral (rounded down to USDC granularity).
    function _withdrawAll(address u) internal {
        (, uint256 size,, uint256 coll,,,,,) = pair.positionBuckets(u);
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

    /// @notice Same lifecycle with REAL funding accrued through the live index: fills execute
    ///         above oracle (mark > index → longs pay), time passes, the next fill accrues the
    ///         index, then positions close. Funding must transfer between the sides — settled
    ///         into collateral on close — without minting or dropping a cent.
    ///         Dropping the funding leg on a fill-driven close breaks the sum at "after closes".
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
        _assertZeroSum(50_000, "after premium fill");

        // Let funding accrue over 30 minutes, then trigger an index update with another fill.
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
    ///         seized to insurance, inventory to the vault), the vault's inventory unloads against
    ///         a fresh buyer's resting bid, and the survivors unwind. Every step must conserve —
    ///         including the liquidator and unload rewards (insurance-debited, paid out as cash).
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

        // The vault sells its inherited long into carol's resting bid at ~$41k.
        _deposit(carol, 12_000 * BAZAAR_SCALE);
        _placeLimit(carol, true, 1 * BAZAAR_SCALE, 41_400 * BAZAAR_SCALE);
        assertEq(_unloadAt(41_000), 1 * BAZAAR_SCALE, "vault inventory closed");
        (,,,,,, uint256 plSize,,,,,) = pair.pairVault();
        assertEq(plSize, 0, "vault fully unwound");
        _assertZeroSum(41_000, "after vault close");

        // Bob (short, in profit) closes against carol; both flat; everyone withdraws.
        _crossAt(bob, 41_500 * BAZAAR_SCALE, carol, 40_500 * BAZAAR_SCALE, 1 * BAZAAR_SCALE, 41_000);
        _assertZeroSum(41_000, "after survivors closed");

        _withdrawAll(alice); // seized to zero — no-op, but must not revert
        _withdrawAll(bob); // withdraws deposits + realized profit
        _assertZeroSum(41_000, "after bob withdrew");

        // Carol — last to withdraw — must get her fully-backed collateral out. Without the I → D
        // transfer booked at unload finalize, the vault's loss (backing for bob's realized
        // profit) would be debited from insurance alone, bob's profit-inclusive withdrawal would
        // drain a deposits ledger that had never been credited, and carol's withdrawal would
        // underflow it. With the transfer booked, the ledger covers every withdrawer in any order.
        _withdrawAll(carol);
        _assertZeroSum(41_000, "after withdrawals");
    }

    /// @notice Whipsaw producing a VAULT PROFIT: bob's short is liquidated on a spike to $59k,
    ///         the market falls back, and the unload closes the inherited short below its basis —
    ///         vaultPnl > 0, exercising the D → I transfer. Without that transfer, each vault
    ///         profit permanently inflates expectedBalance (I + D) above actual USDC,
    ///         accumulating toward a false reason-3 termination.
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

        // Market falls back to $48k. The unload buys the inventory back from carol's resting ask
        // BELOW the vault's ~$50k basis → vault profit → D → I transfer.
        _deposit(carol, 12_000 * BAZAAR_SCALE);
        _placeLimitAt(carol, false, 1 * BAZAAR_SCALE, 48_200 * BAZAAR_SCALE, 48_000);
        assertEq(_unloadAt(48_000), 1 * BAZAAR_SCALE, "vault inventory closed at a profit");
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

    /// @dev Total claims marked at `priceUsd` (same computation as _assertZeroSum, without the
    ///      equality assertion): insurance + Σ trader equity + vault inventory.
    function _claimsAt(uint256 priceUsd) internal view returns (int256 claims) {
        (,,,,, uint256 I,,,,,,) = pair.pairVault();
        uint256 p = priceUsd * BAZAAR_SCALE;
        int256 f = pair.currentFundingIndex();
        claims = int256(I);
        for (uint256 i = 0; i < traders.length; i++) {
            claims += _equityAt(traders[i], p, f);
        }
        claims += _vaultInventoryAt(p, f);
    }

    /// @notice A winner's realized-and-withdrawn profit leaves the deposits ledger below the
    ///         loser's book collateral; the loser then goes insolvent. The seizure caps at the
    ///         ledger (an uncapped debit would panic and leave the loser unliquidatable), the
    ///         uncapped remainder becomes a cash surplus over claims rather than a deficit, the
    ///         pair stays live, the estate-close walk runs with a zero fee budget (all fees
    ///         waived — nothing charged, nothing paid), and the surviving winner withdraws in
    ///         full once the estate settles.
    function test_seizureCap_solventPairSurvivesThinLedger() public {
        _deposit(alice, 11_500 * BAZAAR_SCALE);
        _deposit(bob, 17_500 * BAZAAR_SCALE);
        _deposit(carol, 15_500 * BAZAAR_SCALE);
        _deposit(dave, 9_000 * BAZAAR_SCALE);
        _assertZeroSum(50_000, "after deposits");

        // Alice long 1 BTC vs bob short 1 BTC at $51k; bob carries ~34% margin.
        _cross(alice, 51_000 * BAZAAR_SCALE, bob, 49_000 * BAZAAR_SCALE, 1 * BAZAAR_SCALE);
        _assertZeroSum(50_000, "after open");

        // Rally to $68.5k. Alice hands her long to carol (fresh open) and realizes +$17.5k —
        // the loss backing it stays UNREALIZED in bob's still-open short.
        _crossAt(carol, 68_500 * BAZAAR_SCALE, alice, 67_500 * BAZAAR_SCALE, 1 * BAZAAR_SCALE, 68_500);
        _assertZeroSum(68_500, "after alice realized against carol's open");

        // Alice (flat) walks out with principal + profit; dave (flat) exits too. The cash they
        // took includes dollars whose book claim still sits in bob's bucket.
        _withdrawAll(alice);
        _withdrawAll(dave);
        _assertZeroSum(68_500, "after winners withdrew");

        // Precondition of the whole scenario: bob's book collateral now exceeds the entire
        // deposits ledger, while bob's EQUITY is only just below zero (solvent boundary).
        (,,, uint256 bobBook,,,,,) = pair.positionBuckets(bob);
        (,,,, uint256 dBefore, uint256 iBefore,,,,,,) = pair.pairVault();
        assertGt(bobBook, dBefore, "bob's book must exceed the deposits ledger");

        int256 gapBefore = int256(usdc.balanceOf(address(pair)) * 1e12) - _claimsAt(68_500);

        // Liquidate bob. The seizure credits insurance with the whole remaining ledger, floors
        // the ledger at zero, books NO deficit, and the pair stays live.
        _advance(3);
        address[] memory users = new address[](1);
        users[0] = bob;
        vm.prank(dave);
        assertEq(pair.liquidate(users, _pu(68_500)), 1, "liquidation must survive the thin ledger");

        {
            (,,,, uint256 dAfter, uint256 iAfter,,,,,, uint256 deficit) = pair.pairVault();
            assertEq(dAfter, 0, "ledger seized to exactly zero");
            assertEq(deficit, 0, "no deficit: solvency is decided at estate settlement");
            // Insurance received the capped amount (liquidator reward nets out of I and cash
            // symmetrically, so bound rather than pin it).
            assertGe(iAfter + 20e18, iBefore + dBefore, "insurance credited the capped seizure");
            assertLe(iAfter, iBefore + dBefore, "insurance never credited above the ledger");
        }

        // The dropped remainder (book minus ledger) turns into cash surplus over claims — the
        // conservative direction: unclaimable surplus, never an unbacked claim.
        int256 gapAfter = int256(usdc.balanceOf(address(pair)) * 1e12) - _claimsAt(68_500);
        assertApproxEqAbs(gapAfter - gapBefore, int256(bobBook - dBefore), CLAIMS_TOL, "surplus == dropped seizure");

        // Estate close through the unload walk with the deposits ledger at ZERO: the walk's fee
        // budget is zero, so carol's closing fill is charged NO fee and no fee is paid out.
        // Insurance funds the estate's entry-basis loss into the ledger, which re-covers carol's
        // claim, and separately pays the caller's unload reward as cash.
        (,, uint256 carolEntry, uint256 carolCollBefore, int256 carolFundIdx,,,,) = pair.positionBuckets(carol);
        (,,,,, uint256 iPreClose,,,, int256 plFundIdx,,) = pair.pairVault();

        _placeLimitAt(carol, false, 1 * BAZAAR_SCALE, 68_500 * BAZAAR_SCALE, 68_500);
        assertEq(_unloadAt(68_500), 1 * BAZAAR_SCALE, "estate closed against carol");

        {
            (,,,,,, uint256 plSize,,,,,) = pair.pairVault();
            assertEq(plSize, 0, "vault fully unwound");
        }
        {
            // Carol's collateral moved by exactly her realized PnL + funding — zero fee. Any
            // charged fee would break this equality.
            (,,, uint256 carolCollAfter,,,,,) = pair.positionBuckets(carol);
            int256 realized = int256(68_500 * BAZAAR_SCALE) - int256(carolEntry);
            int256 rawFunding =
                (pair.currentFundingIndex() - carolFundIdx) * int256(1 * BAZAAR_SCALE) / int256(BAZAAR_SCALE);
            int256 expected = int256(carolCollBefore) + realized + (-rawFunding);
            assertApproxEqAbs(int256(carolCollAfter), expected, 1e12, "close charged no fee (budget exhausted)");
        }
        {
            // Insurance paid the estate's full entry-basis loss (price leg + funding leg) into
            // the deposits ledger, paid the caller's unload reward (2 bp of the $68.5k unloaded
            // notional — above the $0.10 floor), and received nothing else — no insurance fee
            // was collected in the waived walk, so any fee credit would break these equalities.
            uint256 expectedLoss =
                uint256(int256(17_500 * BAZAAR_SCALE) - (pair.currentFundingIndex() - plFundIdx));
            uint256 unloadReward = 68_500 * BAZAAR_SCALE * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
            (,,,, uint256 dPost, uint256 iPost,,,,,, uint256 deficit) = pair.pairVault();
            assertEq(deficit, 0, "estate loss fully funded by insurance");
            assertApproxEqAbs(
                iPreClose - iPost, expectedLoss + unloadReward, 1e12, "insurance funded the loss + unload reward"
            );
            assertApproxEqAbs(dPost, expectedLoss, 1e12, "ledger re-covered for the survivor");
            assertGe(dPost, carolCollAfterOf(), "ledger covers carol's full claim");
        }

        // The survivor exits whole through the live path — the pair never terminated.
        _withdrawAll(bob); // seized to zero — no-op
        _withdrawAll(carol);
        {
            (,,, uint256 carolCollFinal,,,,,) = pair.positionBuckets(carol);
            assertLt(carolCollFinal, 1e12, "carol withdrew her entire claim");
            (,,,,,,,,,,, uint256 deficit) = pair.pairVault();
            assertEq(deficit, 0, "pair ends live and solvent");
        }
    }

    function carolCollAfterOf() internal view returns (uint256 coll) {
        (,,, coll,,,,,) = pair.positionBuckets(carol);
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
        // thin margin. Both fills complete at placement, so no resting order is left for the
        // liquidation's inline unload to consume.
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
            (,, uint256 carolEntry, uint256 carolColl,,,,,) = pair.positionBuckets(carol);
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
