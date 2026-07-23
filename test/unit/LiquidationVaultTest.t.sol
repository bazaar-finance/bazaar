// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.34;

// Consolidated: liquidator reward, vault funding netting, ADL guard, vault health, transfer safety.
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BazaarFactory} from "../../src/BazaarFactory.sol";
import {BazaarPair} from "../../src/BazaarPair.sol";
import {BazaarTypes} from "../../src/libraries/BazaarTypes.sol";
import {AdlLib} from "../../src/libraries/AdlLib.sol";
import {LiquidationLib} from "../../src/libraries/LiquidationLib.sol";
import {VaultHealthLib} from "../../src/libraries/VaultHealthLib.sol";
import {DeployBazaar} from "../../script/DeployBazaar.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

// ==================== from LiquidatorRewardTest.t.sol ====================

/// @notice Harness owning its own vault/bucket state and forwarding into LiquidationLib,
///         so the per-position reward math can be unit-tested without a full BazaarPair.
contract LiqRewardHarness {
    mapping(uint256 => BazaarTypes.Order) public orders;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;
    BazaarTypes.Vault public vault;

    function setBucket(address user, bool isLong, uint256 size, uint256 entryValue, uint256 collateral) external {
        BazaarTypes.PositionBucket storage b = positionBuckets[user];
        b.isLong = isLong;
        b.size = size;
        b.entryValue = entryValue;
        b.collateral = collateral;
    }

    /// @dev Seed totalCollateralDeposited so the per-position seizure (`-= collateral`) doesn't underflow.
    function seedCollateral(uint256 amount) external {
        vault.totalCollateralDeposited = amount;
    }

    function liquidate(address[] calldata users, uint256 price) external returns (BazaarTypes.LiquidateResult memory) {
        return LiquidationLib.processLiquidations(
            users,
            orders,
            positionBuckets,
            vault,
            BazaarTypes.LiquidateParams({
                currentPrice: price,
                currentFundingIndex: 0,
                marginReqs: BazaarTypes.MarginRequirements({imrBp: 300, mmrBp: 150, lastUpdateTs: 0, laggedMmrBp: 0}),
                pairId: bytes32("TEST"),
                currentBlock: 1,
                usdc: address(0) // reward payment no-ops (soft-fail restores the debit)
            })
        );
    }

    function pendingLiqSize() external view returns (uint256) {
        return vault.pendingLiqSize;
    }
}

/// @notice Unit tests for the unconditional liquidator reward:
///         reward per position = max($0.10 floor, 2bps × notional), summed across the batch,
///         paid at liquidation time with no profit-contingent (secondary) component.
contract LiquidatorRewardTest is Test {
    uint256 internal constant FLOOR = 1e17; // 0.10 USDC
    uint256 internal constant PRICE = 50_000e18; // $50,000

    LiqRewardHarness internal harness;

    function setUp() public {
        harness = new LiqRewardHarness();
        harness.seedCollateral(1_000_000e18);
    }

    /// @dev A long position of `size` BTC, entered `cushionBp` above PRICE with `collateral`,
    ///      so it is underwater at PRICE. Entry slightly above spot guarantees a loss.
    function _long(address user, uint256 size, uint256 entryPrice, uint256 collateral) internal {
        harness.setBucket(user, true, size, Math_mulDiv(size, entryPrice, 1e18), collateral);
    }

    function _liq(address user, uint256 price) internal returns (BazaarTypes.LiquidateResult memory) {
        address[] memory users = new address[](1);
        users[0] = user;
        return harness.liquidate(users, price);
    }

    // -------------------- Floor vs bps --------------------

    /// @notice $5,000 notional → 2bps = $1.00 > $0.10 floor → reward is the bps term.
    function test_largePosition_paysBps() public {
        _long(alice(), 0.1e18, 50_050e18, 10e18); // 0.1 BTC, ~$5,005 entry, $10 collateral
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1);
        assertEq(r.totalUpfrontReward, 1e18, "2bps of $5,000 = $1.00");
    }

    /// @notice $50 notional → 2bps = $0.01 < $0.10 floor → reward is the floor.
    function test_smallPosition_paysFloor() public {
        _long(alice(), 0.001e18, 50_050e18, 0.1e18); // 0.001 BTC, ~$50 notional
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1);
        assertEq(r.totalUpfrontReward, FLOOR, "below breakeven pays the 0.10 floor");
    }

    /// @notice $500 notional is the exact breakeven: 2bps × $500 = $0.10 = floor.
    function test_breakevenPosition_floorEqualsBps() public {
        _long(alice(), 0.01e18, 50_050e18, 1e18); // 0.01 BTC, $500 notional
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.totalUpfrontReward, FLOOR, "at $500 the floor and 2bps coincide");
    }

    // -------------------- Batch summation --------------------

    function test_batchSumsPerPositionRewards() public {
        _long(alice(), 0.1e18, 50_050e18, 10e18); // large → $1.00
        _long(dave(), 0.001e18, 50_050e18, 0.1e18); // small → $0.10

        address[] memory users = new address[](2);
        users[0] = alice();
        users[1] = dave();
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 2);
        assertEq(r.totalUpfrontReward, 1e18 + FLOOR, "reward is summed per position");
    }

    // -------------------- Reward is independent of how the position nets --------------------

    /// @notice Opposite-direction liquidations fully net the aggregate to zero, but each still
    ///         earns its reward — the reward is for the act of liquidating, not the close.
    function test_oppositeNetting_stillPaysBothRewards() public {
        _long(alice(), 0.1e18, 55_000e18, 100e18); // long underwater at $50k
        harness.setBucket(dave(), false, 0.1e18, Math_mulDiv(0.1e18, 45_500e18, 1e18), 100e18); // short underwater

        address[] memory users = new address[](2);
        users[0] = alice();
        users[1] = dave();
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 2);
        assertEq(harness.pendingLiqSize(), 0, "equal opposite sizes fully net");
        // Both $5,000 notional → $1.00 each, paid despite the aggregate netting to zero.
        assertEq(r.totalUpfrontReward, 2e18, "netting does not suppress the per-position reward");
    }

    // -------------------- Helpers --------------------

    function Math_mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return a * b / d;
    }

    function alice() internal returns (address) {
        return makeAddr("alice");
    }

    function dave() internal returns (address) {
        return makeAddr("dave");
    }
}

// ==================== from VaultFundingNettingTest.t.sol ====================

/// @notice Harness that pre-seeds the vault's pending-liquidation aggregate so the
///         opposing-liquidation NETTING path can be exercised in isolation. The funding
///         index is settable per liquidate() call, which the LiquidatorRewardTest harness
///         (hardcoded to 0) cannot do.
contract NettingHarness {
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

    /// @dev Simulate the vault already holding an inventory of liquidated positions on one side,
    ///      entered at funding index `entryFundingIndex`.
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

    function liquidate(address user, uint256 price, int256 fundingIndex)
        external
        returns (BazaarTypes.LiquidateResult memory)
    {
        address[] memory users = new address[](1);
        users[0] = user;
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

    function insuranceFundBalance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function pendingLiqSize() external view returns (uint256) {
        return vault.pendingLiqSize;
    }

    function deficit() external view returns (uint256) {
        return vault.deficit;
    }
}

/// @notice Verifies that when an opposing liquidation NETS against the vault's inherited
///         inventory, the funding the vault accrued on the netted portion over its holding
///         window is realized into the insurance fund — keeping funding zero-sum on the
///         netting path, symmetric with the Pass-A vault close.
///
///         Construction isolates the funding term: the opposing position carries the SAME
///         entry notional as the netted inventory, so the price component of the net PnL is
///         exactly zero. The only insurance movements are then (a) the opposing position's
///         seized collateral and (b) the realized vault funding on the netted size. The
///         post-H2 funding index carries the price factor, so the funding term is USD-scaled.
contract VaultFundingNettingTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant PRICE = 50_000e18;
    uint256 internal constant SIZE = 1e18; // 1 unit
    uint256 internal constant BASE_INSURANCE = 1_000e18;
    uint256 internal constant SEIZED_COLLATERAL = 10e18;

    NettingHarness internal h;

    function setUp() public {
        h = new NettingHarness();
        h.seedCollateral(1_000_000e18);
        h.seedInsurance(BASE_INSURANCE);
    }

    function _mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return a * b / d;
    }

    // ----- Vault holds a LONG inventory; funding rose → vault (as long) PAYS → insurance falls -----

    function test_nettingLongInventory_realizesFundingOutflow() public {
        // Opposing SHORT entered at $49k (underwater at $50k), same entry notional as the inventory.
        uint256 entryNotional = _mulDiv(SIZE, 49_000e18, SCALE);
        int256 entryIdx = 0;
        int256 currentIdx = 100e18; // price-scaled funding accumulation over the holding window

        h.seedPending(true, SIZE, entryNotional, _mulDiv(SIZE, 48_000e18, SCALE), entryIdx);
        // Short's own entry funding index == current → its own funding PnL is zero, isolating
        // the vault-inventory funding under test.
        h.setBucket(dave(), false, SIZE, entryNotional, SEIZED_COLLATERAL, currentIdx);

        h.liquidate(dave(), PRICE, currentIdx);

        assertEq(h.pendingLiqSize(), 0, "equal opposite sizes fully net");

        uint256 nettedFunding = uint256(currentIdx - entryIdx) * SIZE / SCALE; // 100e18
        // base + seized - funding (long pays when funding rises); price netPnl == 0
        uint256 expected = BASE_INSURANCE + SEIZED_COLLATERAL - nettedFunding;
        assertEq(h.insuranceFundBalance(), expected, "long-inventory funding realized as outflow");
    }

    // ----- Vault holds a SHORT inventory; funding rose → vault (as short) RECEIVES → insurance rises -----

    function test_nettingShortInventory_realizesFundingInflow() public {
        // Opposing LONG entered at $51k (underwater at $50k), same entry notional as the inventory.
        uint256 entryNotional = _mulDiv(SIZE, 51_000e18, SCALE);
        int256 entryIdx = 0;
        int256 currentIdx = 100e18;

        h.seedPending(false, SIZE, entryNotional, _mulDiv(SIZE, 52_000e18, SCALE), entryIdx);
        h.setBucket(dave(), true, SIZE, entryNotional, SEIZED_COLLATERAL, currentIdx);

        h.liquidate(dave(), PRICE, currentIdx);

        assertEq(h.pendingLiqSize(), 0, "equal opposite sizes fully net");

        uint256 nettedFunding = uint256(currentIdx - entryIdx) * SIZE / SCALE; // 100e18
        // base + seized + funding (short receives when funding rises); price netPnl == 0
        uint256 expected = BASE_INSURANCE + SEIZED_COLLATERAL + nettedFunding;
        assertEq(h.insuranceFundBalance(), expected, "short-inventory funding realized as inflow");
    }

    // ----- Control: no funding delta → no funding adjustment (only seizure + zero price PnL) -----

    function test_nettingNoFundingDelta_noAdjustment() public {
        uint256 entryNotional = _mulDiv(SIZE, 49_000e18, SCALE);
        int256 idx = 0; // entry index == current index → zero funding delta

        h.seedPending(true, SIZE, entryNotional, _mulDiv(SIZE, 48_000e18, SCALE), idx);
        h.setBucket(dave(), false, SIZE, entryNotional, SEIZED_COLLATERAL, idx);

        h.liquidate(dave(), PRICE, idx);

        assertEq(h.pendingLiqSize(), 0, "equal opposite sizes fully net");
        // base + seized only; price netPnl == 0 and funding delta == 0
        assertEq(h.insuranceFundBalance(), BASE_INSURANCE + SEIZED_COLLATERAL, "no funding term when delta is zero");
    }

    function dave() internal returns (address) {
        return makeAddr("dave");
    }

    // ----- Deficit recording: netting loss overruns insurance -> realized bad debt tracked -----

    /// @notice When an opposing liquidation's netting loss exceeds the insurance fund, the overrun
    ///         is recorded as `vault.deficit` (and insurance floors to 0). A non-zero deficit is the
    ///         definitive insolvency signal that isVaultHealthy terminates on.
    function test_nettingOverrunsInsurance_recordsDeficit() public {
        // Vault holds a long inherited at $60k entry (underwater at $50k).
        h.seedPending(true, SIZE, 60_000 * SCALE, 58_000 * SCALE, 0);
        // Insurance only $4k.
        h.seedInsurance(4_000 * SCALE);

        // Opposing short entered at $48k with $1k collateral -> insolvent at $50k (loss $2k > $1k).
        h.setBucket(dave(), false, SIZE, 48_000 * SCALE, 1_000 * SCALE, 0);

        h.liquidate(dave(), PRICE, 0);

        assertEq(h.pendingLiqSize(), 0, "equal opposite sizes fully net");
        assertEq(h.insuranceFundBalance(), 0, "insurance wiped by the netting loss");
        // Short's $1k collateral is seized into insurance first (4k -> 5k), then the $12k netting
        // loss (60k entry vs 48k) overruns it: deficit = 12k - 5k = 7k.
        assertEq(h.deficit(), 7_000 * SCALE, "overrun recorded as realized deficit");
    }
}

// ==================== from Phase3AdlGuardTest.t.sol ====================

/// @notice Harness that owns its own ADL state and forwards into AdlLib.executeAdlCore.
///         Lets us construct edge-case bucket states (size > 0, collateral = 0) without
///         standing up a full BazaarPair.
contract AdlHarness {
    mapping(uint256 => BazaarTypes.Order) public orders;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;
    BazaarTypes.Vault public vault;

    function setBucket(address user, bool isLong, uint256 size, uint256 entryValue, uint256 collateral) external {
        BazaarTypes.PositionBucket storage b = positionBuckets[user];
        b.isLong = isLong;
        b.size = size;
        b.entryValue = entryValue;
        b.collateral = collateral;
    }

    function setPendingLiq(uint256 size, uint256 bankruptcyNotional, bool isLong) external {
        vault.pendingLiqSize = size;
        vault.pendingLiqBankruptcyNotional = bankruptcyNotional;
        vault.pendingLiqIsLong = isLong;
        vault.pendingLiqEntryNotional = bankruptcyNotional;
    }

    function setVaultInsurance(uint256 insuranceFundBalance) external {
        vault.insuranceFundBalance = insuranceFundBalance;
    }

    function setVaultCollateral(uint256 totalCollateralDeposited) external {
        vault.totalCollateralDeposited = totalCollateralDeposited;
    }

    // -------- accounting accessors for conservation tests --------
    function vaultInsurance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function vaultCollateral() external view returns (uint256) {
        return vault.totalCollateralDeposited;
    }

    function bucketCollateral(address u) external view returns (uint256) {
        return positionBuckets[u].collateral;
    }

    /// @dev Seed OI fields so the ADL close-path doesn't underflow when decrementing them.
    function setOI(
        uint256 totalLongOI,
        uint256 totalShortOI,
        uint256 longWeightedEntrySum,
        uint256 shortWeightedEntrySum
    ) external {
        vault.totalLongOI = totalLongOI;
        vault.totalShortOI = totalShortOI;
        vault.longWeightedEntrySum = longWeightedEntrySum;
        vault.shortWeightedEntrySum = shortWeightedEntrySum;
    }

    // -------- ADL window-deposit state (epoch-tagged score freeze) --------
    uint64 public adlEpoch;
    mapping(address => uint64) internal adlDepositEpoch;
    mapping(address => uint256) internal adlWindowDeposits;

    function execAdl(address[] calldata winners, BazaarTypes.AdlParams calldata params)
        external
        returns (BazaarTypes.AdlResult memory)
    {
        return AdlLib.executeAdlCore(
            orders, positionBuckets, vault, winners, params, adlEpoch, adlDepositEpoch, adlWindowDeposits
        );
    }
}

/// @notice Zero-collateral winners in ADL. Historically: first a Panic(0x12) div-by-zero,
///         then a `continue` skip — which made a winner who withdrew ALL collateral
///         (allowed: the equity gate passes on unrealized PnL alone) ADL-IMMUNE, the exact
///         opposite of intent. Current semantics: score collateral floors at 1 wei, so a
///         pure-profit account ranks effectively infinite and is closed FIRST, with its
///         credit computed on its real (zero) collateral.
contract Phase3AdlGuardTest is Test {
    AdlHarness harness;
    uint256 constant SCALE = 1e18;

    address constant BAD_USER = address(0xBAD);

    function setUp() public {
        harness = new AdlHarness();
        // Warp far enough forward that `block.timestamp - 15 minutes` doesn't underflow.
        vm.warp(1_700_000_000);
    }

    // Canonical scenario throughout: LONGS got liquidated (vault holds longs), so the
    // deleverage side is the opposite — the winning SHORTS (adlLongs = false).
    function _params() internal view returns (BazaarTypes.AdlParams memory) {
        return BazaarTypes.AdlParams({
            adlLongs: false,
            adlSnapshotPrice: 100 * SCALE,
            adlSnapshotFundingIndex: 0,
            adlPendingSince: block.timestamp - 15 minutes, // ADL_AUCTION_DURATION → threshold = 1
            currentPrice: 100 * SCALE,
            currentFundingIndex: 0,
            marginRequirements: BazaarTypes.MarginRequirements({
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0
            }),
            pairId: bytes32(uint256(0xBAB)),
            adlId: 0,
            currentBlock: uint64(block.number)
        });
    }

    /// @notice A zero-collateral winner no longer panics OR gets skipped: it scores on the
    ///         1-wei floor (effectively infinite), is closed, and its credit is its PnL on
    ///         its real (zero) collateral.
    function test_ZeroCollateral_WinnerClosedNotSkipped() public {
        harness.setPendingLiq({size: 1 * SCALE, bankruptcyNotional: 100 * SCALE, isLong: true});
        harness.setOI({
            totalLongOI: 0, totalShortOI: 1 * SCALE, longWeightedEntrySum: 0, shortWeightedEntrySum: 150 * SCALE
        });
        harness.setVaultInsurance(1_000 * SCALE);
        harness.setVaultCollateral(1_000 * SCALE);

        // Short winner: size = 1, entry = $150, collateral = 0 (everything withdrawn on
        // unrealized-PnL equity). At snapshot $100: totalPnl = $50 → score floors to max.
        harness.setBucket({user: BAD_USER, isLong: false, size: 1 * SCALE, entryValue: 150 * SCALE, collateral: 0});

        address[] memory winners = new address[](1);
        winners[0] = BAD_USER;

        BazaarTypes.AdlResult memory r = harness.execAdl(winners, _params());
        assertEq(r.eligibleCount, 1, "pure-profit winner is eligible, not skipped");
        assertEq(r.totalLiqSize, 1 * SCALE, "closed in full");
        assertEq(harness.bucketCollateral(BAD_USER), 50 * SCALE, "credit = PnL on real (zero) collateral");
        assertEq(harness.vaultInsurance(), 1_000 * SCALE - 50 * SCALE, "credit funded from insurance");
    }

    /// @notice Zero-collateral winner ranks FIRST (descending-score order) ahead of a normal
    ///         winner, and both are processed.
    function test_ZeroCollateral_RanksFirst_BothProcessed() public {
        address validUser = address(0xC001);

        harness.setPendingLiq({size: 2 * SCALE, bankruptcyNotional: 200 * SCALE, isLong: true});
        // Seed short-side OI matching the winners so the close-path's OI decrement doesn't underflow.
        harness.setOI({
            totalLongOI: 0, totalShortOI: 2 * SCALE, longWeightedEntrySum: 0, shortWeightedEntrySum: 300 * SCALE
        });
        harness.setVaultInsurance(1_000 * SCALE);
        harness.setVaultCollateral(1_000 * SCALE);

        // Pure-profit winner (short): size > 0, collateral = 0 → floored score (max).
        harness.setBucket({user: BAD_USER, isLong: false, size: 1 * SCALE, entryValue: 150 * SCALE, collateral: 0});
        // Normal winner (short): $50 pnl on $10 collateral → score 5e18.
        harness.setBucket({
            user: validUser, isLong: false, size: 1 * SCALE, entryValue: 150 * SCALE, collateral: 10 * SCALE
        });

        // Descending score order requires the pure-profit winner FIRST.
        address[] memory winners = new address[](2);
        winners[0] = BAD_USER;
        winners[1] = validUser;

        BazaarTypes.AdlResult memory r = harness.execAdl(winners, _params());
        assertEq(r.eligibleCount, 2, "both winners eligible");
        assertEq(r.totalLiqSize, 2 * SCALE, "both closed");
        assertEq(harness.bucketCollateral(BAD_USER), 50 * SCALE, "pure-profit credit = pnl");
        assertEq(harness.bucketCollateral(validUser), 60 * SCALE, "normal credit = collateral + pnl");
    }

    /// @notice 5.3 (R2-5): mid-batch health check is now functional. When closing a subset of
    ///         winners restores vault health, the early-break fires and remaining winners
    ///         are spared. Setup: 6 winners, all with positive PnL. Insurance fund is sized
    ///         so that closing 3 brings exposure below the 60% cancel threshold.
    function test_EarlyBreak_SparesRemainingWinnersWhenHealthRestored() public {
        // Long-side liq: vault inherited longs at bankruptcy $200; current price = $150 →
        // per-unit exposure = $50. Six total units of pending liq. Winners are shorts.
        harness.setPendingLiq({size: 6 * SCALE, bankruptcyNotional: 1_200 * SCALE, isLong: true});
        harness.setOI({
            totalLongOI: 0, totalShortOI: 6 * SCALE, longWeightedEntrySum: 0, shortWeightedEntrySum: 1_200 * SCALE
        });

        // Insurance: needs to be just large enough that closing 3 units (= $150 exposure
        // remaining = 3 × ($200 - $150)) drops the running expectedLoss below 60% cancel threshold.
        // Initial exposure = 6 × $50 = $300. After closing 3 units = $150. We want
        // cancel threshold = 60% × insurance >= $150 → insurance >= $250.
        // Pick insurance = $260 so we're comfortably past the threshold after 3 closes.
        BazaarTypes.Vault memory _v;
        _v.insuranceFundBalance = 260 * SCALE;
        // Apply via setOI which doesn't touch insurance; use raw write via inline:
        harness.setVaultInsurance(260 * SCALE);

        // Six valid short winners, each with 1-unit position, $200 entry, $10 collateral —
        // positive PnL at the $150 snapshot ($50/unit).
        address[] memory winners = new address[](6);
        for (uint256 i = 0; i < 6; i++) {
            address w = address(uint160(uint256(keccak256(abi.encode("winner", i)))));
            harness.setBucket({
                user: w, isLong: false, size: 1 * SCALE, entryValue: 200 * SCALE, collateral: 10 * SCALE
            });
            winners[i] = w;
        }

        // currentPrice at snapshot equals adlSnapshotPrice = $100 (per default params), which
        // is below bankruptcy $200 — vault is in loss → ADL pending state makes sense.
        // Use a modified params where currentPrice = $150 so loss = 3 × $50 = $150 after 3 closes.
        BazaarTypes.AdlParams memory p = _params();
        p.currentPrice = 150 * SCALE;
        p.adlSnapshotPrice = 150 * SCALE;

        BazaarTypes.AdlResult memory r = harness.execAdl(winners, p);

        // Six winners eligible, but only 3 should have actually closed via the early-break.
        // (The check fires at closedCount % 3 == 0 → after winner 3.)
        // r.eligibleSize reflects Pass 1's read of all six.
        // r.totalLiqSize reflects the actual loop closed amount, which must be < 6 if early-break fired.
        assertEq(r.eligibleSize, 6 * SCALE, "all six pre-qualified");
        assertLt(r.totalLiqSize, 6 * SCALE, "early break spared some winners");
        assertGe(r.totalLiqSize, 3 * SCALE, "at least 3 closed (the iteration before the check)");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║   ADL ACCOUNTING CONSERVATION — winner PnL funded by insurance ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @dev Canonical funded-winner scenario: vault inherited longs at bankruptcy $200
    ///      (settlement price), one short winner entered at $250 (so +$50 PnL when settled
    ///      at $200), profitable at the $150 snapshot. Returns the winner address.
    function _setupFundedWinner(uint256 insurance, uint256 collateralTracked) internal returns (address winner) {
        harness.setPendingLiq({size: 1 * SCALE, bankruptcyNotional: 200 * SCALE, isLong: true});
        harness.setOI({
            totalLongOI: 0, totalShortOI: 1 * SCALE, longWeightedEntrySum: 0, shortWeightedEntrySum: 250 * SCALE
        });
        harness.setVaultInsurance(insurance);
        harness.setVaultCollateral(collateralTracked);

        winner = address(0xBEEF);
        harness.setBucket({
            user: winner, isLong: false, size: 1 * SCALE, entryValue: 250 * SCALE, collateral: 10 * SCALE
        });
    }

    function _fundedWinnerParams() internal view returns (BazaarTypes.AdlParams memory p) {
        p = _params();
        p.adlSnapshotPrice = 150 * SCALE; // short is +$100 here → eligible
        p.currentPrice = 150 * SCALE;
    }

    /// @notice The winner's realized PnL ($50, settled at the $200 bankruptcy price) is debited
    ///         from insurance and credited to totalCollateralDeposited, so the winner's bucket
    ///         can be withdrawn and `insurance + totalCollateralDeposited` is conserved.
    function test_Conservation_WinnerPnlFundedFromInsurance() public {
        address winner = _setupFundedWinner({insurance: 1_000 * SCALE, collateralTracked: 1_000 * SCALE});
        BazaarTypes.AdlParams memory p = _fundedWinnerParams();

        uint256 iBefore = harness.vaultInsurance();
        uint256 tBefore = harness.vaultCollateral();

        address[] memory winners = new address[](1);
        winners[0] = winner;
        harness.execAdl(winners, p);

        assertEq(iBefore - harness.vaultInsurance(), 50 * SCALE, "insurance funded the winner PnL");
        assertEq(harness.vaultCollateral() - tBefore, 50 * SCALE, "collateral tracking grew by the PnL");
        assertEq(harness.bucketCollateral(winner), 60 * SCALE, "winner credited entry collateral + PnL");
        assertEq(
            harness.vaultInsurance() + harness.vaultCollateral(),
            iBefore + tBefore,
            "insurance + totalCollateralDeposited conserved (Check-3 invariant holds)"
        );
    }

    /// @notice Insolvency tail: insurance ($20) can't cover the winner PnL ($50). The credit is
    ///         CAPPED at available insurance — the winner is haircut to $20, the position is still
    ///         fully closed, and `insurance + totalCollateralDeposited` stays conserved so the
    ///         pair remains solvent (no emergency termination).
    function test_Conservation_InsuranceShortfall_CapsWinnerKeepsSolvent() public {
        address winner = _setupFundedWinner({insurance: 20 * SCALE, collateralTracked: 1_000 * SCALE});
        BazaarTypes.AdlParams memory p = _fundedWinnerParams();

        uint256 sumBefore = harness.vaultInsurance() + harness.vaultCollateral();

        address[] memory winners = new address[](1);
        winners[0] = winner;
        harness.execAdl(winners, p); // must not revert; no termination needed

        assertEq(harness.vaultInsurance(), 0, "insurance fully drawn to fund what it can");
        assertEq(
            harness.vaultCollateral() - 1_000 * SCALE, 20 * SCALE, "collateral tracking grew only by the funded amount"
        );
        assertEq(harness.bucketCollateral(winner), 30 * SCALE, "winner capped at entry collateral $10 + funded $20");
        assertEq(
            harness.vaultInsurance() + harness.vaultCollateral(),
            sumBefore,
            "insurance + totalCollateralDeposited conserved - books stay solvent, no termination"
        );
    }

    /// @notice Direction regression: buckets on the SAME side as the liquidation (here longs,
    ///         since the vault holds longs) must never qualify as ADL winners, even with
    ///         positive PnL — only the opposite side gets deleveraged.
    function test_SameSideAsLiquidation_NeverEligible() public {
        harness.setPendingLiq({size: 1 * SCALE, bankruptcyNotional: 100 * SCALE, isLong: true});

        // A long that entered cheap enough to be in profit at the $100 snapshot.
        address cheapLong = address(0x10);
        harness.setBucket({
            user: cheapLong, isLong: true, size: 1 * SCALE, entryValue: 50 * SCALE, collateral: 10 * SCALE
        });

        address[] memory winners = new address[](1);
        winners[0] = cheapLong;

        vm.expectRevert(AdlLib.AdlLib__NoEligibleWinners.selector);
        harness.execAdl(winners, _params());
    }
}

// ==================== from Phase3VaultHealthTest.t.sol ====================

/// @notice Harness exposing VaultHealthLib.checkLiqExposure for direct testing.
contract VaultHealthHarness {
    BazaarTypes.Vault public vault;

    function setVault(
        uint256 insuranceFundBalance,
        uint256 pendingLiqSize,
        uint256 pendingLiqBankruptcyNotional,
        bool pendingLiqIsLong
    ) external {
        vault.insuranceFundBalance = insuranceFundBalance;
        vault.pendingLiqSize = pendingLiqSize;
        vault.pendingLiqBankruptcyNotional = pendingLiqBankruptcyNotional;
        vault.pendingLiqIsLong = pendingLiqIsLong;
    }

    function check(
        uint256 currentPrice,
        bool isAdlPending,
        uint256 adlPendingSince,
        uint256 adlSnapshotPrice,
        bool adlLongs
    ) external view returns (VaultHealthLib.LiqExposureResult memory) {
        return VaultHealthLib.checkLiqExposure(
            vault, currentPrice, isAdlPending, adlPendingSince, adlSnapshotPrice, adlLongs, int256(0), int256(0)
        );
    }
}

/// @notice Tests for the simplified vault expected-loss calculation: direct subtraction
///         of currentNotional from bankruptcyNotional, no 3% floor.
contract Phase3VaultHealthTest is Test {
    VaultHealthHarness h;
    uint256 constant SCALE = 1e18;

    function setUp() public {
        h = new VaultHealthHarness();
    }

    /// @notice Long-side loss: B = $200, P = $100, size = 1 → loss = $100.
    function test_LongLiq_LossAtBelowBankruptcy() public {
        // size 1, bankruptcyNotional = 1 × $200 = $200
        h.setVault({
            insuranceFundBalance: 1_000_000 * SCALE, // huge so threshold not tripped
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 200 * SCALE,
            pendingLiqIsLong: true
        });
        // current price $100 → currentNotional = $100, loss = $200 - $100 = $100
        // ADL trigger threshold = 80% × 1M = $800k; $100 nowhere near, healthy=true.
        VaultHealthLib.LiqExposureResult memory r = h.check(100 * SCALE, false, 0, 0, false);
        assertTrue(r.healthy);
        assertFalse(r.newIsAdlPending);
    }

    /// @notice Short-side loss: B = $100, P = $200, size = 1 → loss = $100.
    function test_ShortLiq_LossAtAboveBankruptcy() public {
        h.setVault({
            insuranceFundBalance: 1_000_000 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE, // bankruptcy $100
            pendingLiqIsLong: false
        });
        // current price $200 → currentNotional = $200; short loses when current > bankruptcy.
        // loss = $200 - $100 = $100.
        VaultHealthLib.LiqExposureResult memory r = h.check(200 * SCALE, false, 0, 0, false);
        assertTrue(r.healthy);
    }

    /// @notice Vault long position in PROFIT (current > bankruptcy) → no loss, ADL not triggered.
    ///         Previously the 3% floor would have inflated expectedLoss to 3% × bankruptcyNotional
    ///         even though the vault is up money. Post-fix, expected loss is exactly 0.
    function test_LongLiq_AboveBankruptcy_NoExposure() public {
        // bankruptcy $100, current $150 — vault is in profit
        h.setVault({
            insuranceFundBalance: 1 * SCALE, // tiny — anything would trigger ADL
            pendingLiqSize: 10 * SCALE,
            pendingLiqBankruptcyNotional: 1_000 * SCALE, // 10 × $100
            pendingLiqIsLong: true
        });
        // Pre-fix would have computed: 3% floor × bankruptcyNotional × currentNotional/bankruptcyNotional
        //   = currentNotional × 3% = $1500 × 3% = $45 → exceeds 80% × $1 = $0.80 → ADL!
        // Post-fix: expectedLoss = 0 since current > bankruptcy → healthy.
        VaultHealthLib.LiqExposureResult memory r = h.check(150 * SCALE, false, 0, 0, false);
        assertTrue(r.healthy, "vault in profit, no exposure");
        assertFalse(r.newIsAdlPending, "ADL must not trigger");
    }

    /// @notice Compares against the old buggy math: pre-fix would have UNDER-reported loss
    ///         when current is far below bankruptcy. Verify the new math reports the FULL loss
    ///         so ADL triggers correctly in stressed markets.
    function test_LongLiq_DeepUnderwater_TriggersAdl() public {
        // bankruptcy $200, current $50 — vault deeply underwater
        // Real loss: 1 × ($200 - $50) = $150.
        // Pre-fix bug: currentNotional × gap / BP = $50 × 75% = $37.50 (off by P/B = 50/200 = 0.25)
        // Post-fix: $200 - $50 = $150
        h.setVault({
            insuranceFundBalance: 100 * SCALE, // small fund
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 200 * SCALE,
            pendingLiqIsLong: true
        });
        // ADL trigger = 80% × $100 = $80.
        // Pre-fix loss ($37.50) < $80 → ADL would NOT trigger (false negative — bug).
        // Post-fix loss ($150) > $80 → ADL DOES trigger.
        VaultHealthLib.LiqExposureResult memory r = h.check(50 * SCALE, false, 0, 0, false);
        assertFalse(r.healthy, "deep underwater must trigger ADL");
        assertTrue(r.newIsAdlPending);
        assertFalse(r.newAdlLongs); // vault inherited longs → deleverage the winning shorts
    }

    /// @notice Regression: the ADL deleverage side must be OPPOSITE the liquidated side.
    ///         Pre-fix, newAdlLongs copied pendingLiqIsLong, so the winner scan filtered to
    ///         the losing side and executeAdl always reverted "No eligible winners" —
    ///         every ADL event timed out into emergency termination.
    function test_AdlTrigger_DeleverageSideOppositeLiquidatedSide() public {
        // Shorts liquidated (price spiked): bankruptcy $100, current $200, loss = $100
        // vs trigger threshold 80% × $50 = $40 → ADL triggers.
        h.setVault({
            insuranceFundBalance: 50 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE,
            pendingLiqIsLong: false
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(200 * SCALE, false, 0, 0, false);
        assertTrue(r.newIsAdlPending);
        assertTrue(r.newAdlLongs, "shorts liquidated -> deleverage the winning longs");
    }

    /// @notice With the floor removed: a vault that's at break-even (current ≈ bankruptcy) and
    ///         a tiny insurance fund must NOT trigger ADL. Pre-fix, the 3% floor would have
    ///         tripped it; post-fix, expectedLoss = 0 → healthy.
    function test_NoFloor_BreakEven_NoFalseAdl() public {
        // bankruptcy = $100, current = $100 — exactly break-even
        h.setVault({
            insuranceFundBalance: 1 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE,
            pendingLiqIsLong: true
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(100 * SCALE, false, 0, 0, false);
        assertTrue(r.healthy, "no floor: break-even is healthy regardless of fund size");
        assertFalse(r.newIsAdlPending);
    }

    /// @notice Mid-auction vault-side flip: ADL triggered on a long-side liquidation
    ///         (adlLongs = false, deleverage shorts), then opposing short liquidations
    ///         overwhelmed the aggregate via netting — the vault now holds SHORTS.
    ///         The pending check must re-target the winners (longs) and re-snapshot the
    ///         price, while preserving adlPendingSince (24h termination clock is monotone).
    function test_MidAuctionFlip_RetargetsAndResnapshots_ClockPreserved() public {
        vm.warp(1_700_000_000);
        uint256 since = block.timestamp - 1 hours;
        uint256 staleSnapshot = 50 * SCALE; // frozen at the original crash

        // Post-flip aggregate: vault holds shorts, bankruptcy $100, current $200 →
        // loss = $100 > cancel threshold 60% × $100 = $60 → ADL still necessary.
        h.setVault({
            insuranceFundBalance: 100 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE,
            pendingLiqIsLong: false
        });
        // adlLongs = false == pendingLiqIsLong → direction conflict detected.
        VaultHealthLib.LiqExposureResult memory r = h.check(200 * SCALE, true, since, staleSnapshot, false);
        assertFalse(r.healthy);
        assertTrue(r.newIsAdlPending, "still pending - exposure above cancel threshold");
        assertTrue(r.newAdlLongs, "re-targeted: vault holds shorts -> deleverage longs");
        assertEq(r.newAdlSnapshotPrice, 200 * SCALE, "snapshot refreshed to current price");
        assertEq(r.newAdlPendingSince, since, "termination clock NOT reset");
        assertFalse(r.adlTimeoutExpired);
    }

    /// @notice Consistent direction while pending: no conflict → snapshot and side untouched.
    function test_PendingNoFlip_StateUntouched() public {
        vm.warp(1_700_000_000);
        uint256 since = block.timestamp - 1 hours;
        uint256 snapshot = 50 * SCALE;

        // Vault holds shorts, adlLongs = true (deleverage longs) — consistent.
        h.setVault({
            insuranceFundBalance: 100 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE,
            pendingLiqIsLong: false
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(200 * SCALE, true, since, snapshot, true);
        assertTrue(r.newIsAdlPending);
        assertTrue(r.newAdlLongs, "direction unchanged");
        assertEq(r.newAdlSnapshotPrice, snapshot, "snapshot stays frozen");
        assertEq(r.newAdlPendingSince, since, "clock unchanged");
    }

    /// @notice Flip where the netted remainder no longer threatens the fund: ADL is
    ///         cancelled outright — necessity is re-evaluated before any re-targeting.
    function test_MidAuctionFlip_ExposureResolved_AdlCancelled() public {
        vm.warp(1_700_000_000);
        uint256 since = block.timestamp - 1 hours;

        // Vault holds shorts, bankruptcy $100, current $110 → loss = $10,
        // well under cancel threshold 60% × $1000 = $600.
        h.setVault({
            insuranceFundBalance: 1_000 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE,
            pendingLiqIsLong: false
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(110 * SCALE, true, since, 50 * SCALE, false);
        assertTrue(r.healthy);
        assertFalse(r.newIsAdlPending, "ADL no longer necessary - cleared");
        assertEq(r.newAdlPendingSince, 0);
        assertEq(r.newAdlSnapshotPrice, 0);
    }
}

// ==================== from Phase1TransferSafetyTest.t.sol ====================

/// @notice Regression tests for Phase 1 (R1-1): unsafe ERC20 return-value handling.
///         Uses vm.mockCall to make USDC.transfer / transferFrom return `false` silently
///         (instead of reverting). Before the SafeERC20 migration, the bare-`.call` pattern
///         would treat this as success. After: the call must revert.
contract Phase1TransferSafetyTest is Test {
    bytes32 constant BTC_USD_FEED_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    uint256 constant USDC_SCALE = 1e6;
    uint256 constant BAZAAR_SCALE = 1e18;
    uint256 constant PROPOSAL_TOTAL = 5_000 * BAZAAR_SCALE;
    uint256 constant PROPOSAL_TOTAL_USDC = 5_000 * USDC_SCALE;

    BazaarFactory factory;
    BazaarPair pair;
    MockUSDC usdc;
    address user;

    function setUp() public {
        user = makeAddr("user");

        vm.etch(address(0x64), address(new MockArbSys()).code);

        DeployBazaar dep = new DeployBazaar();
        HelperConfig helperConfig;
        (factory, helperConfig) = dep.deploy(makeAddr("bugBounty"));

        (, address usdcAddr,,) = helperConfig.activeNetworkConfig();
        usdc = MockUSDC(usdcAddr);

        address deployer = makeAddr("deployer");
        usdc.mint(deployer, PROPOSAL_TOTAL_USDC);
        vm.startPrank(deployer);
        usdc.approve(address(factory), PROPOSAL_TOTAL_USDC);
        bytes32 assertionId = factory.proposePairDeployment(BTC_USD_FEED_ID, true, PROPOSAL_TOTAL, "BTC/USD");
        vm.stopPrank();

        vm.warp(block.timestamp + factory.DEPLOYMENT_LIVENESS() + 1);
        factory.settleDeploymentProposal(assertionId);
        (,,,,,, bytes32 pairId,,,) = factory.deploymentProposals(assertionId);
        pair = BazaarPair(payable(factory.getPairAddress(pairId)));

        usdc.mint(user, 1_000 * USDC_SCALE);
    }

    /// @notice Pre-fix behavior would have silently succeeded; post-fix the deposit must revert
    ///         because SafeERC20 detects the `false` return value from transferFrom.
    function test_depositCollateral_SilentFailingTransferFrom_Reverts() public {
        uint256 amount = 100 * BAZAAR_SCALE;

        vm.prank(user);
        usdc.approve(address(pair), amount * USDC_SCALE / BAZAAR_SCALE);

        // Make USDC.transferFrom return false silently for any args.
        vm.mockCall(address(usdc), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(false));

        vm.prank(user);
        vm.expectRevert(); // SafeERC20: revert without specific selector
        pair.depositCollateral(amount, 0, 0, 0, "", "");
    }

    /// @notice Same regression for withdrawCollateral path (contract → user transfer).
    function test_withdrawCollateral_SilentFailingTransfer_Reverts() public {
        uint256 amount = 100 * BAZAAR_SCALE;

        // Deposit first (normal flow)
        vm.prank(user);
        usdc.approve(address(pair), amount * USDC_SCALE / BAZAAR_SCALE);
        vm.prank(user);
        pair.depositCollateral(amount, 0, 0, 0, "", "");

        // Now make USDC.transfer return false silently
        vm.mockCall(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(false));

        bytes[] memory emptyPu = new bytes[](0);
        vm.prank(user);
        vm.expectRevert();
        pair.withdrawCollateral(amount / 2, emptyPu, 0, 0, 0, "");
    }
}
