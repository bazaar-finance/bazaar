// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {LiquidationLib} from "../../src/libraries/LiquidationLib.sol";

/// @dev Extends the NettingHarness pattern with full read-back getters and batch liquidation, so
///      LiquidationLib's aggregate bookkeeping (netting arms, funding merge, bankruptcy notional,
///      OI floors) can be asserted directly instead of only seeded.
contract BookkeepingHarness {
    mapping(uint256 => BazaarTypes.Order) public orders;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;
    BazaarTypes.Vault public vault;

    function setBucket(
        address user,
        bool isLong,
        uint256 size,
        uint256 entryValue,
        uint256 collateral,
        int256 entryFundingIndex
    ) external {
        BazaarTypes.PositionBucket storage b = positionBuckets[user];
        b.isLong = isLong;
        b.size = size;
        b.entryValue = entryValue;
        b.collateral = collateral;
        b.entryFundingIndex = entryFundingIndex;
    }

    function seedCollateral(uint256 amount) external {
        vault.totalCollateralDeposited = amount;
    }

    function seedInsurance(uint256 amount) external {
        vault.insuranceFundBalance = amount;
    }

    function seedOI(uint256 longOI, uint256 shortOI, uint256 longSum, uint256 shortSum) external {
        vault.totalLongOI = longOI;
        vault.totalShortOI = shortOI;
        vault.longWeightedEntrySum = longSum;
        vault.shortWeightedEntrySum = shortSum;
    }

    function seedPending(
        bool isLong,
        uint256 size,
        uint256 entryNotional,
        uint256 bankruptcyNotional,
        int256 entryFundingIndex
    ) external {
        vault.pendingLiqSize = size;
        vault.pendingLiqEntryNotional = entryNotional;
        vault.pendingLiqBankruptcyNotional = bankruptcyNotional;
        vault.pendingLiqEntryFundingIndex = entryFundingIndex;
        vault.pendingLiqIsLong = isLong;
    }

    function liquidate(address[] calldata users, uint256 price, int256 fundingIndex)
        external
        returns (BazaarTypes.LiquidateResult memory)
    {
        return LiquidationLib.processLiquidations(
            users,
            orders,
            positionBuckets,
            vault,
            BazaarTypes.LiquidateParams({
                currentPrice: price,
                currentFundingIndex: fundingIndex,
                marginReqs: BazaarTypes.MarginRequirements({imrBp: 300, mmrBp: 150, lastUpdateTs: 0, laggedMmrBp: 0}),
                pairId: bytes32("TEST"),
                currentBlock: 1,
                usdc: address(0) // reward payment no-ops (soft-fail restores the debit)
            })
        );
    }

    // read-backs
    function pendingSize() external view returns (uint256) {
        return vault.pendingLiqSize;
    }

    function pendingEntry() external view returns (uint256) {
        return vault.pendingLiqEntryNotional;
    }

    function pendingBankruptcy() external view returns (uint256) {
        return vault.pendingLiqBankruptcyNotional;
    }

    function pendingFundingIdx() external view returns (int256) {
        return vault.pendingLiqEntryFundingIndex;
    }

    function depositsLedger() external view returns (uint256) {
        return vault.totalCollateralDeposited;
    }

    function pendingIsLong() external view returns (bool) {
        return vault.pendingLiqIsLong;
    }

    function insurance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function longOI() external view returns (uint256) {
        return vault.totalLongOI;
    }

    function longSum() external view returns (uint256) {
        return vault.longWeightedEntrySum;
    }

    function bucketSize(address u) external view returns (uint256) {
        return positionBuckets[u].size;
    }
}

/// @notice Read-back tests for LiquidationLib's aggregate bookkeeping — the values every downstream
///         consumer (ADL settlement price, Check-1 exposure, Pass-A close PnL) depends on. Seeding
///         these values directly proves nothing about the merge arithmetic that produces them, so
///         each one is asserted after a real processLiquidations call.
contract LiquidationBookkeepingTest is Test {
    uint256 constant SCALE = 1e18;
    uint256 constant PRICE = 50_000e18;

    BookkeepingHarness h;
    address victim = makeAddr("victim");

    function setUp() public {
        h = new BookkeepingHarness();
        vm.warp(1_700_000_000);
        h.seedCollateral(1_000_000e18);
        h.seedInsurance(5_000e18);
    }

    function _arr(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    // ---------------- opposing netting: partial-reduce ----------------

    /// @notice New opposing liquidation smaller than the aggregate: proportional reduce, same side.
    function test_netting_partialReduce_keepsSideAndProrates() public {
        // Vault long 2 units, entry $50k/u, bankruptcy $48k/u.
        h.seedPending(true, 2 * SCALE, 100_000e18, 96_000e18, 0);
        // Opposing short 1 unit entered $49k, $10 collateral -> insolvent at $50k.
        h.setBucket(victim, false, 1 * SCALE, 49_000e18, 10e18, 0);

        h.liquidate(_arr(victim), PRICE, 0);

        assertEq(h.pendingSize(), 1 * SCALE, "half the aggregate remains");
        assertTrue(h.pendingIsLong(), "side unchanged");
        assertEq(h.pendingEntry(), 50_000e18, "entry notional halved");
        assertEq(h.pendingBankruptcy(), 48_000e18, "bankruptcy notional halved");
        // netPnl = newEntryPortion(49k) - existingPortion(50k) = -1k; seizure +10.
        assertEq(h.insurance(), 5_000e18 + 10e18 - 1_000e18, "net loss absorbed, collateral seized");
        // The loss is an I -> D TRANSFER (backing for the survivors' offsetting realized gains),
        // net of the -10 seizure transfer in the other direction.
        assertEq(h.depositsLedger(), 1_000_000e18 - 10e18 + 1_000e18, "deposits ledger credited by the netting loss");
    }

    // ---------------- opposing netting: direction flip ----------------

    /// @notice New opposing liquidation larger than the aggregate: existing fully netted, the
    ///         remainder flips the side with proportional notionals and the new victim's ENTRY
    ///         funding index (== current here, since the victim's own funding is zeroed).
    function test_netting_flip_remainderTakesOverWithProportionalNotionals() public {
        h.seedPending(true, 1 * SCALE, 50_000e18, 48_000e18, 0);
        // Opposing short 3 units entered $49k/u, $10 collateral, own funding zeroed (entryIdx == current).
        int256 currentIdx = 7e18;
        h.setBucket(victim, false, 3 * SCALE, 147_000e18, 10e18, currentIdx);

        h.liquidate(_arr(victim), PRICE, currentIdx);

        assertEq(h.pendingSize(), 2 * SCALE, "remainder after netting 1 against 1");
        assertFalse(h.pendingIsLong(), "side flipped to the new position's side");
        uint256 expectedEntry = uint256(147_000e18) * 2 / 3;
        assertEq(h.pendingEntry(), expectedEntry, "remainder entry prorated from the new position");
        // Victim bankruptcy notional = entry + effColl + fundingPnl = 147,010; remainder = 2/3 of it.
        uint256 expectedBk = uint256(147_010e18) * 2 / 3;
        assertEq(h.pendingBankruptcy(), expectedBk, "remainder bankruptcy prorated");
        assertEq(h.pendingFundingIdx(), currentIdx, "flip stamps the new funding index");
        // Insurance: +10 seizure, -1,000 net entry PnL, -7 realized vault funding on the netted unit.
        assertEq(h.insurance(), 5_000e18 + 10e18 - 1_000e18 - 7e18, "netting PnL + funding realized");
        // Mirror transfer into the deposits ledger (loss = 1,007), net of the -10 seizure.
        assertEq(h.depositsLedger(), 1_000_000e18 - 10e18 + 1_007e18, "deposits ledger credited by the netting loss");
    }

    // ---------------- same-side merge: weighted funding index ----------------

    /// @notice Same-side aggregate merge takes the size-weighted average of the funding indices.
    function test_merge_sameSide_weightedFundingIndex() public {
        h.seedPending(true, 1 * SCALE, 50_000e18, 48_000e18, 0);
        int256 currentIdx = 100e18;
        // Second underwater long, own funding zeroed.
        h.setBucket(victim, true, 1 * SCALE, 55_000e18, 10e18, currentIdx);

        h.liquidate(_arr(victim), PRICE, currentIdx);

        assertEq(h.pendingSize(), 2 * SCALE, "sizes added");
        assertEq(h.pendingFundingIdx(), 50e18, "size-weighted merge (0x1 + 100x1)/2");
        assertEq(h.pendingEntry(), 105_000e18, "entry notionals added");
        // Victim bankruptcy = 55,000 - 10 (collateral) - 0 (funding) = 54,990.
        assertEq(h.pendingBankruptcy(), 48_000e18 + 54_990e18, "bankruptcy notionals added");
    }

    /// @notice The weighted merge preserves sign with negative funding indices.
    function test_merge_sameSide_negativeFundingIndex() public {
        h.seedPending(true, 1 * SCALE, 50_000e18, 48_000e18, 0);
        int256 currentIdx = -100e18;
        h.setBucket(victim, true, 1 * SCALE, 55_000e18, 10e18, currentIdx);

        h.liquidate(_arr(victim), PRICE, currentIdx);
        assertEq(h.pendingFundingIdx(), -50e18, "signed weighted merge");
    }

    // ---------------- bankruptcy price read-back ----------------

    /// @notice Long bankruptcy notional = entryValue - collateral - fundingPnl, read back after a
    ///         real liquidation, so the subtraction is under test rather than a seeded value.
    function test_bankruptcy_long_entryMinusCollateral() public {
        // entry $50,500, collateral $600: equity 100 < minRequired (1.5% of 50k = 750) -> insolvent.
        h.setBucket(victim, true, 1 * SCALE, 50_500e18, 600e18, 0);

        h.liquidate(_arr(victim), PRICE, 0);

        assertEq(h.pendingBankruptcy(), 49_900e18, "bk = entry - seized collateral");
        assertEq(h.pendingSize(), 1 * SCALE);
        assertTrue(h.pendingIsLong());
        assertEq(h.insurance(), 5_000e18 + 600e18, "full collateral seized to insurance");
    }

    /// @notice The funding term enters the long bankruptcy formula with a negative sign.
    function test_bankruptcy_long_includesFundingTerm() public {
        // Funding rose 50 (long pays): fundingPnl = -50 -> bk = 50,500 - 600 - (-50) = 49,950.
        h.setBucket(victim, true, 1 * SCALE, 50_500e18, 600e18, 0);
        h.liquidate(_arr(victim), PRICE, 50e18);
        assertEq(h.pendingBankruptcy(), 49_950e18, "funding folds into the bankruptcy notional");
    }

    /// @notice A non-positive short numerator clamps the bankruptcy price to zero instead of
    ///         underflowing.
    function test_bankruptcy_short_numeratorClampsAtZero() public {
        // Short entered at $100 with funding pnl -200: numerator = 100 + 0 + (-200) <= 0 -> bk 0.
        h.setBucket(victim, false, 1 * SCALE, 100e18, 0, 200e18);
        h.liquidate(_arr(victim), PRICE, 0);
        assertEq(h.pendingBankruptcy(), 0, "clamped to zero");
        assertEq(h.pendingSize(), 1 * SCALE, "position still inherited");
    }

    // ---------------- victim filtering ----------------

    /// @notice Solvent and flat users in a liquidation batch are skipped untouched.
    function test_batch_skipsSolventAndFlatVictims() public {
        address solvent = makeAddr("solvent");
        address flat = makeAddr("flat");
        h.setBucket(solvent, true, 1 * SCALE, 50_000e18, 5_000e18, 0); // equity 5k >= 750
        h.setBucket(victim, true, 1 * SCALE, 50_500e18, 600e18, 0); // insolvent

        address[] memory users = new address[](3);
        users[0] = solvent;
        users[1] = victim;
        users[2] = flat;
        BazaarTypes.LiquidateResult memory r = h.liquidate(users, PRICE, 0);

        assertEq(r.liquidatedCount, 1, "only the insolvent victim liquidated");
        assertEq(h.bucketSize(solvent), 1 * SCALE, "solvent bucket untouched");
        assertEq(h.bucketSize(victim), 0, "insolvent bucket reset");
    }

    /// @notice A zero-collateral insolvent victim still liquidates: nothing seized, and the
    ///         unconditional liquidator reward accrues at the bps rate (above the $0.10 floor).
    function test_zeroCollateralVictim_liquidatesWithBpsReward() public {
        h.setBucket(victim, true, 1 * SCALE, 55_000e18, 0, 0);

        uint256 insBefore = h.insurance();
        BazaarTypes.LiquidateResult memory r = h.liquidate(_arr(victim), PRICE, 0);

        assertEq(r.liquidatedCount, 1);
        assertEq(h.insurance(), insBefore, "nothing to seize");
        // notional 50k x 200 EBP / 1e6 = $10 > $0.10 floor
        uint256 expected = 50_000e18 * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
        assertEq(r.totalUpfrontReward, expected, "bps reward on notional");
        assertGt(expected, BazaarTypes.MIN_LIQUIDATOR_REWARD, "sanity: above the floor");
    }

    // ---------------- OI decrement floors ----------------

    /// @notice OI decrements floor at zero when the aggregate under-counts the victim's size —
    ///         drift is masked rather than reverting the liquidation.
    function test_oiDecrement_floorsAtZeroInsteadOfUnderflowing() public {
        h.seedOI(SCALE / 2, 0, 1_000e18, 0); // long OI smaller than the victim's 1e18
        h.setBucket(victim, true, 1 * SCALE, 55_000e18, 10e18, 0);

        BazaarTypes.LiquidateResult memory r = h.liquidate(_arr(victim), PRICE, 0);

        assertEq(r.liquidatedCount, 1, "liquidation not blocked by OI drift");
        assertEq(h.longOI(), 0, "floored, not underflowed");
        assertEq(h.longSum(), 0, "weighted sum floored");
    }
}
