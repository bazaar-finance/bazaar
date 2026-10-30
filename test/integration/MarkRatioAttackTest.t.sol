// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";

/// @title MarkRatioAttackTest
/// @notice What the two-tally mark gives an attacker, pinned at the pair level. One call moves the
///         reading at most a quarter of the way to its print whatever its size; a block of calls
///         compounds only through that cap, each weighed against the volume the ones before it
///         recorded and against a floor the attacker's own open interest keeps raising; a wash
///         under the floor reads its own share of the floor and fades within the hour; dust riding
///         a held premium moves neither its anchor nor its reading beyond its own weight; a fill
///         that leaves no open interest and no volume is not recorded; and a store landing after a
///         held premium has run out charges the window's average, not its closing reading of zero.
contract MarkRatioAttackTest is IntegrationBase {
    uint256 constant BTC = 1e18;
    uint256 constant ORACLE = 50_000 * BAZAAR_SCALE;
    uint256 constant EDGE = 52_000 * BAZAAR_SCALE; // the band edge, 4% over the oracle
    uint256 constant BASE = BTC / 2; // the open interest every test starts from: a $500 floor
    uint256 constant BIG = BTC / 1040; // $49 at $51k: under the $50 cap that floor sets
    uint256 constant W = FundingLib.MAKER_EXPOSURE_BLOCKS;
    uint256 constant PERIOD = FundingLib.MARK_DECAY_PERIOD;
    uint256 constant BAND = FundingLib.MAX_MARK_DEVIATION_BP * 1e14;

    /// @dev A copy of the pair's open-interest aggregates, so the library can be replayed against
    ///      the floor the pair's own update saw.
    BazaarTypes.Vault internal vaultMirror;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 1_000_000 * BAZAAR_SCALE);
        _deposit(bob, 1_000_000 * BAZAAR_SCALE);
        _deposit(carol, 1_000_000 * BAZAAR_SCALE);
        _deposit(dave, 1_000_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, BASE, ORACLE);
        _roll(W);
        _placeLimit(bob, false, BASE, ORACLE);
    }

    // ---------------------------- helpers ----------------------------

    function _mark() internal view returns (uint256) {
        return lens.markPrice(address(pair));
    }

    /// @dev The mark's premium over the oracle, as the lens reads it.
    function _premium() internal view returns (int256) {
        return (int256(_mark()) - int256(ORACLE)) * int256(BAZAAR_SCALE) / int256(ORACLE);
    }

    function _anchor() internal view returns (uint256) {
        return pair.auxState().lastMarkUpdateTs;
    }

    /// @dev Per-side open interest, counting the vault's inventory on its side, as the floor is
    ///      sized (RiskParamsLib.openInterestSize).
    function _oiSize() internal view returns (uint256) {
        (uint256 l, uint256 s,,,,, uint256 pend,,,, bool pendLong,,,,,,) = pair.pairVault();
        if (pendLong) l += pend;
        else s += pend;
        return l > s ? l : s;
    }

    function _floor(uint256 index) internal view returns (uint256) {
        return FundingLib.floorVolumeOf(_oiSize(), index);
    }

    /// @dev The pair's stored line: anchor and volume tally from auxState, the premium tally from
    ///      its slot, the one BazaarPairLens names SLOT_MARK_PREMIUM_NOTIONAL.
    function _storedLine() internal view returns (FundingLib.MarkState memory s) {
        BazaarTypes.AuxState memory a = pair.auxState();
        s.lastMarkUpdateTs = a.lastMarkUpdateTs;
        s.rollingVolume = a.rollingVolume;
        s.premiumNotional = int256(uint256(vm.load(address(pair), bytes32(uint256(63)))));
    }

    /// @dev The volume tally the line reads now.
    function _liveVolume() internal view returns (uint256) {
        BazaarTypes.AuxState memory a = pair.auxState();
        if (a.lastMarkUpdateTs == 0) return 0;
        uint256 age = vm.getBlockTimestamp() - a.lastMarkUpdateTs;
        if (age >= PERIOD) return 0;
        return a.rollingVolume * (PERIOD - age) / PERIOD;
    }

    /// @dev FundingLib's update from `line` for a full-weight fill of `size` at `price` judged
    ///      against `index`, with the floor sized from the open interest the pair holds now.
    function _replay(FundingLib.MarkState memory line, uint256 size, uint256 price, uint256 index)
        internal
        returns (FundingLib.MarkState memory)
    {
        (uint256 l, uint256 s,,,,, uint256 pend,,,, bool pendLong,,,,,,) = pair.pairVault();
        vaultMirror.totalLongOI = l;
        vaultMirror.totalShortOI = s;
        vaultMirror.pendingLiqSize = pend;
        vaultMirror.pendingLiqIsLong = pendLong;
        return FundingLib.updateMarkPrice(line, size * price / BAZAAR_SCALE, size, index, vaultMirror);
    }

    function _assertLine(FundingLib.MarkState memory got, FundingLib.MarkState memory want, string memory why)
        internal
        pure
    {
        assertEq(got.premiumNotional, want.premiumNotional, string.concat(why, ": premium tally"));
        assertEq(got.lastMarkUpdateTs, want.lastMarkUpdateTs, string.concat(why, ": anchor"));
        assertEq(got.rollingVolume, want.rollingVolume, string.concat(why, ": volume tally"));
    }

    /// @dev A full-weight far-side print: `maker`'s bid at `price` stands a whole exposure window
    ///      over the oracle before `taker` sells into it.
    function _farSidePrint(address maker, address taker, uint256 size, uint256 price) internal {
        _placeLimit(maker, true, size, price);
        _roll(W);
        _placeLimit(taker, false, size, price);
    }

    /// @dev Twenty $49 prints a minute apart at $51k: the line stands well above the floor.
    function _plateau() internal {
        for (uint256 k; k < 20; ++k) {
            _farSidePrint(alice, bob, BIG, 51_000 * BAZAAR_SCALE);
            vm.warp(vm.getBlockTimestamp() + 1 minutes);
        }
        assertGt(_liveVolume(), _floor(ORACLE), "fixture: the line stands above the floor");
    }

    // ---------------------------- the cap ----------------------------

    /// @notice One call, however large, moves the reading at most a quarter of the way to its
    ///         print. Two BTC sold into a bid 4% over the oracle that stood a full window: $104k
    ///         printed, $625 admitted (a quarter of the $2,500 floor the open interest then sets),
    ///         and the mark lands a quarter of the band over the index.
    function test_oneCall_movesAtMostAQuarterOfTheWay() public {
        _farSidePrint(carol, dave, 2 * BTC, EDGE);
        assertEq(_oiSize(), BASE + 2 * BTC, "fixture: 2.5 BTC a side");
        assertEq(pair.auxState().rollingVolume, 625 * BAZAAR_SCALE, "the admitted notional, not the $104k printed");
        assertEq(_premium(), int256(BAND) / 4, "a quarter of the band");
    }

    /// @notice A block of calls compounds only through the cap. Ten sells into ten bids 4% over the
    ///         oracle, each a call of its own in one block: after each, the pair's line is exactly
    ///         what FundingLib.updateMarkPrice gives from the line before it against the open
    ///         interest the fill left. Each call admits a quarter of a floor the attacker's own open
    ///         interest keeps raising ($150, $175, … $250) until the fifth brings the volume to the
    ///         floor, then a quarter of a volume now above it; ten of them stand the reading at the
    ///         band edge, and no further. The count of calls prices nothing: the same exposed bids
    ///         carry the same admitted volume however many calls take them.
    function test_aBlockOfCalls_compoundsOnlyThroughTheCap() public {
        uint256 size = BTC / 10;
        for (uint256 k; k < 10; ++k) {
            _placeLimit(carol, true, size, EDGE);
        }
        _roll(W);
        for (uint256 k; k < 10; ++k) {
            FundingLib.MarkState memory before = _storedLine();
            _placeLimit(dave, false, size, EDGE);
            _assertLine(_storedLine(), _replay(before, size, EDGE, ORACLE), "the pair follows the library");
            assertLe(_premium(), int256(BAND), "never past the band");
        }
        assertGt(pair.auxState().rollingVolume, _floor(ORACLE), "the volume stands above the floor");
        assertEq(_premium(), int256(BAND), "the band edge after ten capped calls, and no further");
    }

    // ---------------------------- under the floor ----------------------------

    /// @notice A wash under the floor reads its own share of the floor and fades within the hour:
    ///         $10.40 sold into a bid 4% over the oracle reads 10.40 / 500.20 of the band, half of
    ///         that half an hour on, nothing after the hour.
    function test_washUnderTheFloor_readsItsShareAndFades() public {
        uint256 size = BTC / 5000; // 0.0002 BTC: $10.40 at the band edge
        _farSidePrint(carol, dave, size, EDGE);
        uint256 floorVolume = _floor(ORACLE);
        assertEq(floorVolume, (BASE + size) * 50_000 * 200 / 10_000, "fixture: 2% of the open interest at the oracle");
        int256 share = int256(size * 52_000) * int256(BAND) / int256(floorVolume);
        assertEq(_premium(), share, "its share of the floor");
        uint256 printedAt = vm.getBlockTimestamp();
        vm.warp(printedAt + 30 minutes);
        assertApproxEqAbs(_premium(), share / 2, 2, "half an hour on, half");
        vm.warp(printedAt + PERIOD);
        assertEq(_premium(), 0, "gone at the hour");
    }

    // ---------------------------- dust on a held premium ----------------------------

    /// @notice Dust riding a held premium moves neither the anchor nor the reading beyond its own
    ///         weight. Six $5 prints at the band edge, one every five minutes, each against a bid
    ///         that stood one block (13 cents of weighted notional), land on a line holding hundreds
    ///         of dollars of volume: each can move the anchor by at most its volume share of the
    ///         line's age, a second or so, and the reading by at most its weighted premium over the
    ///         live volume, and the premium is gone a period after the last anchor.
    function test_dustOnAHeldPremium_cannotExtendIt() public {
        _plateau();
        uint256 anchor0 = _anchor();
        uint256 dust = BTC / 10_000; // $5.20 at the band edge, weighted to $0.13 after one block
        uint256 weighted = dust * 52_000 / W;
        for (uint256 k = 1; k <= 6; ++k) {
            vm.warp(vm.getBlockTimestamp() + 5 minutes);
            uint256 anchorBefore = _anchor();
            uint256 volumeBefore = _liveVolume();
            uint256 markBefore = _mark();
            _placeLimit(carol, true, dust, EDGE);
            _roll(1);
            _placeLimit(dave, false, dust, EDGE);
            uint256 age = vm.getBlockTimestamp() - anchorBefore;
            assertLe(_anchor() - anchorBefore, age * weighted / volumeBefore + 1, "the anchor moves at most its share");
            uint256 bound = ORACLE * (weighted * BAND / volumeBefore) / BAZAAR_SCALE + 1;
            assertLe(_mark(), markBefore + bound, "the reading rises at most its weighted premium over the volume");
        }
        assertLe(_anchor() - anchor0, 12, "six dust prints bought the line under a dozen seconds");
        vm.warp(_anchor() + PERIOD);
        assertEq(_mark(), ORACLE, "gone a period after the anchor");
    }

    // ---------------------------- an empty pair ----------------------------

    /// @notice A fill that leaves no open interest and no volume is not recorded, so an empty pair
    ///         carries no line into its next life. Alice's ask 4% under the oracle (a far-side
    ///         quote) rests a window and Bob lifts it to close both positions: the pair is flat,
    ///         the floor is zero, there is no volume to weigh the print against, and the mark stays
    ///         unformed. The next far-side print starts a fresh line against the new open interest.
    function test_fillThatLeavesNoOpenInterest_isNotRecorded() public {
        _placeLimit(alice, false, BASE, 48_000 * BAZAAR_SCALE);
        _roll(W);
        _placeLimit(bob, true, BASE, 48_000 * BAZAAR_SCALE);
        assertEq(_oiSize(), 0, "fixture: both flat");
        assertEq(_anchor(), 0, "no line formed");
        assertEq(_mark(), 0, "no mark");

        _farSidePrint(carol, dave, BTC / 2000, EDGE);
        assertEq(_anchor(), vm.getBlockTimestamp(), "a fresh line against the new open interest");
        assertGt(_mark(), ORACLE, "with a premium");
    }

    // ---------------------------- the accrual ----------------------------

    /// @notice A store landing after a held premium has run out charges the window's average, not
    ///         its closing reading of zero. After the stream stops nothing stores until a second
    ///         past the line's end; the window the store accrues (the 30 minutes before it, by the
    ///         age cap) held the premium for part of its length and faded over the rest, and the
    ///         accrual is exactly FundingLib.averagePremium over it, while the mark at the store
    ///         reads the index.
    function test_storeAfterTheLineRanOut_chargesTheWindowsAverage() public {
        _plateau();
        FundingLib.MarkState memory line = _storedLine();
        int256 idxBefore = pair.currentFundingIndex();

        uint256 storeAt = line.lastMarkUpdateTs + PERIOD + 1;
        assertGt(storeAt, vm.getBlockTimestamp() + FundingLib.MAX_FUNDING_AGE, "fixture: past the age cap");
        vm.warp(storeAt);
        assertEq(_mark(), ORACLE, "fixture: the closing reading is the index");
        bytes[] memory pu = _freshPrice();
        vm.prank(seq);
        pair.refreshPrice(pu);

        int256 average = FundingLib.averagePremium(line, _floor(ORACLE), storeAt - FundingLib.MAX_FUNDING_AGE, storeAt);
        assertGt(average, 0, "the window read a premium for most of its length");
        uint256 dampener =
            pair.isContinuouslyTraded() ? FundingLib.FUNDING_DAMPENER_CONTINUOUS : FundingLib.FUNDING_DAMPENER_SESSION;
        int256 expected = average / int256(dampener) * int256(ORACLE) * int256(FundingLib.MAX_FUNDING_AGE)
            / int256(BAZAAR_SCALE) / int256(FundingLib.FUNDING_INTERVAL);
        assertEq(pair.currentFundingIndex() - idxBefore, expected, "charged at the window's average");
    }
}
