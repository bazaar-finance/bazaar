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
import {PythSeed} from "../PythSeed.sol";

// ==================== liquidator reward ====================

/// @notice Harness owning its own vault/bucket state and forwarding into LiquidationLib,
///         so the per-position reward math can be unit-tested without a full BazaarPair.
contract LiqRewardHarness {
    mapping(uint256 => BazaarTypes.Order) public orders;
    BazaarTypes.OrderBook internal book;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;
    BazaarTypes.Vault public vault;
    BazaarTypes.FeeEscrow internal feeEscrow;

    /// @dev The liquidator's accrued reward (the lib credits msg.sender, i.e. the test contract).
    function claimable(address who) external view returns (uint256) {
        return feeEscrow.claimable[who];
    }

    function setBucket(address user, bool isLong, uint256 size, uint256 entryValue, uint256 collateral) external {
        BazaarTypes.PositionBucket storage b = positionBuckets[user];
        b.isLong = isLong;
        b.size = uint128(size);
        b.entryValue = uint128(entryValue);
        b.collateral = uint128(collateral);
    }

    /// @dev Seed totalCollateralDeposited. The seizure is capped at the deposits ledger, so
    ///      tests asserting a FULL seizure must seed at least the summed bucket collateral;
    ///      seeding less exercises the cap itself.
    function seedCollateral(uint256 amount) external {
        vault.totalCollateralDeposited = amount;
    }

    function deposits() external view returns (uint256) {
        return vault.totalCollateralDeposited;
    }

    /// @dev Seed free capital. The seizure a liquidation credits is earmarked against the
    ///      inventory it arrives with, so only what is seeded here can pay the reward.
    function seedInsurance(uint256 amount) external {
        vault.insuranceFundBalance = amount;
    }

    function insurance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function deficit() external view returns (uint256) {
        return vault.deficit;
    }

    function liquidate(address[] calldata users, uint256 price) external returns (BazaarTypes.LiquidateResult memory) {
        return LiquidationLib.processLiquidations(
            users,
            orders,
            book,
            positionBuckets,
            vault,
            feeEscrow,
            BazaarTypes.LiquidateParams({
                currentPrice: price,
                currentFundingIndex: 0,
                marginReqs: BazaarTypes.MarginRequirements({
                    imrBp: 300, mmrBp: 150, lastUpdateTs: 0, laggedMmrBp: 0, laggedMmrTs: 0
                }),
                pairId: bytes32("TEST"),
                currentBlock: 1
            })
        );
    }

    function pendingLiqSize() external view returns (uint256) {
        return vault.pendingLiqSize;
    }
}

/// @notice Unit tests for the liquidator reward:
///         reward per position = max($0.10 floor, 2bps × notional), summed across the batch,
///         capped at the fund's free capital, debited from insurance and accrued to the
///         liquidator's claimable balance at liquidation time, with no profit-contingent
///         (secondary) component.
contract LiquidatorRewardTest is Test {
    uint256 internal constant FLOOR = 1e17; // 0.10 USDC
    uint256 internal constant PRICE = 50_000e18; // $50,000

    LiqRewardHarness internal harness;

    function setUp() public {
        harness = new LiqRewardHarness();
        harness.seedCollateral(1_000_000e18);
        harness.seedInsurance(1_000e18); // free capital the reward is paid from
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
        assertEq(harness.claimable(address(this)), 1e18, "reward accrued to the liquidator's claimable balance");
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
        assertEq(harness.claimable(address(this)), 1e18 + FLOOR, "the batch total accrues in one credit");
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

    // -------------------- Capped at free capital --------------------

    /// @notice The seizure just credited is earmarked against the inventory it arrived with, so
    ///         it is not free capital: a fund holding nothing else pays no reward, and the earmark
    ///         reaches the books whole.
    function test_noFreeCapital_paysNothing_earmarkStaysWhole() public {
        harness = new LiqRewardHarness();
        harness.seedCollateral(1_000_000e18);
        _long(alice(), 0.1e18, 50_050e18, 10e18); // earns $1.00; seizes $10 into an empty fund
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1);
        assertEq(r.totalUpfrontReward, 0, "nothing accrued: the fund holds only the earmark");
        assertEq(harness.claimable(address(this)), 0, "nothing claimable");
        assertEq(harness.insurance(), 10e18, "the seizure sits in the fund untouched");
    }

    /// @notice Free capital short of the reward pays what it has, never more.
    function test_partialFreeCapital_paysTheCappedReward() public {
        harness = new LiqRewardHarness();
        harness.seedCollateral(1_000_000e18);
        harness.seedInsurance(0.4e18);
        _long(alice(), 0.1e18, 50_050e18, 10e18); // earns $1.00 against $0.40 of free capital
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.totalUpfrontReward, 0.4e18, "capped at free capital");
        assertEq(harness.claimable(address(this)), 0.4e18, "the capped amount accrued");
        assertEq(harness.insurance(), 10e18, "the earmark is whole: only the free $0.40 left the fund");
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

// ==================== seizure ledger cap ====================

/// @notice The liquidation seizure credits insurance with the liquidatee's book collateral
///         capped at totalCollateralDeposited. Winners realize gains into buckets without
///         touching the deposits ledger and withdraw them from it later, so a loser's book
///         collateral can legitimately exceed the entire remaining ledger — an uncapped
///         seizure would panic there and make the position unliquidatable.
contract SeizureLedgerClampTest is Test {
    uint256 internal constant PRICE = 50_000e18;

    LiqRewardHarness internal harness;
    address internal loser;
    address internal loser2;

    function setUp() public {
        harness = new LiqRewardHarness();
        loser = makeAddr("loser");
        loser2 = makeAddr("loser2");
    }

    /// @dev A long that is insolvent at PRICE: entry $65k on 1 unit → $15k loss against
    ///      `collateral` of book value.
    function _underwaterLong(address user, uint256 collateral) internal {
        harness.setBucket(user, true, 1e18, 65_000e18, collateral);
    }

    function _liq(address user) internal returns (BazaarTypes.LiquidateResult memory) {
        address[] memory users = new address[](1);
        users[0] = user;
        return harness.liquidate(users, PRICE);
    }

    /// @notice Book collateral above the whole ledger: liquidation succeeds, insurance is
    ///         credited exactly the ledger balance, the ledger floors at zero, and no
    ///         deficit is booked — settlement of the inherited estate decides solvency.
    function test_bucketAboveLedger_seizureCapsAndSucceeds() public {
        _underwaterLong(loser, 10_000e18);
        harness.seedCollateral(9_200e18);

        BazaarTypes.LiquidateResult memory r = _liq(loser);

        assertEq(r.liquidatedCount, 1, "liquidation must not revert on a thin ledger");
        assertEq(
            harness.insurance(),
            9_200e18 - r.totalUpfrontReward,
            "insurance receives the capped amount, less the reward"
        );
        assertEq(harness.deposits(), 0, "ledger floors at zero");
        assertEq(harness.deficit(), 0, "no deficit at seizure time");
        assertEq(harness.pendingLiqSize(), 1e18, "estate carries the full position");
    }

    /// @notice Ledger fully covers the book: the cap is inactive and the full collateral
    ///         moves to insurance.
    function test_ledgerCoversBook_fullSeizure() public {
        _underwaterLong(loser, 10_000e18);
        harness.seedCollateral(30_000e18);

        BazaarTypes.LiquidateResult memory r = _liq(loser);

        assertEq(harness.insurance(), 10_000e18 - r.totalUpfrontReward, "full book value seized, less the reward");
        assertEq(harness.deposits(), 20_000e18);
        assertEq(harness.deficit(), 0);
    }

    /// @notice A batch whose summed books exceed the ledger, though each position fits
    ///         alone: the first seizure takes its full book, the second is capped at the
    ///         remainder, and both liquidations commit.
    function test_batchCascade_capsAtRemainder() public {
        _underwaterLong(loser, 6_000e18);
        _underwaterLong(loser2, 6_000e18);
        harness.seedCollateral(9_000e18);

        address[] memory users = new address[](2);
        users[0] = loser;
        users[1] = loser2;
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 2, "the aggregate cap must not revert the batch");
        assertEq(harness.insurance(), 9_000e18 - r.totalUpfrontReward, "6,000 full + 3,000 capped, less the rewards");
        assertEq(harness.deposits(), 0);
        assertEq(harness.pendingLiqSize(), 2e18, "both estates on the books");
    }

    /// @notice An empty ledger seizes nothing but the liquidation still commits and the
    ///         estate is still recorded.
    function test_emptyLedger_liquidationStillCommits() public {
        _underwaterLong(loser, 10_000e18);
        harness.seedCollateral(0);

        BazaarTypes.LiquidateResult memory r = _liq(loser);

        assertEq(r.liquidatedCount, 1);
        assertEq(harness.insurance(), 0, "nothing attributable, nothing credited");
        assertEq(harness.claimable(address(this)), 0, "a reward the fund cannot cover is skipped, never partial");
        assertEq(harness.pendingLiqSize(), 1e18);
    }
}

// ==================== vault funding netting ====================

/// @notice Harness that pre-seeds the vault's pending-liquidation aggregate so the
///         opposing-liquidation NETTING path can be exercised in isolation. The funding
///         index is settable per liquidate() call, which the LiquidatorRewardTest harness
///         (hardcoded to 0) cannot do.
contract NettingHarness {
    mapping(uint256 => BazaarTypes.Order) public orders;
    BazaarTypes.OrderBook internal book;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;
    BazaarTypes.Vault public vault;
    BazaarTypes.FeeEscrow internal feeEscrow;

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
        b.size = uint128(size);
        b.entryValue = uint128(entryValue);
        b.collateral = uint128(collateral);
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
        // The gap between the two notionals is staged as the collateral seized with the inventory.
        vault.pendingLiqSeized = entryNotional > bankruptcyNotional
            ? entryNotional - bankruptcyNotional
            : bankruptcyNotional - entryNotional;
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
            book,
            positionBuckets,
            vault,
            feeEscrow,
            BazaarTypes.LiquidateParams({
                currentPrice: price,
                currentFundingIndex: fundingIndex,
                marginReqs: BazaarTypes.MarginRequirements({
                    imrBp: 300, mmrBp: 150, lastUpdateTs: 0, laggedMmrBp: 0, laggedMmrTs: 0
                }),
                pairId: bytes32("TEST"),
                currentBlock: 1
            })
        );
    }

    function insuranceFundBalance() external view returns (uint256) {
        return vault.insuranceFundBalance;
    }

    function claimable(address who) external view returns (uint256) {
        return feeEscrow.claimable[who];
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

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave(), PRICE, currentIdx);

        assertEq(h.pendingLiqSize(), 0, "equal opposite sizes fully net");

        uint256 nettedFunding = uint256(currentIdx - entryIdx) * SIZE / SCALE; // 100e18
        // base + seized - funding (long pays when funding rises) - liquidator reward; price netPnl == 0
        uint256 expected = BASE_INSURANCE + SEIZED_COLLATERAL - nettedFunding - r.totalUpfrontReward;
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

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave(), PRICE, currentIdx);

        assertEq(h.pendingLiqSize(), 0, "equal opposite sizes fully net");

        uint256 nettedFunding = uint256(currentIdx - entryIdx) * SIZE / SCALE; // 100e18
        // base + seized + funding (short receives when funding rises) - liquidator reward; price netPnl == 0
        uint256 expected = BASE_INSURANCE + SEIZED_COLLATERAL + nettedFunding - r.totalUpfrontReward;
        assertEq(h.insuranceFundBalance(), expected, "short-inventory funding realized as inflow");
    }

    // ----- Control: no funding delta → no funding adjustment (only seizure + zero price PnL) -----

    function test_nettingNoFundingDelta_noAdjustment() public {
        uint256 entryNotional = _mulDiv(SIZE, 49_000e18, SCALE);
        int256 idx = 0; // entry index == current index → zero funding delta

        h.seedPending(true, SIZE, entryNotional, _mulDiv(SIZE, 48_000e18, SCALE), idx);
        h.setBucket(dave(), false, SIZE, entryNotional, SEIZED_COLLATERAL, idx);

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave(), PRICE, idx);

        assertEq(h.pendingLiqSize(), 0, "equal opposite sizes fully net");
        // base + seized - liquidator reward only; price netPnl == 0 and funding delta == 0
        assertEq(
            h.insuranceFundBalance(),
            BASE_INSURANCE + SEIZED_COLLATERAL - r.totalUpfrontReward,
            "no funding term when delta is zero"
        );
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
        // The reward is judged after the netting: an emptied fund cannot pay it, so it is skipped.
        assertEq(h.claimable(address(this)), 0, "no reward from a wiped fund");
    }
}

// ==================== ADL execution guards ====================

/// @notice Harness that owns its own ADL state and forwards into AdlLib.executeAdlCore.
///         Lets us construct edge-case bucket states (size > 0, collateral = 0) without
///         standing up a full BazaarPair.
contract AdlHarness {
    mapping(uint256 => BazaarTypes.Order) public orders;
    BazaarTypes.OrderBook internal book;
    mapping(address => BazaarTypes.PositionBucket) public positionBuckets;
    BazaarTypes.Vault public vault;

    function setBucket(address user, bool isLong, uint256 size, uint256 entryValue, uint256 collateral) external {
        BazaarTypes.PositionBucket storage b = positionBuckets[user];
        b.isLong = isLong;
        b.size = uint128(size);
        b.entryValue = uint128(entryValue);
        b.collateral = uint128(collateral);
    }

    function setPendingLiq(uint256 size, uint256 bankruptcyNotional, bool isLong) external {
        vault.pendingLiqSize = size;
        vault.pendingLiqBankruptcyNotional = bankruptcyNotional;
        vault.pendingLiqIsLong = isLong;
        vault.pendingLiqEntryNotional = bankruptcyNotional;
        vault.pendingLiqSeized = 0;
    }

    /// @dev Stage an entry basis away from the bankruptcy notional: the gap is staged as the
    ///      collateral seized with the inventory.
    function setPendingLiqEntryNotional(uint256 x) external {
        vault.pendingLiqEntryNotional = x;
        uint256 bk = vault.pendingLiqBankruptcyNotional;
        vault.pendingLiqSeized = x > bk ? x - bk : bk - x;
    }

    function vaultDeficit() external view returns (uint256) {
        return vault.deficit;
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

    function bucketSize(address u) external view returns (uint256) {
        return positionBuckets[u].size;
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
            orders, book, positionBuckets, vault, winners, params, adlEpoch, adlDepositEpoch, adlWindowDeposits
        );
    }
}

/// @notice Zero-collateral winners in ADL. Score collateral floors at 1 wei: dividing by the raw
///         zero would Panic(0x12), and skipping the bucket instead would make a winner who
///         withdrew ALL collateral (allowed: the equity gate passes on unrealized PnL alone)
///         ADL-IMMUNE — the exact opposite of intent. With the floor a pure-profit account ranks
///         effectively infinite and is closed FIRST, with its credit computed on its real (zero)
///         collateral.
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
            adlAuctionStartTs: block.timestamp - 15 minutes, // ADL_AUCTION_DURATION → threshold = 1
            currentPrice: 100 * SCALE,
            currentFundingIndex: 0,
            marginRequirements: BazaarTypes.MarginRequirements({
                imrBp: 2_000, mmrBp: 1_000, lastUpdateTs: 0, laggedMmrBp: 0, laggedMmrTs: 0
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
        // Vault holds 2 units at bankruptcy $100/u, marked at $90 against a $10 fund: the size
        // that restores health exceeds the single unit this winner can cover, so the close is
        // bounded by the winner and not by the batch cap.
        harness.setPendingLiq({size: 2 * SCALE, bankruptcyNotional: 200 * SCALE, isLong: true});
        harness.setOI({
            totalLongOI: 0, totalShortOI: 1 * SCALE, longWeightedEntrySum: 0, shortWeightedEntrySum: 150 * SCALE
        });
        harness.setVaultInsurance(10 * SCALE);
        harness.setVaultCollateral(1_000 * SCALE);

        // Short winner: size = 1, entry = $150, collateral = 0 (everything withdrawn on
        // unrealized-PnL equity). At snapshot $100: totalPnl = $50 → score floors to max.
        harness.setBucket({user: BAD_USER, isLong: false, size: 1 * SCALE, entryValue: 150 * SCALE, collateral: 0});

        address[] memory winners = new address[](1);
        winners[0] = BAD_USER;

        BazaarTypes.AdlParams memory p = _params();
        p.currentPrice = 90 * SCALE; // below the bankruptcy price: the vault is in real loss

        BazaarTypes.AdlResult memory r = harness.execAdl(winners, p);
        assertEq(r.eligibleCount, 1, "pure-profit winner is eligible, not skipped");
        assertEq(r.totalLiqSize, 1 * SCALE, "closed in full");
        assertEq(harness.bucketCollateral(BAD_USER), 50 * SCALE, "credit = PnL on real (zero) collateral");
        assertEq(harness.vaultInsurance(), 10 * SCALE, "inventory closed at its own basis: insurance untouched");
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
        // An empty fund can finish nothing inside the band, so the size that restores health is
        // the whole $160 exposure: the batch cap leaves room for both closes.
        harness.setVaultInsurance(0);
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

        BazaarTypes.AdlParams memory p = _params();
        p.currentPrice = 20 * SCALE; // below the $100 bankruptcy price: the vault is in real loss

        BazaarTypes.AdlResult memory r = harness.execAdl(winners, p);
        assertEq(r.eligibleCount, 2, "both winners eligible");
        assertEq(r.totalLiqSize, 2 * SCALE, "both closed");
        assertEq(harness.bucketCollateral(BAD_USER), 50 * SCALE, "pure-profit credit = pnl");
        assertEq(harness.bucketCollateral(validUser), 60 * SCALE, "normal credit = collateral + pnl");
    }

    /// @notice The batch cap spares the winners the exposure does not need, and it stops at a
    ///         size rather than at a winner boundary: with 6 eligible units and the fund $85
    ///         short of what finishing them at the band edge would cost, 1.48 units close — the
    ///         second winner partially, the last four not at all. Rounding the stop up to whole
    ///         winners would deleverage the rest of the second for nothing.
    function test_BatchCap_SparesRemainingWinnersOnceTheFundIsRestored() public {
        // Long-side liq: vault inherited longs at bankruptcy $200; current price = $150 →
        // per-unit exposure = $50. Six total units of pending liq. Winners are shorts.
        harness.setPendingLiq({size: 6 * SCALE, bankruptcyNotional: 1_200 * SCALE, isLong: true});
        harness.setOI({
            totalLongOI: 0, totalShortOI: 6 * SCALE, longWeightedEntrySum: 0, shortWeightedEntrySum: 1_200 * SCALE
        });

        // Finishing the 6 units at the band edge ($142.50, the $150 mark less the 5% band) would
        // cost 6 × $57.50 = $345 against a $260 fund, none of it earmarked, so $85 must come off.
        // Each unit closed removes $57.50 of that and hands $0.05 of it to the executor, so the
        // cap lands at 85 / 57.45 = 1.48 units.
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

        // All six pre-qualify in the scan; the cap decides how much of that eligible size the
        // close pass actually consumes.
        assertEq(r.eligibleSize, 6 * SCALE, "all six pre-qualified");
        assertApproxEqRel(r.totalLiqSize, 1.479547e18, 0.0001e18, "$85 excess / $57.45 per unit");

        assertEq(harness.bucketSize(winners[0]), 0, "first winner closed in full");
        assertEq(harness.bucketSize(winners[1]), 2 * SCALE - r.totalLiqSize, "second closed only to the cap");
        assertEq(harness.bucketSize(winners[2]), 1 * SCALE, "third untouched");
        assertEq(harness.bucketSize(winners[3]), 1 * SCALE, "fourth untouched");
        assertEq(harness.bucketSize(winners[4]), 1 * SCALE, "fifth untouched");
        assertEq(harness.bucketSize(winners[5]), 1 * SCALE, "sixth untouched");
    }

    // ╔══════════════════════════════════════════════════════════════╗
    // ║   ADL ACCOUNTING CONSERVATION — inventory settled by insurance ║
    // ╚══════════════════════════════════════════════════════════════╝

    /// @dev Canonical scenario: the vault inherited 1 unit of longs, estate entry $250 and
    ///      bankruptcy $200 (a $50 seizure sitting in the fund), one short winner entered at
    ///      $250 with $10 collateral (+$50 at the $200 settlement), profitable at the $150
    ///      snapshot. Returns the winner address.
    function _setupFundedWinner(uint256 insurance, uint256 collateralTracked) internal returns (address winner) {
        harness.setPendingLiq({size: 1 * SCALE, bankruptcyNotional: 200 * SCALE, isLong: true});
        harness.setPendingLiqEntryNotional(250 * SCALE);
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

    /// @notice The inventory slice realizes its loss from the estate's entry to the settlement
    ///         price ($200 − $250 = −$50, exactly the seizure) as an I → D transfer, and the
    ///         winner is credited their full $50 PnL. The two coincide here because the winner
    ///         entered at the estate's entry; `insurance + totalCollateralDeposited` is conserved.
    function test_Conservation_VaultLossReturnsSeizureToLedger() public {
        // The fund holds exactly the $50 it seized off the estate and no free capital, so the
        // size that restores health is the whole unit and the winner closes in full.
        address winner = _setupFundedWinner({insurance: 50 * SCALE, collateralTracked: 1_000 * SCALE});
        BazaarTypes.AdlParams memory p = _fundedWinnerParams();

        uint256 iBefore = harness.vaultInsurance();
        uint256 tBefore = harness.vaultCollateral();

        address[] memory winners = new address[](1);
        winners[0] = winner;
        harness.execAdl(winners, p);

        assertEq(iBefore - harness.vaultInsurance(), 50 * SCALE, "insurance returned the seizure to the ledger");
        assertEq(harness.vaultCollateral() - tBefore, 50 * SCALE, "deposits ledger grew by the vault's loss");
        assertEq(harness.bucketCollateral(winner), 60 * SCALE, "winner credited entry collateral + PnL");
        assertEq(harness.vaultDeficit(), 0, "no bad debt");
        assertEq(
            harness.vaultInsurance() + harness.vaultCollateral(),
            iBefore + tBefore,
            "insurance + totalCollateralDeposited conserved (Check-3 invariant holds)"
        );
    }

    /// @notice No free capital: the fund holds exactly the $50 seizure and the live index charges
    ///         the long inventory $5 more, so the vault's loss is $55. The seizure is returned to
    ///         the ledger, the $5 the fund cannot back is withheld from the winner's own $5 of
    ///         funding income, nothing is booked as deficit, and the pair stays solvent.
    function test_Conservation_CarryShortfall_WithheldFromWinnerFunding() public {
        address winner = _setupFundedWinner({insurance: 50 * SCALE, collateralTracked: 1_000 * SCALE});
        BazaarTypes.AdlParams memory p = _fundedWinnerParams();
        p.currentFundingIndex = int256(5 * SCALE); // shorts receive $5/unit; the vault's long pays it

        uint256 sumBefore = harness.vaultInsurance() + harness.vaultCollateral();

        address[] memory winners = new address[](1);
        winners[0] = winner;
        harness.execAdl(winners, p);

        assertEq(harness.vaultInsurance(), 0, "seizure fully returned to the ledger");
        assertEq(harness.vaultCollateral() - 1_000 * SCALE, 50 * SCALE, "ledger grew by what the fund could pay");
        assertEq(harness.bucketCollateral(winner), 60 * SCALE, "price PnL $50 paid in full, $5 funding withheld");
        assertEq(harness.vaultDeficit(), 0, "a withheld carry is not bad debt");
        assertEq(
            harness.vaultInsurance() + harness.vaultCollateral(),
            sumBefore,
            "insurance + totalCollateralDeposited conserved"
        );
    }

    /// @notice The fund holds less than the seizure it earmarked ($20 against $50) and the
    ///         inventory owes $5 of funding: the $35 shortfall exceeds the winner's $5 funding
    ///         income, so that income is withheld and the remaining $30 is recorded as deficit.
    ///         The winner's $50 price PnL is never touched.
    function test_Conservation_EarmarkBreach_RecordsDeficitBeyondWinnerFunding() public {
        address winner = _setupFundedWinner({insurance: 20 * SCALE, collateralTracked: 1_000 * SCALE});
        BazaarTypes.AdlParams memory p = _fundedWinnerParams();
        p.currentFundingIndex = int256(5 * SCALE);

        uint256 sumBefore = harness.vaultInsurance() + harness.vaultCollateral();

        address[] memory winners = new address[](1);
        winners[0] = winner;
        harness.execAdl(winners, p);

        assertEq(harness.vaultInsurance(), 0, "insurance fully drawn");
        assertEq(harness.vaultCollateral() - 1_000 * SCALE, 20 * SCALE, "ledger grew only by the funded amount");
        assertEq(harness.bucketCollateral(winner), 60 * SCALE, "price PnL intact, funding income withheld");
        assertEq(harness.vaultDeficit(), 30 * SCALE, "unbacked remainder recorded as deficit");
        assertEq(
            harness.vaultInsurance() + harness.vaultCollateral(), sumBefore, "the deficit is bookkeeping: I + D unmoved"
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

// ==================== vault health / ADL trigger ====================

/// @notice Harness exposing VaultHealthLib.checkLiqExposure for direct testing.
contract VaultHealthHarness {
    BazaarTypes.Vault public vault;

    /// @dev `seizedCollateral` reconstructs the entry basis the loss is measured from: a long's
    ///      equity reaches zero that far BELOW entry, a short's that far above. The two must stay
    ///      consistent because insuranceFundBalance is expected to already hold that collateral —
    ///      a fixture with a large gap and a tiny fund is not a state the protocol can reach.
    function setVault(
        uint256 insuranceFundBalance,
        uint256 pendingLiqSize,
        uint256 pendingLiqBankruptcyNotional,
        bool pendingLiqIsLong,
        uint256 seizedCollateral
    ) external {
        vault.insuranceFundBalance = insuranceFundBalance;
        vault.pendingLiqSize = pendingLiqSize;
        vault.pendingLiqBankruptcyNotional = pendingLiqBankruptcyNotional;
        vault.pendingLiqIsLong = pendingLiqIsLong;
        vault.pendingLiqEntryNotional = pendingLiqIsLong
            ? pendingLiqBankruptcyNotional + seizedCollateral
            : pendingLiqBankruptcyNotional - seizedCollateral;
        vault.pendingLiqSeized = seizedCollateral;
    }

    function setEntryFundingIndex(int256 i) external {
        vault.pendingLiqEntryFundingIndex = i;
    }

    /// @dev Stage the entry basis independently of the bankruptcy notional, for fixtures where
    ///      the bankruptcy price also carries funding the estate accrued before liquidation.
    function setEntryNotional(uint256 x) external {
        vault.pendingLiqEntryNotional = x;
    }

    function check(
        uint256 currentPrice,
        bool isAdlPending,
        uint256 adlPendingSince,
        uint256 adlSnapshotPrice,
        bool adlLongs
    ) external view returns (VaultHealthLib.LiqExposureResult memory) {
        return VaultHealthLib.checkLiqExposure(
            vault, currentPrice, isAdlPending, adlPendingSince, adlSnapshotPrice, adlLongs, int256(0), int256(0), MMR_BP
        );
    }

    function checkWithFunding(uint256 currentPrice, int256 currentFundingIndex)
        external
        view
        returns (VaultHealthLib.LiqExposureResult memory)
    {
        return VaultHealthLib.checkLiqExposure(
            vault, currentPrice, false, 0, 0, false, currentFundingIndex, int256(0), MMR_BP
        );
    }

    /// @dev Warmup MMR; the unload band it derives is capped at 5% of the price.
    uint256 constant MMR_BP = 1_000;
}

/// @notice Tests for the vault expected-loss calculation: what closing the inherited inventory
///         would take out of the fund, measured on the liquidatees' entry basis.
contract Phase3VaultHealthTest is Test {
    VaultHealthHarness h;
    uint256 constant SCALE = 1e18;

    function setUp() public {
        h = new VaultHealthHarness();
    }

    /// @notice Long-side loss: entry $250, P = $100, size = 1 → loss = $150.
    function test_LongLiq_LossAtBelowBankruptcy() public {
        // size 1, bankruptcy $200 with $50 of collateral seized → entry basis $250
        h.setVault({
            insuranceFundBalance: 1_000_000 * SCALE, // huge so threshold not tripped
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 200 * SCALE,
            pendingLiqIsLong: true,
            seizedCollateral: 50 * SCALE
        });
        // current price $100 → loss = $250 - $100 = $150
        // Free capital is $1M with nothing cached as a target; $150 nowhere near, healthy=true.
        VaultHealthLib.LiqExposureResult memory r = h.check(100 * SCALE, false, 0, 0, false);
        assertTrue(r.healthy);
        assertFalse(r.newIsAdlPending);
    }

    /// @notice Short-side loss: entry $50, P = $200, size = 1 → loss = $150.
    function test_ShortLiq_LossAtAboveBankruptcy() public {
        h.setVault({
            insuranceFundBalance: 1_000_000 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE, // bankruptcy $100, above a short's entry
            pendingLiqIsLong: false,
            seizedCollateral: 50 * SCALE // → entry basis $50
        });
        // current price $200; a short loses as price rises → loss = $200 - $50 = $150.
        VaultHealthLib.LiqExposureResult memory r = h.check(200 * SCALE, false, 0, 0, false);
        assertTrue(r.healthy);
    }

    /// @notice Vault long position in PROFIT against the entry basis → no loss, no ADL. The
    ///         inventory closes for more than it was inherited at, so nothing leaves the fund.
    function test_LongLiq_AboveEntry_NoExposure() public {
        // entry $1,200 (bankruptcy $1,000 + $200 seized), current $1,500 — vault is up money
        h.setVault({
            insuranceFundBalance: 200 * SCALE, // holds the seizure and nothing more
            pendingLiqSize: 10 * SCALE,
            pendingLiqBankruptcyNotional: 1_000 * SCALE, // 10 × $100
            pendingLiqIsLong: true,
            seizedCollateral: 200 * SCALE
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(150 * SCALE, false, 0, 0, false);
        assertTrue(r.healthy, "vault in profit, no exposure");
        assertFalse(r.newIsAdlPending, "ADL must not trigger");
    }

    /// @notice Inventory still inside the collateral taken in costs the fund nothing on net,
    ///         however thin the fund is. The seizure covers exactly this stretch, so a gate that
    ///         counted the loss without also discounting the seizure would fire on every fresh
    ///         liquidation — a position liquidated at its margin boundary has lost its collateral
    ///         by construction.
    function test_LongLiq_WithinSeizedCollateral_NoTrigger() public {
        // entry $1,200, bankruptcy $1,000 ($200 seized), current $1,100 — between the two
        h.setVault({
            insuranceFundBalance: 200 * SCALE, // the seizure and nothing more
            pendingLiqSize: 10 * SCALE,
            pendingLiqBankruptcyNotional: 1_000 * SCALE,
            pendingLiqIsLong: true,
            seizedCollateral: 200 * SCALE
        });
        // $100 of inventory loss against $200 of collateral → episode is $100 ahead.
        VaultHealthLib.LiqExposureResult memory r = h.check(110 * SCALE, false, 0, 0, false);
        assertTrue(r.healthy, "loss inside the collateral is not an exposure");
        assertFalse(r.newIsAdlPending);
    }

    /// @notice Past the collateral, the gate must fire against the capital that existed BEFORE
    ///         the seizure. Comparing the overrun to the raw balance instead scales the trigger
    ///         with the position taken on, so the larger the liquidation the harder it becomes
    ///         to fire — and the fund drains to nothing without the auction ever opening.
    function test_LongLiq_BeyondCollateral_FiresAgainstPreSeizureCapital() public {
        // $10 fund before, $100 seized → balance $110. Entry $1,000, bankruptcy $900.
        // Current $850 is $50 past the collateral: closing here leaves the fund at −$40.
        h.setVault({
            insuranceFundBalance: 110 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 900 * SCALE,
            pendingLiqIsLong: true,
            seizedCollateral: 100 * SCALE
        });
        // Overrun $50 vs the $10 of free capital above the seizure.
        VaultHealthLib.LiqExposureResult memory r = h.check(850 * SCALE, false, 0, 0, false);
        assertFalse(r.healthy, "overrun past the collateral must open the auction");
        assertTrue(r.newIsAdlPending);
    }

    /// @notice Funding accrued on the inventory is part of the claim: a vault holding longs
    ///         while the index rises owes that leg on unload, and a price-only gate would miss it.
    function test_LongLiq_FundingLegCountedInTrigger() public {
        // entry $110, current $110 — flat on price alone
        h.setVault({
            insuranceFundBalance: 100 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE,
            pendingLiqIsLong: true,
            seizedCollateral: 10 * SCALE
        });
        VaultHealthLib.LiqExposureResult memory flat = h.checkWithFunding(110 * SCALE, 0);
        assertTrue(flat.healthy, "no price gap and no funding -> nothing owed");

        // $101/unit of funding accrued against the vault's longs: $91 owed beyond the $10 seizure,
        // against $90 of free capital above it.
        VaultHealthLib.LiqExposureResult memory owed = h.checkWithFunding(110 * SCALE, 101 * int256(SCALE));
        assertFalse(owed.healthy, "funding owed on the inventory triggers ADL on its own");
    }

    /// @notice The funding an estate accrued before liquidation is counted once. It sits inside
    ///         the bankruptcy price and inside the funding leg the vault realizes from the estate's
    ///         entry, so the seizure has to be the collateral the fund actually received rather
    ///         than the gap between the two notionals: with $10 of pre-liquidation funding on a
    ///         $50 seizure, the inventory is whole exactly at its $220 bankruptcy price.
    function test_LongLiq_PreLiquidationFundingCountedOnce() public {
        // entry $260, $50 seized, $10/unit paid before liquidation → bankruptcy $220 (= 260 − 50 + 10).
        h.setVault({
            insuranceFundBalance: 50 * SCALE, // the seizure and nothing more: any loss trips the gate
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 220 * SCALE,
            pendingLiqIsLong: true,
            seizedCollateral: 50 * SCALE
        });
        h.setEntryNotional(260 * SCALE);
        h.setEntryFundingIndex(-10 * int256(SCALE)); // live index 0: $10/unit accrued since entry

        assertTrue(h.checkWithFunding(220 * SCALE, 0).healthy, "whole at the bankruptcy price");
        assertFalse(h.checkWithFunding(219 * SCALE, 0).healthy, "a dollar under it is a loss the fund cannot carry");
    }

    /// @notice Deep underwater must trigger: entry $250, current $50 → $200 claim against a
    ///         $100 fund.
    function test_LongLiq_DeepUnderwater_TriggersAdl() public {
        h.setVault({
            insuranceFundBalance: 100 * SCALE, // small fund
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 200 * SCALE,
            pendingLiqIsLong: true,
            seizedCollateral: 50 * SCALE
        });
        // Free capital above the $50 seizure is $50; the $200 claim clears it.
        VaultHealthLib.LiqExposureResult memory r = h.check(50 * SCALE, false, 0, 0, false);
        assertFalse(r.healthy, "deep underwater must trigger ADL");
        assertTrue(r.newIsAdlPending);
        assertFalse(r.newAdlLongs); // vault inherited longs → deleverage the winning shorts
    }

    /// @notice The ADL deleverage side must be OPPOSITE the liquidated side. Copying
    ///         pendingLiqIsLong straight into newAdlLongs would filter the winner scan to the
    ///         LOSING side, so executeAdl would always revert "No eligible winners" and every
    ///         ADL event would time out into emergency termination.
    function test_AdlTrigger_DeleverageSideOppositeLiquidatedSide() public {
        // Shorts liquidated (price spiked): entry $50, current $200, loss = $150 against no free
        // capital beyond the seizure → ADL triggers.
        h.setVault({
            insuranceFundBalance: 50 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE,
            pendingLiqIsLong: false,
            seizedCollateral: 50 * SCALE
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(200 * SCALE, false, 0, 0, false);
        assertTrue(r.newIsAdlPending);
        assertTrue(r.newAdlLongs, "shorts liquidated -> deleverage the winning longs");
    }

    /// @notice A vault whose inventory sits at its entry basis owes nothing, so no ADL — there
    ///         is no floor under expectedLoss that would trip on the fund's size alone.
    function test_NoFloor_BreakEven_NoFalseAdl() public {
        // entry = $100 (no collateral left to seize), current = $100 — exactly break-even
        h.setVault({
            insuranceFundBalance: 1 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE,
            pendingLiqIsLong: true,
            seizedCollateral: 0
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(100 * SCALE, false, 0, 0, false);
        assertTrue(r.healthy, "no floor: break-even is healthy regardless of fund size");
        assertFalse(r.newIsAdlPending);
    }

    /// @notice A seizure that dwarfs the fund it lands in must not open an auction by itself.
    ///         The inventory arrives having consumed its collateral, so charging that against a
    ///         balance the same collateral just inflated would halt trading on essentially every
    ///         liquidation into a thin fund.
    function test_LargeSeizureIntoThinFund_NoSpuriousTrigger() public {
        // $2 fund before the liquidation, $100 of collateral seized → balance $102.
        // Inventory sits exactly at bankruptcy: closing it pays back the $100 and leaves $2.
        h.setVault({
            insuranceFundBalance: 102 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE,
            pendingLiqIsLong: true,
            seizedCollateral: 100 * SCALE
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(100 * SCALE, false, 0, 0, false);
        assertTrue(r.healthy, "episode is whole: the seizure covers the inventory exactly");
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

        // Post-flip aggregate: vault holds shorts, bankruptcy $100, current $200 → finishing at
        // the band edge ($210) would cost $110 against $50 of free capital → ADL still necessary.
        h.setVault({
            insuranceFundBalance: 100 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE,
            pendingLiqIsLong: false,
            seizedCollateral: 50 * SCALE
        });
        // adlLongs = false == pendingLiqIsLong → direction conflict detected.
        VaultHealthLib.LiqExposureResult memory r = h.check(200 * SCALE, true, since, staleSnapshot, false);
        assertFalse(r.healthy);
        assertTrue(r.newIsAdlPending, "still pending - the band edge does not fit under the free capital");
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
            pendingLiqIsLong: false,
            seizedCollateral: 50 * SCALE
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

        // Vault holds shorts, bankruptcy $100, current $110 → finishing at the band edge
        // ($115.50) would cost $15.50, well under the $950 of free capital.
        h.setVault({
            insuranceFundBalance: 1_000 * SCALE,
            pendingLiqSize: 1 * SCALE,
            pendingLiqBankruptcyNotional: 100 * SCALE,
            pendingLiqIsLong: false,
            seizedCollateral: 50 * SCALE
        });
        VaultHealthLib.LiqExposureResult memory r = h.check(110 * SCALE, true, since, 50 * SCALE, false);
        assertTrue(r.healthy);
        assertFalse(r.newIsAdlPending, "ADL no longer necessary - cleared");
        assertEq(r.newAdlPendingSince, 0);
        assertEq(r.newAdlSnapshotPrice, 0);
    }
}

// ==================== ERC20 transfer safety ====================

/// @notice ERC20 return-value handling. Uses vm.mockCall to make USDC.transfer / transferFrom
///         return `false` silently instead of reverting — the non-standard-token case a bare
///         `.call` would read as success. Every such transfer must revert instead.
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

        PythSeed.seed(address(factory.oracle().pyth()), BTC_USD_FEED_ID);
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

    /// @notice The deposit must revert because SafeERC20 detects the `false` return value from
    ///         transferFrom. An unchecked low-level call would read it as success and credit
    ///         collateral that never arrived.
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
