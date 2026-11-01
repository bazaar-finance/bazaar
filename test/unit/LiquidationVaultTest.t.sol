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
    address[] internal deferred;

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

    function arrears() external view returns (uint256) {
        return vault.ledgerArrears;
    }

    function liquidate(address[] calldata users, uint256 price) external returns (BazaarTypes.LiquidateResult memory) {
        return LiquidationLib.processLiquidations(
            users,
            orders,
            book,
            positionBuckets,
            vault,
            feeEscrow,
            deferred,
            BazaarTypes.LiquidateParams({
                currentPrice: price,
                currentFundingIndex: 0,
                marginReqs: BazaarTypes.MarginRequirements({imrBp: 300, mmrBp: 150, lastUpdateTs: 0, laggedMmrBp: 0}),
                pairId: bytes32("TEST"),
                currentBlock: 1
            })
        );
    }

    function pendingLiqSize() external view returns (uint256) {
        return vault.pendingLiqSize;
    }
}

/// @notice Unit tests for the liquidator reward's flat part: the floor for every position a
///         call seizes, limited to the account's own equity when its position is worth less than
///         MIN_ORDER_AMOUNT, summed across the call, capped at the fund's free capital, debited
///         from insurance and accrued to the liquidator's claimable balance at liquidation time,
///         with no profit-contingent (secondary) component. The rate on what the call sells is
///         paid by the inline unload, which this harness does not run.
contract LiquidatorRewardTest is Test {
    uint256 internal constant FLOOR = 0.05e18; // 0.05 USDC
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

    // -------------------- The flat reward --------------------

    /// @notice A seizure pays the flat $0.05 whatever the position's size. The rate is paid on
    ///         what the call's inline unload sells into the book, which this harness does not run.
    function test_largePosition_paysTheFlatReward() public {
        _long(alice(), 0.1e18, 50_050e18, 10e18); // 0.1 BTC, ~$5,005 entry, $10 collateral
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1);
        assertEq(harness.claimable(address(this)), FLOOR, "the flat reward, not a rate on the position");
        assertEq(r.unloadPrepaid, FLOOR, "nothing netted: the walk is credited with the whole flat reward");
    }

    function test_smallPosition_paysTheFlatReward() public {
        _long(alice(), 0.001e18, 50_050e18, 0.1e18); // 0.001 BTC, ~$50 notional
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1);
        assertEq(harness.claimable(address(this)), FLOOR, "the same flat reward");
    }

    // -------------------- One reward per seizure --------------------

    /// @notice The flat reward is due for every position the call seizes, so one call naming
    ///         several accounts earns what separate calls would and batching costs a keeper
    ///         nothing.
    function test_batchPaysTheFlatRewardPerSeizure() public {
        _long(alice(), 0.1e18, 50_050e18, 10e18);
        _long(dave(), 0.001e18, 50_050e18, 0.1e18);

        address[] memory users = new address[](2);
        users[0] = alice();
        users[1] = dave();
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 2);
        assertEq(harness.claimable(address(this)), 2 * FLOOR, "one flat reward per seizure, both accrued");
    }

    /// @notice An account named twice in one call is seized once and paid for once: the second
    ///         entry finds an empty bucket.
    function test_duplicateEntry_paysOnce() public {
        _long(alice(), 0.1e18, 50_050e18, 10e18);

        address[] memory users = new address[](2);
        users[0] = alice();
        users[1] = alice();
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 1, "seized once");
        assertEq(harness.claimable(address(this)), FLOOR, "paid once");
    }

    /// @notice A call that seizes nothing earns nothing: the reward is for work done, so naming
    ///         a solvent account cannot farm it.
    function test_nothingSeized_paysNothing() public {
        _long(alice(), 0.1e18, 50_000e18, 5_000e18); // fully collateralized, solvent at the price
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 0);
        assertEq(harness.claimable(address(this)), 0, "no seizure, no reward");
        assertEq(r.unloadPrepaid, 0, "and nothing credited against the walk");
    }

    // -------------------- A netting retires exposure --------------------

    /// @notice Opposite-direction liquidations in one call: the first seeds the inventory and
    ///         earns its flat reward, the second nets it to zero. The netting takes the 0.1 BTC
    ///         off the fund, so its account earns 2 bp of the $5,000 at the liquidation price,
    ///         $1, in place of its own flat reward.
    function test_oppositeNetting_paysTheRateOnWhatItRetired() public {
        _long(alice(), 0.1e18, 55_000e18, 100e18); // long underwater at $50k
        harness.setBucket(dave(), false, 0.1e18, Math_mulDiv(0.1e18, 45_500e18, 1e18), 100e18); // short underwater

        address[] memory users = new address[](2);
        users[0] = alice();
        users[1] = dave();
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 2);
        assertEq(harness.pendingLiqSize(), 0, "equal opposite sizes fully net");
        assertEq(harness.claimable(address(this)), FLOOR + 1e18, "alice's flat reward and 2 bp of the $5,000 netted");
        assertEq(r.unloadPrepaid, FLOOR, "only alice's flat reward is credited against the walk");
    }

    // -------------------- Capped at free capital --------------------

    /// @notice The seizure just credited is earmarked against the inventory it arrived with, so
    ///         it is not free capital: a fund holding nothing else pays no reward, and the earmark
    ///         reaches the books whole.
    function test_noFreeCapital_paysNothing_earmarkStaysWhole() public {
        harness = new LiqRewardHarness();
        harness.seedCollateral(1_000_000e18);
        _long(alice(), 0.1e18, 50_050e18, 10e18); // earns $0.05; seizes $10 into an empty fund
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1);
        assertEq(harness.claimable(address(this)), 0, "nothing accrued: the fund holds only the earmark");
        assertEq(r.unloadPrepaid, 0, "nothing paid, nothing credited against the walk");
        assertEq(harness.insurance(), 10e18, "the seizure sits in the fund untouched");
    }

    /// @notice Free capital short of the reward pays what it has, never more.
    function test_partialFreeCapital_paysTheCappedReward() public {
        harness = new LiqRewardHarness();
        harness.seedCollateral(1_000_000e18);
        harness.seedInsurance(0.04e18);
        _long(alice(), 0.1e18, 50_050e18, 10e18); // earns $0.05 against $0.04 of free capital
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(harness.claimable(address(this)), 0.04e18, "capped at free capital");
        assertEq(r.unloadPrepaid, 0.04e18, "the walk is credited with what was paid, not what was due");
        assertEq(harness.insurance(), 10e18, "the earmark is whole: only the free $0.04 left the fund");
    }

    // -------------------- Positions below the order minimum --------------------

    uint256 internal constant SUB_MIN_SIZE = 0.00008e18; // $4 at PRICE, under MIN_ORDER_AMOUNT
    uint256 internal constant MIN_SIZE = 0.0001e18; // exactly MIN_ORDER_AMOUNT at PRICE

    /// @notice A position worth less than MIN_ORDER_AMOUNT with no equity left earns no flat
    ///         reward: the fund takes over nothing of value with it, so it pays nothing for it.
    function test_subMinimumPosition_noEquity_paysNoFlatReward() public {
        // $4 of notional entered at $50,100: a $0.008 loss against $0.005 of collateral.
        _long(alice(), SUB_MIN_SIZE, 50_100e18, 0.005e18);
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(harness.claimable(address(this)), 0, "no flat reward for an account with nothing left");
        assertEq(harness.insurance(), 1_000e18 + 0.005e18, "the fund received the seizure and paid nothing");
    }

    /// @notice Below MIN_ORDER_AMOUNT the flat reward is the account's own equity when that is
    ///         smaller than MIN_LIQUIDATOR_REWARD.
    function test_subMinimumPosition_paysItsEquity() public {
        // $4 of notional at its entry price with $0.03 of collateral, under the $0.06 maintenance line.
        _long(alice(), SUB_MIN_SIZE, 50_000e18, 0.03e18);
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(harness.claimable(address(this)), 0.03e18, "the flat reward is the account's equity");
        assertEq(harness.insurance(), 1_000e18, "the fund paid out exactly the equity it took over");
    }

    /// @notice The cap binds only when the equity is smaller: a position below the minimum that
    ///         still holds more than the floor earns the full floor.
    function test_subMinimumPosition_equityAboveTheFloor_paysTheFullFloor() public {
        // $4 of notional with $0.055 of collateral: under the $0.06 maintenance line, over the floor.
        _long(alice(), SUB_MIN_SIZE, 50_000e18, 0.055e18);
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(harness.claimable(address(this)), FLOOR, "the full floor");
    }

    /// @notice A position worth MIN_ORDER_AMOUNT or more earns the full floor even with no equity
    ///         left: until it is seized its further losses are the fund's.
    function test_positionAtTheMinimum_bankrupt_paysTheFullFloor() public {
        // Exactly $5 of notional entered at $50,100 with no collateral: $0.01 past bankruptcy.
        _long(alice(), MIN_SIZE, 50_100e18, 0);
        BazaarTypes.LiquidateResult memory r = _liq(alice(), PRICE);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(harness.claimable(address(this)), FLOOR, "the full floor, whatever the equity");
    }

    /// @notice Each account in a batch is capped on its own: a sub-minimum account with nothing
    ///         left adds nothing, and a full-size one beside it still adds the floor.
    function test_batch_capsEachAccountOnItsOwn() public {
        _long(alice(), SUB_MIN_SIZE, 50_100e18, 0.005e18); // no equity left
        _long(dave(), 0.1e18, 50_050e18, 10e18); // ~$5,000, under maintenance

        address[] memory users = new address[](2);
        users[0] = alice();
        users[1] = dave();
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 2, "both seized");
        assertEq(harness.claimable(address(this)), FLOOR, "only the full-size account adds the floor");
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
    ///         credited exactly the ledger balance, the ledger floors at zero, the unpaid
    ///         remainder is carried as the ledger's arrears to the fund, and no deficit is
    ///         booked — settlement of the inherited estate decides solvency.
    function test_bucketAboveLedger_seizureCapsAndSucceeds() public {
        _underwaterLong(loser, 10_000e18);
        harness.seedCollateral(9_200e18);

        BazaarTypes.LiquidateResult memory r = _liq(loser);

        assertEq(r.liquidatedCount, 1, "liquidation must not revert on a thin ledger");
        assertEq(
            harness.insurance(),
            9_200e18 - harness.claimable(address(this)),
            "insurance receives the capped amount, less the reward"
        );
        assertEq(harness.deposits(), 0, "ledger floors at zero");
        assertEq(harness.arrears(), 800e18, "the unpaid remainder is the ledger's arrears to the fund");
        assertEq(harness.deficit(), 0, "no deficit at seizure time");
        assertEq(harness.pendingLiqSize(), 1e18, "estate carries the full position");
    }

    /// @notice Ledger fully covers the book: the cap is inactive, the full collateral moves to
    ///         insurance and no arrears arise.
    function test_ledgerCoversBook_fullSeizure() public {
        _underwaterLong(loser, 10_000e18);
        harness.seedCollateral(30_000e18);

        _liq(loser);

        assertEq(
            harness.insurance(), 10_000e18 - harness.claimable(address(this)), "full book value seized, less the reward"
        );
        assertEq(harness.deposits(), 20_000e18);
        assertEq(harness.arrears(), 0, "a ledger that covers the book owes nothing");
        assertEq(harness.deficit(), 0);
    }

    /// @notice A batch whose summed books exceed the ledger, though each position fits
    ///         alone: the first seizure takes its full book, the second is capped at the
    ///         remainder with the rest carried as arrears, and both liquidations commit.
    function test_batchCascade_capsAtRemainder() public {
        _underwaterLong(loser, 6_000e18);
        _underwaterLong(loser2, 6_000e18);
        harness.seedCollateral(9_000e18);

        address[] memory users = new address[](2);
        users[0] = loser;
        users[1] = loser2;
        BazaarTypes.LiquidateResult memory r = harness.liquidate(users, PRICE);

        assertEq(r.liquidatedCount, 2, "the aggregate cap must not revert the batch");
        assertEq(
            harness.insurance(),
            9_000e18 - harness.claimable(address(this)),
            "6,000 full + 3,000 capped, less the rewards"
        );
        assertEq(harness.deposits(), 0);
        assertEq(harness.arrears(), 3_000e18, "the second seizure's unpaid 3,000 is owed to the fund");
        assertEq(harness.pendingLiqSize(), 2e18, "both estates on the books");
    }

    /// @notice An empty ledger seizes nothing but the liquidation still commits, the estate is
    ///         still recorded, and the whole book is owed to the fund.
    function test_emptyLedger_liquidationStillCommits() public {
        _underwaterLong(loser, 10_000e18);
        harness.seedCollateral(0);

        BazaarTypes.LiquidateResult memory r = _liq(loser);

        assertEq(r.liquidatedCount, 1);
        assertEq(harness.insurance(), 0, "nothing attributable, nothing credited");
        assertEq(harness.arrears(), 10_000e18, "the whole book is owed to the fund");
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
    address[] internal deferred;

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

    /// @dev Seed what the deposits ledger already owes the fund, as an earlier seizure the
    ///      ledger could only partly pay would have left it.
    function seedArrears(uint256 amount) external {
        vault.ledgerArrears = amount;
    }

    function arrears() external view returns (uint256) {
        return vault.ledgerArrears;
    }

    function deposits() external view returns (uint256) {
        return vault.totalCollateralDeposited;
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
            deferred,
            BazaarTypes.LiquidateParams({
                currentPrice: price,
                currentFundingIndex: fundingIndex,
                marginReqs: BazaarTypes.MarginRequirements({imrBp: 300, mmrBp: 150, lastUpdateTs: 0, laggedMmrBp: 0}),
                pairId: bytes32("TEST"),
                currentBlock: 1
            })
        );
    }

    function liquidateMany(address[] calldata users, uint256 price, int256 fundingIndex)
        external
        returns (BazaarTypes.LiquidateResult memory)
    {
        return LiquidationLib.processLiquidations(
            users,
            orders,
            book,
            positionBuckets,
            vault,
            feeEscrow,
            deferred,
            BazaarTypes.LiquidateParams({
                currentPrice: price,
                currentFundingIndex: fundingIndex,
                marginReqs: BazaarTypes.MarginRequirements({imrBp: 300, mmrBp: 150, lastUpdateTs: 0, laggedMmrBp: 0}),
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

    function deferredList() external view returns (address[] memory) {
        return deferred;
    }

    function bucketSize(address user) external view returns (uint256) {
        return positionBuckets[user].size;
    }

    function pendingLiqIsLong() external view returns (bool) {
        return vault.pendingLiqIsLong;
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
        // base + seized - funding (long pays when funding rises) - liquidator reward; price netPnl == 0
        uint256 expected = BASE_INSURANCE + SEIZED_COLLATERAL - nettedFunding - h.claimable(address(this));
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
        // base + seized + funding (short receives when funding rises) - liquidator reward; price netPnl == 0
        uint256 expected = BASE_INSURANCE + SEIZED_COLLATERAL + nettedFunding - h.claimable(address(this));
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
        // base + seized - liquidator reward only; price netPnl == 0 and funding delta == 0
        assertEq(
            h.insuranceFundBalance(),
            BASE_INSURANCE + SEIZED_COLLATERAL - h.claimable(address(this)),
            "no funding term when delta is zero"
        );
    }

    function dave() internal returns (address) {
        return makeAddr("dave");
    }

    // ----- Deferral: a netting the fund cannot afford is not run -----

    /// @notice When the netting's loss exceeds what backs the two netted slices — free capital
    ///         above the reserve, their seizure and the ledger's arrears — the position is not
    ///         seized: it stays open, is recorded as deferred for the auction to close against its
    ///         own counterparties, and neither the inventory nor the fund moves. The liquidator
    ///         earns the reward floor once for recording it, and nothing for naming it again.
    function test_nettingBeyondBacking_defersInsteadOfBookingDeficit() public {
        // Vault holds a long inherited at $60k entry, bankrupt at $58k: $2k seized with it.
        h.seedPending(true, SIZE, 60_000 * SCALE, 58_000 * SCALE, 0);
        // Insurance $4k, of which the $2k earmark: $2k free.
        h.seedInsurance(4_000 * SCALE);
        // Opposing short entered at $48k with $1k collateral -> insolvent at $50k (loss $2k > $1k).
        h.setBucket(dave(), false, SIZE, 48_000 * SCALE, 1_000 * SCALE, 0);

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave(), PRICE, 0);

        // The $12k entry gap (60k long against 48k short) against $2k free + $2k earmark + $1k
        // seizure: unaffordable, so nothing is seized or netted.
        assertEq(r.liquidatedCount, 0, "not seized");
        assertEq(r.deferredCount, 1, "deferred");
        assertEq(h.bucketSize(dave()), SIZE, "position left open");
        assertEq(h.pendingLiqSize(), SIZE, "inventory untouched");
        assertEq(h.deficit(), 0, "no bad debt booked");
        address[] memory listed = h.deferredList();
        assertEq(listed.length, 1, "recorded");
        assertEq(listed[0], dave(), "recorded");
        // The recording tip is the reward floor, paid from the fund's free capital. A deferral
        // nets nothing, so it earns no rate and the whole tip is credited against the walk.
        assertEq(h.claimable(address(this)), BazaarTypes.MIN_LIQUIDATOR_REWARD, "the floor, for the recording");
        assertEq(r.unloadPrepaid, BazaarTypes.MIN_LIQUIDATOR_REWARD, "the whole tip credited against the walk");
        assertEq(
            h.insuranceFundBalance(),
            4_000 * SCALE - BazaarTypes.MIN_LIQUIDATOR_REWARD,
            "the fund moved by the tip alone"
        );

        // Naming a listed account again re-evaluates it and pays nothing.
        r = h.liquidate(dave(), PRICE, 0);
        assertEq(r.deferredCount, 1, "still deferred");
        assertEq(h.claimable(address(this)), BazaarTypes.MIN_LIQUIDATOR_REWARD, "no tip for a re-submission");
        assertEq(r.unloadPrepaid, 0, "nothing paid, nothing credited");
        assertEq(h.deferredList().length, 1, "listed once");
    }

    /// @notice Recording several accounts in one call pays the flat reward for each, like
    ///         seizing several does.
    function test_twoNewDeferralsInOneCall_payTheFlatRewardEach() public {
        // Two units inherited at $60k entry, bankrupt at $58k: $4k earmarked, the whole fund.
        h.seedPending(true, 2 * SIZE, 120_000 * SCALE, 116_000 * SCALE, 0);
        h.seedInsurance(4_200 * SCALE);
        address erin = makeAddr("erin");
        // Two opposing shorts, each from $48k on $1k: each netting's $12k entry gap is unaffordable.
        h.setBucket(dave(), false, SIZE, 48_000 * SCALE, 1_000 * SCALE, 0);
        h.setBucket(erin, false, SIZE, 48_000 * SCALE, 1_000 * SCALE, 0);
        address[] memory users = new address[](2);
        users[0] = dave();
        users[1] = erin;

        BazaarTypes.LiquidateResult memory r = h.liquidateMany(users, PRICE, 0);

        assertEq(r.liquidatedCount, 0, "neither seized");
        assertEq(r.deferredCount, 2, "both recorded");
        assertEq(h.deferredList().length, 2);
        assertEq(h.claimable(address(this)), 2 * BazaarTypes.MIN_LIQUIDATOR_REWARD, "one flat reward per recording");
    }

    /// @notice A new deferral is paid like a seizure and capped the same way: an account whose
    ///         position is worth less than MIN_ORDER_AMOUNT earns at most its own equity.
    function test_subMinimumDeferral_paysItsEquity() public {
        // Vault holds a long inherited at $60k entry, bankrupt at $58k: $2k seized with it.
        h.seedPending(true, SIZE, 60_000 * SCALE, 58_000 * SCALE, 0);
        // $0.50 of free capital on top of the $2k earmark.
        h.seedInsurance(2_000 * SCALE + SCALE / 2);
        // A $4 short entered at $48k with $0.19 of collateral: its $0.16 loss at $50k leaves $0.03
        // of equity, under the $0.06 maintenance line.
        uint256 dust = 0.00008e18;
        h.setBucket(dave(), false, dust, _mulDiv(dust, 48_000 * SCALE, SCALE), 0.19e18, 0);

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave(), PRICE, 0);

        // Netting it would lose $0.96 on the entry gap against $0.85 of backing: the $0.50 free,
        // $0.16 of the inventory's seizure and its own $0.19.
        assertEq(r.deferredCount, 1, "deferred");
        assertEq(r.liquidatedCount, 0, "not seized");
        assertEq(h.claimable(address(this)), 0.03e18, "the flat reward is the account's equity");
        assertEq(h.insuranceFundBalance(), 2_000 * SCALE + SCALE / 2 - 0.03e18, "the fund paid the capped reward");
    }

    /// @notice A deferred account is seized by the next call that finds the inventory it would
    ///         have netted against gone: it becomes the vault's inventory on its own side, earns
    ///         the call its flat reward and leaves the list.
    function test_deferred_seizedOnceTheInventoryIsGone() public {
        h.seedPending(true, SIZE, 60_000 * SCALE, 58_000 * SCALE, 0);
        h.seedInsurance(4_000 * SCALE);
        h.setBucket(dave(), false, SIZE, 48_000 * SCALE, 1_000 * SCALE, 0);
        h.liquidate(dave(), PRICE, 0);
        assertEq(h.deferredList().length, 1, "deferred");

        // The inventory is unloaded elsewhere.
        h.seedPending(true, 0, 0, 0, 0);
        BazaarTypes.LiquidateResult memory r = h.liquidate(dave(), PRICE, 0);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(r.deferredCount, 0, "not deferred again");
        assertEq(h.deferredList().length, 0, "delisted");
        assertEq(h.pendingLiqSize(), SIZE, "now the inventory");
        assertFalse(h.pendingLiqIsLong(), "on its own side");
        assertEq(h.claimable(address(this)), 2 * BazaarTypes.MIN_LIQUIDATOR_REWARD, "the flat reward, after the tip");
        assertEq(r.unloadPrepaid, BazaarTypes.MIN_LIQUIDATOR_REWARD, "nothing netted: the whole flat reward credited");
    }

    /// @notice A deferred account that is solvent again when next named — a reversal, a deposit
    ///         — is simply delisted: the gate reads the buckets, so nothing else tracked it.
    function test_deferred_delistedWhenSolventAgain() public {
        h.seedPending(true, SIZE, 60_000 * SCALE, 58_000 * SCALE, 0);
        h.seedInsurance(4_000 * SCALE);
        h.setBucket(dave(), false, SIZE, 48_000 * SCALE, 1_000 * SCALE, 0);
        h.liquidate(dave(), PRICE, 0);
        assertEq(h.deferredList().length, 1, "deferred");

        // Back at his entry the short is whole.
        BazaarTypes.LiquidateResult memory r = h.liquidate(dave(), 48_000 * SCALE, 0);

        assertEq(r.liquidatedCount, 0, "solvent: not seized");
        assertEq(r.deferredCount, 0, "solvent: not deferred");
        assertEq(h.deferredList().length, 0, "delisted");
        assertEq(h.bucketSize(dave()), SIZE, "still open");
    }

    /// @notice The list holds MAX_DEFERRED_LIQUIDATIONS accounts. A newcomer with a larger loss
    ///         beyond its collateral than the smallest listed one takes that entry's place; one
    ///         with a smaller loss is left untracked. The recording tip goes to the account that
    ///         is newly listed and to nothing else.
    function test_deferred_listCapKeepsTheLargestExcess() public {
        h.seedPending(true, SIZE, 60_000 * SCALE, 58_000 * SCALE, 0);
        h.seedInsurance(4_000 * SCALE);
        uint256 cap = BazaarTypes.MAX_DEFERRED_LIQUIDATIONS;
        // Every short entered at $48k loses $2k at $50k; collateral from $200 up in $100 steps,
        // so the loss beyond it descends with the index and the last entry is the shallowest.
        address[] memory shorts = new address[](cap);
        for (uint256 i = 0; i < cap; i++) {
            shorts[i] = makeAddr(string.concat("short", vm.toString(i)));
            h.setBucket(shorts[i], false, SIZE, 48_000 * SCALE, (200 + 100 * i) * SCALE, 0);
            h.liquidate(shorts[i], PRICE, 0);
            assertEq(h.claimable(address(this)), (i + 1) * BazaarTypes.MIN_LIQUIDATOR_REWARD, "tipped");
        }
        assertEq(h.deferredList().length, cap, "full");

        // $100 collateral: $1,900 beyond it, the largest of all -> displaces the shallowest entry.
        address deeper = makeAddr("deeper");
        h.setBucket(deeper, false, SIZE, 48_000 * SCALE, 100 * SCALE, 0);
        BazaarTypes.LiquidateResult memory r = h.liquidate(deeper, PRICE, 0);
        assertEq(r.deferredCount, 1, "deferred");
        assertEq(h.claimable(address(this)), (cap + 1) * BazaarTypes.MIN_LIQUIDATOR_REWARD, "newly listed: tipped");
        address[] memory listed = h.deferredList();
        assertEq(listed.length, cap, "still at the cap");
        assertTrue(_listed(listed, deeper), "the deeper account is listed");
        assertFalse(_listed(listed, shorts[cap - 1]), "the shallowest entry made room");
        assertEq(h.bucketSize(shorts[cap - 1]), SIZE, "displaced, not seized");

        // The collateral the displaced entry held: its loss beyond it is smaller than every entry
        // still listed, so this one is left untracked and earns nothing. Derived from the cap so
        // the case survives a change to it.
        address shallower = makeAddr("shallower");
        h.setBucket(shallower, false, SIZE, 48_000 * SCALE, (200 + 100 * (cap - 1)) * SCALE, 0);
        r = h.liquidate(shallower, PRICE, 0);
        assertEq(r.deferredCount, 1, "deferred all the same");
        assertEq(h.claimable(address(this)), (cap + 1) * BazaarTypes.MIN_LIQUIDATOR_REWARD, "not listed: no tip");
        assertFalse(_listed(h.deferredList(), shallower), "untracked");
        assertEq(h.bucketSize(shallower), SIZE, "still open");
    }

    function _listed(address[] memory list, address who) internal pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == who) return true;
        }
        return false;
    }

    // ----- Arrears netting: what the ledger owes the fund comes off the fund's payment first -----

    /// @notice The same loss with the ledger owing the fund $7k from an earlier seizure it could
    ///         only partly pay: $2k free, the $2k earmark, the $1k seizure and the $7k arrears
    ///         back the $12k exactly, so the netting runs. The loss is paid net of the arrears
    ///         and the $5k the fund holds covers the rest, with no deficit.
    function test_nettingLoss_netsLedgerArrearsBeforeInsurancePays() public {
        h.seedPending(true, SIZE, 60_000 * SCALE, 58_000 * SCALE, 0);
        h.seedInsurance(4_000 * SCALE);
        h.seedArrears(7_000 * SCALE);
        h.setBucket(dave(), false, SIZE, 48_000 * SCALE, 1_000 * SCALE, 0);
        uint256 ledgerBefore = h.deposits();

        h.liquidate(dave(), PRICE, 0);

        assertEq(h.pendingLiqSize(), 0, "equal opposite sizes fully net");
        assertEq(h.arrears(), 0, "the loss consumed the whole arrears");
        assertEq(h.insuranceFundBalance(), 0, "the fund paid the $5k left after netting");
        assertEq(h.deficit(), 0, "no deficit: the fund covered the loss beyond the estates' collateral");
        // The ledger gave up the $1k seizure and received the $5k net payment.
        assertEq(h.deposits(), ledgerBefore - 1_000 * SCALE + 5_000 * SCALE, "ledger credited the net loss");
    }

    /// @notice Arrears count toward what the netting may spend, and short of covering the loss
    ///         together with the rest of the backing they leave the position deferred: nothing
    ///         is consumed and nothing booked.
    function test_nettingLoss_arrearsShortOfTheLoss_defers() public {
        h.seedPending(true, SIZE, 60_000 * SCALE, 58_000 * SCALE, 0);
        h.seedInsurance(4_000 * SCALE);
        h.seedArrears(3_000 * SCALE);
        h.setBucket(dave(), false, SIZE, 48_000 * SCALE, 1_000 * SCALE, 0);

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave(), PRICE, 0);

        // $2k free + $2k earmark + $1k seizure + $3k arrears = $8k against a $12k loss.
        assertEq(r.deferredCount, 1, "deferred");
        assertEq(h.arrears(), 3_000 * SCALE, "arrears untouched");
        assertEq(h.pendingLiqSize(), SIZE, "inventory untouched");
        assertEq(h.deficit(), 0, "nothing booked");
    }

    /// @notice A netting GAIN on a ledger too thin to pay it: the seizure takes what the ledger
    ///         holds and the gain the ledger cannot pay is added to its arrears rather than
    ///         dropped, so the fund's claim on the estates' value survives.
    function test_nettingGain_thinLedgerCarriesTheGainAsArrears() public {
        // Vault holds a long inherited at $40k entry (in profit at $50k).
        h.seedPending(true, SIZE, 40_000 * SCALE, 38_000 * SCALE, 0);
        h.seedInsurance(4_000 * SCALE);
        // The ledger holds $500 against a $1k bucket: the seizure is capped at $500.
        h.seedCollateral(500 * SCALE);
        h.setBucket(dave(), false, SIZE, 48_000 * SCALE, 1_000 * SCALE, 0);

        h.liquidate(dave(), PRICE, 0);

        assertEq(h.pendingLiqSize(), 0, "equal opposite sizes fully net");
        assertEq(h.deposits(), 0, "the ledger gave up everything it held");
        // $500 of unpaid seizure plus the $8k netting gain (48k − 40k) the empty ledger could not pay.
        assertEq(h.arrears(), 8_500 * SCALE, "unpaid seizure and uncollected gain are both owed to the fund");
        // The liquidator is paid 2 bp of the netted unit at $50k: $10.
        assertEq(h.claimable(address(this)), 10 * SCALE, "the rate on what the netting retired");
        assertEq(
            h.insuranceFundBalance(), 4_500 * SCALE - 10 * SCALE, "fund holds base + the cash seized, less the reward"
        );
        assertEq(h.deficit(), 0);
    }
}

// ==================== netting reward ====================

/// @notice The rate a liquidation earns on what its nettings retire. A position seized against
///         an opposite inventory cancels the overlap at once, which takes that much exposure off
///         the fund just as an unload sale does, so its account earns LIQUIDATION_FEE_EBP of the
///         overlap's notional at the liquidation price when that beats its flat reward. Each
///         account earns its own larger figure, so batching changes nothing. What the payment
///         holds beyond the nettings' rate is the credit handed to the inline unload
///         (LiquidateResult.unloadPrepaid), which pays its own rate on what it sells only past
///         that credit.
///
///         Every inventory here is staged at the oracle with no earmark and every opposing
///         position enters at the oracle, so a netting's entry gap is zero: it is always
///         affordable and moves the fund only by the seizure and the reward.
contract NettingRewardTest is Test {
    uint256 internal constant SCALE = 1e18;
    uint256 internal constant PRICE = 50_000e18;
    uint256 internal constant FLOOR = BazaarTypes.MIN_LIQUIDATOR_REWARD;

    NettingHarness internal h;
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");
    address internal frank = makeAddr("frank");

    function setUp() public {
        h = new NettingHarness();
        h.seedCollateral(1_000_000e18);
        h.seedInsurance(1_000e18);
    }

    /// @dev LIQUIDATION_FEE_EBP of `size` at PRICE, computed as processLiquidations does.
    function _rate(uint256 size) internal pure returns (uint256) {
        return (size * PRICE / SCALE) * BazaarTypes.LIQUIDATION_FEE_EBP / BazaarTypes.EBP_SCALE;
    }

    /// @dev An inventory of `size` on `isLong`, entered at PRICE, with nothing earmarked.
    function _inventory(bool isLong, uint256 size) internal {
        uint256 notional = size * PRICE / SCALE;
        h.seedPending(isLong, size, notional, notional, 0);
    }

    /// @dev A position of `size` entered at PRICE with `collateral`, under maintenance at PRICE
    ///      whenever the collateral is below 1.5% of its notional.
    function _position(address user, bool isLong, uint256 size, uint256 collateral) internal {
        h.setBucket(user, isLong, size, size * PRICE / SCALE, collateral, 0);
    }

    function _three(address a, address b, address c) internal pure returns (address[] memory out) {
        out = new address[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    /// @notice A netting that retires the whole inventory earns 2 bp of its notional, $10 for a
    ///         unit at $50k, where the flat reward alone would pay $0.05.
    function test_fullNetting_paysTheRateOnTheNettedNotional() public {
        _inventory(true, SCALE);
        _position(dave, false, SCALE, 10e18);

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        assertEq(r.liquidatedCount, 1, "seized");
        assertEq(h.pendingLiqSize(), 0, "netted to zero");
        assertEq(_rate(SCALE), 10e18, "premise: 2 bp of $50,000");
        assertEq(h.claimable(address(this)), 10e18, "the rate on what the netting retired");
        assertEq(r.unloadPrepaid, 0, "the netting rate spent the whole payment");
        assertEq(h.insuranceFundBalance(), 1_000e18 + 10e18 - 10e18, "the fund received the seizure and paid the rate");
    }

    /// @notice An estate larger than the inventory nets only the overlap; the rest becomes the
    ///         new inventory, exposure moved onto the fund, and earns nothing until it is sold.
    function test_flipNetting_paysTheRateOnTheOverlapOnly() public {
        _inventory(true, SCALE);
        _position(dave, false, 3 * SCALE, 30e18);

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        assertEq(h.pendingLiqSize(), 2 * SCALE, "two units left over");
        assertFalse(h.pendingLiqIsLong(), "now on the estate's side");
        assertEq(h.claimable(address(this)), _rate(SCALE), "2 bp of the one unit netted, not of all three");
        assertEq(r.unloadPrepaid, 0, "nothing left to credit against the walk");
    }

    /// @notice A netting smaller than the inventory nets its own size.
    function test_partialNetting_paysTheRateOnTheEstate() public {
        _inventory(true, 3 * SCALE);
        _position(dave, false, SCALE, 10e18);

        h.liquidate(dave, PRICE, 0);

        assertEq(h.pendingLiqSize(), 2 * SCALE, "two units of inventory survive");
        assertTrue(h.pendingLiqIsLong(), "on the inventory's side");
        assertEq(h.claimable(address(this)), _rate(SCALE), "2 bp of the unit the estate retired");
    }

    /// @notice Below $250 netted, 2 bp is under the flat reward, which stands. The walk is then
    ///         credited with what the flat reward pays beyond the netting rate, so that a sale
    ///         earns only what its own rate adds past the flat total.
    function test_smallNetting_flatRewardGoverns_walkCreditedWithTheRest() public {
        uint256 size = 0.0002e18; // $10 at $50k
        _inventory(true, size);
        _position(dave, false, size, 0.1e18); // under the $0.15 maintenance line

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        uint256 rate = _rate(size);
        assertEq(rate, 0.002e18, "premise: 2 bp of $10");
        assertEq(h.claimable(address(this)), FLOOR, "the flat reward stands");
        assertEq(r.unloadPrepaid, FLOOR - rate, "the walk is credited with the flat reward less the netting rate");
    }

    /// @notice Each account is paid its own larger figure: a $50 netting, whose 2 bp is a cent,
    ///         earns its flat reward, and the two same-side seizures after it earn theirs. The
    ///         walk is credited with the three flat rewards less the cent the netting's rate holds.
    function test_smallNettingAndTwoSeizures_eachAccountEarnsItsOwnLarger() public {
        uint256 size = 0.001e18; // $50 at $50k
        _inventory(true, size);
        _position(dave, false, size, 0.5e18); // nets the inventory away
        _position(erin, false, size, 0.5e18); // seeds a short inventory
        _position(frank, false, size, 0.5e18); // adds to it

        BazaarTypes.LiquidateResult memory r = h.liquidateMany(_three(dave, erin, frank), PRICE, 0);

        assertEq(r.liquidatedCount, 3, "all three seized");
        assertEq(h.pendingLiqSize(), 2 * size, "erin and frank are the new inventory");
        assertEq(h.claimable(address(this)), 3 * FLOOR, "three flat rewards, not three plus the rate");
        assertEq(r.unloadPrepaid, 3 * FLOOR - _rate(size), "the flat total less the netting rate");
    }

    /// @notice A large netting and a small seizure in one call earn what two calls would: the
    ///         netting's $10 and the seizure's $0.05, where one maximum over the call would drop
    ///         the $0.05 and pay a keeper to split the batch.
    function test_largeNettingAndASeizure_payWhatTwoCallsWould() public {
        _inventory(true, SCALE);
        _position(dave, false, SCALE, 10e18); // nets the inventory away: $10
        _position(erin, false, 0.001e18, 0.5e18); // seeds a short inventory: $0.05
        address[] memory users = new address[](2);
        users[0] = dave;
        users[1] = erin;

        BazaarTypes.LiquidateResult memory r = h.liquidateMany(users, PRICE, 0);

        assertEq(r.liquidatedCount, 2, "both seized");
        assertEq(h.claimable(address(this)), _rate(SCALE) + FLOOR, "the netting's rate and the seizure's flat reward");
        assertEq(r.unloadPrepaid, FLOOR, "erin's flat reward is credited against the walk that sells her");
    }

    /// @notice A cap between the netting's rate and its flat reward: the fund pays the free
    ///         capital it has, and the walk is credited only with what that payment holds beyond
    ///         the rate.
    function test_capBetweenTheRateAndTheFlatReward_creditIsWhatWasPaidPastTheRate() public {
        h.seedInsurance(0);
        uint256 size = 0.0002e18; // $10 at $50k: a $0.002 rate against the $0.05 floor
        _inventory(true, size);
        _position(dave, false, size, 0.03e18); // its $0.03 seizure is the fund's only free capital

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        assertEq(h.claimable(address(this)), 0.03e18, "capped at the $0.03 the fund holds free");
        assertEq(r.unloadPrepaid, 0.03e18 - _rate(size), "the payment less the netting's rate");
    }

    /// @notice Each netting is measured against the inventory left by the one before it: two
    ///         one-unit estates against 1.5 units net 1 and 0.5, and the second's other half
    ///         becomes the new inventory.
    function test_twoNettings_eachMeasuredAgainstTheInventoryLeft() public {
        _inventory(true, 1.5e18);
        _position(dave, false, SCALE, 10e18);
        _position(erin, false, SCALE, 10e18);
        address[] memory users = new address[](2);
        users[0] = dave;
        users[1] = erin;

        BazaarTypes.LiquidateResult memory r = h.liquidateMany(users, PRICE, 0);

        assertEq(r.liquidatedCount, 2, "both seized");
        assertEq(h.pendingLiqSize(), 0.5e18, "half of erin's unit is left over");
        assertFalse(h.pendingLiqIsLong(), "on the estates' side");
        assertEq(h.claimable(address(this)), _rate(1.5e18), "2 bp of the 1.5 units netted");
    }

    /// @notice The netting rate is paid like the flat part: capped at free capital. A fund that
    ///         holds only the netted estate's seizure pays that and no more, and credits the
    ///         walk with nothing.
    function test_nettingRate_cappedAtFreeCapital() public {
        h.seedInsurance(0);
        _inventory(true, SCALE);
        _position(dave, false, SCALE, 4e18); // its $4 seizure is the fund's only free capital

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        assertEq(h.pendingLiqSize(), 0, "netted to zero");
        assertEq(h.claimable(address(this)), 4e18, "the $10 rate, capped at the $4 the fund holds free");
        assertEq(r.unloadPrepaid, 0, "a capped payment leaves nothing to credit");
        assertEq(h.insuranceFundBalance(), 0, "the fund paid out its free capital and no more");
    }

    /// @notice A netting the fund cannot afford is deferred, not run: the account earns the flat
    ///         reward for its recording and the rate on nothing.
    function test_deferredNetting_earnsNoRate() public {
        // A unit inherited at $60k entry, bankrupt at $58k ($2k earmarked), against a short from
        // $48k with $1k: the $12k entry gap is past the $2k free, the $2k earmark and the $1k seizure.
        h.seedPending(true, SCALE, 60_000 * SCALE, 58_000 * SCALE, 0);
        h.seedInsurance(4_000 * SCALE);
        h.setBucket(dave, false, SCALE, 48_000 * SCALE, 1_000 * SCALE, 0);

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        assertEq(r.deferredCount, 1, "deferred");
        assertEq(h.pendingLiqSize(), SCALE, "nothing netted");
        assertEq(h.claimable(address(this)), FLOOR, "the recording tip alone");
        assertEq(r.unloadPrepaid, FLOOR, "all of it credited against the walk");
    }

    /// @notice Whatever the two sizes, the call pays max(flat, 2 bp of the overlap) and credits
    ///         the walk with what that leaves past the netting rate.
    function testFuzz_netting_paysTheLargerOfFlatAndTheRateOnTheOverlap(uint256 inventorySize, uint256 estateSize)
        public
    {
        // From the $5 order minimum to 100 BTC on each side, so the flat part is the full floor.
        inventorySize = bound(inventorySize, 0.0001e18, 100e18);
        estateSize = bound(estateSize, 0.0001e18, 100e18);
        h.seedInsurance(1_000_000e18);
        _inventory(true, inventorySize);
        _position(dave, false, estateSize, 0); // no collateral: insolvent at any size

        BazaarTypes.LiquidateResult memory r = h.liquidate(dave, PRICE, 0);

        uint256 overlap = inventorySize < estateSize ? inventorySize : estateSize;
        uint256 rate = _rate(overlap);
        uint256 paid = rate > FLOOR ? rate : FLOOR;
        assertEq(h.claimable(address(this)), paid, "max(flat, rate on the overlap)");
        assertEq(r.unloadPrepaid, paid - rate, "the walk is credited with the flat part past the rate");
        uint256 left = inventorySize > estateSize ? inventorySize - estateSize : estateSize - inventorySize;
        assertEq(h.pendingLiqSize(), left, "the overlap left the books");
    }
}

// ==================== ADL execution guards ====================

/// @notice Harness that owns its own ADL state and forwards into AdlLib.executeAdlCore.
///         Lets us construct edge-case bucket states (size > 0, collateral = 0) without
///         standing up a full BazaarPair.
contract AdlHarness {
    mapping(uint256 => BazaarTypes.Order) public orders;
    BazaarTypes.FeeEscrow internal feeEscrow;
    address[] internal deferred;
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
            orders,
            book,
            positionBuckets,
            vault,
            feeEscrow,
            deferred,
            winners,
            winners[0:0],
            params,
            adlEpoch,
            adlDepositEpoch,
            adlWindowDeposits
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
        // Closed at its own basis, the inventory moves the fund only by the executor's 2 bp of
        // the unit at the $90 mark, $0.018, more than 0.1% of the $10 the close averted.
        assertEq(
            harness.vaultInsurance(), 10 * SCALE - 0.018e18, "inventory closed at its own basis: only the reward leaves"
        );
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
        // Identical positions score identically, and equal scores are submitted by ascending
        // address.
        for (uint256 i = 1; i < 6; i++) {
            for (uint256 j = i; j > 0 && winners[j] < winners[j - 1]; j--) {
                (winners[j], winners[j - 1]) = (winners[j - 1], winners[j]);
            }
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

    /// @notice The band the batch is sized against reads the lower of the current rate and the
    ///         lagged minimum. With the current rate at the 5% cap but a 2.5% minimum over the
    ///         day, finishing at the narrower edge ($146.25) costs $53.75 a unit against the same
    ///         $260 fund, so the cap lands at 62.5 / 53.70 = 1.16 units rather than 1.48.
    function test_BatchCap_BandReadsTheLaggedMinimum() public {
        harness.setPendingLiq({size: 6 * SCALE, bankruptcyNotional: 1_200 * SCALE, isLong: true});
        harness.setOI({
            totalLongOI: 0, totalShortOI: 6 * SCALE, longWeightedEntrySum: 0, shortWeightedEntrySum: 1_200 * SCALE
        });
        harness.setVaultInsurance(260 * SCALE);
        address[] memory winners = new address[](6);
        for (uint256 i = 0; i < 6; i++) {
            address w = address(uint160(uint256(keccak256(abi.encode("winner", i)))));
            harness.setBucket({
                user: w, isLong: false, size: 1 * SCALE, entryValue: 200 * SCALE, collateral: 10 * SCALE
            });
            winners[i] = w;
        }
        for (uint256 i = 1; i < 6; i++) {
            for (uint256 j = i; j > 0 && winners[j] < winners[j - 1]; j--) {
                (winners[j], winners[j - 1]) = (winners[j - 1], winners[j]);
            }
        }
        BazaarTypes.AdlParams memory p = _params();
        p.currentPrice = 150 * SCALE;
        p.adlSnapshotPrice = 150 * SCALE;
        p.marginRequirements.laggedMmrBp = 250;

        BazaarTypes.AdlResult memory r = harness.execAdl(winners, p);
        assertApproxEqRel(r.totalLiqSize, 1.163873e18, 0.001e18, "$62.5 excess / $53.70 per unit");
        assertLt(r.totalLiqSize, 1.48e18, "narrower band, smaller batch than at the 5% cap");
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
    mapping(address => BazaarTypes.PositionBucket) internal positionBuckets;
    address[] internal deferred;

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
            vault,
            positionBuckets,
            deferred,
            currentPrice,
            isAdlPending,
            adlPendingSince,
            adlSnapshotPrice,
            adlLongs,
            int256(0),
            int256(0),
            MMR_BP
        );
    }

    function checkWithFunding(uint256 currentPrice, int256 currentFundingIndex)
        external
        view
        returns (VaultHealthLib.LiqExposureResult memory)
    {
        return VaultHealthLib.checkLiqExposure(
            vault, positionBuckets, deferred, currentPrice, false, 0, 0, false, currentFundingIndex, int256(0), MMR_BP
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
