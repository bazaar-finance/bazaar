// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @dev Reads the line from its own frame, so every reading takes the block's timestamp afresh
///      after a warp rather than one the optimizer kept from earlier in the test.
contract MarkReader {
    function currentPremium(FundingLib.MarkState memory s, uint256 floorVolume) external view returns (int256) {
        return FundingLib.currentPremium(s.premiumNotional, s.rollingVolume, s.lastMarkUpdateTs, floorVolume);
    }

    function currentMark(FundingLib.MarkState memory s, uint256 floorVolume, uint256 indexPrice)
        external
        view
        returns (uint256)
    {
        return FundingLib.currentMark(s.premiumNotional, s.rollingVolume, s.lastMarkUpdateTs, floorVolume, indexPrice);
    }

    /// @dev The volume tally the line gives at this block, as updateMarkPrice decays it.
    function currentVolume(FundingLib.MarkState memory s) external view returns (uint256) {
        if (s.lastMarkUpdateTs == 0) return 0;
        uint256 age = block.timestamp - s.lastMarkUpdateTs;
        if (age >= FundingLib.MARK_DECAY_PERIOD) return 0;
        return s.rollingVolume * (FundingLib.MARK_DECAY_PERIOD - age) / FundingLib.MARK_DECAY_PERIOD;
    }

    /// @dev The premium tally the line gives at this block.
    function currentPremiumNotional(FundingLib.MarkState memory s) external view returns (int256) {
        if (s.lastMarkUpdateTs == 0) return 0;
        uint256 age = block.timestamp - s.lastMarkUpdateTs;
        if (age >= FundingLib.MARK_DECAY_PERIOD) return 0;
        return s.premiumNotional * int256(FundingLib.MARK_DECAY_PERIOD - age) / int256(FundingLib.MARK_DECAY_PERIOD);
    }
}

/// @notice Direct unit tests for FundingLib's mark internals — the two tallies and their ratio,
///         the single-call cap, the open-interest floor, the exec-price deviation band, the
///         tallies' decay and the anchor's volume-share rule — and, on the funding side, the
///         window average, the age-cap middle branch and the per-pair-type ceiling/dampener
///         pairings that keep the rate clamp outside the band.
contract FundingLibTest is Test {
    uint256 constant SCALE = 1e18;
    int256 constant PCT = 1e16; // 1% of the index, as a premium
    uint256 constant T0 = 1_700_000_000;
    uint256 constant PERIOD = FundingLib.MARK_DECAY_PERIOD;
    uint256 constant BAND = FundingLib.MAX_MARK_DEVIATION_BP * 1e14; // the band edge as a premium

    MarkReader reader;
    /// @dev The vault the library sizes the floor from; only its open interest is read.
    BazaarTypes.Vault internal vault;

    function setUp() public {
        vm.warp(T0);
        reader = new MarkReader();
    }

    // ---------------- helpers ----------------

    /// @dev Sets per-side open interest to `size`, so the floor is 2% of size × index.
    function _oi(uint256 size) internal {
        vault.totalLongOI = size;
        vault.totalShortOI = size;
        vault.pendingLiqSize = 0;
    }

    function _floor(uint256 index) internal view returns (uint256) {
        return FundingLib.floorVolumeOf(
            vault.totalLongOI > vault.totalShortOI ? vault.totalLongOI : vault.totalShortOI, index
        );
    }

    function _update(FundingLib.MarkState memory s, uint256 notional, uint256 size, uint256 index)
        internal
        view
        returns (FundingLib.MarkState memory)
    {
        return FundingLib.updateMarkPrice(s, notional, size, index, vault);
    }

    function _premium(FundingLib.MarkState memory s, uint256 index) internal view returns (int256) {
        return reader.currentPremium(s, _floor(index));
    }

    function _read(FundingLib.MarkState memory s, uint256 index) internal view returns (uint256) {
        return reader.currentMark(s, _floor(index), index);
    }

    function _accrue(FundingLib.MarkState memory s, uint256 lastFunding, uint256 index, bool continuous)
        internal
        view
        returns (int256 delta)
    {
        (delta,) = FundingLib.updateFundingIndex(
            s.premiumNotional,
            s.rollingVolume,
            s.lastMarkUpdateTs,
            0,
            lastFunding,
            index,
            block.timestamp,
            vault,
            continuous
        );
    }

    function _assertUnchanged(FundingLib.MarkState memory got, FundingLib.MarkState memory want, string memory why)
        internal
        pure
    {
        assertEq(got.premiumNotional, want.premiumNotional, string.concat(why, ": premium tally"));
        assertEq(got.lastMarkUpdateTs, want.lastMarkUpdateTs, string.concat(why, ": anchor"));
        assertEq(got.rollingVolume, want.rollingVolume, string.concat(why, ": volume tally"));
    }

    /// @dev A line whose reading is `premium` on volume `vol`, anchored at `ts`.
    function _line(int256 premium, uint256 ts, uint256 vol) internal pure returns (FundingLib.MarkState memory s) {
        s.premiumNotional = int256(vol) * premium / int256(SCALE);
        s.lastMarkUpdateTs = ts;
        s.rollingVolume = vol;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    /// @dev updateMarkPrice takes the walk's notional and size and derives the VWAP itself, so the
    ///      tests state a target print price and the notional it implies at a chosen size.
    function _notional(uint256 size, uint256 price) internal pure returns (uint256) {
        return size * price / SCALE;
    }

    // ---------------- the single-call cap ----------------

    /// @notice First fill ever on a pair: open interest of 1,040,000 at $200 is $208M of notional,
    ///         so the floor is $4.16M and one call may add at most $1.04M. A $20.5M print 2.5%
    ///         above the index enters at that cap, read over the floor: 0.625%, a mark of 201.25.
    ///         The volume records what was admitted, not the whole fill, so the tallies stay a
    ///         weighted average of admitted prints.
    function test_mark_firstFill_dominantFillCappedAtAQuarter() public {
        _oi(1_040_000 * SCALE);
        FundingLib.MarkState memory s = _update(
            FundingLib.MarkState(0, 0, 0), _notional(100_000 * SCALE, 205 * SCALE), 100_000 * SCALE, 200 * SCALE
        );
        assertEq(
            _premium(s, 200 * SCALE),
            625 * PCT / 1_000,
            "a dominant fill moves the reading a quarter of the way to its print"
        );
        assertEq(_read(s, 200 * SCALE), 20_125 * SCALE / 100, "a mark of 201.25");
        assertEq(s.rollingVolume, 1_040_000 * SCALE, "the admitted notional is the volume");
        assertEq(s.premiumNotional, 1_040_000 * int256(SCALE) * 25 / 1_000, "times the print's premium");
        assertEq(s.lastMarkUpdateTs, block.timestamp, "a line formed from nothing is anchored at its print");
    }

    /// @notice Above the floor the cap is a share of the volume: a $52 print joining $1,000 of
    ///         live volume enters whole (under a quarter), a $520 one is clipped to $250, and
    ///         either way the reading moves at most a quarter of the way to the print.
    function test_mark_capIsAQuarterOfTheVolumeItJoins() public view {
        uint256 index = 100 * SCALE;
        FundingLib.MarkState memory before = _line(PCT, block.timestamp, 1_000 * SCALE);

        FundingLib.MarkState memory small = _update(before, _notional(SCALE / 2, 104 * SCALE), SCALE / 2, index);
        assertEq(small.rollingVolume, 1_052 * SCALE, "a print under the cap enters whole");
        // (1,000 × 1% + 52 × 4%) / 1,052
        assertEq(_premium(small, index), (1_000 * PCT + 52 * 4 * PCT) / 1_052, "the volume-weighted blend");

        FundingLib.MarkState memory big = _update(before, _notional(5 * SCALE, 104 * SCALE), 5 * SCALE, index);
        assertEq(big.rollingVolume, 1_250 * SCALE, "a print over the cap is clipped to a quarter of the volume");
        assertEq(_premium(big, index), (1_000 * PCT + 250 * 4 * PCT) / 1_250, "and enters at the clipped size");
        assertLe(
            _abs(_premium(big, index) - PCT) * 4,
            _abs(4 * PCT - PCT),
            "no call moves the reading more than a quarter of the way"
        );
    }

    /// @notice An execution print far from the index is clamped to the deviation band before its
    ///         premium is taken, so a self-crossed wash trade at an arbitrary price can't push the
    ///         mark past the band even where the cap admits the whole fill.
    function test_mark_execPriceClampedToDeviationBand() public {
        _oi(1_040_000 * SCALE);
        // A $1.04M print at 300 vs index 200 (+50%, far past the band), exactly the cap.
        FundingLib.MarkState memory s =
            _update(FundingLib.MarkState(0, 0, 0), _notional(3_467 * SCALE, 300 * SCALE), 3_467 * SCALE, 200 * SCALE);
        // Print clamps to 200 x 1.04 = 208, a 4% premium; a quarter of it is 1%, a mark of 202
        // (NOT 225, which is what an unclamped 300 print would give).
        assertEq(_premium(s, 200 * SCALE), PCT, "print clamped to the band before it enters");
        assertEq(_read(s, 200 * SCALE), 202 * SCALE, "a mark of 202");
    }

    // ---------------- the floor ----------------

    /// @notice The floor is what closes the quiet-pair hole: a quote smaller than it reads only
    ///         its own share of its premium. Against the $4.16M floor a single unit printing at
    ///         $205 is $205 of notional, so its 2.5% premium reads 205 / 4.16M of itself.
    function test_mark_openInterestFloorScalesDustToItsShare() public {
        _oi(1_040_000 * SCALE);
        FundingLib.MarkState memory s =
            _update(FundingLib.MarkState(0, 0, 0), _notional(1 * SCALE, 205 * SCALE), 1 * SCALE, 200 * SCALE);
        assertEq(s.rollingVolume, 205 * SCALE, "the dust is recorded");
        assertEq(_premium(s, 200 * SCALE), 25 * PCT / 10 * 205 / 4_160_000, "and reads its share of its premium");
        assertLt(_premium(s, 200 * SCALE), PCT / 1_000, "which is nothing to speak of");
    }

    /// @notice Real rolling volume above the floor governs on its own — the floor is a backstop
    ///         for quiet pairs, not an override. $1B of rolling volume beats the same $4.16M floor,
    ///         and a $20,500 print at 2.5% moves the reading by its share of the billion.
    function test_mark_rollingVolumeAboveFloorGoverns() public {
        _oi(1_040_000 * SCALE);
        FundingLib.MarkState memory before = _line(0, block.timestamp, 1_000_000_000 * SCALE);
        FundingLib.MarkState memory s = _update(before, _notional(100 * SCALE, 205 * SCALE), 100 * SCALE, 200 * SCALE);
        assertEq(s.rollingVolume, 1_000_020_500 * SCALE, "the print joins the volume");
        assertEq(_premium(s, 200 * SCALE), 25 * PCT / 10 * 20_500 / 1_000_020_500, "and reads its share of it");
        assertEq(s.lastMarkUpdateTs, before.lastMarkUpdateTs, "a line anchored at the block keeps its anchor");
    }

    /// @notice A print against no volume and no open interest has nothing to be weighed against,
    ///         so it writes nothing: the pair never passes such a state after a fill, since a
    ///         fill that leaves no open interest closed positions and joins the volume they made.
    function test_mark_printAgainstNothing_writesNothing() public view {
        FundingLib.MarkState memory before = FundingLib.MarkState(0, 0, 0);
        _assertUnchanged(
            _update(before, _notional(SCALE, 205 * SCALE), SCALE, 200 * SCALE), before, "nothing to weigh against"
        );
    }

    /// @notice An update with no qualifying fill writes nothing.
    function test_mark_zeroFill_writesNothing() public view {
        FundingLib.MarkState memory before = _line(10 * PCT, block.timestamp - 30 minutes, 50 * SCALE);
        _assertUnchanged(_update(before, 0, 0, 200 * SCALE), before, "no fill");
    }

    // ---------------- reading the line ----------------

    /// @notice Above the floor the fade leaves the ratio alone: a line reads its premium in full
    ///         until its volume drops under the floor, then fades with its premium tally, and is
    ///         gone at the period. Open interest of 1,000 at $100 floors the volume at $2,000; a
    ///         line of $8,000 at 1% holds for three quarters of the period and fades over the last.
    function test_mark_decay_flatAboveTheFloorThenLinear() public {
        _oi(1_000 * SCALE);
        uint256 index = 100 * SCALE;
        FundingLib.MarkState memory s = _line(PCT, T0, 8_000 * SCALE);
        assertEq(_premium(s, index), PCT, "at the anchor");
        vm.warp(T0 + 30 minutes);
        assertEq(_premium(s, index), PCT, "flat while the volume is above the floor");
        vm.warp(T0 + 45 minutes);
        assertEq(_premium(s, index), PCT, "down to the crossing");
        vm.warp(T0 + 52 minutes + 30 seconds);
        assertEq(_premium(s, index), PCT / 2, "halfway down the fade");
        vm.warp(T0 + 60 minutes);
        assertEq(_premium(s, index), 0, "at the period");
        vm.warp(T0 + 61 minutes);
        assertEq(_premium(s, index), 0, "past it");
    }

    /// @notice A line under the floor fades from its anchor: halfway after half the period.
    function test_mark_decay_linearUnderTheFloor() public {
        _oi(1_000 * SCALE);
        uint256 index = 100 * SCALE;
        // $1,000 of volume under a $2,000 floor: reads half its 2% at the anchor.
        FundingLib.MarkState memory s = _line(2 * PCT, T0, 1_000 * SCALE);
        assertEq(_premium(s, index), PCT, "its share at the anchor");
        vm.warp(T0 + 30 minutes);
        assertEq(_premium(s, index), PCT / 2, "halfway");
        assertEq(_read(s, index), 1005 * SCALE / 10, "a mark of 100.5");
        vm.warp(T0 + 60 minutes);
        assertEq(_premium(s, index), 0, "gone at the period");
    }

    /// @notice Before any mark has formed the line has no premium, and the mark is the index.
    function test_mark_decay_unformedReadsTheIndex() public view {
        assertEq(reader.currentMark(FundingLib.MarkState(0, 0, 0), 0, 200 * SCALE), 200 * SCALE, "no mark");
        assertEq(reader.currentMark(_line(10 * PCT, 0, SCALE), 0, 200 * SCALE), 200 * SCALE, "no anchor");
    }

    /// @notice The mark is the index carried by the premium, so a move of the index moves the mark
    ///         with it: the same line reads the same 3% premium on an index of $100 as on one of
    ///         $200.
    function test_mark_decay_carriedByTheIndex() public view {
        FundingLib.MarkState memory s = _line(3 * PCT, block.timestamp - 30 minutes, 1_000 * SCALE);
        assertEq(reader.currentMark(s, 0, 100 * SCALE), 103 * SCALE, "3% on $100");
        assertEq(reader.currentMark(s, 0, 200 * SCALE), 206 * SCALE, "3% on $200");
    }

    /// @notice The reading is clipped to the band: a stored line whose rounding carries the ratio
    ///         a hair past the band edge still reads the edge, so the factor the mark applies to
    ///         the index never leaves the band.
    function test_mark_readingClippedToTheBand() public view {
        FundingLib.MarkState memory s;
        s.lastMarkUpdateTs = block.timestamp;
        s.rollingVolume = 1_000;
        s.premiumNotional = 41; // 4.1% of 1,000: past the band by rounding's reach
        assertEq(reader.currentPremium(s, 0), int256(BAND), "clipped to the band edge");
    }

    // ---------------- the decay clock ----------------

    /// @notice Prints too small to buy a second of the clock cannot walk the anchor forward.
    ///         Two thousand prints of $200 each join $1M of live volume half-way down its line, all
    ///         in one block: each one's share of the line's 30 minutes is a third of a second, so
    ///         the anchor never moves and the line still ends an hour after it.
    function test_clock_minimumSharePrintsCannotWalkTheAnchor() public {
        _oi(1_000_000 * SCALE);
        uint256 index = 100 * SCALE;
        uint256 anchor = T0 - 30 minutes;
        FundingLib.MarkState memory s = _line(PCT, anchor, 2_000_000 * SCALE);
        uint256 size = 2_001 * SCALE / 1_000;
        uint256 price = 10_001 * SCALE / 100;
        for (uint256 k; k < 2_000; ++k) {
            FundingLib.MarkState memory next = _update(s, _notional(size, price), size, index);
            assertTrue(next.rollingVolume != s.rollingVolume, "fixture: every print is recorded");
            assertEq(next.lastMarkUpdateTs, anchor, "a sub-second share never moves the anchor");
            s = next;
        }
        vm.warp(anchor + PERIOD - 1);
        assertGt(_premium(s, index), 0, "a premium until the old end");
        vm.warp(anchor + PERIOD);
        assertEq(_premium(s, index), 0, "none at it");
    }

    /// @notice A print on a live line keeps the old volume's share of its age. $1,000 of volume at
    ///         3% anchored at T0 reads $500 at 3% half an hour in, when a $125 print lands 1.5%
    ///         above the index (the cap, a quarter of the volume). The reading becomes the blend,
    ///         (500 × 3% + 125 × 1.5%) / 625; the anchor keeps 500/625 of the line's 30 minutes,
    ///         1,440 s, so it moves 360 s past the old anchor and the line ends 36 minutes after
    ///         the print rather than an hour after it. The tallies are stored as of that anchor,
    ///         scaled by 3,600 / 2,160.
    function test_clock_printOnALiveLine_keepsTheOldVolumesShareOfItsAge() public view {
        uint256 index = 100 * SCALE;
        FundingLib.MarkState memory before = _line(3 * PCT, T0 - 30 minutes, 1_000 * SCALE);
        FundingLib.MarkState memory s =
            _update(before, _notional(5 * SCALE / 4, 1_015 * SCALE / 10), 5 * SCALE / 4, index);

        assertEq(s.lastMarkUpdateTs, T0 - 30 minutes + 360, "the anchor keeps the old volume's share of its age");
        assertEq(s.rollingVolume, 625 * SCALE * 3_600 / 2_160, "the volume is stored as of the anchor");
        assertEq(s.premiumNotional, int256(16_875 * SCALE / 1_000) * 3_600 / 2_160, "and so is the premium tally");
        assertApproxEqAbs(
            _premium(s, index), (500 * 3 * PCT + 125 * 15 * PCT / 10) / 625, 1, "the line reads the blend at the print"
        );
    }

    /// @notice The same line, read on: it holds the blend while its volume stands above the floor
    ///         and is gone at its end.
    function test_clock_printOnALiveLine_endsAtTheKeptEnd() public {
        uint256 index = 100 * SCALE;
        FundingLib.MarkState memory s = _update(
            _line(3 * PCT, T0 - 30 minutes, 1_000 * SCALE),
            _notional(5 * SCALE / 4, 1_015 * SCALE / 10),
            5 * SCALE / 4,
            index
        );
        int256 blend = (500 * 3 * PCT + 125 * 15 * PCT / 10) / 625;
        vm.warp(T0 + 15 minutes);
        assertApproxEqAbs(_premium(s, index), blend, 1, "held: no floor, so the ratio stands");
        vm.warp(T0 - 30 minutes + 360 + PERIOD - 1);
        assertGt(_premium(s, index), 0, "a premium until the end of the line");
        vm.warp(T0 - 30 minutes + 360 + PERIOD);
        assertEq(_premium(s, index), 0, "none at it");
    }

    /// @notice A print on a spent line anchors a fresh one and gets the whole period.
    function test_clock_printOnASpentLine_getsTheFullPeriod() public {
        _oi(1_000 * SCALE);
        uint256 index = 100 * SCALE;
        vm.warp(T0 + 2 hours);
        FundingLib.MarkState memory s =
            _update(_line(6 * PCT, T0, 1_000 * SCALE), _notional(5 * SCALE, 103 * SCALE), 5 * SCALE, index);
        assertEq(s.lastMarkUpdateTs, T0 + 2 hours, "anchored at the print");
        assertEq(s.rollingVolume, 500 * SCALE, "the cap, a quarter of the $2,000 floor");
        assertEq(_premium(s, index), 3 * PCT / 4, "a quarter of the print's premium over the floor");
        assertEq(_read(s, index), 10_075 * SCALE / 100, "a mark of 100.75");
        vm.warp(T0 + 3 hours - 1);
        assertGt(_premium(s, index), 0, "a premium for the whole period");
        vm.warp(T0 + 3 hours);
        assertEq(_premium(s, index), 0, "and none past it");
    }

    /// @notice Further updates in the same block find what the last one left: neither tally
    ///         decays twice, however many prints land in one block. Fifty prints on a half-run
    ///         line move the anchor only forward and leave the volume at the sum of what came in.
    function test_clock_sameBlockUpdatesDecayNothingTwice() public {
        uint256 index = 100 * SCALE;
        vm.warp(T0 + 30 minutes);
        FundingLib.MarkState memory s = _line(6 * PCT, T0, 1_000 * SCALE);
        uint256 startVolume = reader.currentVolume(s); // 500: half the line has run
        uint256 notional = _notional(SCALE / 100, 104 * SCALE); // $1.04 at the band edge
        for (uint256 k; k < 50; ++k) {
            uint256 volume = reader.currentVolume(s);
            int256 tally = reader.currentPremiumNotional(s);
            FundingLib.MarkState memory next = _update(s, notional, SCALE / 100, index);
            assertGe(next.lastMarkUpdateTs, s.lastMarkUpdateTs, "the anchor only moves forward");
            assertLe(next.lastMarkUpdateTs, T0 + 30 minutes, "and never past the block");
            assertApproxEqAbs(reader.currentVolume(next), volume + notional, 1, "the volume decays once");
            assertApproxEqAbs(
                reader.currentPremiumNotional(next),
                tally + int256(notional) * 4 * PCT / int256(SCALE),
                1e3,
                "and so does the premium tally"
            );
            s = next;
        }
        assertApproxEqAbs(reader.currentVolume(s), startVolume + 50 * notional, 50, "no collapse within the block");
    }

    /// @notice A print against the premium dilutes it by its volume share and extends the line by
    ///         the same share: $4,000 at 4% anchored 30 minutes ago reads $2,000 at 4%, and a $192
    ///         ask 4% under the index (under the $500 cap) leaves (2,000 × 4% − 192 × 4%) / 2,192
    ///         and keeps 2,000/2,192 of the 1,800 s of age, rounded up to 1,643 s.
    function test_clock_printAgainstThePremium_dilutesAndExtendsByItsShare() public {
        uint256 index = 100 * SCALE;
        uint256 anchor = T0 - 30 minutes;
        FundingLib.MarkState memory s =
            _update(_line(4 * PCT, anchor, 4_000 * SCALE), _notional(2 * SCALE, 96 * SCALE), 2 * SCALE, index);
        assertApproxEqAbs(_premium(s, index), (2_000 * 4 * PCT - 192 * 4 * PCT) / 2_192, 1, "the volume-weighted blend");
        assertEq(s.lastMarkUpdateTs, anchor + 1_800 - 1_643, "the anchor keeps 2,000/2,192 of 1,800 s, rounded up");
        vm.warp(s.lastMarkUpdateTs + PERIOD - 1);
        assertGt(_premium(s, index), 0, "a premium until the extended end");
        vm.warp(s.lastMarkUpdateTs + PERIOD);
        assertEq(_premium(s, index), 0, "none at it");
    }

    /// @notice A run of prints against the premium turns it over once their volume outweighs the
    ///         survivor, and the reading crosses zero without a jump: each print is a quarter of
    ///         the volume, so a few prints 4% under the index on $1,000 at 4% leave a discount.
    function test_clock_printsAgainstThePremium_turnItOver() public view {
        uint256 index = 100 * SCALE;
        FundingLib.MarkState memory s = _line(4 * PCT, block.timestamp, 1_000 * SCALE);
        int256 last = _premium(s, index);
        for (uint256 k; k < 30; ++k) {
            s = _update(s, _notional(10 * SCALE, 96 * SCALE), 10 * SCALE, index);
            int256 now_ = _premium(s, index);
            assertLt(now_, last, "every print takes premium away");
            assertGe(now_, -4 * PCT, "and never past the band");
            last = now_;
        }
        assertLt(last, -3 * PCT, "turned over to a discount past 3%");
    }

    // ---------------- trend ----------------

    /// @notice The index moves the mark and is never read as premium. A print one basis point above
    ///         a $100 index, at one ten-thousandth of the floor, forms a premium of a hundred
    ///         millionth of a percent; half an hour later the index has fallen to $99.50, and the
    ///         mark sits on it, so half an hour of session funding is next to nothing. A mark held
    ///         as a price would sit halfway between the $100 it was printed against and the moved
    ///         index, about a quarter of a percent above it.
    function test_trend_anIndexMoveIsNotPremium() public {
        _oi(1_000_000 * SCALE);
        FundingLib.MarkState memory s = _update(
            FundingLib.MarkState(0, 0, 0),
            _notional(2_001 * SCALE / 1_000, 10_001 * SCALE / 100),
            2_001 * SCALE / 1_000,
            100 * SCALE
        );
        assertApproxEqAbs(
            _premium(s, 100 * SCALE), PCT / 1_000_000, 1e8, "fixture: a millionth of a percent of premium"
        );

        vm.warp(T0 + 30 minutes);
        uint256 index = 995 * SCALE / 10;
        assertApproxEqRel(_read(s, index), index, 1e10, "the mark sits on the moved index");
        int256 accrued = _accrue(s, T0, index, false);
        assertLt(_abs(accrued), 1e12, "the index's own move charges no funding");
    }

    /// @notice An honest discount in a falling market reads as a discount. With the index falling a
    ///         dollar an hour from $100, an ask half a percent below it is lifted every minute on a
    ///         line standing well above the $2 floor; for three hours the premium is exactly that
    ///         discount, after every print and between them, and the mark sits below the index
    ///         wherever the index goes.
    function test_trend_discountPrintsInAFallingMarketReadAsADiscount() public {
        _oi(1 * SCALE);
        FundingLib.MarkState memory s = _line(-PCT / 2, T0, 100 * SCALE);
        for (uint256 k = 1; k <= 180; k++) {
            vm.warp(T0 + k * 1 minutes);
            uint256 index = 100 * SCALE - k * SCALE / 60;
            s = _update(s, _notional(SCALE, index * 995 / 1_000), SCALE, index);
            assertApproxEqAbs(_premium(s, index), -PCT / 2, 1e6, "the discount after the print");
            assertLt(_read(s, index), index, "the mark below the index");
            vm.warp(T0 + k * 1 minutes + 30);
            uint256 later = 100 * SCALE - k * SCALE / 60 - SCALE / 120;
            assertApproxEqAbs(_premium(s, later), -PCT / 2, 1e6, "and between prints");
            assertLt(_read(s, later), later, "while the index keeps falling");
        }
    }

    /// @notice Calibration under steady flow. A print at the band edge every minute, on a line
    ///         standing well above the $2 floor, reads the band edge in full after every print and
    ///         between prints, for as long as the stream runs: the fade scales both tallies alike,
    ///         so the ratio of a steady stream is the stream's own premium, not a fraction of it.
    ///         The stream also keeps the volume up: a capped print moves the anchor a fifth of the
    ///         way to the present, and a minute's fade takes back less than the quarter it adds.
    function test_clock_steadyFlowReadsItsPremiumInFull() public {
        _oi(1 * SCALE);
        uint256 index = 100 * SCALE;
        FundingLib.MarkState memory s = _line(4 * PCT, T0, 100 * SCALE);
        for (uint256 k = 1; k <= 300; k++) {
            vm.warp(T0 + k * 1 minutes);
            s = _update(s, _notional(SCALE, 104 * SCALE), SCALE, index);
            assertApproxEqAbs(_premium(s, index), 4 * PCT, 1e6, "reads the band edge in full after every print");
            vm.warp(T0 + k * 1 minutes + 59);
            assertApproxEqAbs(_premium(s, index), 4 * PCT, 1e6, "and between prints");
        }
        assertGt(reader.currentVolume(s), 100 * SCALE, "the stream keeps the volume far above the floor");
    }

    /// @notice Five minutes apart the stream still holds. A capped print moves the anchor a fifth
    ///         of the way to the present, and five minutes of fade take back less than the quarter
    ///         the print adds, so the volume climbs above the floor and the band edge reads in full,
    ///         after prints and between them.
    function test_clock_fiveMinuteStreamReadsInFull() public {
        _oi(1 * SCALE);
        uint256 index = 100 * SCALE;
        FundingLib.MarkState memory s = _line(4 * PCT, T0, 100 * SCALE);
        for (uint256 k = 1; k <= 60; k++) {
            vm.warp(T0 + k * 5 minutes);
            s = _update(s, _notional(SCALE, 104 * SCALE), SCALE, index);
        }
        assertGt(reader.currentVolume(s), 2 * SCALE, "the volume stands above the floor");
        assertApproxEqAbs(_premium(s, index), 4 * PCT, 1e6, "the band edge in full after a print");
        vm.warp(T0 + 60 * 5 minutes + 299);
        assertGt(reader.currentVolume(s), 2 * SCALE, "and still above it before the next");
        assertApproxEqAbs(_premium(s, index), 4 * PCT, 1e6, "so the band edge between prints too");
    }

    /// @notice The stream has to keep coming. The same prints ten minutes apart cannot hold the
    ///         volume above the floor: ten minutes of fade take more than the quarter a capped print
    ///         adds, and the volume settles under the $2 floor at about $1.25 before a print and
    ///         $1.75 after. The reading is then the volume's share of the band edge, about 3.5%
    ///         after a print fading to 2.5% before the next — a declining fraction as the gaps grow,
    ///         a quarter for a print on a spent line. The full read needs qualifying prints more
    ///         often than about every six and a half minutes.
    function test_clock_sparseCappedStream_readsItsVolumesShareOfTheFloor() public {
        _oi(1 * SCALE);
        uint256 index = 100 * SCALE;
        FundingLib.MarkState memory s = _line(4 * PCT, T0, 100 * SCALE);
        for (uint256 k = 1; k <= 200; k++) {
            vm.warp(T0 + k * 10 minutes);
            s = _update(s, _notional(SCALE, 104 * SCALE), SCALE, index);
        }
        uint256 live = reader.currentVolume(s);
        assertLt(live, 2 * SCALE, "the volume settled under the floor");
        assertApproxEqRel(live, 175 * SCALE / 100, 0.05e18, "at about $1.75 right after a print");
        assertApproxEqRel(
            _premium(s, index), int256(live) * 4 * PCT / int256(2 * SCALE), 0.001e18, "its share of the band"
        );
        vm.warp(T0 + 200 * 10 minutes + 599);
        assertApproxEqRel(_premium(s, index), 25 * PCT / 10, 0.05e18, "fading toward 2.5% before the next");
    }

    /// @notice Under the floor the same stream reads its share: $104 every five minutes against a
    ///         $20,000 floor leaves, in steady state, about $780 of live volume, so the band edge
    ///         reads at about 3.9% of itself. The floor is what prices a quote: the stream would
    ///         have to be the floor's size to read in full.
    function test_clock_steadyFlowUnderTheFloorReadsItsShare() public {
        _oi(10_000 * SCALE);
        uint256 index = 100 * SCALE;
        FundingLib.MarkState memory s;
        for (uint256 k = 1; k <= 200; k++) {
            vm.warp(T0 + k * 5 minutes);
            s = _update(s, _notional(SCALE, 104 * SCALE), SCALE, index);
        }
        uint256 live = reader.currentVolume(s);
        assertLt(live, 20_000 * SCALE, "fixture: the stream stays under the floor");
        assertApproxEqAbs(
            _premium(s, index),
            int256(live) * 4 * PCT / int256(20_000 * SCALE),
            2,
            "reads volume / floor of the band edge"
        );
    }

    // ---------------- the fuzzed update ----------------

    /// @notice Whatever the stored line, the index, the print and the open interest: a print with
    ///         nothing to be weighed against writes nothing, and an admitted one leaves a line that
    ///         reads the volume-weighted blend of the decayed tallies and the clamped print, admits
    ///         at most a tenth of the volume it is weighed against, never reads outside the band,
    ///         keeps its anchor between the old one and the block, and reads the volume that came
    ///         in. The stored tallies keep their ratio inside the band too.
    function testFuzz_update_readsAsTheWeightedBlend(
        int256 premiumSeed,
        uint256 ageSeed,
        uint256 execSeed,
        uint256 sizeSeed,
        uint256 volSeed,
        uint256 oiSeed,
        uint256 indexSeed,
        bool formed
    ) public {
        uint256 index = bound(indexSeed, SCALE / 100, 1_000_000 * SCALE);
        uint256 age = bound(ageSeed, 0, 2 hours);
        int256 oldPremium = bound(premiumSeed, -int256(BAND), int256(BAND));
        uint256 size = bound(sizeSeed, 1e12, 1e24);
        uint256 notional = _notional(size, bound(execSeed, index / 2, index * 3 / 2));
        _oi(bound(oiSeed, 0, 1e24));
        FundingLib.MarkState memory before =
            formed ? _line(oldPremium, T0 - age, bound(volSeed, 1e15, 1e27)) : FundingLib.MarkState(0, 0, 0);

        // The admission and the print the library derives, restated.
        uint256 volumeBefore = reader.currentVolume(before);
        int256 tallyBefore = reader.currentPremiumNotional(before);
        uint256 floorVolume = _floor(index);
        uint256 denom = volumeBefore > floorVolume ? volumeBefore : floorVolume;
        uint256 admitted = notional < denom / 4 ? notional : denom / 4;
        uint256 exec = notional * SCALE / size;
        uint256 low = (index * (10_000 - FundingLib.MAX_MARK_DEVIATION_BP) + 9_999) / 10_000;
        uint256 high = index * (10_000 + FundingLib.MAX_MARK_DEVIATION_BP) / 10_000;
        uint256 bounded = exec < low ? low : (exec > high ? high : exec);
        int256 printPremium = (int256(bounded) - int256(index)) * int256(SCALE) / int256(index);

        FundingLib.MarkState memory s = _update(before, notional, size, index);
        if (admitted == 0) {
            _assertUnchanged(s, before, "a print with nothing to be weighed against writes nothing");
            return;
        }
        uint256 volumeAfter = volumeBefore + admitted;
        int256 tallyAfter = tallyBefore + int256(admitted) * printPremium / int256(SCALE);
        uint256 readDenom = volumeAfter > floorVolume ? volumeAfter : floorVolume;
        int256 expected = tallyAfter * int256(SCALE) / int256(readDenom);
        // A unit of rounding in either tally is SCALE / denominator in the reading.
        uint256 tolerance = 2 * SCALE / readDenom + 2;
        assertApproxEqAbs(_premium(s, index), expected, tolerance, "the line reads the weighted blend at the print");
        assertLe(_abs(_premium(s, index)), BAND, "inside the band");
        assertLe(admitted * 4, denom + 3, "at most a quarter of the volume it is weighed against");
        assertGe(s.lastMarkUpdateTs, before.lastMarkUpdateTs, "the anchor never moves backward");
        assertLe(s.lastMarkUpdateTs, T0, "nor past the block");
        assertApproxEqAbs(reader.currentVolume(s), volumeAfter, 1, "the volume reads what came in");
        assertLe(
            _abs(s.premiumNotional),
            s.rollingVolume * BAND / SCALE + 10_000,
            "the stored tallies keep their ratio inside the band"
        );
    }

    // ---------------- an attacker's cadence ----------------

    /// @notice Timing buys nothing. With the same hourly budget of band-edge prints, spent as a
    ///         drip every minute or as a burst every half hour split into calls the cap admits, the
    ///         time-average premium over the fourth and fifth hours is no higher for the bursts.
    ///         The reading holds between prints only while the volume stands above the floor, and
    ///         keeping it there costs the same inflow whatever its timing. Open interest of 1,000
    ///         at $100 floors the volume at $2,000; the budget is $4,000 an hour.
    function test_attack_burstsBuyNoMoreThanADrip() public {
        _oi(1_000 * SCALE);
        uint256 index = 100 * SCALE;
        int256 drip = _averageUnderCadence(index, 60, 4_000 * SCALE / 60);
        int256 bursts = _averageUnderCadence(index, 1_800, 4_000 * SCALE / 2);
        assertGt(drip, 3 * PCT, "fixture: the drip holds most of the band");
        assertLe(bursts, drip, "bursts buy no more premium per dollar than a drip");
    }

    /// @dev Prints at the band edge every `cadence` seconds, `budget` of notional each time, split
    ///      into as many calls as the cap needs, for five hours; returns the reading's time-average
    ///      over the last two, sampled every minute.
    function _averageUnderCadence(uint256 index, uint256 cadence, uint256 budget) internal returns (int256) {
        FundingLib.MarkState memory s;
        uint256 price = index * 104 / 100;
        int256 sum;
        uint256 n;
        for (uint256 t; t < 5 hours; t += cadence) {
            vm.warp(T0 + t);
            uint256 left = budget;
            for (uint256 c; c < 64 && left > 0; ++c) {
                uint256 size = left * SCALE / price;
                if (size == 0) break;
                FundingLib.MarkState memory next = _update(s, left, size, index);
                uint256 used = reader.currentVolume(next) - reader.currentVolume(s);
                if (used == 0) break;
                left -= used < left ? used : left;
                s = next;
            }
            if (t >= 3 hours) {
                for (uint256 k; k < cadence; k += 60) {
                    vm.warp(T0 + t + k);
                    sum += _premium(s, index);
                    ++n;
                }
            }
        }
        return sum / int256(n);
    }

    // ---------------- funding index: the window average ----------------

    /// @notice A window that lies wholly on the flat part of a line is charged at the premium the
    ///         line holds, exactly what the same premium read at the window's close would charge:
    ///         a premium of 1% on $8,000 of volume over a $2,000 floor holds for 45 minutes, and
    ///         half an hour of session funding on it on a $200 index is 1%/8 × $200 × 0.5 h.
    function test_funding_windowOnTheFlatPart_chargesThePremium() public {
        _oi(500 * SCALE);
        uint256 index = 200 * SCALE;
        FundingLib.MarkState memory s = _line(PCT, T0, 8_000 * SCALE);
        vm.warp(T0 + 30 minutes);
        assertEq(_accrue(s, T0, index, false), int256(SCALE / 8), "0.125 in price units");
    }

    /// @notice A window on the fade is charged at its average, not its closing value: $1,000 of
    ///         volume under a $2,000 floor at 2% reads 1% at its anchor and fades to zero at the
    ///         hour. The half hour from minute 30 to minute 60 averages a quarter of a percent,
    ///         while its closing reading is zero.
    function test_funding_windowOnTheFade_chargesTheAverage() public {
        _oi(500 * SCALE);
        uint256 index = 200 * SCALE;
        FundingLib.MarkState memory s = _line(2 * PCT, T0, 1_000 * SCALE);
        vm.warp(T0 + 60 minutes);
        assertEq(_premium(s, index), 0, "fixture: the closing reading is zero");
        // 0.25% / 8 × $200 × 0.5 h = 0.03125
        assertEq(
            _accrue(s, T0 + 30 minutes, index, false), int256(SCALE * 3_125 / 100_000), "the fade's average, 0.25%"
        );
    }

    /// @notice A window across the crossing takes the flat part at the held premium and the fade at
    ///         its average: the $8,000 line holds 1% for 45 minutes, then fades over 15. The age
    ///         cap trims a store at the hour to its last 30 minutes, which average
    ///         15 × 1% + 15 × 0.5% over 30 minutes, 0.75%; a store asked for that window directly
    ///         charges the same.
    function test_funding_windowAcrossTheCrossing_sumsBothPieces() public {
        _oi(500 * SCALE);
        uint256 index = 200 * SCALE;
        FundingLib.MarkState memory s = _line(PCT, T0, 8_000 * SCALE);
        vm.warp(T0 + 60 minutes);
        // Age-capped to the last 30 minutes: 15 flat at 1% plus 15 fading from 1% to 0 → 0.75%.
        // 0.75% / 8 × $200 × 0.5 h = 0.09375
        assertEq(_accrue(s, T0, index, false), int256(SCALE * 9_375 / 100_000), "both pieces of the capped window");
        // The same window asked for directly, from minute 30.
        assertEq(_accrue(s, T0 + 30 minutes, index, false), int256(SCALE * 9_375 / 100_000), "flat then fade");
    }

    /// @notice The window average is what the line integrates to: averagePremium against a brute
    ///         sum of per-second readings, on a line that crosses the floor inside the window.
    function test_funding_averageMatchesTheSecondBySecondSum() public pure {
        uint256 floorVolume = 2_000 * SCALE;
        FundingLib.MarkState memory s = _line(PCT, T0 - 20 minutes, 5_000 * SCALE);
        uint256 from = T0 - 10 minutes;
        uint256 to = T0 + 30 minutes;
        int256 sum;
        for (uint256 t = from; t < to; t += 15) {
            sum += FundingLib.premiumAt(s.premiumNotional, s.rollingVolume, s.lastMarkUpdateTs, floorVolume, t + 7);
        }
        int256 brute = sum * 15 / int256(to - from);
        assertApproxEqRel(
            FundingLib.averagePremium(s, floorVolume, from, to), brute, 0.001e18, "closed form = integral"
        );
    }

    /// @notice Time before the anchor and after the line's end reads zero, and a line whose anchor
    ///         is the window's close contributes nothing to it.
    function test_funding_windowOutsideTheLine_chargesNothing() public {
        _oi(1_000 * SCALE);
        uint256 index = 200 * SCALE;
        FundingLib.MarkState memory s = _line(PCT, T0 + 30 minutes, 8_000 * SCALE);
        vm.warp(T0 + 30 minutes);
        assertEq(_accrue(s, T0, index, false), 0, "a line anchored at the close");
        vm.warp(T0 + 2 hours);
        assertEq(_accrue(s, T0 + 100 minutes, index, false), 0, "a line that ran out before the window");
    }

    /// @notice Each pair type's dampener is derived from its own rate ceiling against the shared
    ///         band, so a mark held exactly at the band edge produces exactly that ceiling and
    ///         the clamp is unreachable from strictly inside the band. Pinning both pairings guards
    ///         the invariant that actually matters: declaring band, rate and dampener independently
    ///         leaves a saturated stretch of band where funding stops responding to mark movement.
    ///         The age cap trims each window to 30 minutes, so the accrual is rate x $200 x 0.5h.
    function test_funding_bandEdgeYieldsExactlyTheClamp_bothPairTypes() public {
        uint256 index = 200 * SCALE;
        FundingLib.MarkState memory edge = _line(int256(BAND), T0, 1_000 * SCALE);
        FundingLib.MarkState memory inside = _line(int256(BAND) - PCT / 2, T0, 1_000 * SCALE);
        vm.warp(T0 + 1 hours);

        // Session: premium 4% over a dampener of 8 is exactly 0.5%/h. 0.005 x 200 x 0.5 = 0.5.
        int256 session = _accrue(edge, T0, index, false);
        assertEq(session, int256(SCALE / 2), "session band edge accrues exactly its ceiling, no more");

        // Continuous: the same 4% over a dampener of 40 is exactly 0.1%/h. 0.001 x 200 x 0.5 = 0.1.
        int256 continuous = _accrue(edge, T0, index, true);
        assertEq(continuous, int256(SCALE / 10), "continuous band edge accrues exactly its ceiling, no more");

        // Half a percent inside the band accrues strictly less on both — no saturated dead zone below the edge.
        assertLt(
            _accrue(inside, T0, index, false), session, "session: inside the band the rate is strictly below the clamp"
        );
        assertLt(
            _accrue(inside, T0, index, true),
            continuous,
            "continuous: inside the band the rate is strictly below the clamp"
        );
    }

    /// @notice The pair types share one band, so the mark may sit equally far from the index on
    ///         either — only the strength of the resulting pull differs, by the ratio of the two
    ///         ceilings. A continuous pair's deeper clamp is what its 24/7 accrual pays for.
    function test_funding_continuousClampIsOneFifthOfSession() public {
        uint256 index = 200 * SCALE;
        FundingLib.MarkState memory edge = _line(-int256(BAND), T0, 1_000 * SCALE);
        vm.warp(T0 + 30 minutes);

        int256 session = _accrue(edge, T0, index, false);
        int256 continuous = _accrue(edge, T0, index, true);

        assertEq(session, -int256(SCALE / 2), "session clamps at -0.5%/h");
        assertEq(continuous, -int256(SCALE / 10), "continuous clamps at -0.1%/h");
        assertEq(session, continuous * 5, "the ceilings differ by exactly the 5x duty-cycle ratio");
    }

    /// @dev Premium, in bp, at which a pairing's rate ceiling is first reached.
    function _bandAtCeiling(uint256 rate, uint256 dampener) internal pure returns (uint256) {
        return rate * dampener * FundingLib.BP_SCALE / FundingLib.BAZAAR_SCALE;
    }

    /// @notice Each dampener is derived by integer division of the band by its ceiling, which is
    ///         exact only while the band is a whole multiple of that ceiling in bp per hour. This
    ///         asserts the round trip on the constants themselves rather than probing near the band
    ///         edge, where a dead zone narrower than the probe step would slip through unnoticed.
    ///         The load-bearing direction is >=: a dampener that truncated low would put the
    ///         ceiling BELOW the band edge, so the clamp would bind from inside the band and leave
    ///         a stretch over which funding no longer responds to mark movement — the precise shape
    ///         the derivation exists to prevent. Equality additionally says no band is wasted: the
    ///         ceiling sits exactly at the edge rather than above everything the band permits.
    function test_funding_everyCeilingReachesExactlyTheBandEdge() public pure {
        assertEq(
            _bandAtCeiling(FundingLib.MAX_FUNDING_RATE_SESSION, FundingLib.FUNDING_DAMPENER_SESSION),
            FundingLib.MAX_MARK_DEVIATION_BP,
            "session ceiling must be reached exactly at the band edge, not inside it"
        );
        assertEq(
            _bandAtCeiling(FundingLib.MAX_FUNDING_RATE_CONTINUOUS, FundingLib.FUNDING_DAMPENER_CONTINUOUS),
            FundingLib.MAX_MARK_DEVIATION_BP,
            "continuous ceiling must be reached exactly at the band edge, not inside it"
        );
    }

    /// @notice The 30-minute age cap (middle branch): a 2-hour quiet gap with a fresh oracle tick
    ///         accrues EXACTLY the 30 minutes before the tick, not 2 hours. The line is anchored
    ///         at the start of that half hour and holds 1% across it.
    function test_funding_ageCap_accruesExactly30MinutesAfterQuietGap() public {
        vm.warp(T0 + 2 hours);
        FundingLib.MarkState memory s = _line(PCT, T0 + 90 minutes, 8_000 * SCALE);
        // A premium of 1% on a $200 index: rate = 1%/8 = 0.125%/h.
        (int256 idx, uint256 ts) = FundingLib.updateFundingIndex(
            s.premiumNotional, s.rollingVolume, s.lastMarkUpdateTs, 0, T0, 200 * SCALE, block.timestamp, vault, false
        );
        // delta = 0.00125 x $200 x (30min/1h) = 0.125 in price units.
        assertEq(idx, int256(SCALE / 8), "exactly 30 minutes of accrual");
        assertEq(ts, block.timestamp, "clock advanced");
    }

    /// @notice The funding rate clamps at -0.5%/h for deep negative premiums (mirror of the
    ///         tested positive clamp): a stored line past the band reads the band edge.
    function test_funding_negativeClamp() public {
        vm.warp(T0 + 30 minutes);
        FundingLib.MarkState memory s;
        s.lastMarkUpdateTs = T0;
        s.rollingVolume = 1_000 * SCALE;
        s.premiumNotional = -100 * int256(SCALE); // a tally of -10%, clipped to the band on reading
        // delta = -0.005 x $200 x 0.5h = -0.5 price units.
        assertEq(_accrue(s, T0, 200 * SCALE, false), -int256(SCALE / 2), "clamped at -MAX_FUNDING_RATE");
    }

    /// @notice Zero index price is a no-accrue guard: the clock advances, the index does not move.
    function test_funding_zeroIndexPriceGuard() public {
        vm.warp(T0 + 10 minutes);
        FundingLib.MarkState memory s = _line(PCT, T0, 1_000 * SCALE);
        (int256 idx, uint256 ts) = FundingLib.updateFundingIndex(
            s.premiumNotional, s.rollingVolume, s.lastMarkUpdateTs, 7e18, T0, 0, block.timestamp, vault, false
        );
        assertEq(idx, 7e18, "index unchanged");
        assertEq(ts, block.timestamp, "clock advanced");
    }

    /// @notice A >12h stale gap skips the window entirely (validStart jumps to the oracle ts).
    function test_funding_staleGapSkipsAccrual() public {
        vm.warp(T0 + 13 hours);
        FundingLib.MarkState memory s = _line(5 * PCT, T0 + 13 hours - 10 minutes, 1_000 * SCALE);
        (int256 idx, uint256 ts) = FundingLib.updateFundingIndex(
            s.premiumNotional, s.rollingVolume, s.lastMarkUpdateTs, 3e18, T0, 200 * SCALE, block.timestamp, vault, false
        );
        assertEq(idx, 3e18, "no back-charging across the outage");
        assertEq(ts, block.timestamp, "clock advanced");
    }

    // ---------------- maker exposure weight ----------------

    /// @notice The window is about ten seconds of Arbitrum blocks: what a watcher needs to take a
    ///         quote resting away from fair before its owner can take it back at full weight. A
    ///         longer window would discount the fills that say the most, the bids above the index
    ///         that active pairs take within seconds.
    function test_exposure_windowIsTenSecondsOfBlocks() public pure {
        assertEq(FundingLib.MAKER_EXPOSURE_BLOCKS, 40, "40 blocks of ~250 ms");
    }

    /// @notice A maker taken in the block it was placed carries no weight: it was never on offer
    ///         to anyone but the account that took it.
    function test_exposure_sameBlockIsZero() public pure {
        assertEq(FundingLib.makerExposureWeight(1_000_000, 1_000_000), 0, "same block");
    }

    /// @notice Inside the window the weight is the age in blocks, so a fill against a maker that
    ///         stood for a quarter of the window enters at a quarter weight.
    function test_exposure_proRataInsideTheWindow() public pure {
        uint256 window = FundingLib.MAKER_EXPOSURE_BLOCKS;
        assertEq(FundingLib.makerExposureWeight(1_000_001, 1_000_000), 1, "one block");
        assertEq(FundingLib.makerExposureWeight(1_000_000 + uint64(window / 4), 1_000_000), window / 4, "quarter");
        assertEq(FundingLib.makerExposureWeight(1_000_000 + uint64(window) - 1, 1_000_000), window - 1, "last block");
    }

    /// @notice At and past the window the weight is the window itself, so standing longer buys
    ///         nothing more.
    function test_exposure_capsAtTheWindow() public pure {
        uint256 window = FundingLib.MAKER_EXPOSURE_BLOCKS;
        assertEq(FundingLib.makerExposureWeight(1_000_000 + uint64(window), 1_000_000), window, "at the window");
        assertEq(FundingLib.makerExposureWeight(5_000_000, 1_000_000), window, "far past it");
    }

    /// @notice The stamp holds the block's low 32 bits and the age is taken modulo 2^32, so a
    ///         maker that rested across the counter passing a multiple of 2^32 still reads its
    ///         true age, and a block number past 2^32 compares like any other.
    function test_exposure_ageWrapsWithTheStamp() public pure {
        uint64 wrap = uint64(1) << 32;
        // Rested five blocks before the wrap, filled fifteen blocks after it: aged twenty.
        assertEq(FundingLib.makerExposureWeight(wrap + 15, uint32(wrap - 5)), 20, "across the wrap");
        // Both past the wrap: an ordinary subtraction on the low bits.
        assertEq(FundingLib.makerExposureWeight(wrap + 100, uint32(wrap + 70)), 30, "past the wrap");
        // Same block past the wrap is still zero.
        assertEq(FundingLib.makerExposureWeight(wrap + 7, uint32(wrap + 7)), 0, "same block past the wrap");
    }

    // -------------------- the rested premium --------------------

    uint256 constant PPM = FundingLib.RESTED_PREMIUM_SCALE;
    uint256 constant BAND_PPM = FundingLib.MAX_MARK_DEVIATION_BP * PPM / 10_000;

    /// @notice The stamp is a bid's distance above the index or an ask's below it; the near
    ///         side, the index itself and a zero index stamp nothing.
    function test_restedPremium_farSideOnly() public pure {
        assertEq(FundingLib.restedPremiumOf(true, 102 * SCALE, 100 * SCALE), 20_000, "bid 2% above");
        assertEq(FundingLib.restedPremiumOf(false, 97 * SCALE, 100 * SCALE), 30_000, "ask 3% below");
        assertEq(FundingLib.restedPremiumOf(true, 98 * SCALE, 100 * SCALE), 0, "bid below");
        assertEq(FundingLib.restedPremiumOf(false, 103 * SCALE, 100 * SCALE), 0, "ask above");
        assertEq(FundingLib.restedPremiumOf(true, 100 * SCALE, 100 * SCALE), 0, "bid at the index");
        assertEq(FundingLib.restedPremiumOf(false, 100 * SCALE, 100 * SCALE), 0, "ask at the index");
        assertEq(FundingLib.restedPremiumOf(true, 102 * SCALE, 0), 0, "no index, bid");
        assertEq(FundingLib.restedPremiumOf(false, 98 * SCALE, 0), 0, "no index, ask");
        assertEq(FundingLib.restedPremiumOf(true, 150 * SCALE, 100 * SCALE), BAND_PPM, "capped at the band");
    }

    /// @notice A fill counts at the smaller of its own premium and the one its maker rested at:
    ///         a bid stamped at 1% and filled 2% over a lower index counts 1%; one filled 0.5%
    ///         over a higher index counts 0.5%. The mirror holds for an ask.
    function test_printPrice_smallerOfFillAndStamp() public pure {
        assertEq(FundingLib.printPriceOf(true, 102 * SCALE, 10_000, 100 * SCALE), 101 * SCALE, "bid: the stamp");
        assertEq(
            FundingLib.printPriceOf(true, 1005 * SCALE / 10, 10_000, 100 * SCALE), 1005 * SCALE / 10, "bid: the fill"
        );
        assertEq(FundingLib.printPriceOf(false, 98 * SCALE, 10_000, 100 * SCALE), 99 * SCALE, "ask: the stamp");
        assertEq(
            FundingLib.printPriceOf(false, 995 * SCALE / 10, 10_000, 100 * SCALE), 995 * SCALE / 10, "ask: the fill"
        );
    }

    /// @notice The counted premium never exceeds the stamped one nor the fill's own, never flips
    ///         to the near side, and falls short of the smaller of the two by under one unit of
    ///         the stamp's scale.
    function testFuzz_printPrice_boundedByStampAndFill(bool isLong, uint256 index, uint256 gapPpm, uint256 stamp)
        public
        pure
    {
        index = bound(index, 1e6, 1e30);
        gapPpm = bound(gapPpm, 1, 500_000); // the fill's own far-side distance, up to 50%
        stamp = bound(stamp, 1, BAND_PPM);
        uint256 gap = index * gapPpm / PPM + 1;
        uint256 limit = isLong ? index + gap : index - gap;
        uint256 p = FundingLib.printPriceOf(isLong, limit, stamp, index);
        if (isLong) {
            assertLe(p, limit, "never past the fill");
            assertGe(p, index, "never below the index");
            assertLe((p - index) * PPM, stamp * index, "never past the stamp");
            if (p != limit) assertLt(stamp * index - (p - index) * PPM, PPM, "the stamp, rounded down");
        } else {
            assertGe(p, limit, "never past the fill");
            assertLe(p, index, "never above the index");
            assertLe((index - p) * PPM, stamp * index, "never past the stamp");
            if (p != limit) assertLt(stamp * index - (index - p) * PPM, PPM, "the stamp, rounded up");
        }
    }

    /// @notice A quote stamped and filled against the same index counts at its own limit: the
    ///         stamp rounds up, so an honest far-side quote loses nothing to the cap unless it sits
    ///         past the band, where the print is clamped anyway.
    function testFuzz_printPrice_sameIndexKeepsTheQuote(bool isLong, uint256 index, uint256 gapPpm) public pure {
        index = bound(index, 1e6, 1e30);
        gapPpm = bound(gapPpm, 0, BAND_PPM - 1);
        // Strictly inside the band: the stamp is the gap's ppm rounded up, at most BAND_PPM.
        uint256 gap = index * gapPpm / PPM + 1;
        uint256 limit = isLong ? index + gap : index - gap;
        uint16 stamp = FundingLib.restedPremiumOf(isLong, limit, index);
        assertGt(stamp, 0, "a far-side quote is stamped");
        assertEq(FundingLib.printPriceOf(isLong, limit, stamp, index), limit, "counted at its limit");
    }

    /// @notice The stamp overstates the quote's distance by under one unit of its scale.
    function testFuzz_restedPremium_withinOneUnit(bool isLong, uint256 index, uint256 gap) public pure {
        index = bound(index, 1e6, 1e30);
        gap = bound(gap, 1, index * (BAND_PPM - 1) / PPM);
        uint256 limit = isLong ? index + gap : index - gap;
        uint256 stamp = FundingLib.restedPremiumOf(isLong, limit, index);
        assertGe(stamp * index, gap * PPM, "never under the distance");
        assertLt(stamp * index - gap * PPM, index, "over it by under one unit");
    }
}
