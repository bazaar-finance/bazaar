// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BucketLib} from "../../src/libraries/BucketLib.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @notice Exposes BucketLib's storage-mutating helpers over a real PositionBucket.
contract BucketHarness {
    BazaarTypes.PositionBucket internal b;

    function seed(BazaarTypes.PositionBucket calldata init) external {
        b = init;
    }

    function applyState(BazaarTypes.BucketState calldata st) external {
        BucketLib.updateFromState(b, st);
    }

    function emitUpdate(address user, int256 cfi, BazaarTypes.MarginRequirements calldata mr, bytes32 pid) external {
        BucketLib.emitBucketUpdate(user, b, cfi, mr, pid);
    }

    function bucket() external view returns (BazaarTypes.PositionBucket memory) {
        return b;
    }
}

contract BucketLibTest is Test {
    BucketHarness internal h;

    // local copy of the event so vm.expectEmit can match by topic+data
    event PositionBucketUpdated(
        bytes32 indexed pairId,
        address indexed owner,
        bool isLong,
        uint256 size,
        uint256 entryValue,
        uint256 collateral,
        int256 entryFundingIndex,
        int256 globalFundingIndex,
        uint256 imrBp,
        uint256 mmrBp,
        uint256 entryMmrBp
    );

    function setUp() public {
        h = new BucketHarness();
    }

    function test_updateFromState_persistsAndPreservesUntouchedFields() public {
        // takeProfit/stopLoss/activeMarket order IDs and isLong must survive updateFromState.
        h.seed(
            BazaarTypes.PositionBucket({
                isLong: true,
                size: 1,
                entryValue: 2,
                collateral: 3,
                entryFundingIndex: 4,
                takeProfitOrderId: 55,
                stopLossOrderId: 66,
                entryMmrBp: 7,
                activeMarketOrderId: 77,
                mmrUpdateTs: 8
            })
        );

        BazaarTypes.BucketState memory st;
        st.adjustedSize = 100;
        st.entryValue = 200;
        st.effectiveCollateral = 300;
        st.adjustedEntryFundingIndex = 400;
        st.entryMmrBp = 500;
        st.mmrUpdateTs = 600;
        h.applyState(st);

        BazaarTypes.PositionBucket memory g = h.bucket();
        // persisted from state
        assertEq(g.size, 100);
        assertEq(g.entryValue, 200);
        assertEq(g.collateral, 300);
        assertEq(g.entryFundingIndex, 400);
        assertEq(g.entryMmrBp, 500);
        assertEq(g.mmrUpdateTs, 600);
        // preserved (not written by updateFromState)
        assertTrue(g.isLong);
        assertEq(g.takeProfitOrderId, 55);
        assertEq(g.stopLossOrderId, 66);
        assertEq(g.activeMarketOrderId, 77);
    }

    function test_emitBucketUpdate_emitsBucketAndMarginFields() public {
        h.seed(
            BazaarTypes.PositionBucket({
                isLong: false,
                size: 100,
                entryValue: 200,
                collateral: 300,
                entryFundingIndex: 400,
                takeProfitOrderId: 0,
                stopLossOrderId: 0,
                entryMmrBp: 500,
                activeMarketOrderId: 0,
                mmrUpdateTs: 0
            })
        );
        BazaarTypes.MarginRequirements memory mr =
            BazaarTypes.MarginRequirements({imrBp: 300, mmrBp: 150, lastUpdateTs: 0, laggedMmrBp: 0});
        bytes32 pid = bytes32("PID");
        address user = address(0xABCD);

        vm.expectEmit(true, true, false, true);
        emit PositionBucketUpdated(pid, user, false, 100, 200, 300, 400, 999, 300, 150, 500);
        h.emitUpdate(user, 999, mr, pid);
    }
}
