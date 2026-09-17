// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";

/// @title BazaarIntegrationTest
/// @notice Core cross-subsystem scenarios: matching, liquidation, the vault, and the insurance fund
///         on a full factory/oracle/pair deployment. Harness lives in IntegrationBase.
contract BazaarIntegrationTest is IntegrationBase {
    /// @notice Liquidation cascade: an underwater position is liquidated → collateral is seized into
    ///         the insurance fund → the vault inherits the position as pending-liq exposure.
    function test_e2e_LiquidationSeizesToInsuranceAndVaultInherits() public {
        _setupInsolventAlice();
        (, uint256 aliceSize,,,,,,,) = pair.positionBuckets(alice);
        assertEq(aliceSize, BAZAAR_SCALE / 10, "alice holds a 0.1 BTC long");

        (,,,,, uint256 insBefore,,,,,,,,) = pair.pairVault();

        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), _freshPrice()), 1, "alice liquidated");

        (, uint256 aliceSizeAfter,, uint256 aliceColl,,,,,) = pair.positionBuckets(alice);
        assertEq(aliceSizeAfter, 0, "position closed");
        assertEq(aliceColl, 0, "collateral fully seized");

        (,,,,, uint256 insAfter, uint256 pendSize,,,, bool pendIsLong,,,) = pair.pairVault();
        assertGt(insAfter, insBefore, "insurance grew from the seizure");
        assertEq(pendSize, BAZAAR_SCALE / 10, "vault inherited the 0.1 BTC");
        assertTrue(pendIsLong, "vault holds the long side");
    }

    /// @notice PnL is peer-to-peer and zero-sum: a matched long/short valued at $55k via the Lens
    ///         show equal-and-opposite unrealized PnL.
    function test_e2e_MatchedPositions_ZeroSumPnl() public {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, 1 * BAZAAR_SCALE, 50_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, 1 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), 1 * BAZAAR_SCALE, "opened at $50k");

        BazaarTypes.BucketState memory aState = lens.checkBucketSolvency(address(pair), alice, 55_000 * BAZAAR_SCALE);
        BazaarTypes.BucketState memory bState = lens.checkBucketSolvency(address(pair), bob, 55_000 * BAZAAR_SCALE);

        assertEq(aState.unrealizedPnl, int256(5_000 * BAZAAR_SCALE), "long +$5k at $55k");
        assertEq(bState.unrealizedPnl, -int256(5_000 * BAZAAR_SCALE), "short -$5k at $55k");
        assertEq(aState.totalPnl, -bState.totalPnl, "zero-sum");
        assertGt(aState.totalPnl, int256(0));
        assertLt(bState.totalPnl, int256(0));
    }

    /// @notice Insurance-fund lifecycle: an insurer deposits and receives shares, then a liquidation
    ///         banks its seizure into the fund alongside the inventory the vault now holds. A
    ///         redemption does not see that seizure — it is earmarked against the inventory and
    ///         leaves again when it unloads, and the surplus beyond it is never paid to a leaver —
    ///         while a newcomer pays for the surplus the moment it exists.
    function test_e2e_InsurerShareValue_SeizureEarmarkedUntilUnload() public {
        _depositInsurance(carol, 1_000 * BAZAAR_SCALE);

        uint256 sharesBefore = pair.insuranceShares(carol);
        assertGt(sharesBefore, 0, "carol received insurance shares");
        uint256 valueBefore = lens.getInsuranceDepositValue(address(pair), carol);
        uint256 mark = 50_000 * BAZAAR_SCALE;
        uint256 quoteBefore = lens.quoteInsuranceDeposit(address(pair), 1_000 * BAZAAR_SCALE, mark);

        _setupInsolventAlice();
        vm.prank(bob);
        assertEq(pair.liquidate(_arr1(alice), _freshPrice()), 1, "liquidated");

        assertEq(pair.insuranceShares(carol), sharesBefore, "share count unchanged");
        // The liquidator's reward came out of free capital; the seizure adds nothing a leaver can take.
        assertLe(lens.getInsuranceDepositValue(address(pair), carol), valueBefore, "redemption value did not grow");
        assertLt(
            lens.quoteInsuranceDeposit(address(pair), 1_000 * BAZAAR_SCALE, mark),
            quoteBefore,
            "a newcomer pays for the inventory's surplus"
        );
    }
}
