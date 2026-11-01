// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";

/// @title InsuranceWithdrawalWindowTest
/// @notice A matured insurance-withdrawal request stays executable for a window whose length
///         follows the pair's trading calendar: two days on a pair that trades around the clock,
///         four on a pair with trading hours, whose execute calls need its venue open. These tests
///         pin both lengths at execution and in the lens, that the lock-too-late rule is judged
///         against the pair's own window end, and that a session pair's window opening as a long
///         weekend begins still pays at the reopen.
contract InsuranceWithdrawalWindowTest is IntegrationBase {
    uint256 internal constant COOLDOWN = InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN;
    uint256 internal constant CLAIM_DELAY = InsuranceVaultLib.INSURANCE_WITHDRAWAL_CLAIM_DELAY;
    uint256 internal constant REOPEN_DELAY = InsuranceVaultLib.INSURANCE_WITHDRAWAL_REOPEN_CLAIM_DELAY;
    uint256 internal constant BTC_USD = 50_000;
    uint256 internal constant AAPL_USD = 150;

    address internal keeper = makeAddr("keeper");

    // ---------------------------------------------------------------- fixtures

    /// @dev A keeper stores a fresh print on `p` four seconds on, past the cache's staleness
    ///      bound, forwarding the Pyth fee.
    function _refresh(BazaarPair p, bytes32 feedId, uint256 priceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdateFor(feedId, priceUsd, uint64(vm.getBlockTimestamp()));
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(keeper, fee);
        vm.prank(keeper);
        p.refreshPrice{value: fee}(pu);
    }

    /// @dev Moves the chain to `ts` with `p` trading: a keeper stores the print that ends any
    ///      storage gap a reopen delay and a minute before, and another seconds before `ts`, so a
    ///      lock at `ts` opens its claim a plain claim delay later.
    function _liveAt(BazaarPair p, bytes32 feedId, uint256 priceUsd, uint256 ts) internal {
        vm.warp(ts - REOPEN_DELAY - 60);
        _refresh(p, feedId, priceUsd);
        vm.warp(ts - 10);
        _refresh(p, feedId, priceUsd);
        vm.warp(ts);
    }

    function _aaplNow() internal view returns (bytes[] memory) {
        return _priceUpdateFor(AAPL_USD_FEED_ID, AAPL_USD, uint64(vm.getBlockTimestamp()));
    }

    /// @dev `user` requests every share it holds on the BTC pair.
    function _requestAllBtc(address user) internal {
        uint256 shares = pair.insuranceShares(user);
        vm.prank(user);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
    }

    /// @dev `user` funds the AAPL pair's insurance with $1,000, which reads no price while the
    ///      vault holds no inventory, and requests a fifth of the shares it minted.
    function _depositAndRequestAapl(address user) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), 1_000 * USDC_SCALE);
        aaplPair.depositToInsurance(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "", "");
        aaplPair.requestInsuranceWithdrawal(aaplPair.insuranceShares(user) / 5, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    /// @dev One call by `user` on `p` carrying `pu`, expected to revert with `revertData`.
    function _expectRedemptionRevert(BazaarPair p, address user, bytes[] memory pu, bytes memory revertData) internal {
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(user, fee);
        vm.prank(user);
        vm.expectRevert(revertData);
        p.executeInsuranceWithdrawal{value: fee}(pu, 0, 0, 0, "", "");
    }

    // ---------------------------------------------------------------- lengths

    /// @notice The window's length is chosen by the pair's trading calendar alone.
    function test_windowLength_followsTheTradingCalendar() public pure {
        assertEq(InsuranceVaultLib.INSURANCE_WITHDRAWAL_WINDOW_CONTINUOUS, 2 days, "24/7 pairs: two days");
        assertEq(InsuranceVaultLib.INSURANCE_WITHDRAWAL_WINDOW_SESSION, 4 days, "session pairs: four days");
        assertEq(InsuranceVaultLib.withdrawalWindowOf(true), 2 days, "a continuously traded pair takes the short one");
        assertEq(InsuranceVaultLib.withdrawalWindowOf(false), 4 days, "a pair with trading hours takes the long one");
    }

    /// @notice On the BTC pair, which trades around the clock, the window closes two days after
    ///         the cooldown. The last lock it admits claims at its final second, and one second
    ///         later a ripe request is refused with its shares kept.
    function test_continuousPair_windowClosesTwoDaysAfterTheCooldown() public {
        _depositInsurance(carol, 1_000 * BAZAAR_SCALE);
        _depositInsurance(dave, 1_000 * BAZAAR_SCALE);
        uint256 requestTs = vm.getBlockTimestamp();
        _requestAllBtc(carol);
        _requestAllBtc(dave);
        uint256 daveShares = pair.insuranceShares(dave);

        (,,,, uint256 windowEndTs) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertEq(windowEndTs, requestTs + COOLDOWN + 2 days, "the lens closes the window two days on");

        _liveAt(pair, BTC_USD_FEED_ID, BTC_USD, windowEndTs - CLAIM_DELAY);
        _executeRedemption(pair, carol, _priceAt(BTC_USD));
        (bool isLocked,,, uint256 opensTs,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertTrue(isLocked, "a lock a claim delay before the end is accepted");
        assertEq(opensTs, windowEndTs, "its claim opens as the window closes");
        vm.warp(opensTs);
        uint256 before = usdc.balanceOf(carol);
        _executeRedemption(pair, carol, _priceAt(BTC_USD));
        assertGt(usdc.balanceOf(carol), before, "paid at the window's last second");
        assertEq(pair.insuranceShares(carol), 0, "carol's requested shares burned");

        vm.warp(windowEndTs + 1);
        _expectRedemptionRevert(
            pair,
            dave,
            _priceAt(BTC_USD),
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__WithdrawalWindowExpired.selector)
        );
        assertEq(pair.insuranceShares(dave), daveShares, "the lapsed request keeps its shares");
    }

    /// @notice On the AAPL pair, which has trading hours, the same request stays executable for
    ///         four days after the cooldown, twice as long: the lens and execution agree on the
    ///         end, the last lock claims at its final second, and one second later a ripe request
    ///         is refused.
    function test_sessionPair_windowClosesFourDaysAfterTheCooldown() public {
        _refresh(aaplPair, AAPL_USD_FEED_ID, AAPL_USD);
        uint256 requestTs = vm.getBlockTimestamp();
        _depositAndRequestAapl(carol);
        _depositAndRequestAapl(dave);
        uint256 carolShares = aaplPair.insuranceShares(carol);
        uint256 carolRequested = aaplPair.insuranceWithdrawalRequestShareAmount(carol);
        uint256 daveShares = aaplPair.insuranceShares(dave);

        (,,,, uint256 windowEndTs) = lens.getInsuranceWithdrawalLock(address(aaplPair), carol);
        assertEq(windowEndTs, requestTs + COOLDOWN + 4 days, "the lens closes the window four days on");

        _liveAt(aaplPair, AAPL_USD_FEED_ID, AAPL_USD, windowEndTs - CLAIM_DELAY);
        _executeRedemption(aaplPair, carol, _aaplNow());
        (bool isLocked,,, uint256 opensTs,) = lens.getInsuranceWithdrawalLock(address(aaplPair), carol);
        assertTrue(isLocked, "a lock a claim delay before the end is accepted");
        assertEq(opensTs, windowEndTs, "its claim opens as the window closes");
        vm.warp(opensTs);
        uint256 before = usdc.balanceOf(carol);
        _executeRedemption(aaplPair, carol, _aaplNow());
        assertGt(usdc.balanceOf(carol), before, "paid at the window's last second");
        assertEq(aaplPair.insuranceShares(carol), carolShares - carolRequested, "carol's requested shares burned");

        vm.warp(windowEndTs + 1);
        _expectRedemptionRevert(
            aaplPair,
            dave,
            _aaplNow(),
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__WithdrawalWindowExpired.selector)
        );
        assertEq(aaplPair.insuranceShares(dave), daveShares, "the lapsed request keeps its shares");
    }

    /// @notice The lock-too-late rule reads the pair's own window: on the AAPL pair a lock one
    ///         second after the last one its window admits is refused with the four-day end, and
    ///         nothing is recorded.
    function test_sessionPair_lockTooLateIsJudgedAgainstTheSessionWindow() public {
        _refresh(aaplPair, AAPL_USD_FEED_ID, AAPL_USD);
        _depositAndRequestAapl(carol);
        (,,,, uint256 windowEndTs) = lens.getInsuranceWithdrawalLock(address(aaplPair), carol);
        _liveAt(aaplPair, AAPL_USD_FEED_ID, AAPL_USD, windowEndTs - CLAIM_DELAY + 1);

        _expectRedemptionRevert(
            aaplPair,
            carol,
            _aaplNow(),
            abi.encodeWithSelector(
                InsuranceVaultLib.InsuranceVaultLib__LockTooLate.selector, windowEndTs + 1, windowEndTs
            )
        );
        (bool isLocked,,,,) = lens.getInsuranceWithdrawalLock(address(aaplPair), carol);
        assertFalse(isLocked, "nothing was recorded");
    }

    // ---------------------------------------------------------------- closures

    /// @notice The four days hold a long weekend. Carol's AAPL window opens as the venue shuts for
    ///         a holiday next to a weekend, 89.5 hours from a Thursday close to a Monday open, and
    ///         nothing is stored in between. At the reopen her first call carries the print that
    ///         ends the closure and locks; its claim opens a reopen delay later, still inside the
    ///         window, and pays. A window of the BTC pair's length would have closed before the
    ///         venue reopened.
    function test_sessionPair_windowOpeningAtALongWeekendPaysAtTheReopen() public {
        _refresh(aaplPair, AAPL_USD_FEED_ID, AAPL_USD);
        uint256 requestTs = vm.getBlockTimestamp();
        _depositAndRequestAapl(carol);
        uint256 shares = aaplPair.insuranceShares(carol);
        uint256 requested = aaplPair.insuranceWithdrawalRequestShareAmount(carol);

        // The session's last prints land as the window opens; the venue then stays shut.
        uint256 windowOpensTs = requestTs + COOLDOWN;
        _liveAt(aaplPair, AAPL_USD_FEED_ID, AAPL_USD, windowOpensTs);
        uint256 reopenTs = windowOpensTs + 89 hours + 30 minutes;
        assertGt(
            reopenTs,
            windowOpensTs + InsuranceVaultLib.INSURANCE_WITHDRAWAL_WINDOW_CONTINUOUS,
            "fixture: a 24/7 pair's window would be shut by the reopen"
        );

        vm.warp(reopenTs);
        _executeRedemption(aaplPair, carol, _aaplNow());
        (bool isLocked,,, uint256 opensTs, uint256 windowEndTs) =
            lens.getInsuranceWithdrawalLock(address(aaplPair), carol);
        assertTrue(isLocked, "the reopen print locks the matured request");
        assertEq(opensTs, reopenTs + REOPEN_DELAY, "the claim opens a reopen delay after the print");
        assertLe(opensTs, windowEndTs, "inside the window");

        vm.warp(opensTs);
        uint256 before = usdc.balanceOf(carol);
        _executeRedemption(aaplPair, carol, _aaplNow());
        assertGt(usdc.balanceOf(carol), before, "paid on the reopened session");
        assertEq(aaplPair.insuranceShares(carol), shares - requested, "requested shares burned");
    }
}
