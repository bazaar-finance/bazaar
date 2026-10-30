// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BazaarMathLib} from "./libraries/BazaarMathLib.sol";
import {BazaarTypes} from "./libraries/BazaarTypes.sol";

/// @title BazaarOracle
/// @notice Shared Pyth oracle contract that all BazaarPair instances call.
///         Separates read (view) and write (payable) oracle interactions so
///         callers only send ETH when an on-chain price update is actually needed.
///         USDC quote is hardcoded to $1 — assets quoted directly in USD need only the
///         base asset price. Assets quoted in another currency use a registered
///         composite feed: a base leg (the asset in its native currency) combined with
///         an FX leg that converts that currency to USD. Composite IDs are deterministic
///         hashes of their legs and are passed around exactly like plain Pyth feed IDs;
///         callers never need to know whether an ID is raw or composite.
///         Returns directional bracket prices (low = spot − conf, high = spot + conf) so
///         callers can value long/short exposure conservatively without recomputing conf.
contract BazaarOracle {
    // -------------------- Errors --------------------
    error BazaarOracle__ZeroAddress();
    error BazaarOracle__InvalidPrice(bytes32 feedId, int64 price, int32 expo);
    error BazaarOracle__ConfidenceTooHigh(uint256 confidence, uint256 price);
    error BazaarOracle__InvalidCompositeLegs(bytes32 baseId, bytes32 quoteId);
    error BazaarOracle__SampleCountMismatch(uint256 updates, uint256 expected);
    error BazaarOracle__SampleFeeMismatch(uint256 supplied, uint256 required);

    // -------------------- Events --------------------
    event CompositeFeedRegistered(
        bytes32 indexed compositeId, bytes32 indexed baseId, bytes32 indexed quoteId, bool invertQuote
    );

    // -------------------- Types --------------------
    /// @param baseId Pyth feed for the asset in its native quote currency (e.g. a JPY-quoted stock)
    /// @param quoteId Pyth FX feed linking that currency to USD (e.g. GBP/USD or USD/JPY)
    /// @param invertQuote False when the FX feed is CCY/USD (multiply), true when it is USD/CCY (divide)
    struct CompositeFeed {
        bytes32 baseId;
        bytes32 quoteId;
        bool invertQuote;
    }

    /// @dev A chained sample set's legs and its running target, held in memory so the parse loop
    ///      stays shallow (see fetchChainedMedian).
    struct SampleChain {
        bytes32 baseId;
        bytes32 quoteId;
        bool invertQuote;
        uint256 legs;
        bytes32[] feedIds;
        uint64 target;
        uint64 maxPublishTime;
    }

    // -------------------- Constants --------------------
    int32 public constant BAZAAR_EXPONENT = BazaarTypes.BAZAAR_EXPONENT;
    uint256 public constant BAZAAR_SCALE = BazaarTypes.BAZAAR_SCALE;
    uint256 public constant BP_SCALE = BazaarTypes.BP_SCALE;
    uint256 public constant MAX_CONFIDENCE_BP = 200; // max Pyth confidence/price ratio: 2%

    // -------------------- Immutables --------------------
    IPyth public immutable pyth;

    // -------------------- Storage --------------------
    /// @notice compositeId => underlying legs. Empty baseId means the key is a raw Pyth feed ID.
    mapping(bytes32 => CompositeFeed) public composites;

    constructor(address _pyth) {
        if (_pyth == address(0)) revert BazaarOracle__ZeroAddress();
        pyth = IPyth(_pyth);
    }

    // ================================================================
    //                       Composite feed registry
    // ================================================================

    /// @notice Register a composite feed that prices a non-USD-quoted asset in USD by
    ///         combining the asset's native-currency feed with an FX feed.
    /// @dev Permissionless and idempotent: the composite ID is the hash of the legs, so a
    ///      given ID can only ever resolve to one (baseId, quoteId, invertQuote) tuple.
    /// @param baseId Pyth feed ID for the asset in its native quote currency
    /// @param quoteId Pyth FX feed ID linking that currency to USD
    /// @param invertQuote False when the FX feed is CCY/USD (e.g. GBP/USD — multiply),
    ///                    true when it is USD/CCY (e.g. USD/JPY — divide)
    /// @return compositeId The deterministic ID to use anywhere a feed ID is expected
    function registerComposite(bytes32 baseId, bytes32 quoteId, bool invertQuote)
        external
        returns (bytes32 compositeId)
    {
        if (baseId == bytes32(0) || quoteId == bytes32(0) || baseId == quoteId) {
            revert BazaarOracle__InvalidCompositeLegs(baseId, quoteId);
        }
        // Legs must be raw Pyth feed IDs — nesting composites is not supported
        if (composites[baseId].baseId != bytes32(0) || composites[quoteId].baseId != bytes32(0)) {
            revert BazaarOracle__InvalidCompositeLegs(baseId, quoteId);
        }

        compositeId = getCompositeId(baseId, quoteId, invertQuote);
        if (composites[compositeId].baseId == bytes32(0)) {
            composites[compositeId] = CompositeFeed({baseId: baseId, quoteId: quoteId, invertQuote: invertQuote});
            emit CompositeFeedRegistered(compositeId, baseId, quoteId, invertQuote);
        }
    }

    /// @notice Deterministic composite ID for a given leg configuration.
    function getCompositeId(bytes32 baseId, bytes32 quoteId, bool invertQuote) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseId, quoteId, invertQuote));
    }

    // ================================================================
    //                         Read functions (view, no ETH)
    // ================================================================

    /// @notice Try to read a fresh pair price from Pyth's on-chain cache.
    /// @param baseFeedId The Pyth feed ID for the base asset, or a registered composite ID
    /// @param maxStaleness Maximum acceptable age in seconds (applies to every leg)
    /// @return found True if the price (all legs, for composites) is fresh enough
    /// @return spotPrice The USD price normalized to BAZAAR_SCALE
    /// @return lowPrice spotPrice − confidence (floored at 1 wei)
    /// @return highPrice spotPrice + confidence
    /// @return publishTime The price publish timestamp (oldest leg for composites)
    function tryReadFreshPrice(bytes32 baseFeedId, uint256 maxStaleness)
        external
        view
        returns (bool found, uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime)
    {
        (bytes32 baseId, bytes32 quoteId, bool invertQuote) = _resolve(baseFeedId);

        PythStructs.Price memory basePrice;
        try pyth.getPriceNoOlderThan(baseId, maxStaleness) returns (PythStructs.Price memory bp) {
            basePrice = bp;
        } catch {
            return (false, 0, 0, 0, 0);
        }

        if (quoteId == bytes32(0)) {
            (spotPrice, lowPrice, highPrice, publishTime) = _normalizeBase(baseId, basePrice);
            return (true, spotPrice, lowPrice, highPrice, publishTime);
        }

        try pyth.getPriceNoOlderThan(quoteId, maxStaleness) returns (PythStructs.Price memory qp) {
            (spotPrice, lowPrice, highPrice, publishTime) = _composeSafe(baseId, basePrice, qp, quoteId, invertQuote);
            found = true;
        } catch {
            return (false, 0, 0, 0, 0);
        }
    }

    /// @notice Stale-path read with a confidence ladder: prefer the spot price when every leg's
    ///         confidence is within MAX_CONFIDENCE_BP, else the EMA (smoothed) price when ITS
    ///         confidence is within the cap. Reads regardless of age (the caller has accepted
    ///         staleness). Returns found=false if neither qualifies, so the caller can fall back to
    ///         its last stored price rather than operate on a low-confidence one.
    /// @dev Confidence is checked per-leg on the raw conf/price ratio (exponent-independent) AND,
    ///      for composites, on the composed bracket (per-leg alone would allow ~2× the cap in
    ///      total uncertainty) — consistent with the safe path. Does not revert on wide
    ///      confidence — a rung that fails either check falls through.
    function tryReadStalePrice(bytes32 baseFeedId)
        external
        view
        returns (bool found, uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime)
    {
        (bytes32 baseId, bytes32 quoteId, bool invertQuote) = _resolve(baseFeedId);

        // Rung 1: spot price, used only if every leg clears the confidence cap.
        PythStructs.Price memory base = pyth.getPriceUnsafe(baseId);
        if (quoteId == bytes32(0)) {
            if (_legConfOk(base)) {
                (spotPrice, lowPrice, highPrice, publishTime) = _normalizeBaseUnsafe(baseId, base);
                return (true, spotPrice, lowPrice, highPrice, publishTime);
            }
        } else {
            PythStructs.Price memory quote = pyth.getPriceUnsafe(quoteId);
            if (_legConfOk(base) && _legConfOk(quote)) {
                (spotPrice, lowPrice, highPrice, publishTime) =
                    _composeUnsafe(baseId, base, quoteId, quote, invertQuote);
                if (_composedBracketOk(spotPrice, lowPrice, highPrice)) {
                    return (true, spotPrice, lowPrice, highPrice, publishTime);
                }
            }
        }

        // Rung 2: EMA price (smoothed) — reached only because the spot above was too uncertain.
        PythStructs.Price memory baseEma = pyth.getEmaPriceUnsafe(baseId);
        if (quoteId == bytes32(0)) {
            if (_legConfOk(baseEma)) {
                (spotPrice, lowPrice, highPrice, publishTime) = _normalizeBaseUnsafe(baseId, baseEma);
                return (true, spotPrice, lowPrice, highPrice, publishTime);
            }
        } else {
            PythStructs.Price memory quoteEma = pyth.getEmaPriceUnsafe(quoteId);
            if (_legConfOk(baseEma) && _legConfOk(quoteEma)) {
                (spotPrice, lowPrice, highPrice, publishTime) =
                    _composeUnsafe(baseId, baseEma, quoteId, quoteEma, invertQuote);
                if (_composedBracketOk(spotPrice, lowPrice, highPrice)) {
                    return (true, spotPrice, lowPrice, highPrice, publishTime);
                }
            }
        }

        // Neither rung qualified → caller falls back to its last stored price.
        return (false, 0, 0, 0, 0);
    }

    /// @notice Returns the ETH fee required to post the given Pyth price updates.
    function getUpdateFee(bytes[] calldata priceUpdate) external view returns (uint256) {
        return pyth.getUpdateFee(priceUpdate);
    }

    /// @notice Returns the ETH fee fetchChainedMedian charges for `priceUpdate`. Each sample is
    ///         parsed in a Pyth call of its own, so this is the sum of Pyth's fee for each
    ///         sample's updates, read as consecutive groups of one update per leg of
    ///         `baseFeedId`; a trailing group short of a leg adds nothing.
    /// @param baseFeedId The Pyth feed ID for the base asset, or a registered composite ID
    /// @param priceUpdate The sample set, one update per leg for each sample in turn
    /// @return fee The total fee in wei
    function getSampleSetFee(bytes32 baseFeedId, bytes[] calldata priceUpdate) external view returns (uint256 fee) {
        (, bytes32 quoteId,) = _resolve(baseFeedId);
        uint256 legs = quoteId == bytes32(0) ? 1 : 2;
        for (uint256 i = 0; i + legs <= priceUpdate.length; i += legs) {
            fee += pyth.getUpdateFee(_sampleUpdates(priceUpdate, i, legs));
        }
    }

    // ================================================================
    //                        Write functions (payable, needs ETH)
    // ================================================================

    /// @notice Pay to update Pyth price feeds, then read and return the fresh USD price.
    /// @dev For composite feeds, priceUpdate must contain updates for both legs.
    function updateAndFetchPrice(bytes32 baseFeedId, bytes[] calldata priceUpdate, uint256 maxStaleness)
        external
        payable
        returns (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime)
    {
        pyth.updatePriceFeeds{value: msg.value}(priceUpdate);

        (bytes32 baseId, bytes32 quoteId, bool invertQuote) = _resolve(baseFeedId);

        PythStructs.Price memory basePrice = pyth.getPriceNoOlderThan(baseId, maxStaleness);
        if (quoteId == bytes32(0)) {
            return _normalizeBase(baseId, basePrice);
        }

        return _composeSafe(baseId, basePrice, pyth.getPriceNoOlderThan(quoteId, maxStaleness), quoteId, invertQuote);
    }

    /// @notice Parse a price update and return the USD price of the first tick published at or
    ///         after `minPublishTime`, provided that tick was published no later than
    ///         `maxPublishTime`.
    /// @dev Pyth checks the update's embedded previous publish time against `minPublishTime`, so
    ///      the returned tick is provably the first one at or after it: whoever supplies the update
    ///      cannot choose among later prints, and a window that opens while the feed is quiet
    ///      resolves to the feed's next print rather than to anything stored. When that first
    ///      print falls after `maxPublishTime` no update qualifies and the call reverts with
    ///      Pyth's PriceFeedNotFoundWithinRange. This is Pyth's `parsePriceFeedUpdatesUnique`
    ///      spelled out through the configurable parser (uniqueness on, extra feeds in the payload
    ///      tolerated, nothing stored), so the test mock enforces the same uniqueness check the
    ///      live contract does. For composite feeds each leg is its own first print: an FX leg
    ///      that trades around the clock resolves within seconds of `minPublishTime` while an
    ///      equity leg may resolve at its next session open.
    ///
    ///      The confidence cap is deliberately NOT applied. There is exactly one qualifying print,
    ///      so a cap could never redirect to a better one — it could only refuse, which leaves the
    ///      caller only its stored-price fallback, after whatever wait that fallback carries, even
    ///      though a genuine print exists. The first print after a closed session is routinely
    ///      wide, so a cap would push every off-hours cutoff onto that fallback. Only a
    ///      non-positive price is rejected.
    /// @param baseFeedId The Pyth feed ID for the base asset, or a registered composite ID
    /// @param priceUpdate The update(s) to parse, one per leg
    /// @param minPublishTime Earliest acceptable publish time; the returned tick is the first at or after it
    /// @param maxPublishTime Latest acceptable publish time for that first tick
    /// @return spotPrice The USD price normalized to BAZAAR_SCALE
    function fetchFirstPriceAtOrAfter(
        bytes32 baseFeedId,
        bytes[] calldata priceUpdate,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (uint256 spotPrice) {
        (bytes32 baseId, bytes32 quoteId, bool invertQuote) = _resolve(baseFeedId);

        (PythStructs.PriceFeed[] memory priceFeeds,) = pyth.parsePriceFeedUpdatesWithConfig{value: msg.value}(
            priceUpdate, _feedIdArray(baseId, quoteId), minPublishTime, maxPublishTime, true, false, false
        );

        if (quoteId == bytes32(0)) {
            (spotPrice,,,) = _normalizeBaseUnsafe(baseId, priceFeeds[0].price);
            return spotPrice;
        }

        (spotPrice,,,) = _composeUnsafe(baseId, priceFeeds[0].price, quoteId, priceFeeds[1].price, invertQuote);
    }

    /// @notice Parse a chained sample set and return the median of its USD prices. The first
    ///         sample is the first print at or after `firstTarget`; each later sample is the first
    ///         print at or after `spacing` past the publish time of the sample before it (the
    ///         later of its two legs' for a composite). Every sample must be published no later
    ///         than `maxPublishTime`, and the set must hold exactly `count` samples.
    /// @dev Every sample is pinned the way fetchFirstPriceAtOrAfter pins its one print: Pyth checks
    ///      each update's embedded previous publish time against that sample's own target, so the
    ///      sample is provably the first print at or after it, and every target after the first is
    ///      computed here from the publish time Pyth verified for the sample before, never taken
    ///      from the caller. The whole set is therefore fixed by the feed's history alone: a set
    ///      built from any other prints, in any other order, or with a sample short reverts, so
    ///      whoever submits it chooses nothing. Measuring each target from the previous sample
    ///      rather than from the first keeps the samples apart whatever the feed does: a target
    ///      that falls in a quiet stretch resolves to the feed's next print, and the target after
    ///      it moves past that print, so a cutoff at a session's close yields the close and then
    ///      prints from the reopen onward instead of the reopen's first print over and over. The
    ///      median of an odd count is its middle sample, so moving it means moving more than half
    ///      of the samples.
    ///
    ///      Each sample is parsed in a Pyth call of its own, carrying that sample's fee, and
    ///      `msg.value` must equal their sum (getSampleSetFee), so no ETH is left here. As in
    ///      fetchFirstPriceAtOrAfter the confidence cap is not applied, since each sample has
    ///      exactly one qualifying print and a cap could only refuse it; only a non-positive price
    ///      is rejected.
    /// @param baseFeedId The Pyth feed ID for the base asset, or a registered composite ID
    /// @param priceUpdate The sample set: for each sample in turn, one update per leg, the legs of
    ///        a sample in either order
    /// @param firstTarget The first sample's target
    /// @param maxPublishTime Latest acceptable publish time for every sample
    /// @param spacing How far after a sample's publish time the next sample's target lies
    /// @param count How many samples the set must hold
    /// @return medianPrice The median sample price, normalized to BAZAAR_SCALE
    function fetchChainedMedian(
        bytes32 baseFeedId,
        bytes[] calldata priceUpdate,
        uint64 firstTarget,
        uint64 maxPublishTime,
        uint64 spacing,
        uint256 count
    ) external payable returns (uint256 medianPrice) {
        SampleChain memory chain = _sampleChain(baseFeedId, firstTarget, maxPublishTime);
        uint256 expected = count * chain.legs;
        if (count == 0 || priceUpdate.length != expected) {
            revert BazaarOracle__SampleCountMismatch(priceUpdate.length, expected);
        }
        uint256[] memory prices = new uint256[](count);
        uint256 spent;
        for (uint256 k = 0; k < count; k++) {
            uint256 fee;
            (prices[k], fee) = _parseSample(chain, _sampleUpdates(priceUpdate, k * chain.legs, chain.legs), spacing);
            spent += fee;
        }
        if (spent != msg.value) revert BazaarOracle__SampleFeeMismatch(msg.value, spent);
        medianPrice = _median(prices);
    }

    // ================================================================
    //                         Internal helpers
    // ================================================================

    /// @dev A sample chain over `baseFeedId`'s legs, its first target `firstTarget`.
    function _sampleChain(bytes32 baseFeedId, uint64 firstTarget, uint64 maxPublishTime)
        internal
        view
        returns (SampleChain memory chain)
    {
        (chain.baseId, chain.quoteId, chain.invertQuote) = _resolve(baseFeedId);
        chain.legs = chain.quoteId == bytes32(0) ? 1 : 2;
        chain.feedIds = _feedIdArray(chain.baseId, chain.quoteId);
        chain.target = firstTarget;
        chain.maxPublishTime = maxPublishTime;
    }

    /// @dev Parses one sample of `chain`: every leg's first print at or after the chain's target
    ///      and no later than its maximum, composed to a USD price. Then moves the target to
    ///      `spacing` past the later leg's publish time, where the next sample starts.
    /// @param chain The chain's legs, its current target and its maximum publish time; the target
    ///        is advanced in place
    /// @param updates The sample's updates, one per leg
    /// @param spacing How far after this sample's publish time the next sample's target lies
    /// @return price The sample's USD price, normalized to BAZAAR_SCALE
    /// @return fee The Pyth fee the parse paid
    function _parseSample(SampleChain memory chain, bytes[] memory updates, uint64 spacing)
        internal
        returns (uint256 price, uint256 fee)
    {
        fee = pyth.getUpdateFee(updates);
        (PythStructs.PriceFeed[] memory feeds,) = pyth.parsePriceFeedUpdatesWithConfig{value: fee}(
            updates, chain.feedIds, chain.target, chain.maxPublishTime, true, false, false
        );
        uint256 publishTime = feeds[0].price.publishTime;
        if (chain.legs == 1) {
            (price,,,) = _normalizeBaseUnsafe(chain.baseId, feeds[0].price);
        } else {
            (price,,,) = _composeUnsafe(chain.baseId, feeds[0].price, chain.quoteId, feeds[1].price, chain.invertQuote);
            if (feeds[1].price.publishTime > publishTime) publishTime = feeds[1].price.publishTime;
        }
        // Pyth refused any leg published after maxPublishTime, a uint64, so the cast is exact; a
        // target past the uint64 range reverts here rather than wrapping to an earlier one.
        chain.target = uint64(publishTime) + spacing;
    }

    /// @dev The updates of one sample in a flat sample set: `legs` updates from index `start`.
    function _sampleUpdates(bytes[] calldata priceUpdate, uint256 start, uint256 legs)
        internal
        pure
        returns (bytes[] memory updates)
    {
        updates = new bytes[](legs);
        for (uint256 j = 0; j < legs; j++) {
            updates[j] = priceUpdate[start + j];
        }
    }

    /// @dev The middle value of `values` once sorted, sorting them in place: the median of an odd
    ///      count, and the upper of the two middle values of an even one.
    function _median(uint256[] memory values) internal pure returns (uint256) {
        uint256 n = values.length;
        for (uint256 i = 1; i < n; i++) {
            uint256 v = values[i];
            uint256 j = i;
            while (j > 0 && values[j - 1] > v) {
                values[j] = values[j - 1];
                j--;
            }
            values[j] = v;
        }
        return values[n / 2];
    }

    /// @dev Resolve a feed ID into its legs. Raw Pyth IDs resolve to themselves with no quote leg.
    function _resolve(bytes32 feedId) internal view returns (bytes32 baseId, bytes32 quoteId, bool invertQuote) {
        CompositeFeed storage c = composites[feedId];
        baseId = c.baseId;
        if (baseId == bytes32(0)) {
            return (feedId, bytes32(0), false);
        }
        return (baseId, c.quoteId, c.invertQuote);
    }

    function _feedIdArray(bytes32 baseId, bytes32 quoteId) internal pure returns (bytes32[] memory feedIds) {
        if (quoteId == bytes32(0)) {
            feedIds = new bytes32[](1);
            feedIds[0] = baseId;
        } else {
            feedIds = new bytes32[](2);
            feedIds[0] = baseId;
            feedIds[1] = quoteId;
        }
    }

    /// @dev True iff the COMPOSED bracket is within MAX_CONFIDENCE_BP of the composed spot on
    ///      both sides. Per-leg checks are necessary but not sufficient for composites: relative
    ///      widths ADD under multiply/divide, so two legs at the cap compound to ~2× it. This
    ///      enforces the total-uncertainty policy on the result, letting the legs share the 2%
    ///      budget however it falls (1.8% + 0.15% passes; 1.2% + 1.2% fails).
    function _composedBracketOk(uint256 spotPrice, uint256 lowPrice, uint256 highPrice) internal pure returns (bool) {
        uint256 cap = spotPrice * MAX_CONFIDENCE_BP;
        return (highPrice - spotPrice) * BP_SCALE <= cap && (spotPrice - lowPrice) * BP_SCALE <= cap;
    }

    /// @dev True iff a Pyth leg's confidence ratio is within MAX_CONFIDENCE_BP and its price is
    ///      positive. conf and price share the same exponent, so the ratio needs no conversion.
    function _legConfOk(PythStructs.Price memory p) internal pure returns (bool) {
        if (p.price <= 0) return false;
        return uint256(int256(p.price)) * MAX_CONFIDENCE_BP >= uint256(p.conf) * BP_SCALE;
    }

    /// @dev Normalize base price to BAZAAR_SCALE, validate confidence ratio, and compute bracket.
    ///      For single-feed assets the USDC quote is assumed to be $1, so spotPrice = baseNorm.
    function _normalizeBase(bytes32 baseId, PythStructs.Price memory basePrice)
        internal
        pure
        returns (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime)
    {
        // A non-positive price is an oracle malfunction (real prices are positive). Reject it on
        // every path rather than flooring — operating on a zero/negative price mass-liquidates
        // longs and mis-values positions. Symmetric with the quote-leg rejection.
        if (basePrice.price <= 0) {
            revert BazaarOracle__InvalidPrice(baseId, basePrice.price, basePrice.expo);
        }

        int256 baseNorm = BazaarMathLib.convertExponent(int256(basePrice.price), basePrice.expo, BAZAAR_EXPONENT);
        if (baseNorm <= 0) revert BazaarOracle__InvalidPrice(baseId, basePrice.price, basePrice.expo);
        int256 baseConf =
            BazaarMathLib.convertExponent(int256(uint256(basePrice.conf)), basePrice.expo, BAZAAR_EXPONENT);

        // Validate confidence-to-price ratio: revert if conf/price > MAX_CONFIDENCE_BP/BP_SCALE
        if (uint256(baseConf) * BP_SCALE > uint256(baseNorm) * MAX_CONFIDENCE_BP) {
            revert BazaarOracle__ConfidenceTooHigh(uint256(baseConf), uint256(baseNorm));
        }

        spotPrice = uint256(baseNorm);
        uint256 conf = baseConf > 0 ? uint256(baseConf) : 0;
        lowPrice = conf >= spotPrice ? 1 : spotPrice - conf;
        highPrice = spotPrice + conf;
        publishTime = basePrice.publishTime;
    }

    /// @dev Same normalization as _normalizeBase but without the confidence ratio check
    ///      (unsafe read paths accept degraded data).
    function _normalizeBaseUnsafe(bytes32 baseId, PythStructs.Price memory basePrice)
        internal
        pure
        returns (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime)
    {
        // Reject non-positive prices even on the unsafe path — a zero/negative price is a
        // malfunction, not "degraded but usable" data (matches the safe path and the quote leg).
        if (basePrice.price <= 0) {
            revert BazaarOracle__InvalidPrice(baseId, basePrice.price, basePrice.expo);
        }

        int256 baseNorm = BazaarMathLib.convertExponent(int256(basePrice.price), basePrice.expo, BAZAAR_EXPONENT);
        if (baseNorm <= 0) revert BazaarOracle__InvalidPrice(baseId, basePrice.price, basePrice.expo);

        spotPrice = uint256(baseNorm);

        int256 baseConf =
            BazaarMathLib.convertExponent(int256(uint256(basePrice.conf)), basePrice.expo, BAZAAR_EXPONENT);
        uint256 conf = baseConf > 0 ? uint256(baseConf) : 0;
        lowPrice = conf >= spotPrice ? 1 : spotPrice - conf;
        highPrice = spotPrice + conf;
        publishTime = basePrice.publishTime;
    }

    /// @dev Normalize the FX quote leg. Unlike the base leg, a zero/negative quote is a hard
    ///      error in every path: the quote scales the whole composite price, so flooring it
    ///      to 1 wei (the base-leg trick) would explode the result instead of zeroing it.
    function _normalizeQuote(bytes32 quoteId, PythStructs.Price memory quotePrice, bool enforceConfRatio)
        internal
        pure
        returns (uint256 spot, uint256 low, uint256 high, uint256 publishTime)
    {
        if (quotePrice.price <= 0) {
            revert BazaarOracle__InvalidPrice(quoteId, quotePrice.price, quotePrice.expo);
        }

        int256 quoteNorm = BazaarMathLib.convertExponent(int256(quotePrice.price), quotePrice.expo, BAZAAR_EXPONENT);
        if (quoteNorm <= 0) {
            revert BazaarOracle__InvalidPrice(quoteId, quotePrice.price, quotePrice.expo);
        }

        int256 quoteConf =
            BazaarMathLib.convertExponent(int256(uint256(quotePrice.conf)), quotePrice.expo, BAZAAR_EXPONENT);
        uint256 conf = quoteConf > 0 ? uint256(quoteConf) : 0;

        if (enforceConfRatio && conf * BP_SCALE > uint256(quoteNorm) * MAX_CONFIDENCE_BP) {
            revert BazaarOracle__ConfidenceTooHigh(conf, uint256(quoteNorm));
        }

        spot = uint256(quoteNorm);
        low = conf >= spot ? 1 : spot - conf;
        high = spot + conf;
        publishTime = quotePrice.publishTime;
    }

    /// @dev Normalize both legs with confidence ratio checks, then combine into a USD price.
    ///      The per-leg checks fast-fail obviously-bad inputs; the composed bracket is then held
    ///      to the same MAX_CONFIDENCE_BP so composites never act above 2% TOTAL uncertainty.
    function _composeSafe(
        bytes32 baseId,
        PythStructs.Price memory basePrice,
        PythStructs.Price memory quotePrice,
        bytes32 quoteId,
        bool invertQuote
    ) internal pure returns (uint256, uint256, uint256, uint256) {
        (uint256 bSpot, uint256 bLow, uint256 bHigh, uint256 bPub) = _normalizeBase(baseId, basePrice);
        (uint256 qSpot, uint256 qLow, uint256 qHigh, uint256 qPub) = _normalizeQuote(quoteId, quotePrice, true);
        (uint256 spot, uint256 low, uint256 high, uint256 pub) =
            _compose(bSpot, bLow, bHigh, bPub, qSpot, qLow, qHigh, qPub, invertQuote);
        if (!_composedBracketOk(spot, low, high)) {
            uint256 dev = high - spot > spot - low ? high - spot : spot - low;
            revert BazaarOracle__ConfidenceTooHigh(dev, spot);
        }
        return (spot, low, high, pub);
    }

    /// @dev Normalize both legs without confidence ratio checks, then combine into a USD price.
    function _composeUnsafe(
        bytes32 baseId,
        PythStructs.Price memory basePrice,
        bytes32 quoteId,
        PythStructs.Price memory quotePrice,
        bool invertQuote
    ) internal pure returns (uint256, uint256, uint256, uint256) {
        (uint256 bSpot, uint256 bLow, uint256 bHigh, uint256 bPub) = _normalizeBaseUnsafe(baseId, basePrice);
        (uint256 qSpot, uint256 qLow, uint256 qHigh, uint256 qPub) = _normalizeQuote(quoteId, quotePrice, false);
        return _compose(bSpot, bLow, bHigh, bPub, qSpot, qLow, qHigh, qPub, invertQuote);
    }

    /// @dev Combine two normalized legs into a USD composite. The bracket pairs each base
    ///      bound with the quote bound that moves the result in the same direction, so the
    ///      composite bracket stays conservative for both long and short exposure.
    function _compose(
        uint256 baseSpot,
        uint256 baseLow,
        uint256 baseHigh,
        uint256 basePub,
        uint256 quoteSpot,
        uint256 quoteLow,
        uint256 quoteHigh,
        uint256 quotePub,
        bool invertQuote
    ) internal pure returns (uint256 spotPrice, uint256 lowPrice, uint256 highPrice, uint256 publishTime) {
        if (invertQuote) {
            // Quote feed is USD/CCY (CCY per USD) — divide
            spotPrice = Math.mulDiv(baseSpot, BAZAAR_SCALE, quoteSpot);
            lowPrice = Math.mulDiv(baseLow, BAZAAR_SCALE, quoteHigh);
            highPrice = Math.mulDiv(baseHigh, BAZAAR_SCALE, quoteLow);
        } else {
            // Quote feed is CCY/USD (USD per CCY) — multiply
            spotPrice = Math.mulDiv(baseSpot, quoteSpot, BAZAAR_SCALE);
            lowPrice = Math.mulDiv(baseLow, quoteLow, BAZAAR_SCALE);
            highPrice = Math.mulDiv(baseHigh, quoteHigh, BAZAAR_SCALE);
        }

        // Preserve the single-feed path's 1-wei floor semantics after rounding
        if (spotPrice == 0) spotPrice = 1;
        if (lowPrice == 0) lowPrice = 1;
        if (highPrice < spotPrice) highPrice = spotPrice;

        // The composite is only as fresh as its stalest leg
        publishTime = basePub < quotePub ? basePub : quotePub;
    }
}
