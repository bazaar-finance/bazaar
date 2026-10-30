// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {FundingLib} from "../../src/libraries/FundingLib.sol";

/// @title FundingIntegrationTest
/// @notice End-to-end funding-rate lifecycle: open a matched long/short whose fill against a quote
///         standing on the far side of the index forms the mark's premium, let time elapse, and
///         verify the cumulative funding index moves in the right direction and transfers value
///         long↔short, zero-sum. The premium comes from the fill alone: the mark is the index
///         carried by it, so a move of the index moves the mark too and charges nothing.
contract FundingIntegrationTest is IntegrationBase {
    /// @dev Push a fresh BTC index price through refreshPrice, paying the Pyth fee.
    function _refreshIndex(uint256 priceUsd) internal {
        bytes[] memory pu = _priceAt(priceUsd);
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(address(this), fee);
        pair.refreshPrice{value: fee}(pu);
    }

    /// @notice Mark above index (bob sells into alice's bid resting above the $50k oracle) →
    ///         premium positive → funding index rises → longs PAY, shorts RECEIVE.
    function test_e2e_Funding_LongPaysWhenMarkAboveIndex() public {
        uint256 size = 1 * BAZAAR_SCALE;
        _openPosition(alice, bob, true, size); // alice long / bob short, filled at her $51k bid
        assertGt(lens.markPrice(address(pair)), 50_000 * BAZAAR_SCALE, "fixture: the fill formed a premium");

        int256 idxBefore = pair.currentFundingIndex();

        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        _refreshIndex(50_000);

        int256 idxAfter = pair.currentFundingIndex();
        assertGt(idxAfter, idxBefore, "funding index rose (mark > index)");

        BazaarTypes.BucketState memory aState = lens.checkBucketSolvency(address(pair), alice, 50_000 * BAZAAR_SCALE);
        BazaarTypes.BucketState memory bState = lens.checkBucketSolvency(address(pair), bob, 50_000 * BAZAAR_SCALE);
        assertLt(aState.fundingPnl, 0, "long pays funding");
        assertGt(bState.fundingPnl, 0, "short receives funding");
        assertEq(aState.fundingPnl, -bState.fundingPnl, "funding transfer is zero-sum");
    }

    /// @notice Mark below index (alice buys from bob's ask resting below the $50k oracle) →
    ///         premium negative → funding index falls → longs RECEIVE, shorts PAY. The mirror of
    ///         the above.
    function test_e2e_Funding_LongReceivesWhenMarkBelowIndex() public {
        uint256 size = 1 * BAZAAR_SCALE;
        _openPosition(bob, alice, false, size); // bob short / alice long, filled at his $49k ask
        assertLt(lens.markPrice(address(pair)), 50_000 * BAZAAR_SCALE, "fixture: the fill formed a discount");

        int256 idxBefore = pair.currentFundingIndex();

        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        _refreshIndex(50_000);

        int256 idxAfter = pair.currentFundingIndex();
        assertLt(idxAfter, idxBefore, "funding index fell (mark < index)");

        BazaarTypes.BucketState memory aState = lens.checkBucketSolvency(address(pair), alice, 50_000 * BAZAAR_SCALE);
        BazaarTypes.BucketState memory bState = lens.checkBucketSolvency(address(pair), bob, 50_000 * BAZAAR_SCALE);
        assertGt(aState.fundingPnl, 0, "long receives funding");
        assertLt(bState.fundingPnl, 0, "short pays funding");
        assertEq(aState.fundingPnl, -bState.fundingPnl, "funding transfer is zero-sum");
    }

    /// @dev The pair's stored mark line: the anchor and volume tally from auxState, the premium
    ///      tally from its storage slot, the one BazaarPairLens names SLOT_MARK_PREMIUM_NOTIONAL.
    function _storedLine() internal view returns (FundingLib.MarkState memory s) {
        BazaarTypes.AuxState memory a = pair.auxState();
        s.lastMarkUpdateTs = a.lastMarkUpdateTs;
        s.rollingVolume = a.rollingVolume;
        s.premiumNotional = int256(uint256(vm.load(address(pair), bytes32(uint256(63)))));
    }

    /// @dev Per-side open interest, counting the vault's inventory on its side, as the floor is
    ///      sized (RiskParamsLib.openInterestSize).
    function _oiSize() internal view returns (uint256) {
        (uint256 l, uint256 s,,,,, uint256 pend,,,, bool pendLong,,,,,,) = pair.pairVault();
        if (pendLong) l += pend;
        else s += pend;
        return l > s ? l : s;
    }

    /// @notice The index's own move is not a premium, and a store charges the average premium its
    ///         window read. Alice's bid above the $50k oracle forms a premium; half an hour later
    ///         the index stands at $48k, and the store charges what FundingLib.averagePremium gives
    ///         for the pair's stored line over that half hour, carried on $48k, with the floor
    ///         sized from the open interest at $48k. The window's average lies between the premium
    ///         the print formed and half of it, since the line is under the floor and fades from its
    ///         anchor. A mark drawn as a price from the $50k the print traded against would read
    ///         the $2k fall as premium too.
    function test_e2e_Funding_IndexMoveChargesOnlyThePremium() public {
        uint256 size = 1 * BAZAAR_SCALE;
        _openPosition(alice, bob, true, size);
        uint256 printedAt = vm.getBlockTimestamp();
        uint256 printIndex = 50_000 * BAZAAR_SCALE;
        int256 premium =
            (int256(lens.markPrice(address(pair))) - int256(printIndex)) * int256(BAZAAR_SCALE) / int256(printIndex);
        assertGt(premium, 0, "fixture: the fill formed a premium");
        FundingLib.MarkState memory line = _storedLine();

        int256 idxBefore = pair.currentFundingIndex();

        vm.warp(printedAt + 30 minutes);
        _refreshIndex(48_000);

        uint256 index = 48_000 * BAZAAR_SCALE;
        int256 average = FundingLib.averagePremium(
            line, FundingLib.floorVolumeOf(_oiSize(), index), printedAt, printedAt + 30 minutes
        );
        // The floor at $48k is 4% smaller than at $50k, so the same tally reads 4% more over it.
        int256 atPrint = premium * 50_000 / 48_000;
        assertLt(average, atPrint, "the average is below the premium the print formed");
        assertGt(average, atPrint / 2, "and above half of it, where the fade leaves the window's close");

        uint256 dampener =
            pair.isContinuouslyTraded() ? FundingLib.FUNDING_DAMPENER_CONTINUOUS : FundingLib.FUNDING_DAMPENER_SESSION;
        int256 rate = average / int256(dampener);
        int256 expected =
            rate * int256(index) * int256(30 minutes) / int256(BAZAAR_SCALE) / int256(FundingLib.FUNDING_INTERVAL);
        assertEq(pair.currentFundingIndex() - idxBefore, expected, "funding on the window's average premium alone");
        assertLt(expected, int256(10 * BAZAAR_SCALE), "a few dollars a BTC for the half hour");
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
