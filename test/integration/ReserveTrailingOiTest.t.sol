// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";

/// @title ReserveTrailingOiTest
/// @notice The fund's reserve is sized on the lower of live open interest and its lowest reading
///         over the trailing day. Open interest counts matched positions of one owner, so sized
///         on the live figure alone the reserve could be raised within a transaction: the fund's
///         capital above it would fall to zero, and a loss the fund can carry would open an ADL
///         window that charges it to winners instead. Open interest reaches the reserve only once
///         it has been held for the whole lookback.
contract ReserveTrailingOiTest is IntegrationBase {
    uint256 constant MARK_USD = 50_000;
    uint256 constant MARK = MARK_USD * BAZAAR_SCALE;
    uint256 constant HONEST = 1 * BAZAAR_SCALE; // open interest per side that has been there all day
    uint256 constant MATCHED = 100 * BAZAAR_SCALE; // one owner's matched long and short

    // ---------------------------- fixture ----------------------------

    function _trailingOi() internal view returns (uint256 t) {
        (,,,,,,,,,,,,,,,, t) = pair.pairVault();
    }

    function _pendingLiqSize() internal view returns (uint256 size) {
        (,,,,,, size,,,,,,,,,,) = pair.pairVault();
    }

    /// @dev Store a fresh mark at `priceUsd` as the keeper `after_` seconds on, which also advances
    ///      the sample ring and runs the health check.
    function _refreshAfter(uint256 after_, uint256 priceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + after_);
        bytes[] memory pu = _priceAt(priceUsd);
        vm.prank(seq);
        pair.refreshPrice(pu);
    }

    /// @dev `hours_` hourly refreshes at `priceUsd`.
    function _refreshHourly(uint256 hours_, uint256 priceUsd) internal {
        for (uint256 i = 0; i < hours_; i++) {
            _refreshAfter(1 hours, priceUsd);
        }
    }

    /// @dev `long_` and `short_` cross `size` at `priceUsd`.
    function _cross(address long_, address short_, uint256 size, uint256 priceUsd) internal {
        _placeLimitAt(long_, true, size, priceUsd * BAZAAR_SCALE, priceUsd);
        _roll(2);
        _placeLimitAt(short_, false, size, priceUsd * BAZAAR_SCALE, priceUsd);
        assertEq(_posSize(short_), size, "fixture: the two orders crossed");
    }

    /// @dev alice and bob hold one unit each side at the mark, and the ring has sampled it hourly
    ///      for more than a day, so it is the trailing figure.
    function _honestDay() internal {
        _deposit(alice, 30_000 * BAZAAR_SCALE);
        _deposit(bob, 30_000 * BAZAAR_SCALE);
        _cross(alice, bob, HONEST, MARK_USD);
        _refreshHourly(26, MARK_USD);
        assertEq(_trailingOi(), HONEST, "fixture: a day of history at the honest open interest");
    }

    /// @dev Free capital, the reserve and the inventory's net position, all at the stored mark and
    ///      the live funding index: the three figures the ADL gate's opening test compares.
    function _fundAtMark() internal view returns (uint256 free, uint256 reserve, int256 net) {
        (
            uint256 longOI,
            uint256 shortOI,,,,
            uint256 fund,
            uint256 size,
            uint256 entryNotional,,
            int256 entryFundingIndex,
            bool isLong,,
            uint256 targetBp,
            uint256 seized,
            uint256 arrears,,
            uint256 trailing
        ) = pair.pairVault();
        (uint256 spot,,,,) = pair.lastPairPrice();
        free = fund - seized;
        reserve = RiskParamsLib.adlReserveOf(
            RiskParamsLib.reserveOiSizeOf(RiskParamsLib.openInterestSizeOf(longOI, shortOI, size, isLong), trailing),
            spot,
            targetBp
        );
        net = int256(seized + arrears)
            + RiskParamsLib.inventoryPnl(
                size, entryNotional, entryFundingIndex, isLong, spot, pair.currentFundingIndex()
            );
    }

    /// @dev The insurance target in dollars on live open interest at the stored mark.
    function _targetOnLiveOi() internal view returns (uint256) {
        (uint256 longOI, uint256 shortOI,,,,, uint256 size,,,, bool isLong,, uint256 targetBp,,,,) = pair.pairVault();
        (uint256 spot,,,,) = pair.lastPairPrice();
        return RiskParamsLib.openInterestSizeOf(longOI, shortOI, size, isLong) * spot / BAZAAR_SCALE * targetBp / 10_000;
    }

    /// @dev Leave the vault long one unit with half the fund seized alongside it and a loss at the
    ///      mark that leaves the fund twice its target on live open interest. Coverage above
    ///      target keeps the taker insurance fee at its base rate, so the fee the matched
    ///      positions pay into the fund stays small beside the reserve they would add. Staged on
    ///      a whole inventory first so the refresh that follows opens no window.
    function _stageLossInsideTheHeadroom() internal returns (uint256 headroom) {
        _depositInsurance(deployer, 200_000 * BAZAAR_SCALE);
        uint256 seized = _insuranceBal() / 2;
        _stageHeldInventory(MARK + seized, seized);
        _refreshAfter(30, MARK_USD);
        assertFalse(pair.isAdlPending(), "fixture: a whole inventory opens no window");

        (uint256 free, uint256 reserve,) = _fundAtMark();
        uint256 remaining = 2 * _targetOnLiveOi();
        assertGt(reserve, 0, "fixture: a reserve exists");
        assertGt(remaining, 2 * reserve, "fixture: what the loss leaves clears the reserve on twice the honest book");
        uint256 loss = free - remaining;
        headroom = remaining - reserve;
        // One unit long: net = seized + mark - entry - funding index.
        _stageHeldInventory(uint256(int256(MARK + seized) - pair.currentFundingIndex()) + loss, seized);
        int256 net;
        (free, reserve, net) = _fundAtMark();
        assertEq(net, -int256(loss), "fixture: the staged loss");
        assertEq(free - reserve - loss, headroom, "fixture: and the headroom it leaves");
    }

    /// @dev carol and dave, standing in for one owner's two accounts, cross MATCHED at the mark:
    ///      a hundred times the honest open interest, opened in two calls.
    function _openMatchedPositions() internal {
        uint256 collateral = MATCHED * MARK_USD;
        usdc.mint(carol, collateral * USDC_SCALE / BAZAAR_SCALE);
        usdc.mint(dave, collateral * USDC_SCALE / BAZAAR_SCALE);
        _deposit(carol, collateral);
        _deposit(dave, collateral);
        _cross(carol, dave, MATCHED, MARK_USD);
    }

    // ---------------------------- tests ----------------------------

    /// @notice Matched positions a hundred times the size of the book, opened while the vault holds
    ///         inventory at a loss the fund can carry, do not open an ADL window: the reserve
    ///         stays on the open interest that was there all day, so the fund's capital above it
    ///         is what it was.
    function test_matchedPositions_doNotRaiseTheReserve_noWindowOpens() public {
        _honestDay();
        _stageLossInsideTheHeadroom();

        _openMatchedPositions();

        assertFalse(pair.isAdlPending(), "the fill's own health check opens no window");
        assertEq(_trailingOi(), HONEST, "the trailing figure is still the day's low");
        (uint256 free, uint256 reserve, int256 net) = _fundAtMark();
        assertLe(uint256(-net), free - reserve, "the loss still fits free capital above the reserve");
        _refreshAfter(3, MARK_USD);
        assertFalse(pair.isAdlPending(), "nor does a refresh at the same mark");
    }

    /// @notice Open interest that is held does reach the reserve, a full day later: positions
    ///         carried that long are exposure in their own right. Until then the pair stays
    ///         healthy; once every sampled interval in the window carries them the reserve rises
    ///         and the same loss no longer fits above it.
    function test_heldPositions_raiseTheReserveAfterAFullDay() public {
        _honestDay();
        _stageLossInsideTheHeadroom();
        _openMatchedPositions();

        _refreshHourly(23, MARK_USD);
        assertEq(_trailingOi(), HONEST, "an interval that saw the honest figure is still in the window");
        assertFalse(pair.isAdlPending(), "and the pair is healthy while it is");

        _refreshHourly(3, MARK_USD);
        assertGt(_trailingOi(), MATCHED, "every interval in the window now carries the larger figure");
        assertTrue(pair.isAdlPending(), "sized on it, the reserve leaves the loss no room");
    }

    /// @notice An ADL batch is sized to end the auction in one call when live open interest sits
    ///         above the trailing figure. Closing inventory then lowers live open interest
    ///         without lowering the reserve, so the batch cannot count on a reserve release to
    ///         cover part of the distance.
    function test_adlBatch_sizedWithoutAReserveRelease_endsTheAuction() public {
        uint256 size = 72 * BAZAAR_SCALE / 100;

        // A day of history at a tenth of a unit per side.
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(carol, 20_000 * BAZAAR_SCALE);
        _cross(alice, carol, BAZAAR_SCALE / 10, 80_000);
        _refreshHourly(26, 80_000);
        assertEq(_trailingOi(), BAZAAR_SCALE / 10, "fixture: the trailing figure is the small book");

        // dave long and bob short 0.72, opened now; dave is seized on a fall to $30k, which leaves
        // the vault long 0.72 with a loss far past the fund.
        _deposit(dave, 19_200 * BAZAAR_SCALE);
        _deposit(bob, 16_000 * BAZAAR_SCALE);
        _cross(dave, bob, size, 80_000);
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceAt(30_000);
        vm.prank(seq);
        assertEq(pair.liquidate(_arr1(dave), pu), 1, "fixture: dave seized");
        assertTrue(pair.isAdlPending(), "fixture: the estate's loss exceeds the fund");
        assertEq(_trailingOi(), BAZAAR_SCALE / 10, "fixture: live open interest sits above the trailing figure");

        // Past the Dutch decay, so bob's score clears the threshold.
        vm.warp(vm.getBlockTimestamp() + BazaarTypes.ADL_AUCTION_DURATION + 1);
        pu = _priceAt(30_000);
        vm.prank(seq);
        pair.executeAdl(_arr1(bob), new address[](0), pu);

        assertFalse(pair.isAdlPending(), "one batch ends the auction");
        assertGt(_pendingLiqSize(), 0, "without closing the whole inventory");
        assertLt(_pendingLiqSize(), size, "and having closed part of it");
    }
}
