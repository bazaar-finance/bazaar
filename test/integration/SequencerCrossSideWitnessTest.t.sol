// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {BazaarSequencer} from "../../src/BazaarSequencer.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @notice The Pass-C cross-side omission witnesses (lowestShortLimitPriceC / highestLongLimitPriceC)
///         — the always-on anti-selective-censorship path for Market/StopLoss orders when no same-side
///         market head matched. `grep PriceC` found no test touching these. A censoring sequencer that
///         matches only limit×limit while dropping a crossable market must still be slashable via the
///         cross-side witness; these prove it, on both sides.
contract SequencerCrossSideWitnessTest is IntegrationBase {
    address internal challenger;

    function setUp() public override {
        super.setUp();
        challenger = makeAddr("challenger");
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _deposit(dave, 20_000 * BAZAAR_SCALE);
    }

    function _captureBatch() internal returns (uint256 batchId, BazaarTypes.BatchInfo memory info) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == BazaarTypes.BatchRecorded.selector) {
                batchId = uint256(logs[i].topics[2]);
                info = abi.decode(logs[i].data, (BazaarTypes.BatchInfo));
                return (batchId, info);
            }
        }
        revert("no BatchRecorded event emitted");
    }

    /// @dev A pure Pass-C limit×limit cross (carol long $52k vs dave short $49k). No market matches,
    ///      so lowestLongMarketPrice stays 0 and the Pass-C cross-side witnesses are the only way an
    ///      omitted market can be in-range.
    function _passCBatch() internal returns (uint256 batchId, BazaarTypes.BatchInfo memory info) {
        uint256 size = 1 * BAZAAR_SCALE;
        uint256 carolLong = _placeLimit(carol, true, size, 52_000 * BAZAAR_SCALE);
        uint256 daveShort = _placeLimit(dave, false, size, 49_000 * BAZAAR_SCALE);
        _roll(2);
        vm.recordLogs();
        assertEq(_match(_lists(_one(carolLong), _one(daveShort), _empty(), _empty()), 10), 1, "Pass-C cross fills");
        (batchId, info) = _captureBatch();
    }

    /// @notice An omitted long MARKET is admitted by the lowestShortLimitPriceC witness (the lowest
    ///         short limit that crossed in Pass C), even though no long market matched to set a
    ///         same-side witness. The sequencer is slashed.
    function test_crossSide_longMarketOmission_slashed() public {
        uint256 marketId = _placeMarket(alice, true, 1 * BAZAAR_SCALE / 10, 500); // omitted long market
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _passCBatch();

        assertEq(info.lowestLongMarketPrice, 0, "no same-side market witness");
        assertGt(info.lowestShortLimitPriceC, 0, "Pass-C cross-side witness is set");

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.prank(challenger);
        sequencer.challengeOmission(address(pair), batchId, info, marketId);
        assertLt(sequencer.sequencerBonds(seq), bondBefore, "long market in-range via cross-side witness -> slashed");
    }

    /// @notice Mirror on the short side: an omitted short MARKET is admitted by highestLongLimitPriceC.
    function test_crossSide_shortMarketOmission_slashed() public {
        uint256 marketId = _placeMarket(alice, false, 1 * BAZAAR_SCALE / 10, 500); // omitted short market
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _passCBatch();

        assertEq(info.highestShortMarketPrice, 0, "no same-side market witness");
        assertGt(info.highestLongLimitPriceC, 0, "Pass-C cross-side witness is set");

        uint256 bondBefore = sequencer.sequencerBonds(seq);
        vm.prank(challenger);
        sequencer.challengeOmission(address(pair), batchId, info, marketId);
        assertLt(sequencer.sequencerBonds(seq), bondBefore, "short market in-range via cross-side witness -> slashed");
    }
}
