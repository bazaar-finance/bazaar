// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {VaultHealthLib} from "../../src/libraries/VaultHealthLib.sol";

contract VaultHealthEdgeHarness {
    BazaarTypes.Vault public vault;

    function seed(bool isLong, uint256 size, uint256 bankruptcyNotional, uint256 insurance) external {
        vault.pendingLiqSize = size;
        vault.pendingLiqBankruptcyNotional = bankruptcyNotional;
        vault.pendingLiqEntryNotional = bankruptcyNotional;
        vault.pendingLiqIsLong = isLong;
        vault.insuranceFundBalance = insurance;
    }

    function check(uint256 price, bool isAdlPending, uint256 adlPendingSince, uint256 snapshotPrice, bool adlLongs)
        external
        returns (VaultHealthLib.LiqExposureResult memory)
    {
        return VaultHealthLib.checkLiqExposure(
            vault, price, isAdlPending, adlPendingSince, snapshotPrice, adlLongs, int256(0), int256(0)
        );
    }
}

/// @notice Pins the 80/60 hysteresis band and the 24h ADL-timeout boundary — the exact levels at
///         which trading freezes, stays frozen, and finally escalates to termination.
contract VaultHealthEdgeTest is Test {
    uint256 constant SCALE = 1e18;
    uint256 constant PRICE = 50_000e18;
    VaultHealthEdgeHarness h;

    function setUp() public {
        h = new VaultHealthEdgeHarness();
        vm.warp(1_700_000_000);
    }

    /// @dev Vault long 1 unit: expected loss = bankruptcyNotional - currentNotional.
    function _seedLoss(uint256 loss) internal {
        h.seed(true, 1 * SCALE, PRICE + loss, 1_000e18); // insurance $1k
    }

    /// @notice The hysteresis band: a ~70% loss is healthy when NOT pending (below the 80% trigger)
    ///         but unhealthy when pending (above the 60% cancel) — same state, different phase.
    function test_hysteresis_70PercentLossDependsOnPhase() public {
        _seedLoss(700e18);
        VaultHealthLib.LiqExposureResult memory quiet = h.check(PRICE, false, 0, 0, false);
        assertTrue(quiet.healthy, "70% below the 80% trigger: no ADL");
        assertFalse(quiet.newIsAdlPending, "not triggered");

        VaultHealthLib.LiqExposureResult memory pending =
            h.check(PRICE, true, block.timestamp - 5 minutes, PRICE, false);
        assertFalse(pending.healthy, "70% above the 60% cancel: ADL persists");
        assertTrue(pending.newIsAdlPending, "stays pending");
    }

    /// @notice Above the 80% trigger, ADL turns on with the snapshot and opposite-side targeting.
    function test_hysteresis_81PercentTriggersAdl() public {
        _seedLoss(810e18);
        VaultHealthLib.LiqExposureResult memory r = h.check(PRICE, false, 0, 0, false);
        assertFalse(r.healthy, "over the trigger");
        assertTrue(r.newIsAdlPending, "ADL triggered");
        assertEq(r.newAdlPendingSince, block.timestamp, "auction clock started");
        assertEq(r.newAdlSnapshotPrice, PRICE, "snapshot at trigger price");
        assertFalse(r.newAdlLongs, "deleverage the side OPPOSITE the vault's long");
    }

    /// @notice Below the 60% cancel threshold a pending ADL clears.
    function test_hysteresis_59PercentCancelsPendingAdl() public {
        _seedLoss(590e18);
        VaultHealthLib.LiqExposureResult memory r = h.check(PRICE, true, block.timestamp - 5 minutes, PRICE, false);
        assertTrue(r.healthy, "under the cancel threshold");
        assertFalse(r.newIsAdlPending, "ADL cleared");
    }

    /// @notice The 24h timeout is strict: one second past fires, exactly at the boundary does not.
    function test_timeout_boundaryIsStrict() public {
        _seedLoss(700e18); // above cancel -> the pending branch (where the timeout lives) runs

        VaultHealthLib.LiqExposureResult memory atBoundary =
            h.check(PRICE, true, block.timestamp - VaultHealthLib.ADL_TIMEOUT_DURATION, PRICE, false);
        assertFalse(atBoundary.adlTimeoutExpired, "exactly 24h: not yet expired");

        VaultHealthLib.LiqExposureResult memory past =
            h.check(PRICE, true, block.timestamp - VaultHealthLib.ADL_TIMEOUT_DURATION - 1, PRICE, false);
        assertTrue(past.adlTimeoutExpired, "24h + 1s: escalate to termination");
    }
}
