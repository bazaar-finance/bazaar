// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairLens} from "../../src/BazaarPairLens.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";
import {OrderView} from "../OrderView.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

/// @dev Stateful fuzzing handler for the conservation invariants. Drives deposits, withdrawals
///      (flat and against an open position), crossing trades, resting quotes, oracle moves,
///      liquidations, vault unloads and auto-deleveraging over nine actors.
///
///      The design problem this handler exists to solve is that conservation is easy to satisfy in
///      the states that are easy to reach. So it deliberately reaches the awkward ones: fill prices
///      are drawn across the whole legal placement band rather than beside the mark; withdrawals
///      run against open positions, where cash leaves while a claim on it stays open; and the
///      oracle moves far enough to carry leveraged positions through their maintenance margin,
///      which is the only way anything here becomes insolvent and the seizure path runs at all.
///
///      Several parameters are set specifically to keep that reachable, and each is load-bearing
///      rather than incidental — a deposit cap, collateral sized by leverage, and no top-up for an
///      actor who already holds a position. Any of them relaxed buries the book under collateral
///      no price in the band can touch, and the liquidation regime silently stops being covered.
///      The ghost counters exist so that "silently" cannot happen.
///
///      Every pair call is wrapped in try/catch so an occasional legitimate revert (thin margin,
///      dust order, a frozen pair) advances the sequence instead of aborting the run.
contract ZeroSumHandler is Test {
    bytes32 constant FEED = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    int32 constant EXPO = -8;
    uint256 constant SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant BP_SCALE = BazaarTypes.BP_SCALE;

    /// @dev The price every update in this handler prints. Moved by movePrice within a band wide
    ///      enough to carry a leveraged position through its maintenance margin — that is the only
    ///      way this handler produces a liquidation, since nothing else makes a solvent position
    ///      insolvent. Bounded rather than unbounded: realizing bad debt fixes the settlement price
    ///      and freezes the pair, after which only terminal settlement and price stores still run,
    ///      so the band trades some of that reach for sequences that keep exercising the live book.
    ///      Bad debt is still reached inside it, through the size draw in trade().
    uint256 constant MARK_START_USD = 50_000;
    uint256 constant MARK_MIN_USD = 30_000;
    uint256 constant MARK_MAX_USD = 80_000;
    uint256 public markUsd = MARK_START_USD;

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
    /// @dev Sequences reach this counter only when some actor actually held an open position with
    ///      releasable headroom. It separates "the release path is broken" from "this sequence
    ///      never offered a release to make", which is what the coverage assertion has to tell
    ///      apart: positions sitting at their retained-collateral floor have nothing to give back,
    ///      and a run of them is a legitimate shape rather than a dead branch.
    uint256 public ghostOpenWithdrawChances;
    /// @dev Counts successful order placements. Each placement runs at most one matching walk,
    ///      so payout-truncation dust is bounded by a small multiple of this count.
    uint256 public ghostTrades;
    /// @dev Placements that actually moved the arriving taker's bucket. A placement that merely
    ///      rests proves nothing about settlement, so the walk itself needs its own counter.
    uint256 public ghostFills;
    uint256 public ghostPriceMoves;
    /// @dev Positions actually seized, not calls made. The liquidation action submits the whole
    ///      actor list and the pair takes whoever is underwater, so only the returned count says
    ///      whether the regime was reached at all.
    uint256 public ghostLiquidations;
    uint256 public ghostUnloads;
    /// @dev Auto-deleverage batches that closed inventory. A window opens only once the fund can
    ///      no longer absorb the estates, so this counts sequences that reached the ADL regime and
    ///      resolved it, not calls made.
    uint256 public ghostAdlBatches;
    /// @dev Deleverage calls the pair refused for cohort ordering. The handler ranks winners the
    ///      way executeAdl requires — score descending, ties by ascending address — so this must
    ///      stay at zero; a nonzero count means the ADL regime went untested behind the try.
    uint256 public ghostAdlOrderRejects;
    /// @dev High-water mark of realized bad debt seen during the sequence, and whether the pair
    ///      ever froze. Both are outcomes the handler reaches rather than actions it takes, so
    ///      neither can be asserted per sequence without forcing the run to be pathological — they
    ///      are recorded so the regime the suite actually covers is measurable instead of assumed.
    uint256 public ghostMaxDeficit;
    bool public ghostFroze;
    /// @dev Calls that moved the funding index while the vault held inventory. The vault's carry
    ///      on inventory it holds is the one remaining source of realized bad debt, and it is the
    ///      one thing a sequence of three-second steps can never accumulate, so this counts the
    ///      action that supplies it rather than assuming it lands.
    uint256 public ghostFundingAccruals;
    /// @dev How far off the oracle accrueFunding's peg prints. Above MAX_MARK_DEVIATION_BP (the
    ///      band the funding clamp is derived from), so a peg print that rests at this distance
    ///      enters the mark clamped at the band edge, the farthest any print can sit; what it adds
    ///      is its alpha of that edge.
    uint256 constant PREMIUM_BP = 500;
    /// @dev High-water mark of the deferred-liquidation list: opposite-side seizures the fund
    ///      could not afford to net, left open for the auction to close against their own
    ///      counterparties. Reached only when an inventory the fund is already straining under
    ///      meets a reversal deep enough to bankrupt the other side, so it is recorded rather
    ///      than asserted.
    uint256 public ghostMaxDeferred;
    /// @dev Whether an ADL window was open at ANY point in the sequence. Matching and
    ///      position-holder withdrawals are both frozen for as long as one is, so a sequence that
    ///      spent its calls inside a window had no honest opportunity to do either — and the
    ///      window may well have been released again by the last call, which is why the
    ///      end-of-run flag alone cannot stand in for this.
    bool public ghostAdlEverPending;

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
        (,,, uint256 coll,,,) = pair.positionBuckets(u);
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

    /// @dev Top up only a flat actor — see trade() for why an open position is left where the mark
    ///      put it.
    function _fundIfFlat(address u, uint256 target) internal {
        (, uint256 size,,,,,) = pair.positionBuckets(u);
        if (size != 0) return;
        _ensureCollateral(u, target);
    }

    /// @dev Pick an actor that is currently flat (or holding a position, per `wantOpen`), starting
    ///      the search at the fuzzed index and wrapping. Choosing the index alone and giving up
    ///      when it does not qualify wastes almost every call of an action once the actors diverge
    ///      — flat actors become rare the moment trading starts, and so do open ones before it —
    ///      which leaves the action credited with calls it never actually ran. Scanning from a
    ///      fuzzed offset keeps the choice random while guaranteeing the action does its work
    ///      whenever any actor qualifies at all.
    ///
    ///      The reserved last actor is never a candidate. Its callers hand the pick orders
    ///      (_pegMarkAgainstTheVault) or expect a position (withdrawAgainstPosition), and the
    ///      reserved actor must hold neither for withdraw() to rely on it.
    /// @return The chosen actor, or address(0) when none qualifies.
    function _pickActor(uint256 seed, bool wantOpen) internal view returns (address) {
        uint256 n = traders.length - 1;
        uint256 start = bound(seed, 0, n - 1);
        for (uint256 i = 0; i < n; i++) {
            address a = traders[(start + i) % n];
            (, uint256 size,, uint256 coll,,,) = pair.positionBuckets(a);
            if (coll < 1e18) continue;
            if (wantOpen == (size != 0)) return a;
        }
        return address(0);
    }

    /// @dev Pick an actor with collateral and nothing it must keep margin for — no position and no
    ///      live resting order — scanning from the fuzzed offset the way _pickActor does. Resting
    ///      orders disqualify as much as a position: the pair prices any withdrawal from an account
    ///      that holds them, which needs a fresh update, and reserves the orders' margin out of the
    ///      collateral. The reserved last actor is a candidate and qualifies whenever it is funded,
    ///      since no action ever gives it an order or a position.
    /// @return The chosen actor, or address(0) when none qualifies.
    function _pickIdleActor(uint256 seed) internal view returns (address) {
        uint256 n = traders.length;
        uint256 start = bound(seed, 0, n - 1);
        for (uint256 i = 0; i < n; i++) {
            address a = traders[(start + i) % n];
            (, uint256 size,, uint256 coll,,,) = pair.positionBuckets(a);
            if (coll < 1e18 || size != 0) continue;
            (,, uint256 longSize, uint256 shortSize) = lens.outstandingOrderExposure(address(pair), a);
            if (longSize == 0 && shortSize == 0) return a;
        }
        return address(0);
    }

    /// @dev The price the withdrawal path values `isLong`'s position at, which is the price the
    ///      lens requires its withdrawal quote to be taken at: spot less the update's confidence for
    ///      a long, spot plus it for a short. _pu sets the confidence to a thousandth of the price.
    function _withdrawalBracket(bool isLong) internal view returns (uint256) {
        uint256 spot = markUsd * SCALE;
        uint256 conf = spot / 1000;
        return isLong ? spot - conf : spot + conf;
    }

    /// @dev The most funding a withdrawal can charge `size` before its margin check that the lens
    ///      quote does not already see. The lens values a position at the stored funding index;
    ///      the withdrawal first stores this call's price, which advances the index over the time
    ///      since the last stored price at no more than MAX_FUNDING_RATE_CONTINUOUS per
    ///      FUNDING_INTERVAL, credited over at most MAX_FUNDING_AGE. One unit is added for rounding.
    function _fundingAllowance(uint256 size) internal view returns (uint256) {
        (,, uint256 lastTs,,) = pair.lastPairPrice();
        uint256 nowTs = vm.getBlockTimestamp();
        uint256 elapsed = nowTs > lastTs ? nowTs - lastTs : 0;
        if (elapsed > FundingLib.MAX_FUNDING_AGE) elapsed = FundingLib.MAX_FUNDING_AGE;
        uint256 accrual =
            size * markUsd * FundingLib.MAX_FUNDING_RATE_CONTINUOUS * elapsed / (SCALE * FundingLib.FUNDING_INTERVAL);
        return accrual + 1;
    }

    /// @dev The part of a bucket a fill moves. Nothing else in this handler debits a bucket — the
    ///      relayer fee is zero and no trigger fires — so a change across a placement means that
    ///      placement matched.
    function _fingerprint(address u) internal view returns (bytes32) {
        (bool isLong, uint256 size, uint256 entryValue, uint256 coll,,,) = pair.positionBuckets(u);
        return keccak256(abi.encode(isLong, size, entryValue, coll));
    }

    // ---- fuzzer entrypoints ----

    /// @dev Capped well below the actor's balance. Each actor starts with a million USDC, and a
    ///      deposit action free to move all of it buries every position under collateral no price
    ///      inside the band can reach — which silently costs the whole liquidation regime, since
    ///      nothing then ever becomes insolvent for the seizure path to find. The cap is what keeps
    ///      deposits varied without letting one of them end the sequence's usefulness.
    function deposit(uint256 actorSeed, uint256 amtSeed) public {
        address a = traders[bound(actorSeed, 0, traders.length - 1)];
        uint256 bal = usdc.balanceOf(a);
        if (bal < 1e6) return;
        uint256 ceiling = bal * 1e12;
        if (ceiling > 8_000 * SCALE) ceiling = 8_000 * SCALE;
        uint256 amtBaz = bound(amtSeed, 1e18, ceiling);
        vm.startPrank(a);
        usdc.approve(address(pair), amtBaz * USDC_SCALE / SCALE);
        try pair.depositCollateral(amtBaz, 0, 0, 0, "", "") {
            ghostDeposits++;
        } catch {}
        vm.stopPrank();
    }

    /// @dev Withdraw from an idle account (see _pickIdleActor). This action carries an empty price
    ///      update, which only a withdrawal the pair does not price can use; rest() and trade()
    ///      leave position-less accounts holding orders all the time, and picking by position
    ///      alone lands on them and is refused.
    function withdraw(uint256 actorSeed, uint256 amtSeed) public {
        address a = _pickIdleActor(actorSeed);
        if (a == address(0)) {
            // Every actor that trades ends up holding something, and a size that returns exactly
            // to zero is vanishingly rare with fuzzed fills, so the flat path would go unexercised
            // from the first trade onward. The reserved actor never trades and is topped back up
            // here, which keeps the no-position branch reachable for the whole sequence.
            a = traders[traders.length - 1];
            _ensureCollateral(a, 5_000 * SCALE);
        }
        (,,, uint256 coll,,,) = pair.positionBuckets(a);
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
        (bool isLong, uint256 size,, uint256 coll,,,) = pair.positionBuckets(a);
        uint256 ceiling = coll;
        // Same reasoning as the guaranteed first fill: until one release has landed, take the
        // bounded draw, which is the one that cannot be refused for asking too much. That holds
        // only if the quote is priced the way the withdrawal prices the position — at its
        // confidence bracket, less the funding the withdrawal accrues before its check — or a
        // draw near the top of the quote is refused, and a sequence whose only releasable
        // positions sit near their floor registers chances it can never take.
        vm.warp(vm.getBlockTimestamp() + 4);
        bool bounded = amtSeed & 1 == 0 || ghostOpenWithdrawals == 0;
        if (bounded) {
            uint256 releasable = lens.getMaxWithdrawable(address(pair), a, _withdrawalBracket(isLong));
            uint256 allowance = _fundingAllowance(size);
            if (releasable < allowance + 1e12) return;
            ghostOpenWithdrawChances++;
            ceiling = releasable - allowance;
        }
        // Floored at one USDC unit, not one dollar. A leveraged position that the mark has moved
        // against may have only cents of headroom left, and those are the releases most worth
        // following through the accounting — insisting on a dollar would skip exactly the
        // near-floor cases and leave the branch untested whenever the book is under stress.
        //
        // Once one release has landed, half of the bounded draws take almost the whole releasable
        // amount, leaving the position at its floor. That is the position the next small move
        // takes out, and the one whose seizure covers the least of its estate — which is what
        // lets a later netting of two estates outrun the fund and realize bad debt. The guaranteed
        // first draw stays uniform, so every sequence lands an ordinary release before its draws
        // start concentrating on the floor.
        bool toFloor = bounded && ghostOpenWithdrawals > 0 && amtSeed & 2 != 0;
        uint256 amtBaz = toFloor ? ceiling - ceiling / 1000 : bound(amtSeed, 1e12, ceiling);
        amtBaz -= amtBaz % 1e12; // round to USDC granularity
        if (amtBaz == 0) return;

        bytes[] memory pu = _pu(markUsd); // built before the prank: the mockPyth call consumes one
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
        // Sized against the genesis insurance seed, not against the actors' balances. Realized
        // bad debt is booked only where a loss lands on the fund all at once — an opposing
        // liquidation netting two estates — and it needs that loss to outrun the seed plus both
        // estates' seizures. A seizure is the loser's whole bucket: as little as a fifth of the
        // notional at the warmup margin floor, a tenth after a withdrawal against the position.
        // So the netting loss beats the seizures whenever the two entries are far enough apart,
        // and beating the seed on top of that is a matter of size: with positions an order of
        // magnitude below the seed no sequence realizes bad debt however far the mark travels.
        uint256 size = bound(sizeSeed, 5e16, 1e18); // 0.05 - 1 BTC

        // Fund to a fuzzed LEVERAGE rather than a fuzzed dollar amount. A flat dollar target
        // overfunds a small position so heavily that no move inside the price band can reach its
        // maintenance margin, which would leave the liquidation path unreachable however far the
        // mark travels. Sizing collateral against the position's own notional keeps every position
        // a bounded distance from its floor, and fuzzing that distance is what decides which of
        // them a given move takes out.
        uint256 notional = size * markUsd; // size (1e18) x price (whole USD) = notional in 1e18
        // The pair sits inside its warmup for the whole run, so the IMR floor is 20% and 5x is
        // the most the margin gate admits. The fill gate charges the mark-vs-fill gap to the
        // overpaying side before it checks margin, so a draw at the limit fills only at the mark
        // and the wide price draw below is refused outright; the lower draws keep a supply of
        // fills the conservation checks can follow. Every draw still puts the position within
        // reach of the price band above, which is all the liquidation path needs.
        uint256 leverage = bound(collSeed, 2, 5);
        uint256 collTarget = notional / leverage;
        // Fund only actors who are currently flat. Topping up an actor who already holds a position
        // rescues it: the mark moves it toward its floor and the next trade quietly re-margins it
        // back out of reach, so the seizure path stays unreachable no matter how far the price
        // travels. Leaving open positions alone is what lets a move actually land on one.
        _fundIfFlat(L, collTarget);
        _fundIfFlat(S, collTarget);

        // The band createOrder enforces on a Limit placement, inclusive at both ends.
        uint256 mark = markUsd * SCALE;
        uint256 lo = mark * (BP_SCALE - BazaarTypes.MAX_PLACEMENT_DEVIATION_BP) / BP_SCALE;
        uint256 hi = mark * (BP_SCALE + BazaarTypes.MAX_PLACEMENT_DEVIATION_BP) / BP_SCALE;
        // Cross by construction: the ask sits one wei under the bid, so the two always match and
        // the fill lands at the bid. Drawing the two sides independently would leave most
        // placements resting without a walk ever running, which is the coverage this action exists
        // for; the resting leftovers supply the far-apart book on their own.
        //
        // Two draws on a seed bit, for the same reason the withdrawal amount has two: the wide draw
        // is the one worth having, but a fill far enough from the mark is refused outright, so a
        // run made only of wide draws exercises the rejection and never the fill. The narrow draw
        // keeps a supply of fills the conservation checks can actually follow through settlement.
        uint256 bid;
        if (priceSeed & 1 == 0) {
            uint256 near = mark / 20; // ±5% of the mark
            bid = bound(priceSeed, mark - near, mark + near);
        } else {
            bid = bound(priceSeed, lo + 1, hi);
        }

        // Until one fill has landed, take the conditions that make a fill near-certain: at the
        // mark, small, and generously margined. A wide state space means some sequences would
        // otherwise spend every trade on combinations the margin gate refuses and finish having
        // never run a walk — which reads as a dead action rather than as the unlucky draw it is.
        // One guaranteed fill per sequence keeps that signal meaningful; everything after it is
        // fuzzed as normal.
        if (ghostFills == 0) {
            size = 1e16;
            bid = mark;
            collTarget = size * markUsd / 2;
            _ensureCollateral(L, collTarget);
            _ensureCollateral(S, collTarget);
        }

        // Watch BOTH actors across BOTH placements. The second leg is the intended taker, but the
        // first can cross a leftover from an earlier trade and fill as taker itself, so watching
        // only the second misses real matches — and undercounting here reads as "the walk never
        // ran", which is the one thing this counter exists to rule out.
        bytes32 beforeL = _fingerprint(L);
        bytes32 beforeS = _fingerprint(S);
        vm.warp(vm.getBlockTimestamp() + 4);
        _place(L, true, size, bid);
        vm.warp(vm.getBlockTimestamp() + 4);
        _place(S, false, size, bid - 1);
        if (_fingerprint(L) != beforeL || _fingerprint(S) != beforeS) ghostFills++;
    }

    /// @dev Move the oracle and store it. Nothing else in this handler can make a solvent position
    ///      insolvent, so this is the sole source of liquidations, of vault inventory, and of the
    ///      bad-debt regime beyond them — the states the conservation identity is least obviously
    ///      right in. Pushed through refreshPrice so the mark lands even when no other action runs
    ///      in the same step, and so the pair's own health evaluation sees it.
    ///
    ///      Half the moves land on a band edge. Realizing bad debt takes two estates seized at
    ///      opposite ends of the band — a long taken near the top, a short taken near the bottom —
    ///      netted against each other before the auction closes either, and uniform draws only
    ///      rarely put both ends into one sequence.
    function movePrice(uint256 priceSeed) public {
        uint256 pick = priceSeed % 4;
        if (pick == 0) markUsd = MARK_MIN_USD;
        else if (pick == 1) markUsd = MARK_MAX_USD;
        else markUsd = bound(priceSeed, MARK_MIN_USD, MARK_MAX_USD);
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _pu(markUsd);
        try pair.refreshPrice(pu) {
            ghostPriceMoves++;
        } catch {}
        _recordRegime();
    }

    /// @dev Hold the vault's inventory across real time so its funding carry accumulates.
    ///
    ///      Every other action steps the clock by three seconds, which across a whole sequence
    ///      leaves the funding index almost where it started. That matters because the carry the
    ///      vault owes on inventory it holds is what the estates' seized collateral does not
    ///      cover: the bankruptcy price embeds funding only up to the seizure, so everything
    ///      after it is paid by the fund, and the part beyond the fund's free capital and beyond
    ///      what the closing winner's own funding income can absorb is booked as `deficit`. With
    ///      the netting arm now refusing a loss it cannot afford, that is the only writer a
    ///      sequence can still reach, and no action here was reaching it.
    ///
    ///      Stepped rather than warped in one jump, because a single long step accrues almost
    ///      nothing: `FundingLib` credits at most MAX_FUNDING_AGE of elapsed time per update and
    ///      ignores a gap past MAX_FUNDING_GAP entirely, so the index moves only for callers who
    ///      keep showing up. Each step stores a fresh price, which is what advances the index.
    ///
    ///      Each step also re-pegs the mark, which is what keeps a rate alive at all. The rate is
    ///      driven by the mark's premium over the oracle, and the mark decays into the oracle over
    ///      MARK_DECAY_PERIOD from an anchor that only a weighted far-side fill moves, and only by
    ///      the share of the premium that fill adds — so a hold with no trading in it earns its
    ///      carry within the first hour and nothing afterwards. Landing a small cross each step
    ///      holds the premium up, which is the book a vault carrying inventory actually sits in.
    ///      The cross is placed on the side that makes the vault's OWN inventory the payer: the
    ///      adverse direction is the one worth reaching, since funding the vault receives can
    ///      never leave a claim unbacked. PREMIUM_BP sits above MAX_MARK_DEVIATION_BP so a peg
    ///      print that rests at that distance enters at the band edge, the farthest any print can.
    function accrueFunding(uint256 roundsSeed, uint256 actorSeed) public {
        (,,,,,, uint256 inventory,,,, bool vaultIsLong,,,,,,) = pair.pairVault();
        if (inventory == 0) return; // nothing is carrying anything
        int256 indexBefore = pair.currentFundingIndex();
        uint256 rounds = bound(roundsSeed, 1, 6);
        for (uint256 i = 0; i < rounds; i++) {
            vm.warp(vm.getBlockTimestamp() + 25 minutes);
            bytes[] memory pu = _pu(markUsd);
            try pair.refreshPrice(pu) {} catch {}
            _pegMarkAgainstTheVault(vaultIsLong, actorSeed + i);
        }
        if (pair.currentFundingIndex() != indexBefore) ghostFundingAccruals++;
        _recordRegime();
    }

    /// @dev Cross a small fill away from the oracle, on the side that leaves the vault's inventory
    ///      paying funding: above it when the vault is long, below it when the vault is short.
    ///      The resting order is the exposed one, a bid above the oracle or an ask below it, and
    ///      it stands a full exposure window before it is taken, so the fill enters the mark at
    ///      full weight; a near-side maker, or one taken in the block it rested, would carry none
    ///      and move nothing. It is priced inside the opposite head of the book, since crossing
    ///      it would fill there as a taker and rest nothing, and skipped when the head leaves no
    ///      room on the far side of the oracle. Silent when the book is frozen, which is most of
    ///      an open ADL window.
    function _pegMarkAgainstTheVault(bool vaultIsLong, uint256 actorSeed) internal {
        if (pair.isAdlPending() || pair.isPairTerminated()) return;
        address L = _pickActor(actorSeed, false);
        address S = _pickActor(actorSeed + 1, false);
        if (L == address(0) || S == address(0) || L == S) return;

        uint256 size = 2e16; // 0.02, small enough not to reshape the book it is pricing
        uint256 oracle = markUsd * SCALE;
        (uint64 bidHead, uint64 askHead,,) = pair.book();
        uint256 px;
        if (vaultIsLong) {
            px = oracle * (BP_SCALE + PREMIUM_BP) / BP_SCALE;
            if (askHead != 0) {
                uint256 bestAsk = OrderView.order(pair, askHead).limitPrice;
                if (bestAsk <= oracle + 1) return;
                if (px >= bestAsk) px = bestAsk - 1;
            }
        } else {
            px = oracle * (BP_SCALE - PREMIUM_BP) / BP_SCALE;
            if (bidHead != 0) {
                uint256 bestBid = OrderView.order(pair, bidHead).limitPrice;
                if (bestBid + 1 >= oracle) return;
                if (px <= bestBid) px = bestBid + 1;
            }
        }

        // The overpaying side is charged the mark-vs-fill gap before its margin is checked, so
        // both legs are funded for the gap on top of the notional.
        uint256 collTarget = size * markUsd / 2;
        _fundIfFlat(L, collTarget);
        _fundIfFlat(S, collTarget);

        if (vaultIsLong) {
            _place(L, true, size, px);
            vm.roll(vm.getBlockNumber() + FundingLib.MAKER_EXPOSURE_BLOCKS);
            vm.warp(vm.getBlockTimestamp() + 4);
            _place(S, false, size, px - 1);
        } else {
            _place(S, false, size, px);
            vm.roll(vm.getBlockNumber() + FundingLib.MAKER_EXPOSURE_BLOCKS);
            vm.warp(vm.getBlockTimestamp() + 4);
            _place(L, true, size, px + 1);
        }
    }

    /// @dev Liquidate whatever the move above left underwater. The whole actor list goes in every
    ///      time: the pair skips accounts that are still solvent and reports how many it took, so
    ///      the handler needs no solvency model of its own to mirror — one that drifted from the
    ///      contract's would quietly stop finding liquidations.
    function liquidateUnderwater(uint256) public {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _pu(markUsd);
        try pair.liquidate(traders, pu) returns (uint256 count) {
            ghostLiquidations += count;
        } catch {}
        _recordRegime();
    }

    /// @dev Cross the vault's seized inventory back into the book. Without it the inventory only
    ///      accumulates: past the trigger the ADL latch freezes matching, and every later action in
    ///      the sequence starts failing for a reason that has nothing to do with what it tests.
    ///      This is the path that resolves the window, so it is what keeps a post-liquidation
    ///      sequence alive long enough to be worth checking.
    function unloadInventory(uint256) public {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _pu(markUsd);
        try pair.unloadVault(0, pu) returns (uint256 unloaded) {
            if (unloaded > 0) ghostUnloads++;
        } catch {}
        _recordRegime();
    }

    /// @dev Rest a single limit order beside the mark with no crossing counterparty. The vault's
    ///      unload walk fills only against resting orders close to the mark, and trade() leaves
    ///      leftovers only when one of its legs is refused, so without this the estate-close walk
    ///      often finds the book empty exactly where it may fill. A resting quote can also cross a
    ///      leftover from an earlier trade, so the fill counter watches it like any placement.
    function rest(uint256 actorSeed, uint256 sideSeed, uint256 sizeSeed, uint256 priceSeed) public {
        address a = traders[bound(actorSeed, 0, traders.length - 2)];
        uint256 size = bound(sizeSeed, 5e16, 1e18);
        uint256 mark = markUsd * SCALE;
        uint256 near = mark / 50; // ±2% of the mark
        uint256 px = bound(priceSeed, mark - near, mark + near);
        _fundIfFlat(a, size * markUsd / 3);
        bytes32 before = _fingerprint(a);
        vm.warp(vm.getBlockTimestamp() + 4);
        _place(a, sideSeed & 1 == 0, size, px);
        if (_fingerprint(a) != before) ghostFills++;
    }

    /// @dev Close profitable counterparties against the vault's inventory once the fund can no
    ///      longer absorb it. The latch freezes matching and position-holder withdrawals, so a
    ///      sequence that opens a window and never resolves it spends its remaining calls on
    ///      reverts; this is the path that ends the window the way the protocol intends.
    ///
    ///      The Dutch decay admits a realistically profitable account only in the auction's last
    ///      minute, and every other action here advances the clock by seconds, so this one jumps
    ///      past the decay: the threshold is then 1 and every profitable account qualifies — the
    ///      auction's designed end state, not a way around it. Both cohorts are submitted: the
    ///      side opposite the inventory closes the inventory, the inventory's own side closes
    ///      the deferred liquidations, each in descending score order as the lens ranks them.
    function deleverage(uint256) public {
        if (!pair.isAdlPending()) return;
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION + 1);
        bool adlLongs = pair.auxState().adlLongs;
        address[] memory winners = _adlWinners(adlLongs);
        address[] memory deferredWinners = _adlWinners(!adlLongs);
        if (winners.length == 0 && deferredWinners.length == 0) return;
        (,,,,,, uint256 inventoryBefore,,,,,,,,,,) = pair.pairVault();
        bytes[] memory pu = _pu(markUsd);
        try pair.executeAdl(winners, deferredWinners, pu) {
            (,,,,,, uint256 inventoryAfter,,,,,,,,,,) = pair.pairVault();
            if (inventoryAfter < inventoryBefore) ghostAdlBatches++;
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            if (
                selector == AdlLib.AdlLib__NotDescendingAdlScoreOrder.selector
                    || selector == AdlLib.AdlLib__NotAscendingAddressTie.selector
            ) ghostAdlOrderRejects++;
        }
        _recordRegime();
    }

    /// @dev Every actor on `isLong`'s side the lens reports eligible, in the order executeAdl
    ///      requires: descending score, ties by ascending address.
    function _adlWinners(bool isLong) internal view returns (address[] memory winners) {
        uint256 n = traders.length;
        address[] memory sorted = new address[](n);
        uint256[] memory scores = new uint256[](n);
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            (bool side,,,,,,) = pair.positionBuckets(traders[i]);
            if (side != isLong) continue;
            (uint256 score, bool eligible) = lens.getAdlScore(address(pair), traders[i]);
            if (!eligible) continue;
            uint256 j = count;
            while (j > 0 && (scores[j - 1] < score || (scores[j - 1] == score && sorted[j - 1] > traders[i]))) {
                sorted[j] = sorted[j - 1];
                scores[j] = scores[j - 1];
                j--;
            }
            sorted[j] = traders[i];
            scores[j] = score;
            count++;
        }
        winners = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            winners[i] = sorted[i];
        }
    }

    /// @dev Sample the two regime markers after any action that can move them. Reading them from
    ///      the invariant would be cleaner but those run view-only, and these have to accumulate.
    function _recordRegime() internal {
        (,,,,,,,,,,, uint256 deficit,,,,,) = pair.pairVault();
        if (deficit > ghostMaxDeficit) ghostMaxDeficit = deficit;
        if (pair.settlementPriceFixedTs() != 0) ghostFroze = true;
        uint256 deferred = pair.auxState().deferredCount;
        if (deferred > ghostMaxDeferred) ghostMaxDeferred = deferred;
        if (pair.isAdlPending()) ghostAdlEverPending = true;
    }

    function _place(address u, bool isLong, uint256 size, uint256 px) internal {
        bytes[] memory pu = _pu(markUsd);
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
        // Eight trading actors and one reserved depositor. Realized bad debt needs two estates
        // whose entries sit far apart on opposite sides — a long seized near the top of the band
        // netted against a short seized near the bottom — and with three traders the book rarely
        // holds both at once: every fill pairs two of them at one price, so a trader's later fill
        // mostly nets its own position instead of opening a second entry. Spreading the fills
        // over more accounts is what lets entries at different prices coexist long enough.
        actors = new address[](9);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;
        actors[3] = dave;
        string[5] memory extra = ["eve", "frank", "grace", "heidi", "ivan"];
        for (uint256 i = 0; i < extra.length; i++) {
            actors[4 + i] = makeAddr(extra[i]);
            usdc.mint(actors[4 + i], INITIAL_USER_BALANCE);
        }
        handler = new ZeroSumHandler(pair, lens, usdc, mockPyth, actors);
        targetContract(address(handler));
    }

    /// @dev Trader equity marked at (price p, funding index f). Mirrors ZeroSumInvariantTest.
    function _equityAt(address u, uint256 p, int256 f) internal view returns (int256 equity) {
        (bool isLong, uint256 size, uint256 entryValue, uint256 collateral, int256 entryFundingIdx,,) =
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
        (,,,,,, uint256 plSize, uint256 plEntry,, int256 plFundIdx, bool plIsLong,,,,,,) = pair.pairVault();
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

    /// @notice Full zero-sum conservation: Σ trader equity + registered terminal claims + vault
    ///         inventory + insurance + ledger arrears == actual USDC held, net of realized bad debt.
    ///         Marked at the pair's own price while it is live and at the fixed settlement price
    ///         once one is set, so the identity holds across the freeze that bad debt triggers.
    function invariant_zeroSum() public view {
        (,,,,, uint256 I,,,,,, uint256 deficit,,, uint256 arrears,,) = pair.pairVault();
        BazaarTypes.AuxState memory aux = pair.auxState();
        // Once a settlement price is fixed, every leg is valued at it. The stored mark and the
        // funding index stop advancing at the fix, and terminal settlement realizes each position
        // at exactly this price, so it is the one price at which settled and unsettled legs agree;
        // with positions leaving one side at a time, no other price keeps the sum price-free.
        uint256 p = aux.settlementPrice != 0 ? aux.settlementPrice : _markPrice();
        int256 f = pair.currentFundingIndex();
        // Earned-but-unclaimed fees are a third-party claim on cash the contract still holds,
        // so they count as claims until someone calls claimFees. The ledger's arrears are the
        // fund's claim on cash the deposits ledger holds for it (a seizure the ledger could only
        // partly pay), owed to no bucket until settlement nets it, so they count the same way.
        int256 claims = int256(I) + int256(_escrowTotal()) + int256(arrears);
        for (uint256 i = 0; i < actors.length; i++) {
            claims += _equityAt(actors[i], p, f);
            // A winner settled at the fixed price holds its profit as a registered claim rather
            // than in its bucket; nothing is paid until finalize, which this handler never calls.
            claims += int256(pair.terminalProfitClaim(actors[i]));
        }
        claims += _vaultInventoryAt(p, f);
        // Realized bad debt is the one term that breaks the plain claims == cash form, and it does
        // so by a known amount rather than an unknown one. A loss that overran what backed it still
        // credits the winning side in full and still zeroes the loser's bucket, so the books go on
        // describing value the contract does not hold — exactly `deficit` of it. Netting it off the
        // claims side restores the identity and, more usefully, pins the SIZE of the hole: a bug
        // that books bad debt at the wrong magnitude, or credits a winner without recording the
        // shortfall, moves the two sides by different amounts and still fails here.
        claims -= int256(deficit);
        // The terminal twin of `deficit`: a loser settled at the fixed price beyond its collateral
        // leaves the uncovered part in this tally while its counterparty's claim is registered in
        // full, so the books again describe exactly that much value the contract does not hold.
        claims -= int256(aux.terminalBadDebt);
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
            (bool isLong, uint256 size,,,,,) = pair.positionBuckets(actors[i]);
            if (isLong) longSum += size;
            else shortSum += size;
        }
        (uint256 totalLongOI, uint256 totalShortOI,,,,,,,,,,,,,,,) = pair.pairVault();
        assertEq(totalLongOI, longSum, "totalLongOI == sum of long position sizes");
        assertEq(totalShortOI, shortSum, "totalShortOI == sum of short position sizes");
    }

    /// @notice A deferred liquidation is listed only while an ADL window is open. The list exists
    ///         for a window's auction, and every health check that leaves no window open empties
    ///         it; an entry outliving its window would be a liquidation candidate the gate keeps
    ///         walking and a later window could open on without anyone re-testing its netting.
    ///         Exact on this pair: it is continuously traded, so no verdict runs on the stale
    ///         fallback, the one case that keeps an entry with no window stored. Past a fixed
    ///         settlement price the pair settles instead of judging health and the window is
    ///         retired at finalize, so the check stops there.
    function invariant_deferredListedOnlyInsideWindow() public view {
        if (pair.settlementPriceFixedTs() != 0) return;
        if (pair.auxState().deferredCount != 0) {
            assertTrue(pair.isAdlPending(), "a deferred liquidation is listed with no window open");
        }
    }

    /// @notice Every handler action reached its success path at least once in this run.
    /// @dev The invariants above are all one-directional safety properties: they pass trivially
    ///      over a sequence in which nothing happened. Combined with a profile that does not fail
    ///      on revert and a handler that catches every call, that makes an action which reverts on
    ///      every invocation completely silent — the run stays green and the coverage it is
    ///      credited with is imaginary. Asserting the counters here is what converts that failure
    ///      mode from invisible to loud. Runs once per sequence, against counters the per-run state
    ///      snapshot resets.
    ///
    ///      Skipped once a settlement price is fixed. That freeze is a legitimate destination for
    ///      this handler — a move large enough to realize bad debt sends the pair there on purpose —
    ///      and past it deposits, withdrawals and matching are all supposed to refuse, so demanding
    ///      they succeed would turn the very regime the handler was widened to reach into a test
    ///      failure. The conservation invariants keep running across the freeze; only the
    ///      liveness-shaped coverage claims are suspended.
    function afterInvariant() public view {
        assertEq(handler.ghostAdlOrderRejects(), 0, "a deleverage batch was refused for cohort ordering");
        if (pair.settlementPriceFixedTs() != 0) return;
        assertGt(handler.ghostDeposits(), 0, "no deposit landed");
        assertGt(handler.ghostTrades(), 0, "no order was placed");
        assertGt(handler.ghostFlatWithdrawals(), 0, "no flat-user withdrawal landed");
        assertGt(handler.ghostPriceMoves(), 0, "the mark never moved");
        // Matching and position-holder withdrawals are both frozen for as long as an ADL window is
        // open, so a sequence that latched one can have no honest opportunity to do either. That
        // freeze is a destination this handler is meant to reach, not a defect to assert away.
        // Judged over the whole sequence rather than on the final state: a window that opened and
        // was resolved again still spent the calls in between refusing both actions, and reading
        // only the end state would demand coverage the run was never allowed to produce.
        if (handler.ghostAdlEverPending()) return;
        assertGt(handler.ghostFills(), 0, "no placement ever matched");
        // Asserted against opportunities rather than unconditionally. The quote the action draws
        // against comes from the lens, independently of the path being tested, so a broken release
        // still registers a chance and still fails here; what the guard drops is the sequence whose
        // position holders all sat at their floor, which had nothing releasable to offer at all.
        if (handler.ghostOpenWithdrawChances() > 0) {
            assertGt(handler.ghostOpenWithdrawals(), 0, "no withdrawal against an open position landed");
        }
    }
}
