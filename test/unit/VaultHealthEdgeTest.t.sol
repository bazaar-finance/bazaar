// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {VaultHealthLib} from "../../src/libraries/VaultHealthLib.sol";

contract VaultHealthEdgeHarness {
    BazaarTypes.Vault public vault;
    mapping(address => BazaarTypes.PositionBucket) buckets;
    address[] deferred;

    function seed(bool isLong, uint256 size, uint256 bankruptcyNotional, uint256 insurance) external {
        vault.pendingLiqSize = size;
        vault.pendingLiqBankruptcyNotional = bankruptcyNotional;
        vault.pendingLiqEntryNotional = bankruptcyNotional;
        vault.pendingLiqIsLong = isLong;
        vault.insuranceFundBalance = insurance;
    }

    /// @dev List `user` as a deferred liquidation: `size` units from `entryNotional` on `collateral`.
    function defer(address user, bool isLong, uint256 size, uint256 entryNotional, uint256 collateral) external {
        BazaarTypes.PositionBucket storage b = buckets[user];
        b.isLong = isLong;
        b.size = uint128(size);
        b.entryValue = uint128(entryNotional);
        b.collateral = uint128(collateral);
        deferred.push(user);
    }

    /// @dev Warmup MMR. The band is capped at 5%, so on the one-unit inventory the tests seed the
    ///      band edge sits $2,500 from the $50k oracle.
    uint256 constant MMR_BP = 1_000;

    function check(uint256 price, bool isAdlPending, uint256 adlPendingSince, uint256 snapshotPrice, bool adlLongs)
        external
        returns (VaultHealthLib.LiqExposureResult memory)
    {
        return VaultHealthLib.checkLiqExposure(
            vault,
            buckets,
            deferred,
            price,
            isAdlPending,
            adlPendingSince,
            snapshotPrice,
            adlLongs,
            int256(0),
            int256(0),
            MMR_BP
        );
    }
}

/// @notice Pins the ADL gate's two levels, which side a deferred liquidation has to sit on to
///         count, and the 24h ADL-timeout boundary — the exact levels at which trading freezes,
///         stays frozen, and finally escalates to termination.
contract VaultHealthEdgeTest is Test {
    uint256 constant SCALE = 1e18;
    uint256 constant PRICE = 50_000e18;
    uint256 constant FUND = 10_000e18;
    address constant LISTED = address(0xD1);
    VaultHealthEdgeHarness h;

    function setUp() public {
        h = new VaultHealthEdgeHarness();
        vm.warp(1_700_000_000);
    }

    /// @dev Vault long 1 unit, nothing earmarked and no target cached, so the base is the whole
    ///      $10k fund: expected loss = bankruptcyNotional − currentNotional, and finishing the
    ///      unit at the band edge costs that loss plus $2,500.
    function _seedLoss(uint256 loss) internal {
        h.seed(true, 1 * SCALE, PRICE + loss, FUND);
    }

    /// @notice The hysteresis band: a $9,000 loss is healthy when NOT pending (under the $10,000
    ///         base) but unhealthy when pending (finishing at the band edge would cost $11,500) —
    ///         same state, different phase.
    function test_hysteresis_lossInsideTheBandDependsOnPhase() public {
        _seedLoss(9_000e18);
        VaultHealthLib.LiqExposureResult memory quiet = h.check(PRICE, false, 0, 0, false);
        assertTrue(quiet.healthy, "$9,000 under the $10,000 base: no ADL");
        assertFalse(quiet.newIsAdlPending, "not triggered");

        VaultHealthLib.LiqExposureResult memory pending =
            h.check(PRICE, true, block.timestamp - 5 minutes, PRICE, false);
        assertFalse(pending.healthy, "$11,500 to finish at the band edge: ADL persists");
        assertTrue(pending.newIsAdlPending, "stays pending");
    }

    /// @notice Past the base, ADL turns on with the snapshot and opposite-side targeting.
    function test_hysteresis_lossPastBaseTriggersAdl() public {
        _seedLoss(10_001e18);
        VaultHealthLib.LiqExposureResult memory r = h.check(PRICE, false, 0, 0, false);
        assertFalse(r.healthy, "over the trigger");
        assertTrue(r.newIsAdlPending, "ADL triggered");
        assertEq(r.newAdlPendingSince, block.timestamp, "auction clock started");
        assertEq(r.newAdlSnapshotPrice, PRICE, "snapshot at trigger price");
        assertFalse(r.newAdlLongs, "deleverage the side OPPOSITE the vault's long");
    }

    /// @notice A pending ADL clears once the base could finish the remainder at the band edge:
    ///         $7,499 of loss plus $2,500 fits under $10,000, $7,501 does not.
    function test_hysteresis_releaseOnceTheBandEdgeFits() public {
        _seedLoss(7_499e18);
        VaultHealthLib.LiqExposureResult memory r = h.check(PRICE, true, block.timestamp - 5 minutes, PRICE, false);
        assertTrue(r.healthy, "the band edge fits under the base");
        assertFalse(r.newIsAdlPending, "ADL cleared");

        _seedLoss(7_501e18);
        r = h.check(PRICE, true, block.timestamp - 5 minutes, PRICE, false);
        assertFalse(r.healthy, "$2 over: the band edge no longer fits");
        assertTrue(r.newIsAdlPending, "stays pending");
    }

    /// @notice With no capital above the reserve, a pending ADL still clears once the inventory
    ///         sits above water by more than the band: finishing it costs nothing.
    function test_hysteresis_noBase_releasesOnlyAboveWaterBeyondTheBand() public {
        h.seed(true, 1 * SCALE, PRICE - 3_000e18, 0); // bankruptcy $3,000 under the oracle, no fund
        VaultHealthLib.LiqExposureResult memory r = h.check(PRICE, true, block.timestamp - 5 minutes, PRICE, false);
        assertTrue(r.healthy, "band edge $2,500 under the oracle: finishing costs nothing");
        assertFalse(r.newIsAdlPending, "ADL cleared");

        h.seed(true, 1 * SCALE, PRICE - 2_000e18, 0);
        r = h.check(PRICE, true, block.timestamp - 5 minutes, PRICE, false);
        assertFalse(r.healthy, "$500 to finish at the band edge and nothing to pay it with");
        assertTrue(r.newIsAdlPending, "stays pending");
    }

    // ---------------- deferred liquidations: which side the gate counts ----------------

    /// @dev One listed short from $40k on $5,000: $10,000 under water at the $50k oracle, so
    ///      $5,000 of loss its collateral does not cover.
    function _listUnderwaterShort() internal {
        h.defer(LISTED, false, 1 * SCALE, 40_000e18, 5_000e18);
    }

    /// @notice A listed account opposite the inventory holds the window: its uncovered loss is
    ///         exposure no earmark backs, whatever the inventory reads. The inventory here is
    ///         $1,000 under water against a $10,000 base, so the window is the listed account's.
    function test_deferredGate_oppositeSideAccountLatchesTheWindow() public {
        _seedLoss(1_000e18);
        _listUnderwaterShort();

        VaultHealthLib.LiqExposureResult memory quiet = h.check(PRICE, false, 0, 0, false);
        assertFalse(quiet.healthy, "the listed short's $5,000 of uncovered loss opens the window");
        assertTrue(quiet.newIsAdlPending, "triggered");
        assertFalse(quiet.newAdlLongs, "aimed at the shorts, opposite the long inventory");

        VaultHealthLib.LiqExposureResult memory pending =
            h.check(PRICE, true, block.timestamp - 5 minutes, PRICE, false);
        assertFalse(pending.healthy, "and holds it");
        assertTrue(pending.newIsAdlPending, "stays pending");
    }

    /// @notice The same account on the inventory's own side holds nothing. A netting flipped the
    ///         inventory short, so no cohort closes the listed short through the window, and the
    ///         next liquidation that names it seizes it into the inventory instead. The gate
    ///         skips it, and a window the inventory alone does not need releases.
    function test_deferredGate_sameSideAccountDoesNotLatchTheWindow() public {
        h.seed(false, 1 * SCALE, PRICE - 1_000e18, FUND); // short inventory, $1,000 under water
        _listUnderwaterShort();

        VaultHealthLib.LiqExposureResult memory quiet = h.check(PRICE, false, 0, 0, false);
        assertTrue(quiet.healthy, "a same-side listed account opens nothing");
        assertFalse(quiet.newIsAdlPending, "not triggered");

        // A window aimed at the shorts before the flip releases rather than re-targeting.
        VaultHealthLib.LiqExposureResult memory pending =
            h.check(PRICE, true, block.timestamp - 5 minutes, PRICE, false);
        assertTrue(pending.healthy, "nothing holds the window");
        assertFalse(pending.newIsAdlPending, "released");
    }

    /// @notice The 24h timeout is strict: one second past fires, exactly at the boundary does not.
    function test_timeout_boundaryIsStrict() public {
        _seedLoss(9_000e18); // the band edge does not fit -> the pending branch (where the timeout lives) runs

        VaultHealthLib.LiqExposureResult memory atBoundary =
            h.check(PRICE, true, block.timestamp - VaultHealthLib.ADL_TIMEOUT_DURATION, PRICE, false);
        assertFalse(atBoundary.adlTimeoutExpired, "exactly 24h: not yet expired");

        VaultHealthLib.LiqExposureResult memory past =
            h.check(PRICE, true, block.timestamp - VaultHealthLib.ADL_TIMEOUT_DURATION - 1, PRICE, false);
        assertTrue(past.adlTimeoutExpired, "24h + 1s: escalate to termination");
    }
}
