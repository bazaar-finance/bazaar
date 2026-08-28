// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

/// @dev Stateful fuzzing handler. Drives deposit / withdraw / crossing-trade sequences over four
///      actors at a FIXED $50k oracle price. Fixed price + generous collateral keeps every position
///      solvent (equity == collateral, no PnL drift), so no liquidation or bad debt ever fires — the
///      handler stays in the regime where BOTH the Check-3 solvency and the full zero-sum invariant
///      must hold. Every pair call is wrapped in try/catch so an occasional legitimate revert (thin
///      margin, dust order) advances the sequence instead of aborting the run.
contract ZeroSumHandler is Test {
    bytes32 constant FEED = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    int32 constant EXPO = -8;
    uint256 constant SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;

    BazaarPair internal pair;
    MockUSDC internal usdc;
    MockPyth internal mockPyth;
    address[] internal traders;

    uint256 public ghostDeposits;
    uint256 public ghostWithdrawals;
    /// @dev Counts successful order placements. Each placement runs at most one matching walk,
    ///      so payout-truncation dust is bounded by a small multiple of this count.
    uint256 public ghostTrades;

    uint256 internal idProbe;

    constructor(BazaarPair _pair, MockUSDC _usdc, MockPyth _pyth, address[] memory _traders) {
        pair = _pair;
        usdc = _usdc;
        mockPyth = _pyth;
        traders = _traders;
        vm.deal(address(this), 100 ether);
    }

    function _pu(uint256 priceUsd) internal view returns (bytes[] memory pu) {
        uint64 pt = uint64(vm.getBlockTimestamp());
        int64 px = int64(int256(priceUsd * 1e8));
        uint64 conf = uint64(priceUsd * 1e8 / 1000);
        bytes memory d = mockPyth.createPriceFeedUpdateData(FEED, px, conf, EXPO, px, conf, pt, pt > 0 ? pt - 1 : 0);
        pu = new bytes[](1);
        pu[0] = d;
    }

    function _ensureCollateral(address u, uint256 target) internal {
        (,,, uint256 coll,,,,,) = pair.positionBuckets(u);
        if (coll >= target) return;
        uint256 needBaz = target - coll;
        uint256 usdcNeed = needBaz * USDC_SCALE / SCALE;
        if (usdc.balanceOf(u) < usdcNeed) return;
        vm.startPrank(u);
        usdc.approve(address(pair), usdcNeed);
        try pair.depositCollateral(needBaz, 0, 0, 0, "", "") {
            ghostDeposits++;
        } catch {}
        vm.stopPrank();
    }

    // ---- fuzzer entrypoints ----

    function deposit(uint256 actorSeed, uint256 amtSeed) public {
        address a = traders[bound(actorSeed, 0, traders.length - 1)];
        uint256 bal = usdc.balanceOf(a);
        if (bal < 1e6) return;
        uint256 amtBaz = bound(amtSeed, 1e18, bal * 1e12);
        vm.startPrank(a);
        usdc.approve(address(pair), amtBaz * USDC_SCALE / SCALE);
        try pair.depositCollateral(amtBaz, 0, 0, 0, "", "") {
            ghostDeposits++;
        } catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 amtSeed) public {
        address a = traders[bound(actorSeed, 0, traders.length - 1)];
        (, uint256 size,, uint256 coll,,,,,) = pair.positionBuckets(a);
        if (size != 0 || coll < 1e18) return; // flat users only: empty price update suffices
        uint256 amtBaz = bound(amtSeed, 1e18, coll);
        amtBaz -= amtBaz % 1e12; // round to USDC granularity
        if (amtBaz == 0) return;
        vm.prank(a);
        try pair.withdrawCollateral(amtBaz, new bytes[](0), 0, 0, 0, "") {
            ghostWithdrawals++;
        } catch {}
    }

    /// @dev Rest a long at $51k, then arrive a crossing short at $49k — the arrival fills at the
    ///      resting maker's price inside its own createOrder. Leftover resting orders from
    ///      margin-failed halves simply become makers for later trades, which widens the state
    ///      space the invariants are checked over.
    function trade(uint256 lSeed, uint256 sSeed, uint256 sizeSeed) public {
        address L = traders[bound(lSeed, 0, traders.length - 1)];
        address S = traders[bound(sSeed, 0, traders.length - 1)];
        if (L == S) return;
        _ensureCollateral(L, 30_000 * SCALE);
        _ensureCollateral(S, 30_000 * SCALE);
        uint256 size = bound(sizeSeed, 1e16, 2e17); // 0.01 - 0.2 BTC

        vm.warp(vm.getBlockTimestamp() + 3);
        _place(L, true, size, 51_000 * SCALE);
        vm.warp(vm.getBlockTimestamp() + 3);
        _place(S, false, size, 49_000 * SCALE);
    }

    function _place(address u, bool isLong, uint256 size, uint256 px) internal {
        bytes[] memory pu = _pu(50_000);
        BazaarTypes.OrderSpec memory spec;
        spec.orderType = BazaarTypes.OrderType.Limit;
        spec.isLong = isLong;
        spec.size = size;
        spec.limitPrice = px;
        spec.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        BazaarTypes.MatchHints memory hints;
        vm.prank(u);
        try pair.createOrder(spec, hints, pu, 0, 0, 0, "") {
            ghostTrades++;
        } catch {}
    }
}

/// @notice Drives randomized deposit/trade/withdraw sequences and asserts the two books
///         invariants after every call — catching D-drift, dropped fees, or PnL credited without
///         a debit that fixed-checkpoint scenario tests can miss.
contract ZeroSumHandlerInvariantTest is IntegrationBase {
    ZeroSumHandler internal handler;
    address[] internal actors;

    function setUp() public override {
        super.setUp();
        actors = new address[](4);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = dave;
        handler = new ZeroSumHandler(pair, usdc, mockPyth, actors);
        targetContract(address(handler));
    }

    /// @dev Trader equity marked at (price p, funding index f). Mirrors ZeroSumInvariantTest.
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

    /// @dev Vault pendingLiq inventory marked at (p, f). Mirrors ZeroSumInvariantTest.
    function _vaultInventoryAt(uint256 p, int256 f) internal view returns (int256 value) {
        (,,,,,, uint256 plSize, uint256 plEntry,, int256 plFundIdx, bool plIsLong,) = pair.pairVault();
        if (plSize == 0) return 0;
        int256 notional = int256(plSize * p / BAZAAR_SCALE);
        int256 pricePnl = plIsLong ? notional - int256(plEntry) : int256(plEntry) - notional;
        int256 rawFunding = (f - plFundIdx) * int256(plSize) / int256(BAZAAR_SCALE);
        int256 windowFunding = plIsLong ? -rawFunding : rawFunding;
        value = pricePnl + windowFunding;
    }

    /// @notice Check-3 solvency: the contract always holds at least I + D of USDC (minus rounding),
    ///         at every point in any deposit/trade/withdraw sequence.
    function invariant_check3Solvency() public view {
        assertGe(_cashBaz() + BOOKS_TOL, _ledgerBaz(), "cash >= I + D (Check-3)");
    }

    /// @notice Full zero-sum conservation: Σ trader equity + vault inventory + insurance == actual
    ///         USDC held. Marked at the fixed $50k price (conservation is price-independent). deficit
    ///         must stay 0 — the handler never enters the bad-debt regime.
    function invariant_zeroSum() public view {
        (,,,,, uint256 I,,,,,, uint256 deficit) = pair.pairVault();
        assertEq(deficit, 0, "no realized bad debt in the healthy-margin handler");
        uint256 p = 50_000 * BAZAAR_SCALE;
        int256 f = pair.currentFundingIndex();
        int256 claims = int256(I);
        for (uint256 i = 0; i < actors.length; i++) {
            claims += _equityAt(actors[i], p, f);
        }
        claims += _vaultInventoryAt(p, f);
        int256 cash = int256(usdc.balanceOf(address(pair)) * 1e12);

        // The two directions are NOT equally safe, so they get different bounds:
        //
        //  - VALUE CREATION (claims > cash): the insolvency-risk direction — the books would owe
        //    more than the contract holds. Truncation dust NEVER pushes this way (the contract keeps
        //    the sub-unit remainder), so this bound stays TIGHT and fixed regardless of fill count.
        //    A per-fill value-minting bug cannot hide behind the activity-scaled band here.
        //
        //  - VALUE DESTRUCTION beyond dust (claims << cash): the benign direction where legitimate
        //    1e18->1e6 payout truncation accumulates. Each successful placement runs at most one
        //    walk with at most one truncating payout (the bug-bounty skim), so the band scales
        //    with ghostTrades (reset to 0 per run via the state snapshot). A real dropped
        //    funding/PnL leak would be dollars — orders of magnitude above this dust band.
        int256 mintBand = 1e13; // tight: value never minted
        int256 dustBand = int256(1e13 + handler.ghostTrades() * 2e12); // scaled: benign truncation
        assertLe(claims, cash + mintBand, "no value minted (claims <= cash + dust)");
        assertGe(claims, cash - dustBand, "no value destroyed beyond truncation dust");
    }
}
