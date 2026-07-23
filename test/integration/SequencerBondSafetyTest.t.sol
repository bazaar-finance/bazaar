// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {IntegrationBase} from "./IntegrationBase.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {BazaarSequencer} from "../../src/BazaarSequencer.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title SequencerBondSafetyTest
/// @notice The slashing backbone under stress: a penalty larger than the sequencer's remaining bond
///         is capped at the bond (no totalSequencerBonds underflow, no over-slash), and a follow-up
///         challenge against the emptied bond slashes zero without reverting.
contract SequencerBondSafetyTest is IntegrationBase {
    address internal seq2;

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

    // The scenario needs a stale-labelable batch, which only a non-24/7 pair can produce (a
    // continuously-traded pair reverts on an empty price update instead of falling back to the
    // stale ladder) — so everything runs on aaplPair.
    function _depositAapl(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(aaplPair), amount * USDC_SCALE / BAZAAR_SCALE);
        aaplPair.depositCollateral(amount, 0, 0, 0, "", "");
        vm.stopPrank();
    }

    function _placeLimitAapl(address user, bool isLong, uint256 size, uint256 limitPrice) internal returns (uint256) {
        bytes[] memory pu = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(vm.getBlockTimestamp()));
        vm.prank(user);
        aaplPair.createOrder(
            BazaarTypes.OrderType.Limit,
            0,
            limitPrice,
            0,
            size,
            isLong,
            false,
            uint64(vm.getBlockNumber() + 500_000),
            address(0),
            pu,
            0,
            0,
            0,
            ""
        );
        (uint256[] memory ids,,,) = aaplPair.getUserActiveLimitOrders(user);
        return ids[ids.length - 1];
    }

    function _insuranceBalAapl() internal view returns (uint256 b) {
        (,,,,, b,,,,,,) = aaplPair.pairVault();
    }

    /// @notice Penalty > bond: the slash is capped at the remaining bond; the bond zeroes out; a
    ///         second challenge on the same batch slashes nothing and does not revert.
    ///         With the 14× volume cap, omission liability alone maxes out at 7% × 14 = 98% of the
    ///         bond, so penalty-exceeds-bond is only reachable via the accepted stacking residual:
    ///         a stale challenge (1%) landing on the same batch as max omission (7%). The batch is
    ///         therefore falsely stale-labeled and slashed 1% first, before the omission challenge.
    function test_e2e_OmissionSlash_CappedAtBond_ThenZeroSlashNoRevert() public {
        // A second sequencer holding exactly MIN_BOND ($1,000 → $14k volume capacity).
        seq2 = makeAddr("seq2");
        usdc.mint(seq2, 1_000 * USDC_SCALE);
        vm.startPrank(seq2);
        usdc.approve(address(sequencer), 1_000 * USDC_SCALE);
        sequencer.deposit(1_000 * USDC_SCALE);
        vm.stopPrank();

        _depositAapl(alice, 20_000 * BAZAAR_SCALE);
        _depositAapl(bob, 20_000 * BAZAAR_SCALE);
        _depositAapl(carol, 60_000 * BAZAAR_SCALE);
        _depositAapl(dave, 60_000 * BAZAAR_SCALE);

        // Two aggressive, crossable longs that the sequencer will omit (Limit type — still
        // omission-challengeable in a stale batch, unlike Market/StopLoss).
        uint256 omitted1 = _placeLimitAapl(alice, true, 80 * BAZAAR_SCALE, 208 * BAZAAR_SCALE);
        uint256 omitted2 = _placeLimitAapl(bob, true, 80 * BAZAAR_SCALE, 207 * BAZAAR_SCALE);
        // Worse-priced pair the sequencer matches instead. Capacity truncates the fill to $14k.
        uint256 carolLong = _placeLimitAapl(carol, true, 100 * BAZAAR_SCALE, 204 * BAZAAR_SCALE);
        uint256 daveShort = _placeLimitAapl(dave, false, 100 * BAZAAR_SCALE, 196 * BAZAAR_SCALE);

        // Stale the price cache, then match with an empty update → the batch records isStale = true
        // (Pass C limit×limit still runs during stale).
        vm.warp(vm.getBlockTimestamp() + 30);
        _roll(2);
        vm.recordLogs();
        {
            uint64 obs = uint64(vm.getBlockNumber() - 1);
            vm.prank(seq2);
            assertEq(
                aaplPair.matchBatch(
                    _lists(_one(carolLong), _one(daveShort), _empty(), _empty()), 10, new bytes[](0), obs
                ),
                1,
                "matched"
            );
        }
        (uint256 batchId, BazaarTypes.BatchInfo memory info) = _captureBatch();
        assertTrue(info.isStale, "batch labeled stale");

        // A fresh tick DID exist 1s before the match, so the stale label was false: the stale
        // challenge lands first and slashes 1% of the batch notional (~$140), leaving ~$860.
        {
            bytes[] memory tick = _priceUpdateFor(AAPL_USD_FEED_ID, 200, uint64(info.matchTimestamp) - 1);
            address staleChallenger = makeAddr("bondCapStaleChallenger");
            vm.deal(staleChallenger, 1 ether);
            vm.prank(staleChallenger);
            sequencer.challengeStaleBatch{value: 0.05 ether}(address(aaplPair), batchId, info, tick);
        }

        // Censored notional (80 × $208 = $16.6k) vs matched (~$14k): 7% of the min (~$980)
        // exceeds the stale-slashed remaining bond (~$860).
        uint256 censored = 80 * BAZAAR_SCALE * 208;
        uint256 base = censored < info.totalMatchNotional ? censored : info.totalMatchNotional;
        uint256 computedPenalty = base * sequencer.OMISSION_PENALTY_BP() / 10_000;
        uint256 bondBefore = sequencer.sequencerBonds(seq2);
        assertGt(computedPenalty, bondBefore, "scenario: computed penalty exceeds the bond");

        address challenger1 = makeAddr("bondCapChallenger1");
        uint256 insBefore = _insuranceBalAapl();
        vm.prank(challenger1);
        sequencer.challengeOmission(address(aaplPair), batchId, info, omitted1);

        // Slash capped at the whole remaining bond — not the computed 7%.
        assertEq(sequencer.sequencerBonds(seq2), 0, "bond fully consumed");
        uint256 challengerShare = bondBefore / 7;
        assertEq(usdc.balanceOf(challenger1), challengerShare / 1e12, "challenger paid from the capped amount");
        assertEq(
            _insuranceBalAapl() - insBefore, ((bondBefore - challengerShare) / 1e12) * 1e12, "insurance got the rest"
        );

        // Second omitted order, same batch: bond empty → slash 0, and crucially NO revert.
        address challenger2 = makeAddr("bondCapChallenger2");
        vm.prank(challenger2);
        sequencer.challengeOmission(address(aaplPair), batchId, info, omitted2);
        assertEq(sequencer.sequencerBonds(seq2), 0, "still zero, no underflow");
        assertEq(usdc.balanceOf(challenger2), 0, "nothing left to pay the second challenger");

        // --- Fix 3: the zero-value slash above must NOT have consumed the (batch, omitted2) key. ---
        // The slash collected 0 purely because the bond was empty (cap room still remained), so the
        // proven omission stays chargeable. Re-bond seq2 and re-challenge omitted2: it must still slash.
        // A pre-fix build burned the key on the zero-slash, making this revert AlreadyChallenged.
        usdc.mint(seq2, 1_000 * USDC_SCALE);
        vm.startPrank(seq2);
        usdc.approve(address(sequencer), 1_000 * USDC_SCALE);
        sequencer.deposit(1_000 * USDC_SCALE);
        vm.stopPrank();

        uint256 bondAfterRebond = sequencer.sequencerBonds(seq2);
        address challenger3 = makeAddr("bondCapChallenger3");
        vm.prank(challenger3);
        sequencer.challengeOmission(address(aaplPair), batchId, info, omitted2);
        assertLt(
            sequencer.sequencerBonds(seq2),
            bondAfterRebond,
            "re-challenge slashed the re-bonded stake - key was left open"
        );

        // That nonzero slash finally consumes the key: a further challenge now reverts.
        vm.prank(challenger3);
        vm.expectRevert(BazaarSequencer.Sequencer__AlreadyChallenged.selector);
        sequencer.challengeOmission(address(aaplPair), batchId, info, omitted2);
    }
}
