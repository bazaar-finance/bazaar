// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarPairTerminator} from "../../src/BazaarPairTerminator.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {InsuranceVaultLib} from "../../src/libraries/InsuranceVaultLib.sol";

/// @title InsuranceForwardExitTest
/// @notice A live-pair insurance redemption is priced forward: the first execute call locks what
///         the requested shares are worth, and the paying call pays the lower of that and what
///         they are worth once a delay has passed. A loss a price move has already caused reaches
///         the share price only when a keeper seizes the position, so an exit priced at one moment
///         the LP picks could leave at the pre-loss value. These tests pin that the delay puts
///         such a loss on the leaver, that a storage gap or a price jump after the lock pushes the
///         paying call back and that call can never itself be the store carrying one, that a
///         lock abandoned in its window costs nothing and blocks nothing, and that a terminated
///         pair still pays in one call.
contract InsuranceForwardExitTest is IntegrationBase {
    using stdStorage for StdStorage;

    uint256 internal constant REQUESTED = 3_000 * BAZAAR_SCALE;
    uint256 internal constant CLAIM_DELAY = InsuranceVaultLib.INSURANCE_WITHDRAWAL_CLAIM_DELAY;
    uint256 internal constant REOPEN_DELAY = InsuranceVaultLib.INSURANCE_WITHDRAWAL_REOPEN_CLAIM_DELAY;
    /// @dev InsuranceWithdrawalRateLimitState.withdrawnThisPeriod, from `forge inspect BazaarPair
    ///      storage-layout` (the lens pins the same slot).
    uint256 internal constant SLOT_INSURANCE_RATE_LIMIT = 57;

    address internal keeper = makeAddr("keeper");

    // ---------------------------------------------------------------- fixtures

    /// @dev One BTC each way at $50k, alice long and bob short with $20k collateral each, so the
    ///      withdrawal rate limit has open interest to read. Alice's bankruptcy price is $30k.
    function _openOI() internal {
        _deposit(alice, 20_000 * BAZAAR_SCALE);
        _deposit(bob, 20_000 * BAZAAR_SCALE);
        _placeLimit(alice, true, 1 * BAZAAR_SCALE, 50_000 * BAZAAR_SCALE);
        _roll(2);
        _placeLimit(bob, false, 1 * BAZAAR_SCALE, 49_000 * BAZAAR_SCALE);
        assertEq(_posSize(alice), 1 * BAZAAR_SCALE, "fixture: OI opened");
    }

    /// @dev A keeper stores a fresh print on `p` three seconds on, forwarding the Pyth fee.
    function _refresh(BazaarPair p, bytes32 feedId, uint256 priceUsd) internal {
        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceUpdateFor(feedId, priceUsd, uint64(vm.getBlockTimestamp()));
        uint256 fee = oracle.getUpdateFee(pu);
        vm.deal(keeper, fee);
        vm.prank(keeper);
        p.refreshPrice{value: fee}(pu);
    }

    /// @dev Carol deposits $30k, requests REQUESTED shares and serves the cooldown. A keeper then
    ///      stores the print that ends the cooldown's silence and another a reopen delay later, so
    ///      the pair reads as live and the next lock's claim opens a plain claim delay after it.
    function _ripenLive() internal {
        _depositInsurance(carol, 30_000 * BAZAAR_SCALE);
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(REQUESTED, 0, 0, 0, "", "");
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);
        _refresh(pair, BTC_USD_FEED_ID, 50_000);
        vm.warp(vm.getBlockTimestamp() + REOPEN_DELAY);
        _refresh(pair, BTC_USD_FEED_ID, 50_000);
    }

    /// @dev Carol's first call at `priceUsd`: it locks and pays nothing.
    function _lockAt(uint256 priceUsd) internal returns (uint256 lockedAmount, uint256 opensTs) {
        _executeRedemption(pair, carol, _priceAt(priceUsd));
        bool isLocked;
        (isLocked, lockedAmount,, opensTs,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertTrue(isLocked, "the first call locked");
    }

    /// @dev Carol's paying call at `priceUsd`; returns what reached her, in BAZAAR precision.
    function _claimAt(uint256 priceUsd) internal returns (uint256 paid) {
        uint256 before = usdc.balanceOf(carol);
        _executeRedemption(pair, carol, _priceAt(priceUsd));
        paid = (usdc.balanceOf(carol) - before) * 1e12;
    }

    /// @dev One call by carol on `p` carrying `pu`, expected to revert with `revertData`.
    function _expectRedemptionRevert(BazaarPair p, bytes[] memory pu, bytes memory revertData) internal {
        vm.prank(carol);
        vm.expectRevert(revertData);
        p.executeInsuranceWithdrawal(pu, 0, 0, 0, "", "");
    }

    function _spent() internal view returns (uint256) {
        return uint256(vm.load(address(pair), bytes32(SLOT_INSURANCE_RATE_LIMIT)));
    }

    /// @dev Credits the fund with `amount` of real USDC, the way fee income would arrive.
    function _creditFund(uint256 amount) internal {
        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(_insuranceBal() + amount);
        usdc.mint(address(pair), amount / 1e12);
    }

    // ---------------------------------------------------------------- lock and claim

    /// @notice The first call records what the requested shares are worth and moves nothing: no
    ///         share is burned, no USDC leaves the fund or the pair, and the rate-limit budget is
    ///         untouched.
    function test_lock_recordsTheValueAndMovesNothing() public {
        _openOI();
        _ripenLive();
        uint256 quote = lens.quoteInsuranceWithdrawal(address(pair), REQUESTED, 50_000 * BAZAAR_SCALE);
        uint256 shares = pair.insuranceShares(carol);
        uint256 supply = pair.totalInsuranceShares();
        uint256 fund = _insuranceBal();
        uint256 usdcBefore = usdc.balanceOf(carol);
        uint256 pairUsdcBefore = usdc.balanceOf(address(pair));
        uint256 spent = _spent();
        uint256 lockTs = vm.getBlockTimestamp();

        vm.expectEmit(true, true, false, true, address(pair));
        emit BazaarTypes.InsuranceWithdrawalLocked(pair.pairId(), carol, REQUESTED, quote, lockTs + CLAIM_DELAY);
        (uint256 lockedAmount, uint256 opensTs) = _lockAt(50_000);

        assertEq(lockedAmount, quote, "the lock records the shares' value at that moment");
        assertEq(opensTs, lockTs + CLAIM_DELAY, "a live pair's claim opens a claim delay after the lock");
        assertEq(pair.insuranceShares(carol), shares, "nothing burned");
        assertEq(pair.totalInsuranceShares(), supply, "supply unchanged");
        assertEq(_insuranceBal(), fund, "the fund is untouched");
        assertEq(usdc.balanceOf(carol), usdcBefore, "nothing paid");
        assertEq(usdc.balanceOf(address(pair)), pairUsdcBefore, "no USDC left the pair");
        assertEq(_spent(), spent, "the lock draws nothing on the rate-limit budget");
    }

    /// @notice The paying call is refused until the claim opens, then burns the shares and pays
    ///         the locked value when nothing moved in between, charging the budget at that point.
    function test_claim_opensAfterTheDelayAndPaysTheLockedValue() public {
        _openOI();
        _ripenLive();
        uint256 shares = pair.insuranceShares(carol);
        (uint256 lockedAmount, uint256 opensTs) = _lockAt(50_000);

        vm.warp(opensTs - 1);
        _expectRedemptionRevert(
            pair,
            _priceAt(50_000),
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__ClaimNotOpen.selector, opensTs)
        );

        vm.warp(opensTs);
        vm.expectEmit(true, true, false, true, address(pair));
        emit BazaarTypes.InsuranceWithdrawalExecuted(pair.pairId(), carol, REQUESTED, lockedAmount);
        uint256 paid = _claimAt(50_000);

        assertApproxEqAbs(paid, lockedAmount, 1e12, "pays the locked value (USDC granularity)");
        assertEq(pair.insuranceShares(carol), shares - REQUESTED, "requested shares burned");
        assertEq(pair.insuranceWithdrawalRequestTs(carol), 0, "request cleared");
        (bool isLocked,,,,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertFalse(isLocked, "lock cleared");
        assertEq(_spent(), lockedAmount, "the paying call is what the budget books");
    }

    /// @notice A price move carries alice past bankruptcy, and carol's lock
    ///         is the first call to carry that price: it records the pre-loss value, since nothing
    ///         has seized alice yet. A keeper seizes her inside the delay, which puts the loss in
    ///         the share price, and the paying call pays the post-loss value. A redemption priced
    ///         at the lock alone would have left with carol's share of that loss.
    function test_lossBookedDuringTheDelayIsChargedToTheLeaver() public {
        _openOI();
        _ripenLive();
        uint256 supply = pair.totalInsuranceShares();

        // Three seconds on, so the lock's own update is the freshest tick and is what it stores.
        vm.warp(vm.getBlockTimestamp() + 4);
        uint256 preLoss = lens.quoteInsuranceWithdrawal(address(pair), REQUESTED, 28_000 * BAZAAR_SCALE);
        (uint256 lockedAmount,) = _lockAt(28_000);
        (uint256 storedSpot,,,,) = pair.lastPairPrice();
        assertEq(storedSpot, 28_000 * BAZAAR_SCALE, "the lock is the first call to carry the crash");
        assertEq(lockedAmount, preLoss, "the lock saw no loss: alice is still unseized");
        assertEq(_posSize(alice), 1 * BAZAAR_SCALE, "fixture: alice is past bankruptcy but open");

        vm.warp(vm.getBlockTimestamp() + 4);
        bytes[] memory pu = _priceAt(28_000);
        vm.prank(keeper);
        assertEq(pair.liquidate(_arr1(alice), pu), 1, "the keeper seizes alice inside the delay");

        // Keepers go on pricing the pair; the first store a sampling interval on re-bases the jump
        // reference, and the claim opens a claim delay after that last jump-carrying store.
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        _refresh(pair, BTC_USD_FEED_ID, 28_000);
        _warpToRedemptionClaim(pair, carol);
        uint256 postLoss = lens.quoteInsuranceWithdrawal(address(pair), REQUESTED, 28_000 * BAZAAR_SCALE);
        // Alice's $20k collateral covers $20k of her $22k loss at $28k and the fund bears the other
        // $2k, of which carol's requested shares carry their fraction of the supply.
        assertApproxEqRel(
            lockedAmount - postLoss,
            REQUESTED * 2_000 * BAZAAR_SCALE / supply,
            5e16,
            "the seizure booked the fund's loss into the share price"
        );

        uint256 paid = _claimAt(28_000);
        assertApproxEqRel(paid, postLoss, 1e15, "the leaver is paid the post-loss value");
        assertLt(paid, lockedAmount, "and carries its share of the loss");
    }

    /// @notice A gain the fund makes while the redemption waits stays with the LPs who remain:
    ///         the paying call pays the locked value, not the higher value it finds.
    function test_gainDuringTheDelayStaysWithThePool() public {
        _openOI();
        _ripenLive();
        (uint256 lockedAmount, uint256 opensTs) = _lockAt(50_000);

        _creditFund(1_000 * BAZAAR_SCALE);
        vm.warp(opensTs);
        uint256 now_ = lens.quoteInsuranceWithdrawal(address(pair), REQUESTED, 50_000 * BAZAAR_SCALE);
        assertGt(now_, lockedAmount, "fixture: the shares gained while waiting");

        uint256 fundBefore = _insuranceBal();
        uint256 paid = _claimAt(50_000);
        assertApproxEqAbs(paid, lockedAmount, 1e12, "capped at the locked value");
        assertEq(fundBefore - _insuranceBal(), lockedAmount, "the fund keeps the gain on the redeemed shares");
    }

    /// @notice The paying call is still judged against vault health: inventory that drifts past
    ///         the ADL trigger after the lock blocks it, and once the mark keeps the loss under
    ///         the trigger it pays the lower, loss-bearing value rather than the locked one.
    function test_claimIsStillJudgedAgainstVaultHealth() public {
        _ripenLive();
        uint256 shares = pair.insuranceShares(carol);
        (uint256 lockedAmount, uint256 opensTs) = _lockAt(50_000);

        // One unit of long inventory with half the fund seized alongside it. At $50k its loss
        // beyond the seizure exceeds the free half, past the ADL trigger; $7k higher, it is under.
        uint256 fund = _insuranceBal();
        _stageHeldInventory(50_000 * BAZAAR_SCALE + fund + 1_000 * BAZAAR_SCALE, fund / 2);
        vm.warp(opensTs);
        _expectRedemptionRevert(
            pair,
            _priceAt(50_000),
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__AdlBlocking.selector)
        );
        assertEq(pair.insuranceShares(carol), shares, "shares retained while blocked");

        // The mark recovers $7k, under the trigger. That move is a jump, so the claim opens a claim
        // delay after the store that carried it.
        _refresh(pair, BTC_USD_FEED_ID, 57_000);
        _warpToRedemptionClaim(pair, carol);
        uint256 paid = _claimAt(57_000);
        assertLt(paid, lockedAmount, "pays the value that bears the inventory's loss");
    }

    // ---------------------------------------------------------------- price jumps

    /// @notice A jump stored while the lock waits pushes the claim back to a claim delay after
    ///         it, the time keepers need to seize what it carried past bankruptcy. A move of
    ///         exactly the smallest maintenance rate counts.
    function test_jumpWhileTheLockWaitsPushesTheClaimBack() public {
        _ripenLive();
        (, uint256 opensTs) = _lockAt(50_000);

        vm.warp(opensTs - 2 minutes);
        _refresh(pair, BTC_USD_FEED_ID, 49_000); // 2% under the sample
        uint256 jumpTs = vm.getBlockTimestamp();
        (,,, uint256 pushedTs,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertEq(pushedTs, jumpTs + CLAIM_DELAY, "the jump restarted the claim delay");

        vm.warp(opensTs);
        _expectRedemptionRevert(
            pair,
            _priceAt(49_000),
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__ClaimNotOpen.selector, pushedTs)
        );
        vm.warp(pushedTs);
        assertGt(_claimAt(49_000), 0, "paid once the delay after the jump passed");
    }

    /// @notice A paying call that itself carries a jump is refused, a claim delay out, and the
    ///         revert takes its store with it: the claim cannot be the first transaction to price
    ///         a jump, ahead of the keepers who would seize what it bankrupted.
    function test_claimCarryingAJumpIsRefused() public {
        _ripenLive();
        (, uint256 opensTs) = _lockAt(50_000);
        vm.warp(opensTs);
        (,, uint256 storedTs,,) = pair.lastPairPrice();

        _expectRedemptionRevert(
            pair,
            _priceAt(45_000),
            abi.encodeWithSelector(
                InsuranceVaultLib.InsuranceVaultLib__ClaimNotOpen.selector, vm.getBlockTimestamp() + CLAIM_DELAY
            )
        );
        (,, uint256 storedAfter,,) = pair.lastPairPrice();
        assertEq(storedAfter, storedTs, "the refused claim stored nothing");
    }

    /// @notice A move under the smallest maintenance rate is not a jump and holds nothing back.
    function test_moveUnderTheJumpThresholdDoesNotDelayTheClaim() public {
        _ripenLive();
        (, uint256 opensTs) = _lockAt(50_000);

        vm.warp(opensTs - 2 minutes);
        _refresh(pair, BTC_USD_FEED_ID, 49_010); // 1.98% under the sample
        (,,, uint256 stillOpensTs,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertEq(stillOpensTs, opensTs, "no jump, no push");

        vm.warp(opensTs);
        assertGt(_claimAt(49_010), 0, "paid on time");
    }

    // ---------------------------------------------------------------- discontinuities

    /// @notice The store that ends a discontinuity can never be the paying call. Carol locks on a
    ///         session pair, and the venue closes before her claim opens. Her claim carrying the
    ///         first print after the closure is refused, a reopen delay out, and the revert takes
    ///         that store with it. Once a keeper has stored the reopen, the claim opens a reopen
    ///         delay later: the time keepers get to seize whatever the gap revealed.
    function test_theStoreEndingAGapCannotBeThePayingCall() public {
        _refresh(aaplPair, AAPL_USD_FEED_ID, 150);
        vm.startPrank(carol);
        usdc.approve(address(aaplPair), 1_000 * USDC_SCALE);
        aaplPair.depositToInsurance(1_000 * BAZAAR_SCALE, new bytes[](0), 0, 0, 0, "", "");
        aaplPair.requestInsuranceWithdrawal(200 * BAZAAR_SCALE, 0, 0, 0, "", "");
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);
        _refresh(aaplPair, AAPL_USD_FEED_ID, 150);
        vm.warp(vm.getBlockTimestamp() + REOPEN_DELAY);
        _refresh(aaplPair, AAPL_USD_FEED_ID, 150);

        _executeRedemption(aaplPair, carol, _priceUpdateFor(AAPL_USD_FEED_ID, 150, uint64(vm.getBlockTimestamp())));
        (bool isLocked,, uint256 lockTs, uint256 opensTs,) = lens.getInsuranceWithdrawalLock(address(aaplPair), carol);
        assertTrue(isLocked, "locked while the venue trades");
        assertEq(opensTs, lockTs + CLAIM_DELAY, "claim would open a claim delay later");

        // The venue closes: nothing is stored overnight.
        vm.warp(vm.getBlockTimestamp() + 17 hours + 30 minutes);
        (,, uint256 storedTs,,) = aaplPair.lastPairPrice();
        uint256 reopenTs = vm.getBlockTimestamp();
        bytes[] memory reopen = _priceUpdateFor(AAPL_USD_FEED_ID, 150, uint64(reopenTs));
        _expectRedemptionRevert(
            aaplPair,
            reopen,
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__ClaimNotOpen.selector, reopenTs + REOPEN_DELAY)
        );
        (,, uint256 storedAfter,,) = aaplPair.lastPairPrice();
        assertEq(storedAfter, storedTs, "the refused claim stored nothing");

        // A keeper stores the reopen; the claim now opens a reopen delay after it.
        vm.deal(keeper, oracle.getUpdateFee(reopen));
        vm.prank(keeper);
        aaplPair.refreshPrice{value: oracle.getUpdateFee(reopen)}(reopen);
        (,,, opensTs,) = lens.getInsuranceWithdrawalLock(address(aaplPair), carol);
        assertEq(opensTs, reopenTs + REOPEN_DELAY, "the reopen pushed the claim back");

        vm.warp(opensTs - 1);
        _expectRedemptionRevert(
            aaplPair,
            _priceUpdateFor(AAPL_USD_FEED_ID, 150, uint64(vm.getBlockTimestamp())),
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__ClaimNotOpen.selector, opensTs)
        );
        vm.warp(opensTs);
        uint256 before = usdc.balanceOf(carol);
        _executeRedemption(aaplPair, carol, _priceUpdateFor(AAPL_USD_FEED_ID, 150, uint64(vm.getBlockTimestamp())));
        assertGt(usdc.balanceOf(carol), before, "paid once the reopen delay passed");
        assertEq(aaplPair.insuranceShares(carol), 800 * BAZAAR_SCALE, "requested shares burned");
    }

    // ---------------------------------------------------------------- window and request

    /// @notice A lock that is never claimed lapses with the request's window and costs nothing:
    ///         no share left, the fund and the rate-limit budget are untouched, and the shares go
    ///         on sharing the pool's gains. A new request starts unlocked, and its own first call
    ///         locks afresh at the value then.
    function test_abandonedLock_lapsesWithTheWindowAndCostsNothing() public {
        _openOI();
        _ripenLive();
        uint256 shares = pair.insuranceShares(carol);
        uint256 supply = pair.totalInsuranceShares();
        uint256 usdcBefore = usdc.balanceOf(carol);
        uint256 spent = _spent();
        uint256 fund = _insuranceBal();
        (uint256 lockedAmount,) = _lockAt(50_000);

        (,,,, uint256 windowEndTs) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        vm.warp(windowEndTs + 1);
        _expectRedemptionRevert(
            pair,
            _priceAt(50_000),
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__WithdrawalWindowExpired.selector)
        );
        assertEq(pair.insuranceShares(carol), shares, "shares stay with carol");
        assertEq(pair.totalInsuranceShares(), supply, "supply unchanged");
        assertEq(_insuranceBal(), fund, "the fund is untouched");
        assertEq(usdc.balanceOf(carol), usdcBefore, "nothing paid");
        assertEq(_spent(), spent, "no budget spent for anyone else to miss");

        // The shares still share what the pool earns.
        uint256 valueBefore = lens.getInsuranceDepositValue(address(pair), carol);
        _creditFund(1_000 * BAZAAR_SCALE);
        assertGt(lens.getInsuranceDepositValue(address(pair), carol), valueBefore, "the lapsed shares earn");

        // A new request starts unlocked; its first call after the cooldown locks at the new value.
        vm.prank(carol);
        pair.requestInsuranceWithdrawal(REQUESTED, 0, 0, 0, "", "");
        (bool isLocked,,,,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertFalse(isLocked, "a new request ignores the lapsed lock");
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_COOLDOWN + 1);
        _refresh(pair, BTC_USD_FEED_ID, 50_000);
        vm.warp(vm.getBlockTimestamp() + REOPEN_DELAY);
        _refresh(pair, BTC_USD_FEED_ID, 50_000);
        uint256 usdcMid = usdc.balanceOf(carol);
        (uint256 relocked, uint256 opensTs) = _lockAt(50_000);
        assertEq(usdc.balanceOf(carol), usdcMid, "the new request's first call only locks");
        assertGt(relocked, lockedAmount, "locked afresh at the value the gain raised");
        vm.warp(opensTs);
        assertApproxEqAbs(_claimAt(50_000), relocked, 1e12, "and pays on its own claim");
    }

    /// @notice Filing a new request while a lock is pending starts over: the lock no longer
    ///         counts, and the new request serves its own cooldown.
    function test_newRequestDuringALockStartsOver() public {
        _ripenLive();
        _lockAt(50_000);

        vm.prank(carol);
        pair.requestInsuranceWithdrawal(REQUESTED / 2, 0, 0, 0, "", "");
        (bool isLocked,,,,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertFalse(isLocked, "the pending lock no longer counts");
        vm.warp(vm.getBlockTimestamp() + CLAIM_DELAY);
        _expectRedemptionRevert(
            pair,
            _priceAt(50_000),
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__CooldownNotElapsed.selector)
        );
    }

    /// @notice A fund wiped below $1 and recapitalized between the lock and the claim starts a new
    ///         share generation: the request, made against the wiped stake, is void, so its claim
    ///         is refused rather than burning shares of the new generation.
    function test_shareEpochResetBetweenLockAndClaimVoidsTheRequest() public {
        _ripenLive();
        (, uint256 opensTs) = _lockAt(50_000);

        _stdstore.target(address(pair)).sig("pairVault()").depth(5).checked_write(BAZAAR_SCALE / 2);
        _depositInsurance(dave, 100 * BAZAAR_SCALE);
        vm.warp(opensTs);
        _expectRedemptionRevert(
            pair,
            _priceAt(50_000),
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__WithdrawalRequestStaleEpoch.selector)
        );
        assertEq(pair.insuranceShares(carol), 0, "the wiped stake is gone");
        assertEq(pair.insuranceShares(dave), 100 * BAZAAR_SCALE, "the rescuer is priced against its own deposit");
    }

    /// @notice Shares voted into an insurer-termination proposal after the lock back that vote,
    ///         so the paying call cannot redeem them while it stands.
    function test_sharesVotedAfterTheLockHoldTheClaim() public {
        _ripenLive();
        (, uint256 opensTs) = _lockAt(50_000);

        BazaarPairTerminator terminator = factory.pairTerminator();
        uint256 bond = 1_000 * USDC_SCALE; // INSURER_TERMINATION_BOND_USDC
        usdc.mint(carol, bond);
        vm.startPrank(carol);
        usdc.approve(address(terminator), bond);
        bytes32 id = terminator.proposeInsurerTermination(address(pair), uint64(vm.getBlockTimestamp()) + 1 days);
        terminator.voteForInsurerTermination(address(pair), id, pair.insuranceShares(carol));
        vm.stopPrank();

        vm.warp(opensTs);
        _expectRedemptionRevert(
            pair,
            _priceAt(50_000),
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__SharesLockedForVoting.selector)
        );
    }

    /// @notice A claim the period budget refuses keeps its lock: dave's paying call spends most of
    ///         the budget, carol's is refused, and in the next period, still inside her window,
    ///         the same lock pays.
    function test_claimRefusedByTheRateLimitKeepsItsLock() public {
        _openOI();
        _depositInsurance(dave, 30_000 * BAZAAR_SCALE);
        vm.prank(dave);
        pair.requestInsuranceWithdrawal(4_000 * BAZAAR_SCALE, 0, 0, 0, "", "");
        _ripenLive();

        _executeRedemption(pair, dave, _priceAt(50_000));
        (uint256 lockedAmount,) = _lockAt(50_000);
        _warpToRedemptionClaim(pair, carol);
        _executeRedemption(pair, dave, _priceAt(50_000));
        (uint256 remaining,,,,) = lens.getInsuranceWithdrawalBudget(address(pair), 50_000 * BAZAAR_SCALE);
        assertLt(remaining, lockedAmount, "fixture: dave left too little budget for carol");
        _expectRedemptionRevert(
            pair,
            _priceAt(50_000),
            abi.encodeWithSelector(InsuranceVaultLib.InsuranceVaultLib__RateLimitExceeded.selector)
        );
        (bool isLocked, uint256 stillLocked,,,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertTrue(isLocked, "the refused claim keeps the lock");
        assertEq(stillLocked, lockedAmount, "at the amount it recorded");

        // The next period, priced live again: the same lock pays.
        vm.warp(vm.getBlockTimestamp() + InsuranceVaultLib.INSURANCE_WITHDRAWAL_RATE_LIMIT_PERIOD);
        _refresh(pair, BTC_USD_FEED_ID, 50_000);
        vm.warp(vm.getBlockTimestamp() + REOPEN_DELAY);
        _refresh(pair, BTC_USD_FEED_ID, 50_000);
        _warpToRedemptionClaim(pair, carol);
        assertApproxEqRel(_claimAt(50_000), lockedAmount, 1e14, "paid on the next period's budget");
    }

    /// @dev Keeps the BTC pair live up to `ts` and moves there: a keeper stores a print a reopen
    ///      delay and a little before, so `ts` is inside an hour of the last store and past the
    ///      reopen delay of the one before it.
    function _liveAt(uint256 ts) internal {
        vm.warp(ts - REOPEN_DELAY - 60);
        _refresh(pair, BTC_USD_FEED_ID, 50_000);
        vm.warp(ts - 10);
        _refresh(pair, BTC_USD_FEED_ID, 50_000);
        vm.warp(ts);
    }

    /// @notice A lock whose claim could only open after the window closes is refused outright
    ///         with both instants, rather than recorded to lapse.
    function test_lockTooLateInTheWindowIsRefused() public {
        _ripenLive();
        (,,,, uint256 windowEndTs) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        _liveAt(windowEndTs - CLAIM_DELAY + 1);

        _expectRedemptionRevert(
            pair,
            _priceAt(50_000),
            abi.encodeWithSelector(
                InsuranceVaultLib.InsuranceVaultLib__LockTooLate.selector, windowEndTs + 1, windowEndTs
            )
        );
        (bool isLocked,,,,) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        assertFalse(isLocked, "nothing was recorded");
    }

    /// @notice The last lock the window admits opens its claim exactly at the window's end, and
    ///         that claim is still inside the window.
    function test_lastLockInTheWindowClaimsAtItsEnd() public {
        _ripenLive();
        (,,,, uint256 windowEndTs) = lens.getInsuranceWithdrawalLock(address(pair), carol);
        _liveAt(windowEndTs - CLAIM_DELAY);

        (uint256 lockedAmount, uint256 opensTs) = _lockAt(50_000);
        assertEq(opensTs, windowEndTs, "the claim opens as the window closes");
        vm.warp(opensTs);
        assertApproxEqAbs(_claimAt(50_000), lockedAmount, 1e12, "paid at the window's last second");
    }

    // ---------------------------------------------------------------- terminated pair

    /// @notice A terminated pair's residual is final, so its redemption pays in one call at the
    ///         terminal value; a lock made while the pair was live plays no part and is cleared.
    ///         Between the scheduled cutoff and the finalize, the claim waits like every exit.
    function test_terminatedPairPaysInOneCallIgnoringALock() public {
        _ripenLive();
        (uint256 lockedAmount, uint256 opensTs) = _lockAt(50_000);
        _creditFund(1_000 * BAZAAR_SCALE);

        _stdstore.target(address(pair)).sig("scheduledTerminationTs()").checked_write(opensTs - 1);
        vm.warp(opensTs);
        _expectRedemptionRevert(
            pair,
            _priceAt(50_000),
            abi.encodeWithSelector(
                InsuranceVaultLib.InsuranceVaultLib__PairScheduledForTermination.selector, opensTs - 1
            )
        );

        vm.prank(pair.umaContract());
        pair.fixSettlementPrice(50_000 * BAZAAR_SCALE);
        pair.finalizeTermination();
        assertTrue(pair.isPairTerminated(), "fixture: terminated");

        uint256 terminalValue = pair.insuranceWithdrawalRequestShareAmount(carol) * _insuranceBal()
            / pair.totalInsuranceShares();
        assertGt(terminalValue, lockedAmount, "fixture: the terminal value exceeds the old lock");
        bytes32 lockSlot = keccak256(abi.encode(carol, uint256(112))); // insuranceWithdrawalLock
        assertGt(uint256(vm.load(address(pair), lockSlot)), 0, "fixture: the pin reads the live lock");
        uint256 before = usdc.balanceOf(carol);
        _executeRedemption(pair, carol, new bytes[](0));
        uint256 paid = (usdc.balanceOf(carol) - before) * 1e12;
        assertApproxEqAbs(paid, terminalValue, 1e12, "one call pays the terminal value");
        assertEq(pair.insuranceWithdrawalRequestTs(carol), 0, "request cleared");
        assertEq(uint256(vm.load(address(pair), lockSlot)), 0, "the live-pair lock is cleared");
    }
}
