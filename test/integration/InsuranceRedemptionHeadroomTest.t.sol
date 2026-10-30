// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";
import {RiskParamsLib} from "../../src/libraries/RiskParamsLib.sol";

/// @title InsuranceRedemptionHeadroomTest
/// @notice While the vault holds inventory, a live-pair redemption pays no more than the fund's
///         headroom: free capital less the reserve and the cost of finishing the inventory, valued
///         together at whichever edge of the unload band makes their sum larger. Paid past it, a
///         payout would
///         take part of the reserve, or leave the fund where a refresh bounty or a move of the mark
///         inside the band opens an ADL window. A larger claim is paid up to the headroom at its
///         own amount per share, and the rest of the request stays open under the same lock for a
///         later call in the window; a claim the headroom cannot pay any of is refused. The lock,
///         which pays nothing, never is.
contract InsuranceRedemptionHeadroomTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 constant MARK_USD = 50_000;
    uint256 constant MARK = MARK_USD * BAZAAR_SCALE;

    uint256 carolShares; // 40% of the supply in most tests: twice the headroom the fixture leaves
    uint256 daveShares; // 10% of the supply: worth half of it

    /// @dev Where the fixture leaves the one-unit inventory against the unload band:
    ///      - AtLoss: under water at the mark, and further at the band's edge against the vault;
    ///      - ClearOfTheBand: above water by the band's move, so finishing it costs nothing even at
    ///        that edge;
    ///      - InsideTheBand: whole at the mark and under water at that edge.
    enum Stage {
        AtLoss,
        ClearOfTheBand,
        InsideTheBand
    }

    // ---------------------------- fixture ----------------------------

    /// @dev Free capital, the reserve and the inventory's net position, all at the stored mark and
    ///      the live funding index: the figures the ADL gate's opening test compares.
    function _fundAtMark() internal view returns (uint256 free, uint256 reserve, int256 net) {
        (uint256 spot,,,,) = pair.lastPairPrice();
        (free, reserve, net) = _fundAt(spot);
    }

    /// @dev The same figures with the inventory valued at `price`; the reserve stays at the stored
    ///      mark.
    function _fundAt(uint256 price) internal view returns (uint256 free, uint256 reserve, int256 net) {
        (
            ,,,,,
            uint256 fund,
            uint256 size,
            uint256 entryNotional,,
            int256 entryFundingIndex,
            bool isLong,,,
            uint256 seized,
            uint256 arrears,,
        ) = pair.pairVault();
        (uint256 spot,,,,) = pair.lastPairPrice();
        free = fund - seized;
        reserve = _reserveAt(spot);
        net = int256(seized + arrears)
            + RiskParamsLib.inventoryPnl(
                size, entryNotional, entryFundingIndex, isLong, price, pair.currentFundingIndex()
            );
    }

    /// @dev The reserve valued at `price`, as RiskParamsLib.adlReserve sizes it: ADL_RESERVE_BP of
    ///      the cached target on the lower of per-side open interest and its trailing minimum.
    function _reserveAt(uint256 price) internal view returns (uint256) {
        (
            uint256 longOI,
            uint256 shortOI,,,,,
            uint256 size,,,,
            bool isLong,,
            uint256 targetBp,,,,
            uint128 trailingOiSize
        ) = pair.pairVault();
        uint256 oiSize = RiskParamsLib.reserveOiSizeOf(
            RiskParamsLib.openInterestSizeOf(longOI, shortOI, size, isLong), trailingOiSize
        );
        return RiskParamsLib.adlReserveOf(oiSize, price, targetBp);
    }

    function _inventoryIsLong() internal view returns (bool isLong) {
        (,,,,,,,,,, isLong,,,,,,) = pair.pairVault();
    }

    /// @dev The maintenance rate the payout cap derives its unload band from: the stored rate.
    function _bandMmrBp() internal view returns (uint256 mmrBp) {
        (, mmrBp,,) = pair.marginRequirements();
    }

    /// @dev The band's width either side of the stored mark: the stored rate, capped at
    ///      LIQ_MAX_SLIPPAGE_BP.
    function _bandBp() internal view returns (uint256 bandBp) {
        bandBp = _bandMmrBp();
        if (bandBp > BazaarTypes.LIQ_MAX_SLIPPAGE_BP) bandBp = BazaarTypes.LIQ_MAX_SLIPPAGE_BP;
    }

    /// @dev The band's lower edge, where the payout cap finishes an inventory of longs.
    function _lowerEdge() internal view returns (uint256) {
        (uint256 spot,,,,) = pair.lastPairPrice();
        return spot * (10_000 - _bandBp()) / 10_000;
    }

    /// @dev The band's upper edge, where the payout cap values the reserve and finishes an
    ///      inventory of shorts.
    function _upperEdge() internal view returns (uint256) {
        (uint256 spot,,,,) = pair.lastPairPrice();
        return spot * (10_000 + _bandBp()) / 10_000;
    }

    /// @dev What finishing the inventory at the band's edge against the vault would cost: its loss
    ///      there, 0 when it is above water even at that edge.
    function _finish() internal view returns (uint256) {
        (,, int256 netAtEdge) = _fundAt(_inventoryIsLong() ? _lowerEdge() : _upperEdge());
        return netAtEdge < 0 ? uint256(-netAtEdge) : 0;
    }

    /// @dev What the payout cap holds back at `edge`: the reserve and the inventory's loss, both
    ///      valued there.
    function _heldAt(uint256 edge) internal view returns (uint256) {
        (,, int256 netAtEdge) = _fundAt(edge);
        return _reserveAt(edge) + (netAtEdge < 0 ? uint256(-netAtEdge) : 0);
    }

    /// @dev What the payout cap holds back: the larger of the two edge sums.
    function _held() internal view returns (uint256) {
        uint256 atLower = _heldAt(_lowerEdge());
        uint256 atUpper = _heldAt(_upperEdge());
        return atLower > atUpper ? atLower : atUpper;
    }

    /// @dev What the fund can still pay out before free capital falls below what the cap holds back.
    ///      Negative once it has.
    function _headroom() internal view returns (int256) {
        (uint256 free,,) = _fundAtMark();
        return int256(free) - int256(_held());
    }

    /// @dev Store a fresh mark at `priceUsd` as the keeper, which also runs the health check.
    function _refreshAt(uint256 priceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + 30);
        bytes[] memory pu = _priceAt(priceUsd);
        vm.prank(seq);
        pair.refreshPrice(pu);
    }

    /// @dev Restage the vault's one-unit inventory, long or short, with `seized` collateral behind
    ///      it and a net position of `net` at the stored mark, running no health check.
    function _restage(bool isShort, uint256 seized, int256 net) internal {
        int256 index = pair.currentFundingIndex();
        if (!isShort) {
            // One unit long: net = seized + mark - entry - funding index.
            _stageHeldInventory(uint256(int256(MARK + seized) - index - net), seized);
            return;
        }
        // One unit short: net = seized + entry - mark + funding index. The estates went bankrupt
        // the seizure above their entry.
        uint256 entry = uint256(net - int256(seized) + int256(MARK) - index);
        _stdstore.target(address(pair)).sig("pairVault()").depth(6).checked_write(BAZAAR_SCALE);
        _stdstore.target(address(pair)).sig("pairVault()").depth(7).checked_write(entry);
        _stdstore.target(address(pair)).sig("pairVault()").depth(8).checked_write(entry + seized);
        _stdstore.target(address(pair)).sig("pairVault()").depth(10).checked_write(false);
        _stdstore.target(address(pair)).sig("pairVault()").depth(13).checked_write(seized);
    }

    /// @dev Leave the vault holding one unit, long or short, at `stage` with a headroom set so
    ///      carol's 40% claim is worth twice it and dave's 10% half of it. The refresh runs on a
    ///      whole inventory first, so the reserve is the one the pair's live target gives; the
    ///      figures are staged after it, with no health check since.
    function _stageHeadroom(Stage stage, bool isShort) internal returns (uint256 headroom) {
        uint256 seized = _insuranceBal() / 2;
        _restage(isShort, seized, 0);
        _refreshAt(MARK_USD);
        assertFalse(pair.isAdlPending(), "fixture: a whole inventory opens no window");
        assertGe(_bandMmrBp(), BazaarTypes.LIQ_MAX_SLIPPAGE_BP, "fixture: the band sits at its cap");

        (uint256 free, uint256 reserve,) = _fundAtMark();
        assertGt(reserve, 0, "fixture: a reserve exists");
        (uint256 spot,,,,) = pair.lastPairPrice();
        uint256 band = spot - _lowerEdge();
        assertEq(_upperEdge() - spot, band, "fixture: the band is as wide either side");
        // The edge whose sum decides: the upper one for shorts, whose reserve and loss rise
        // together, and for an inventory clear of the band, whose loss is nil at both edges; the
        // lower one for longs under water there, the fixture's reserve being far below the
        // inventory, so the loss the band adds outweighs what it adds to the reserve.
        bool upperDecides = isShort || stage == Stage.ClearOfTheBand;
        uint256 reserveAtEdge = _reserveAt(upperDecides ? _upperEdge() : _lowerEdge());
        // The redemption basis is free capital less the loss at the mark: the deciding edge's
        // reserve plus the headroom plus the band's move wherever the inventory is under water at
        // that edge, that reserve plus the headroom where it is clear of the band. A quarter of
        // the rest makes the basis five headrooms.
        headroom = (stage == Stage.ClearOfTheBand ? reserveAtEdge : reserveAtEdge + band) / 4;
        if (stage == Stage.AtLoss) {
            // The loss at the deciding edge is the loss at the mark plus the band's move.
            _restage(isShort, seized, -int256(free - reserveAtEdge - headroom - band));
        } else if (stage == Stage.ClearOfTheBand) {
            _restage(isShort, free + seized - reserveAtEdge - headroom, int256(band));
        } else {
            _restage(isShort, free + seized - reserveAtEdge - headroom - band, 0);
        }
        uint256 atLower = _heldAt(_lowerEdge());
        uint256 atUpper = _heldAt(_upperEdge());
        assertTrue(upperDecides ? atUpper >= atLower : atLower > atUpper, "fixture: the intended edge decides");
        assertEq(_headroom(), int256(headroom), "fixture: the staged figures leave the intended headroom");
    }

    function _stageHeadroom(Stage stage) internal returns (uint256) {
        return _stageHeadroom(stage, false);
    }

    /// @dev carol and dave fund the pool and file their requests, the cooldown passes, and both
    ///      lock with the headroom already staged. Then the paying calls open and the headroom is
    ///      staged again against the reserve in force at that moment.
    function _lockBothThenOpenClaims(Stage stage, bool isShort) internal returns (uint256 headroom) {
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        _depositInsurance(dave, 10_000 * BAZAAR_SCALE);
        uint256 supply = pair.totalInsuranceShares();
        carolShares = supply * 40 / 100;
        daveShares = supply * 10 / 100;
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(carolShares, 0, 0, 0, "", "");
        vm.prank(dave);
        pair.requestInsuranceWithdrawal(daveShares, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);

        _stageHeadroom(stage, isShort);
        _executeRedemption(pair, carol, _priceAt(MARK_USD));
        _executeRedemption(pair, dave, _priceAt(MARK_USD));
        (bool carolLocked,,,,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertTrue(carolLocked, "a lock pays nothing, so the headroom does not hold it back");

        _warpToRedemptionClaim(pair, carol);
        _warpToRedemptionClaim(pair, dave);
        headroom = _stageHeadroom(stage, isShort);
    }

    function _lockBothThenOpenClaims(Stage stage) internal returns (uint256) {
        return _lockBothThenOpenClaims(stage, false);
    }

    /// @dev What `user`'s paying call would claim now: the lower of the locked amount and the
    ///      requested shares' value at the stored mark.
    function _claimValue(address user, uint256 shares) internal view returns (uint256 value) {
        (uint256 spot,,,,) = pair.lastPairPrice();
        value = lens.quoteInsuranceWithdrawal(address(pair), shares, spot);
        (, uint256 locked,,,) = lens.getInsuranceWithdrawalLock(address(pair), user);
        if (locked < value) value = locked;
    }

    function _budgetRemaining() internal view returns (uint256 remaining) {
        (uint256 spot,,,,) = pair.lastPairPrice();
        (remaining,,,,) = lens.getInsuranceWithdrawalBudget(address(pair), spot);
    }

    /// @dev What the current rate-limit period has already paid out.
    function _budgetSpent() internal view returns (uint256) {
        (uint256 spot,,,,) = pair.lastPairPrice();
        (uint256 remaining, uint256 cap,,,) = lens.getInsuranceWithdrawalBudget(address(pair), spot);
        return cap - remaining;
    }

    function _claimExpect(address user, uint256 priceUsd, bytes4 selector) internal {
        bytes[] memory pu = _priceAt(priceUsd);
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(user, fee);
        vm.prank(user);
        vm.expectRevert(selector);
        pair.executeInsuranceWithdrawal{value: fee}(pu, 0, 0, 0, "", "");
    }

    /// @dev A refresh in the same block judges the fund the redemption left at the mark it paid at.
    function _assertNoWindowOnRefresh(string memory when) internal {
        bytes[] memory pu = _priceAt(MARK_USD);
        vm.prank(seq);
        pair.refreshPrice(pu);
        assertFalse(pair.isAdlPending(), when);
    }

    /// @dev The inventory unloads at the stored mark: its PnL from the estates' entry settles
    ///      against the fund, which spends the seizure and pays the loss beyond it, and nothing is
    ///      held back afterwards. The fixture carries no arrears, so the fund keeps free capital
    ///      plus the inventory's net position.
    function _unloadAtMark() internal {
        (uint256 free,, int256 net) = _fundAtMark();
        (,,,,,,,,,,,,,, uint256 arrears,,) = pair.pairVault();
        assertEq(arrears, 0, "fixture: no arrears");
        _stageHeldInventory(pair, 0, 0, 0);
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(uint256(int256(free) + net));
    }

    /// @dev carol's paying call, her claim worth more than `headroom`, checked against the trim:
    ///      the shares the headroom pays for at the claim's amount per share, that payment and its
    ///      event, the rest of the request and its lock scaled to the shares left, the rate limit
    ///      charged with the payment, and dave's shares worth no less for it.
    function _assertTrimmedClaim(uint256 headroom) internal {
        uint256 value = _claimValue(carol, carolShares);
        assertGt(value, headroom, "fixture: carol's claim exceeds the headroom");
        assertLe(value, _budgetRemaining(), "fixture: the rate limit admits the whole claim");
        uint256 paidShares = Math.mulDiv(carolShares, headroom, value);
        uint256 paid = Math.mulDiv(value, paidShares, carolShares);
        assertGt(paid, 0, "fixture: the headroom pays part of the claim");

        (, uint256 locked,,,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        (uint256 spot,,,,) = pair.lastPairPrice();
        uint256 daveQuote = lens.quoteInsuranceWithdrawal(address(pair), daveShares, spot);
        uint256 spent = _budgetSpent();
        uint256 fund = _insuranceBal();
        uint256 shares = pair.insuranceShares(carol);
        uint256 before = usdc.balanceOf(carol);

        // The update and its fee are taken before the expectation, so the oracle calls they make
        // are not the call it binds to.
        bytes32 pairId = pair.pairId();
        bytes[] memory pu = _priceAt(MARK_USD);
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(carol, fee);
        vm.expectEmit(true, true, false, true, address(pair));
        emit BazaarTypes.InsuranceWithdrawalExecuted(pairId, carol, paidShares, paid);
        vm.prank(carol);
        pair.executeInsuranceWithdrawal{value: fee}(pu, 0, 0, 0, "", "");

        assertEq(_insuranceBal(), fund - paid, "the fund paid up to the headroom");
        assertApproxEqAbs((usdc.balanceOf(carol) - before) * 1e12, paid, 1e12, "carol received it");
        assertEq(pair.insuranceShares(carol), shares - paidShares, "the shares that payment redeems are burned");
        assertEq(
            pair.insuranceWithdrawalRequestShareAmount(carol), carolShares - paidShares, "the rest stays requested"
        );
        (bool stillLocked, uint256 lockedAfter,,,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertTrue(stillLocked, "under the same lock");
        assertEq(lockedAfter, Math.mulDiv(locked, carolShares - paidShares, carolShares), "scaled to the shares left");
        assertEq(_budgetSpent() - spent, paid, "the rate limit is charged with what was paid");
        assertGe(_headroom(), 0, "the payout stays inside the headroom");
        assertGe(
            lens.quoteInsuranceWithdrawal(address(pair), daveShares, spot),
            daveQuote,
            "the other LPs' shares are worth no less"
        );
        _assertNoWindowOnRefresh("a trimmed claim leaves the pair healthy");
    }

    // ---------------------------- tests ----------------------------

    /// @notice A paying call worth more than the headroom is paid up to it, although the fund is
    ///         healthy before it: paid in full, it would leave the fund short of finishing the
    ///         inventory at the band's edge, so a move of the mark toward that edge would open a
    ///         window and charge the loss to winners.
    function test_claim_pastTheHeadroom_paysUpToIt_restStaysRequested() public {
        _assertTrimmedClaim(_lockBothThenOpenClaims(Stage.AtLoss));
    }

    /// @notice With the inventory clear of the band, the headroom is free capital above the reserve
    ///         at the band's upper edge, where the reserve is highest and the loss nil, so a larger
    ///         claim is paid only that far and the reserve stays whole.
    function test_clearOfTheBand_claimTrimmedToKeepTheReserve() public {
        uint256 headroom = _lockBothThenOpenClaims(Stage.ClearOfTheBand);
        assertEq(_finish(), 0, "fixture: nothing to finish even at the band's edge");

        _assertTrimmedClaim(headroom);

        (uint256 free,,) = _fundAtMark();
        assertGe(free, _held(), "free capital keeps the reserve at the band's upper edge");
    }

    /// @notice With the inventory whole at the mark but under water at the band's edge, the
    ///         headroom keeps what finishing it there would cost on top of the reserve at that edge,
    ///         so the payout leaves the fund able to absorb that move without a window.
    function test_insideTheBand_claimKeepsTheBandEdgeFinish() public {
        uint256 headroom = _lockBothThenOpenClaims(Stage.InsideTheBand);
        (,, int256 net) = _fundAtMark();
        assertGe(net, 0, "fixture: no loss at the mark");
        assertGt(_finish(), 0, "fixture: a loss at the band's edge");

        _assertTrimmedClaim(headroom);

        (uint256 free,,) = _fundAtMark();
        assertGe(free, _held(), "free capital keeps the reserve and the band-edge finish");
    }

    /// @notice With nothing above the reserve and the inventory clear of the band, any payout
    ///         would take the reserve, so the paying call is refused with the fund, the request and
    ///         the lock untouched.
    function test_noCapitalAboveTheReserve_claimRefused() public {
        _lockBothThenOpenClaims(Stage.ClearOfTheBand);
        (, uint256 reserve,) = _fundAtMark();
        (uint256 spot,,,,) = pair.lastPairPrice();
        _restage(false, _insuranceBal() - reserve, int256(spot - _lowerEdge()));
        assertLt(_headroom(), 0, "fixture: nothing above the reserve");
        uint256 fund = _insuranceBal();

        _claimExpect(dave, MARK_USD, InsuranceVaultLib.InsuranceVaultLib__AdlBlocking.selector);

        assertEq(_insuranceBal(), fund, "fund untouched");
        assertEq(pair.insuranceWithdrawalRequestShareAmount(dave), daveShares, "the request is untouched");
        (bool locked,,,,) = lens.getInsuranceWithdrawalLock(address(pair), dave);
        assertTrue(locked, "the lock survives the refused call");
    }

    /// @notice Control: in the same state a paying call that fits the headroom is paid in full,
    ///         closes the request, and a health check right after it opens no window.
    function test_claim_insideTheHeadroom_pays_andNoWindowOpens() public {
        uint256 headroom = _lockBothThenOpenClaims(Stage.AtLoss);
        uint256 value = _claimValue(dave, daveShares);
        assertGt(value, 0, "fixture: dave's claim is worth something");
        assertLe(value, headroom, "fixture: dave's claim fits the headroom");
        uint256 fund = _insuranceBal();

        uint256 before = usdc.balanceOf(dave);
        _executeRedemption(pair, dave, _priceAt(MARK_USD));

        assertApproxEqAbs((usdc.balanceOf(dave) - before) * 1e12, value, 1e12, "paid at the quote");
        assertEq(_insuranceBal(), fund - value, "the fund paid it");
        assertEq(pair.insuranceWithdrawalRequestShareAmount(dave), 0, "the request is complete");
        assertEq(_headroom(), int256(headroom - value), "the payout came out of the headroom");
        _assertNoWindowOnRefresh("a claim inside the headroom leaves the pair healthy");
    }

    /// @notice With no headroom at all the paying call is refused, and the refusal lasts only while
    ///         the inventory's position leaves no room: once the mark moves back toward its entry
    ///         the same locked claim pays, at no more than the amount it locked.
    function test_claim_noHeadroom_refused_thenPaysOnceTheMarkRecovers() public {
        _lockBothThenOpenClaims(Stage.AtLoss);
        (uint256 free,,) = _fundAtMark();
        (uint256 spot,,,,) = pair.lastPairPrice();
        _restage(false, _insuranceBal() - free, -int256(free - _reserveAt(_lowerEdge()) - (spot - _lowerEdge())));
        assertEq(_headroom(), 0, "fixture: the band-edge finish takes the whole headroom");
        (, uint256 locked,,,) = lens.getInsuranceWithdrawalLock(address(pair), dave);
        uint256 value = _claimValue(dave, daveShares);
        uint256 fund = _insuranceBal();

        _claimExpect(dave, MARK_USD, InsuranceVaultLib.InsuranceVaultLib__AdlBlocking.selector);
        assertEq(_insuranceBal(), fund, "fund untouched");
        assertEq(pair.insuranceWithdrawalRequestShareAmount(dave), daveShares, "the request is untouched");

        // A mark higher by twice the claim, in whole dollars, takes that much off the inventory's
        // loss at the mark and all but the band's share of it off the loss at the band's lower
        // edge, which moves with the mark, while the reserve there gains only its own small share
        // of the rise, leaving more headroom than the claim is worth. It stays under the 2% that
        // would count as a price jump and restart the claim delay.
        uint256 recoveredUsd = MARK_USD + 2 * value / BAZAAR_SCALE + 1;
        assertLt((recoveredUsd - MARK_USD) * 10_000, MARK_USD * RiskParamsLib.MIN_STRESS_MOVE_BP, "fixture: no jump");
        vm.warp(vm.getBlockTimestamp() + 4);
        uint256 before = usdc.balanceOf(dave);
        _executeRedemption(pair, dave, _priceAt(recoveredUsd));

        uint256 paid = (usdc.balanceOf(dave) - before) * 1e12;
        assertGt(paid, 0, "the claim pays once the mark has recovered");
        assertLe(paid, locked, "never more than the lock recorded");
        assertEq(pair.insuranceWithdrawalRequestShareAmount(dave), 0, "in full");
        assertGe(_headroom(), 0, "and the payout stays inside the headroom");
        assertFalse(pair.isAdlPending(), "no window");
    }

    /// @notice A payout at the cap leaves room for what the fund pays out next without any move of
    ///         the mark: with the reserve far below the inventory, as here, the refresh bounty a
    ///         keeper collects on the next store opens no window, though the claim was for nearly
    ///         the whole pool. Held only to the reserve and the loss at the mark, the payout would
    ///         leave the fund on the line the gate opens at, and that bounty would open one.
    function test_trimmedClaim_leavesRoomForTheNextRefreshBounty() public {
        _depositInsurance(carol, 300_000 * BAZAAR_SCALE);
        carolShares = pair.insuranceShares(carol);
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(carolShares, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);
        _stageHeadroom(Stage.AtLoss);
        _executeRedemption(pair, carol, _priceAt(MARK_USD));
        _warpToRedemptionClaim(pair, carol);
        _stageHeadroom(Stage.AtLoss);

        (uint256 free, uint256 reserve, int256 net) = _fundAtMark();
        uint256 value = _claimValue(carol, carolShares);
        assertGt(value, free - reserve - uint256(-net), "fixture: the claim reaches past the reserve and the loss");
        assertLe(value, _budgetRemaining(), "fixture: the rate limit admits the whole claim");
        _executeRedemption(pair, carol, _priceAt(MARK_USD));
        assertGt(pair.insuranceWithdrawalRequestShareAmount(carol), 0, "fixture: the claim was trimmed");
        (uint256 freeBefore,,) = _fundAtMark();
        uint256 keeperBefore = _escrowOwed(seq);

        vm.warp(vm.getBlockTimestamp() + RiskParamsLib.REFRESH_BOUNTY_MIN_GAP + 1);
        bytes[] memory pu = _priceAt(MARK_USD);
        vm.prank(seq);
        pair.refreshPrice(pu);

        assertEq(_escrowOwed(seq) - keeperBefore, RiskParamsLib.REFRESH_BOUNTY, "fixture: the bounty was paid");
        (uint256 freeAfter,,) = _fundAtMark();
        assertEq(freeBefore - freeAfter, RiskParamsLib.REFRESH_BOUNTY, "out of free capital");
        assertFalse(pair.isAdlPending(), "and no window opened");
    }

    /// @notice With an inventory of shorts the reserve rises with the mark as the loss does. After a
    ///         payout at the cap, a rise of the mark to a dollar inside the band's upper edge opens
    ///         no window: the cap held back the reserve and the loss at that edge. The rise
    ///         is stored within VARIANCE_UPDATE_COOLDOWN of the last sample, so it adds no variance
    ///         to the fund target the reserve is sized on.
    function test_shortInventory_payoutAtTheCap_opensNoWindowInsideTheBand() public {
        _assertTrimmedClaim(_lockBothThenOpenClaims(Stage.AtLoss, true));
        uint256 insideUsd = _upperEdge() / BAZAAR_SCALE - 1;
        (uint256 spot,,,,) = pair.lastPairPrice();
        assertGt(_reserveAt(insideUsd * BAZAAR_SCALE), _reserveAt(spot), "fixture: the reserve rises with the mark");

        _refreshAt(insideUsd);

        assertFalse(pair.isAdlPending(), "a rise inside the band opens no window");
    }

    /// @notice With an inventory of longs, after a payout at the cap held to the lower edge's sum,
    ///         neither a fall of the mark to a dollar inside that edge nor a rise to a dollar inside
    ///         the upper one, where the reserve has grown while the loss shrank, opens a window.
    ///         Both are stored
    ///         within VARIANCE_UPDATE_COOLDOWN of the last sample, so neither adds variance to the
    ///         fund target.
    function test_longInventory_payoutAtTheCap_opensNoWindowInsideTheBand() public {
        _assertTrimmedClaim(_lockBothThenOpenClaims(Stage.AtLoss));
        uint256 lowerUsd = _lowerEdge() / BAZAAR_SCALE + 1;
        uint256 upperUsd = _upperEdge() / BAZAAR_SCALE - 1;

        _refreshAt(lowerUsd);
        assertFalse(pair.isAdlPending(), "a fall inside the band opens no window");
        _refreshAt(upperUsd);
        assertFalse(pair.isAdlPending(), "nor a rise inside it");
    }

    /// @notice The rest of a trimmed claim pays later in the same window once the inventory has
    ///         unloaded, at the lower of its scaled lock and what those shares are worth then, so
    ///         the calls together never pay more than the lock recorded for the whole request.
    function test_trimmedClaim_restPaysLaterInTheWindow() public {
        _lockBothThenOpenClaims(Stage.AtLoss);
        (, uint256 locked,,,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        uint256 before = usdc.balanceOf(carol);
        _executeRedemption(pair, carol, _priceAt(MARK_USD));
        uint256 rest = pair.insuranceWithdrawalRequestShareAmount(carol);
        assertGt(rest, 0, "fixture: the first call was trimmed");
        uint256 afterFirst = usdc.balanceOf(carol);

        _unloadAtMark();
        vm.warp(vm.getBlockTimestamp() + 4);
        uint256 restValue = _claimValue(carol, rest);
        _executeRedemption(pair, carol, _priceAt(MARK_USD));

        assertEq(pair.insuranceWithdrawalRequestShareAmount(carol), 0, "the request is complete");
        (bool stillLocked,,,,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertFalse(stillLocked, "and its lock cleared");
        assertApproxEqAbs((usdc.balanceOf(carol) - afterFirst) * 1e12, restValue, 1e12, "the rest paid as claimed");
        assertLe((usdc.balanceOf(carol) - before) * 1e12, locked, "never more than the lock recorded in all");
    }

    /// @notice A new request after a trimmed claim starts unlocked, as every new request does: the
    ///         scaled lock belongs to the old request's window and cannot be claimed under the new
    ///         one, which serves its own cooldown.
    function test_trimmedClaim_newRequestStartsUnlocked() public {
        _lockBothThenOpenClaims(Stage.AtLoss);
        _executeRedemption(pair, carol, _priceAt(MARK_USD));
        uint256 rest = pair.insuranceWithdrawalRequestShareAmount(carol);
        assertGt(rest, 0, "fixture: the first call was trimmed");

        vm.prank(carol);
        pair.requestInsuranceWithdrawal(rest, 0, 0, 0, "", "");

        (bool locked,,,,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertFalse(locked, "the new request starts unlocked");
        _claimExpect(carol, MARK_USD, InsuranceVaultLib.InsuranceVaultLib__CooldownNotElapsed.selector);
    }

    /// @notice Whatever share of the supply is redeemed, whichever side the inventory holds and
    ///         wherever it sits against the band, the paying call pays the lower of its claim and
    ///         the headroom, to the share, and leaves the rest requested; no outcome opens a window,
    ///         at the mark or after a move of it to anywhere inside the band stored within
    ///         VARIANCE_UPDATE_COOLDOWN, which adds no variance to the fund target.
    function testFuzz_claim_paysUpToTheHeadroom(uint256 shareBp, uint8 stageSeed, bool isShort, uint256 moveSeed)
        public
    {
        shareBp = bound(shareBp, 1, 6_000);
        Stage stage = Stage(stageSeed % 3);
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        uint256 shares = pair.totalInsuranceShares() * shareBp / 10_000;
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(shares, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);

        _stageHeadroom(stage, isShort);
        _executeRedemption(pair, carol, _priceAt(MARK_USD));
        _warpToRedemptionClaim(pair, carol);
        uint256 headroom = _stageHeadroom(stage, isShort);

        uint256 value = _claimValue(carol, shares);
        assertLe(value, _budgetRemaining(), "fixture: the rate limit admits every size tried");
        uint256 paidShares = value > headroom ? Math.mulDiv(shares, headroom, value) : shares;
        uint256 paid = value > headroom ? Math.mulDiv(value, paidShares, shares) : value;
        uint256 fund = _insuranceBal();
        uint256 lowerUsd = _lowerEdge() / BAZAAR_SCALE;
        uint256 movedUsd = lowerUsd + 1 + moveSeed % (_upperEdge() / BAZAAR_SCALE - lowerUsd - 1);

        _executeRedemption(pair, carol, _priceAt(MARK_USD));

        assertEq(_insuranceBal(), fund - paid, "paid the lower of the claim and the headroom");
        assertEq(pair.insuranceWithdrawalRequestShareAmount(carol), shares - paidShares, "the rest stays requested");
        assertGe(_headroom(), 0, "the payout stays inside the headroom");
        _assertNoWindowOnRefresh("no outcome leaves the pair past the ADL trigger");
        _refreshAt(movedUsd);
        assertFalse(pair.isAdlPending(), "nor does a move of the mark inside the band");
    }
}
