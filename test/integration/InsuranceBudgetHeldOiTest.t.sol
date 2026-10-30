// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";

/// @title InsuranceBudgetHeldOiTest
/// @notice Above target, the insurance withdrawal budget's open-interest term counts only open
///         interest the pair has held for the whole trailing day. Open interest counts matched
///         positions of one owner, so a budget sized on an instant's reading could be set by
///         positions opened for the withdrawal that rolls the period and closed before the paying
///         call that spends it. Sized on the held figure, only positions carried for a day widen
///         it, while the coverage ratio that picks the regime keeps reading live open interest.
contract InsuranceBudgetHeldOiTest is IntegrationBase {
    uint256 constant MARK_USD = 50_000;
    uint256 constant MARK = MARK_USD * BAZAAR_SCALE;
    uint256 constant HONEST = 20 * BAZAAR_SCALE; // open interest per side held all day
    uint256 constant SMALL_WASH = 2 * BAZAAR_SCALE; // one owner's matched long and short, with the fund still above target
    uint256 constant BIG_WASH = 100 * BAZAAR_SCALE; // one owner's matched long and short, five times the book
    uint256 constant FUND_A = 30_000 * BAZAAR_SCALE;
    uint256 constant FUND_B = 10_000 * BAZAAR_SCALE;

    // BazaarPair storage slot of the withdrawal rate-limit state, from `forge inspect BazaarPair
    // storage-layout`: +0 is what the period has paid out, +2 the period's OI snapshot term.
    uint256 constant SLOT_INSURANCE_RATE_LIMIT = 57;

    address lpA = makeAddr("lpA");
    address lpB = makeAddr("lpB");

    // ---------------------------- fixture ----------------------------

    function _trailingOi() internal view returns (uint256 t) {
        (,,,,,,,,,,,,,,,, t) = pair.pairVault();
    }

    function _spentSlot() internal view returns (uint256) {
        return uint256(vm.load(address(pair), bytes32(SLOT_INSURANCE_RATE_LIMIT)));
    }

    function _periodCapSlot() internal view returns (uint256) {
        return uint256(vm.load(address(pair), bytes32(SLOT_INSURANCE_RATE_LIMIT + 2)));
    }

    /// @dev INSURANCE_WITHDRAWAL_ABOVE_TARGET_RATE_LIMIT_BP (1%) of `oiSize` at the mark.
    function _aboveTargetOiCap(uint256 oiSize) internal pure returns (uint256) {
        return Math.mulDiv(oiSize, MARK, BAZAAR_SCALE)
            * InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_RATE_LIMIT_BP / 10_000;
    }

    /// @dev The budget an execution at the mark is checked against, as the lens reports it.
    function _budget() internal view returns (uint256 remaining, uint256 cap, uint256 coverageBp, uint256 targetBp) {
        (remaining, cap,, coverageBp, targetBp) = lens.getInsuranceWithdrawalBudget(address(pair), MARK);
    }

    /// @dev Shares that redeem for `amount` at the mark, rounded down.
    function _sharesWorth(uint256 amount) internal view returns (uint256) {
        uint256 total = pair.totalInsuranceShares();
        return Math.mulDiv(amount, total, lens.quoteInsuranceWithdrawal(address(pair), total, MARK));
    }

    /// @dev What `user`'s paying call would send now: the lower of the locked amount and the
    ///      requested shares' value at the mark.
    function _claimValue(address user) internal view returns (uint256 value) {
        value = lens.quoteInsuranceWithdrawal(address(pair), pair.insuranceWithdrawalRequestShareAmount(user), MARK);
        (, uint256 locked,,,) = lens.getInsuranceWithdrawalLock(address(pair), user);
        if (locked < value) value = locked;
    }

    /// @dev Sized before the prank: the quote's external calls would consume it.
    function _requestWorth(address user, uint256 amount) internal {
        uint256 shares = _sharesWorth(amount);
        vm.prank(user);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
    }

    /// @dev `user`'s paying call at the mark, expected to revert with `selector`.
    function _claimExpect(address user, bytes4 selector) internal {
        bytes[] memory pu = _priceAt(MARK_USD);
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(user, fee);
        vm.prank(user);
        vm.expectRevert(selector);
        pair.executeInsuranceWithdrawal{value: fee}(pu, 0, 0, 0, "", "");
    }

    /// @dev Store a fresh mark `after_` seconds on, which also advances the sample ring.
    function _refreshAfter(uint256 after_) internal {
        vm.warp(vm.getBlockTimestamp() + after_);
        bytes[] memory pu = _priceAt(MARK_USD);
        vm.prank(seq);
        pair.refreshPrice(pu);
    }

    function _refreshHourly(uint256 hours_) internal {
        for (uint256 i = 0; i < hours_; i++) {
            _refreshAfter(1 hours);
        }
    }

    /// @dev `long_` and `short_` cross `size` at the mark.
    function _cross(address long_, address short_, uint256 size) internal {
        _placeLimitAt(long_, true, size, MARK, MARK_USD);
        _roll(2);
        _placeLimitAt(short_, false, size, MARK, MARK_USD);
    }

    /// @dev carol and dave, standing in for one owner's two accounts, cross `size` at the mark.
    function _openMatched(uint256 size) internal {
        uint256 collateral = size * MARK_USD;
        usdc.mint(carol, collateral * USDC_SCALE / BAZAAR_SCALE);
        usdc.mint(dave, collateral * USDC_SCALE / BAZAAR_SCALE);
        _deposit(carol, collateral);
        _deposit(dave, collateral);
        _cross(carol, dave, size);
        assertEq(_posSize(dave), size, "fixture: the matched positions are open");
    }

    /// @dev The matched positions close against each other.
    function _closeMatched(uint256 size) internal {
        _cross(dave, carol, size);
        assertEq(_posSize(carol), 0, "fixture: the matched positions are closed");
        assertEq(_posSize(dave), 0, "fixture: on both accounts");
    }

    /// @dev lpA and lpB fund the pool and request redemptions worth `worthA` and `worthB` at the
    ///      mark (a zero requests nothing); alice and bob then hold HONEST per side at the mark
    ///      through a day of hourly refreshes, so it is the trailing figure; the chain is left at
    ///      the requests' windows.
    function _honestDayWithRequests(uint256 worthA, uint256 worthB) internal {
        usdc.mint(lpA, FUND_A * USDC_SCALE / BAZAAR_SCALE);
        usdc.mint(lpB, FUND_B * USDC_SCALE / BAZAAR_SCALE);
        _depositInsurance(lpA, FUND_A);
        _depositInsurance(lpB, FUND_B);
        uint256 requestTs = vm.getBlockTimestamp();
        if (worthA != 0) _requestWorth(lpA, worthA);
        if (worthB != 0) _requestWorth(lpB, worthB);

        _deposit(alice, 300_000 * BAZAAR_SCALE);
        _deposit(bob, 300_000 * BAZAAR_SCALE);
        _cross(alice, bob, HONEST);
        _refreshHourly(26);
        assertEq(_trailingOi(), HONEST, "fixture: a day of history at the honest open interest");

        vm.warp(requestTs + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);
    }

    /// @dev `user` locks its redemption at the mark, and the chain moves to its paying call.
    function _lock(address user) internal {
        _executeRedemption(pair, user, _priceAt(MARK_USD));
        _warpToRedemptionClaim(pair, user);
    }

    // ---------------------------- tests ----------------------------

    /// @notice Matched positions opened on top of the day-old book leave the above-target budget
    ///         on the open interest held all day, and the lens reports the budget execution
    ///         enforces: a claim that fits 1% of live open interest but not 1% of the held figure
    ///         is refused, and one inside the held figure pays.
    function test_aboveTarget_budgetReadsTheHeldOpenInterest_lensAgrees() public {
        _honestDayWithRequests(10_300 * BAZAAR_SCALE, 9_000 * BAZAAR_SCALE);
        _lock(lpA);
        _lock(lpB);
        _openMatched(SMALL_WASH);
        assertEq(_trailingOi(), HONEST, "the matched positions are not in the trailing figure");

        (uint256 remaining, uint256 cap, uint256 coverageBp, uint256 targetBp) = _budget();
        assertGe(coverageBp, targetBp, "fixture: the fund reads above target with the matched positions open");
        uint256 heldCap = _aboveTargetOiCap(HONEST);
        uint256 fundFloor = _insuranceBal() * InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_FUND_CAP_BP / 10_000;
        assertGt(heldCap, fundFloor, "fixture: the OI term is the binding one");
        assertEq(cap, heldCap, "the budget is 1% of the open interest held all day");
        assertLt(cap, _aboveTargetOiCap(HONEST + SMALL_WASH), "not of live open interest");

        uint256 claimA = _claimValue(lpA);
        assertGt(claimA, remaining, "lens: lpA's claim does not fit the held budget");
        assertLe(claimA, _aboveTargetOiCap(HONEST + SMALL_WASH), "though it would fit a budget on live open interest");
        _claimExpect(lpA, InsuranceVaultLib.InsuranceVaultLib__RateLimitExceeded.selector);

        uint256 claimB = _claimValue(lpB);
        assertLe(claimB, remaining, "lens: lpB's claim fits");
        _executeRedemption(pair, lpB, _priceAt(MARK_USD));
        assertEq(_spentSlot(), claimB, "the period books what lpB was paid");
    }

    /// @notice The audit's route: matched positions five times the book are open while a dust
    ///         redemption rolls the period, so the snapshot holds the inflated figure, and they
    ///         are closed before the large redemption. The large claim is still judged on the
    ///         open interest held all day.
    function test_matchedPositionsAtThePeriodOpen_closedBeforeTheClaim_widenNothing() public {
        _honestDayWithRequests(20_000 * BAZAAR_SCALE, 10 * BAZAAR_SCALE);
        _lock(lpA);
        _lock(lpB);

        _openMatched(BIG_WASH);
        _executeRedemption(pair, lpB, _priceAt(MARK_USD));
        uint256 inflatedSnapshot = Math.mulDiv(HONEST + BIG_WASH, MARK, BAZAAR_SCALE)
            * InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_BP / 10_000;
        assertEq(_periodCapSlot(), inflatedSnapshot, "the dust claim opened the period on the inflated reading");
        assertGt(_spentSlot(), 0, "and was paid");
        _closeMatched(BIG_WASH);
        assertEq(_trailingOi(), HONEST, "the trailing figure never saw them");

        (uint256 remaining, uint256 cap, uint256 coverageBp, uint256 targetBp) = _budget();
        assertGe(coverageBp, targetBp, "the fund reads above target again");
        uint256 heldCap = _aboveTargetOiCap(HONEST);
        uint256 fundFloor = _insuranceBal() * InsuranceVaultLib.INSURANCE_WITHDRAWAL_ABOVE_TARGET_FUND_CAP_BP / 10_000;
        assertEq(cap, heldCap > fundFloor ? heldCap : fundFloor, "the budget is on the held figure");
        assertLt(cap, 2 * inflatedSnapshot, "not on the snapshot");

        assertGt(_claimValue(lpA), remaining, "lens: the large claim does not fit");
        _claimExpect(lpA, InsuranceVaultLib.InsuranceVaultLib__RateLimitExceeded.selector);
    }

    /// @notice Matched positions held through the paying call do not help either: the coverage
    ///         ratio reads live open interest, so they push the fund below target, where the
    ///         budget is the stricter of the snapshot and 5% of the fund.
    function test_matchedPositionsHeldThroughTheClaim_readBelowTarget() public {
        _honestDayWithRequests(20_000 * BAZAAR_SCALE, 0);
        _lock(lpA);
        _openMatched(BIG_WASH);

        (uint256 remaining, uint256 cap, uint256 coverageBp, uint256 targetBp) = _budget();
        assertLt(coverageBp, targetBp, "the matched positions carry the fund below target");
        assertEq(
            cap,
            _insuranceBal() * InsuranceVaultLib.INSURANCE_WITHDRAWAL_BELOW_TARGET_FUND_CAP_BP / 10_000,
            "5% of the fund"
        );
        assertGt(_claimValue(lpA), remaining, "lens: the claim does not fit");
        _claimExpect(lpA, InsuranceVaultLib.InsuranceVaultLib__RateLimitExceeded.selector);
    }

    /// @notice Open interest that is held does widen the budget, a full day later: once every
    ///         hourly sample in the window carries the matched positions, the held figure does too,
    ///         and the claim the day-old figure refused pays.
    function test_openInterestHeldForADay_widensTheBudget() public {
        _honestDayWithRequests(10_300 * BAZAAR_SCALE, 0);
        _lock(lpA);
        _openMatched(SMALL_WASH);
        (, uint256 capBefore,,) = _budget();
        assertEq(capBefore, _aboveTargetOiCap(HONEST), "the matched positions are not yet held");
        assertGt(_claimValue(lpA), capBefore, "fixture: the claim does not fit the day-old figure");

        _refreshHourly(26);
        assertEq(_trailingOi(), HONEST + SMALL_WASH, "every sample in the window now carries them");
        (uint256 remaining, uint256 cap,,) = _budget();
        assertEq(cap, _aboveTargetOiCap(HONEST + SMALL_WASH), "and the budget is 1% of the larger figure");
        uint256 claim = _claimValue(lpA);
        assertLe(claim, remaining, "lens: the claim now fits");
        _warpToRedemptionClaim(pair, lpA);
        _executeRedemption(pair, lpA, _priceAt(MARK_USD));
        assertEq(_spentSlot(), claim, "and pays");
    }
}
