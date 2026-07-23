// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title FundingIntegrationTest
/// @notice End-to-end funding-rate lifecycle: open a matched long/short (which seeds the mark-price
///         EMA from the fill), move the index away from the mark, let time elapse, and verify the
///         cumulative funding index moves in the right direction and transfers value long↔short,
///         zero-sum. Divergence is driven by refreshPrice (moving the index) rather than by matching
///         away from oracle, so no matching deviation guard is involved.
contract FundingIntegrationTest is IntegrationBase {
    /// @dev Push a fresh BTC index price through refreshPrice, paying the Pyth fee.
    function _refreshIndex(uint256 priceUsd) internal {
        bytes[] memory pu = _priceAt(priceUsd);
        uint256 fee = pair.getPythFee(pu);
        vm.deal(address(this), fee);
        pair.refreshPrice{value: fee}(pu);
    }

    /// @notice Mark above index (index falls below the fill-seeded mark) → premium positive → funding
    ///         index rises → longs PAY, shorts RECEIVE.
    function test_e2e_Funding_LongPaysWhenMarkAboveIndex() public {
        uint256 size = 1 * BAZAAR_SCALE;
        _openPosition(alice, bob, true, size); // alice long / bob short at $50k → mark seeded ~$50k

        int256 idxBefore = pair.currentFundingIndex();

        // Drop the index to $48k while the mark is still near $50k, then accrue over 30 min.
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        _refreshIndex(48_000);

        int256 idxAfter = pair.currentFundingIndex();
        assertGt(idxAfter, idxBefore, "funding index rose (mark > index)");

        BazaarTypes.BucketState memory aState = lens.checkBucketSolvency(address(pair), alice, 48_000 * BAZAAR_SCALE);
        BazaarTypes.BucketState memory bState = lens.checkBucketSolvency(address(pair), bob, 48_000 * BAZAAR_SCALE);
        assertLt(aState.fundingPnl, 0, "long pays funding");
        assertGt(bState.fundingPnl, 0, "short receives funding");
        assertEq(aState.fundingPnl, -bState.fundingPnl, "funding transfer is zero-sum");
    }

    /// @notice Mark below index (index rises above the fill-seeded mark) → premium negative → funding
    ///         index falls → longs RECEIVE, shorts PAY. The mirror of the above.
    function test_e2e_Funding_LongReceivesWhenMarkBelowIndex() public {
        uint256 size = 1 * BAZAAR_SCALE;
        _openPosition(alice, bob, true, size);

        int256 idxBefore = pair.currentFundingIndex();

        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        _refreshIndex(52_000);

        int256 idxAfter = pair.currentFundingIndex();
        assertLt(idxAfter, idxBefore, "funding index fell (mark < index)");

        BazaarTypes.BucketState memory aState = lens.checkBucketSolvency(address(pair), alice, 52_000 * BAZAAR_SCALE);
        BazaarTypes.BucketState memory bState = lens.checkBucketSolvency(address(pair), bob, 52_000 * BAZAAR_SCALE);
        assertGt(aState.fundingPnl, 0, "long receives funding");
        assertLt(bState.fundingPnl, 0, "short pays funding");
        assertEq(aState.fundingPnl, -bState.fundingPnl, "funding transfer is zero-sum");
    }

    /// @notice A price gap beyond MAX_FUNDING_GAP (12h) accrues no funding for the outage window —
    ///         the clock advances but the index does not back-charge over the gap.
    function test_e2e_Funding_StaleGapAccruesNothing() public {
        uint256 size = 1 * BAZAAR_SCALE;
        _openPosition(alice, bob, true, size);

        int256 idxBefore = pair.currentFundingIndex();

        // 13h with no price > MAX_FUNDING_GAP: the window is skipped, funding does not accrue.
        vm.warp(vm.getBlockTimestamp() + 13 hours);
        _refreshIndex(48_000);

        assertEq(pair.currentFundingIndex(), idxBefore, "no funding accrued across a >12h gap");
    }
}
