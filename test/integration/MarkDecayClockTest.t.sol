// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";

/// @title MarkDecayClockTest
/// @notice The mark's two tallies fade along one line, and a print moves the line's anchor toward
///         the present only by its share of the volume. A print too small to matter therefore
///         extends the line by next to nothing and moves the reading by no more than its own
///         share, so a train of them can hold neither a premium nor the funding read from it. A
///         line standing above the floor holds its reading until the volume fades under the floor,
///         then fades out; one on a spent mark gets the whole period.
contract MarkDecayClockTest is IntegrationBase {
    uint256 constant BTC = 1e18;
    uint256 constant ORACLE = 50_000 * BAZAAR_SCALE;
    uint256 constant BASE = BTC / 2; // the open interest every test starts from
    // $25.50 at $51k: under the $125 one call may add against the $500 floor BASE sets.
    uint256 constant PRINT = BTC / 2000;
    // $49 at $51k: under that cap too, and twenty of them in twenty minutes stand the line above
    // the floor.
    uint256 constant BIG = BTC / 1040;
    uint256 constant DUST = BTC / 10_000; // $5.0005 at $50,005: the order minimum
    uint256 constant W = FundingLib.MAKER_EXPOSURE_BLOCKS;
    uint256 constant PERIOD = FundingLib.MARK_DECAY_PERIOD;

    /// @dev Every test starts from BASE of open interest opened by a print at the oracle, a
    ///      near-side print that forms no mark.
    function setUp() public override {
        super.setUp();
        _deposit(alice, 100_000 * BAZAAR_SCALE);
        _deposit(bob, 100_000 * BAZAAR_SCALE);
        _deposit(carol, 100_000 * BAZAAR_SCALE);
        _deposit(dave, 100_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, BASE, ORACLE);
        _roll(W);
        _placeLimit(bob, false, BASE, ORACLE);
    }

    function _mark() internal view returns (uint256) {
        return lens.markPrice(address(pair));
    }

    function _anchor() internal view returns (uint256) {
        return pair.auxState().lastMarkUpdateTs;
    }

    /// @dev The volume floor at the oracle: 2% of per-side open interest, counting the vault's
    ///      inventory on its side.
    function _floor() internal view returns (uint256) {
        (uint256 l, uint256 s,,,,, uint256 pend,,,, bool pendLong,,,,,,) = pair.pairVault();
        if (pendLong) l += pend;
        else s += pend;
        return FundingLib.floorVolumeOf(l > s ? l : s, ORACLE);
    }

    /// @dev The volume tally the line reads now.
    function _liveVolume() internal view returns (uint256) {
        BazaarTypes.AuxState memory a = pair.auxState();
        if (a.lastMarkUpdateTs == 0) return 0;
        uint256 age = vm.getBlockTimestamp() - a.lastMarkUpdateTs;
        if (age >= PERIOD) return 0;
        return a.rollingVolume * (PERIOD - age) / PERIOD;
    }

    /// @dev A full-weight far-side print of `size` at $51k: Alice's bid stands a whole exposure
    ///      window above the index before Bob sells into it.
    function _fullWeightPrint(uint256 size) internal {
        _placeLimit(alice, true, size, 51_000 * BAZAAR_SCALE);
        _roll(W);
        _placeLimit(bob, false, size, 51_000 * BAZAAR_SCALE);
    }

    /// @dev A $5 far-side print against a bid that stood one block: weight 1/40, so an eighth of a
    ///      dollar of weighted notional at a premium of one basis point.
    function _dustPrint() internal {
        _placeLimit(carol, true, DUST, 50_005 * BAZAAR_SCALE);
        _roll(1);
        _placeLimit(dave, false, DUST, 50_005 * BAZAAR_SCALE);
    }

    /// @dev The most one dust print can move the mark: its weighted notional times its premium,
    ///      read over at least the $500 floor and carried on the oracle.
    function _dustMarkBound() internal pure returns (uint256) {
        uint256 weighted = DUST * 50_005 / W; // an eighth of a dollar
        uint256 premiumAdd = weighted * 1e14 / BAZAAR_SCALE; // at one basis point
        return ORACLE * (premiumAdd * BAZAAR_SCALE / (500 * BAZAAR_SCALE)) / BAZAAR_SCALE + 1;
    }

    /// @notice Control: with no further print, the premium is gone one period after it formed.
    function test_noPrint_premiumGoneAfterOnePeriod() public {
        _fullWeightPrint(PRINT);
        assertGt(_mark(), ORACLE, "fixture: the print formed a premium");
        assertEq(_anchor(), vm.getBlockTimestamp(), "fixture: anchored at the print");
        vm.warp(vm.getBlockTimestamp() + PERIOD);
        assertEq(_mark(), ORACLE, "back at the index");
    }

    /// @notice Twelve $5 far-side prints, one every five minutes, each against a bid that stood one
    ///         block: each lifts the mark by no more than its own weighted premium over the floor,
    ///         a thousandth of a cent (it can only lower it, by the open interest it adds to the
    ///         floor), and the premium is gone within a period of the last of them.
    function test_dustPrints_cannotHoldThePremium() public {
        _fullWeightPrint(PRINT);
        uint256 bound = _dustMarkBound();
        for (uint256 k; k < 12; ++k) {
            vm.warp(vm.getBlockTimestamp() + 5 minutes);
            uint256 markBefore = _mark();
            uint256 anchorBefore = _anchor();
            _dustPrint();
            assertGe(_anchor(), anchorBefore, "the anchor only moves forward");
            assertLe(_mark(), markBefore + bound, "a dust print lifts the mark by its own share at most");
        }
        uint256 lastDust = vm.getBlockTimestamp();
        vm.warp(lastDust + PERIOD);
        assertEq(_mark(), ORACLE, "the premium is gone within a period of the last print");
    }

    /// @notice The funding consequence: the same thirteen price stores, five minutes apart, accrue
    ///         the same funding whether or not a dust print rides each one, to within the dust's
    ///         share of the volume. Twelve prints of 13 cents of weighted notional against a $25.50
    ///         line are 6% of it, and each extends the line by its share of the age, so they may
    ///         add funding in that proportion and no more.
    function test_dustPrints_addOnlyTheirOwnFunding() public {
        _fullWeightPrint(PRINT);
        uint256 t0 = vm.getBlockTimestamp();
        uint256 b0 = vm.getBlockNumber();
        uint256 snap = vm.snapshotState();

        for (uint256 k = 1; k <= 13; ++k) {
            vm.warp(t0 + k * 5 minutes);
            bytes[] memory pu = _freshPrice();
            vm.prank(seq);
            pair.refreshPrice(pu);
        }
        int256 withoutDust = pair.currentFundingIndex();
        assertTrue(withoutDust != 0, "fixture: the premium accrued funding");

        vm.revertToState(snap);
        vm.warp(t0);
        vm.roll(b0);
        for (uint256 k = 1; k <= 13; ++k) {
            vm.warp(t0 + k * 5 minutes);
            _dustPrint();
        }
        // Twelve dust prints' weighted notional as a share of the line's: the most they can extend
        // it by, and so the most funding they can add.
        uint256 share = 12 * (DUST * 50_005 / W) * BAZAAR_SCALE / (PRINT * 51_000);
        assertApproxEqRel(pair.currentFundingIndex(), withoutDust, share, "dust prints add at most their share");
    }

    /// @notice A full-weight print on a spent mark anchors a fresh line: the whole period again.
    function test_printOnASpentMark_getsTheFullPeriod() public {
        _fullWeightPrint(PRINT);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        assertEq(_mark(), ORACLE, "fixture: the first premium is spent");

        _fullWeightPrint(PRINT);
        uint256 printedAt = vm.getBlockTimestamp();
        assertEq(_anchor(), printedAt, "a fresh anchor at the print");
        vm.warp(printedAt + PERIOD - 1);
        assertGt(_mark(), ORACLE, "a premium until the period ends");
        vm.warp(printedAt + PERIOD);
        assertEq(_mark(), ORACLE, "and none after it");
    }

    /// @notice A print on a live line keeps the old volume's share of its age: the anchor moves
    ///         forward by the new print's share of the volume, rounded in the line's favour, and
    ///         stays short of the print, so the premium ends before a full period after the print.
    function test_printOnALiveLine_extendsItByItsVolumeShare() public {
        _fullWeightPrint(PRINT);
        uint256 firstAnchor = _anchor();
        vm.warp(firstAnchor + 30 minutes);
        uint256 survivor = _mark() - ORACLE;

        _fullWeightPrint(PRINT);
        uint256 printedAt = vm.getBlockTimestamp();
        uint256 age = printedAt - firstAnchor;
        uint256 oldVolume = PRINT * 51_000 * (PERIOD - age) / PERIOD;
        uint256 kept = (age * oldVolume + oldVolume + PRINT * 51_000 - 1) / (oldVolume + PRINT * 51_000);
        uint256 anchor = _anchor();
        assertGt(_mark() - ORACLE, survivor, "the print added premium");
        assertEq(anchor, printedAt - kept, "the anchor keeps the old volume's share of the age");
        assertGt(anchor, firstAnchor, "so it moved forward");
        assertLt(anchor, printedAt, "but stayed short of the print");

        vm.warp(anchor + PERIOD - 1);
        assertGt(_mark(), ORACLE, "a premium until the new end");
        vm.warp(anchor + PERIOD);
        assertEq(_mark(), ORACLE, "none at it, short of a full period after the print");
    }

    /// @notice A line standing above the floor holds its reading after prints stop, until its volume
    ///         fades under the floor, and is gone at its end. Twenty $49 prints a minute apart leave
    ///         about $800 of live volume against a $520 floor: the mark holds for the first ten
    ///         minutes of quiet, fades afterwards, and sits on the index a period after the anchor.
    function test_quietAfterFlow_holdsAboveTheFloorThenFades() public {
        for (uint256 k; k < 20; ++k) {
            _fullWeightPrint(BIG);
            vm.warp(vm.getBlockTimestamp() + 1 minutes);
        }
        uint256 held = _mark();
        uint256 anchor = _anchor();
        assertGt(_liveVolume(), _floor(), "fixture: the line stands above the floor");
        assertGt(held, ORACLE, "fixture: a premium");

        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        assertGt(_liveVolume(), _floor(), "fixture: still above the floor");
        assertApproxEqAbs(_mark(), held, 1e6, "held while the volume stands above the floor");

        vm.warp(anchor + PERIOD - 2 minutes);
        assertLt(_liveVolume(), _floor(), "fixture: under the floor near the end");
        assertGt(_mark(), ORACLE, "fading, not gone");
        assertLt(_mark(), held, "and below what it held");

        vm.warp(anchor + PERIOD);
        assertEq(_mark(), ORACLE, "gone a period after the anchor");
    }

    /// @notice A move of the index carries the mark with it rather than reading as premium. Half
    ///         an hour after a full-weight print, a price store at $49,500 finds the mark half the
    ///         print's premium above $49,500. Drawn as a line in price from the $50,000 the print
    ///         traded against, the mark would read the $500 fall as a further premium of about half
    ///         a percent.
    function test_indexMove_carriesTheMark() public {
        _fullWeightPrint(PRINT);
        uint256 printedAt = vm.getBlockTimestamp();
        uint256 premium = (_mark() - ORACLE) * BAZAAR_SCALE / ORACLE;
        assertGt(premium, 0, "fixture: the print formed a premium");

        vm.warp(printedAt + 30 minutes);
        bytes[] memory pu = _priceAt(49_500);
        vm.prank(seq);
        pair.refreshPrice(pu);

        // The line is under the floor, so its reading fades from the anchor: half of it is left.
        // The floor is taken at the new index, 1% smaller, so the half reads 1% larger.
        uint256 index = 49_500 * BAZAAR_SCALE;
        uint256 half = premium / 2 * 50_000 / 49_500;
        assertApproxEqAbs(_mark(), index + index * half / BAZAAR_SCALE, 1e6, "half the premium, on the new index");
    }
}
