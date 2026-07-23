// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockOptimisticOracleV3} from "../mocks/MockOptimisticOracleV3.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythErrors} from "@pythnetwork/pyth-sdk-solidity/PythErrors.sol";

/// @notice Unit tests for BazaarOracle composite (two-feed) price support:
///         registry semantics, multiply/divide composition, bracket math, and staleness.
contract CompositeOracleTest is Test {
    // Arbitrary leg feed IDs (raw Pyth IDs in production)
    bytes32 constant ASSET_JPY_FEED = keccak256("test.EQUITY.7203/JPY");
    bytes32 constant USD_JPY_FEED = keccak256("test.FX.USD/JPY");
    bytes32 constant ASSET_GBP_FEED = keccak256("test.EQUITY.LLOY/GBP");
    bytes32 constant GBP_USD_FEED = keccak256("test.FX.GBP/USD");

    int32 constant PYTH_EXPO = -8;
    uint256 constant BAZAAR_SCALE = 1e18;

    MockPyth mockPyth;
    BazaarOracle oracle;

    function setUp() public {
        vm.warp(1_700_000_000);
        mockPyth = new MockPyth(60, 1); // validTimePeriod 60s, 1 wei fee per update
        oracle = new BazaarOracle(address(mockPyth));
        vm.deal(address(this), 1 ether);
    }

    // ==================== Helpers ====================

    function _updateData(bytes32 id, int64 price, uint64 conf, uint64 publishTime)
        internal
        view
        returns (bytes memory)
    {
        return mockPyth.createPriceFeedUpdateData(id, price, conf, PYTH_EXPO, price, conf, publishTime, publishTime - 1);
    }

    function _push(bytes32 id, int64 price, uint64 conf, uint64 publishTime) internal {
        bytes[] memory updates = new bytes[](1);
        updates[0] = _updateData(id, price, conf, publishTime);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(updates)}(updates);
    }

    /// @dev Push a feed with independently-set spot and EMA price/conf (for the stale-ladder tests).
    function _pushSpotEma(bytes32 id, int64 spotP, uint64 spotC, int64 emaP, uint64 emaC, uint64 pub) internal {
        bytes[] memory updates = new bytes[](1);
        updates[0] = mockPyth.createPriceFeedUpdateData(id, spotP, spotC, PYTH_EXPO, emaP, emaC, pub, pub - 1);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(updates)}(updates);
    }

    function _bothLegUpdates(int64 basePrice, uint64 baseConf, int64 quotePrice, uint64 quoteConf, uint64 publishTime)
        internal
        view
        returns (bytes[] memory updates)
    {
        updates = new bytes[](2);
        updates[0] = _updateData(ASSET_JPY_FEED, basePrice, baseConf, publishTime);
        updates[1] = _updateData(USD_JPY_FEED, quotePrice, quoteConf, publishTime);
    }

    function _registerJpyComposite() internal returns (bytes32) {
        return oracle.registerComposite(ASSET_JPY_FEED, USD_JPY_FEED, true);
    }

    function _registerGbpComposite() internal returns (bytes32) {
        return oracle.registerComposite(ASSET_GBP_FEED, GBP_USD_FEED, false);
    }

    // ==================== Registry ====================

    function test_RegisterComposite_DeterministicIdAndStorage() public {
        bytes32 id = _registerJpyComposite();

        assertEq(id, keccak256(abi.encodePacked(ASSET_JPY_FEED, USD_JPY_FEED, true)));
        assertEq(id, oracle.getCompositeId(ASSET_JPY_FEED, USD_JPY_FEED, true));

        (bytes32 baseId, bytes32 quoteId, bool invertQuote) = oracle.composites(id);
        assertEq(baseId, ASSET_JPY_FEED);
        assertEq(quoteId, USD_JPY_FEED);
        assertTrue(invertQuote);
    }

    function test_RegisterComposite_InvertFlagChangesId() public {
        bytes32 idInverted = oracle.registerComposite(ASSET_JPY_FEED, USD_JPY_FEED, true);
        bytes32 idStraight = oracle.registerComposite(ASSET_JPY_FEED, USD_JPY_FEED, false);
        assertTrue(idInverted != idStraight);
    }

    function test_RegisterComposite_Idempotent() public {
        bytes32 id1 = _registerJpyComposite();
        bytes32 id2 = _registerJpyComposite(); // must not revert
        assertEq(id1, id2);
    }

    function test_RegisterComposite_RevertsOnInvalidLegs() public {
        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__InvalidCompositeLegs.selector, bytes32(0), USD_JPY_FEED)
        );
        oracle.registerComposite(bytes32(0), USD_JPY_FEED, true);

        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__InvalidCompositeLegs.selector, ASSET_JPY_FEED, bytes32(0))
        );
        oracle.registerComposite(ASSET_JPY_FEED, bytes32(0), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__InvalidCompositeLegs.selector, ASSET_JPY_FEED, ASSET_JPY_FEED
            )
        );
        oracle.registerComposite(ASSET_JPY_FEED, ASSET_JPY_FEED, true);
    }

    function test_RegisterComposite_RevertsOnNestedComposite() public {
        bytes32 compositeId = _registerJpyComposite();

        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__InvalidCompositeLegs.selector, compositeId, GBP_USD_FEED)
        );
        oracle.registerComposite(compositeId, GBP_USD_FEED, false);

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__InvalidCompositeLegs.selector, ASSET_GBP_FEED, compositeId
            )
        );
        oracle.registerComposite(ASSET_GBP_FEED, compositeId, false);
    }

    // ============ tryReadStalePrice bracket math (spot rung) ============
    // These exercise the same _composeUnsafe bracket math the stale path relies on. Confidence is
    // tight on every leg, so rung 1 (spot) is selected and `found` is always true. (They formerly
    // covered readUnsafePrice, which was removed once terminateStalePair switched to this path.)

    function test_TryReadStale_DividePath() public {
        // 3000 JPY stock, USD/JPY = 150 (inverted) => $20
        bytes32 compositeId = _registerJpyComposite();
        _push(ASSET_JPY_FEED, 3000e8, 0, uint64(block.timestamp));
        _push(USD_JPY_FEED, 150e8, 0, uint64(block.timestamp));

        (bool found, uint256 spot, uint256 low, uint256 high, uint256 publishTime) =
            oracle.tryReadStalePrice(compositeId);
        assertTrue(found, "tight conf -> spot rung");
        assertEq(spot, 20e18);
        assertEq(low, 20e18);
        assertEq(high, 20e18);
        assertEq(publishTime, block.timestamp);
    }

    function test_TryReadStale_MultiplyPath() public {
        // 150 GBP stock, GBP/USD = 1.25 => $187.50
        bytes32 compositeId = _registerGbpComposite();
        _push(ASSET_GBP_FEED, 150e8, 0, uint64(block.timestamp));
        _push(GBP_USD_FEED, 1.25e8, 0, uint64(block.timestamp));

        (bool found, uint256 spot,,,) = oracle.tryReadStalePrice(compositeId);
        assertTrue(found);
        assertEq(spot, 187.5e18);
    }

    function test_TryReadStale_MultiplyBracketIsConservative() public {
        // base 150 +/- 1 GBP, fx 1.25 +/- 0.01 USD/GBP (both within 2%)
        bytes32 compositeId = _registerGbpComposite();
        _push(ASSET_GBP_FEED, 150e8, 1e8, uint64(block.timestamp));
        _push(GBP_USD_FEED, 1.25e8, 0.01e8, uint64(block.timestamp));

        (bool found, uint256 spot, uint256 low, uint256 high,) = oracle.tryReadStalePrice(compositeId);
        assertTrue(found);
        assertEq(spot, 187.5e18);
        assertEq(low, 149e18 * 1.24e18 / 1e18); // 184.76
        assertEq(high, 151e18 * 1.26e18 / 1e18); // 190.26
        assertLt(low, spot);
        assertGt(high, spot);
    }

    function test_TryReadStale_DivideBracketIsConservative() public {
        // base 3000 +/- 30 JPY, fx 150 +/- 1 JPY/USD (inverted) (both within 2%)
        bytes32 compositeId = _registerJpyComposite();
        _push(ASSET_JPY_FEED, 3000e8, 30e8, uint64(block.timestamp));
        _push(USD_JPY_FEED, 150e8, 1e8, uint64(block.timestamp));

        (bool found, uint256 spot, uint256 low, uint256 high,) = oracle.tryReadStalePrice(compositeId);
        assertTrue(found);
        assertEq(spot, 20e18);
        assertEq(low, uint256(2970e18) * 1e18 / 151e18); // low base over high fx
        assertEq(high, uint256(3030e18) * 1e18 / 149e18); // high base over low fx
        assertLt(low, spot);
        assertGt(high, spot);
    }

    function test_TryReadStale_PublishTimeIsOldestLeg() public {
        bytes32 compositeId = _registerJpyComposite();
        uint64 older = uint64(block.timestamp - 100);
        uint64 newer = uint64(block.timestamp - 5);
        _push(ASSET_JPY_FEED, 3000e8, 0, newer);
        _push(USD_JPY_FEED, 150e8, 0, older);

        (,,,, uint256 publishTime) = oracle.tryReadStalePrice(compositeId);
        assertEq(publishTime, older);
    }

    function test_TryReadStale_NotFoundOnNonPositiveBase() public {
        // A non-positive base price fails the per-leg confidence/positivity check on both rungs,
        // so the stale path returns found=false (caller falls back to its last stored price)
        // rather than reverting. The safe path's hard reject is covered separately below.
        _push(ASSET_JPY_FEED, 0, 0, uint64(block.timestamp));
        (bool found,,,,) = oracle.tryReadStalePrice(ASSET_JPY_FEED);
        assertFalse(found, "non-positive base -> not found, no revert");
    }

    function test_TryReadFresh_RevertsOnNonPositiveBase() public {
        // The safe (confidence-checked) path rejects a non-positive base too — same error,
        // not a swallowed `found=false` (only staleness returns found=false).
        _push(ASSET_JPY_FEED, 0, 0, uint64(block.timestamp));
        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__InvalidPrice.selector, ASSET_JPY_FEED, int64(0), PYTH_EXPO
            )
        );
        oracle.tryReadFreshPrice(ASSET_JPY_FEED, 60);
    }

    // ==================== tryReadStalePrice (spot -> EMA -> found=false ladder) ====================

    function test_TryReadStale_UsesSpotWhenTight() public {
        // spot conf 0.1% (tight); EMA differs in value so we can tell which was used.
        _pushSpotEma(ASSET_JPY_FEED, 3000e8, 3e8, 2900e8, 3e8, uint64(block.timestamp));
        (bool found, uint256 spot,,,) = oracle.tryReadStalePrice(ASSET_JPY_FEED);
        assertTrue(found, "found via spot");
        assertEq(spot, 3000e18, "uses spot price, not EMA");
    }

    function test_TryReadStale_FallsToEmaWhenSpotWide() public {
        // spot conf 5% (wide -> rung 1 fails); EMA conf 0.1% (tight -> rung 2 used).
        _pushSpotEma(ASSET_JPY_FEED, 3000e8, 150e8, 2900e8, 3e8, uint64(block.timestamp));
        (bool found, uint256 spot,,,) = oracle.tryReadStalePrice(ASSET_JPY_FEED);
        assertTrue(found, "found via EMA");
        assertEq(spot, 2900e18, "falls back to the EMA price");
    }

    function test_TryReadStale_NotFoundWhenBothWide() public {
        // spot 5% and EMA ~5% -> neither rung clears the cap -> found=false (caller uses lastPairPrice).
        _pushSpotEma(ASSET_JPY_FEED, 3000e8, 150e8, 2900e8, 150e8, uint64(block.timestamp));
        (bool found,,,,) = oracle.tryReadStalePrice(ASSET_JPY_FEED);
        assertFalse(found, "neither spot nor EMA clears 2% -> not found");
    }

    function test_TryReadStale_Composite_FallsToEmaWhenBaseSpotWide() public {
        // Composite (asset/JPY): base spot wide, base EMA tight, quote tight on both -> EMA composite.
        _registerJpyComposite();
        bytes32 id = oracle.getCompositeId(ASSET_JPY_FEED, USD_JPY_FEED, true);
        _pushSpotEma(ASSET_JPY_FEED, 3000e8, 150e8, 3000e8, 3e8, uint64(block.timestamp)); // base: spot wide, ema tight
        _pushSpotEma(USD_JPY_FEED, 150e8, 1e7, 150e8, 1e7, uint64(block.timestamp)); // quote: tight on both
        (bool found, uint256 spot,,,) = oracle.tryReadStalePrice(id);
        assertTrue(found, "composite found via EMA legs");
        assertGt(spot, 0, "priced");
    }

    function test_TryReadStale_SingleFeedBracket() public {
        _push(ASSET_JPY_FEED, 3000e8, 2e8, uint64(block.timestamp));

        (bool found, uint256 spot, uint256 low, uint256 high,) = oracle.tryReadStalePrice(ASSET_JPY_FEED);
        assertTrue(found);
        assertEq(spot, 3000e18);
        assertEq(low, 2998e18);
        assertEq(high, 3002e18);
    }

    // ==================== tryReadFreshPrice ====================

    function test_TryReadFresh_CompositeFound() public {
        bytes32 compositeId = _registerJpyComposite();
        _push(ASSET_JPY_FEED, 3000e8, 0, uint64(block.timestamp));
        _push(USD_JPY_FEED, 150e8, 0, uint64(block.timestamp));

        (bool found, uint256 spot,,,) = oracle.tryReadFreshPrice(compositeId, 60);
        assertTrue(found);
        assertEq(spot, 20e18);
    }

    function test_TryReadFresh_NotFoundWhenQuoteStale() public {
        bytes32 compositeId = _registerJpyComposite();
        _push(USD_JPY_FEED, 150e8, 0, uint64(block.timestamp));

        vm.warp(block.timestamp + 600);
        _push(ASSET_JPY_FEED, 3000e8, 0, uint64(block.timestamp)); // base fresh, quote 600s old

        (bool found,,,,) = oracle.tryReadFreshPrice(compositeId, 60);
        assertFalse(found);
    }

    function test_TryReadFresh_NotFoundWhenQuoteNeverPublished() public {
        bytes32 compositeId = _registerJpyComposite();
        _push(ASSET_JPY_FEED, 3000e8, 0, uint64(block.timestamp));

        (bool found,,,,) = oracle.tryReadFreshPrice(compositeId, 60);
        assertFalse(found);
    }

    // ==================== updateAndFetchPrice ====================

    function test_UpdateAndFetch_Composite() public {
        bytes32 compositeId = _registerJpyComposite();
        bytes[] memory updates = _bothLegUpdates(3000e8, 0, 150e8, 0, uint64(block.timestamp));
        uint256 fee = oracle.getUpdateFee(updates);

        (uint256 spot,,, uint256 publishTime) = oracle.updateAndFetchPrice{value: fee}(compositeId, updates, 60);
        assertEq(spot, 20e18);
        assertEq(publishTime, block.timestamp);
    }

    function test_UpdateAndFetch_RevertsWhenQuoteStale() public {
        bytes32 compositeId = _registerJpyComposite();
        _push(USD_JPY_FEED, 150e8, 0, uint64(block.timestamp));
        vm.warp(block.timestamp + 600);

        // Update only the base leg; the cached quote leg is 600s old
        bytes[] memory updates = new bytes[](1);
        updates[0] = _updateData(ASSET_JPY_FEED, 3000e8, 0, uint64(block.timestamp));
        uint256 fee = oracle.getUpdateFee(updates);

        vm.expectRevert(PythErrors.StalePrice.selector);
        oracle.updateAndFetchPrice{value: fee}(compositeId, updates, 60);
    }

    function test_UpdateAndFetch_RevertsOnQuoteConfidenceTooHigh() public {
        bytes32 compositeId = _registerJpyComposite();
        // quote conf 4/150 ~ 2.7% > MAX_CONFIDENCE_BP (2%)
        bytes[] memory updates = _bothLegUpdates(3000e8, 0, 150e8, 4e8, uint64(block.timestamp));
        uint256 fee = oracle.getUpdateFee(updates);

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__ConfidenceTooHigh.selector, uint256(4e18), uint256(150e18)
            )
        );
        oracle.updateAndFetchPrice{value: fee}(compositeId, updates, 60);
    }

    // ==================== composed-bracket cap (2% TOTAL uncertainty) ====================

    /// @notice Legs share the 2% budget: 1.8% + 0.15% composes to ~1.95% — passes, even though
    ///         a naive per-leg 1% split would have rejected the base leg.
    function test_ComposedCap_LopsidedWithinBudget_Passes() public {
        bytes32 compositeId = _registerJpyComposite();
        // base conf 54e8 = 1.8% of 3000e8; quote conf 0.225e8 = 0.15% of 150e8.
        bytes[] memory updates = _bothLegUpdates(3000e8, 54e8, 150e8, 22500000, uint64(block.timestamp));
        uint256 fee = oracle.getUpdateFee(updates);

        (uint256 spot,,,) = oracle.updateAndFetchPrice{value: fee}(compositeId, updates, 60);
        assertEq(spot, 20e18);
    }

    /// @notice Two legs at 1.2% each pass the per-leg checks but compose to ~2.43% total —
    ///         the composed-bracket cap rejects what per-leg-only enforcement used to allow.
    function test_ComposedCap_EvenSplitOverBudget_Reverts() public {
        bytes32 compositeId = _registerJpyComposite();
        // base conf 36e8 = 1.2% of 3000e8; quote conf 1.8e8 = 1.2% of 150e8.
        bytes[] memory updates = _bothLegUpdates(3000e8, 36e8, 150e8, 1.8e8, uint64(block.timestamp));
        uint256 fee = oracle.getUpdateFee(updates);

        vm.expectPartialRevert(BazaarOracle.BazaarOracle__ConfidenceTooHigh.selector);
        oracle.updateAndFetchPrice{value: fee}(compositeId, updates, 60);
    }

    /// @notice Stale ladder: a spot rung whose legs pass individually but compose over 2% falls
    ///         through to the EMA rung (distinct EMA values prove which rung answered).
    function test_TryReadStale_ComposedCap_FallsThroughToEma() public {
        bytes32 compositeId = _registerJpyComposite();
        // Spot legs: 1.2% conf each → composed ~2.43%, rung 1 rejected.
        // EMA legs: tight conf, 2790/155 = $18 (≠ the spot rung's $20, proving rung 2 answered).
        _pushSpotEma(ASSET_JPY_FEED, 3000e8, 36e8, 2790e8, 0, uint64(block.timestamp));
        _pushSpotEma(USD_JPY_FEED, 150e8, 1.8e8, 155e8, 0, uint64(block.timestamp));

        (bool found, uint256 spot,,,) = oracle.tryReadStalePrice(compositeId);
        assertTrue(found, "EMA rung qualifies");
        assertEq(spot, 18e18, "composed-cap failure on rung 1 fell through to EMA");
    }

    /// @notice Stale ladder: both rungs over the composed cap -> found=false (caller falls back
    ///         to its last stored price).
    function test_TryReadStale_ComposedCap_BothRungsFail_NotFound() public {
        bytes32 compositeId = _registerJpyComposite();
        _pushSpotEma(ASSET_JPY_FEED, 3000e8, 36e8, 3000e8, 36e8, uint64(block.timestamp));
        _pushSpotEma(USD_JPY_FEED, 150e8, 1.8e8, 150e8, 1.8e8, uint64(block.timestamp));

        (bool found,,,,) = oracle.tryReadStalePrice(compositeId);
        assertFalse(found, "no rung within the composed 2% cap");
    }

    // ==================== fetchHistoricalPrice ====================

    function test_FetchHistorical_Composite() public {
        bytes32 compositeId = _registerJpyComposite();
        uint64 ts = uint64(block.timestamp - 50);
        bytes[] memory updates = _bothLegUpdates(2800e8, 0, 140e8, 0, ts);
        uint256 fee = oracle.getUpdateFee(updates);

        uint256 spot = oracle.fetchHistoricalPrice{value: fee}(compositeId, updates, ts - 10, ts + 10);
        assertEq(spot, 20e18);
    }

    function test_FetchHistorical_RevertsWhenQuoteLegMissing() public {
        bytes32 compositeId = _registerJpyComposite();
        uint64 ts = uint64(block.timestamp - 50);
        bytes[] memory updates = new bytes[](1);
        updates[0] = _updateData(ASSET_JPY_FEED, 2800e8, 0, ts);
        uint256 fee = oracle.getUpdateFee(updates);

        vm.expectRevert(PythErrors.PriceFeedNotFoundWithinRange.selector);
        oracle.fetchHistoricalPrice{value: fee}(compositeId, updates, ts - 10, ts + 10);
    }
}

/// @notice Factory-level tests for composite pair deployment: the FX leg forces
///         non-continuous trading, and a composite pair prices end-to-end through BazaarPair.
contract CompositeFactoryTest is Test {
    bytes32 constant ASSET_JPY_FEED = keccak256("test.EQUITY.7203/JPY");
    bytes32 constant USD_JPY_FEED = keccak256("test.FX.USD/JPY");
    int32 constant PYTH_EXPO = -8;

    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;

    BazaarFactory factory;
    BazaarOracle oracle;
    MockUSDC usdc;
    MockPyth mockPyth;
    MockOptimisticOracleV3 mockOOv3;
    bytes32 compositeId;
    address user1;

    function setUp() public {
        user1 = makeAddr("user1");

        vm.etch(address(0x64), address(new MockArbSys()).code);

        DeployBazaar deployer = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = deployer.deploy(makeAddr("bugBounty"));

        (, address usdcContract, address optimisticOracleV3,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcContract);
        mockOOv3 = MockOptimisticOracleV3(optimisticOracleV3);
        oracle = factory.oracle();
        mockPyth = MockPyth(address(oracle.pyth()));

        compositeId = oracle.registerComposite(ASSET_JPY_FEED, USD_JPY_FEED, true);

        usdc.mint(user1, PROPOSAL_TOTAL_USDC * 2);
    }

    function _pushLeg(bytes32 id, int64 price, uint64 publishTime) internal {
        bytes[] memory updates = new bytes[](1);
        updates[0] = mockPyth.createPriceFeedUpdateData(id, price, 0, PYTH_EXPO, price, 0, publishTime, publishTime - 1);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(updates)}(updates);
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || needle.length > haystack.length) return false;
        for (uint256 i = 0; i <= haystack.length - needle.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    function test_DeploymentClaim_EnforcesLinearAssetRules() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(keccak256("test.BTC/USD"), true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();

        bytes memory claim = mockOOv3.claims(assertionId);
        assertTrue(_contains(claim, "LINEAR, NON-EXPIRING ASSETS ONLY"));
        assertTrue(_contains(claim, "could someone hold this asset indefinitely"));
        assertTrue(_contains(claim, "leveraged or inverse products"));
        assertTrue(_contains(claim, "pegged, rebased, or actively managed toward a target price"));
        assertTrue(_contains(claim, "bonds, preferred stocks, and other fixed-income or yield-based instruments"));
        assertTrue(_contains(claim, "provided the dividend is not the instrument's primary source of return"));
        assertTrue(_contains(claim, "broad market price index"));
        assertTrue(_contains(claim, "NO MIRRORED DUPLICATES"));
        assertTrue(_contains(claim, "tracking another underlying asset or index 1:1"));
        assertTrue(
            _contains(
                claim,
                "EXCEPTION: a 1:1 tracker IS eligible if the underlying asset or index it tracks has NO active Pyth price feed"
            )
        );
        assertTrue(_contains(claim, "Base feed ID"));
        // The old carve-out explicitly allowing leveraged assets must be gone
        assertFalse(_contains(claim, "(e.g. leveraged assets)"));
    }

    function test_DeploymentClaim_CompositeListsBothLegs() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(compositeId, false, PROPOSAL_TOTAL, "Toyota on TSE");
        vm.stopPrank();

        bytes memory claim = mockOOv3.claims(assertionId);
        assertTrue(_contains(claim, "Composite feed ID (USD price = base leg DIVIDED by quote leg)"));
        assertTrue(_contains(claim, "Base leg feed ID"));
        assertTrue(_contains(claim, "Quote leg inverted: true"));
        assertTrue(_contains(claim, "QUOTE LEG CORRECTNESS"));
        assertTrue(_contains(claim, "Composite proposals MUST be marked 'false'"));
        assertTrue(_contains(claim, "MUST be one of: EUR, GBP, JPY, CHF, CAD, AUD, NZD, SEK, NOK, DKK, SGD, HKD, CNH"));
        assertTrue(_contains(claim, "onshore CNY must use the offshore USD/CNH FX feed"));
    }

    function test_TerminationClaim_ContainsStructuralChangeCatchAll() public {
        // Deploy a composite pair
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 deployAssertionId = factory.proposePairDeployment(compositeId, false, PROPOSAL_TOTAL, "Toyota on TSE");
        vm.stopPrank();
        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(deployAssertionId);
        address pair = factory.getPairAddress(compositeId);

        // Propose its termination and inspect the UMA claim
        BazaarPairTerminator terminator = factory.pairTerminator();
        vm.startPrank(user1);
        usdc.approve(address(terminator), terminator.TERMINATION_PROPOSAL_BOND());
        bytes32 termAssertionId = terminator.proposeTermination(
            pair, "Toyota on TSE", block.timestamp + 7 days, "Reverse split announced for next month."
        );
        vm.stopPrank();

        bytes memory claim = mockOOv3.claims(termAssertionId);
        assertTrue(_contains(claim, "makes its price series discontinuous"));
        assertTrue(_contains(claim, "special dividends or other one-time distributions exceeding 5%"));
        assertTrue(_contains(claim, "redenomination of the quote currency of a composite pair"));
        assertTrue(_contains(claim, "market-driven price moves of ANY expected size"));
        // Composite pairs resolve their legs in termination claims too
        assertTrue(_contains(claim, "Base leg feed ID"));
    }

    function test_ProposeCompositePair_RevertsWhenContinuous() public {
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        vm.expectRevert(BazaarFactory.Factory__CompositePairMustBeNonContinuous.selector);
        factory.proposePairDeployment(compositeId, true, PROPOSAL_TOTAL, "Toyota on TSE");
        vm.stopPrank();
    }

    function test_CompositePair_DeploysAndPricesEndToEnd() public {
        // Propose + settle through UMA
        vm.startPrank(user1);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(compositeId, false, PROPOSAL_TOTAL, "Toyota on TSE");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);

        BazaarPair pair = BazaarPair(payable(factory.getPairAddress(compositeId)));
        assertTrue(address(pair) != address(0));
        assertEq(pair.baseFeedId(), compositeId);
        assertFalse(pair.isContinuouslyTraded());

        // Push both legs into Pyth's cache and refresh the pair price:
        // 3000 JPY at USD/JPY 150 => $20
        _pushLeg(ASSET_JPY_FEED, 3000e8, uint64(block.timestamp));
        _pushLeg(USD_JPY_FEED, 150e8, uint64(block.timestamp));

        pair.refreshPrice(new bytes[](0));

        (uint256 spot,,,,) = pair.lastPairPrice();
        assertEq(spot, 20e18);
    }
}
