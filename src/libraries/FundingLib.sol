// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BazaarTypes} from "./BazaarTypes.sol";
import {RiskParamsLib} from "./RiskParamsLib.sol";

/// @title FundingLib
/// @notice Mark-price and funding-index accrual math for BazaarPair.
/// @dev Deployed as an EXTERNAL library (DELEGATECALL, like MatchingEngineLib et al.) so its
///      bytecode does not count toward BazaarPair's EIP-170 limit. The pair's mark state lives in
///      scalar storage vars, so the external functions take values and return the updated values
///      for the pair's thin wrappers to write back (each has exactly one call site in the pair).
///      Both take the pair's vault by storage pointer and size the volume floor from its open
///      interest themselves, so the pair computes that floor nowhere.
library FundingLib {
    uint256 internal constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 internal constant BP_SCALE = BazaarTypes.BP_SCALE;

    uint256 internal constant FUNDING_INTERVAL = 1 hours;
    // Hourly rate ceilings, split on the pair's trading calendar. A session-bound pair accrues only
    // while its oracle is fresh — roughly a fifth of the week — so matching a continuously traded
    // pair's corrective force per calendar week takes a higher ceiling per accruing hour.
    uint256 internal constant MAX_FUNDING_RATE_SESSION = BAZAAR_SCALE / 200; // 0.5% per FUNDING_INTERVAL
    uint256 internal constant MAX_FUNDING_RATE_CONTINUOUS = BAZAAR_SCALE / 1000; // 0.1% per FUNDING_INTERVAL
    uint256 internal constant MAX_FUNDING_AGE = 30 minutes;
    uint256 internal constant MAX_FUNDING_GAP = 12 hours;
    uint256 internal constant MARK_DECAY_PERIOD = 1 hours;
    // One band for every pair, so the mark carries the same meaning wherever it is read.
    uint256 internal constant MAX_MARK_DEVIATION_BP = 400;
    // Accruing hours of funding needed to pay off the mark-index gap: the premium is divided by
    // this before the rate clamp, so a smaller value makes funding a stronger convergence force.
    // Derived from the band and the pair's ceiling rather than chosen, so a mark exactly at the
    // band edge yields exactly that ceiling and the clamp is never reached from strictly inside the
    // band. Declaring band, rate and dampener independently is what leaves a stretch of the band
    // over which funding is already saturated and stops responding to further mark movement — the
    // region a manipulated mark aims for. Holding the band common across pair types is what forces
    // the two dampeners apart; they still land at comparable calendar horizons, since 8 accruing
    // hours is a little over a day on a session pair and 40 is a little under two on a continuous
    // one.
    uint256 internal constant FUNDING_DAMPENER_SESSION =
        MAX_MARK_DEVIATION_BP * BAZAAR_SCALE / (MAX_FUNDING_RATE_SESSION * BP_SCALE);
    uint256 internal constant FUNDING_DAMPENER_CONTINUOUS =
        MAX_MARK_DEVIATION_BP * BAZAAR_SCALE / (MAX_FUNDING_RATE_CONTINUOUS * BP_SCALE);

    // Floor on the volume the premium tally is read over, as a share of open-interest notional.
    // Denominating it in open interest is what makes it scale-free: funding transfers a percentage
    // of open interest, so the size a print needs before it can move the mark is measured in the
    // same units as what moving the mark is worth, on pairs of any size, and a pair with no open
    // interest has nothing to transfer. The floor sets how big an exposed quote has to be to
    // matter: a quote smaller than it reads only its own share of its premium. The exposure weight
    // below is what makes a print cost its maker anything at all.
    uint256 internal constant VOLUME_FLOOR_BP = 200; // 2% of per-side open-interest notional
    // How long a maker must have stood in the book, in Arbitrum L2 blocks (~250 ms each), for a
    // fill against it to enter the mark at full weight; a younger maker's fill enters in
    // proportion to its age, and one placed in the same block not at all. A print carries no
    // cost of its own — two accounts under one owner can print any admissible price for a fee —
    // so the mark is built only from fills against standing offers on the far side of the index
    // (MatchingEngineLib._accrueMarkPrint), and a standing offer costs its maker something only
    // for as long as it stood where anyone could take it. Measured in blocks rather than seconds
    // because a block is one opportunity for another transaction to land: an order that rested
    // through a stretch with no blocks was on offer to nobody, and an order placed and taken in
    // one block was never on offer at all. The window is about ten seconds. What it buys is the
    // time a watcher has to take a quote resting away from fair before its owner can take it back
    // at full weight. On a pair with bots watching, a quote at the band edge is taken within a
    // block or two, and on a pair nobody watches no window helps, so a window of seconds keeps
    // nearly all the protection a window of minutes would, while a longer window would discount
    // the fills that say the most: on an active pair a bid above the index is taken within seconds
    // by someone who chose to pay above fair, and that fill would carry only a sliver of weight.
    uint256 internal constant MAKER_EXPOSURE_BLOCKS = 40; // ~10 s
    // The unit Order.restedPremiumPpm is stored in: millionths of the index. Fine enough that the
    // rounding at the link moves a quote's stamp by under a hundredth of a basis point, and the
    // band (MAX_MARK_DEVIATION_BP) in it fits the uint16 field.
    uint256 internal constant RESTED_PREMIUM_SCALE = 1e6;
    // The most volume one matching call may add, as a share (in BP_SCALE) of the volume it is
    // weighed against: the larger of the line's volume now and the floor. A call therefore moves
    // the reading at most a quarter of the way toward its print, whether the floor binds or the
    // volume does. The volume a call records is clipped the same way, so the tallies stay a
    // weighted average of what was admitted. Not a manipulation bound: an attacker's cost is the
    // notional they must leave exposed on the far side, which the cap leaves unchanged, since it
    // only splits a given admission into more calls, and calls cost gas. What it bounds is one
    // anomalous print, and what it costs is cadence: a capped call moves the anchor only by its
    // share of the volume, so a stream of capped calls every T seconds holds its volume above the
    // floor only while T is under cap × MARK_DECAY_PERIOD / (2 + cap), about six and a half
    // minutes at a quarter against under three at a tenth. A quarter lets a pair with nine
    // qualifying fills an hour read its premium in full while holding one call's reach to a
    // quarter of the band; a half would buy little more cadence for twice the one-call reach.
    uint256 internal constant MAX_ALPHA = 2500; // 25% of BP_SCALE

    /// @notice The pair's mark state (scalar storage vars in BazaarPair): two tallies of the
    ///         fills that count, held on one fading line.
    /// @dev `rollingVolume` is the exposure-weighted notional of the admitted prints and
    ///      `premiumNotional` is that notional times each print's premium over the index (a signed
    ///      fraction of the index, BAZAAR_SCALE = 100%), so in notional units. Both are the line's
    ///      values at `lastMarkUpdateTs`, its anchor, and from there both run linearly to zero over
    ///      MARK_DECAY_PERIOD. The mark's premium at any moment is the premium tally over the larger
    ///      of the volume tally and the open-interest floor (premiumAt), and the mark is the index
    ///      of the moment carried by that premium (currentMark), so a move of the index moves the
    ///      mark with it and only a premium some print traded at, measured against the index of its
    ///      moment, is ever charged.
    ///
    ///      The premium is read as a ratio of the two tallies rather than blended toward each print
    ///      because a blend that fades between prints balances each print's pull against the fade
    ///      and settles at half of a steady premium whatever the flow; the fade scales both tallies
    ///      alike, so the ratio reads a sustained premium in full. While the volume is above the
    ///      floor the reading is the hour's volume-weighted average premium, which prints stopping
    ///      leaves standing until the volume fades under the floor; below the floor the reading
    ///      fades with the premium tally. That hold is what any fade of the ratio itself between
    ///      prints would give back as bias, and a hold timed from the last print is what a dust
    ///      print could restart; volume above the floor is a hold a dust print extends only by the
    ///      volume it adds.
    ///
    ///      The anchor is not the time of the last print. An update moves it toward the present
    ///      only by the share of the volume its print adds (updateMarkPrice), so it can predate
    ///      that print, and the stored values then sit at least as far from zero as any reading
    ///      taken since. Read them through premiumAt, never raw. A zero anchor means no mark has
    ///      formed.
    struct MarkState {
        int256 premiumNotional;
        uint256 lastMarkUpdateTs;
        uint256 rollingVolume;
    }

    /// @notice The volume floor the premium tally is read over: VOLUME_FLOOR_BP of per-side
    ///         open-interest notional.
    /// @param oiSize Per-side open-interest size (RiskParamsLib.openInterestSize)
    /// @param indexPrice The index that notional is taken at
    /// @return The floor, in notional units
    function floorVolumeOf(uint256 oiSize, uint256 indexPrice) internal pure returns (uint256) {
        return Math.mulDiv(oiSize, indexPrice, BAZAAR_SCALE) * VOLUME_FLOOR_BP / BP_SCALE;
    }

    /// @dev The line's two tallies at `t`: their values at the anchor scaled by the share of the
    ///      period the line has left, zero once it has run out or before any mark has formed, and
    ///      the anchor values themselves for a `t` at or before the anchor. The accrual can open a
    ///      window a few seconds before the anchor, since a print judged against a price stored by
    ///      an earlier call within MAX_PRICE_STALENESS lands after that call's accrual.
    function _lineAt(int256 premiumNotional, uint256 rollingVolume, uint256 anchor, uint256 t)
        private
        pure
        returns (int256 pn, uint256 vol)
    {
        if (anchor == 0) return (0, 0);
        if (t <= anchor) return (premiumNotional, rollingVolume);
        uint256 age = t - anchor;
        if (age >= MARK_DECAY_PERIOD) return (0, 0);
        uint256 left = MARK_DECAY_PERIOD - age;
        pn = premiumNotional * int256(left) / int256(MARK_DECAY_PERIOD);
        vol = rollingVolume * left / MARK_DECAY_PERIOD;
    }

    /// @notice The premium the stored line reads at `t`: its premium tally over the larger of its
    ///         volume tally and the floor, zero before any mark has formed or once the line has
    ///         run out.
    /// @dev A reading never leaves the band: every admitted print's premium is clamped to it and the
    ///      tallies are a weighted sum of such prints, so the ratio stays inside it up to the
    ///      rounding of the stored values, which the reading clips off.
    /// @param premiumNotional The stored premium tally, the line's value at its anchor (MarkState)
    /// @param rollingVolume The stored volume tally, the line's value at its anchor (MarkState)
    /// @param anchor The line's anchor; 0 before any mark has formed
    /// @param floorVolume The volume floor (floorVolumeOf)
    /// @param t The moment to read the line at
    /// @return The premium at `t`, a signed fraction of the index (BAZAAR_SCALE = 100%)
    function premiumAt(int256 premiumNotional, uint256 rollingVolume, uint256 anchor, uint256 floorVolume, uint256 t)
        internal
        pure
        returns (int256)
    {
        (int256 pn, uint256 vol) = _lineAt(premiumNotional, rollingVolume, anchor, t);
        uint256 denom = Math.max(vol, floorVolume);
        if (denom == 0) return 0;
        uint256 magnitude =
            Math.min(Math.mulDiv(_abs(pn), BAZAAR_SCALE, denom), MAX_MARK_DEVIATION_BP * BAZAAR_SCALE / BP_SCALE);
        return pn < 0 ? -int256(magnitude) : int256(magnitude);
    }

    /// @notice The premium the stored line reads at this block (premiumAt).
    /// @param premiumNotional The stored premium tally (MarkState)
    /// @param rollingVolume The stored volume tally (MarkState)
    /// @param lastMarkUpdateTs The line's anchor; 0 before any mark has formed
    /// @param floorVolume The volume floor (floorVolumeOf)
    /// @return The premium at this block, a signed fraction of the index (BAZAAR_SCALE = 100%)
    function currentPremium(
        int256 premiumNotional,
        uint256 rollingVolume,
        uint256 lastMarkUpdateTs,
        uint256 floorVolume
    ) internal view returns (int256) {
        return premiumAt(premiumNotional, rollingVolume, lastMarkUpdateTs, floorVolume, block.timestamp);
    }

    /// @notice The mark at this block: `indexPrice` carried by the stored line's current premium.
    /// @dev A reading never leaves the band (premiumAt), so the factor applied to the index is
    ///      always positive.
    /// @param premiumNotional The stored premium tally (MarkState)
    /// @param rollingVolume The stored volume tally (MarkState)
    /// @param lastMarkUpdateTs The line's anchor; 0 before any mark has formed
    /// @param floorVolume The volume floor (floorVolumeOf)
    /// @param indexPrice The index the premium is carried on
    /// @return The mark at this block, BAZAAR_SCALE precision
    function currentMark(
        int256 premiumNotional,
        uint256 rollingVolume,
        uint256 lastMarkUpdateTs,
        uint256 floorVolume,
        uint256 indexPrice
    ) internal view returns (uint256) {
        int256 factor = int256(BAZAAR_SCALE)
            + currentPremium(premiumNotional, rollingVolume, lastMarkUpdateTs, floorVolume);
        return Math.mulDiv(indexPrice, SafeCast.toUint256(factor), BAZAAR_SCALE);
    }

    /// @notice The weight a fill against a resting maker carries into the mark: the number of
    ///         blocks the maker has stood in the book at its current price and size, capped at
    ///         MAKER_EXPOSURE_BLOCKS. A caller scales the fill's notional and size by
    ///         weight / MAKER_EXPOSURE_BLOCKS before handing them to updateMarkPrice.
    /// @dev The subtraction runs on the block's low 32 bits and wraps, so the result is exact for
    ///      any maker younger than 2^32 blocks whatever the absolute block number, including across
    ///      the counter passing a multiple of 2^32; an order cannot rest that long.
    /// @param currentBlock The L2 block the fill executes in.
    /// @param restedBlock The maker's Order.restedBlock.
    /// @return The weight, 0 … MAKER_EXPOSURE_BLOCKS.
    function makerExposureWeight(uint64 currentBlock, uint32 restedBlock) internal pure returns (uint256) {
        uint32 age;
        unchecked {
            age = uint32(currentBlock) - restedBlock;
        }
        return age < MAKER_EXPOSURE_BLOCKS ? uint256(age) : MAKER_EXPOSURE_BLOCKS;
    }

    /// @notice How far on the far side of the index a quote stands — a bid's distance above it
    ///         or an ask's below it — as the book stamps it on the order when it links
    ///         (Order.restedPremiumPpm). Zero on the near side, at the index, and with no index.
    /// @dev Rounded up, so a fill at the index the quote linked at counts the quote's own premium
    ///      exactly (printPriceOf) rather than a sliver less; the stamp then exceeds the true
    ///      distance by under one unit. Capped at the band, the furthest the mark ever reads from
    ///      the index, which also keeps the value inside the uint16 field.
    /// @param isLong The quote's side: true for a bid
    /// @param limitPrice The quote's limit price
    /// @param indexPrice The fresh index the link is measured against; 0 when the caller holds
    ///        none, which stamps zero
    /// @return The far-side distance in millionths of the index (RESTED_PREMIUM_SCALE)
    function restedPremiumOf(bool isLong, uint256 limitPrice, uint256 indexPrice) internal pure returns (uint16) {
        if (indexPrice == 0 || (isLong ? limitPrice <= indexPrice : limitPrice >= indexPrice)) return 0;
        uint256 gap = isLong ? limitPrice - indexPrice : indexPrice - limitPrice;
        uint256 ppm = Math.ceilDiv(gap * RESTED_PREMIUM_SCALE, indexPrice);
        uint256 cap = MAX_MARK_DEVIATION_BP * RESTED_PREMIUM_SCALE / BP_SCALE;
        return uint16(ppm < cap ? ppm : cap);
    }

    /// @notice The price a fill against a resting far-side maker enters the mark at: the maker's
    ///         limit, pulled back toward the index so that its premium is no larger than the
    ///         premium the maker rested at (restedPremiumOf). A quote proves only the premium it
    ///         stood at where anyone could take it, so a move of the index past it adds nothing.
    /// @dev The bound rounds toward the index on both sides (down for a bid, up for an ask), so
    ///      the counted premium never exceeds the stamped one, nor the fill's own; with the stamp
    ///      rounded up, a fill at the index the maker linked at is counted at its limit.
    /// @param isLong The maker's side: true for a bid
    /// @param limitPrice The maker's limit, the price the fill executed at
    /// @param restedPremiumPpm The maker's Order.restedPremiumPpm
    /// @param indexPrice The index the fill is judged against
    /// @return The price to count the fill at in the mark
    function printPriceOf(bool isLong, uint256 limitPrice, uint256 restedPremiumPpm, uint256 indexPrice)
        internal
        pure
        returns (uint256)
    {
        if (isLong) {
            uint256 high = indexPrice * (RESTED_PREMIUM_SCALE + restedPremiumPpm) / RESTED_PREMIUM_SCALE;
            return limitPrice < high ? limitPrice : high;
        }
        uint256 low = Math.ceilDiv(indexPrice * (RESTED_PREMIUM_SCALE - restedPremiumPpm), RESTED_PREMIUM_SCALE);
        return limitPrice > low ? limitPrice : low;
    }

    /// @notice Folds one matching call's qualifying fills into the mark.
    /// @dev The call's weighted notional is admitted up to MAX_ALPHA of the volume it is weighed
    ///      against, the larger of the line's volume now and the open-interest floor, and that
    ///      admitted notional enters both tallies: the volume as it is, the premium tally times
    ///      the print's premium over the index. The cap is the single-call bound: a call moves the
    ///      reading at most a quarter of the way toward its print. The floor is load-bearing in the
    ///      other direction: `rollingVolume` is fed only by prior calls to this function, so without
    ///      the floor a pair with no other traders would let one account supply the entire
    ///      denominator and read every dust print in full. A call whose admitted notional rounds to
    ///      zero — a print against no volume and no open interest — writes nothing. The exec price
    ///      is clamped to ±MAX_MARK_DEVIATION_BP of the index before its premium is taken, so an
    ///      implausible print moves the mark no further than one at the band's edge, and the
    ///      reading, a weighted average of clamped premiums, never leaves the band.
    ///      The notional and size a caller passes are already exposure-weighted, already filtered
    ///      to fills against makers on the far side of the index that also linked on the far
    ///      side, and already priced at no more premium than each maker linked at
    ///      (MatchingEngineLib._accrueMarkPrint, printPriceOf): this function sees only the
    ///      volume that counts, so fills that do not count can neither move the mark nor swell
    ///      the denominator the counting ones are weighed against.
    ///
    ///      The decay clock. The new anchor sits back from this block by the old line's age
    ///      weighted by the old volume's share of the two: kept age = age × old / (old + admitted),
    ///      rounded up, so no print moves the anchor further than its share, and a print whose
    ///      share of the age is under a second moves it not at all. A print on a spent line, or on
    ///      no line, gets the full period; one that adds little to a live line moves its end
    ///      little. An anchor at the print's own time would instead give the whole line a fresh
    ///      period at every admitted fill, so dust prints could hold the tallies, and the premium
    ///      read from them, up indefinitely. Measured on volume rather than on premium so that a
    ///      print against the premium, which adds volume while taking premium away, extends the
    ///      line exactly as much as it dilutes it.
    ///
    ///      The tallies are stored as of the new anchor, scaled so that at this block the line
    ///      reads the decayed tallies plus this fill. A second update in the same block therefore
    ///      finds what this one left, to within rounding, and decays nothing twice.
    /// @param s Mark state to advance: the stored line (MarkState).
    /// @param fillNotional Σ(weight × price × size) over this call's qualifying fills, each at
    ///        its print price (printPriceOf): both the VWAP numerator and the notional the call is
    ///        weighed by. Zero writes nothing.
    /// @param fillSize Σ(weight × size) over the same fills — the VWAP denominator.
    /// @param indexPrice Oracle price the deviation band and the print's premium are measured from.
    ///        Zero writes nothing.
    /// @param vault The pair's vault, whose open interest sizes the floor. Liquidation, ADL and
    ///        settlement each move size off a single leg, and a floor that fell with them would
    ///        make the mark more sensitive per fill exactly while the vault unloads the inventory
    ///        those moves created, so the floor is taken per side with the vault's inventory
    ///        counted on its side (RiskParamsLib.openInterestSize).
    /// @return The advanced mark state, for the caller to write back.
    function updateMarkPrice(
        MarkState memory s,
        uint256 fillNotional,
        uint256 fillSize,
        uint256 indexPrice,
        BazaarTypes.Vault storage vault
    ) external view returns (MarkState memory) {
        if (fillNotional == 0 || indexPrice == 0) return s;

        // How far the stored line has run, and what it reads now. A mark that never formed has no
        // line, and no volume.
        uint256 age = s.lastMarkUpdateTs == 0
            ? MARK_DECAY_PERIOD
            : Math.min(block.timestamp - s.lastMarkUpdateTs, MARK_DECAY_PERIOD);
        (int256 decayedPremiumNotional, uint256 decayedVolume) =
            _lineAt(s.premiumNotional, s.rollingVolume, s.lastMarkUpdateTs, block.timestamp);

        // fillNotional IS Σ(print price × size), so it is the exact VWAP numerator — the walk's
        // average print price needs no re-derivation. A non-zero notional implies a non-zero
        // size, so the division is safe past the early-out above.
        uint256 execPrice = Math.mulDiv(fillNotional, BAZAAR_SCALE, fillSize);

        uint256 floorVolume = floorVolumeOf(RiskParamsLib.openInterestSize(vault), indexPrice);
        uint256 admitted = Math.min(fillNotional, Math.max(decayedVolume, floorVolume) * MAX_ALPHA / BP_SCALE);
        if (admitted == 0) return s;

        // Clamp the print to a band around the index before taking its premium, so a wash trade
        // between two resting limits at an arbitrary price (fresh-oracle limit fills carry no
        // price band of their own) can't inject that price into the mark. Both edges round
        // toward the index, so the clamped print's premium never exceeds the band.
        uint256 bandHigh = indexPrice * (BP_SCALE + MAX_MARK_DEVIATION_BP) / BP_SCALE;
        uint256 bandLow = Math.ceilDiv(indexPrice * (BP_SCALE - MAX_MARK_DEVIATION_BP), BP_SCALE);
        uint256 boundedExec = Math.min(Math.max(execPrice, bandLow), bandHigh);
        int256 printPremium = (int256(boundedExec) - int256(indexPrice)) * int256(BAZAAR_SCALE) / int256(indexPrice);

        // A non-zero decayed volume means the old line is still running, so `age` is under the
        // period and so is any age the anchor keeps.
        uint256 keptAge =
            decayedVolume == 0 ? 0 : Math.mulDiv(age, decayedVolume, decayedVolume + admitted, Math.Rounding.Ceil);
        uint256 rest = MARK_DECAY_PERIOD - keptAge;

        s.lastMarkUpdateTs = block.timestamp - keptAge;
        s.premiumNotional = (decayedPremiumNotional + int256(admitted) * printPremium / int256(BAZAAR_SCALE))
            * int256(MARK_DECAY_PERIOD) / int256(rest);
        s.rollingVolume = (decayedVolume + admitted) * MARK_DECAY_PERIOD / rest;
        return s;
    }

    /// @dev The size of a signed tally.
    function _abs(int256 x) private pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    /// @notice The time-average of the premium the stored line reads over [from, to).
    /// @dev The reading is flat while the line's volume is above the floor and a straight line
    ///      once it is under it, so the average is exact from the held reading over the flat piece
    ///      and a trapezoid over the fade. The flat piece is taken as a constant rather than a
    ///      trapezoid because with no floor it runs to the line's very end, where the reading
    ///      drops to zero rather than fading there. Time before the anchor or after the line's end
    ///      reads zero. Charging a window at its closing reading instead would miss most of a
    ///      premium that fades inside the window, and all of one whose line runs out before the
    ///      window closes, which on a quiet pair with stores half an hour apart is the common
    ///      case.
    /// @param s The stored line (MarkState)
    /// @param floorVolume The volume floor (floorVolumeOf)
    /// @param from Start of the window
    /// @param to End of the window; at or before `from` averages to zero
    /// @return The average premium, a signed fraction of the index (BAZAAR_SCALE = 100%)
    function averagePremium(MarkState memory s, uint256 floorVolume, uint256 from, uint256 to)
        internal
        pure
        returns (int256)
    {
        if (to <= from || s.lastMarkUpdateTs == 0) return 0;
        uint256 anchor = s.lastMarkUpdateTs;
        uint256 end = anchor + MARK_DECAY_PERIOD;
        uint256 a0 = Math.max(from, anchor);
        uint256 a1 = Math.min(to, end);
        if (a1 <= a0) return 0;

        // Where the fading volume crosses the floor: the whole line is flat when there is no
        // floor, and fades from its anchor when it never stood above the floor.
        uint256 kink =
            s.rollingVolume > floorVolume ? end - Math.mulDiv(floorVolume, MARK_DECAY_PERIOD, s.rollingVolume) : anchor;
        kink = Math.min(Math.max(kink, a0), a1);

        int256 held = premiumAt(s.premiumNotional, s.rollingVolume, anchor, floorVolume, a0) * int256(kink - a0);
        return (held + _trapezoid(s, floorVolume, kink, a1)) / int256(to - from);
    }

    /// @dev ∫ premium dt over [x, y], exact while the reading is linear on it.
    function _trapezoid(MarkState memory s, uint256 floorVolume, uint256 x, uint256 y) private pure returns (int256) {
        if (y <= x) return 0;
        int256 px = premiumAt(s.premiumNotional, s.rollingVolume, s.lastMarkUpdateTs, floorVolume, x);
        int256 py = premiumAt(s.premiumNotional, s.rollingVolume, s.lastMarkUpdateTs, floorVolume, y);
        return (px + py) * int256(y - x) / 2;
    }

    /// @notice Updates funding index
    /// @dev The window accrues at the time-average of the premium the stored line reads across it
    ///      (averagePremium), with the floor sized from the open interest and index at this store.
    /// @param premiumNotional The stored premium tally (MarkState)
    /// @param rollingVolume The stored volume tally (MarkState)
    /// @param lastMarkUpdateTs The mark line's anchor; 0 before any mark has formed
    /// @param currentFundingIndex The cumulative funding index before this accrual
    /// @param lastFundingUpdateTs When the index last accrued
    /// @param indexPrice The oracle price just stored, which the accrual is scaled by; zero accrues
    ///        nothing
    /// @param oracleUpdateTs That price's publish time, which bounds the window the accrual covers
    /// @param vault The pair's vault, whose open interest sizes the floor
    /// @param isContinuouslyTraded Selects the pair's rate ceiling and its paired dampener. Both
    ///        pairings put the ceiling exactly at MAX_MARK_DEVIATION_BP of premium, so the choice
    ///        changes how hard funding pulls, never how far the mark may sit from the index.
    /// @return newFundingIndex The updated cumulative funding index (price units)
    /// @return newLastFundingUpdateTs The updated accrual timestamp
    function updateFundingIndex(
        int256 premiumNotional,
        uint256 rollingVolume,
        uint256 lastMarkUpdateTs,
        int256 currentFundingIndex,
        uint256 lastFundingUpdateTs,
        uint256 indexPrice,
        uint256 oracleUpdateTs,
        BazaarTypes.Vault storage vault,
        bool isContinuouslyTraded
    ) external view returns (int256 newFundingIndex, uint256 newLastFundingUpdateTs) {
        uint256 currentTs = block.timestamp;
        uint256 lastUpdate = lastFundingUpdateTs;

        if (currentTs <= lastUpdate) return (currentFundingIndex, lastFundingUpdateTs);

        uint256 validStart = lastUpdate;
        if (oracleUpdateTs > lastUpdate + MAX_FUNDING_GAP) {
            validStart = oracleUpdateTs;
        } else if (oracleUpdateTs > lastUpdate + MAX_FUNDING_AGE) {
            validStart = oracleUpdateTs > MAX_FUNDING_AGE ? oracleUpdateTs - MAX_FUNDING_AGE : 0;
        }

        if (validStart >= currentTs) {
            return (currentFundingIndex, currentTs);
        }

        uint256 elapsed = currentTs - validStart;
        if (elapsed == 0) {
            return (currentFundingIndex, currentTs);
        }

        if (indexPrice == 0) {
            return (currentFundingIndex, currentTs);
        }

        // Ceiling and dampener are one pairing, never mixed: each dampener is derived from its own
        // ceiling against the shared band, so taking one from each pair type would put the clamp
        // back inside the band.
        (uint256 maxRate, uint256 dampener) = isContinuouslyTraded
            ? (MAX_FUNDING_RATE_CONTINUOUS, FUNDING_DAMPENER_CONTINUOUS)
            : (MAX_FUNDING_RATE_SESSION, FUNDING_DAMPENER_SESSION);

        int256 premium = averagePremium(
            MarkState({
                premiumNotional: premiumNotional, lastMarkUpdateTs: lastMarkUpdateTs, rollingVolume: rollingVolume
            }),
            floorVolumeOf(RiskParamsLib.openInterestSize(vault), indexPrice),
            validStart,
            currentTs
        );
        int256 dampenedPremium = premium / int256(dampener);

        int256 fundingRate;
        if (dampenedPremium > int256(maxRate)) {
            fundingRate = int256(maxRate);
        } else if (dampenedPremium < -int256(maxRate)) {
            fundingRate = -int256(maxRate);
        } else {
            fundingRate = dampenedPremium;
        }

        // Accumulate in price units (rate × indexPrice): BucketLib computes funding PnL as
        // Δindex × size / 1e18, so the index must carry the price factor for PnL to be on notional.
        int256 fundingDelta =
            fundingRate * int256(indexPrice) * int256(elapsed) / int256(BAZAAR_SCALE) / int256(FUNDING_INTERVAL);
        return (currentFundingIndex + fundingDelta, currentTs);
    }
}
