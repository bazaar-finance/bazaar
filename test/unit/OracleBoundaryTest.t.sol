// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarOracle} from "../../src/BazaarOracle.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

/// @notice Oracle boundary reverts CompositeOracleTest didn't reach: the QUOTE-leg non-positive
///         reject (only the base leg was covered), and the SINGLE-FEED base confidence cap — the
///         path every non-composite pair hits (only the quote-leg and composed-bracket caps were
///         covered). An inverted comparison here would silently price a pair off a bad tick.
contract OracleBoundaryTest is Test {
    bytes32 constant ASSET_JPY_FEED = keccak256("test.EQUITY.7203/JPY");
    bytes32 constant USD_JPY_FEED = keccak256("test.FX.USD/JPY");
    int32 constant PYTH_EXPO = -8;

    MockPyth mockPyth;
    BazaarOracle oracle;

    function setUp() public {
        vm.warp(1_700_000_000);
        mockPyth = new MockPyth(60, 1);
        oracle = new BazaarOracle(address(mockPyth));
        vm.deal(address(this), 1 ether);
    }

    function _updateData(bytes32 id, int64 price, uint64 conf, uint64 pub) internal view returns (bytes memory) {
        return mockPyth.createPriceFeedUpdateData(id, price, conf, PYTH_EXPO, price, conf, pub, pub - 1);
    }

    function _push(bytes32 id, int64 price, uint64 conf, uint64 pub) internal {
        bytes[] memory u = new bytes[](1);
        u[0] = _updateData(id, price, conf, pub);
        mockPyth.updatePriceFeeds{value: mockPyth.getUpdateFee(u)}(u);
    }

    function _bothLegs(int64 baseP, uint64 baseC, int64 quoteP, uint64 quoteC, uint64 pub)
        internal
        view
        returns (bytes[] memory u)
    {
        u = new bytes[](2);
        u[0] = _updateData(ASSET_JPY_FEED, baseP, baseC, pub);
        u[1] = _updateData(USD_JPY_FEED, quoteP, quoteC, pub);
    }

    // ==================== quote-leg non-positive (hard reject on every path) ====================

    /// @notice A zero quote leg is a hard error on the fresh path — flooring it (the base-leg trick)
    ///         would explode the composite instead of zeroing it, so it must revert.
    function test_quoteZero_tryReadFresh_reverts() public {
        oracle.registerComposite(ASSET_JPY_FEED, USD_JPY_FEED, true);
        bytes32 id = oracle.getCompositeId(ASSET_JPY_FEED, USD_JPY_FEED, true);
        _push(ASSET_JPY_FEED, 3000e8, 0, uint64(block.timestamp)); // base valid
        _push(USD_JPY_FEED, 0, 0, uint64(block.timestamp)); // quote zero

        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__InvalidPrice.selector, USD_JPY_FEED, int64(0), PYTH_EXPO)
        );
        oracle.tryReadFreshPrice(id, 60);
    }

    /// @notice Same reject through the state-changing updateAndFetchPrice entry.
    function test_quoteZero_updateAndFetch_reverts() public {
        oracle.registerComposite(ASSET_JPY_FEED, USD_JPY_FEED, true);
        bytes32 id = oracle.getCompositeId(ASSET_JPY_FEED, USD_JPY_FEED, true);
        bytes[] memory u = _bothLegs(3000e8, 0, 0, 0, uint64(block.timestamp));
        uint256 fee = oracle.getUpdateFee(u); // hoist: expectRevert binds to the NEXT external call

        vm.expectRevert(
            abi.encodeWithSelector(BazaarOracle.BazaarOracle__InvalidPrice.selector, USD_JPY_FEED, int64(0), PYTH_EXPO)
        );
        oracle.updateAndFetchPrice{value: fee}(id, u, 60);
    }

    /// @notice A negative quote leg is rejected the same way (distinct from the base leg's 1-wei floor).
    function test_quoteNegative_updateAndFetch_reverts() public {
        oracle.registerComposite(ASSET_JPY_FEED, USD_JPY_FEED, true);
        bytes32 id = oracle.getCompositeId(ASSET_JPY_FEED, USD_JPY_FEED, true);
        bytes[] memory u = _bothLegs(3000e8, 0, -1e8, 0, uint64(block.timestamp));
        uint256 fee = oracle.getUpdateFee(u); // hoist: expectRevert binds to the NEXT external call

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__InvalidPrice.selector, USD_JPY_FEED, int64(-1e8), PYTH_EXPO
            )
        );
        oracle.updateAndFetchPrice{value: fee}(id, u, 60);
    }

    // ==================== single-feed base confidence cap (2%) ====================

    /// @notice A single-feed base whose confidence exceeds 2% of price is rejected — the safe path
    ///         every non-composite pair takes. conf 61 on price 3000 = 2.03% > 2%.
    function test_singleFeed_confidenceTooHigh_reverts() public {
        bytes[] memory u = new bytes[](1);
        u[0] = _updateData(ASSET_JPY_FEED, 3000e8, 61e8, uint64(block.timestamp));
        uint256 fee = oracle.getUpdateFee(u); // hoist: expectRevert binds to the NEXT external call

        vm.expectRevert(
            abi.encodeWithSelector(
                BazaarOracle.BazaarOracle__ConfidenceTooHigh.selector, uint256(61e18), uint256(3000e18)
            )
        );
        oracle.updateAndFetchPrice{value: fee}(ASSET_JPY_FEED, u, 60);
    }

    /// @notice Confidence exactly at 2% (conf 60 on price 3000) passes — pins the strict-`>` boundary.
    function test_singleFeed_confidenceExactly2pct_passes() public {
        bytes[] memory u = new bytes[](1);
        u[0] = _updateData(ASSET_JPY_FEED, 3000e8, 60e8, uint64(block.timestamp));

        (uint256 spot,,,) = oracle.updateAndFetchPrice{value: oracle.getUpdateFee(u)}(ASSET_JPY_FEED, u, 60);
        assertEq(spot, 3000e18, "exactly 2% confidence is accepted");
    }
}
