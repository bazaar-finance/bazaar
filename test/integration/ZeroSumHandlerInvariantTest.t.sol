// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairLens} from "../../src/BazaarPairLens.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

/// @dev Stateful fuzzing handler. Drives deposit / withdraw / crossing-trade sequences over four
///      actors at a FIXED oracle price. Holding the oracle still is what keeps the run inside the
///      regime where BOTH the Check-3 solvency and the full zero-sum invariant must hold: no
///      position can drift into insolvency on its own, so no liquidation and no bad debt ever
///      fires. Fills still print away from that mark — the fill price is fuzzed across the whole
///      legal placement band — but the fill gate charges the mark-vs-fill gap to the overpaying
///      side up front or refuses the fill, so an off-mark fill is solvent by construction rather
///      than by the handler avoiding it.
///
///      Every pair call is wrapped in try/catch so an occasional legitimate revert (thin margin,
///      dust order) advances the sequence instead of aborting the run.
contract ZeroSumHandler is Test {
    bytes32 constant FEED = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    int32 constant EXPO = -8;
    uint256 constant SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant BP_SCALE = BazaarTypes.BP_SCALE;

    /// @dev The price every update in this handler prints.
    uint256 constant MARK_USD = 50_000;

    BazaarPair internal pair;
    BazaarPairLens internal lens;
    MockUSDC internal usdc;
    MockPyth internal mockPyth;
    address[] internal traders;

    // Per-action coverage counters, asserted by afterInvariant. The invariant profile does not
    // fail on revert and every call here is caught, so an action that reverts on every single
    // invocation would otherwise leave a green run that exercised nothing it claims to — the
    // counters are what make a widened handler's coverage checkable rather than assumed.
    uint256 public ghostDeposits;
    uint256 public ghostFlatWithdrawals;
    uint256 public ghostOpenWithdrawals;
    /// @dev Withdrawals against an open position that a margin or retention floor refused. Not a
    ///      failure — the draw deliberately straddles the floor — but a run that is ALL rejects
    ///      has not tested the accounting behind a successful one, which is why the two are
    ///      counted apart.
    uint256 public ghostOpenWithdrawRejects;
    /// @dev Counts successful order placements. Each placement runs at most one matching walk,
    ///      so payout-truncation dust is bounded by a small multiple of this count.
    uint256 public ghostTrades;
    /// @dev Placements that actually moved the arriving taker's bucket. A placement that merely
    ///      rests proves nothing about settlement, so the walk itself needs its own counter.
    uint256 public ghostFills;

    constructor(BazaarPair _pair, BazaarPairLens _lens, MockUSDC _usdc, MockPyth _pyth, address[] memory _traders) {
        pair = _pair;
        lens = _lens;
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

    /// @dev Pick an actor that is currently flat (or holding a position, per `wantOpen`), starting
    ///      the search at the fuzzed index and wrapping. Choosing the index alone and giving up
    ///      when it does not qualify wastes almost every call of an action once the actors diverge
    ///      — flat actors become rare the moment trading starts, and so do open ones before it —
    ///      which leaves the action credited with calls it never actually ran. Scanning from a
    ///      fuzzed offset keeps the choice random while guaranteeing the action does its work
    ///      whenever any actor qualifies at all.
    /// @return The chosen actor, or address(0) when none qualifies.
    function _pickActor(uint256 seed, bool wantOpen) internal view returns (address) {
        uint256 n = traders.length;
        uint256 start = bound(seed, 0, n - 1);
        for (uint256 i = 0; i < n; i++) {
            address a = traders[(start + i) % n];
            (, uint256 size,, uint256 coll,,,,,) = pair.positionBuckets(a);
            if (coll < 1e18) continue;
            if (wantOpen == (size != 0)) return a;
        }
        return address(0);
    }

    /// @dev The part of a bucket a fill moves. Nothing else in this handler debits a bucket — the
    ///      relayer fee is zero and no trigger fires — so a change across a placement means that
    ///      placement matched.
    function _fingerprint(address u) internal view returns (bytes32) {
        (bool isLong, uint256 size, uint256 entryValue, uint256 coll,,,,,) = pair.positionBuckets(u);
        return keccak256(abi.encode(isLong, size, entryValue, coll));
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
        address a = _pickActor(actorSeed, false); // flat users only: empty price update suffices
        if (a == address(0)) {
            // Every actor that trades ends up holding something, and a size that returns exactly
            // to zero is vanishingly rare with fuzzed fills, so the flat path would go unexercised
            // from the first trade onward. The reserved actor never trades and is topped back up
            // here, which keeps the no-position branch reachable for the whole sequence.
            a = traders[traders.length - 1];
            _ensureCollateral(a, 5_000 * SCALE);
        }
        (,,, uint256 coll,,,,,) = pair.positionBuckets(a);
        if (coll < 1e18) return;
        uint256 amtBaz = bound(amtSeed, 1e18, coll);
        amtBaz -= amtBaz % 1e12; // round to USDC granularity
        if (amtBaz == 0) return;
        vm.prank(a);
        try pair.withdrawCollateral(amtBaz, new bytes[](0), 0, 0, 0, "") {
            ghostFlatWithdrawals++;
        } catch {}
    }

    /// @dev Withdraw while holding an open position. This is the branch the flat-user path never
    ///      reaches: it is where the margin check and the retained-collateral floor decide how much
    ///      of a bucket is releasable, and therefore where conservation is hardest to get right —
    ///      cash leaves the contract while a claim on it stays open. A position holder must supply
    ///      a fresh price, so this action carries one.
    ///
    ///      The amount alternates between two draws on a seed bit, because neither alone exercises
    ///      the branch. Drawing across the whole bucket probes the floor — most of that range sits
    ///      above what a position may release — but a sequence whose positions all opened far from
    ///      the mark has almost nothing releasable, so every draw is refused and the accounting
    ///      behind a SUCCESSFUL release goes untested for the whole run. Drawing inside the quoted
    ///      maximum guarantees the release path runs. Keeping both means the floor is probed and
    ///      the cash-leaves-while-a-claim-stays-open path is reached in every sequence.
    function withdrawAgainstPosition(uint256 actorSeed, uint256 amtSeed) public {
        address a = _pickActor(actorSeed, true);
        if (a == address(0)) return;
        (,,, uint256 coll,,,,,) = pair.positionBuckets(a);
        uint256 ceiling = coll;
        if (amtSeed & 1 == 0) {
            uint256 releasable = lens.getMaxWithdrawable(address(pair), a, MARK_USD * SCALE);
            if (releasable < 1e18) return;
            ceiling = releasable;
        }
        uint256 amtBaz = bound(amtSeed, 1e18, ceiling);
        amtBaz -= amtBaz % 1e12; // round to USDC granularity
        if (amtBaz == 0) return;

        vm.warp(vm.getBlockTimestamp() + 3);
        bytes[] memory pu = _pu(MARK_USD); // built before the prank: the mockPyth call consumes one
        vm.prank(a);
        try pair.withdrawCollateral(amtBaz, pu, 0, 0, 0, "") {
            ghostOpenWithdrawals++;
        } catch {
            ghostOpenWithdrawRejects++;
        }
    }

    /// @dev Rest a long, then arrive a crossing short — the arrival fills at the resting maker's
    ///      price inside its own createOrder. The fill price and both actors' collateral are
    ///      fuzzed. Drawing the fill price from the whole legal placement band, rather than from
    ///      beside the mark, is what puts the walk through fills the mark says are badly priced:
    ///      the gap has to be charged to the overpaying side or the fill refused, and either way
    ///      none of it may land on another trader. Leftover resting orders from margin-failed
    ///      halves become makers for later trades, which widens the state space further.
    function trade(uint256 lSeed, uint256 sSeed, uint256 sizeSeed, uint256 priceSeed, uint256 collSeed) public {
        // The last actor is reserved as a pure depositor and is never given a position — see
        // withdraw() for why the flat branch needs one actor held back.
        uint256 lastTradeable = traders.length - 2;
        address L = traders[bound(lSeed, 0, lastTradeable)];
        address S = traders[bound(sSeed, 0, lastTradeable)];
        if (L == S) return;
        _ensureCollateral(L, bound(collSeed, 1_000 * SCALE, 30_000 * SCALE));
        _ensureCollateral(S, bound(collSeed, 1_000 * SCALE, 30_000 * SCALE));
        uint256 size = bound(sizeSeed, 1e16, 2e17); // 0.01 - 0.2 BTC

        // The band createOrder enforces on a Limit placement, inclusive at both ends.
        uint256 mark = MARK_USD * SCALE;
        uint256 lo = mark * (BP_SCALE - BazaarTypes.MAX_PLACEMENT_DEVIATION_BP) / BP_SCALE;
        uint256 hi = mark * (BP_SCALE + BazaarTypes.MAX_PLACEMENT_DEVIATION_BP) / BP_SCALE;
        // Cross by construction: the ask sits one wei under the bid, so the two always match and
        // the fill lands at the bid. Drawing the two sides independently would leave most
        // placements resting without a walk ever running, which is the coverage this action exists
        // for; the resting leftovers supply the far-apart book on their own.
        uint256 bid = bound(priceSeed, lo + 1, hi);

        vm.warp(vm.getBlockTimestamp() + 3);
        _place(L, true, size, bid);
        vm.warp(vm.getBlockTimestamp() + 3);
        bytes32 takerBefore = _fingerprint(S);
        _place(S, false, size, bid - 1);
        if (_fingerprint(S) != takerBefore) ghostFills++;
    }

    function _place(address u, bool isLong, uint256 size, uint256 px) internal {
        bytes[] memory pu = _pu(MARK_USD);
        BazaarTypes.OrderSpec memory spec;
        spec.orderType = BazaarTypes.OrderType.Limit;
        spec.isLong = isLong;
        spec.size = size;
        spec.limitPrice = px;
        spec.expirationBlock = uint64(vm.getBlockNumber() + 500_000);
        BazaarTypes.MatchHints memory hints;
        vm.prank(u);
        try pair.createOrder(spec, hints, pu, 0, 0, 0, "", "") {
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
        handler = new ZeroSumHandler(pair, lens, usdc, mockPyth, actors);
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
        (,,,,,, uint256 plSize, uint256 plEntry,, int256 plFundIdx, bool plIsLong,,,) = pair.pairVault();
        if (plSize == 0) return 0;
        int256 notional = int256(plSize * p / BAZAAR_SCALE);
        int256 pricePnl = plIsLong ? notional - int256(plEntry) : int256(plEntry) - notional;
        int256 rawFunding = (f - plFundIdx) * int256(plSize) / int256(BAZAAR_SCALE);
        int256 windowFunding = plIsLong ? -rawFunding : rawFunding;
        value = pricePnl + windowFunding;
    }

    /// @dev The mark every leg of the conservation sum is valued at. Conservation does not depend
    ///      on WHICH price is chosen — only on one price valuing every leg — so this reads the
    ///      pair's own stored mark rather than restating the handler's constant, and stays correct
    ///      for a handler that moves the oracle. Falls back only before any price is stored.
    function _markPrice() internal view returns (uint256 p) {
        (p,,,,) = pair.lastPairPrice();
        if (p == 0) p = 50_000 * BAZAAR_SCALE;
    }

    /// @notice Check-3 solvency: the contract always holds at least I + D of USDC (minus rounding),
    ///         at every point in any deposit/trade/withdraw sequence.
    function invariant_check3Solvency() public view {
        assertGe(_cashBaz() + BOOKS_TOL, _ledgerBaz(), "cash >= I + D (Check-3)");
    }

    /// @notice Full zero-sum conservation: Σ trader equity + vault inventory + insurance == actual
    ///         USDC held, marked at the pair's own price. deficit must stay 0 — the fixed oracle
    ///         keeps the handler out of the bad-debt regime.
    function invariant_zeroSum() public view {
        (,,,,, uint256 I,,,,,, uint256 deficit,,) = pair.pairVault();
        assertEq(deficit, 0, "no realized bad debt in the healthy-margin handler");
        uint256 p = _markPrice();
        int256 f = pair.currentFundingIndex();
        // Earned-but-unclaimed fees are a third-party claim on cash the contract still holds,
        // so they count as claims until someone calls claimFees.
        int256 claims = int256(I) + int256(_escrowTotal());
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

    /// @notice The open-interest aggregates are exactly the sum of the actors' position sizes,
    ///         per side, after every operation. finalizeTermination's completeness gate reads
    ///         these aggregates: drift above the true sum would hold a termination until the
    ///         escape hatch, drift below would let it finalize with positions still open.
    ///         Sizes never pass through a division on any path, so the match must be exact.
    function invariant_openInterestMatchesPositions() public view {
        uint256 longSum;
        uint256 shortSum;
        for (uint256 i = 0; i < actors.length; i++) {
            (bool isLong, uint256 size,,,,,,,) = pair.positionBuckets(actors[i]);
            if (isLong) longSum += size;
            else shortSum += size;
        }
        (uint256 totalLongOI, uint256 totalShortOI,,,,,,,,,,,,) = pair.pairVault();
        assertEq(totalLongOI, longSum, "totalLongOI == sum of long position sizes");
        assertEq(totalShortOI, shortSum, "totalShortOI == sum of short position sizes");
    }

    /// @notice Every handler action reached its success path at least once in this run.
    /// @dev The invariants above are all one-directional safety properties: they pass trivially
    ///      over a sequence in which nothing happened. Combined with a profile that does not fail
    ///      on revert and a handler that catches every call, that makes an action which reverts on
    ///      every invocation completely silent — the run stays green and the coverage it is
    ///      credited with is imaginary. Asserting the counters here is what converts that failure
    ///      mode from invisible to loud. Runs once per sequence, against counters the per-run state
    ///      snapshot resets.
    function afterInvariant() public view {
        assertGt(handler.ghostDeposits(), 0, "no deposit landed");
        assertGt(handler.ghostTrades(), 0, "no order was placed");
        assertGt(handler.ghostFills(), 0, "no placement ever matched");
        assertGt(handler.ghostFlatWithdrawals(), 0, "no flat-user withdrawal landed");
        assertGt(handler.ghostOpenWithdrawals(), 0, "no withdrawal against an open position landed");
    }
}
