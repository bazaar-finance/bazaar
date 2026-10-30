// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";

/// @title InsuranceWithdrawalBudgetTest
/// @notice BazaarPairLens.getInsuranceWithdrawalBudget must report the budget execution enforces.
///         Every prediction here is checked against executeInsuranceWithdrawal's paying call in
///         the same rate-limit period, and the storage slots the lens reads through `extsload`
///         are pinned against the contract's own behaviour: a layout change that moved any of
///         them fails these tests rather than silently feeding the view the wrong words.
contract InsuranceWithdrawalBudgetTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 internal constant P = 50_000 * BAZAAR_SCALE;

    // BazaarPair storage slots, from `forge inspect BazaarPair storage-layout`. The tests below
    // write and read through these directly, so a stale value fails an absolute assertion.
    uint256 internal constant SLOT_LIQUIDATION_GAP_EMA = 43;
    uint256 internal constant SLOT_INSURANCE_RATE_LIMIT = 57;
    uint256 internal constant SLOT_REOPEN_GAP_EMA = 105;

    // ------------------------------------------------------------------ helpers

    /// @dev Open a 1v1 BTC position (alice long / bob short at $50k) so the pair has live OI.
    function _openOI() internal {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, 1 * BAZAAR_SCALE, 50_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, 1 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), 1 * BAZAAR_SCALE, "OI opened");
    }

    function _budget()
        internal
        view
        returns (uint256 remaining, uint256 cap, uint256 resetsAt, uint256 coverageBp, uint256 targetBp)
    {
        return lens.getInsuranceWithdrawalBudget(address(pair), P);
    }

    /// @dev Shares that redeem for `amount` at P, rounded down.
    function _sharesWorth(uint256 amount) internal view returns (uint256) {
        uint256 total = pair.totalInsuranceShares();
        return Math.mulDiv(amount, total, lens.quoteInsuranceWithdrawal(address(pair), total, P));
    }

    /// @dev What `user`'s pending request redeems for at P.
    function _requestQuote(address user) internal view returns (uint256) {
        return lens.quoteInsuranceWithdrawal(address(pair), pair.insuranceWithdrawalRequestShareAmount(user), P);
    }

    function _requestShares(address user, uint256 shares) internal {
        vm.prank(user);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
    }

    /// @dev A full live-pair redemption at the $50k mark: the lock, then the paying call once it
    ///      opens.
    function _execute(address user) internal {
        _redeemAt(user, 50_000);
    }

    /// @dev Locks `user`'s redemption and expects its paying call, the only one the rate limit
    ///      reads, to revert with `selector`.
    function _claimExpect(address user, bytes4 selector) internal {
        _executeRedemption(pair, user, _freshPrice());
        _warpToRedemptionClaim(pair, user);
        bytes[] memory pu = _freshPrice();
        vm.prank(user);
        vm.expectRevert(selector);
        pair.executeInsuranceWithdrawal(pu, 0, 0, 0, "", "");
    }

    function _spentSlot() internal view returns (uint256) {
        return uint256(vm.load(address(pair), bytes32(SLOT_INSURANCE_RATE_LIMIT)));
    }

    // ------------------------------------------------------------------ budget vs execution

    /// @notice Above target: what the lens says fits, executes; what it says does not, reverts.
    ///         Carol's withdrawal lands inside the reported budget and is booked into the period
    ///         at exactly the amount the lens quoted; the lens then reads that spend back from
    ///         the live slot, and Dave's request, which it reports as over the remainder, is
    ///         rejected by his paying call in the same period.
    function test_budget_predictsExecution_aboveTarget() public {
        _openOI();
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        _depositInsurance(dave, 30_000 * BAZAAR_SCALE);
        (, uint256 cap0,, uint256 coverage0, uint256 target0) = _budget();
        assertGe(coverage0, target0, "fixture sits above target");

        _requestShares(carol, _sharesWorth(cap0 * 6 / 10));
        _requestShares(dave, _sharesWorth(cap0 * 6 / 10));
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);

        (uint256 remaining,,,,) = _budget();
        uint256 carolPaid = _requestQuote(carol);
        assertLe(carolPaid, remaining, "lens: carol fits");
        _execute(carol);
        assertEq(_spentSlot(), carolPaid, "the period books exactly what carol was paid");

        (uint256 remainingAfter, uint256 capAfter,,,) = _budget();
        assertEq(capAfter - remainingAfter, carolPaid, "lens reads the spend back from the live slot");
        assertGt(_requestQuote(dave), remainingAfter, "lens: dave does not fit");
        _claimExpect(dave, InsuranceVaultLib.InsuranceVaultLib__RateLimitExceeded.selector);
    }

    /// @notice Below target the stricter regime sets the cap, and the lens both selects it and
    ///         predicts the rejection that follows.
    function test_budget_predictsExecution_belowTarget() public {
        _openOI();
        _depositInsurance(carol, 6_000 * BAZAAR_SCALE);
        _requestShares(carol, pair.insuranceShares(carol));
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);
        // Crush the fund to $900 on $50k of OI: 1.8% coverage, under the 2% floor target.
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(900 * BAZAAR_SCALE);

        (uint256 remaining, uint256 cap,, uint256 coverage, uint256 target) = _budget();
        assertLt(coverage, target, "fixture sits below target");

        (uint256 longOI,,,,,,,,,,,,,,,,) = pair.pairVault();
        uint256 oiTerm = Math.mulDiv(longOI, P, BAZAAR_SCALE) * 50 / 10_000; // 0.5% of OI notional
        uint256 fundTerm = 900 * BAZAAR_SCALE * 500 / 10_000; // 5% of the fund
        assertEq(cap, oiTerm < fundTerm ? oiTerm : fundTerm, "below target: the stricter of the two terms");

        assertGt(_requestQuote(carol), remaining, "lens: the exit does not fit");
        _claimExpect(carol, InsuranceVaultLib.InsuranceVaultLib__RateLimitExceeded.selector);
    }

    /// @notice The pair only rolls a lapsed period when a withdrawal lands in it, so its storage
    ///         goes on describing an expired period. The lens reports the fresh one the next
    ///         withdrawal would actually open.
    function test_budget_lapsedPeriodReportsTheFreshWindow() public {
        _openOI();
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        (, uint256 cap0,,,) = _budget();
        _requestShares(carol, _sharesWorth(cap0 / 2));
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);
        _execute(carol);
        uint256 spent = _spentSlot();
        assertGt(spent, 0, "a withdrawal was booked");

        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD);
        (uint256 remaining, uint256 cap, uint256 resetsAt,,) = _budget();
        assertEq(remaining, cap, "a lapsed period reads as nothing spent");
        assertEq(
            resetsAt,
            vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD,
            "the fresh period runs from now"
        );
        assertEq(_spentSlot(), spent, "while storage still holds the expired period");
    }

    /// @notice With no open interest execution applies no rate limit, and the lens says so.
    function test_budget_noOpenInterestIsUnlimited() public view {
        (uint256 remaining, uint256 cap, uint256 resetsAt,,) = _budget();
        assertEq(remaining, type(uint256).max, "remaining unlimited");
        assertEq(cap, type(uint256).max, "cap unlimited");
        assertEq(resetsAt, type(uint256).max, "no period to reset");
    }

    // ------------------------------------------------------------------ live target vs contract

    /// @dev Price-jump stamp written into the top bits of the reopen slot alongside the seeded gap.
    uint256 internal seededJumpTs;

    /// @dev Seed the stored risk estimators on the AAPL pair (a session pair, so the reopen floor
    ///      is consumed) and have the pair recompute its cached target from them. The refresh sits
    ///      10 minutes after the previous stored price — under both the 1h reopen threshold and
    ///      the 12h fade-suspension threshold — so neither rewrites what was seeded. The slippage
    ///      anchor 3 days back halves that leg exactly, and the drift anchor a day back takes a
    ///      quarter off the drift leg.
    function _seedAaplRiskAndRefresh(uint256 slippageBp, uint256 driftBp, uint256 reopenBp)
        internal
        returns (uint256 cachedTarget, uint256 lensTarget)
    {
        // Put the chain well past the 3-day anchor offset before anything is seeded.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        aaplPair.refreshPrice(_priceUpdateFor(AAPL_USD_FEED_ID, 150, uint64(vm.getBlockTimestamp())));
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256 nowTs = vm.getBlockTimestamp();

        // Both lines in RiskParamsLib.GAP_EMA_SCALE units per bp; their anchors and the batch
        // clock share one word, 64 bits each from the low end. Each of the three is distinct, so
        // a lens reading an anchor from the wrong 64 bits lands on a different target.
        uint256 scale = RiskParamsLib.GAP_EMA_SCALE;
        vm.store(address(aaplPair), bytes32(SLOT_LIQUIDATION_GAP_EMA), bytes32(slippageBp * scale));
        vm.store(address(aaplPair), bytes32(SLOT_LIQUIDATION_GAP_EMA + 1), bytes32(driftBp * scale));
        vm.store(
            address(aaplPair),
            bytes32(SLOT_LIQUIDATION_GAP_EMA + 2),
            bytes32((nowTs - 3 days) | ((nowTs - 1 days) << 64) | ((nowTs - 2 hours) << 128))
        );
        vm.store(address(aaplPair), bytes32(SLOT_REOPEN_GAP_EMA), bytes32((seededJumpTs << 192) | (reopenBp << 64)));
        aaplPair.refreshPrice(_priceUpdateFor(AAPL_USD_FEED_ID, 150, uint64(nowTs)));

        (,,,,,,,,,,,, cachedTarget,,,,) = aaplPair.pairVault();
        (,,,, lensTarget) = lens.getInsuranceWithdrawalBudget(address(aaplPair), 150 * BAZAAR_SCALE);
    }

    /// @notice The forecast leg wins, so the target turns on the slippage and reopen slots: the
    ///         stress move is max(vol 3%, reopen 5%) + faded slippage 2% = 7%. A lens reading
    ///         either slot from the wrong word would land on 5%.
    function test_liveTarget_forecastLeg_matchesContract() public {
        (uint256 cachedTarget, uint256 lensTarget) = _seedAaplRiskAndRefresh(400, 0, 500);
        assertEq(cachedTarget, 700, "the pair reads the seeded estimators as intended");
        assertEq(lensTarget, cachedTarget, "the lens rebuilds the same target");
    }

    /// @notice The reopen slot also carries the last price jump's timestamp in its top bits. The
    ///         same forecast case with a jump stamped there must give the same 7%: a lens that
    ///         read the gap without masking the stamp off would land far above it.
    function test_liveTarget_ignoresThePriceJumpStampInTheReopenSlot() public {
        seededJumpTs = vm.getBlockTimestamp();
        (uint256 cachedTarget, uint256 lensTarget) = _seedAaplRiskAndRefresh(400, 0, 500);
        assertEq(cachedTarget, 700, "the pair reads the gap without the jump stamp above it");
        assertEq(lensTarget, cachedTarget, "and so does the lens");
    }

    /// @notice The drift leg wins, so the target turns on the drift slot and its anchor: drift of
    ///         12% a day old fades to 9% and beats the 7% forecast. A lens missing the drift would
    ///         land on 7%; one missing the anchor would skip the fade and saturate at the 10%
    ///         ceiling, and one swapping the two anchors would land on 8%.
    function test_liveTarget_driftLeg_matchesContract() public {
        (uint256 cachedTarget, uint256 lensTarget) = _seedAaplRiskAndRefresh(400, 1_200, 500);
        assertEq(cachedTarget, 900, "the pair reads the seeded estimators as intended");
        assertEq(lensTarget, cachedTarget, "the lens rebuilds the same target");
    }
}
